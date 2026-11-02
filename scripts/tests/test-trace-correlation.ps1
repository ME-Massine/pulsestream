# Regression coverage for Select-CorrelatedConsumerSpan
# (scripts/lib/PulseStreamTracing.psm1), the correlation step in
# both tracing validators (#158/#159). Synthetic Jaeger responses only - no
# cluster, no Jaeger, no network.
#
# Each validator generates one event for a fresh device. Its tenant/device key
# identifies that event; replay can reuse the SAME ordering key. A key
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

$messageKey = "v1:dGVuYW50:ZGV2aWNlLXJ1bi0x"
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

$rawTrace = New-ConsumerTrace -TraceId "raw0001" -Topic $rawTopic -MessageKey $messageKey
$dlqTrace = New-ConsumerTrace -TraceId "dlq0001" -Topic $dlqTopic -MessageKey $messageKey

# --- The DLQ trace listed FIRST must not decide the verdict ------------------
# This is the ordering the old code failed on: it picked $traces[0], found
# telemetry.events.dlq on it, and reported the run as failed while the
# raw-topic trace sat second in the same response.
$match = Select-CorrelatedConsumerSpan `
    -Traces @($dlqTrace, $rawTrace) `
    -MessageKey $messageKey `
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
    -MessageKey $messageKey `
    -DestinationTopic $rawTopic

Assert-Equal -What "raw trace first, DLQ trace second -> raw trace selected" `
    -Expected "raw0001" -Actual $match.Trace.traceID

# --- A DLQ trace alone is still not a pass -----------------------------------
# The topic check exists because the key alone cannot establish that the event
# travelled the normal ingest path.
$match = Select-CorrelatedConsumerSpan `
    -Traces @($dlqTrace) `
    -MessageKey $messageKey `
    -DestinationTopic $rawTopic

Assert-Equal -What "DLQ trace alone -> no span selected" -Expected $null -Actual $match.Span
Assert-Equal -What "DLQ trace alone -> the topic seen is reported" `
    -Expected $dlqTopic -Actual ($match.ObservedDestinations -join ",")

# --- Another event's raw-topic trace is not this run's ------------------------
$otherTrace = New-ConsumerTrace -TraceId "other001" -Topic $rawTopic `
    -MessageKey "v1:dGVuYW50:ZGV2aWNlLXJ1bi0y"

$match = Select-CorrelatedConsumerSpan `
    -Traces @($otherTrace) `
    -MessageKey $messageKey `
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
            "messaging.kafka.message.key" = $messageKey
        }
    )
}

$match = Select-CorrelatedConsumerSpan `
    -Traces @($splitTrace) `
    -MessageKey $messageKey `
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
            "messaging.kafka.message.key" = $messageKey
            "messaging.destination.name"  = $rawTopic
        }
    )
}

$match = Select-CorrelatedConsumerSpan `
    -Traces @($producerTrace) `
    -MessageKey $messageKey `
    -DestinationTopic $rawTopic

Assert-Equal -What "producer span on the raw topic -> no span selected" `
    -Expected $null -Actual $match.Span

# --- An empty response is a miss, not an error -------------------------------
# The caller retries on a miss, so no result at all has to come back the same
# shape rather than throwing.
$match = Select-CorrelatedConsumerSpan `
    -Traces @() `
    -MessageKey $messageKey `
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

# --- The PowerShell key encoder follows the shared Java contract vectors -----
$vectors = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot "../../contracts/ordering-keys.json") | ConvertFrom-Json
foreach ($vector in $vectors) {
    Assert-Equal -What "shared ordering key vector $($vector.tenantId)/$($vector.deviceId)" `
        -Expected $vector.key `
        -Actual (Get-TelemetryOrderingKey -TenantId $vector.tenantId -DeviceId $vector.deviceId)
}
# Non-ASCII UTF-8, URL-safe alphabet and omitted padding, expressed without a
# source-file encoding dependency on Windows PowerShell 5.1.
Assert-Equal -What "UTF-8 URL-safe ordering key" -Expected "v1:4KC-:4KC_" `
    -Actual (Get-TelemetryOrderingKey -TenantId ([string][char]0x083e) -DeviceId ([string][char]0x083f))

