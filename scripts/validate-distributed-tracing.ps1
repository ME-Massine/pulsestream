[CmdletBinding()]
param(
    [string] $IngestionBaseUrl = "http://localhost:8081",
    [string] $JaegerBaseUrl = "http://localhost:16686",
    [string] $IngestionServiceName = "ingestion-service",
    [string] $ProcessorServiceName = "telemetry-processor",
    # How far back (seconds) the Jaeger searches look. The window also bounds how
    # long we wait for the processor to consume the generated event and emit its
    # own trace.
    [int] $LookbackSeconds = 300,
    [int] $TimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force

# Fixed lower bound captured before we send traffic so the generated spans always
# fall inside the search window. The upper bound is recomputed per attempt so
# just-emitted spans are included.
$searchStartMicros = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - ($LookbackSeconds * 1000)) * 1000

function Get-TraceWindowEndMicros {
    [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) * 1000
}

function Invoke-JaegerTraceSearch {
    param(
        [Parameter(Mandatory)] [string] $ServiceName,
        [hashtable] $Tags = @{},
        [int] $Limit = 20
    )

    $query = "service=$([System.Uri]::EscapeDataString($ServiceName))" +
             "&start=$searchStartMicros&end=$(Get-TraceWindowEndMicros)&limit=$Limit"

    if ($Tags.Count -gt 0) {
        $tagsJson = ($Tags | ConvertTo-Json -Compress)
        $query += "&tags=$([System.Uri]::EscapeDataString($tagsJson))"
    }

    $result = Invoke-JsonGet "$JaegerBaseUrl/api/traces?$query"
    @($result.data)
}

function Get-TraceServiceNames {
    param([Parameter(Mandatory)] $Trace)
    @($Trace.processes.PSObject.Properties | ForEach-Object { $_.Value.serviceName })
}

function Test-SpanKind {
    param(
        [Parameter(Mandatory)] $Trace,
        [Parameter(Mandatory)] [string] $Kind
    )
    [bool](@($Trace.spans | Where-Object {
        $_.tags | Where-Object { $_.key -eq "span.kind" -and $_.value -eq $Kind }
    }).Count)
}

Write-Host "Validating distributed tracing end to end..."

# 1. The ingestion-service must be accepting traffic before we generate a request.
Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "ingestion-service health endpoint did not report UP within $TimeoutSeconds seconds." `
    -Operation {
        $result = Invoke-JsonGet "$IngestionBaseUrl/actuator/health"
        Confirm-Condition `
            -Condition ($result.status -eq "UP") `
            -SuccessMessage "ingestion-service health endpoint is UP" `
            -FailureMessage "ingestion-service health endpoint did not report UP"
    }

# 2. Jaeger must be reachable through its query API before we rely on it.
Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Jaeger query API was not reachable within $TimeoutSeconds seconds." `
    -Operation {
        $services = Invoke-JsonGet "$JaegerBaseUrl/api/services"
        Confirm-Condition `
            -Condition ($null -ne $services.data) `
            -SuccessMessage "Jaeger query API is reachable" `
            -FailureMessage "Jaeger query API did not return a service list"
    }

# 3. Generate a request. The event id is unique so we can locate the exact trace
#    it produces; the controller records it on the span as `pulsestream.event.id`.
$eventId = [Guid]::NewGuid().ToString()
$requestBody = @{
    eventId   = $eventId
    tenantId  = "trace-validation"
    eventType = "telemetry.reading"
    timestamp = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    source    = "validate-distributed-tracing"
    version   = "1.0"
    payload   = @{
        deviceId   = "trace-validation-device"
        deviceType = "temperature-sensor"
        metric     = "temperature"
        value      = 21.5
        unit       = "celsius"
        location   = "validation-lab"
    }
} | ConvertTo-Json -Depth 5

try {
    Invoke-RestMethod -Method Post -Uri "$IngestionBaseUrl/api/v1/events" `
        -ContentType "application/json" -Body $requestBody -TimeoutSec 10 | Out-Null
} catch {
    throw "Failed to POST telemetry event to ingestion-service. $($_.Exception.Message)"
}
Write-Host "[ok] Generated telemetry request (eventId: $eventId)"

# 4. The ingestion trace for this request must be complete: the HTTP entry span,
#    the application span, and the Kafka publish span must all be present. Search
#    by the event id tag so we assert against the exact trace we generated.
$ingestionTrace = Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "No ingestion-service trace was found for eventId $eventId within $TimeoutSeconds seconds." `
    -Operation {
        $traces = Invoke-JaegerTraceSearch `
            -ServiceName $IngestionServiceName `
            -Tags @{ "pulsestream.event.id" = $eventId }

        Confirm-Condition `
            -Condition ($traces.Count -gt 0) `
            -SuccessMessage "Ingestion trace is visible in Jaeger for eventId $eventId" `
            -FailureMessage "Ingestion trace is not yet visible in Jaeger for eventId $eventId"

        $traces[0]
    }

$operationNames = @($ingestionTrace.spans | ForEach-Object { $_.operationName })

Confirm-Condition `
    -Condition ($operationNames -contains "TelemetryController.ingestTelemetry") `
    -SuccessMessage "Ingestion trace contains the TelemetryController.ingestTelemetry span" `
    -FailureMessage "Ingestion trace is missing the TelemetryController.ingestTelemetry span"

Confirm-Condition `
    -Condition (Test-SpanKind -Trace $ingestionTrace -Kind "server") `
    -SuccessMessage "Ingestion trace contains the HTTP server span" `
    -FailureMessage "Ingestion trace is missing the HTTP server span"

Confirm-Condition `
    -Condition (Test-SpanKind -Trace $ingestionTrace -Kind "producer") `
    -SuccessMessage "Ingestion trace contains the Kafka producer span" `
    -FailureMessage "Ingestion trace is missing the Kafka producer span"

# 5. The telemetry-processor must independently participate in tracing. HTTP-only
#    context propagation means it does not yet share the ingestion trace id, so we
#    assert it registers with Jaeger and emits its own consumer trace after
#    consuming the event we just published.
Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "telemetry-processor did not register with Jaeger within $TimeoutSeconds seconds." `
    -Operation {
        $services = Invoke-JsonGet "$JaegerBaseUrl/api/services"
        Confirm-Condition `
            -Condition (@($services.data) -contains $ProcessorServiceName) `
            -SuccessMessage "telemetry-processor is registered as a Jaeger service" `
            -FailureMessage "telemetry-processor is not yet registered as a Jaeger service"
    }

Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "No telemetry-processor consumer trace was found within $TimeoutSeconds seconds." `
    -Operation {
        $processorTraces = Invoke-JaegerTraceSearch -ServiceName $ProcessorServiceName

        Confirm-Condition `
            -Condition ($processorTraces.Count -gt 0) `
            -SuccessMessage "telemetry-processor traces are visible in Jaeger" `
            -FailureMessage "telemetry-processor traces are not yet visible in Jaeger"

        $hasConsumerSpan = $processorTraces | Where-Object { Test-SpanKind -Trace $_ -Kind "consumer" }
        Confirm-Condition `
            -Condition ([bool]$hasConsumerSpan) `
            -SuccessMessage "telemetry-processor trace contains a Kafka consumer span" `
            -FailureMessage "telemetry-processor trace is missing a Kafka consumer span"
    }

Write-Host "[ok] Distributed tracing validation completed."
