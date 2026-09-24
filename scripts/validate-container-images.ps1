[CmdletBinding()]
param(
    # Which services to validate. Each must have a Dockerfile under services/<name>.
    [string[]] $Services = @("ingestion-service", "telemetry-processor", "query-service"),
    # Docker network the validation containers join so the platform hostnames used
    # by the services (kafka:29092, postgres:5432) resolve. This is the network the
    # infrastructure/docker/docker-compose.yml stack creates: <project>_<network> =
    # "pulsestream-local_pulsestream-net". Run `docker network ls` if it differs.
    [string] $Network = "pulsestream-local_pulsestream-net",
    # Tag prefix for the locally built images. Full tag is <prefix>/<service>:local.
    [string] $ImagePrefix = "pulsestream",
    # Skip the build phase and validate images already built with the same tags.
    [switch] $SkipBuild,
    # Exact service=image-reference mappings to pull and validate. This is how
    # publish-images.yml tests the immutable digest it will later promote.
    [string[]] $ImageReference = @(),
    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamYaml.psm1") -Force

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Invoke-Docker {
    # Run the docker CLI without letting its stderr kill the script. docker writes
    # build/pull progress to stderr; under Windows PowerShell 5.1 with
    # $ErrorActionPreference = "Stop", native stderr is promoted to a terminating
    # NativeCommandError. Flip to Continue for the call and let callers decide
    # success from $LASTEXITCODE. stderr is merged into the returned stream so
    # progress and errors still reach the console.
    param([Parameter(ValueFromRemainingArguments = $true)] $DockerArgs)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & docker @DockerArgs 2>&1
    } finally {
        $ErrorActionPreference = $prev
    }
}

# Per-service validation parameters. Everything a container needs to start and to
# expose a reachable health endpoint on the host lives here so the run loop below
# stays generic.
#
# - MainPort/ManagementPort: container ports for the Kubernetes probe paths and
#                the full actuator surface. telemetry-processor serves the latter
#                on a separate loopback-bound port, so validation targets both and
#                binds it to 0.0.0.0 (via PULSESTREAM_MANAGEMENT_ADDRESS).
# - MainHostPort/ManagementHostPort: host ports offset into the 19xxx range so
#                validation never collides with a service on its native port.
# - Env:         environment overrides the container needs to start cleanly.
$serviceConfig = @{
    "ingestion-service"   = @{
        MainPort           = 8081
        MainHostPort       = 19081
        ManagementPort     = 8081
        ManagementHostPort = 19081
        Env                = @{ PULSESTREAM_OTEL_TRACES_EXPORTER = "none" }
    }
    "telemetry-processor" = @{
        MainPort           = 8082
        MainHostPort       = 19082
        ManagementPort     = 9083
        ManagementHostPort = 19083
        Env                = @{
            PULSESTREAM_OTEL_TRACES_EXPORTER = "none"
            # The management port is bound to loopback inside the container by
            # default. Bind it to all interfaces here so the published port is
            # reachable from the host for the health check. Validation only.
            PULSESTREAM_MANAGEMENT_ADDRESS   = "0.0.0.0"
        }
    }
    "query-service"       = @{
        MainPort           = 8083
        MainHostPort       = 19084
        ManagementPort     = 8083
        ManagementHostPort = 19084
        Env                = @{ PULSESTREAM_OTEL_TRACES_EXPORTER = "none" }
    }
}

if ($ImageReference.Count -gt 0 -and $SkipBuild) {
    throw "-ImageReference already skips the local build; do not combine it with -SkipBuild."
}

$providedReference = @{}
foreach ($entry in $ImageReference) {
    $parts = $entry.Split([char[]] '=', 2)
    if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
        throw "Image reference '$entry' is not in '<service>=<image-reference>' form."
    }

    $service = $parts[0].Trim()
    if (-not $serviceConfig.ContainsKey($service)) {
        throw "Image reference '$entry' names unknown service '$service'."
    }
    if ($providedReference.ContainsKey($service)) {
        throw "Image reference was supplied more than once for '$service'."
    }
    $providedReference[$service] = $parts[1].Trim()
}

