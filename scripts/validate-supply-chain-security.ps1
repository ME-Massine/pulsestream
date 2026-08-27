<#
.SYNOPSIS
    Validates the repository's supply-chain security configuration.

.DESCRIPTION
    The controls added for issue #263 are configuration, and configuration rots
    quietly: an unpinned action, a new service Dependabot never learned about, a
    Maven wrapper whose checksum was dropped during an upgrade, an accepted
    vulnerability whose expiry passed months ago. None of that fails a build on
    its own, and none of it is reliably caught by reading a diff.

    This script asserts the properties those controls depend on:

      1. Every GitHub Action is pinned to a full commit SHA with a version
         comment.
      2. Dependabot covers every service on every ecosystem it ships.
      3. Every Maven wrapper verifies the same distribution checksum.
      4. The release workflow scans before it pushes, and the gate is blocking.
      5. Accepted vulnerabilities carry a justification and an unexpired date.
      6. The required security files exist and CODEOWNERS covers critical paths.

    Read-only. No cluster, no network, no Docker.

.PARAMETER RepoRoot
    Repository root to validate. Defaults to the repository this script lives
    in; scripts/tests/test-supply-chain-security.ps1 points it at fixture copies
    to prove each check rejects what it claims to reject.

.PARAMETER Services
    Service directories under services/ that must be covered by Dependabot and
    must carry a checksum-verifying Maven wrapper.

.EXAMPLE
    pwsh -File scripts/validate-supply-chain-security.ps1
    powershell -File scripts\validate-supply-chain-security.ps1
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string[]] $Services = @("ingestion-service", "telemetry-processor", "query-service")
)

$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
$RepoRoot = (Resolve-Path $RepoRoot).Path

$script:Failures = 0

function Write-CheckOk {
    param([Parameter(Mandatory)] [string] $Message)
    Write-Host "[ok] $Message"
}

function Write-CheckFail {
    param([Parameter(Mandatory)] [string] $Message)
    Write-Host "[fail] $Message"
    $script:Failures++
}

function Get-RepoPath {
    param([Parameter(Mandatory)] [string] $RelativePath)
    return (Join-Path $RepoRoot $RelativePath)
}

function Read-RepoText {
    param([Parameter(Mandatory)] [string] $RelativePath)
    return (Get-Content -Raw -LiteralPath (Get-RepoPath $RelativePath))
}

# --- 1. Required files -------------------------------------------------------
# Everything downstream assumes these exist; checking first means a missing file
# is reported as a missing file rather than as a confusing parse failure.

$requiredFiles = @(
    "SECURITY.md",
    ".trivyignore.yaml",
    ".github/CODEOWNERS",
    ".github/dependabot.yml",
    ".github/workflows/codeql.yml",
    ".github/workflows/dependency-review.yml",
    ".github/workflows/publish-images.yml"
)

$missingRequired = @()
foreach ($file in $requiredFiles) {
    if (Test-Path -LiteralPath (Get-RepoPath $file)) {
        continue
    }
    $missingRequired += $file
}

if ($missingRequired.Count -eq 0) {
    Write-CheckOk "all $($requiredFiles.Count) required security files are present"
} else {
    Write-CheckFail "missing required security file(s): $($missingRequired -join ', ')"
    # Nothing below can be trusted without them.
    Write-Host ""
    Write-Host "Supply-chain validation aborted with $script:Failures failure(s)."
    exit 1
}

# --- 2. Action pinning -------------------------------------------------------
# A tag is a moving pointer: whoever controls the action repository can retarget
# v4 at new code, and that code runs with this repository's GITHUB_TOKEN. A
# 40-character commit SHA is the only 'uses' form that cannot be repointed. The
# trailing version comment is what keeps the pin readable and is what Dependabot
# rewrites alongside the SHA.

$workflowDir = Get-RepoPath ".github/workflows"
$workflows = Get-ChildItem -LiteralPath $workflowDir -Filter "*.yml" | Sort-Object Name

