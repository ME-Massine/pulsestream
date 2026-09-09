# Release and container image promotion rules (#264).
#
# Images are published per main commit and Kubernetes manifests are edited by
# hand, so a manifest can name an image built before the probes and ConfigMap
# keys that same manifest declares. The promotion workflow closes that by making
# one artifact - an image digest - the thing that moves from development to
# release candidate to release, and by making the manifests reference that
# digest rather than a tag that can be repointed.
#
# Everything here is pure: it takes manifest text, a release lock, a list of
# check-run results or a list of commits, and returns a verdict. It opens no
# socket, runs no docker, and reads no cluster. That is what lets
# scripts/tests/test-release-promotion.ps1 drive the cases that matter - a
# rebuilt digest, a gate that never ran, two services pinned to different
# commits - none of which can be produced on demand against a real registry.
#
# scripts/validate-release-manifests.ps1 is the CI half (reads the committed
# manifests) and scripts/promote-release-manifests.ps1 is the promotion half
# (writes the lock and rewrites the image references). Both are thin over this.

# ConvertFrom-KubernetesYaml reads the committed manifests without a cluster.
# Imported without -Force: -Force would unload the copy a calling script had
# already imported for its own use.
Import-Module (Join-Path $PSScriptRoot "PulseStreamYaml.psm1")

# The three states an artifact can be in. A state is a property of a digest, not
# of a rebuild: the same digest carries different tags as it moves.
$script:ArtifactStates = @("development", "candidate", "release")

# --- Image references --------------------------------------------------------

# Splits `ghcr.io/owner/pulsestream/query-service:v1.2.0@sha256:<hex>` into its
# parts. Both the tag and the digest are optional and a reference may carry
# both, which is the form release manifests use: the tag documents which release
# this is, the digest is what Kubernetes actually resolves.
#
# The registry may carry a port (`localhost:5000/x`), so the tag separator is
# looked for only in the final path segment - splitting on the first colon would
# read `5000/x` as a tag.
function ConvertFrom-ImageReference {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Reference)

    $text = $Reference.Trim()
    if ($text.Length -eq 0) {
        throw "Image reference is empty."
    }

    $digest = $null
    $atIndex = $text.IndexOf('@')
    if ($atIndex -ge 0) {
        $digest = $text.Substring($atIndex + 1)
        $text = $text.Substring(0, $atIndex)

        if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
            throw "Image reference '$Reference' has a digest that is not a sha256:<64 hex> value."
        }
        if ($text.Length -eq 0) {
            throw "Image reference '$Reference' has a digest but no repository."
        }
    }

    $tag = $null
    $lastSlash = $text.LastIndexOf('/')
    $finalSegment = $text.Substring($lastSlash + 1)
    $colonIndex = $finalSegment.LastIndexOf(':')
    if ($colonIndex -ge 0) {
        $tag = $finalSegment.Substring($colonIndex + 1)
        $text = $text.Substring(0, $lastSlash + 1 + $colonIndex)

        if ($tag.Length -eq 0) {
            throw "Image reference '$Reference' has an empty tag."
        }
    }

    if ($text.Length -eq 0) {
        throw "Image reference '$Reference' has no repository."
    }

    # A registry is the first segment only when it looks like a host: it carries
    # a dot, a colon, or is literally `localhost`. `pulsestream/query-service`
    # has no registry, which is how the locally built images are named.
    $registry = $null
    $repository = $text
    $firstSlash = $text.IndexOf('/')
    if ($firstSlash -gt 0) {
        $candidate = $text.Substring(0, $firstSlash)
        if ($candidate -eq "localhost" -or $candidate.Contains(".") -or $candidate.Contains(":")) {
            $registry = $candidate
            $repository = $text.Substring($firstSlash + 1)
        }
    }

    return [pscustomobject]@{
        Reference  = $Reference.Trim()
        Registry   = $registry
        Repository = $repository
        # Repository without the registry-qualified prefix, i.e. the service.
        Name       = $repository.Substring($repository.LastIndexOf('/') + 1)
        Tag        = $tag
        Digest     = $digest
        # `image: repo` with no tag resolves to `latest` at pull time. It is
        # mutable for the same reason an explicit `latest` is.
        IsMutable  = ($null -eq $digest) -and ($null -eq $tag -or $tag -eq "latest")
        IsPinned   = $null -ne $digest
    }
}

