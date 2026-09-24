# Parse every PowerShell source and run every offline regression test for the
# current PowerShell edition. Cluster-dependent tests are skipped only when
# kubectl cannot reach an API server; Kubernetes resources are checked separately
# by the CI kubeconform job.
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptRoot = Join-Path $repositoryRoot "scripts"
$edition = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"

Write-Host "PulseStream PowerShell checks on $edition"
Write-Host "Repository root: $repositoryRoot"

$parseFailures = [System.Collections.Generic.List[string]]::new()
$testFailures = [System.Collections.Generic.List[string]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()

# These tests use kubectl's client-side serializer, which still needs API
# discovery for the custom resource kind. They are not silently counted as pass.
$clusterDependentTests = @(
    "test-ingestion-hpa-structure.ps1",
    "test-network-policy-structure.ps1"
)

function Invoke-Native {
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
    param([Parameter(Mandatory)] [string] $RepositoryRoot)

    $kubectl = Get-Command kubectl -CommandType Application -ErrorAction SilentlyContinue
    $probe = Join-Path $RepositoryRoot "infrastructure\kubernetes\ingestion-service\hpa.yaml"
    if (-not $kubectl -or -not (Test-Path -LiteralPath $probe -PathType Leaf)) {
        return $false
    }

    $exitCode = Invoke-Native -FilePath $kubectl.Source -Quiet -ArgumentList @(
        "create", "--dry-run=client", "--validate=false", "-o", "json", "-f", $probe
    )
    return ($exitCode -eq 0)
}

Write-Host "== Parsing scripts and modules =="
$sources = @(Get-ChildItem -Path $scriptRoot -Recurse -File -Include "*.ps1", "*.psm1" |
    Sort-Object -Property FullName)
if ($sources.Count -eq 0) {
    throw "No PowerShell sources found under '$scriptRoot'."
}

foreach ($source in $sources) {
    $relativePath = $source.FullName.Substring($repositoryRoot.Length).TrimStart([char]"\", [char]"/")
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $source.FullName, [ref]$tokens, [ref]$errors
    ) | Out-Null

    if ($errors -and $errors.Count -gt 0) {
        Write-Host "[fail] $relativePath"
        foreach ($parseError in $errors) {
            Write-Host "       line $($parseError.Extent.StartLineNumber): $($parseError.Message)"
        }
        $parseFailures.Add($relativePath)
    }
    else {
        Write-Host "[ok] $relativePath"
    }
}

Write-Host ""
Write-Host "== Running regression tests =="
$hostExecutable = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($hostExecutable)) {
    throw "Could not resolve the path of the current PowerShell host."
}

$tests = @(Get-ChildItem -Path $PSScriptRoot -File -Filter "test-*.ps1" |
    Sort-Object -Property Name)
if ($tests.Count -eq 0) {
    throw "No regression tests found under '$PSScriptRoot'."
}

$kubectlSerializes = Test-KubectlSerializes -RepositoryRoot $repositoryRoot
if (-not $kubectlSerializes) {
    Write-Host "kubectl cannot serialize manifests here; cluster-dependent tests will be skipped."
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
    }
    else {
        Write-Host "[ok] $($test.Name)"
    }
}

Write-Host ""
Write-Host "== Summary =="
Write-Host "Edition: $edition"
Write-Host "Parsed: $($sources.Count) file(s), $($parseFailures.Count) failure(s)"
Write-Host "Tests: $($tests.Count) file(s), $($testFailures.Count) failure(s), $($skipped.Count) skipped"
if ($skipped.Count -gt 0) {
    Write-Host "Skipped: $($skipped -join ', ')"
}
if ($parseFailures.Count -gt 0) {
    Write-Host "Parse failures: $($parseFailures -join ', ')"
}
if ($testFailures.Count -gt 0) {
    Write-Host "Test failures: $($testFailures -join ', ')"
}

if ($parseFailures.Count -gt 0 -or $testFailures.Count -gt 0) {
    throw "PowerShell checks failed on $edition."
}

Write-Host "All PowerShell checks passed on $edition."