if ($workflows.Count -eq 0) {
    Write-CheckFail "no workflows found under .github/workflows"
}

$unpinned = @()
$uncommented = @()
$usesCount = 0

foreach ($workflow in $workflows) {
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $workflow.FullName)) {
        $lineNumber++

        $match = [regex]::Match($line, '^\s*(?:-\s*)?uses:\s*(?<ref>[^\s#]+)\s*(?<comment>#.*)?$')
        if (-not $match.Success) {
            continue
        }

        $ref = $match.Groups["ref"].Value.Trim("'", '"')

        # Local composite actions are part of this repository and are already
        # covered by review; there is nothing external to pin.
        if ($ref.StartsWith("./")) {
            continue
        }

        $usesCount++
        $location = "$($workflow.Name):$lineNumber"

        if ($ref -notmatch '^[^@]+@[0-9a-f]{40}$') {
            $unpinned += "$location -> $ref"
            continue
        }

        if ($match.Groups["comment"].Value -notmatch '#\s*v?\d') {
            $uncommented += "$location -> $ref"
        }
    }
}

if ($unpinned.Count -eq 0) {
    Write-CheckOk "all $usesCount external action references across $($workflows.Count) workflows are pinned to a commit SHA"
} else {
    Write-CheckFail "action(s) not pinned to a 40-character commit SHA: $($unpinned -join '; ')"
}

if ($uncommented.Count -eq 0) {
    if ($unpinned.Count -eq 0) {
        Write-CheckOk "every pinned action carries a version comment"
    }
} else {
    Write-CheckFail "pinned action(s) missing a '# vX.Y.Z' version comment: $($uncommented -join '; ')"
}

# --- 2b. Action inputs are scalars -------------------------------------------
# Every value under 'with:' is an action input, and action inputs are strings. A
# YAML sequence there is rejected by GitHub's workflow parser before any job is
# created - which means no check run, no annotation on the pull request, and a
# workflow that looks present but has never executed. Multi-value inputs are
# comma-separated strings instead.

$sequenceInputs = @()

foreach ($workflow in $workflows) {
    $lines = Get-Content -LiteralPath $workflow.FullName
    $withIndent = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($line -match '^(?<indent>\s*)with:\s*$') {
            $withIndent = $Matches["indent"].Length
            continue
        }

        if ($withIndent -lt 0) { continue }
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }

        $indent = ($line -replace '\S.*$', '').Length
        if ($indent -le $withIndent) {
            # Dedented out of the with: block.
            $withIndent = -1
            continue
        }

        if ($line -match '^\s*-\s') {
            $sequenceInputs += "$($workflow.Name):$($i + 1)"
        }
    }
}

if ($sequenceInputs.Count -eq 0) {
    Write-CheckOk "every action input is a scalar, so no workflow is rejected at parse time"
} else {
    Write-CheckFail "action input(s) given as a YAML sequence, which makes the workflow file invalid: $($sequenceInputs -join '; ')"
}

# --- 3. Dependabot coverage --------------------------------------------------
# Each service is an independent Maven project with its own Dockerfile, so each
# needs its own update configuration. Adding a service without adding its blocks
# leaves it silently unmonitored, which looks exactly like a service with no
# vulnerable dependencies.

$dependabotText = Read-RepoText ".github/dependabot.yml"

$configured = New-Object System.Collections.Generic.HashSet[string]
foreach ($match in [regex]::Matches($dependabotText, '(?s)-\s*package-ecosystem:\s*"?(?<eco>[^"\s]+)"?.*?directory:\s*"?(?<dir>[^"\s]+)"?')) {
    [void] $configured.Add("$($match.Groups['eco'].Value)|$($match.Groups['dir'].Value)")
}

$expectedUpdates = @("github-actions|/")
foreach ($service in $Services) {
    $expectedUpdates += "maven|/services/$service"
    $expectedUpdates += "docker|/services/$service"
}

$missingUpdates = @()
foreach ($expected in $expectedUpdates) {
    if (-not $configured.Contains($expected)) {
        $missingUpdates += ($expected -replace '\|', ' at ')
    }
}

