# Runs every PowerShell check the repository owns, in one command, on whichever
# edition invoked it. This is what CI calls; it is also the fastest local check
# before opening a pull request.
#
# Two passes, in this order:
#
# 1. Parse every script and module under scripts\. A validation script is only
#    ever run during an incident, so a syntax error introduced months earlier is
#    discovered at the worst possible moment. Parsing is cheap and catches that
#    class of breakage on every pull request instead.
# 2. Run every scripts\tests\test-*.ps1 regression test. Each one runs in a
#    child process of the current host: several of them install global stand-ins
#    for kubectl or leave modules imported, and sharing a session would let one
#    test decide the outcome of the next.
#
# Two of the tests hand a committed manifest to kubectl's client-side serializer
# to produce the JSON shape the validators consume. `kubectl create
# --dry-run=client` still resolves the kind through API discovery, so it needs a
# reachable API server even though nothing is applied. Those two are skipped -
# loudly, and named in the summary - when no server answers, which is the case
# on a hosted CI runner and on any machine with its local cluster stopped.
#
#   powershell -File scripts\tests\run-all-tests.ps1
#   pwsh -File scripts/tests/run-all-tests.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptRoot = Join-Path $repositoryRoot "scripts"
$edition = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"

Write-Host "PulseStream PowerShell checks on $edition"
Write-Host "Repository root: $repositoryRoot"
Write-Host ""

$parseFailures = New-Object System.Collections.Generic.List[string]
$testFailures = New-Object System.Collections.Generic.List[string]
$skipped = New-Object System.Collections.Generic.List[string]

# Tests that call the real kubectl binary and therefore need API discovery to
# answer. Everything else in scripts\tests is pure offline computation.
$clusterDependentTests = @(
    "test-ingestion-hpa-structure.ps1",
    "test-network-policy-structure.ps1"
)

function Invoke-Native {
    <#
        .SYNOPSIS
        Runs a native command and returns its exit code.

        Windows PowerShell 5.1 turns anything a native command writes to stderr
        into a terminating NativeCommandError while $ErrorActionPreference is
        Stop, and both kubectl and a failing test write there routinely. The
        preference is relaxed for the duration of the call so the exit code -
        the only thing that decides pass or fail here - is what is acted on.
    #>
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [switch] $Quiet
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($Quiet) {
            & $FilePath @ArgumentList 2>&1 | Out-Null
        }
        else {
            & $FilePath @ArgumentList 2>&1 | ForEach-Object { Write-Host $_ }
        }

        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Test-KubectlSerializes {
    <#
        .SYNOPSIS
        Reports whether kubectl can serialize a manifest client-side right now.

        Presence of the binary is not enough: discovery has to reach an API
        server. The probe is the same call the cluster-dependent tests make, on
        a manifest that is always present, so it cannot disagree with them.
    #>
    param(
        [Parameter(Mandatory)] [string] $RepositoryRoot
    )

    $kubectl = Get-Command kubectl -CommandType Application -ErrorAction SilentlyContinue
    if (-not $kubectl) {
        return $false
    }

    $probe = Join-Path $RepositoryRoot "infrastructure\kubernetes\ingestion-service\hpa.yaml"
    if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) {
        return $false
    }

    $exitCode = Invoke-Native -FilePath $kubectl.Source -Quiet -ArgumentList @(
        "create", "--dry-run=client", "--validate=false", "-o", "json", "-f", $probe
    )

    return ($exitCode -eq 0)
}

# --- Pass 1: parse every script and module -----------------------------------

Write-Host "== Parsing scripts and modules =="

$sources = Get-ChildItem -Path $scriptRoot -Recurse -File -Include "*.ps1", "*.psm1" |
    Sort-Object -Property FullName

if ($sources.Count -eq 0) {
    throw "No PowerShell sources found under '$scriptRoot'."
}

foreach ($source in $sources) {
    $relativePath = $source.FullName.Substring($repositoryRoot.Length).TrimStart([char]"\", [char]"/")

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$tokens, [ref]$errors) | Out-Null

    if ($errors -and $errors.Count -gt 0) {
        Write-Host "[fail] $relativePath"
        foreach ($parseError in $errors) {
            Write-Host "       line $($parseError.Extent.StartLineNumber): $($parseError.Message)"
        }
        $parseFailures.Add($relativePath)
        continue
    }

    Write-Host "[ok] $relativePath"
}

Write-Host ""

# --- Pass 2: run the regression tests ----------------------------------------

Write-Host "== Running regression tests =="

# The host that is already running is the edition under test, so the child
# processes are started from its own executable rather than from a hard-coded
# powershell.exe or pwsh.exe.
$hostExecutable = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($hostExecutable)) {
    throw "Could not resolve the path of the current PowerShell host."
}

$tests = Get-ChildItem -Path $PSScriptRoot -File -Filter "test-*.ps1" |
    Sort-Object -Property Name

if ($tests.Count -eq 0) {
    throw "No regression tests found under '$PSScriptRoot'."
}

$kubectlSerializes = Test-KubectlSerializes -RepositoryRoot $repositoryRoot
if (-not $kubectlSerializes) {
    Write-Host "kubectl cannot serialize manifests here (no reachable API server)."
    Write-Host "Cluster-dependent tests will be skipped: $($clusterDependentTests -join ', ')"
}

foreach ($test in $tests) {
    Write-Host ""
    Write-Host "--- $($test.Name) ---"

    if (-not $kubectlSerializes -and $clusterDependentTests -contains $test.Name) {
        Write-Host "[skip] $($test.Name) needs kubectl client-side serialization"
        $skipped.Add($test.Name)
        continue
    }

    $exitCode = Invoke-Native -FilePath $hostExecutable -ArgumentList @(
        "-NoProfile", "-NonInteractive", "-File", $test.FullName
    )

    if ($exitCode -ne 0) {
        Write-Host "[fail] $($test.Name) exited with $exitCode"
        $testFailures.Add($test.Name)
        continue
    }

    Write-Host "[ok] $($test.Name)"
}

# --- Summary -----------------------------------------------------------------

Write-Host ""
Write-Host "== Summary =="
Write-Host "Edition:      $edition"
Write-Host "Parsed:       $($sources.Count) file(s), $($parseFailures.Count) failure(s)"
Write-Host "Tests:        $($tests.Count) file(s), $($testFailures.Count) failure(s), $($skipped.Count) skipped"

if ($skipped.Count -gt 0) {
    Write-Host "Skipped:        $($skipped -join ', ')"
}

if ($parseFailures.Count -gt 0) {
    Write-Host "Parse failures: $($parseFailures -join ', ')"
}

if ($testFailures.Count -gt 0) {
    Write-Host "Test failures:  $($testFailures -join ', ')"
}

if ($parseFailures.Count -gt 0 -or $testFailures.Count -gt 0) {
    throw "PowerShell checks failed on $edition."
}

Write-Host "All PowerShell checks passed on $edition."
