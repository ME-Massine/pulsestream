# Checks that the committed Kubernetes manifests reference platform images the
# release process can account for (#264).
#
# Service images are published for every main commit while the manifests that
# name them are edited separately, so nothing has been stopping a manifest set
# from deploying one service built at commit A next to another built at commit
# B, or from pointing at a tag that can be repointed after review. This is the
# CI half of the promotion workflow: it reads the manifests and the release lock
# (when there is one) and refuses both.
#
# It needs no cluster, no registry and no credentials - it compares committed
# files with each other - so it runs on every pull request.
#
#   pwsh -File scripts/validate-release-manifests.ps1
#   pwsh -File scripts/validate-release-manifests.ps1 -ReleaseVersion v0.7.0
#
# See docs/architecture/release-and-promotion.md.
[CmdletBinding()]
param(
    # Root the Deployment manifests are discovered under.
    [string] $ManifestRoot = (Join-Path $PSScriptRoot "..\infrastructure\kubernetes"),
    # Repository prefix that marks an image as PulseStream-owned. Third-party
    # images (Grafana, Jaeger, the collector) are pinned by their own charts and
    # manifests and are not part of this promotion workflow.
    [string] $RegistryPrefix = "ghcr.io/me-massine/pulsestream",
    # Services that must each be referenced by exactly the manifest set.
    [string[]] $Services = @("ingestion-service", "telemetry-processor", "query-service"),
    # Validate against a specific release lock. Without it, the newest lock under
    # <ManifestRoot>/releases is used, and when there is none the pre-release
    # rules apply.
    [string] $ReleaseVersion,
    # Skip the release lock entirely and check only the pre-release rules.
    [switch] $IgnoreReleaseLock
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamRelease.psm1") -Force

$root = (Resolve-Path -LiteralPath $ManifestRoot).Path
$releaseRoot = Join-Path $root "releases"

$manifests = @(
    Get-ChildItem -Path $root -Recurse -File -Filter "*.yaml" |
        Where-Object { $_.Name -like "*deployment*.yaml" } |
        Sort-Object FullName
)

if ($manifests.Count -eq 0) {
    throw "No Deployment manifests were found under '$root'. Either the path is wrong or the manifests moved, and a check that silently finds nothing to check would pass."
}

Write-Host "Reading $($manifests.Count) manifest file(s) under $root"
$images = Get-ManifestImageReference -Path @($manifests | ForEach-Object { $_.FullName })

# --- Locate the release lock -------------------------------------------------

function Get-ReleaseLockPath {
    param([string] $Version)

    if ($Version) {
        $path = Join-Path (Join-Path $releaseRoot $Version) "images.lock.json"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Release '$Version' has no lock at '$path'. A release cannot be validated against a lock that was never written."
        }
        return $path
    }

    if (-not (Test-Path -LiteralPath $releaseRoot -PathType Container)) {
        return $null
    }

    # Newest by write time rather than by version order: a lock is written once,
    # by the promotion run that produced it, and comparing version strings would
    # need a full semver ordering for no gain here.
    $candidate = Get-ChildItem -Path $releaseRoot -Recurse -File -Filter "images.lock.json" |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($candidate) { return $candidate.FullName }
    return $null
}

$lock = $null
$lockPath = $null

if (-not $IgnoreReleaseLock) {
    $lockPath = Get-ReleaseLockPath -Version $ReleaseVersion
    if ($lockPath) {
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        Write-Host "Validating against release $($lock.version) ($($lock.state)) from $lockPath"
    } else {
        Write-Host "No release lock found under $releaseRoot - applying pre-release rules."
    }
} else {
    Write-Host "Release lock ignored by request - applying pre-release rules."
}

# --- Report ------------------------------------------------------------------

$platform = @($images | Where-Object {
    $repository = if ($_.Image.Registry) { "$($_.Image.Registry)/$($_.Image.Repository)" } else { $_.Image.Repository }
    $repository.StartsWith("$RegistryPrefix/")
})

Write-Host ""
Write-Host "Platform image references:"
foreach ($record in $platform) {
    Write-Host "  $($record.Workload)/$($record.Container): $($record.Image.Reference)"
}

$skipped = $images.Count - $platform.Count
if ($skipped -gt 0) {
    Write-Host "  ($skipped third-party image reference(s) outside $RegistryPrefix/ were not checked)"
}

$result = Test-ReleaseManifestConsistency `
    -ManifestImage $images `
    -RegistryPrefix $RegistryPrefix `
    -ExpectedService $Services `
    -Lock $lock

Write-Host ""
if (-not $result.Ok) {
    foreach ($problem in $result.Problems) {
        Write-Host "::error::$problem"
    }
    throw "$($result.Problems.Count) deployment image reference problem(s) found. See docs/architecture/release-and-promotion.md."
}

if ($lock) {
    Write-Host "[ok] Every platform Deployment is pinned to the digest release $($lock.version) promoted from commit $($lock.commit)."
} else {
    $commits = @($result.SourceCommits)
    if ($commits.Count -eq 1) {
        Write-Host "[ok] Every platform Deployment is pinned to one immutable build tag ($($commits[0]))."
    } else {
        Write-Host "[ok] Every platform Deployment is pinned to an immutable build tag."
    }
}
