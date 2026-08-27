<#
.SYNOPSIS
    Structural coverage for scripts/validate-supply-chain-security.ps1.

.DESCRIPTION
    A validator that passes is only reassuring if it can also fail. Each case
    below copies the repository's real supply-chain configuration into a
    fixture, breaks exactly one property, and asserts the validator rejects it
    with a message that names the problem.

    Every mutation is one a plausible future change could make by accident: an
    action re-pinned to a tag during a hurried upgrade, a service added without
    its Dependabot blocks, a wrapper checksum dropped, a scan moved after the
    push, an acceptance left to rot past its expiry date.

    Offline and read-only. Nothing outside the fixtures is written.

.EXAMPLE
    pwsh -File scripts/tests/test-supply-chain-security.ps1
    powershell -File scripts\tests\test-supply-chain-security.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$script:Failures = 0

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$validator = Join-Path $repoRoot "scripts\validate-supply-chain-security.ps1"

# Re-invoke whichever host is running this file, so the same cases cover Windows
# PowerShell 5.1 and PowerShell 7 without assuming pwsh is on PATH.
$psExe = (Get-Process -Id $PID).Path

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pulsestream-supplychain-" + [Guid]::NewGuid().ToString("N"))

# Only the paths the validator reads. Copying the whole repository would make
# each case slower and would let an unrelated file influence the result.
$fixtureFiles = @(
    "SECURITY.md",
    ".trivyignore.yaml",
    ".github\CODEOWNERS",
    ".github\dependabot.yml",
    "services\ingestion-service\.mvn\wrapper\maven-wrapper.properties",
    "services\telemetry-processor\.mvn\wrapper\maven-wrapper.properties",
    "services\query-service\.mvn\wrapper\maven-wrapper.properties"
)

function New-Fixture {
    $path = Join-Path $fixtureRoot ([Guid]::NewGuid().ToString("N"))

    foreach ($relative in $fixtureFiles) {
        $source = Join-Path $repoRoot $relative
        $destination = Join-Path $path $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
    }

    $workflowSource = Join-Path $repoRoot ".github\workflows"
    $workflowTarget = Join-Path $path ".github\workflows"
    New-Item -ItemType Directory -Force -Path $workflowTarget | Out-Null
    Copy-Item -Path (Join-Path $workflowSource "*.yml") -Destination $workflowTarget

    return $path
}

function Invoke-Validator {
    param([Parameter(Mandatory)] [string] $Path)

    $output = & $psExe -NoProfile -File $validator -RepoRoot $Path 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String)
    }
}

function Edit-FixtureFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $RelativePath,
        [Parameter(Mandatory)] [scriptblock] $Transform
    )

    $file = Join-Path $Path $RelativePath
    $text = Get-Content -Raw -LiteralPath $file
    $updated = & $Transform $text

    if ($updated -eq $text) {
        throw "Mutation of $RelativePath changed nothing - the fixture no longer contains what the case is trying to break."
    }

    Set-Content -LiteralPath $file -Value $updated -NoNewline
}

function Assert-Accepts {
    param([Parameter(Mandatory)] [string] $What)

    $fixture = New-Fixture
    $result = Invoke-Validator -Path $fixture

    if ($result.ExitCode -eq 0) {
        Write-Host "[ok] $What"
        return
    }

    Write-Host "[fail] $What -> the validator rejected the unmodified configuration (exit $($result.ExitCode))"
    Write-Host $result.Output
    $script:Failures++
}

function Assert-Rejects {
    param(
        [Parameter(Mandatory)] [string] $What,
        [Parameter(Mandatory)] [string] $RelativePath,
        [Parameter(Mandatory)] [scriptblock] $Transform,
        [Parameter(Mandatory)] [string] $ExpectedMessage
    )

    $fixture = New-Fixture

    try {
        Edit-FixtureFile -Path $fixture -RelativePath $RelativePath -Transform $Transform
    } catch {
        Write-Host "[fail] $What -> $($_.Exception.Message)"
        $script:Failures++
        return
    }

    $result = Invoke-Validator -Path $fixture

    if ($result.ExitCode -eq 0) {
        Write-Host "[fail] $What -> the validator accepted it"
        $script:Failures++
        return
    }

    if ($result.Output -notmatch $ExpectedMessage) {
        Write-Host "[fail] $What -> rejected, but not for the expected reason (wanted /$ExpectedMessage/)"
        Write-Host $result.Output
        $script:Failures++
        return
    }

    Write-Host "[ok] $What"
}