if ($providedReference.Count -gt 0) {
    foreach ($service in $Services) {
        if (-not $providedReference.ContainsKey($service)) {
            throw "No exact image reference was supplied for '$service'. Digest validation must cover every selected service."
        }
    }
}

function Get-ImageReference {
    param([string] $Service)
    if ($providedReference.ContainsKey($Service)) {
        return $providedReference[$Service]
    }
    "$ImagePrefix/$Service`:local"
}

function Get-ContainerName {
    param([string] $Service)
    "pulsestream-validate-$Service"
}

function Get-DeploymentProbeEndpoints {
    param([string] $Service, $Config)

    $manifestPath = Join-Path $repoRoot "infrastructure\kubernetes\$Service\deployment.yaml"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Deployment manifest for '$Service' was not found at '$manifestPath'."
    }

    $deployment = ConvertFrom-KubernetesYaml -Path $manifestPath
    $containers = @($deployment.spec.template.spec.containers | Where-Object { $_.name -eq $Service })
    if ($containers.Count -ne 1) {
        throw "Deployment '$Service' must contain exactly one '$Service' container for runtime probe validation."
    }

    $endpoints = [System.Collections.Generic.List[object]]::new()
    foreach ($probeSpec in @(
        [pscustomobject]@{ Name = "liveness"; Property = "livenessProbe"; ExpectedPath = "/livez" },
        [pscustomobject]@{ Name = "readiness"; Property = "readinessProbe"; ExpectedPath = "/readyz" }
    )) {
        $probe = $containers[0].$($probeSpec.Property)
        if ($null -eq $probe -or $null -eq $probe.httpGet) {
            throw "Deployment '$Service' has no HTTP $($probeSpec.Name) probe."
        }
        if ($probe.httpGet.path -ne $probeSpec.ExpectedPath) {
            throw "Deployment '$Service' $($probeSpec.Name) probe is '$($probe.httpGet.path)', expected '$($probeSpec.ExpectedPath)'."
        }
        # Kubernetes probes may use a named container port (the manifests use
        # `http`) rather than the numeric port. Resolve that name against the
        # same container before checking the host mapping.
        $declaredPort = [string] $probe.httpGet.port
        $resolvedPort = $declaredPort
        if ($declaredPort -notmatch '^\d+$') {
            $namedPorts = @($containers[0].ports | Where-Object { [string] $_.name -eq $declaredPort })
            if ($namedPorts.Count -ne 1) {
                throw "Deployment '$Service' $($probeSpec.Name) refers to named port '$declaredPort', but that name is not declared exactly once on the container."
            }
            $resolvedPort = [string] $namedPorts[0].containerPort
        }
        if ($resolvedPort -ne [string] $Config.MainPort) {
            throw "Deployment '$Service' $($probeSpec.Name) resolves to port '$resolvedPort' (declared as '$declaredPort'), but runtime validation publishes '$($Config.MainPort)'."
        }

        $endpoints.Add([pscustomobject]@{
            Name = $probeSpec.Name
            Url  = "http://localhost:$($Config.MainHostPort)$($probe.httpGet.path)"
        })
    }

    return $endpoints.ToArray()
}

function Remove-ValidationContainer {
    param([string] $Service)
    # Best effort teardown; a missing container is not an error.
    Invoke-Docker rm -f (Get-ContainerName $Service) | Out-Null
}

