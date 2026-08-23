[CmdletBinding()]
param(
    [string] $IngestionBaseUrl = "http://localhost:8081",
    [string] $JaegerBaseUrl = "http://localhost:16686",
    [string] $IngestionServiceName = "ingestion-service",
    [string] $ProcessorServiceName = "telemetry-processor",
    # The topic ingestion publishes to and the processor consumes from. The
    # consumer span is checked against it so a DLQ or replay record, which
    # carries the same message key, cannot satisfy the correlation.
    [string] $RawTopic = "telemetry.events.raw",
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

# Spans of one kind carrying a specific tag value. Jaeger's `tags` query filters
# TRACES - a trace comes back when any one of its spans matches - so a trace
# returned by a tag search is not on its own evidence that the span we care
# about is the one that carried the tag. Both conditions are re-checked here on
# the same span.
function Get-SpansWithTag {
    param(
        [Parameter(Mandatory)] $Trace,
        [Parameter(Mandatory)] [string] $Kind,
        [Parameter(Mandatory)] [string] $TagKey,
        [Parameter(Mandatory)] [string] $TagValue
    )
    @($Trace.spans | Where-Object {
        $span = $_
        (@($span.tags | Where-Object { $_.key -eq "span.kind" -and $_.value -eq $Kind }).Count -gt 0) -and
        (@($span.tags | Where-Object { $_.key -eq $TagKey -and "$($_.value)" -eq $TagValue }).Count -gt 0)
    })
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
#
#    Completeness is waited for inside the retry, not asserted after it. The
#    spans of one trace reach Jaeger in separate exported batches - the
#    collector's `batch` processor flushes on size or on its 5s timeout - so the
#    first result that comes back is routinely the server span alone. Asserting
#    against that reports "missing the Kafka producer span" for a trace that is
#    merely still arriving.
$requiredOperation = "TelemetryController.ingestTelemetry"
$ingestionTrace = Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "No complete ingestion-service trace was found for eventId $eventId within $TimeoutSeconds seconds." `
    -Operation {
        $traces = Invoke-JaegerTraceSearch `
            -ServiceName $IngestionServiceName `
            -Tags @{ "pulsestream.event.id" = $eventId }

        if ($traces.Count -eq 0) {
            throw "Ingestion trace is not yet visible in Jaeger for eventId $eventId"
        }

        $trace = $traces[0]

        $missing = @()
        if (@($trace.spans | ForEach-Object { $_.operationName }) -notcontains $requiredOperation) {
            $missing += "the $requiredOperation span"
        }
        if (-not (Test-SpanKind -Trace $trace -Kind "server")) { $missing += "the HTTP server span" }
        if (-not (Test-SpanKind -Trace $trace -Kind "producer")) { $missing += "the Kafka producer span" }

        if ($missing.Count -gt 0) {
            throw "Ingestion trace for eventId $eventId is still partial; missing $($missing -join ', ')"
        }

        $trace
    }

Confirm-Condition `
    -Condition ($ingestionTrace.spans.Count -gt 0) `
    -SuccessMessage "Ingestion trace is visible in Jaeger for eventId $eventId" `
    -FailureMessage "Ingestion trace is not visible in Jaeger for eventId $eventId"

$operationNames = @($ingestionTrace.spans | ForEach-Object { $_.operationName })

Confirm-Condition `
    -Condition ($operationNames -contains $requiredOperation) `
    -SuccessMessage "Ingestion trace contains the $requiredOperation span" `
    -FailureMessage "Ingestion trace is missing the $requiredOperation span"

Confirm-Condition `
    -Condition (Test-SpanKind -Trace $ingestionTrace -Kind "server") `
    -SuccessMessage "Ingestion trace contains the HTTP server span" `
    -FailureMessage "Ingestion trace is missing the HTTP server span"

Confirm-Condition `
    -Condition (Test-SpanKind -Trace $ingestionTrace -Kind "producer") `
    -SuccessMessage "Ingestion trace contains the Kafka producer span" `
    -FailureMessage "Ingestion trace is missing the Kafka producer span"

# 5. The telemetry-processor must independently participate in tracing. HTTP-only
#    context propagation means it does not yet share the ingestion trace id, so it
#    is asserted to register with Jaeger and to emit its own consumer trace for
#    the event we just published.
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

#    The consumer trace is correlated to THIS run's event. The processor does
#    not set `pulsestream.event.id` - that attribute is written by the ingestion
#    controller - but ingestion publishes each event under a Kafka message key
#    equal to its event id (KafkaProducerService.resolveMessageKey), and the
#    spring-kafka instrumentation records that key on the consumer span as
#    `messaging.kafka.message.key`. That is the handle: it identifies the exact
#    record this run produced.
#
#    Accepting any recent consumer trace instead would pass on traffic this run
#    never generated - a neighbouring producer, a replayed DLQ record, or a
#    trace still in the lookback window from an earlier run - and would report
#    the processor as tracing correctly even when the event under test was never
#    consumed at all.
$processorTrace = Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "No telemetry-processor consumer trace was found for eventId $eventId within $TimeoutSeconds seconds. The processor consumes from Kafka, so this lags the ingestion trace by the consumer poll and any partition backlog." `
    -Operation {
        $processorTraces = Invoke-JaegerTraceSearch `
            -ServiceName $ProcessorServiceName `
            -Tags @{ "messaging.kafka.message.key" = $eventId }

        Confirm-Condition `
            -Condition ($processorTraces.Count -gt 0) `
            -SuccessMessage "telemetry-processor trace is visible in Jaeger for eventId $eventId" `
            -FailureMessage "telemetry-processor trace is not yet visible in Jaeger for eventId $eventId"

        $correlated = @($processorTraces | Where-Object {
            (Get-SpansWithTag -Trace $_ -Kind "consumer" `
                -TagKey "messaging.kafka.message.key" -TagValue $eventId).Count -gt 0
        })

        Confirm-Condition `
            -Condition ($correlated.Count -gt 0) `
            -SuccessMessage "telemetry-processor trace contains a Kafka consumer span keyed to eventId $eventId" `
            -FailureMessage "telemetry-processor trace is missing a Kafka consumer span keyed to eventId $eventId"

        $correlated[0]
    }

# The record the consumer span names must be the raw telemetry topic. A DLQ or
# replay record carries the same message key, so the key alone does not
# establish that the event travelled the normal ingest path.
$consumerSpan = (Get-SpansWithTag -Trace $processorTrace -Kind "consumer" `
    -TagKey "messaging.kafka.message.key" -TagValue $eventId)[0]

$destination = $consumerSpan.tags |
    Where-Object { $_.key -eq "messaging.destination.name" } |
    Select-Object -First 1 -ExpandProperty value

Confirm-Condition `
    -Condition ($destination -eq $RawTopic) `
    -SuccessMessage "telemetry-processor consumed eventId $eventId from $RawTopic" `
    -FailureMessage "telemetry-processor consumer span for eventId $eventId names destination '$destination', not '$RawTopic'"

Write-Host "[ok] Distributed tracing validation completed."
