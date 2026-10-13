# Execute the actual publishing shell blocks with instrumented Docker/Cosign.
# No registry, credentials, Docker daemon or signing identity is used. Trivy
# and SBOM action results are injected at their real workflow boundaries.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$workflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/publish-images.yml') -Raw
$releaseWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/release-promotion.yml') -Raw
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('pulsestream-publish-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Assert-True {
    param([string] $What, [bool] $Condition)
    if (-not $Condition) { throw $What }
    Write-Host "[ok] $What"
}

function Get-Step {
    param([string] $Name)
    $pattern = '(?ms)^      - name: ' + [regex]::Escape($Name) + '\r?\n(?<body>.*?)(?=^      - name:|^  [a-z]|\z)'
    $match = [regex]::Match($workflow, $pattern)
    if (-not $match.Success) { throw "Missing workflow step '$Name'." }
    return $match.Groups['body'].Value
}

function Get-Shell {
    param([string] $Name)
    $step = Get-Step -Name $Name
    $match = [regex]::Match($step, '(?ms)^        run: \|\r?\n(?<body>.*)')
    if (-not $match.Success) { throw "Missing shell body for '$Name'." }
    return [regex]::Replace($match.Groups['body'].Value, '(?m)^          ', '').Replace("`r`n", "`n")
}

$prepare = Get-Shell -Name 'Prepare the image locally'
$publish = Get-Shell -Name 'Publish the scanned image'
$scan = Get-Step -Name 'Scan before publication'
$sbom = Get-Step -Name 'Generate the scanned image SBOM'
Assert-True 'Trivy scans the local archive and fails on HIGH/CRITICAL vulnerabilities' (
    $scan -match 'uses: aquasecurity/trivy-action@v0.36.0' -and
    $scan -match 'input: candidate.tar' -and $scan -match "exit-code: '1'" -and
    $scan -match 'severity: HIGH,CRITICAL' -and $scan -notmatch 'continue-on-error'
)
Assert-True 'SBOM generation reads the same local archive in SPDX JSON format' (
    $sbom -match 'image: docker-archive:candidate.tar' -and $sbom -match 'format: spdx-json'
)
Assert-True 'new images use a single-platform manifest whose OCI config can be inspected on reuse' (
    $prepare -match 'docker build --provenance=false'
)
Assert-True 'scan and SBOM steps precede publication without an unconditional success bypass' (
    $workflow.IndexOf('name: Prepare the image locally') -lt $workflow.IndexOf('name: Scan before publication') -and
    $workflow.IndexOf('name: Scan before publication') -lt $workflow.IndexOf('name: Generate the scanned image SBOM') -and
    $workflow.IndexOf('name: Generate the scanned image SBOM') -lt $workflow.IndexOf('name: Publish the scanned image') -and
    (Get-Step -Name 'Publish the scanned image') -notmatch 'if:|continue-on-error'
)
Assert-True 'promotion verifies exact workflow identity and signed source commit' (
    $releaseWorkflow -match '--certificate-identity ' -and
    $releaseWorkflow -match "-a 'source-commit=\$\{\{ inputs.source_commit \}\}'"
)

# On Windows, prefer Git Bash over the unrelated WSL bash shim in System32.
$gitBash = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git/bin/bash.exe' } else { '' }
$bash = if ($gitBash -and (Test-Path -LiteralPath $gitBash)) { $gitBash } else { (Get-Command bash -ErrorAction Stop).Source }

$stubs = @'
set -euo pipefail
export GITHUB_SHA=1111111111111111111111111111111111111111
export GITHUB_REPOSITORY_OWNER=ME-Massine
export GITHUB_REPOSITORY=ME-Massine/pulsestream
export GITHUB_SERVER_URL=https://github.com
export SERVICE=ingestion-service
export GITHUB_OUTPUT=prepare-output
image_ref=ghcr.io/me-massine/pulsestream/ingestion-service
built_digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
foreign_digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
image_id=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
identity=https://github.com/ME-Massine/pulsestream/.github/workflows/publish-images.yml@refs/heads/main
: > calls.log
docker() {
  echo "docker $*" >> calls.log
  case "$1 $2" in
    'buildx imagetools')
      if [ "$3" = create ]; then return 0; fi
      if [ "$#" = 4 ]; then [ "$EXISTS" = true ]; return; fi
      if [[ "$6" = *org.opencontainers.image.revision* ]]; then
        if [ "$BAD_REVISION" = true ]; then echo wrong; else echo "$GITHUB_SHA"; fi
      elif [[ "$6" = *org.opencontainers.image.source* ]]; then
        if [ "$BAD_SOURCE" = true ]; then echo https://github.com/foreign/repo; else echo "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"; fi
      elif [[ "$4" = *:sha-* ]] && [ "$REPOINT" = true ] && [ -f scanned ]; then
        echo "$foreign_digest"
      else echo "$built_digest"
      fi
      ;;
    'image inspect')
      if [[ "$5" = *RepoDigests* ]]; then echo "$image_ref@$built_digest"; else echo "$image_id"; fi
      ;;
    'save --output') touch "$3" ;;
    *)
      case "$1" in
        build|pull|push|tag) return 0 ;;
        *) echo "Unexpected Docker invocation: $*" >&2; return 90 ;;
      esac
      ;;
  esac
}
cosign() {
  echo "cosign $*" >> calls.log
  case "$1" in
    verify)
      [[ "$*" = *"--certificate-identity $identity"* ]] || return 91
      [[ "$*" = *"--certificate-oidc-issuer https://token.actions.githubusercontent.com"* ]] || return 92
      [[ "$*" = *"-a source-commit=$GITHUB_SHA"* ]] || return 93
      [[ "$*" = *"$image_ref@$built_digest"* ]] || return 94
      [ "$TRUSTED" = true ] && [ "$SIGNATURE_COMMIT" = "$GITHUB_SHA" ]
      ;;
    attach)
      [[ "$*" = *"--type spdx "* ]] || return 95
      [[ "$*" = *"$image_ref@$built_digest"* ]] || return 96
      ;;
    sign)
      [[ "$*" = *"-a source-commit=$GITHUB_SHA"* ]] || return 97
      [[ "$*" = *"$image_ref@$built_digest"* ]] || return 98
      ;;
    *) return 99 ;;
  esac
}
'@