# Rebuilds a reference from parts, so the promotion rewrite produces exactly one
# spelling of a pinned image: repository:tag@digest.
function ConvertTo-ImageReference {
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [string] $Tag,
        [string] $Digest
    )

    if ([string]::IsNullOrWhiteSpace($Tag) -and [string]::IsNullOrWhiteSpace($Digest)) {
        throw "An image reference needs at least a tag or a digest."
    }
    if (-not [string]::IsNullOrWhiteSpace($Digest) -and $Digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "Digest '$Digest' is not a sha256:<64 hex> value."
    }

    $reference = $Repository
    if (-not [string]::IsNullOrWhiteSpace($Tag)) {
        $reference = "$reference`:$Tag"
    }
    if (-not [string]::IsNullOrWhiteSpace($Digest)) {
        $reference = "$reference@$Digest"
    }
    return $reference
}

# --- Version tags ------------------------------------------------------------

# The version tag conventions. `v<major>.<minor>.<patch>` is a release,
# `v<major>.<minor>.<patch>-rc.<n>` is a release candidate for that same
# version, and nothing else is a version.
#
# The candidate suffix is not cosmetic: the promotion workflow reads the channel
# back off the tag to decide whether it may write a release manifest set, so a
# tag that does not say which it is has to be rejected rather than guessed.
function Test-SemanticVersionTag {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Tag)

    $result = [pscustomobject]@{
        Tag        = $Tag
        IsValid    = $false
        Major      = $null
        Minor      = $null
        Patch      = $null
        Candidate  = $null
        Channel    = $null
        BaseTag    = $null
        Reason     = $null
    }

    $match = [regex]::Match($Tag, '^v(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)(?:-rc\.(?<rc>[1-9][0-9]*))?$')
    if (-not $match.Success) {
        $result.Reason = "'$Tag' is not a PulseStream version tag. Expected v<major>.<minor>.<patch> for a release or v<major>.<minor>.<patch>-rc.<n> for a candidate."
        return $result
    }

    $result.IsValid = $true
    $result.Major = [int] $match.Groups['major'].Value
    $result.Minor = [int] $match.Groups['minor'].Value
    $result.Patch = [int] $match.Groups['patch'].Value
    $result.BaseTag = "v$($result.Major).$($result.Minor).$($result.Patch)"

    if ($match.Groups['rc'].Success) {
        $result.Candidate = [int] $match.Groups['rc'].Value
        $result.Channel = "candidate"
    } else {
        $result.Channel = "release"
    }

    return $result
}

# The immutable per-commit tag publish-images.yml applies to every build. This
# is the only tag promotion reads from, so its spelling lives in one place.
function Get-SourceCommitTag {
    param([Parameter(Mandatory)] [string] $Commit)

    if ($Commit -notmatch '^[0-9a-f]{7,40}$') {
        throw "Commit '$Commit' is not a hexadecimal git object name."
    }
    return "sha-$($Commit.Substring(0, 7))"
}

# --- Manifest image references ----------------------------------------------

# Every container image referenced by the committed Deployment manifests, with
# the file and container it came from so a problem can be reported at the place
# it has to be fixed.
function Get-ManifestImageReference {
    param([Parameter(Mandatory)] [string[]] $Path)

    $records = [System.Collections.Generic.List[object]]::new()

    foreach ($manifestPath in $Path) {
        $document = ConvertFrom-KubernetesYaml -Path $manifestPath

        $kind = if ($document.PSObject.Properties.Name -contains 'kind') { $document.kind } else { $null }
        if ($kind -ne "Deployment") {
            continue
        }

        $name = $document.metadata.name
        $containers = @($document.spec.template.spec.containers | Where-Object { $null -ne $_ })
        if ($containers.Count -eq 0) {
            throw "$manifestPath : Deployment '$name' declares no containers."
        }

        foreach ($container in $containers) {
            if ($container.PSObject.Properties.Name -notcontains 'image') {
                throw "$manifestPath : container '$($container.name)' in Deployment '$name' declares no image."
            }

            $records.Add([pscustomobject]@{
                File      = $manifestPath
                Workload  = $name
                Container = $container.name
                Image     = ConvertFrom-ImageReference -Reference ([string] $container.image)
            })
        }
    }

    return $records.ToArray()
}

