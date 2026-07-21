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
    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force

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
# - HealthPort:  container port the actuator /health endpoint listens on. For most
#                services this is the service port; telemetry-processor serves its
#                management surface on a separate loopback-bound port (see its
#                application.yml), so validation must both target 9083 and bind it
#                to 0.0.0.0 (via PULSESTREAM_MANAGEMENT_ADDRESS) to reach it.
# - HostPort:    host port the HealthPort is published on. Offset into the 19xxx
#                range so validation never collides with a service already running
#                on the host on its native port.
# - Env:         environment overrides the container needs to start cleanly.
$serviceConfig = @{
    "ingestion-service"   = @{
        HealthPort = 8081
        HostPort   = 19081
        Env        = @{ PULSESTREAM_OTEL_TRACES_EXPORTER = "none" }
    }
    "telemetry-processor" = @{
        HealthPort = 9083
        HostPort   = 19083
        Env        = @{
            PULSESTREAM_OTEL_TRACES_EXPORTER = "none"
            # The management port is bound to loopback inside the container by
            # default. Bind it to all interfaces here so the published port is
            # reachable from the host for the health check. Validation only.
            PULSESTREAM_MANAGEMENT_ADDRESS   = "0.0.0.0"
        }
    }
    "query-service"       = @{
        HealthPort = 8083
        HostPort   = 19082
        Env        = @{ PULSESTREAM_OTEL_TRACES_EXPORTER = "none" }
    }
}

function Get-ImageTag {
    param([string] $Service)
    "$ImagePrefix/$Service`:local"
}

function Get-ContainerName {
    param([string] $Service)
    "pulsestream-validate-$Service"
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

    $tag = Get-ImageTag $Service
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

    $tag = Get-ImageTag $Service
    $name = Get-ContainerName $Service

    # Fresh start every run so a leftover container from a prior run cannot mask a
    # regression.
    Remove-ValidationContainer $Service

    $runArgs = @(
        "run", "-d", "--name", $name,
        "--network", $Network,
        "-p", "$($config.HostPort):$($config.HealthPort)"
    )
    foreach ($key in $config.Env.Keys) {
        $runArgs += @("-e", "$key=$($config.Env[$key])")
    }
    $runArgs += $tag

    Invoke-Docker @runArgs | Out-Null
    Confirm-Condition -Permanent `
        -Condition ($LASTEXITCODE -eq 0) `
        -SuccessMessage "Container started: $name" `
        -FailureMessage "docker run failed for '$Service' (exit $LASTEXITCODE)."

    $healthUrl = "http://localhost:$($config.HostPort)/actuator/health"

    try {
        Invoke-WithRetry `
            -TimeoutSeconds $TimeoutSeconds `
            -FailureMessage "'$Service' health endpoint did not report UP within $TimeoutSeconds seconds." `
            -Operation {
                # A crashed container can never recover, so fail fast instead of
                # retrying for the full timeout against a dead container.
                $running = Invoke-Docker inspect -f "{{.State.Running}}" $name
                Confirm-Condition -Permanent `
                    -Condition ("$running".Trim() -eq "true") `
                    -SuccessMessage "'$Service' container is running" `
                    -FailureMessage "'$Service' container exited before becoming healthy. Recent logs:`n$(Invoke-Docker logs --tail 40 $name | Out-String)"

                $result = Invoke-JsonGet $healthUrl
                Confirm-Condition `
                    -Condition ($result.status -eq "UP") `
                    -SuccessMessage "'$Service' health endpoint is UP ($healthUrl)" `
                    -FailureMessage "'$Service' health endpoint status was '$($result.status)', expected UP"
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

    if (-not $SkipBuild) {
        Build-ServiceImage $service
    }

    Test-ServiceContainer $service
    Write-Host ""
}

Write-Host "[ok] All targeted service images built, started, and reported healthy." -ForegroundColor Green
