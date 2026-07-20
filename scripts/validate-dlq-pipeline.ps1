[CmdletBinding()]
param(
    [string] $KafkaContainer = "pulsestream-kafka",
    [string] $BootstrapServer = "localhost:9092",
    [string] $RawTopic = "telemetry.events.raw",
    [string] $DlqTopic = "telemetry.events.dlq",
    # Actuator (health) is served on the separate, loopback-bound management port (see the
    # telemetry-processor application.yml), not on the main service port.
    [string] $ProcessorManagementBaseUrl = "http://localhost:9083",
    [string] $ProcessorSourceService = "telemetry-processor",
    # Path to the telemetry-processor log file the routing-log assertion reads.
    # The processor runs on the host, so its logs are read directly from disk
    # rather than over HTTP. Start the processor with a log file configured
    # (e.g. LOGGING_FILE_NAME=logs/telemetry-processor.log) so this file exists.
    # Default resolves to services/telemetry-processor/logs/telemetry-processor.log.
    [string] $ProcessorLogFile = (Join-Path $PSScriptRoot "..\services\telemetry-processor\logs\telemetry-processor.log"),
    # How long each DLQ read waits (ms) for the console consumer to drain the
    # topic before it times out and returns. The consumer prints a benign
    # TimeoutException to stderr when idle for this long; that is expected.
    [int] $ConsumeTimeoutMs = 8000,
    [int] $TimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force

# A telemetry event that passes JSON deserialization into the processor's
# TelemetryEvent record but fails processing: the payload is null, so the
# normalization step's non-null assertion throws and the consumer routes the
# event to the DLQ. This is the deterministic way to exercise the processing
# failure path end to end, because valid events accepted by ingestion cannot
# reach the processor with a null payload.
function New-PoisonEventJson {
    param([Parameter(Mandatory)] [string] $EventId)

    @{
        eventId   = $EventId
        tenantId  = "dlq-validation"
        eventType = "telemetry.reading"
        timestamp = [DateTime]::UtcNow.ToString("o")
        source    = "validate-dlq-pipeline"
        version   = "1.0"
        payload   = $null
    } | ConvertTo-Json -Compress -Depth 5
}

function Publish-RawEvent {
    param([Parameter(Mandatory)] [string] $Json)

    # kafka-console-producer reads one message per stdin line, so the value must
    # be single-line (compact) JSON. Piping the string in closes stdin after the
    # line, which produces exactly one record.
    #
    # stderr is merged into stdout *inside the container* (the `2>&1` runs in the
    # container's shell, not in PowerShell). This keeps any broker error in
    # $producerOutput for diagnostics while ensuring no native stderr reaches
    # PowerShell: under Windows PowerShell 5.1 with $ErrorActionPreference =
    # "Stop", native command stderr surfaced to PowerShell is promoted to a
    # terminating NativeCommandError, which would make publishing fail spuriously.
    $producerOutput = $Json | docker exec -i $KafkaContainer `
        sh -c "kafka-console-producer --bootstrap-server $BootstrapServer --topic $RawTopic 2>&1"

    if ($LASTEXITCODE -ne 0) {
        $detail = (@($producerOutput) -join [Environment]::NewLine).Trim()
        throw "kafka-console-producer failed to publish to $RawTopic (exit $LASTEXITCODE).$(if ($detail) { " $detail" })"
    }
}

function Read-DlqRecordForEvent {
    param([Parameter(Mandatory)] [string] $EventId)

    # Read the DLQ from the beginning and stop after an idle window. The console
    # consumer prints an expected idle TimeoutException to stderr once it drains
    # the topic; only the message values on stdout are inspected.
    #
    # stderr is redirected to /dev/null *inside the container* (the `2>/dev/null`
    # runs in the container's shell, not in PowerShell) so it never reaches
    # PowerShell. Under Windows PowerShell 5.1 with $ErrorActionPreference =
    # "Stop", redirecting native stderr in PowerShell (2>$null) promotes that
    # benign TimeoutException to a terminating error, which would make this read
    # report a false negative against a perfectly healthy DLQ pipeline.
    $output = docker exec $KafkaContainer `
        sh -c "kafka-console-consumer --bootstrap-server $BootstrapServer --topic $DlqTopic --from-beginning --timeout-ms $ConsumeTimeoutMs 2>/dev/null"

    foreach ($line in @($output)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $record = $line | ConvertFrom-Json
        } catch {
            # Non-JSON lines are not DLQ records we care about.
            continue
        }

        # Defensively locate the nested event id: a record missing the `event`
        # object (or a future envelope shape) simply isn't the one we published,
        # so skip it rather than dereferencing a null property.
        $recordEventId = if ($null -ne $record.event) { $record.event.eventId } else { $null }
        if ($recordEventId -eq $EventId) {
            return $record
        }
    }

    return $null
}