# Rewrites the `image:` value of one container in a manifest file, in place, as
# text. The manifests carry the reasoning for their own settings in comments and
# a parse-and-reserialize round trip would drop all of it, so the single line is
# edited and everything else is left byte-for-byte alone.
#
# Matching is by repository, not by position: a manifest that gained a sidecar
# must not have the sidecar's image rewritten to the service's digest.
function Set-ManifestImageReference {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $NewReference
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Manifest '$Path' was not found."
    }

    $lines = @(Get-Content -LiteralPath $Path)
    $updated = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $match = [regex]::Match($lines[$i], '^(?<indent>\s*)image:\s*(?<value>\S+)\s*$')
        if (-not $match.Success) {
            continue
        }

        $current = ConvertFrom-ImageReference -Reference $match.Groups['value'].Value
        $currentRepository = if ($current.Registry) { "$($current.Registry)/$($current.Repository)" } else { $current.Repository }
        if ($currentRepository -ne $Repository) {
            continue
        }

        $lines[$i] = "$($match.Groups['indent'].Value)image: $NewReference"
        $updated++
    }

    if ($updated -eq 0) {
        throw "Manifest '$Path' has no image reference for repository '$Repository'."
    }

    # Manifests in this repository are LF with a trailing newline; Set-Content
    # would apply the platform default and show every line as changed on Windows.
    $text = ($lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path).Path, $text, (New-Object System.Text.UTF8Encoding($false)))

    return $updated
}

# --- Source commit to digest mapping ----------------------------------------

# "A source commit maps unambiguously to one immutable image digest per
# service": the per-commit tag must never be repointed. Rebuilding the same
# commit produces a different digest for the same tag - Java builds are not
# byte-reproducible - so the publish workflow reuses an existing tag rather than
# overwriting it, and this is the check that says whether it must.
#
# Records are @{ Service; Commit; Digest }.
function Test-SourceCommitDigestMap {
    # Not Mandatory: an empty set is a valid answer ("nothing was published"),
    # and ConvertFrom-Json returns nothing for an empty JSON array, which a
    # mandatory parameter would turn into a binding prompt rather than a verdict.
    param([AllowEmptyCollection()] $Record = @())

    $problems = [System.Collections.Generic.List[string]]::new()
    $seen = @{}

    foreach ($entry in @($Record)) {
        if ($entry.Digest -notmatch '^sha256:[0-9a-f]{64}$') {
            $problems.Add("$($entry.Service) at $($entry.Commit): '$($entry.Digest)' is not a sha256:<64 hex> digest.")
            continue
        }

        $key = "$($entry.Service)@$($entry.Commit)"
        if ($seen.ContainsKey($key)) {
            if ($seen[$key] -ne $entry.Digest) {
                $problems.Add("$($entry.Service) maps commit $($entry.Commit) to two digests: $($seen[$key]) and $($entry.Digest). The per-commit tag was repointed by a rebuild.")
            }
            continue
        }

        $seen[$key] = $entry.Digest
    }

    return [pscustomobject]@{
        Ok       = ($problems.Count -eq 0)
        Problems = $problems.ToArray()
    }
}

