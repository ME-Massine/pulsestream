# Unit coverage for the release and image promotion rules (#264).
#
# Every failure this workflow exists to prevent is one a real registry will not
# produce on demand: a promotion that rebuilt instead of re-tagging, a required
# check that never ran, a manifest set left pinned to the previous release, two
# services deployed from different commits. All of them are arranged here from
# literals, with no registry, no cluster and no docker.
#
# The last section is the end-to-end one: it copies the real Deployment
# manifests to a temporary tree, promotes them with fabricated digests, and runs
# the CI validator over the result - then breaks one digest and requires the
# validator to catch it.
#
#   powershell -File scripts\tests\test-release-promotion.ps1
#   pwsh -File scripts/tests/test-release-promotion.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$script:Failures = 0

Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamRelease.psm1") -Force

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$registry = "ghcr.io/me-massine/pulsestream"
$services = @("ingestion-service", "telemetry-processor", "query-service")

$digestA = "sha256:" + ("a" * 64)
$digestB = "sha256:" + ("b" * 64)
$digestC = "sha256:" + ("c" * 64)

function Assert-Equal {
    param([Parameter(Mandatory)] [string] $What, $Expected, $Actual)

    if ($Expected -eq $Actual) {
        Write-Host "[ok] $What -> $Actual"
        return
    }

    Write-Host "[fail] $What -> expected '$Expected', got '$Actual'"
    $script:Failures++
}

function Assert-True {
    param([Parameter(Mandatory)] [string] $What, [Parameter(Mandatory)] [bool] $Condition)

    if ($Condition) {
        Write-Host "[ok] $What"
        return
    }

    Write-Host "[fail] $What"
    $script:Failures++
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)] [string] $What,
        [Parameter(Mandatory)] [scriptblock] $Script,
        [Parameter(Mandatory)] [string] $ExpectedMessage
    )

    try {
        & $Script | Out-Null
    } catch {
        if ($_.Exception.Message -match $ExpectedMessage) {
            Write-Host "[ok] $What"
            return
        }

        Write-Host "[fail] $What -> expected '$ExpectedMessage', got '$($_.Exception.Message)'"
        $script:Failures++
        return
    }

    Write-Host "[fail] $What -> it was accepted"
    $script:Failures++
}

# Builds the record shape Get-ManifestImageReference returns, without a file.
function New-ImageRecord {
    param([string] $Service, [string] $Reference, [string] $File)

    if (-not $File) { $File = "infrastructure/kubernetes/$Service/deployment.yaml" }

    return [pscustomobject]@{
        File      = $File
        Workload  = $Service
        Container = $Service
        Image     = ConvertFrom-ImageReference -Reference $Reference
    }
}