function Test-ProcessorRoutingLog {
    param([Parameter(Mandatory)] [string] $EventId)

    # The processor emits a WARN routing log line the moment it reroutes a failed
    # event: "Routed failed telemetry event to DLQ ... eventId=<id> reason=...".
    # It runs on the host, so we read its log file directly from disk rather than
    # exposing logs over an unauthenticated actuator endpoint. The file exists
    # only if the processor was started with a log file configured (see
    # -ProcessorLogFile). We match the routing message and the specific eventId on
    # the same line so the assertion is scoped to the event this run produced.
    if (-not (Test-Path -LiteralPath $ProcessorLogFile)) {
        return $false
    }

    $logContent = Get-Content -LiteralPath $ProcessorLogFile -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($logContent)) {
        return $false
    }

    $pattern = "Routed failed telemetry event to DLQ.*eventId=$([regex]::Escape($EventId))"
    return [bool]([regex]::IsMatch($logContent, $pattern))
}

Write-Host "Validating DLQ pipeline end to end..."

# 1. The telemetry-processor must be running and consuming before we publish the
#    poison event, otherwise nothing routes it to the DLQ.
Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "telemetry-processor health endpoint did not report UP within $TimeoutSeconds seconds." `
    -Operation {
        $result = Invoke-JsonGet "$ProcessorManagementBaseUrl/actuator/health"
        Confirm-Condition `
            -Condition ($result.status -eq "UP") `
            -SuccessMessage "telemetry-processor health endpoint is UP" `
            -FailureMessage "telemetry-processor health endpoint did not report UP"
    }

# 2. Publish a poison event to the raw topic. The unique event id lets us locate
#    the exact DLQ record it produces.
$eventId = [Guid]::NewGuid().ToString()
Publish-RawEvent -Json (New-PoisonEventJson -EventId $eventId)
Write-Host "[ok] Published poison telemetry event to '$RawTopic' (eventId: $eventId)"

# 3. Acceptance criterion: the failed event appears in the DLQ topic. Retry
#    because the processor consumes and reroutes asynchronously.
$dlqRecord = Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "No DLQ record for eventId $eventId appeared in '$DlqTopic' within $TimeoutSeconds seconds." `
    -Operation {
        $record = Read-DlqRecordForEvent -EventId $eventId
        Confirm-Condition `
            -Condition ($null -ne $record) `
            -SuccessMessage "Failed event is present in DLQ topic '$DlqTopic' for eventId $eventId" `
            -FailureMessage "Failed event is not yet present in DLQ topic '$DlqTopic' for eventId $eventId"

        $record
    }

# 4. Acceptance criterion: the routing metadata confirms the processor rerouted
#    the event. The DLQ envelope records which producer emitted it and why, which
#    is the machine-readable counterpart to the processor's routing log line.
Confirm-Condition -Permanent `
    -Condition ($dlqRecord.sourceService -eq $ProcessorSourceService) `
    -SuccessMessage "DLQ record was routed by '$ProcessorSourceService'" `
    -FailureMessage "DLQ record sourceService was '$($dlqRecord.sourceService)', expected '$ProcessorSourceService'"

Confirm-Condition -Permanent `
    -Condition ([bool]$dlqRecord.errorMessage) `
    -SuccessMessage "DLQ record carries a failure reason: $($dlqRecord.errorMessage)" `
    -FailureMessage "DLQ record is missing the errorMessage failure reason"

# 5. Acceptance criterion: logs confirm routing. The processor must have logged
#    its successful DLQ-routing message for this exact event. Retry because the
#    log write and the on-disk log file read are independent of the DLQ topic
#    read above and may lag slightly behind it.
Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "No routing log line for eventId $eventId was found in the telemetry-processor logfile within $TimeoutSeconds seconds." `
    -Operation {
        Confirm-Condition `
            -Condition (Test-ProcessorRoutingLog -EventId $eventId) `
            -SuccessMessage "telemetry-processor logs confirm the event was routed to the DLQ (eventId $eventId)" `
            -FailureMessage "telemetry-processor logs do not yet confirm routing for eventId $eventId"
    }

# 6. Acceptance criterion: no system crash. The processor must still be healthy
#    after handling the failed event.
$health = Invoke-JsonGet "$ProcessorManagementBaseUrl/actuator/health"
Confirm-Condition -Permanent `
    -Condition ($health.status -eq "UP") `
    -SuccessMessage "telemetry-processor is still UP after routing the failed event" `
    -FailureMessage "telemetry-processor is no longer UP after routing the failed event (status: $($health.status))"

Write-Host "[ok] DLQ pipeline validation completed."