if ($missingUpdates.Count -eq 0) {
    Write-CheckOk "Dependabot covers all $($expectedUpdates.Count) expected ecosystem/directory pairs"
} else {
    Write-CheckFail "Dependabot is missing update configuration for: $($missingUpdates -join ', ')"
}

# --- 4. Maven wrapper checksums ----------------------------------------------
# mvnw downloads and then executes a Maven distribution. Without
# distributionSha256Sum that archive is trusted on transport security alone. The
# three wrappers must also agree: a service quietly pointing at a different
# distribution is the same problem wearing a different hat.

$wrapperChecksums = @{}
$wrapperUrls = @{}
$wrapperProblems = @()

foreach ($service in $Services) {
    $relative = "services/$service/.mvn/wrapper/maven-wrapper.properties"
    $path = Get-RepoPath $relative

    if (-not (Test-Path -LiteralPath $path)) {
        $wrapperProblems += "$service has no maven-wrapper.properties"
        continue
    }

    $checksum = $null
    $url = $null
    foreach ($line in (Get-Content -LiteralPath $path)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*distributionSha256Sum\s*=\s*(?<value>\S+)\s*$') { $checksum = $Matches["value"] }
        if ($line -match '^\s*distributionUrl\s*=\s*(?<value>\S+)\s*$') { $url = $Matches["value"] }
    }

    if (-not $checksum) {
        $wrapperProblems += "$service does not set distributionSha256Sum"
        continue
    }

    if ($checksum -notmatch '^[0-9a-f]{64}$') {
        $wrapperProblems += "$service has a distributionSha256Sum that is not 64 hex characters"
        continue
    }

    $wrapperChecksums[$service] = $checksum
    $wrapperUrls[$service] = $url
}

if ($wrapperProblems.Count -gt 0) {
    Write-CheckFail "Maven wrapper checksum problems: $($wrapperProblems -join '; ')"
} else {
    $distinctChecksums = @($wrapperChecksums.Values | Sort-Object -Unique)
    $distinctUrls = @($wrapperUrls.Values | Sort-Object -Unique)

    if ($distinctChecksums.Count -ne 1 -or $distinctUrls.Count -ne 1) {
        Write-CheckFail "services do not agree on one Maven distribution: $($distinctUrls.Count) URL(s), $($distinctChecksums.Count) checksum(s)"
    } else {
        Write-CheckOk "all $($Services.Count) Maven wrappers verify the same distribution checksum ($($distinctChecksums[0].Substring(0, 12))...)"
    }
}

# --- 5. Release gate ordering ------------------------------------------------
# A scan that runs after the push is theatre: the image the cluster can already
# pull is the one that was never gated. Order is the property that matters here,
# so it is asserted directly rather than inferred from the steps being present.

$publishLines = Get-Content -LiteralPath (Get-RepoPath ".github/workflows/publish-images.yml")

$gateLine = -1
$pushLine = -1
$gateBlocking = $false

for ($i = 0; $i -lt $publishLines.Count; $i++) {
    if ($gateLine -lt 0 -and $publishLines[$i] -match '^\s*-\s*name:\s*Vulnerability gate\s*$') {
        $gateLine = $i
    }
    if ($pushLine -lt 0 -and $publishLines[$i] -match '^\s*docker push\b') {
        $pushLine = $i
    }
}

if ($gateLine -lt 0) {
    Write-CheckFail "publish-images.yml has no 'Vulnerability gate' step"
} elseif ($pushLine -lt 0) {
    Write-CheckFail "publish-images.yml never pushes an image"
} elseif ($gateLine -gt $pushLine) {
    Write-CheckFail "publish-images.yml pushes (line $($pushLine + 1)) before the vulnerability gate (line $($gateLine + 1))"
} else {
    # The gate must also be able to fail. exit-code 0 would report and continue.
    for ($i = $gateLine; $i -lt $pushLine; $i++) {
        if ($publishLines[$i] -match '^\s*exit-code:\s*"?1"?\s*$') {
            $gateBlocking = $true
            break
        }
    }

    if ($gateBlocking) {
        Write-CheckOk "publish-images.yml gates on a blocking scan (line $($gateLine + 1)) before pushing (line $($pushLine + 1))"
    } else {
        Write-CheckFail "the vulnerability gate in publish-images.yml does not set exit-code: 1, so it cannot block a release"
    }
}