function New-TestLock {
    param([string] $Version = "v0.7.0", [hashtable] $Digest)

    if (-not $Digest) {
        $Digest = @{ "ingestion-service" = $digestA; "telemetry-processor" = $digestB; "query-service" = $digestC }
    }

    $lock = New-ReleaseLock `
        -Version $Version `
        -Commit ("5" * 40) `
        -RegistryPrefix $registry `
        -Digest $Digest

    # Round-tripped through JSON so the tests see exactly what the validator
    # reads off disk, not the ordered hashtable that was written.
    return ($lock | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
}

# --- Image references --------------------------------------------------------

$tagged = ConvertFrom-ImageReference -Reference "$registry/query-service:sha-5f5e845"
Assert-Equal -What "a tagged reference keeps its repository" -Expected "me-massine/pulsestream/query-service" -Actual $tagged.Repository
Assert-Equal -What "a tagged reference keeps its registry" -Expected "ghcr.io" -Actual $tagged.Registry
Assert-Equal -What "a tagged reference exposes the service name" -Expected "query-service" -Actual $tagged.Name
Assert-Equal -What "a tagged reference keeps its tag" -Expected "sha-5f5e845" -Actual $tagged.Tag
Assert-True -What "a sha-<short> tag is not mutable" -Condition (-not $tagged.IsMutable)
Assert-True -What "a sha-<short> tag is not digest-pinned" -Condition (-not $tagged.IsPinned)

$both = ConvertFrom-ImageReference -Reference "$registry/query-service:v0.7.0@$digestA"
Assert-Equal -What "a tag+digest reference keeps the tag" -Expected "v0.7.0" -Actual $both.Tag
Assert-Equal -What "a tag+digest reference keeps the digest" -Expected $digestA -Actual $both.Digest
Assert-True -What "a tag+digest reference is pinned" -Condition $both.IsPinned

$digestOnly = ConvertFrom-ImageReference -Reference "$registry/query-service@$digestA"
Assert-True -What "a digest-only reference has no tag" -Condition ($null -eq $digestOnly.Tag)
Assert-True -What "a digest-only reference is pinned" -Condition $digestOnly.IsPinned

Assert-True -What "an explicit :latest is mutable" -Condition (ConvertFrom-ImageReference -Reference "$registry/query-service:latest").IsMutable
Assert-True -What "an untagged reference is mutable, because it resolves to latest" -Condition (ConvertFrom-ImageReference -Reference "$registry/query-service").IsMutable
Assert-True -What "a digest-pinned :latest is not mutable" -Condition (-not (ConvertFrom-ImageReference -Reference "$registry/query-service:latest@$digestA").IsMutable)

# A registry port is a colon that is not a tag separator.
$ported = ConvertFrom-ImageReference -Reference "localhost:5000/pulsestream/query-service:local"
Assert-Equal -What "a registry port is not read as a tag" -Expected "local" -Actual $ported.Tag
Assert-Equal -What "a registry port stays with the registry" -Expected "localhost:5000" -Actual $ported.Registry

# The local build names used by validate-container-images.ps1 have no registry.
$local = ConvertFrom-ImageReference -Reference "pulsestream/telemetry-processor:local"
Assert-True -What "a reference with no registry host reports none" -Condition ($null -eq $local.Registry)
Assert-Equal -What "a reference with no registry keeps the whole path as the repository" -Expected "pulsestream/telemetry-processor" -Actual $local.Repository

Assert-Throws -What "a truncated digest is rejected" -ExpectedMessage "not a sha256" -Script {
    ConvertFrom-ImageReference -Reference "$registry/query-service@sha256:abc"
}
Assert-Throws -What "an empty tag is rejected" -ExpectedMessage "empty tag" -Script {
    ConvertFrom-ImageReference -Reference "$registry/query-service:"
}
Assert-Throws -What "a reference to nothing but a digest is rejected" -ExpectedMessage "no repository" -Script {
    ConvertFrom-ImageReference -Reference "@$digestA"
}

Assert-Equal -What "a pinned reference is rebuilt as repository:tag@digest" `
    -Expected "$registry/query-service:v0.7.0@$digestA" `
    -Actual (ConvertTo-ImageReference -Repository "$registry/query-service" -Tag "v0.7.0" -Digest $digestA)
Assert-Throws -What "rebuilding a reference with neither tag nor digest is rejected" -ExpectedMessage "at least a tag or a digest" -Script {
    ConvertTo-ImageReference -Repository "$registry/query-service"
}

# --- Version tags ------------------------------------------------------------

$release = Test-SemanticVersionTag -Tag "v1.2.0"
Assert-True -What "v1.2.0 is a version tag" -Condition $release.IsValid
Assert-Equal -What "v1.2.0 is on the release channel" -Expected "release" -Actual $release.Channel

$candidate = Test-SemanticVersionTag -Tag "v1.2.0-rc.3"
Assert-True -What "v1.2.0-rc.3 is a version tag" -Condition $candidate.IsValid
Assert-Equal -What "v1.2.0-rc.3 is on the candidate channel" -Expected "candidate" -Actual $candidate.Channel
Assert-Equal -What "v1.2.0-rc.3 carries its candidate number" -Expected 3 -Actual $candidate.Candidate
Assert-Equal -What "v1.2.0-rc.3 names the release it is a candidate for" -Expected "v1.2.0" -Actual $candidate.BaseTag

foreach ($bad in @("1.2.0", "v1.2", "v1.2.0.1", "latest", "v1.2.0-rc", "v1.2.0-rc.0", "v1.2.0-beta.1", "v01.2.0", "sha-5f5e845", "")) {
    Assert-True -What "'$bad' is not a version tag" -Condition (-not (Test-SemanticVersionTag -Tag $bad).IsValid)
}

Assert-Equal -What "the per-commit tag is the first 7 characters" -Expected "sha-5f5e845" -Actual (Get-SourceCommitTag -Commit "5f5e8450786ad00ea52b9010d44858431557048c")
Assert-Throws -What "a non-hex commit has no build tag" -ExpectedMessage "not a hexadecimal" -Script { Get-SourceCommitTag -Commit "main" }

# --- One commit, one digest --------------------------------------------------

$consistentMap = Test-SourceCommitDigestMap -Record @(
    [pscustomobject]@{ Service = "query-service"; Commit = "5f5e845"; Digest = $digestA },
    [pscustomobject]@{ Service = "query-service"; Commit = "5f5e845"; Digest = $digestA }
)
Assert-True -What "the same commit reported twice with the same digest is consistent" -Condition $consistentMap.Ok

$rebuiltMap = Test-SourceCommitDigestMap -Record @(
    [pscustomobject]@{ Service = "query-service"; Commit = "5f5e845"; Digest = $digestA },
    [pscustomobject]@{ Service = "query-service"; Commit = "5f5e845"; Digest = $digestB }
)
Assert-True -What "a commit that maps to two digests is rejected" -Condition (-not $rebuiltMap.Ok)
Assert-True -What "the two-digest report names the repointed tag" -Condition (($rebuiltMap.Problems -join " ") -match "repointed by a rebuild")

Assert-True -What "a digest that is not a sha256 is rejected" -Condition (
    -not (Test-SourceCommitDigestMap -Record @([pscustomobject]@{ Service = "x"; Commit = "abc1234"; Digest = "latest" })).Ok
)

Assert-Throws -What "a promotion that changed the image is rejected" -ExpectedMessage "never rebuild it" -Script {
    Assert-PromotedDigest -Service "query-service" -SourceDigest $digestA -PromotedDigest $digestB
}
Assert-PromotedDigest -Service "query-service" -SourceDigest $digestA -PromotedDigest $digestA
Write-Host "[ok] a promotion that kept the digest is accepted"

# --- Promotion gates ---------------------------------------------------------

$required = @("CI", "Security")

$allGreen = Test-PromotionGate -Required $required -Gate @(
    [pscustomobject]@{ Name = "CI"; Status = "completed"; Conclusion = "success" },
    [pscustomobject]@{ Name = "Security"; Status = "completed"; Conclusion = "success" },
    [pscustomobject]@{ Name = "Optional"; Status = "completed"; Conclusion = "failure" }
)
Assert-True -What "every required check green promotes, and an unrequired failure does not block" -Condition $allGreen.Ok

$missing = Test-PromotionGate -Required $required -Gate @(
    [pscustomobject]@{ Name = "CI"; Status = "completed"; Conclusion = "success" }
)
Assert-True -What "a required check with no result blocks promotion" -Condition (-not $missing.Ok)
Assert-True -What "the missing-check report says it never ran" -Condition (($missing.Blocking -join " ") -match "never ran")

$failing = Test-PromotionGate -Required $required -Gate @(
    [pscustomobject]@{ Name = "CI"; Status = "completed"; Conclusion = "failure" },
    [pscustomobject]@{ Name = "Security"; Status = "completed"; Conclusion = "success" }
)
Assert-True -What "a failing required check blocks promotion" -Condition (-not $failing.Ok)

$running = Test-PromotionGate -Required $required -Gate @(
    [pscustomobject]@{ Name = "CI"; Status = "in_progress"; Conclusion = $null },
    [pscustomobject]@{ Name = "Security"; Status = "completed"; Conclusion = "success" }
)
Assert-True -What "a required check still running blocks promotion" -Condition (-not $running.Ok)

$skipped = Test-PromotionGate -Required $required -Gate @(
    [pscustomobject]@{ Name = "CI"; Status = "completed"; Conclusion = "skipped" },
    [pscustomobject]@{ Name = "Security"; Status = "completed"; Conclusion = "success" }
)
Assert-True -What "a required check that was skipped blocks promotion" -Condition (-not $skipped.Ok)

# A re-run leaves two results for one check. The green one must not retire the
# red one - that is how a failing gate becomes invisible.
$mixed = Test-PromotionGate -Required $required -Gate @(
    [pscustomobject]@{ Name = "CI"; Status = "completed"; Conclusion = "success" },
    [pscustomobject]@{ Name = "CI"; Status = "completed"; Conclusion = "failure" },
    [pscustomobject]@{ Name = "Security"; Status = "completed"; Conclusion = "success" }
)
Assert-True -What "a green re-run does not hide a failing run of the same check" -Condition (-not $mixed.Ok)

# --- Manifest consistency, before any release exists -------------------------

$sameCommit = @(
    New-ImageRecord -Service "ingestion-service" -Reference "$registry/ingestion-service:sha-5f5e845"
    New-ImageRecord -Service "telemetry-processor" -Reference "$registry/telemetry-processor:sha-5f5e845"
    New-ImageRecord -Service "query-service" -Reference "$registry/query-service:sha-5f5e845"
)
$result = Test-ReleaseManifestConsistency -ManifestImage $sameCommit -RegistryPrefix $registry -ExpectedService $services -Lock $null
Assert-True -What "one build tag across every service is consistent" -Condition $result.Ok

$splitCommit = @(
    New-ImageRecord -Service "ingestion-service" -Reference "$registry/ingestion-service:sha-5f5e845"
    New-ImageRecord -Service "telemetry-processor" -Reference "$registry/telemetry-processor:sha-a0ab2f8"
    New-ImageRecord -Service "query-service" -Reference "$registry/query-service:sha-5f5e845"
)
$result = Test-ReleaseManifestConsistency -ManifestImage $splitCommit -RegistryPrefix $registry -ExpectedService $services -Lock $null
Assert-True -What "services pinned to different commits are rejected" -Condition (-not $result.Ok)
Assert-True -What "the split-commit report names both commits" -Condition (($result.Problems -join " ") -match "telemetry-processor=sha-a0ab2f8")

$mutable = @(
    New-ImageRecord -Service "ingestion-service" -Reference "$registry/ingestion-service:latest"
    New-ImageRecord -Service "telemetry-processor" -Reference "$registry/telemetry-processor:sha-5f5e845"
    New-ImageRecord -Service "query-service" -Reference "$registry/query-service:sha-5f5e845"
)
$result = Test-ReleaseManifestConsistency -ManifestImage $mutable -RegistryPrefix $registry -ExpectedService $services -Lock $null
Assert-True -What "a manifest on :latest is rejected" -Condition (-not $result.Ok)
Assert-True -What "the :latest report explains that the tag can be repointed" -Condition (($result.Problems -join " ") -match "can be repointed")

$untagged = @(
    New-ImageRecord -Service "ingestion-service" -Reference "$registry/ingestion-service"
    New-ImageRecord -Service "telemetry-processor" -Reference "$registry/telemetry-processor:sha-5f5e845"
    New-ImageRecord -Service "query-service" -Reference "$registry/query-service:sha-5f5e845"
)
Assert-True -What "a manifest with no tag at all is rejected" -Condition (
    -not (Test-ReleaseManifestConsistency -ManifestImage $untagged -RegistryPrefix $registry -ExpectedService $services -Lock $null).Ok
)

$missingService = @(
    New-ImageRecord -Service "ingestion-service" -Reference "$registry/ingestion-service:sha-5f5e845"
    New-ImageRecord -Service "telemetry-processor" -Reference "$registry/telemetry-processor:sha-5f5e845"
)
$result = Test-ReleaseManifestConsistency -ManifestImage $missingService -RegistryPrefix $registry -ExpectedService $services -Lock $null
Assert-True -What "a service no manifest deploys is reported" -Condition (-not $result.Ok)
Assert-True -What "the missing-service report names the service" -Condition (($result.Problems -join " ") -match "no Deployment manifest references the 'query-service' image")

# A digest names bytes, not a commit. Without a lock nothing maps it back to
# source, which is the traceability the release lock exists to provide.
$unattributedDigest = @(
    New-ImageRecord -Service "ingestion-service" -Reference "$registry/ingestion-service@$digestA"
    New-ImageRecord -Service "telemetry-processor" -Reference "$registry/telemetry-processor:sha-5f5e845"
    New-ImageRecord -Service "query-service" -Reference "$registry/query-service:sha-5f5e845"
)
$result = Test-ReleaseManifestConsistency -ManifestImage $unattributedDigest -RegistryPrefix $registry -ExpectedService $services -Lock $null
Assert-True -What "a digest with no release lock behind it is rejected" -Condition (-not $result.Ok)
Assert-True -What "the unattributed-digest report says no lock records the commit" -Condition (($result.Problems -join " ") -match "no release lock records which commit")

$unknownService = @(
    New-ImageRecord -Service "ingestion-service" -Reference "$registry/ingestion-service:sha-5f5e845"
    New-ImageRecord -Service "telemetry-processor" -Reference "$registry/telemetry-processor:sha-5f5e845"
    New-ImageRecord -Service "query-service" -Reference "$registry/query-service:sha-5f5e845"
    New-ImageRecord -Service "retired-service" -Reference "$registry/retired-service:sha-5f5e845"
)
Assert-True -What "a platform image for an unknown service is rejected" -Condition (
    -not (Test-ReleaseManifestConsistency -ManifestImage $unknownService -RegistryPrefix $registry -ExpectedService $services -Lock $null).Ok
)

# Third-party images are pinned by their own manifests and are not this
# workflow's to promote.
$withThirdParty = @($sameCommit) + @(
    New-ImageRecord -Service "grafana" -Reference "grafana/grafana:13.1.3@sha256:$('d' * 64)" -File "infrastructure/kubernetes/monitoring/grafana/deployment.yaml"
    New-ImageRecord -Service "jaeger" -Reference "jaegertracing/all-in-one:1.60" -File "infrastructure/kubernetes/observability/jaeger-deployment.yaml"
)
Assert-True -What "third-party images are left to their own manifests" -Condition (
    (Test-ReleaseManifestConsistency -ManifestImage $withThirdParty -RegistryPrefix $registry -ExpectedService $services -Lock $null).Ok
)

# --- Manifest consistency, against a release lock ---------------------------

$lock = New-TestLock
Assert-Equal -What "a release lock records the release state" -Expected "release" -Actual $lock.state
Assert-Equal -What "a release lock records the build tag the digest came from" -Expected "sha-5555555" -Actual $lock.images.'query-service'.sourceTag

$released = @(
    New-ImageRecord -Service "ingestion-service" -Reference "$registry/ingestion-service:v0.7.0@$digestA"
    New-ImageRecord -Service "telemetry-processor" -Reference "$registry/telemetry-processor:v0.7.0@$digestB"
    New-ImageRecord -Service "query-service" -Reference "$registry/query-service:v0.7.0@$digestC"
)
Assert-True -What "manifests pinned to the locked digests are consistent" -Condition (
    (Test-ReleaseManifestConsistency -ManifestImage $released -RegistryPrefix $registry -ExpectedService $services -Lock $lock).Ok
)

$stale = @(
    New-ImageRecord -Service "ingestion-service" -Reference "$registry/ingestion-service:v0.7.0@$digestA"
    New-ImageRecord -Service "telemetry-processor" -Reference "$registry/telemetry-processor:v0.7.0@$digestB"
    New-ImageRecord -Service "query-service" -Reference "$registry/query-service:v0.7.0@sha256:$('9' * 64)"
)
$result = Test-ReleaseManifestConsistency -ManifestImage $stale -RegistryPrefix $registry -ExpectedService $services -Lock $lock
Assert-True -What "a manifest left on the previous digest is rejected" -Condition (-not $result.Ok)
Assert-True -What "the stale-digest report says the manifest is stale" -Condition (($result.Problems -join " ") -match "The manifest is stale")

$tagOnlyUnderLock = @(
    New-ImageRecord -Service "ingestion-service" -Reference "$registry/ingestion-service:v0.7.0"
    New-ImageRecord -Service "telemetry-processor" -Reference "$registry/telemetry-processor:v0.7.0@$digestB"
    New-ImageRecord -Service "query-service" -Reference "$registry/query-service:v0.7.0@$digestC"
)
$result = Test-ReleaseManifestConsistency -ManifestImage $tagOnlyUnderLock -RegistryPrefix $registry -ExpectedService $services -Lock $lock
Assert-True -What "a released manifest that is not digest-pinned is rejected" -Condition (-not $result.Ok)
Assert-True -What "the tag-only report demands the digest" -Condition (($result.Problems -join " ") -match "not pinned by digest")

$wrongTag = @(
    New-ImageRecord -Service "ingestion-service" -Reference "$registry/ingestion-service:v0.6.0@$digestA"
    New-ImageRecord -Service "telemetry-processor" -Reference "$registry/telemetry-processor:v0.7.0@$digestB"
    New-ImageRecord -Service "query-service" -Reference "$registry/query-service:v0.7.0@$digestC"
)
$result = Test-ReleaseManifestConsistency -ManifestImage $wrongTag -RegistryPrefix $registry -ExpectedService $services -Lock $lock
Assert-True -What "a digest that is right under a tag from another release is rejected" -Condition (-not $result.Ok)
Assert-True -What "the wrong-tag report says the tag and digest disagree" -Condition (($result.Problems -join " ") -match "disagree about which release")

$partialLock = New-TestLock -Digest @{ "ingestion-service" = $digestA; "query-service" = $digestC }
$result = Test-ReleaseManifestConsistency -ManifestImage $released -RegistryPrefix $registry -ExpectedService $services -Lock $partialLock
Assert-True -What "a lock missing a service cannot release the manifest set" -Condition (-not $result.Ok)
Assert-True -What "the partial-lock report names the unreleased service" -Condition (($result.Problems -join " ") -match "records no image for 'telemetry-processor'")

# --- Release lock construction ----------------------------------------------

$candidateLock = New-TestLock -Version "v0.7.0-rc.1"
Assert-Equal -What "a candidate lock records the candidate state" -Expected "candidate" -Actual $candidateLock.state
Assert-Equal -What "a lock builds the full pinned reference" `
    -Expected "$registry/ingestion-service:v0.7.0-rc.1@$digestA" `
    -Actual $candidateLock.images.'ingestion-service'.reference

Assert-Throws -What "a lock cannot be written for a short commit" -ExpectedMessage "full 40-character" -Script {
    New-ReleaseLock -Version "v0.7.0" -Commit "5f5e845" -RegistryPrefix $registry -Digest @{ "query-service" = $digestA }
}
Assert-Throws -What "a lock cannot be written for a tag that is not a version" -ExpectedMessage "not a PulseStream version tag" -Script {
    New-ReleaseLock -Version "latest" -Commit ("5" * 40) -RegistryPrefix $registry -Digest @{ "query-service" = $digestA }
}
Assert-Throws -What "a lock cannot record a tag in place of a digest" -ExpectedMessage "not a sha256" -Script {
    New-ReleaseLock -Version "v0.7.0" -Commit ("5" * 40) -RegistryPrefix $registry -Digest @{ "query-service" = "sha-5f5e845" }
}
Assert-Throws -What "a lock with no images is rejected" -ExpectedMessage "at least one service digest" -Script {
    New-ReleaseLock -Version "v0.7.0" -Commit ("5" * 40) -RegistryPrefix $registry -Digest @{}
}

# --- Release notes -----------------------------------------------------------

$notes = New-ReleaseNotes -Version "v0.7.0" -SourceCommit ("5" * 40) -PreviousVersion "v0.6.0" -RepositoryUrl "https://github.com/ME-Massine/pulsestream" -Commit @(
    [pscustomobject]@{ Sha = "1111111"; Subject = "feat(kubernetes): deploy Jaeger tracing backend (#158) (#289)" },
    [pscustomobject]@{ Sha = "2222222"; Subject = "fix(observability): assert the stack per pod (#159)" },
    [pscustomobject]@{ Sha = "3333333"; Subject = "feat(api)!: drop the v0 ingest endpoint (#300)" },
    [pscustomobject]@{ Sha = "4444444"; Subject = "chore: bump the base image" },
    [pscustomobject]@{ Sha = "5555555"; Subject = "Merge pull request #301 from feature/x" }
)

Assert-True -What "release notes group features" -Condition ($notes.Markdown -match "## Features")
Assert-True -What "release notes group fixes" -Condition ($notes.Markdown -match "## Fixes")
Assert-True -What "release notes call out breaking changes" -Condition ($notes.Markdown -match "## Breaking changes")
Assert-True -What "release notes keep the conventional-commit scope" -Condition ($notes.Markdown -match "\*\*kubernetes\*\*")
Assert-True -What "release notes link every issue a commit references" -Condition ($notes.Markdown -match "\[#158\]\(https://github.com/ME-Massine/pulsestream/issues/158\)")
Assert-True -What "release notes name the source commit" -Condition ($notes.Markdown -match ("5" * 40))
Assert-True -What "release notes say what they are measured from" -Condition ($notes.Markdown -match "Changes since v0.6.0")
Assert-True -What "a merge commit is not a release note" -Condition ($notes.Markdown -notmatch "Merge pull request")
Assert-Equal -What "every referenced issue is collected" -Expected 4 -Actual $notes.Issues.Count
Assert-Equal -What "a commit with no issue reference is reported, not dropped" -Expected 1 -Actual $notes.Unreferenced.Count
Assert-Equal -What "the unreferenced commit is the one with no issue" -Expected "chore: bump the base image" -Actual $notes.Unreferenced[0].Subject

# --- Rewriting a manifest image reference -----------------------------------

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("pulsestream-release-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

try {
    $manifestPath = Join-Path $scratch "deployment.yaml"
    $manifestText = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: query-service
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: query-service
  template:
    metadata:
      labels:
        app.kubernetes.io/name: query-service
    spec:
      containers:
        # Bump this to roll out a different build.
        - name: query-service
          image: $registry/query-service:sha-5f5e845
          imagePullPolicy: IfNotPresent
        - name: sidecar
          image: $registry/ingestion-service:sha-5f5e845
"@
    [System.IO.File]::WriteAllText($manifestPath, ($manifestText -replace "`r`n", "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

    $updated = Set-ManifestImageReference -Path $manifestPath -Repository "$registry/query-service" -NewReference "$registry/query-service:v0.7.0@$digestC"
    Assert-Equal -What "exactly the matching container is repinned" -Expected 1 -Actual $updated

    $rewritten = Get-Content -LiteralPath $manifestPath -Raw
    Assert-True -What "the repinned reference is written" -Condition ($rewritten -match [regex]::Escape("image: $registry/query-service:v0.7.0@$digestC"))
    Assert-True -What "a container for another repository is left alone" -Condition ($rewritten -match [regex]::Escape("image: $registry/ingestion-service:sha-5f5e845"))
    Assert-True -What "the comments explaining the manifest survive the rewrite" -Condition ($rewritten -match "Bump this to roll out a different build")

    Assert-Throws -What "repinning a repository the manifest does not use is rejected" -ExpectedMessage "no image reference for repository" -Script {
        Set-ManifestImageReference -Path $manifestPath -Repository "$registry/absent-service" -NewReference "$registry/absent-service:v0.7.0@$digestA"
    }
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

# --- End to end: promote a copy of the real manifests, then validate them ----

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("pulsestream-promote-" + [guid]::NewGuid().ToString("N"))

$promote = (Resolve-Path (Join-Path $PSScriptRoot "..\promote-release-manifests.ps1")).Path
$validate = (Resolve-Path (Join-Path $PSScriptRoot "..\validate-release-manifests.ps1")).Path

# Both scripts are run in-process rather than through a new pwsh, so this test
# exercises whichever edition is running it - the promotion path has to behave
# the same under Windows PowerShell 5.1 and pwsh 7.
function Invoke-Script {
    param([string] $Path, [hashtable] $Argument)

    try {
        & $Path @Argument | Out-Null
        return [pscustomobject]@{ Ok = $true; Message = $null }
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message }
    }
}

try {
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    foreach ($service in $services) {
        Copy-Item -Path (Join-Path $repoRoot "infrastructure\kubernetes\$service") -Destination (Join-Path $scratch $service) -Recurse -Force
    }

    # A commit that exists, so the notes step has a real range to read.
    $head = (& git -C $repoRoot rev-parse HEAD).Trim()

    $promoted = Invoke-Script -Path $promote -Argument @{
        Version      = "v0.7.0-rc.1"
        Commit       = $head
        ImageDigest  = @("ingestion-service=$digestA", "telemetry-processor=$digestB", "query-service=$digestC")
        ManifestRoot = $scratch
    }
    Assert-True -What "promoting a copy of the real manifests succeeds" -Condition $promoted.Ok
    if (-not $promoted.Ok) { Write-Host "       $($promoted.Message)" }

    $lockPath = Join-Path $scratch "releases\v0.7.0-rc.1\images.lock.json"
    Assert-True -What "the promotion writes a release lock" -Condition (Test-Path -LiteralPath $lockPath)
    Assert-True -What "the promotion writes release notes" -Condition (Test-Path -LiteralPath (Join-Path $scratch "releases\v0.7.0-rc.1\release-notes.md"))

    if (Test-Path -LiteralPath $lockPath) {
        $written = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        Assert-Equal -What "the lock records the commit that was promoted" -Expected $head -Actual $written.commit
        Assert-Equal -What "the lock records the build tag the digests were resolved from" -Expected (Get-SourceCommitTag -Commit $head) -Actual $written.promotedFrom
        Assert-Equal -What "a candidate promotion is recorded as a candidate" -Expected "candidate" -Actual $written.state
    }

    $deployment = Get-Content -LiteralPath (Join-Path $scratch "query-service\deployment.yaml") -Raw
    Assert-True -What "the promoted manifest is digest-pinned" -Condition ($deployment -match [regex]::Escape("@$digestC"))
    Assert-True -What "the promoted manifest keeps the comment explaining its image pin" -Condition ($deployment -match "container-image-registry.md")

    $accepted = Invoke-Script -Path $validate -Argument @{ ManifestRoot = $scratch }
    Assert-True -What "the CI validator accepts a freshly promoted manifest set" -Condition $accepted.Ok
    if (-not $accepted.Ok) { Write-Host "       $($accepted.Message)" }

    # Now the failure the check exists for: one service left on a digest this
    # release did not promote, while the lock says otherwise.
    Set-ManifestImageReference `
        -Path (Join-Path $scratch "query-service\deployment.yaml") `
        -Repository "$registry/query-service" `
        -NewReference "$registry/query-service:v0.7.0-rc.1@sha256:$('9' * 64)" | Out-Null

    $rejected = Invoke-Script -Path $validate -Argument @{ ManifestRoot = $scratch }
    Assert-True -What "the CI validator rejects a manifest left on a digest the release did not promote" -Condition (-not $rejected.Ok)

    # A release is a fixed set of digests, so the same version cannot be
    # promoted a second time with different contents.
    $repromoted = Invoke-Script -Path $promote -Argument @{
        Version      = "v0.7.0-rc.1"
        Commit       = $head
        ImageDigest  = @("ingestion-service=$digestB", "telemetry-processor=$digestB", "query-service=$digestC")
        ManifestRoot = $scratch
    }
    Assert-True -What "promoting an existing version again is refused" -Condition (-not $repromoted.Ok)

    # A partial digest set would pin some services to the release and leave the
    # rest wherever they were.
    $partial = Invoke-Script -Path $promote -Argument @{
        Version      = "v0.7.0-rc.2"
        Commit       = $head
        ImageDigest  = @("ingestion-service=$digestA", "query-service=$digestC")
        ManifestRoot = $scratch
    }
    Assert-True -What "a promotion missing a service digest is refused" -Condition (-not $partial.Ok)
    Assert-True -What "the partial-promotion message explains why" -Condition ($partial.Message -match "pins every service or none")
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    throw "$script:Failures release promotion check(s) failed."
}

Write-Host "[ok] Release and image promotion rules behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