# The promoted tag must resolve to the digest it was created from. `imagetools
# create` copies a manifest rather than building one, so a mismatch here means
# something rebuilt between resolve and promote.
function Assert-PromotedDigest {
    param(
        [Parameter(Mandatory)] [string] $Service,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $SourceDigest,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $PromotedDigest
    )

    if ($SourceDigest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "$Service : source digest '$SourceDigest' is not a sha256:<64 hex> value."
    }
    if ($PromotedDigest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "$Service : promoted digest '$PromotedDigest' is not a sha256:<64 hex> value."
    }
    if ($SourceDigest -ne $PromotedDigest) {
        throw "$Service : promotion changed the image. Tested digest $SourceDigest, promoted digest $PromotedDigest. A promotion must re-tag the tested image, never rebuild it."
    }
}

# --- Promotion gates ---------------------------------------------------------

# Whether the checks that must pass for this commit actually passed.
#
# The failure this guards against is not a red check - that is visible - but a
# required check that produced no result at all: a workflow that was never
# triggered for the commit, or one still running when promotion started. Reading
# "no failures" off such a commit is how an untested image gets a release tag,
# so a required gate with no record blocks exactly like a failing one.
#
# Gates are @{ Name; Status; Conclusion }, as GitHub reports check runs.
function Test-PromotionGate {
    param(
        # Not Mandatory: a commit with no check runs at all is exactly the case
        # this has to block on, so it must be able to arrive here.
        [AllowEmptyCollection()] $Gate = @(),
        [Parameter(Mandatory)] [string[]] $Required
    )

    $blocking = [System.Collections.Generic.List[string]]::new()
    $satisfied = [System.Collections.Generic.List[string]]::new()

    $byName = @{}
    foreach ($entry in @($Gate)) {
        if ([string]::IsNullOrWhiteSpace($entry.Name)) {
            continue
        }
        # A check can report more than once for a commit (a re-run). The worst
        # result is the one that counts: a green re-run does not retire the fact
        # that the required check is currently failing on another run.
        if (-not $byName.ContainsKey($entry.Name) -or $entry.Conclusion -ne "success") {
            $byName[$entry.Name] = $entry
        }
    }

    foreach ($name in $Required) {
        if (-not $byName.ContainsKey($name)) {
            $blocking.Add("required check '$name' has no result for this commit (it never ran).")
            continue
        }

        $entry = $byName[$name]
        $status = if ($entry.PSObject.Properties.Name -contains 'Status') { $entry.Status } else { $null }
        if ($status -and $status -ne "completed") {
            $blocking.Add("required check '$name' is '$status', not completed.")
            continue
        }

        if ($entry.Conclusion -ne "success") {
            $conclusion = if ([string]::IsNullOrWhiteSpace($entry.Conclusion)) { "no conclusion" } else { $entry.Conclusion }
            $blocking.Add("required check '$name' concluded '$conclusion'.")
            continue
        }

        $satisfied.Add($name)
    }

    return [pscustomobject]@{
        Ok        = ($blocking.Count -eq 0)
        Blocking  = $blocking.ToArray()
        Satisfied = $satisfied.ToArray()
    }
}

# --- Release lock ------------------------------------------------------------

# The record a release is: which commit, which digest per service, which tags
# that digest now carries. It is what makes a deployed digest traceable back to
# source, and what the manifest consistency check compares the manifests to.
function New-ReleaseLock {
    param(
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $Commit,
        [Parameter(Mandatory)] [string] $RegistryPrefix,
        # service name -> sha256 digest
        [Parameter(Mandatory)] $Digest,
        [string] $PromotedFrom,
        [string] $PromotionRunUrl,
        [datetime] $CreatedUtc = [datetime]::UtcNow
    )

    # Not $version: PowerShell variable names are case-insensitive, so that
    # would overwrite the $Version parameter with the parse result.
    $parsed = Test-SemanticVersionTag -Tag $Version
    if (-not $parsed.IsValid) {
        throw $parsed.Reason
    }
    if ($Commit -notmatch '^[0-9a-f]{40}$') {
        throw "Release lock needs the full 40-character source commit, got '$Commit'."
    }

    $services = @($Digest.Keys | Sort-Object)
    if ($services.Count -eq 0) {
        throw "Release lock needs at least one service digest."
    }

    $images = [ordered]@{}
    foreach ($service in $services) {
        # Not $digest: that is the $Digest parameter under another casing, and
        # assigning it would replace the whole map with the first entry.
        $serviceDigest = [string] $Digest[$service]
        if ($serviceDigest -notmatch '^sha256:[0-9a-f]{64}$') {
            throw "Digest for '$service' is not a sha256:<64 hex> value, got '$serviceDigest'."
        }

        $repository = "$RegistryPrefix/$service"
        $images[$service] = [ordered]@{
            repository = $repository
            digest     = $serviceDigest
            tag        = $Version
            # The tag the image was tested under, kept so an operator holding
            # only the lock can find the build that produced the digest.
            sourceTag  = Get-SourceCommitTag -Commit $Commit
            reference  = ConvertTo-ImageReference -Repository $repository -Tag $Version -Digest $serviceDigest
        }
    }

    return [ordered]@{
        version      = $Version
        state        = if ($parsed.Channel -eq "candidate") { "candidate" } else { "release" }
        commit       = $Commit
        createdUtc   = $CreatedUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
        promotedFrom = $PromotedFrom
        promotionRun = $PromotionRunUrl
        images       = $images
    }
}

