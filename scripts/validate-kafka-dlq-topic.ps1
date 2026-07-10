[CmdletBinding()]
param(
    [string] $KafkaContainer = "pulsestream-kafka",
    [string] $BootstrapServer = "localhost:9092",
    [string] $TopicName = "telemetry.events.dlq",
    [int] $ExpectedPartitions = 1,
    [int] $ExpectedReplicationFactor = 1,
    [int] $TimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force

function Invoke-KafkaTopicsDescribe {
    param([string] $Topic)

    $output = docker exec $KafkaContainer kafka-topics `
        --bootstrap-server $BootstrapServer `
        --describe --topic $Topic 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "kafka-topics --describe --topic $Topic failed. $output"
    }

    $output
}

Write-Host "Validating Kafka DLQ topic '$TopicName'..."

# 1. Acceptance criterion: the topic exists and is visible via the Kafka CLI.
#    Creation happens in the kafka-init container on startup, so retry until
#    it has had a chance to run.
$describeOutput = Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Kafka topic '$TopicName' was not visible within $TimeoutSeconds seconds." `
    -Operation {
        Invoke-KafkaTopicsDescribe -Topic $TopicName
    }

$describeText = $describeOutput -join "`n"

Confirm-Condition -Permanent `
    -Condition ($describeText -match "Topic:\s*$([regex]::Escape($TopicName))") `
    -SuccessMessage "Kafka topic '$TopicName' exists" `
    -FailureMessage "Kafka topic '$TopicName' was not found in describe output: $describeText"

# 2. Acceptance criterion: partitions and replication are configured per the
#    naming-convention doc (docs/architecture/topics.md).
$partitionCountMatch = [regex]::Match($describeText, "PartitionCount:\s*(\d+)")
Confirm-Condition -Permanent `
    -Condition ($partitionCountMatch.Success -and [int]$partitionCountMatch.Groups[1].Value -eq $ExpectedPartitions) `
    -SuccessMessage "Kafka topic '$TopicName' has $ExpectedPartitions partition(s)" `
    -FailureMessage "Kafka topic '$TopicName' does not have $ExpectedPartitions partition(s): $describeText"

$replicationFactorMatch = [regex]::Match($describeText, "ReplicationFactor:\s*(\d+)")
Confirm-Condition -Permanent `
    -Condition ($replicationFactorMatch.Success -and [int]$replicationFactorMatch.Groups[1].Value -eq $ExpectedReplicationFactor) `
    -SuccessMessage "Kafka topic '$TopicName' has replication factor $ExpectedReplicationFactor" `
    -FailureMessage "Kafka topic '$TopicName' does not have replication factor $ExpectedReplicationFactor $describeText"

# 3. Acceptance criterion: the topic follows the <domain>.<entity>.dlq naming
#    convention rather than living in a separate DLQ namespace.
Confirm-Condition -Permanent `
    -Condition ($TopicName -match "^[a-z0-9-]+\.[a-z0-9-]+\.dlq$") `
    -SuccessMessage "Kafka topic '$TopicName' follows the <domain>.<entity>.dlq naming convention" `
    -FailureMessage "Kafka topic '$TopicName' does not follow the <domain>.<entity>.dlq naming convention"

Write-Host "[ok] Kafka DLQ topic validation completed."
