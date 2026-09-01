# Regression coverage for Select-CorrelatedConsumerSpan
# (scripts/lib/PulseStreamTracing.psm1), the correlation step in
# validate-distributed-tracing.ps1 (#158). Synthetic Jaeger responses only - no
# cluster, no Jaeger, no network.
#
# The case this exists for is ordering. The event id is the Kafka message key,
# so a DLQ or replay record for the same event carries the SAME key: a key
# search returns both traces, and Jaeger's ordering within that response is not
# something a run controls. The validator used to take the first same-key
# consumer trace and check its destination topic afterwards, which fails the
# whole run whenever the DLQ trace happened to come back first - even though
# the raw-topic trace was in the very same response.
#
#   powershell -File scripts\tests\test-trace-correlation.ps1
#   pwsh -File scripts/tests/test-trace-correlation.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamTracing.psm1") -Force

$script:Failures = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory)] [string] $What,
        $Expected,
        $Actual
    )

    if ($Expected -eq $Actual) {
        Write-Host "[ok] $What -> $Actual"
        return
    }

    Write-Host "[fail] $What -> expected '$Expected', got '$Actual'"
    $script:Failures++
}

$eventId  = "6f1d4a90-0f2f-4f1a-9a0e-5d2b9c8e7a31"
$rawTopic = "telemetry.events.raw"
$dlqTopic = "telemetry.events.dlq"

# Jaeger renders span attributes as a flat {key, type, value} list, which is
# what the helpers scan, so the fixtures have to carry the same shape.
function New-Span {
    param(
        [Parameter(Mandatory)] [string] $SpanId,
        [Parameter(Mandatory)] [string] $OperationName,
        [hashtable] $Tags = @{}
    )

    [pscustomobject]@{
        spanID        = $SpanId
        operationName = $OperationName
        tags          = @($Tags.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{ key = $_.Key; type = "string"; value = $_.Value }
        })
    }
}

function New-ConsumerTrace {
    param(
        [Parameter(Mandatory)] [string] $TraceId,
        [Parameter(Mandatory)] [string] $Topic,
        [Parameter(Mandatory)] [string] $MessageKey
    )

    [pscustomobject]@{
        traceID = $TraceId
        spans   = @(
            New-Span -SpanId "$TraceId-01" -OperationName "$Topic receive" -Tags @{
                "span.kind"                   = "consumer"
                "messaging.kafka.message.key" = $MessageKey
                "messaging.destination.name"  = $Topic
                "messaging.system"            = "kafka"
            }
            New-Span -SpanId "$TraceId-02" -OperationName "TelemetryProcessingService.process" -Tags @{
                "span.kind" = "internal"
            }
        )
    }
}

$rawTrace = New-ConsumerTrace -TraceId "raw0001" -Topic $rawTopic -MessageKey $eventId
$dlqTrace = New-ConsumerTrace -TraceId "dlq0001" -Topic $dlqTopic -MessageKey $eventId

# --- The DLQ trace listed FIRST must not decide the verdict ------------------
# This is the ordering the old code failed on: it picked $traces[0], found
# telemetry.events.dlq on it, and reported the run as failed while the
# raw-topic trace sat second in the same response.
$match = Select-CorrelatedConsumerSpan `
    -Traces @($dlqTrace, $rawTrace) `
    -MessageKey $eventId `
    -DestinationTopic $rawTopic

Assert-Equal -What "DLQ trace first, raw trace second -> raw trace selected" `
    -Expected "raw0001" -Actual $match.Trace.traceID
Assert-Equal -What "the selected span is the raw-topic consumer span" `
    -Expected "raw0001-01" -Actual $match.Span.spanID
Assert-Equal -What "the selected span names $rawTopic" `
    -Expected $rawTopic `
    -Actual (Get-SpanTagValue -Span $match.Span -Key "messaging.destination.name")

# --- The reverse order is the same verdict -----------------------------------
# Order-independence is the property, so the case that already passed has to
# keep passing rather than the fix merely moving which order fails.
$match = Select-CorrelatedConsumerSpan `
    -Traces @($rawTrace, $dlqTrace) `
    -MessageKey $eventId `
    -DestinationTopic $rawTopic

Assert-Equal -What "raw trace first, DLQ trace second -> raw trace selected" `
    -Expected "raw0001" -Actual $match.Trace.traceID

# --- A DLQ trace alone is still not a pass -----------------------------------
# The topic check exists because the key alone cannot establish that the event
# travelled the normal ingest path.
$match = Select-CorrelatedConsumerSpan `
    -Traces @($dlqTrace) `
    -MessageKey $eventId `
    -DestinationTopic $rawTopic