# --- 6. Accepted vulnerabilities ---------------------------------------------
# An allowlist without expiry dates is a permanent exemption written in pencil.
# Every entry must say why it is accepted and when the acceptance lapses, and an
# entry whose date has already passed is reported here - in pull request CI -
# rather than discovered when a release is blocked.

$trivyIgnoreText = Read-RepoText ".trivyignore.yaml"
$ignoreEntries = [regex]::Matches($trivyIgnoreText, '(?s)-\s*id:\s*(?<id>\S+)(?<body>.*?)(?=(?:\r?\n\s*-\s*id:)|\z)')

if ($ignoreEntries.Count -eq 0) {
    # An empty allowlist is the goal state, not a failure.
    Write-CheckOk "no vulnerabilities are currently accepted in .trivyignore.yaml"
} else {
    $today = (Get-Date).Date
    $entryProblems = @()
    $soonest = $null

    foreach ($entry in $ignoreEntries) {
        $id = $entry.Groups["id"].Value
        $body = $entry.Groups["body"].Value

        if ($body -notmatch 'statement:') {
            $entryProblems += "$id has no statement explaining the acceptance"
        }

        $dateMatch = [regex]::Match($body, 'expired_at:\s*(?<date>\d{4}-\d{2}-\d{2})')
        if (-not $dateMatch.Success) {
            $entryProblems += "$id has no expired_at date"
            continue
        }

        $expiry = [datetime]::ParseExact($dateMatch.Groups["date"].Value, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
        if ($expiry -le $today) {
            $entryProblems += "$id expired on $($dateMatch.Groups['date'].Value)"
            continue
        }

        if ($null -eq $soonest -or $expiry -lt $soonest) {
            $soonest = $expiry
        }
    }

    if ($entryProblems.Count -eq 0) {
        Write-CheckOk "$($ignoreEntries.Count) accepted vulnerability entr(ies), all justified, next expiry $($soonest.ToString('yyyy-MM-dd'))"
    } else {
        Write-CheckFail "accepted vulnerability problems: $($entryProblems -join '; ')"
    }
}

# --- 7. Code ownership -------------------------------------------------------
# Ownership only means something for the paths where an unreviewed change is
# expensive. These are those paths; a rule removed from CODEOWNERS should fail
# here rather than be noticed the first time something merges without review.

$codeownersLines = Get-Content -LiteralPath (Get-RepoPath ".github/CODEOWNERS")

$ownedPatterns = @()
foreach ($line in $codeownersLines) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }

    $parts = $trimmed -split '\s+'
    if ($parts.Count -lt 2) { continue }
    if ($parts[1] -notmatch '^[@]') { continue }

    $ownedPatterns += $parts[0]
}

$requiredOwnership = @(
    "*",
    "/.github/",
    "/.github/workflows/",
    "/infrastructure/",
    "/services/",
    "/scripts/",
    "/SECURITY.md",
    "/.trivyignore.yaml"
)

$unowned = @()
foreach ($pattern in $requiredOwnership) {
    if ($ownedPatterns -notcontains $pattern) {
        $unowned += $pattern
    }
}

if ($unowned.Count -eq 0) {
    Write-CheckOk "CODEOWNERS assigns an owner to all $($requiredOwnership.Count) critical paths"
} else {
    Write-CheckFail "CODEOWNERS has no owner for: $($unowned -join ', ')"
}

# --- Result ------------------------------------------------------------------

Write-Host ""
if ($script:Failures -gt 0) {
    Write-Host "Supply-chain validation failed with $script:Failures failure(s)."
    exit 1
}

Write-Host "Supply-chain security configuration validated."
exit 0
