# Validates connectivity between the deployed PulseStream platform services in
# Kubernetes (#146).
#
# Scope of this script is the leg the other validators do not cover:
#
#   - Peer service-to-service reachability over the internal ClusterIP Services
#     (#143) by their DNS name (#144), proving internal service communication,
#     DNS resolution, and the exposed ports all work together.
#   - Database connectivity from the services: the endpoint telemetry-processor
#     actually runs with, proved live against Postgres. This leg is required by
#     default; -SkipDatabase opts out explicitly and downgrades the run to a
#     partial one that does not claim to have validated #146.
#
# The remaining two legs of the issue's scope each already have a dedicated
# validator, so this script orchestrates them rather than duplicating their
# probes (pass -SkipIngress / -SkipKafka to run either on its own instead):
#   - External ingress to ingestion-service  -> validate-ingestion-external-access.ps1 (#145)
#   - Kafka connectivity from the services    -> validate-kafka-broker-health.ps1 (#142)
#
# Like the Kafka checks, every request is made from a throwaway debug pod that is
# NOT one of the services under test. A curl run from inside a service pod would
# hit its own loopback and prove nothing about the ClusterIP or its DNS name.
[CmdletBinding()]
param(
    [string] $Namespace = "default",
    # Internal ClusterIP Services to cross-check, as "<name>:<port>". The name is
    # both the DNS name (service-discovery.md) and the app.kubernetes.io/name the
    # Service must select; the port is the documented ClusterIP port.
    [string[]] $Services = @(
        "ingestion-service:8081",
        "query-service:8083",
        "telemetry-processor:8082"
    ),
    # Minimal image for the debug pod: Alpine + curl, sh only (no bash). curl
    # resolving the Service name is itself the DNS test, and its exit code tells
    # a resolution failure (6) apart from a refused connection (7).
    [string] $DebugImage = "curlimages/curl:8.11.1",
    [string] $ReadinessPath = "/readyz",
    # The one service that reads a datastore. Its pod env is where the effective
    # Postgres endpoint is read from (envFrom is resolved at pod start, so the
    # ConfigMap alone is not proof of what the process runs with).
    [string] $ProcessorServiceName = "telemetry-processor",
    [string] $PostgresEnvVar = "PULSESTREAM_POSTGRES_URL",
    # Name of the Postgres Service. #146 requires database connectivity from the
    # services to be confirmed, so a missing Service fails the default run: an
    # environment without Postgres cannot produce that proof. Use -SkipDatabase
    # to run the other legs on such an environment; the summary then says so.
    [string] $PostgresServiceName = "postgres",
    # The ingress and Kafka legs are delegated to their own validators (below).
    # Skip either when it is being run on its own, to avoid a redundant pass.
    [switch] $SkipIngress,
    [switch] $SkipKafka,
    # Opt out of the database leg entirely (endpoint + live probe). Only for
    # environments where Postgres is deliberately not deployed; such a run is
    # explicitly not acceptance evidence for #146.
    [switch] $SkipDatabase,
    [int] $TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamKubernetes.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamConnectivity.psm1") -Force

# Every debug pod this run creates carries the same suffix so an interrupted run
# leaves an identifiable pod behind that never collides with a concurrent run.
$runId = [Guid]::NewGuid().ToString('N').Substring(0, 8)

# Parsed once into name/port pairs. A malformed entry is a caller error, so it
# fails loudly here rather than producing a confusing DNS name later. The parse
# itself lives in PulseStreamConnectivity.psm1, where it is covered by
# scripts\tests\test-service-connectivity-parsing.ps1 without needing a cluster.
$serviceTargets = ConvertTo-ServiceTarget -Specification $Services

Write-Host "Validating internal connectivity between platform services in namespace '$Namespace'..."

# 0. Fail fast with a clear message if no cluster is reachable, rather than
#    letting every later check fail with a connection error.
Invoke-KubectlChecked `
    -KubectlArgs @("cluster-info") `
    -ErrorContext "kubectl cannot reach a Kubernetes cluster" | Out-Null
$currentContext = (Invoke-KubectlChecked `
    -KubectlArgs @("config", "current-context") `
    -ErrorContext "Could not determine the current kubectl context").Trim()
Write-Host "[ok] Connected to Kubernetes context '$currentContext' (namespace: $Namespace)"

# 1. Each Service has the shape callers depend on. Read once as JSON: the type,
#    the port, and the selector are all asserted, and separate jsonpath reads
#    would race a Service edited between calls.
foreach ($target in $serviceTargets) {
    $serviceJson = Invoke-KubectlChecked `
        -KubectlArgs @("get", "service", $target.Name, "--namespace", $Namespace, "-o", "json") `
        -ErrorContext "Service '$($target.Name)' was not found in namespace '$Namespace'. Apply infrastructure/kubernetes/$($target.Name)/"

    $service = $serviceJson | ConvertFrom-Json

    Confirm-Condition -Permanent `
        -Condition ($service.spec.type -eq "ClusterIP") `
        -SuccessMessage "Service '$($target.Name)' is of type ClusterIP" `
        -FailureMessage "Service '$($target.Name)' is of type '$($service.spec.type)', not ClusterIP; internal callers address it by its stable ClusterIP"

    $httpPort = @($service.spec.ports | Where-Object { $_.name -eq "http" })[0]

    Confirm-Condition -Permanent `
        -Condition ($null -ne $httpPort) `
        -SuccessMessage "Service '$($target.Name)' exposes a port named 'http'" `
        -FailureMessage "Service '$($target.Name)' has no port named 'http' (found: $(($service.spec.ports | ForEach-Object { $_.name }) -join ', '))"

    Confirm-Condition -Permanent `
        -Condition ([int] $httpPort.port -eq $target.Port) `
        -SuccessMessage "Service '$($target.Name)' listens on the documented port $($target.Port)" `
        -FailureMessage "Service '$($target.Name)' listens on port $($httpPort.port), not the documented $($target.Port) (service-discovery.md)"

    Confirm-Condition -Permanent `
        -Condition ($service.spec.selector."app.kubernetes.io/name" -eq $target.Name) `
        -SuccessMessage "Service '$($target.Name)' selects the '$($target.Name)' pods" `
        -FailureMessage "Service '$($target.Name)' selects app.kubernetes.io/name='$($service.spec.selector.'app.kubernetes.io/name')', which does not match the '$($target.Name)' pods"

    # A ClusterIP with no Ready backend still answers with a virtual IP that
    # black-holes traffic, so the endpoints are checked before the HTTP probe: it
    # separates "nothing is deployed" from "routing is wrong". Retried because
    # this script is also run right after a rollout.
    Invoke-WithRetry -TimeoutSeconds $TimeoutSeconds -FailureMessage "Service '$($target.Name)' never had a Ready endpoint within $TimeoutSeconds seconds." -Operation {
        $sliceJson = Invoke-KubectlChecked `
            -KubectlArgs @(
                "get", "endpointslice",
                "--namespace", $Namespace,
                "-l", "kubernetes.io/service-name=$($target.Name)",
                "-o", "json"
            ) `
            -ErrorContext "Could not read the EndpointSlices of Service '$($target.Name)'"

        $readyAddresses = @(($sliceJson | ConvertFrom-Json).items |
            ForEach-Object { $_.endpoints } |
            Where-Object { $_.conditions.ready -eq $true } |
            ForEach-Object { $_.addresses })

        Confirm-Condition `
            -Condition (@($readyAddresses).Count -ge 1) `
            -SuccessMessage "Service '$($target.Name)' has $(@($readyAddresses).Count) Ready endpoint(s): $($readyAddresses -join ', ')" `
            -FailureMessage "Service '$($target.Name)' has no Ready endpoint, so its ClusterIP has nothing to forward to"
    }
}

# 2. The actual internal reach: from one debug pod, curl every Service's /readyz
#    by its DNS name. A success proves DNS resolution, the ClusterIP route, and
#    the port together, from a vantage point outside the services themselves.
#
#    The command is a single-quoted here-string with {{PLACEHOLDER}} markers so
#    that its `$` shell variables are not touched by PowerShell, then the CRLF
#    that a *.ps1 here-string is checked out with on Windows is normalized to LF
#    (bash/sh otherwise keep the CR on the last token of each line).
$probeTemplate = @'
for entry in {{ENTRIES}}; do
  svc="${entry%%:*}"
  port="${entry##*:}"
  url="http://$svc:$port{{PATH}}"
  if body="$(curl -s -f -m 10 "$url" 2>/tmp/curlerr)"; then
    echo "SVC-OK $svc $url $body"
  else
    echo "SVC-FAIL $svc $url rc=$? $(tr -d '\n' < /tmp/curlerr)"
  fi
done
# The per-service markers above carry the verdict; the loop's own exit status
# would only reflect the last service.
exit 0
'@

$probeCommand = $probeTemplate.
    Replace("{{ENTRIES}}", (($serviceTargets | ForEach-Object { "$($_.Name):$($_.Port)" }) -join " ")).
    Replace("{{PATH}}", $ReadinessPath) -replace "`r`n", "`n" -replace "`r", "`n"

# Retried as a whole: pods may still be starting, and the debug pod itself needs
# its image pulled on a cold cluster.
$script:probeAttempt = 0
Invoke-WithRetry -TimeoutSeconds $TimeoutSeconds -FailureMessage "Not every Service answered $ReadinessPath through its ClusterIP within $TimeoutSeconds seconds." -Operation {
    $script:probeAttempt++

    # The attempt number is part of the pod name: pods are deleted with
    # --wait=false, so the name would otherwise still be taken on the next try.
    $probe = Invoke-KafkaClientCommand `
        -Namespace $Namespace `
        -PodName "svc-connectivity-$runId-$($script:probeAttempt)" `
        -Image $DebugImage `
        -Shell "sh" `
        -TimeoutSeconds $TimeoutSeconds `
        -Command $probeCommand

    Confirm-Condition `
        -Condition ($probe.ExitCode -eq 0) `
        -SuccessMessage "A debug pod probed every Service from outside the services" `
        -FailureMessage "The debug pod did not complete. $($probe.Output)"

    # Each SVC-FAIL carries curl's exit code, which is translated into the
    # reason it stands for (6 = DNS, 7 = refused, ...) so a failed run says
    # whether the DNS name or the port is the problem.
    $probeResult = Get-ServiceProbeResult -Output $probe.Output

    Confirm-Condition `
        -Condition (@($probeResult.Failures).Count -eq 0) `
        -SuccessMessage "Every Service answered $ReadinessPath through its ClusterIP DNS name" `
        -FailureMessage "$(@($probeResult.Failures).Count) Service(s) were unreachable by DNS name: $(($probeResult.Failures | ForEach-Object { $_.Description }) -join ' | ')"

    # curl -f already made a non-2xx a failure, so any SVC-OK reached readiness;
    # the body is still checked so a 200 from something that is not the service
    # (an unexpected UP-less body) does not pass as reachable.
    $notUp = @($probeResult.NotUp | ForEach-Object { $_.Name })
    Confirm-Condition -Permanent `
        -Condition (@($notUp).Count -eq 0) `
        -SuccessMessage "Every reachable Service reported readiness status UP" `
        -FailureMessage "$(@($notUp).Count) Service(s) answered on their port but not with a readiness state of UP ($($notUp -join ', ')); something other than the expected service may be serving the port"

    Confirm-Condition `
        -Condition (@($probeResult.Reached).Count -eq @($serviceTargets).Count) `
        -SuccessMessage "All $(@($serviceTargets).Count) Services were reached ($(@($serviceTargets | ForEach-Object { $_.Name }) -join ', '))" `
        -FailureMessage "Only $(@($probeResult.Reached).Count) of $(@($serviceTargets).Count) Services were reached. $($probe.Output)"
}

# Legs that were deliberately not run. Kept out of the closing summary and
# reported at the end, so a partial run is never read as full validation.
$skippedLegs = [System.Collections.Generic.List[string]]::new()

# 3. Database connectivity from the services. Read from the running processor
#    pod, not the ConfigMap, for the same reason the Kafka checks do: envFrom is
#    resolved once at pod start, so a ConfigMap edited after the last rollout is
#    already correct in the API server while the pod still runs the previous
#    value. The endpoint is then proved live against Postgres itself; #146 asks
#    for database connectivity, which a configured URL alone does not show.
if ($SkipDatabase) {
    Write-Warning "Skipping the database leg (-SkipDatabase): neither the configured datastore endpoint nor live connectivity to it was asserted. This run does not validate the database requirement of #146."
    $skippedLegs.Add("database connectivity from '$ProcessorServiceName' (#146)")
} else {
    $processorPodsJson = Invoke-KubectlChecked `
        -KubectlArgs @("get", "pods", "--namespace", $Namespace, "-l", "app.kubernetes.io/name=$ProcessorServiceName", "-o", "json") `
        -ErrorContext "Deployment '$ProcessorServiceName' was not found or has no pods in namespace '$Namespace'. Deploy infrastructure/kubernetes/$ProcessorServiceName/ first"

    # Readiness and name have to stay correlated per pod, so this is read from -o
    # json rather than as two index-aligned jsonpath lists that a not-yet-scheduled
    # pod would shift.
    $readyProcessorPod = @(($processorPodsJson | ConvertFrom-Json).items |
        Where-Object { $_.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" } } |
        ForEach-Object { $_.metadata.name } |
        Select-Object -First 1)[0]

    Confirm-Condition -Permanent `
        -Condition (-not [string]::IsNullOrWhiteSpace($readyProcessorPod)) `
        -SuccessMessage "'$ProcessorServiceName' has a Ready pod ($readyProcessorPod) to read the datastore endpoint from" `
        -FailureMessage "'$ProcessorServiceName' has no Ready pod, so its configured datastore endpoint cannot be read"

    # printenv rather than a shell snippet: Windows PowerShell 5.1 mangles the
    # double quotes a `bash -c` one-liner would need (see the base64 note in
    # PulseStreamKubernetes.psm1), and printenv exits non-zero precisely when the
    # variable is unset, which is the distinction this check is about.
    $envProbe = Invoke-Kubectl -KubectlArgs @(
        "exec", $readyProcessorPod, "--namespace", $Namespace, "--", "printenv", $PostgresEnvVar
    )
    $postgresUrl = $envProbe.Output.Trim()

    Confirm-Condition -Permanent `
        -Condition ($envProbe.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($postgresUrl)) `
        -SuccessMessage "Read $PostgresEnvVar from pod '$readyProcessorPod' ($postgresUrl)" `
        -FailureMessage "$PostgresEnvVar is unset in pod '$readyProcessorPod', so '$ProcessorServiceName' was never given a datastore endpoint. $($envProbe.Output)"

    # Host and port out of the JDBC URL (see Get-PostgresEndpoint for the shapes
    # accepted, including a portless URL and an IPv6 literal).
    $endpoint = Get-PostgresEndpoint -JdbcUrl $postgresUrl
    Confirm-Condition -Permanent `
        -Condition ($endpoint.IsValid) `
        -SuccessMessage "Parsed the datastore endpoint from $PostgresEnvVar" `
        -FailureMessage "$PostgresEnvVar='$postgresUrl' is not a jdbc:postgresql://host[:port]/db URL, so no host/port can be probed"

    $postgresHost = $endpoint.HostName
    $postgresPort = $endpoint.Port

    # #146 asks for database connectivity from the services, so an absent
    # Postgres Service is a failure rather than a warning: without it the live
    # probe below cannot run, and a run that cannot produce that proof must not
    # report success. -SkipDatabase is the explicit way out on an environment
    # where Postgres is deliberately not deployed.
    $postgresService = Invoke-Kubectl -KubectlArgs @("get", "service", $PostgresServiceName, "--namespace", $Namespace, "-o", "name")

    Confirm-Condition -Permanent `
        -Condition ($postgresService.ExitCode -eq 0) `
        -SuccessMessage "Postgres Service '$PostgresServiceName' is deployed in namespace '$Namespace'" `
        -FailureMessage "Postgres Service '$PostgresServiceName' is not deployed in namespace '$Namespace', so database connectivity from '$ProcessorServiceName' (wired to '$postgresHost`:$postgresPort') cannot be proved. Deploy Postgres, or re-run with -SkipDatabase to validate the other legs only - a skipped run is not acceptance evidence for #146. $($postgresService.Output)"

    # TCP connect from inside the processor pod, against the endpoint that pod
    # actually runs with. This exercises the service's own DNS resolution and
    # network path to Postgres, so a namespace mismatch that only affects this
    # service is caught here. bash is present in the eclipse-temurin:17-jre-jammy
    # base image the service builds on.
    Invoke-WithRetry -TimeoutSeconds $TimeoutSeconds -FailureMessage "'$ProcessorServiceName' could not reach Postgres at '$postgresHost`:$postgresPort' within $TimeoutSeconds seconds." -Operation {
        $tcpProbe = Invoke-Kubectl -KubectlArgs @(
            "exec", $readyProcessorPod, "--namespace", $Namespace, "--",
            "bash", "-c", "exec 3<>/dev/tcp/$postgresHost/$postgresPort && echo POSTGRES-REACHABLE"
        )

        Confirm-Condition `
            -Condition ($tcpProbe.ExitCode -eq 0 -and $tcpProbe.Output -match "POSTGRES-REACHABLE") `
            -SuccessMessage "'$ProcessorServiceName' reaches Postgres at '$postgresHost`:$postgresPort' from its own pod" `
            -FailureMessage "'$ProcessorServiceName' cannot reach '$postgresHost`:$postgresPort' from pod '$readyProcessorPod'. $($tcpProbe.Output)"
    }
}

# 4. The other two legs of the issue's scope (external ingress, Kafka) each have
#    a dedicated validator. Orchestrate them here so one run covers all of #146
#    without re-implementing their probes. A leg that fails throws a terminating
#    error which, under $ErrorActionPreference = "Stop", aborts this run too - so
#    the overall exit code reflects every leg, not just the internal checks.
$delegatedLegs = @(
    [pscustomobject]@{
        Name   = "External ingress to ingestion-service (#145)"
        Script = "validate-ingestion-external-access.ps1"
        Skip   = [bool] $SkipIngress
    }
    [pscustomobject]@{
        Name   = "Kafka connectivity from services (#142)"
        Script = "validate-kafka-broker-health.ps1"
        Skip   = [bool] $SkipKafka
    }
)

# Only the legs that actually ran are named in the closing summary, so a run
# with -SkipIngress/-SkipKafka does not claim to have covered a skipped leg.
$covered = [System.Collections.Generic.List[string]]::new()
$covered.Add("internal ClusterIP reach")
if (-not $SkipDatabase) {
    $covered.Add("database connectivity from '$ProcessorServiceName'")
}

foreach ($leg in $delegatedLegs) {
    if ($leg.Skip) {
        Write-Warning "Skipping '$($leg.Name)'; run scripts/$($leg.Script) on its own to validate it."
        $skippedLegs.Add($leg.Name)
        continue
    }

    Write-Host "--- Delegating '$($leg.Name)' to $($leg.Script) ---"
    & (Join-Path $PSScriptRoot $leg.Script) -Namespace $Namespace -TimeoutSeconds $TimeoutSeconds
    Write-Host "[ok] '$($leg.Name)' validated by $($leg.Script)"
    $covered.Add($leg.Name)
}

if (@($skippedLegs).Count -gt 0) {
    # A partial run still exits 0 (the caller asked for the skips), but it must
    # not read as a completed validation: the closing line names only what ran,
    # and says outright that the run does not stand as evidence for #146.
    Write-Warning "Partial run: $(@($skippedLegs).Count) leg(s) were skipped and NOT validated: $($skippedLegs -join '; '). This run is not acceptance evidence for #146."
    Write-Host "[partial] Platform service connectivity validated for: $($covered -join '; '). Skipped: $($skippedLegs -join '; ')."
} else {
    Write-Host "[ok] Platform service connectivity validation completed: $($covered -join '; ')."
}