Assert-Equal -What "DLQ trace alone -> no span selected" -Expected $null -Actual $match.Span
Assert-Equal -What "DLQ trace alone -> the topic seen is reported" `
    -Expected $dlqTopic -Actual ($match.ObservedDestinations -join ",")

# --- Another event's raw-topic trace is not this run's ------------------------
$otherTrace = New-ConsumerTrace -TraceId "other001" -Topic $rawTopic `
    -MessageKey "00000000-0000-0000-0000-000000000000"

$match = Select-CorrelatedConsumerSpan `
    -Traces @($otherTrace) `
    -MessageKey $eventId `
    -DestinationTopic $rawTopic

Assert-Equal -What "a different event's raw-topic trace -> no span selected" `
    -Expected $null -Actual $match.Span
Assert-Equal -What "a different event's trace is not reported as a wrong topic" `
    -Expected 0 -Actual $match.ObservedDestinations.Count

# --- Kind, key and topic must hold on ONE span -------------------------------
# Jaeger's `tags` query filters traces, not spans: a trace comes back when any
# one of its spans matched. A trace whose attributes are spread across two
# spans satisfies the search and must still be rejected.
$splitTrace = [pscustomobject]@{
    traceID = "split001"
    spans   = @(
        New-Span -SpanId "split001-01" -OperationName "$rawTopic receive" -Tags @{
            "span.kind"                  = "consumer"
            "messaging.destination.name" = $rawTopic
        }
        New-Span -SpanId "split001-02" -OperationName "TelemetryProcessingService.process" -Tags @{
            "span.kind"                   = "internal"
            "messaging.kafka.message.key" = $eventId
        }
    )
}

$match = Select-CorrelatedConsumerSpan `
    -Traces @($splitTrace) `
    -MessageKey $eventId `
    -DestinationTopic $rawTopic

Assert-Equal -What "key and topic on different spans -> no span selected" `
    -Expected $null -Actual $match.Span

# --- A producer span on the raw topic is not consumption ---------------------
# ingestion-service publishes under the same key to the same topic. Only a
# consumer span shows the processor received the record.
$producerTrace = [pscustomobject]@{
    traceID = "prod0001"
    spans   = @(
        New-Span -SpanId "prod0001-01" -OperationName "$rawTopic publish" -Tags @{
            "span.kind"                   = "producer"
            "messaging.kafka.message.key" = $eventId
            "messaging.destination.name"  = $rawTopic
        }
    )
}

$match = Select-CorrelatedConsumerSpan `
    -Traces @($producerTrace) `
    -MessageKey $eventId `
    -DestinationTopic $rawTopic

Assert-Equal -What "producer span on the raw topic -> no span selected" `
    -Expected $null -Actual $match.Span

# --- An empty response is a miss, not an error -------------------------------
# The caller retries on a miss, so no result at all has to come back the same
# shape rather than throwing.
$match = Select-CorrelatedConsumerSpan `
    -Traces @() `
    -MessageKey $eventId `
    -DestinationTopic $rawTopic

Assert-Equal -What "empty trace list -> no span selected" -Expected $null -Actual $match.Span
Assert-Equal -What "empty trace list -> nothing observed" -Expected 0 -Actual $match.ObservedDestinations.Count

# --- Test-TraceSpanKind reads the kind off individual spans ------------------
Assert-Equal -What "raw trace has a consumer span" `
    -Expected $true -Actual (Test-TraceSpanKind -Trace $rawTrace -Kind "consumer")
Assert-Equal -What "raw trace has no producer span" `
    -Expected $false -Actual (Test-TraceSpanKind -Trace $rawTrace -Kind "producer")

# --- An absent attribute is $null, not an empty string -----------------------
# Select-CorrelatedConsumerSpan distinguishes the two when it reports what it
# saw, so a span with no destination is not silently reported as one named "".
Assert-Equal -What "a tag the span does not carry reads as null" `
    -Expected $null `
    -Actual (Get-SpanTagValue -Span $rawTrace.spans[1] -Key "messaging.destination.name")

if ($script:Failures -gt 0) {
    throw "$script:Failures trace correlation check(s) failed."
}

Write-Host "[ok] Trace correlation behaves consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