$boundary = @'
# Transfer the outputs exactly as Actions does between the two shell steps.
export IMAGE="$image" DIGEST="$digest" LOCAL_ID="$local_id" SOURCE_TAG="$source_tag" REBUILT="$rebuilt"
export SBOM=ingestion-service.spdx.json
echo "scan candidate.tar" >> calls.log
[ "$SCAN_OK" = true ]
touch scanned
echo "sbom candidate.tar" >> calls.log
[ "$SBOM_OK" = true ]
touch "$SBOM"
export GITHUB_OUTPUT=publish-output
'@

function Invoke-Case {
    param([string] $Name, [hashtable] $Options = @{}, [bool] $Success)
    $defaults = @{
        EXISTS = 'false'; TRUSTED = 'true'; SIGNATURE_COMMIT = ('1' * 40)
        BAD_REVISION = 'false'; BAD_SOURCE = 'false'; REPOINT = 'false'
        SCAN_OK = 'true'; SBOM_OK = 'true'
    }
    foreach ($key in $Options.Keys) { $defaults[$key] = $Options[$key] }
    $settings = ($defaults.Keys | Sort-Object | ForEach-Object { "$_=$($defaults[$_])" }) -join "`n"
    $casePath = Join-Path $scratch $Name
    New-Item -ItemType Directory -Path $casePath -Force | Out-Null
    $scriptPath = Join-Path $casePath 'run.sh'
    [System.IO.File]::WriteAllText($scriptPath, ($settings + "`n" + $stubs + "`n" + $prepare + "`n" + $boundary + "`n" + $publish), $utf8)
    Push-Location $casePath
    try {
        $output = & $bash $scriptPath.Replace('\', '/') 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { Pop-Location }
    Assert-True "$Name has the expected success/failure result (exit $exitCode): $output" (($exitCode -eq 0) -eq $Success)
    $calls = Get-Content -LiteralPath (Join-Path $casePath 'calls.log') -Raw
    return [pscustomobject]@{ Calls = $calls; Path = $casePath }
}

try {
    $new = Invoke-Case -Name 'new-image' -Success $true
    Assert-True 'new image is scanned and inventoried before any push' (
        $new.Calls.IndexOf('scan candidate.tar') -lt $new.Calls.IndexOf('docker push ') -and
        $new.Calls.IndexOf('sbom candidate.tar') -lt $new.Calls.IndexOf('docker push ')
    )
    Assert-True 'new image is signed before exposing latest' (
        $new.Calls.IndexOf('cosign sign ') -lt $new.Calls.IndexOf('docker buildx imagetools create ')
    )
    Assert-True 'new image records the digest pushed from the scanned local ID' (
        (Get-Content (Join-Path $new.Path 'publish-output') -Raw) -match ('digest=sha256:' + ('a' * 64))
    )

    foreach ($case in @(
        @{ Name = 'rejected-scan'; Options = @{ SCAN_OK = 'false' } },
        @{ Name = 'failed-sbom'; Options = @{ SBOM_OK = 'false' } },
        @{ Name = 'forged-label'; Options = @{ EXISTS = 'true'; TRUSTED = 'false' } },
        @{ Name = 'wrong-signed-commit'; Options = @{ EXISTS = 'true'; SIGNATURE_COMMIT = ('2' * 40) } },
        @{ Name = 'wrong-revision'; Options = @{ EXISTS = 'true'; BAD_REVISION = 'true' } },
        @{ Name = 'wrong-repository'; Options = @{ EXISTS = 'true'; BAD_SOURCE = 'true' } }
    )) {
        $rejected = Invoke-Case -Name $case.Name -Options $case.Options -Success $false
        Assert-True "$($case.Name) causes no push, signing, latest move, or digest record" (
            $rejected.Calls -notmatch 'docker push |cosign sign |imagetools create ' -and
            -not (Test-Path (Join-Path $rejected.Path 'publish-output'))
        )
    }

    $reuse = Invoke-Case -Name 'trusted-reuse' -Options @{ EXISTS = 'true' } -Success $true
    Assert-True 'trusted reuse verifies before pulling and rescans without rebuilding, pushing or signing' (
        $reuse.Calls.IndexOf('cosign verify ') -lt $reuse.Calls.IndexOf('docker pull ') -and
        $reuse.Calls -match 'scan candidate.tar' -and
        $reuse.Calls -notmatch 'docker build |docker push |cosign sign '
    )

    foreach ($existing in @('false', 'true')) {
        $race = Invoke-Case -Name "repointed-$existing" -Options @{ EXISTS = $existing; REPOINT = 'true' } -Success $false
        Assert-True 'a repointed source tag never grants the foreign digest a signature or latest' (
            $race.Calls -notmatch 'cosign sign |imagetools create ' -and
            -not (Test-Path (Join-Path $race.Path 'publish-output'))
        )
    }
}
finally {
    if (Test-Path -LiteralPath $scratch) {
        # The only recursively removed directory is this test's unique temp tree.
        $resolvedScratch = (Resolve-Path -LiteralPath $scratch).Path
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if (-not $resolvedScratch.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected test directory '$resolvedScratch'."
        }
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
}
