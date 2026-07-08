[CmdletBinding()]
param(
    [string] $IngestionBaseUrl = "http://localhost:8081",
    [string] $PrometheusBaseUrl = "http://localhost:9090",
    [string] $PrometheusJob = "ingestion-service",
    [int] $TimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"

function Invoke-JsonGet {
    param([string] $Uri)

    try {
        Invoke-RestMethod -Method Get -Uri $Uri -TimeoutSec 10
    } catch {
        throw "GET $Uri failed. $($_.Exception.Message)"
    }
}

function Invoke-TextGet {
    param([string] $Uri)

    try {
        (Invoke-WebRequest -Method Get -Uri $Uri -UseBasicParsing -TimeoutSec 10).Content
    } catch {
        throw "GET $Uri failed. $($_.Exception.Message)"
    }
}

function Confirm-Condition {
    param(
        [bool] $Condition,
        [string] $SuccessMessage,
        [string] $FailureMessage
    )

    if (-not $Condition) {
        throw $FailureMessage
    }

    Write-Host "[ok] $SuccessMessage"
}

function Invoke-PrometheusQuery {
    param([string] $Query)

    $encodedQuery = [System.Uri]::EscapeDataString($Query)
    $queryResult = Invoke-JsonGet "$PrometheusBaseUrl/api/v1/query?query=$encodedQuery"

    Confirm-Condition `
        -Condition ($queryResult.status -eq "success") `
        -SuccessMessage "Prometheus query succeeded: $Query" `
        -FailureMessage "Prometheus query failed: $Query"

    Confirm-Condition `
        -Condition ($queryResult.data.result.Count -gt 0) `
        -SuccessMessage "Prometheus returned data for: $Query" `
        -FailureMessage "Prometheus returned no data for: $Query"

    $queryResult.data.result
}

function Invoke-WithRetry {
    param(
        [scriptblock] $Operation,
        [string] $FailureMessage
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null

    do {
        try {
            return & $Operation
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    } while ((Get-Date) -lt $deadline)

    throw "$FailureMessage Last error: $lastError"
}

Write-Host "Validating ingestion-service metrics collection..."

$health = Invoke-WithRetry `
    -FailureMessage "ingestion-service health endpoint did not report UP within $TimeoutSeconds seconds." `
    -Operation {
        $result = Invoke-JsonGet "$IngestionBaseUrl/actuator/health"
        Confirm-Condition `
            -Condition ($result.status -eq "UP") `
            -SuccessMessage "ingestion-service health endpoint is UP" `
            -FailureMessage "ingestion-service health endpoint did not report UP"
        $result
    }

$metrics = Invoke-TextGet "$IngestionBaseUrl/actuator/prometheus"
$expectedServiceMetrics = @(
    "jvm_info",
    "process_uptime_seconds",
    "application_ready_time_seconds"
)

foreach ($metricName in $expectedServiceMetrics) {
    Confirm-Condition `
        -Condition ($metrics -match "(?m)^$metricName") `
        -SuccessMessage "service exposes $metricName" `
        -FailureMessage "service metrics endpoint is missing $metricName"
}

Invoke-WithRetry `
    -FailureMessage "Prometheus target for job $PrometheusJob was not healthy within $TimeoutSeconds seconds." `
    -Operation {
        $targets = Invoke-JsonGet "$PrometheusBaseUrl/api/v1/targets?state=active"
        $matchingTargets = @($targets.data.activeTargets | Where-Object { $_.labels.job -eq $PrometheusJob })

        Confirm-Condition `
            -Condition ($matchingTargets.Count -gt 0) `
            -SuccessMessage "Prometheus has an active $PrometheusJob target" `
            -FailureMessage "Prometheus does not have an active target for job $PrometheusJob"

        foreach ($target in $matchingTargets) {
            Confirm-Condition `
                -Condition ($target.health -eq "up") `
                -SuccessMessage "Prometheus target $($target.scrapeUrl) is up" `
                -FailureMessage "Prometheus target $($target.scrapeUrl) is $($target.health)"

            Confirm-Condition `
                -Condition ([string]::IsNullOrWhiteSpace($target.lastError)) `
                -SuccessMessage "Prometheus target $($target.scrapeUrl) has no scrape errors" `
                -FailureMessage "Prometheus target $($target.scrapeUrl) has scrape error: $($target.lastError)"
        }
    }

$upResult = Invoke-WithRetry `
    -FailureMessage "Prometheus did not report up{job=""$PrometheusJob""} within $TimeoutSeconds seconds." `
    -Operation {
        Invoke-PrometheusQuery "up{job=""$PrometheusJob""}"
    }

$upValues = @($upResult | ForEach-Object { $_.value[1] })
Confirm-Condition `
    -Condition ($upValues -contains "1") `
    -SuccessMessage "Prometheus reports up{job=""$PrometheusJob""} = 1" `
    -FailureMessage "Prometheus did not report up{job=""$PrometheusJob""} = 1"

foreach ($metricName in $expectedServiceMetrics) {
    Invoke-WithRetry `
        -FailureMessage "Prometheus did not return $metricName for job $PrometheusJob within $TimeoutSeconds seconds." `
        -Operation {
            Invoke-PrometheusQuery "$metricName{job=""$PrometheusJob""}"
        } | Out-Null
}

Write-Host "[ok] Prometheus metrics collection validation completed."
