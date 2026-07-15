[CmdletBinding()]
param(
    [string] $KafkaContainer = "pulsestream-kafka",
    [string] $BootstrapServer = "localhost:9092",
    [string] $RawTopic = "telemetry.events.raw",
    [string] $DlqTopic = "telemetry.events.dlq",
    # Actuator (health, dlqreplay) is served on the separate, loopback-bound management port (see
    # the telemetry-processor application.yml), not on the main service port.
    [string] $ProcessorManagementBaseUrl = "http://localhost:9083",
    # Path to the telemetry-processor log file the routing/replay-log assertions read. The
    # processor runs on the host, so its logs are read directly from disk rather than over HTTP.
    # Start the processor with a log file configured (e.g.
    # LOGGING_FILE_NAME=logs/telemetry-processor.log) so this file exists.
    [string] $ProcessorLogFile = (Join-Path $PSScriptRoot "..\services\telemetry-processor\logs\telemetry-processor.log"),
    # How long each Kafka read waits (ms) for the console consumer to drain the topic before it
    # times out and returns. The consumer prints a benign TimeoutException to stderr when idle for
    # this long; that is expected.
    [int] $ConsumeTimeoutMs = 8000,
    [int] $TimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force

# A DLQ record wrapping a *valid* TelemetryEvent: valid payload, so once replayed it processes
# successfully instead of failing again the same way. This simulates the realistic replay case
# described in the event replay strategy (docs/architecture/event-replay-strategy.md) -- an event
# that landed in the DLQ once (e.g. a since-fixed downstream issue) and is now safe to reprocess.
# It is published directly to the DLQ topic, standing in for that earlier failure, so the replay
# flow can be validated without depending on a specific non-replay failure mode.
function New-ReplayableDlqRecordJson {
    param([Parameter(Mandatory)] [string] $EventId)

    @{
        event = @{
            eventId   = $EventId
            tenantId  = "event-replay-validation"
            eventType = "telemetry.reading"
            timestamp = [DateTime]::UtcNow.ToString("o")
            source    = "validate-event-replay"
            version   = "1.0"
            payload   = @{
                deviceId   = "device-replay-validation"
                deviceType = "sensor"
                metric     = "temperature"
                value      = 21.5
                unit       = "celsius"
                location   = "validation-rig"
            }
        }
        errorMessage  = "simulated pre-fix failure for replay validation"
        sourceService = "telemetry-processor"
        failedAt      = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Compress -Depth 5
}

function Publish-DlqRecord {
    param([Parameter(Mandatory)] [string] $Json)

    # See validate-dlq-pipeline.ps1's Publish-RawEvent for why stderr is merged inside the
    # container's shell rather than redirected in PowerShell.
    $producerOutput = $Json | docker exec -i $KafkaContainer `
        sh -c "kafka-console-producer --bootstrap-server $BootstrapServer --topic $DlqTopic 2>&1"

    if ($LASTEXITCODE -ne 0) {
        $detail = (@($producerOutput) -join [Environment]::NewLine).Trim()
        throw "kafka-console-producer failed to publish to $DlqTopic (exit $LASTEXITCODE).$(if ($detail) { " $detail" })"
    }
}

function Read-RawRecordForEvent {
    param([Parameter(Mandatory)] [string] $EventId)

    # See validate-dlq-pipeline.ps1's Read-DlqRecordForEvent for why stderr is redirected inside
    # the container's shell rather than in PowerShell.
    $output = docker exec $KafkaContainer `
        sh -c "kafka-console-consumer --bootstrap-server $BootstrapServer --topic $RawTopic --from-beginning --timeout-ms $ConsumeTimeoutMs 2>/dev/null"

    foreach ($line in @($output)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $record = $line | ConvertFrom-Json
        } catch {
            continue
        }

        if ($record.eventId -eq $EventId) {
            return $record
        }
    }

    return $null
}

function Test-DlqRecordForEvent {
    param([Parameter(Mandatory)] [string] $EventId)

    $output = docker exec $KafkaContainer `
        sh -c "kafka-console-consumer --bootstrap-server $BootstrapServer --topic $DlqTopic --from-beginning --timeout-ms $ConsumeTimeoutMs 2>/dev/null"

    foreach ($line in @($output)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $record = $line | ConvertFrom-Json
        } catch {
            continue
        }

        $recordEventId = if ($null -ne $record.event) { $record.event.eventId } else { $null }
        if ($recordEventId -eq $EventId) {
            return $true
        }
    }

    return $false
}

function Get-ProcessorLogContent {
    if (-not (Test-Path -LiteralPath $ProcessorLogFile)) {
        return ""
    }

    $logContent = Get-Content -LiteralPath $ProcessorLogFile -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($logContent)) {
        return ""
    }

    return $logContent
}

function Test-ProcessorLogPattern {
    param([Parameter(Mandatory)] [string] $Pattern)

    $logContent = Get-ProcessorLogContent
    if ([string]::IsNullOrEmpty($logContent)) {
        return $false
    }

    return [bool]([regex]::IsMatch($logContent, $Pattern))
}

function Invoke-DlqReplayTrigger {
    param(
        [Parameter(Mandatory)] [string] $Action,
        [string[]] $EventIds
    )

    $body = if ($EventIds) { @{ eventIds = ($EventIds -join ",") } } else { @{} }

    try {
        Invoke-RestMethod -Method Post `
            -Uri "$ProcessorManagementBaseUrl/actuator/dlqreplay/$Action" `
            -ContentType "application/json" `
            -Body ($body | ConvertTo-Json -Compress) `
            -TimeoutSec 10
    } catch {
        throw "POST $ProcessorManagementBaseUrl/actuator/dlqreplay/$Action failed. $($_.Exception.Message)"
    }
}

function Get-DlqReplayStatus {
    Invoke-JsonGet "$ProcessorManagementBaseUrl/actuator/dlqreplay"
}

Write-Host "Validating event replay end to end..."

# 1. The telemetry-processor must be running before we seed a DLQ record, otherwise nothing is
#    there to trigger replay against.
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

# 2. Seed the DLQ with a record wrapping a valid event, standing in for an event that failed once
#    and is now safe to reprocess. The unique event id lets us locate it through the whole flow.
$eventId = [Guid]::NewGuid().ToString()
Publish-DlqRecord -Json (New-ReplayableDlqRecordJson -EventId $eventId)
Write-Host "[ok] Seeded DLQ record for replay (eventId: $eventId)"

# 3. Trigger a selective replay for exactly this event id via the dlqreplay actuator endpoint
#    (#125). This is the operator-triggered replay described in the event replay strategy -- there
#    is no automatic DLQ retry loop.
Invoke-DlqReplayTrigger -Action "start" -EventIds @($eventId) | Out-Null
Write-Host "[ok] Triggered DLQ replay for eventId $eventId"

# 4. Acceptance criterion: replay actually runs. The listener must report itself running with this
#    event selected shortly after the trigger.
Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "DLQ replay listener did not report running with eventId $eventId selected within $TimeoutSeconds seconds." `
    -Operation {
        $status = Get-DlqReplayStatus
        Confirm-Condition `
            -Condition ($status.running -and ($status.selectedEventIds -contains $eventId)) `
            -SuccessMessage "DLQ replay listener is running with eventId $eventId selected" `
            -FailureMessage "DLQ replay listener status does not yet show eventId $eventId selected and running"
    }

# 5. Acceptance criterion: logs confirm the replay flow picked up the selected DLQ record.
Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "No 'Replaying selected DLQ event' log line for eventId $eventId was found within $TimeoutSeconds seconds." `
    -Operation {
        Confirm-Condition `
            -Condition (Test-ProcessorLogPattern -Pattern "Replaying selected DLQ event.*eventId=$([regex]::Escape($eventId))") `
            -SuccessMessage "telemetry-processor logs confirm the DLQ event was picked up for replay (eventId $eventId)" `
            -FailureMessage "telemetry-processor logs do not yet confirm the DLQ event was picked up for replay"
    }

# 6. Acceptance criterion: the event is reprocessed. The replayed event must be republished onto
#    the raw topic (#124) so it re-enters the pipeline through the existing raw-topic consumer.
$rawRecord = Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Replayed event for eventId $eventId did not appear on '$RawTopic' within $TimeoutSeconds seconds." `
    -Operation {
        $record = Read-RawRecordForEvent -EventId $eventId
        Confirm-Condition `
            -Condition ($null -ne $record) `
            -SuccessMessage "Replayed event was republished to '$RawTopic' for eventId $eventId" `
            -FailureMessage "Replayed event is not yet present on '$RawTopic' for eventId $eventId"

        $record
    }

Confirm-Condition -Permanent `
    -Condition ($rawRecord.payload.deviceId -eq "device-replay-validation") `
    -SuccessMessage "Republished event preserved the original event payload" `
    -FailureMessage "Republished event payload does not match the original seeded event"

Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "No 'Republished replayed event' log line for eventId $eventId was found within $TimeoutSeconds seconds." `
    -Operation {
        Confirm-Condition `
            -Condition (Test-ProcessorLogPattern -Pattern "Republished replayed event to raw topic.*eventId=$([regex]::Escape($eventId))") `
            -SuccessMessage "telemetry-processor logs confirm the event was republished (eventId $eventId)" `
            -FailureMessage "telemetry-processor logs do not yet confirm republishing"
    }

# 7. Acceptance criterion: the event is successfully reprocessed, i.e. it does not fail again and
#    land back in the DLQ. The seeded event carries a valid payload, so a second DLQ record for the
#    same eventId would mean reprocessing failed rather than succeeded.
Confirm-Condition -Permanent `
    -Condition (-not (Test-DlqRecordForEvent -EventId $eventId)) `
    -SuccessMessage "Replayed event was not routed back to the DLQ; reprocessing succeeded" `
    -FailureMessage "Replayed event landed back in '$DlqTopic'; reprocessing did not succeed"

# 8. Acceptance criterion: no system failure. The processor must still be healthy, and the replay
#    listener must have stopped itself again once it drained the backlog it was started for
#    (DlqReplayService stops the listener on idle so it does not keep sweeping the DLQ).
Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "DLQ replay listener did not stop itself after draining the backlog within $TimeoutSeconds seconds." `
    -Operation {
        $status = Get-DlqReplayStatus
        Confirm-Condition `
            -Condition (-not $status.running) `
            -SuccessMessage "DLQ replay listener stopped itself after draining the backlog" `
            -FailureMessage "DLQ replay listener is still running"
    }

$health = Invoke-JsonGet "$ProcessorManagementBaseUrl/actuator/health"
Confirm-Condition -Permanent `
    -Condition ($health.status -eq "UP") `
    -SuccessMessage "telemetry-processor is still UP after the replay" `
    -FailureMessage "telemetry-processor is no longer UP after the replay (status: $($health.status))"

Write-Host "[ok] Event replay validation completed."
