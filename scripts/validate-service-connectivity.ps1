# Validates connectivity between the deployed PulseStream platform services in
# Kubernetes (#146).
#
# Scope of this script is the leg the other validators do not cover:
#
#   - Peer service-to-service reachability over the internal ClusterIP Services
#     (#143) by their DNS name (#144), proving internal service communication,
#     DNS resolution, and the exposed ports all work together.
#   - The database endpoint the services are configured with.
#
# It deliberately does NOT re-test what already has a dedicated validator:
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
    # Name of the Postgres Service, if deployed. Provisioning Postgres itself is
    # tracked separately (service-discovery.md), so its absence is reported, not
    # failed: the live DB probe is skipped and the configured endpoint is still
    # asserted so a regression that drops the URL is caught.
    [string] $PostgresServiceName = "postgres",
    [int] $TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamKubernetes.psm1") -Force

# Every debug pod this run creates carries the same suffix so an interrupted run
# leaves an identifiable pod behind that never collides with a concurrent run.
$runId = [Guid]::NewGuid().ToString('N').Substring(0, 8)

# Parsed once into name/port pairs. A malformed entry is a caller error, so it
# fails loudly here rather than producing a confusing DNS name later.
$serviceTargets = @($Services | ForEach-Object {
    $parts = $_ -split ":"
    if (@($parts).Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or $parts[1] -notmatch "^\d+$") {
        throw "Invalid -Services entry '$_'; expected '<name>:<port>'."
    }
    [pscustomobject]@{ Name = $parts[0]; Port = [int] $parts[1] }
})

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

    $failures = @([regex]::Matches($probe.Output, "(?m)^SVC-FAIL\s+(.*)$") | ForEach-Object { $_.Groups[1].Value })
    Confirm-Condition `
        -Condition (@($failures).Count -eq 0) `
        -SuccessMessage "Every Service answered $ReadinessPath through its ClusterIP DNS name" `
        -FailureMessage "$(@($failures).Count) Service(s) were unreachable by DNS name (curl rc 6 = DNS, 7 = refused, 22 = HTTP error): $($failures -join ' | ')"

    # curl -f already made a non-2xx a failure, so any SVC-OK reached readiness;
    # the body is still checked so a 200 from something that is not the service
    # (an unexpected UP-less body) does not pass as reachable.
    $okLines = @([regex]::Matches($probe.Output, "(?m)^SVC-OK\s+(\S+)\s+(\S+)\s+(.*)$"))
    $notUp = @($okLines | Where-Object { $_.Groups[3].Value -notmatch '"status"\s*:\s*"UP"' } | ForEach-Object { $_.Groups[1].Value })
    Confirm-Condition -Permanent `
        -Condition (@($notUp).Count -eq 0) `
        -SuccessMessage "Every reachable Service reported readiness status UP" `
        -FailureMessage "$(@($notUp).Count) Service(s) answered on their port but not with a readiness state of UP ($($notUp -join ', ')); something other than the expected service may be serving the port"

    Confirm-Condition `
        -Condition (@($okLines).Count -eq @($serviceTargets).Count) `
        -SuccessMessage "All $(@($serviceTargets).Count) Services were reached ($(@($serviceTargets | ForEach-Object { $_.Name }) -join ', '))" `
        -FailureMessage "Only $(@($okLines).Count) of $(@($serviceTargets).Count) Services were reached. $($probe.Output)"
}

# 3. Database endpoint. Read from the running processor pod, not the ConfigMap,
#    for the same reason the Kafka checks do: envFrom is resolved once at pod
#    start, so a ConfigMap edited after the last rollout is already correct in
#    the API server while the pod still runs the previous value.
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

# printenv rather than a shell snippet: Windows PowerShell 5.1 mangles the double
# quotes a `bash -c` one-liner would need (see the base64 note in
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

# Host and port out of the JDBC URL (jdbc:postgresql://<host>:<port>/<db>).
$jdbcMatch = [regex]::Match($postgresUrl, "^jdbc:postgresql://([^:/]+):(\d+)/")
Confirm-Condition -Permanent `
    -Condition ($jdbcMatch.Success) `
    -SuccessMessage "Parsed the datastore endpoint from $PostgresEnvVar" `
    -FailureMessage "$PostgresEnvVar='$postgresUrl' is not a jdbc:postgresql://host:port/db URL, so no host/port can be probed"

$postgresHost = $jdbcMatch.Groups[1].Value
$postgresPort = $jdbcMatch.Groups[2].Value

# Provisioning Postgres is tracked separately, so its absence is reported rather
# than failed: the endpoint above is asserted either way, and the live TCP probe
# only runs when the Service actually exists.
$postgresService = Invoke-Kubectl -KubectlArgs @("get", "service", $PostgresServiceName, "--namespace", $Namespace, "-o", "name")

if ($postgresService.ExitCode -ne 0) {
    Write-Warning "Postgres Service '$PostgresServiceName' is not deployed in namespace '$Namespace' (provisioning it is tracked separately; see service-discovery.md). '$ProcessorServiceName' is wired to '$postgresHost`:$postgresPort' but live database connectivity was not asserted."
} else {
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

Write-Host "[ok] Internal service connectivity validation completed. External ingress is validated by validate-ingestion-external-access.ps1 (#145); Kafka connectivity by validate-kafka-broker-health.ps1 (#142)."