# --- Manifest consistency ----------------------------------------------------

# Compares what the manifests reference against what a release says they should,
# or - before any release exists - against the rules every reference must follow
# regardless.
#
# Without a lock the check is still meaningful, and catches the problem this
# workflow exists for: images published per commit while manifests are edited
# independently, leaving one service pinned to one commit and its neighbour to
# another. A digest with no lock is rejected rather than accepted, because a
# digest alone names no commit - the lock is the only thing that maps it back.
function Test-ReleaseManifestConsistency {
    param(
        [AllowEmptyCollection()] $ManifestImage = @(),
        [Parameter(Mandatory)] [string] $RegistryPrefix,
        [Parameter(Mandatory)] [string[]] $ExpectedService,
        $Lock
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $platform = [System.Collections.Generic.List[object]]::new()

    foreach ($record in @($ManifestImage)) {
        $image = $record.Image
        $repository = if ($image.Registry) { "$($image.Registry)/$($image.Repository)" } else { $image.Repository }
        if (-not $repository.StartsWith("$RegistryPrefix/")) {
            continue
        }

        $platform.Add([pscustomobject]@{
            Record     = $record
            Repository = $repository
            Service    = $image.Name
        })
    }

    $where = {
        param($entry)
        "$($entry.Record.File) (container '$($entry.Record.Container)')"
    }

    foreach ($entry in $platform) {
        $image = $entry.Record.Image

        if ($ExpectedService -notcontains $entry.Service) {
            $problems.Add("$(& $where $entry): references '$($entry.Repository)', which is not a known platform service.")
            continue
        }

        if ($image.IsMutable) {
            $tag = if ($image.Tag) { "'$($image.Tag)'" } else { "no tag, which resolves to 'latest'" }
            $problems.Add("$(& $where $entry): $($entry.Service) is pinned to $tag. A mutable tag can be repointed after the manifest was reviewed.")
        }
    }

    $seenServices = @($platform | ForEach-Object { $_.Service } | Sort-Object -Unique)
    foreach ($service in $ExpectedService) {
        if ($seenServices -notcontains $service) {
            $problems.Add("no Deployment manifest references the '$service' image. Its deployment cannot be traced to a build.")
        }
    }

    if ($null -eq $Lock) {
        # Pre-release: every service must be pinned to the same source commit
        # tag, since that tag is the only thing tying a manifest set together.
        $sourceTags = @{}

        foreach ($entry in $platform) {
            $image = $entry.Record.Image

            if ($image.IsPinned) {
                $problems.Add("$(& $where $entry): $($entry.Service) is pinned by digest, but no release lock records which commit that digest was built from.")
                continue
            }
            if ($image.IsMutable) {
                continue
            }

            $tag = $image.Tag
            if ($tag -match '^sha-[0-9a-f]{7}$') {
                $sourceTags[$tag] = $true
                continue
            }

            $version = Test-SemanticVersionTag -Tag $tag
            if (-not $version.IsValid) {
                $problems.Add("$(& $where $entry): $($entry.Service) is pinned to '$tag', which is neither a sha-<short> build tag nor a version tag.")
                continue
            }

            $problems.Add("$(& $where $entry): $($entry.Service) is pinned to version '$tag' but there is no release lock for it, so the digest behind that tag is unverified.")
        }

        if ($sourceTags.Keys.Count -gt 1) {
            $detail = @($platform |
                Where-Object { $_.Record.Image.Tag -match '^sha-[0-9a-f]{7}$' } |
                ForEach-Object { "$($_.Service)=$($_.Record.Image.Tag)" } |
                Sort-Object) -join ", "
            $problems.Add("deployment manifests reference $($sourceTags.Keys.Count) different source commits ($detail). A manifest set must deploy one commit, or the running services are not the ones tested together.")
        }

        return [pscustomobject]@{
            Ok            = ($problems.Count -eq 0)
            Problems      = $problems.ToArray()
            SourceCommits = @($sourceTags.Keys | Sort-Object)
            Lock          = $null
        }
    }

    # A lock exists: the manifests must reference exactly it.
    $lockServices = @($Lock.images.PSObject.Properties.Name | Sort-Object)
    foreach ($service in $ExpectedService) {
        if ($lockServices -notcontains $service) {
            $problems.Add("release $($Lock.version) records no image for '$service', so that service cannot be released with this manifest set.")
        }
    }
    foreach ($service in $lockServices) {
        if ($ExpectedService -notcontains $service) {
            $problems.Add("release $($Lock.version) records an image for '$service', which is not a known platform service.")
        }
    }

    foreach ($entry in $platform) {
        $image = $entry.Record.Image
        if ($lockServices -notcontains $entry.Service) {
            continue
        }

        $locked = $Lock.images.PSObject.Properties[$entry.Service].Value

        if (-not $image.IsPinned) {
            $problems.Add("$(& $where $entry): $($entry.Service) is not pinned by digest. Release $($Lock.version) expects $($locked.digest).")
            continue
        }
        if ($image.Digest -ne $locked.digest) {
            $problems.Add("$(& $where $entry): $($entry.Service) is pinned to $($image.Digest) but release $($Lock.version) promoted $($locked.digest). The manifest is stale.")
            continue
        }
        if ($entry.Repository -ne $locked.repository) {
            $problems.Add("$(& $where $entry): $($entry.Service) is pulled from '$($entry.Repository)' but release $($Lock.version) promoted '$($locked.repository)'.")
            continue
        }
        if ($image.Tag -and $image.Tag -ne $Lock.version) {
            $problems.Add("$(& $where $entry): $($entry.Service) carries tag '$($image.Tag)' but is part of release $($Lock.version). The tag and the digest disagree about which release this is.")
        }
    }

    return [pscustomobject]@{
        Ok            = ($problems.Count -eq 0)
        Problems      = $problems.ToArray()
        SourceCommits = @($Lock.commit)
        Lock          = $Lock
    }
}

# --- Release notes -----------------------------------------------------------

$script:NoteSections = [ordered]@{
    feat     = "Features"
    fix      = "Fixes"
    perf     = "Performance"
    refactor = "Refactoring"
    test     = "Tests"
    docs     = "Documentation"
    build    = "Build"
    ci       = "CI"
    chore    = "Chores"
}

# Release notes built from the commits between two releases.
#
# Every change in this repository lands through a PR that closes an issue (see
# .github/workflows/pr-issue-alignment.yml), so a commit subject with no issue
# reference is a change nobody can trace to a requirement. Those are returned
# separately rather than dropped, so the promotion workflow can refuse to
# publish notes that quietly omit part of the release.
#
# Commits are @{ Sha; Subject }.
function New-ReleaseNotes {
    param(
        [AllowEmptyCollection()] $Commit = @(),
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $SourceCommit,
        [string] $PreviousVersion,
        [string] $RepositoryUrl
    )

    $sections = [ordered]@{}
    foreach ($key in $script:NoteSections.Keys) {
        $sections[$script:NoteSections[$key]] = [System.Collections.Generic.List[object]]::new()
    }
    $sections["Other changes"] = [System.Collections.Generic.List[object]]::new()

    $breaking = [System.Collections.Generic.List[object]]::new()
    $unreferenced = [System.Collections.Generic.List[object]]::new()
    $issues = [System.Collections.Generic.List[int]]::new()

    foreach ($entry in @($Commit)) {
        $subject = ([string] $entry.Subject).Trim()
        if ($subject.Length -eq 0 -or $subject.StartsWith("Merge ")) {
            continue
        }

        $numbers = @([regex]::Matches($subject, '#(?<n>[1-9][0-9]*)') | ForEach-Object { [int] $_.Groups['n'].Value })
        foreach ($number in $numbers) {
            if ($issues -notcontains $number) {
                $issues.Add($number)
            }
        }

        $match = [regex]::Match($subject, '^(?<type>[a-z]+)(?:\((?<scope>[^)]+)\))?(?<breaking>!)?:\s*(?<description>.+)$')
        $section = "Other changes"
        $scope = $null
        $description = $subject

        if ($match.Success) {
            $type = $match.Groups['type'].Value
            if ($script:NoteSections.Contains($type)) {
                $section = $script:NoteSections[$type]
            }
            if ($match.Groups['scope'].Success) {
                $scope = $match.Groups['scope'].Value
            }
            $description = $match.Groups['description'].Value
        }

        $item = [pscustomobject]@{
            Sha         = [string] $entry.Sha
            Subject     = $subject
            Scope       = $scope
            Description = $description
            Issues      = $numbers
        }

        if ($match.Success -and $match.Groups['breaking'].Success) {
            $breaking.Add($item)
        }
        if ($numbers.Count -eq 0) {
            $unreferenced.Add($item)
        }

        $sections[$section].Add($item)
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# $Version")
    $lines.Add("")
    $lines.Add("Source commit: ``$SourceCommit``")
    if (-not [string]::IsNullOrWhiteSpace($PreviousVersion)) {
        $lines.Add("")
        $lines.Add("Changes since $PreviousVersion.")
    }

    if ($breaking.Count -gt 0) {
        $lines.Add("")
        $lines.Add("## Breaking changes")
        $lines.Add("")
        foreach ($item in $breaking) {
            $lines.Add("- $(Format-ReleaseNoteItem -Item $item -RepositoryUrl $RepositoryUrl)")
        }
    }

    foreach ($title in $sections.Keys) {
        $items = $sections[$title]
        if ($items.Count -eq 0) {
            continue
        }

        $lines.Add("")
        $lines.Add("## $title")
        $lines.Add("")
        foreach ($item in $items) {
            $lines.Add("- $(Format-ReleaseNoteItem -Item $item -RepositoryUrl $RepositoryUrl)")
        }
    }

    return [pscustomobject]@{
        Markdown     = ($lines -join "`n") + "`n"
        Issues       = $issues.ToArray()
        Unreferenced = $unreferenced.ToArray()
        Breaking     = $breaking.ToArray()
    }
}

function Format-ReleaseNoteItem {
    param($Item, [string] $RepositoryUrl)

    $text = $Item.Description
    if ($Item.Scope) {
        $text = "**$($Item.Scope)**: $text"
    }

    if ($Item.Issues.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($RepositoryUrl)) {
        $links = @($Item.Issues | ForEach-Object { "[#$_]($($RepositoryUrl.TrimEnd('/'))/issues/$_)" })
        $text = "$text ($($links -join ', '))"
    }

    return $text
}

Export-ModuleMember -Function ConvertFrom-ImageReference, ConvertTo-ImageReference, Test-SemanticVersionTag,
    Get-SourceCommitTag, Get-ManifestImageReference, Set-ManifestImageReference, Test-SourceCommitDigestMap,
    Assert-PromotedDigest, Test-PromotionGate, New-ReleaseLock, Test-ReleaseManifestConsistency, New-ReleaseNotes
