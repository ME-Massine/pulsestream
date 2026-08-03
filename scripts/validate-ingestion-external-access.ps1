# Validates that ingestion-service is reachable from outside the Kubernetes
# cluster through the NodePort Service added in #145.
#
# The point of this script is that every HTTP request below is made from this
# machine, not from inside the cluster. A check running in a pod would pass
# against the ClusterIP Service alone and prove nothing about external exposure.
[CmdletBinding()]
param(
    [string] $Namespace = "default",
    # The NodePort Service under test, from
    # infrastructure/kubernetes/ingestion-service/service-nodeport.yaml.
    [string] $ServiceName = "ingestion-service-external",
    # Label selector of the workload behind it, as set in deployment.yaml.
    [string] $AppLabel = "ingestion-service",
    # Expected port mapping. These are asserted rather than read-and-trusted:
    # the documented address in the directory README depends on the node port
    # staying 30081, and routing is only correct if the Service forwards to the
    # container's named `http` port.
    [int] $ExpectedNodePort = 30081,
    [int] $ExpectedServicePort = 8081,
    [string] $ExpectedTargetPort = "http",
    # Base URL of the cluster from outside, e.g. http://192.168.49.2:30081.
    # Left empty by default so the node address is discovered below; set it for
    # clusters whose nodes are not directly routable from the host (kind without
    # extraPortMappings, a remote cluster reached through a tunnel).
    [string] $BaseUrl = "",
    # Opt-in: POST a well-formed telemetry event to /api/v1/events, which
    # publishes a real record to telemetry.events.raw. Off by default because
    # every other check in this script is side-effect free; routing to the
    # ingest endpoint is proven without it by the rejected-body check.
    [switch] $IncludeIngestTest,
    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamKubernetes.psm1") -Force

$readinessPath = "/readyz"
$ingestPath = "/api/v1/events"

Write-Host "Validating external access to '$ServiceName' in namespace '$Namespace'..."

# --- Service shape -----------------------------------------------------------
# Read once as JSON: the type, the port mapping, and the selector are all
# asserted, and three jsonpath reads would race a Service edited between calls.
$serviceJson = Invoke-KubectlChecked `
    -KubectlArgs @("get", "service", $ServiceName, "--namespace", $Namespace, "-o", "json") `
    -ErrorContext "Service '$ServiceName' was not found in namespace '$Namespace'. Apply infrastructure/kubernetes/ingestion-service/"

$service = $serviceJson | ConvertFrom-Json

Confirm-Condition `
    -Condition ($service.spec.type -eq "NodePort") `
    -SuccessMessage "Service '$ServiceName' is of type NodePort" `
    -FailureMessage "Service '$ServiceName' is of type '$($service.spec.type)', so it allocates no node port and is not reachable from outside the cluster" `
    -Permanent

$httpPort = @($service.spec.ports | Where-Object { $_.name -eq "http" })[0]

Confirm-Condition `
    -Condition ($null -ne $httpPort) `
    -SuccessMessage "Service '$ServiceName' exposes a port named 'http'" `
    -FailureMessage "Service '$ServiceName' has no port named 'http' (found: $(($service.spec.ports | ForEach-Object { $_.name }) -join ', '))" `
    -Permanent

Confirm-Condition `
    -Condition ([int] $httpPort.nodePort -eq $ExpectedNodePort) `
    -SuccessMessage "Node port is $ExpectedNodePort" `
    -FailureMessage "Node port is $($httpPort.nodePort), not the documented $ExpectedNodePort. The README address and this script both reference the pinned value" `
    -Permanent

Confirm-Condition `
    -Condition ([int] $httpPort.port -eq $ExpectedServicePort) `
    -SuccessMessage "Service port is $ExpectedServicePort" `
    -FailureMessage "Service port is $($httpPort.port), not $ExpectedServicePort" `
    -Permanent

Confirm-Condition `
    -Condition ("$($httpPort.targetPort)" -eq $ExpectedTargetPort) `
    -SuccessMessage "Traffic targets the container's named port '$ExpectedTargetPort'" `
    -FailureMessage "Service targets port '$($httpPort.targetPort)' instead of the container's named port '$ExpectedTargetPort'" `
    -Permanent

Confirm-Condition `
    -Condition ($service.spec.selector."app.kubernetes.io/name" -eq $AppLabel) `
    -SuccessMessage "Selector matches the '$AppLabel' pods" `
    -FailureMessage "Selector is app.kubernetes.io/name='$($service.spec.selector.'app.kubernetes.io/name')', which does not select the '$AppLabel' pods" `
    -Permanent

# --- Backends ----------------------------------------------------------------
# A NodePort with no ready backend still accepts a TCP connection on every node
# and then fails the request, so the endpoints are checked before the HTTP
# calls: it separates "nothing is deployed" from "routing is wrong".
Invoke-WithRetry -TimeoutSeconds $TimeoutSeconds -FailureMessage "Service '$ServiceName' never had a Ready endpoint." -Operation {
    $sliceJson = Invoke-KubectlChecked `
        -KubectlArgs @(
            "get", "endpointslice",
            "--namespace", $Namespace,
            "-l", "kubernetes.io/service-name=$ServiceName",
            "-o", "json"
        ) `
        -ErrorContext "Could not read the EndpointSlices of Service '$ServiceName'"

    $readyAddresses = @(($sliceJson | ConvertFrom-Json).items |
        ForEach-Object { $_.endpoints } |
        Where-Object { $_.conditions.ready -eq $true } |
        ForEach-Object { $_.addresses })

    Confirm-Condition `
        -Condition (@($readyAddresses).Count -ge 1) `
        -SuccessMessage "Service '$ServiceName' has $(@($readyAddresses).Count) Ready endpoint(s): $($readyAddresses -join ', ')" `
        -FailureMessage "Service '$ServiceName' has no Ready endpoint, so the node port has nothing to forward to"
}

# --- External address --------------------------------------------------------
# Candidates rather than one derived address: which one answers depends on how
# the cluster runs. A node's ExternalIP is reachable when it exists; a
# single-node cluster on this machine publishes the port on the host, so
# localhost works there and the node's InternalIP often does not.
if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $nodesJson = Invoke-KubectlChecked `
        -KubectlArgs @("get", "nodes", "-o", "json") `
        -ErrorContext "Could not list cluster nodes"

    $nodeAddresses = @(($nodesJson | ConvertFrom-Json).items | ForEach-Object { $_.status.addresses })
    $candidateHosts = @(
        @($nodeAddresses | Where-Object { $_.type -eq "ExternalIP" } | ForEach-Object { $_.address })
        @($nodeAddresses | Where-Object { $_.type -eq "InternalIP" } | ForEach-Object { $_.address })
        "localhost"
    ) | Select-Object -Unique

    $candidateUrls = @($candidateHosts | ForEach-Object { "http://$($_):$ExpectedNodePort" })
} else {
    $candidateUrls = @($BaseUrl.TrimEnd("/"))
}

# --- Reachability ------------------------------------------------------------
# The first request is retried: the candidates are tried in order and the pods
# may still be starting, so a single sweep would report an unreachable cluster
# for a rollout that is seconds from Ready.
$baseUrl = Invoke-WithRetry -TimeoutSeconds $TimeoutSeconds -FailureMessage "No node address answered $readinessPath on port $ExpectedNodePort. Tried: $($candidateUrls -join ', '). If the cluster's nodes are not routable from this machine (kind without extraPortMappings), pass -BaseUrl or use kubectl port-forward." -Operation {
    foreach ($candidate in $candidateUrls) {
        $body = $null
        try {
            $body = Invoke-TextGet -Uri "$candidate$readinessPath"
        } catch {
            # Not reachable on this address; the next candidate may be the one.
            $body = $null
        }

        if ($null -ne $body) {
            # Actuator's readiness probe group returns {"status":"UP"}. Anything
            # else answering on this port is not the ingestion-service, which is
            # a permanent failure rather than something to keep retrying.
            Confirm-Condition `
                -Condition ($body -match '"status"\s*:\s*"UP"') `
                -SuccessMessage "$candidate$readinessPath answered from outside the cluster with status UP" `
                -FailureMessage "$candidate$readinessPath answered, but the body was '$body' instead of a readiness state of UP. Something other than ingestion-service is serving port $ExpectedNodePort" `
                -Permanent

            return $candidate
        }
    }

    throw "None of the candidate addresses answered yet"
}

# --- Routing -----------------------------------------------------------------
# Reaching /readyz only proves the port reaches the application. This proves the
# ingest path is routed too: an empty body reaches TelemetryController and is
# rejected by bean validation with 400. A 404 here would mean the port reaches
# some other application, and a 405 that the route exists for another method.
#
# The 400 is an expected result here, not an error, but Invoke-WebRequest raises
# it as a terminating error whose type differs between Windows PowerShell and
# PowerShell 7. Invoke-HttpStatus normalizes that difference; see its comment in
# lib\PulseStreamValidation.psm1.
$rejectedStatus = Invoke-HttpStatus `
    -Uri "$baseUrl$ingestPath" `
    -Method Post `
    -Body "{}" `
    -ContentType "application/json"

Confirm-Condition `
    -Condition ($rejectedStatus -eq 400) `
    -SuccessMessage "POST $ingestPath with an empty body returned 400, so the request was routed to the ingest endpoint and rejected by validation" `
    -FailureMessage "POST $baseUrl$ingestPath with an empty body returned $rejectedStatus, not the expected 400. A 404 means port $ExpectedNodePort does not route to the ingestion API" `
    -Permanent

if ($IncludeIngestTest) {
    # Matches the telemetry event example in docs/architecture/event-schema.md.
    # This publishes a record to telemetry.events.raw, which is why it is opt-in.
    $event = @{
        eventId   = "evt_ext_probe_$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
        tenantId  = "factory_01"
        eventType = "telemetry.reading"
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        source    = "validate-ingestion-external-access"
        version   = "1.0"
        payload   = @{
            deviceId   = "sensor_1042"
            deviceType = "temperature-sensor"
            metric     = "temperature"
            value      = 28.4
            unit       = "C"
            location   = "zone-a"
        }
    } | ConvertTo-Json -Depth 5

    # Read through the same helper as the check above, so a rejected event
    # reports the status it actually returned instead of aborting on the
    # exception Invoke-WebRequest raises for a non-2xx response.
    $acceptedStatus = Invoke-HttpStatus `
        -Uri "$baseUrl$ingestPath" `
        -Method Post `
        -Body $event `
        -ContentType "application/json"

    Confirm-Condition `
        -Condition ($acceptedStatus -eq 202) `
        -SuccessMessage "POST $ingestPath with a valid event returned 202, so an external client can ingest telemetry" `
        -FailureMessage "POST $baseUrl$ingestPath with a valid event returned $acceptedStatus, not the expected 202" `
        -Permanent
}

Write-Host "[ok] ingestion-service external access validation completed against $baseUrl."