function Assert-RejectsMissingFile {
    param(
        [Parameter(Mandatory)] [string] $What,
        [Parameter(Mandatory)] [string] $RelativePath
    )

    $fixture = New-Fixture
    Remove-Item -LiteralPath (Join-Path $fixture $RelativePath) -Force

    $result = Invoke-Validator -Path $fixture

    if ($result.ExitCode -eq 0) {
        Write-Host "[fail] $What -> the validator accepted it"
        $script:Failures++
        return
    }

    if ($result.Output -notmatch "missing required security file") {
        Write-Host "[fail] $What -> rejected, but not as a missing required file"
        Write-Host $result.Output
        $script:Failures++
        return
    }

    Write-Host "[ok] $What"
}

try {
    Assert-Accepts "the repository's own supply-chain configuration passes"

    # --- Action pinning ------------------------------------------------------

    Assert-Rejects `
        -What "an action re-pinned to a moving tag was rejected" `
        -RelativePath ".github\workflows\dependency-review.yml" `
        -Transform { param($text) $text -replace 'actions/checkout@[0-9a-f]{40} # v[0-9.]+', 'actions/checkout@v4' } `
        -ExpectedMessage "not pinned to a 40-character commit SHA"

    Assert-Rejects `
        -What "an action pinned to a truncated SHA was rejected" `
        -RelativePath ".github\workflows\dependency-review.yml" `
        -Transform { param($text) $text -replace 'actions/checkout@([0-9a-f]{20})[0-9a-f]{20}', 'actions/checkout@$1' } `
        -ExpectedMessage "not pinned to a 40-character commit SHA"

    Assert-Rejects `
        -What "a correctly pinned action with no version comment was rejected" `
        -RelativePath ".github\workflows\dependency-review.yml" `
        -Transform { param($text) $text -replace '(actions/checkout@[0-9a-f]{40}) # v[0-9.]+', '$1' } `
        -ExpectedMessage "missing a '# vX.Y.Z' version comment"

    # --- Action inputs -------------------------------------------------------
    # This is the case that exists because it happened: deny-licenses was
    # written as a YAML list, GitHub rejected the whole file at parse time, and
    # the pull request showed no failing check because no job was ever created.

    Assert-Rejects `
        -What "an action input written as a YAML sequence was rejected" `
        -RelativePath ".github\workflows\dependency-review.yml" `
        -Transform {
            param($text)
            $text -replace 'deny-licenses: "[^"]+"', "deny-licenses:`r`n            - AGPL-3.0-only`r`n            - GPL-3.0-only"
        } `
        -ExpectedMessage "given as a YAML sequence"

    Assert-Rejects `
        -What "a sequence-valued input in the release workflow was rejected" `
        -RelativePath ".github\workflows\publish-images.yml" `
        -Transform {
            param($text)
            $text -replace '(?m)^          severity: CRITICAL,HIGH$', "          severity:`r`n            - CRITICAL`r`n            - HIGH"
        } `
        -ExpectedMessage "given as a YAML sequence"

    # --- Dependabot coverage -------------------------------------------------

    Assert-Rejects `
        -What "a service left out of the Docker update configuration was rejected" `
        -RelativePath ".github\dependabot.yml" `
        -Transform {
            param($text)
            # Drop the final docker block, which is query-service.
            $index = $text.LastIndexOf("  - package-ecosystem: docker")
            return $text.Substring(0, $index)
        } `
        -ExpectedMessage "missing update configuration for: docker at /services/query-service"

    Assert-Rejects `
        -What "removing the GitHub Actions update configuration was rejected" `
        -RelativePath ".github\dependabot.yml" `
        -Transform { param($text) $text -replace 'package-ecosystem: github-actions', 'package-ecosystem: gitsubmodule' } `
        -ExpectedMessage "missing update configuration for: github-actions at /"

    # --- Maven wrapper checksums ---------------------------------------------

    Assert-Rejects `
        -What "a wrapper with no distribution checksum was rejected" `
        -RelativePath "services\query-service\.mvn\wrapper\maven-wrapper.properties" `
        -Transform { param($text) $text -replace '(?m)^distributionSha256Sum=.*$', '' } `
        -ExpectedMessage "does not set distributionSha256Sum"

    Assert-Rejects `
        -What "a wrapper whose checksum is not a SHA-256 was rejected" `
        -RelativePath "services\query-service\.mvn\wrapper\maven-wrapper.properties" `
        -Transform { param($text) $text -replace '(?m)^distributionSha256Sum=.*$', 'distributionSha256Sum=notachecksum' } `
        -ExpectedMessage "not 64 hex characters"

    Assert-Rejects `
        -What "one service pointing at a different Maven distribution was rejected" `
        -RelativePath "services\query-service\.mvn\wrapper\maven-wrapper.properties" `
        -Transform {
            param($text)
            $text -replace '(?m)^distributionSha256Sum=.*$', ('distributionSha256Sum=' + ('a' * 64))
        } `
        -ExpectedMessage "do not agree on one Maven distribution"

    # --- Release gate --------------------------------------------------------

    Assert-Rejects `
        -What "a release workflow that pushes before scanning was rejected" `
        -RelativePath ".github\workflows\publish-images.yml" `
        -Transform {
            param($text)
            # Move a push ahead of the gate without removing the gate, which is
            # what an accidental step reorder looks like.
            $text -replace '(?m)^      - name: Build image$', "      - name: Push early`r`n        run: |`r`n          docker push `"broken`"`r`n`r`n      - name: Build image"
        } `
        -ExpectedMessage "pushes \(line \d+\) before the vulnerability gate"

    Assert-Rejects `
        -What "a vulnerability gate downgraded to report-only was rejected" `
        -RelativePath ".github\workflows\publish-images.yml" `
        -Transform {
            param($text)
            $index = $text.LastIndexOf('exit-code: "1"')
            return $text.Remove($index, 'exit-code: "1"'.Length).Insert($index, 'exit-code: "0"')
        } `
        -ExpectedMessage "does not set exit-code: 1"

    Assert-Rejects `
        -What "removing the vulnerability gate entirely was rejected" `
        -RelativePath ".github\workflows\publish-images.yml" `
        -Transform { param($text) $text -replace '- name: Vulnerability gate', '- name: Vulnerability suggestion' } `
        -ExpectedMessage "no 'Vulnerability gate' step"

    # --- Accepted vulnerabilities --------------------------------------------

    Assert-Rejects `
        -What "an accepted vulnerability past its expiry date was rejected" `
        -RelativePath ".trivyignore.yaml" `
        -Transform { param($text) $text -replace 'expired_at: \d{4}-\d{2}-\d{2}', 'expired_at: 2020-01-01' } `
        -ExpectedMessage "expired on 2020-01-01"

    Assert-Rejects `
        -What "an accepted vulnerability with no expiry date was rejected" `
        -RelativePath ".trivyignore.yaml" `
        -Transform { param($text) $text -replace '(?m)^\s*expired_at: \d{4}-\d{2}-\d{2}\r?\n', '' } `
        -ExpectedMessage "has no expired_at date"

    Assert-Rejects `
        -What "an accepted vulnerability with no justification was rejected" `
        -RelativePath ".trivyignore.yaml" `
        -Transform { param($text) $text -replace 'statement:', 'note:' } `
        -ExpectedMessage "has no statement explaining the acceptance"

    # --- Code ownership ------------------------------------------------------

    Assert-Rejects `
        -What "dropping workflow code ownership was rejected" `
        -RelativePath ".github\CODEOWNERS" `
        -Transform { param($text) $text -replace '(?m)^/\.github/workflows/\s+@\S+\r?\n', '' } `
        -ExpectedMessage "no owner for: /\.github/workflows/"

    Assert-Rejects `
        -What "a CODEOWNERS rule with a pattern but no owner was rejected" `
        -RelativePath ".github\CODEOWNERS" `
        -Transform { param($text) $text -replace '(?m)^(/infrastructure/)\s+@\S+$', '$1' } `
        -ExpectedMessage "no owner for: /infrastructure/"

    # --- Required files ------------------------------------------------------

    Assert-RejectsMissingFile -What "a missing SECURITY.md was rejected" -RelativePath "SECURITY.md"
    Assert-RejectsMissingFile -What "a missing CodeQL workflow was rejected" -RelativePath ".github\workflows\codeql.yml"
    Assert-RejectsMissingFile -What "a missing dependency review workflow was rejected" -RelativePath ".github\workflows\dependency-review.yml"
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

Write-Host ""
if ($script:Failures -gt 0) {
    Write-Host "Supply-chain validator checks failed: $script:Failures case(s)."
    exit 1
}

Write-Host "Supply-chain validator checks behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
exit 0