# Exercise the actual request construction and consumer retry in BOTH scripts.
# Extract only those AST statements; health checks, POSTs, cluster setup and
# cleanup are not executed. A single-attempt retry stub exposes misses directly.
function Invoke-WithRetry {
    param($TimeoutSeconds, $FailureMessage, [scriptblock] $Operation)
    & $Operation
}
function Invoke-JaegerTraceSearch {
    param($ServiceName, $StartMicros, [hashtable] $Tags)
    Assert-Equal -What "$validator searches the processor service" `
        -Expected "telemetry-processor" -Actual $ServiceName
    Assert-Equal -What "$validator queries the generated tenant/device key" `
        -Expected $expectedKey -Actual $Tags["messaging.kafka.message.key"]
    # Return distractors too: Jaeger filters whole traces, so the validator must
    # still match kind, key and topic together on an individual span.
    $fixtureTraces
}

foreach ($validator in @("validate-distributed-tracing.ps1", "validate-observability-stack.ps1")) {
    $validatorPath = Join-Path $PSScriptRoot "../$validator"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($validatorPath, [ref]$null, [ref]$null)
    $assignments = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true))
    $requestStatements = @($assignments | Where-Object {
        $_.Left.Extent.Text -in @('$eventId', '$tenantId', '$deviceId', '$messageKey', '$requestBody')
    } | Sort-Object { $_.Extent.StartOffset })
    Assert-Equal -What "$validator has a complete request stimulus" -Expected 5 -Actual $requestStatements.Count
    $requestCode = [scriptblock]::Create(($requestStatements.Extent.Text -join "`n"))
    . $requestCode
    $firstRequest = $requestBody | ConvertFrom-Json
    . $requestCode
    $secondRequest = $requestBody | ConvertFrom-Json
    Assert-Equal -What "$validator generates a fresh device each run" -Expected $false `
        -Actual ($firstRequest.payload.deviceId -eq $secondRequest.payload.deviceId)
    Assert-Equal -What "$validator retains event-specific identity in the device" -Expected $true `
        -Actual ($secondRequest.payload.deviceId.EndsWith($secondRequest.eventId))
    $expectedKey = Get-TelemetryOrderingKey -TenantId $secondRequest.tenantId -DeviceId $secondRequest.payload.deviceId
    $previousKey = Get-TelemetryOrderingKey -TenantId $firstRequest.tenantId -DeviceId $firstRequest.payload.deviceId
    $legacyTrace = New-ConsumerTrace -TraceId "legacy" -Topic $rawTopic -MessageKey $eventId
    $previousTrace = New-ConsumerTrace -TraceId "previous" -Topic $rawTopic -MessageKey $previousKey
    $replayTrace = New-ConsumerTrace -TraceId "replay" -Topic $dlqTopic -MessageKey $expectedKey
    $currentTrace = New-ConsumerTrace -TraceId "current" -Topic $rawTopic -MessageKey $expectedKey
    $fixtureTraces = @($legacyTrace, $previousTrace, $replayTrace, $currentTrace)
    $ProcessorServiceName = $ProcessorService = "telemetry-processor"
    $TimeoutSeconds = 1
    $searchStartMicros = 0
    $consumerStatement = @($assignments | Where-Object { $_.Left.Extent.Text -eq '$correlation' })
    Assert-Equal -What "$validator has one consumer correlation" -Expected 1 -Actual $consumerStatement.Count
    $consumerCode = [scriptblock]::Create($consumerStatement[0].Extent.Text)
    . $consumerCode
    Assert-Equal -What "$validator selects current raw event after distractors" `
        -Expected "current" -Actual $correlation.Trace.traceID

    $fixtureTraces = @($legacyTrace, $previousTrace, $replayTrace)
    $rejected = $false
    try { . $consumerCode } catch { $rejected = $true }
    Assert-Equal -What "$validator rejects old event IDs, previous runs and wrong topics" `
        -Expected $true -Actual $rejected
}

if ($script:Failures -gt 0) {
    throw "$script:Failures trace correlation check(s) failed."
}

Write-Host "[ok] Trace correlation behaves consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
