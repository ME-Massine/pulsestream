# Writes the release manifest set for a promotion (#264).
#
# This is the only supported way deployment image references change. It takes
# digests that already exist in the registry - it never builds, tags or pushes
# anything - records them in a release lock, repins every platform Deployment to
# those digests, and generates the release notes for the range being released.
# The result is a working tree change that
# .github/workflows/release-promotion.yml turns into a pull request, because
# main only accepts reviewed changes.
#
# Running it by hand is the documented recovery path when the workflow cannot
# (see docs/architecture/release-and-promotion.md):
#
#   pwsh -File scripts/promote-release-manifests.ps1 `
#       -Version v0.7.0-rc.1 `
#       -Commit 5f5e8450786ad00ea52b9010d44858431557048c `
#       -ImageDigest "ingestion-service=sha256:...","telemetry-processor=sha256:...","query-service=sha256:..."
#
# The last thing it does is re-run the consistency check that CI runs, so a
# promotion that would leave the manifests and the lock disagreeing fails here
# rather than on the pull request.
[CmdletBinding()]
param(
    # Release or candidate tag: v<major>.<minor>.<patch>[-rc.<n>].
    [Parameter(Mandatory)] [string] $Version,
    # Full 40-character commit the images were built from.
    [Parameter(Mandatory)] [string] $Commit,
    # One "<service>=sha256:<hex>" entry per service, as resolved from the
    # registry by the tag that commit was published under.
    [Parameter(Mandatory)] [string[]] $ImageDigest,
    [string] $ManifestRoot = (Join-Path $PSScriptRoot "..\infrastructure\kubernetes"),
    [string] $RegistryPrefix = "ghcr.io/me-massine/pulsestream",
    [string[]] $Services = @("ingestion-service", "telemetry-processor", "query-service"),
    [string] $RepositoryUrl = "https://github.com/ME-Massine/pulsestream",
    # Release the notes are measured from. Defaults to the newest release
    # already recorded under <ManifestRoot>/releases.
    [string] $PreviousVersion,
    # Link back to the run that performed the promotion, so a deployed digest
    # leads to the evidence it was promoted on.
    [string] $PromotionRunUrl,
    # Refuse to promote when a commit in the range references no issue. Every
    # change lands through an issue-linked PR (pr-issue-alignment.yml), so one
    # that does not is either a direct push or a release the notes misdescribe.
    [switch] $RequireIssueReferences
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamRelease.psm1") -Force

$root = (Resolve-Path -LiteralPath $ManifestRoot).Path
$releaseRoot = Join-Path $root "releases"

# Not $version: PowerShell variable names are case-insensitive, so that would
# overwrite the $Version parameter with the parse result.
$parsedVersion = Test-SemanticVersionTag -Tag $Version
if (-not $parsedVersion.IsValid) {
    throw $parsedVersion.Reason
}
if ($Commit -notmatch '^[0-9a-f]{40}$') {
    throw "Promotion needs the full 40-character source commit, got '$Commit'."
}

$targetDirectory = Join-Path $releaseRoot $Version
if (Test-Path -LiteralPath $targetDirectory) {
    throw "Release '$Version' already exists at '$targetDirectory'. A released version is a fixed set of digests; publish a new version rather than rewriting one."
}

# --- Digests -----------------------------------------------------------------

$digests = @{}
foreach ($entry in $ImageDigest) {
    $parts = $entry.Split([char[]] '=', 2)
    if ($parts.Count -ne 2) {
        throw "Image digest '$entry' is not in '<service>=sha256:<hex>' form."
    }

    $service = $parts[0].Trim()
    if ($Services -notcontains $service) {
        throw "Image digest '$entry' names '$service', which is not one of: $($Services -join ', ')."
    }
    if ($digests.ContainsKey($service)) {
        throw "Service '$service' was given two digests. A commit maps to exactly one digest per service."
    }

    $digests[$service] = $parts[1].Trim()
}

foreach ($service in $Services) {
    if (-not $digests.ContainsKey($service)) {
        throw "No digest was given for '$service'. A release manifest set pins every service or none: a partial set deploys a mix of releases."
    }
}

# --- Release notes -----------------------------------------------------------

# The baseline the notes are measured from. Using the previous release's
# recorded commit rather than a git tag keeps this working before the first
# `v*` tag exists, and keeps the range honest if a tag is ever moved.
$previousCommit = $null
$baselineVersion = $PreviousVersion

if ($baselineVersion) {
    $previousLockPath = Join-Path (Join-Path $releaseRoot $baselineVersion) "images.lock.json"
    if (-not (Test-Path -LiteralPath $previousLockPath -PathType Leaf)) {
        throw "Previous release '$baselineVersion' has no lock at '$previousLockPath'."
    }
    $previousCommit = (Get-Content -LiteralPath $previousLockPath -Raw | ConvertFrom-Json).commit
} elseif (Test-Path -LiteralPath $releaseRoot -PathType Container) {
    $previousLock = Get-ChildItem -Path $releaseRoot -Recurse -File -Filter "images.lock.json" |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($previousLock) {
        $parsed = Get-Content -LiteralPath $previousLock.FullName -Raw | ConvertFrom-Json
        $baselineVersion = $parsed.version
        $previousCommit = $parsed.commit
    }
}

$range = if ($previousCommit) { "$previousCommit..$Commit" } else { $Commit }
Write-Host "Collecting commits for $range"

$separator = [char] 0x1f
$log = @(& git log --format="%H$separator%s" $range 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "git log $range failed: $log"
}

$commits = @(
    $log |
        Where-Object { $_ -and $_.Contains($separator) } |
        ForEach-Object {
            $fields = $_.Split([char[]] $separator, 2)
            [pscustomobject]@{ Sha = $fields[0]; Subject = $fields[1] }
        }
)

$notes = New-ReleaseNotes `
    -Commit $commits `
    -Version $Version `
    -SourceCommit $Commit `
    -PreviousVersion $baselineVersion `
    -RepositoryUrl $RepositoryUrl

Write-Host "$($commits.Count) commit(s), $($notes.Issues.Count) issue reference(s)"

if ($notes.Unreferenced.Count -gt 0) {
    foreach ($item in $notes.Unreferenced) {
        Write-Host "::warning::commit $($item.Sha.Substring(0,7)) references no issue: $($item.Subject)"
    }
    if ($RequireIssueReferences) {
        throw "$($notes.Unreferenced.Count) commit(s) in $range reference no issue, so the release notes cannot be generated from issue-scoped changes."
    }
}

# --- Write the lock and repin the manifests ---------------------------------

$lock = New-ReleaseLock `
    -Version $Version `
    -Commit $Commit `
    -RegistryPrefix $RegistryPrefix `
    -Digest $digests `
    -PromotedFrom (Get-SourceCommitTag -Commit $Commit) `
    -PromotionRunUrl $PromotionRunUrl

New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$lockPath = Join-Path $targetDirectory "images.lock.json"
[System.IO.File]::WriteAllText($lockPath, (($lock | ConvertTo-Json -Depth 6) -replace "`r`n", "`n") + "`n", $utf8NoBom)
Write-Host "Wrote $lockPath"

$notesPath = Join-Path $targetDirectory "release-notes.md"
[System.IO.File]::WriteAllText($notesPath, ($notes.Markdown -replace "`r`n", "`n"), $utf8NoBom)
Write-Host "Wrote $notesPath"

$manifests = @(
    Get-ChildItem -Path $root -Recurse -File -Filter "*.yaml" |
        Where-Object { $_.Name -like "*deployment*.yaml" } |
        Sort-Object FullName
)
$images = Get-ManifestImageReference -Path @($manifests | ForEach-Object { $_.FullName })

foreach ($service in $Services) {
    $repository = "$RegistryPrefix/$service"
    $reference = ConvertTo-ImageReference -Repository $repository -Tag $Version -Digest $digests[$service]

    $files = @(
        $images |
            Where-Object {
                $image = $_.Image
                $current = if ($image.Registry) { "$($image.Registry)/$($image.Repository)" } else { $image.Repository }
                $current -eq $repository
            } |
            ForEach-Object { $_.File } |
            Sort-Object -Unique
    )

    if ($files.Count -eq 0) {
        throw "No Deployment manifest references '$repository', so promoting '$service' would produce a lock nothing deploys."
    }

    foreach ($file in $files) {
        $updated = Set-ManifestImageReference -Path $file -Repository $repository -NewReference $reference
        Write-Host "Repinned $updated reference(s) in $file -> $reference"
    }
}

# --- Verify what was written -------------------------------------------------

$verification = Test-ReleaseManifestConsistency `
    -ManifestImage (Get-ManifestImageReference -Path @($manifests | ForEach-Object { $_.FullName })) `
    -RegistryPrefix $RegistryPrefix `
    -ExpectedService $Services `
    -Lock (Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json)

if (-not $verification.Ok) {
    foreach ($problem in $verification.Problems) {
        Write-Host "::error::$problem"
    }
    throw "The promoted manifest set does not match the lock that was just written."
}

Write-Host "[ok] $Version ($($lock.state)) pins every platform Deployment to the digests built from $Commit."