function Build-ServiceImage {
    param([string] $Service)

    $context = Join-Path $repoRoot "services\$Service"
    if (-not (Test-Path (Join-Path $context "Dockerfile"))) {
        throw "No Dockerfile found for '$Service' at $context."
    }

    $tag = Get-ImageReference $Service
    Write-Host "Building $tag ..."
    Invoke-Docker build -t $tag $context
    Confirm-Condition -Permanent `
        -Condition ($LASTEXITCODE -eq 0) `
        -SuccessMessage "Image built: $tag" `
        -FailureMessage "docker build failed for '$Service' (exit $LASTEXITCODE)."
}

function Test-ServiceContainer {
    param([string] $Service)

    $config = $serviceConfig[$Service]
    if ($null -eq $config) {
        throw "No validation config for service '$Service'."
    }

    $tag = Get-ImageReference $Service
    $name = Get-ContainerName $Service

    $configuredUser = (Invoke-Docker inspect --format '{{.Config.User}}' $tag | Out-String).Trim()
    Confirm-Condition -Permanent `
        -Condition (($LASTEXITCODE -eq 0) -and -not [string]::IsNullOrWhiteSpace($configuredUser) -and $configuredUser -notin @("root", "0", "0:0")) `
        -SuccessMessage "Image is configured to run as non-root ($configuredUser)" `
        -FailureMessage "Image '$Service' must configure a non-root user (got '$configuredUser')."

    # Fresh start every run so a leftover container from a prior run cannot mask a
    # regression.
    Remove-ValidationContainer $Service

    $runArgs = @(
        "run", "-d", "--name", $name,
        "--network", $Network,
        "-p", "$($config.MainHostPort):$($config.MainPort)"
    )
    if ($config.ManagementHostPort -ne $config.MainHostPort -or $config.ManagementPort -ne $config.MainPort) {
        $runArgs += @("-p", "$($config.ManagementHostPort):$($config.ManagementPort)")
    }
    foreach ($key in $config.Env.Keys) {
        $runArgs += @("-e", "$key=$($config.Env[$key])")
    }
    $runArgs += $tag

    Invoke-Docker @runArgs | Out-Null
    Confirm-Condition -Permanent `
        -Condition ($LASTEXITCODE -eq 0) `
        -SuccessMessage "Container started: $name" `
        -FailureMessage "docker run failed for '$Service' (exit $LASTEXITCODE)."

    # Read liveness/readiness from the committed Deployment rather than merely
    # duplicating their paths here. telemetry-processor's full management
    # surface remains separately reachable on 9083.
    $endpoints = @(
        Get-DeploymentProbeEndpoints -Service $Service -Config $config
        [pscustomobject]@{ Name = "management health"; Url = "http://localhost:$($config.ManagementHostPort)/actuator/health" }
    )

    try {
        Invoke-WithRetry `
            -TimeoutSeconds $TimeoutSeconds `
            -FailureMessage "'$Service' deployed liveness, readiness, and management endpoints did not all report UP within $TimeoutSeconds seconds." `
            -Operation {
                # A crashed container can never recover, so fail fast instead of
                # retrying for the full timeout against a dead container.
                $running = Invoke-Docker inspect -f "{{.State.Running}}" $name
                Confirm-Condition -Permanent `
                    -Condition ("$running".Trim() -eq "true") `
                    -SuccessMessage "'$Service' container is running" `
                    -FailureMessage "'$Service' container exited before becoming healthy. Recent logs:`n$(Invoke-Docker logs --tail 40 $name | Out-String)"

                foreach ($endpoint in $endpoints) {
                    $result = Invoke-JsonGet $endpoint.Url
                    Confirm-Condition `
                        -Condition ($result.status -eq "UP") `
                        -SuccessMessage "'$Service' $($endpoint.Name) endpoint is UP ($($endpoint.Url))" `
                        -FailureMessage "'$Service' $($endpoint.Name) endpoint status was '$($result.status)', expected UP ($($endpoint.Url))"
                }
            }
    }
    finally {
        Remove-ValidationContainer $Service
    }
}

Write-Host "Validating platform container images: $($Services -join ', ')"
Write-Host "Network: $Network"
Write-Host ""

foreach ($service in $Services) {
    Write-Host "=== $service ===" -ForegroundColor Cyan

    if ($providedReference.Count -gt 0) {
        $reference = Get-ImageReference $service
        Write-Host "Pulling exact image $reference ..."
        Invoke-Docker pull $reference | Out-Null
        Confirm-Condition -Permanent `
            -Condition ($LASTEXITCODE -eq 0) `
            -SuccessMessage "Exact image pulled: $reference" `
            -FailureMessage "docker pull failed for '$reference' (exit $LASTEXITCODE)."
    } elseif (-not $SkipBuild) {
        Build-ServiceImage $service
    }

    Test-ServiceContainer $service
    Write-Host ""
}

Write-Host "[ok] All targeted service images built, started, and reported healthy." -ForegroundColor Green
