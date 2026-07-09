[CmdletBinding()]
param(
    [string] $GrafanaBaseUrl = "http://localhost:3000",
    [string] $DatasourceUid = "prometheus",
    [string] $GrafanaUser = "admin",
    [string] $GrafanaPassword = "admin",
    [int] $TimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"

$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("${GrafanaUser}:${GrafanaPassword}"))
}

function Invoke-JsonGet {
    param([string] $Uri)

    try {
        Invoke-RestMethod -Method Get -Uri $Uri -Headers $authHeader -TimeoutSec 10
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

Write-Host "Validating Grafana Prometheus datasource connectivity..."

# 1. The datasource is provisioned and reachable via the Grafana API.
Invoke-WithRetry `
    -FailureMessage "Grafana datasource '$DatasourceUid' was not found within $TimeoutSeconds seconds." `
    -Operation {
        $datasource = Invoke-JsonGet "$GrafanaBaseUrl/api/datasources/uid/$DatasourceUid"

        Confirm-Condition `
            -Condition ($datasource.type -eq "prometheus") `
            -SuccessMessage "Grafana datasource '$DatasourceUid' is provisioned (type: prometheus)" `
            -FailureMessage "Grafana datasource '$DatasourceUid' is not a Prometheus datasource"

        Confirm-Condition `
            -Condition ($datasource.isDefault -eq $true) `
            -SuccessMessage "Grafana datasource '$DatasourceUid' is the default datasource" `
            -FailureMessage "Grafana datasource '$DatasourceUid' is not the default datasource"
    }

# 2. Acceptance criterion: the datasource is healthy.
Invoke-WithRetry `
    -FailureMessage "Grafana datasource '$DatasourceUid' did not report a healthy status within $TimeoutSeconds seconds." `
    -Operation {
        $health = Invoke-JsonGet "$GrafanaBaseUrl/api/datasources/uid/$DatasourceUid/health"

        Confirm-Condition `
            -Condition ($health.status -eq "OK") `
            -SuccessMessage "Grafana datasource health is OK: $($health.message)" `
            -FailureMessage "Grafana datasource health is $($health.status): $($health.message)"
    }

# 3. Acceptance criterion: queries return data (proxied through Grafana to Prometheus).
Invoke-WithRetry `
    -FailureMessage "Grafana datasource '$DatasourceUid' did not return query data within $TimeoutSeconds seconds." `
    -Operation {
        $queryResult = Invoke-JsonGet "$GrafanaBaseUrl/api/datasources/proxy/uid/$DatasourceUid/api/v1/query?query=up"

        Confirm-Condition `
            -Condition ($queryResult.status -eq "success") `
            -SuccessMessage "Query 'up' succeeded through the Grafana datasource proxy" `
            -FailureMessage "Query 'up' failed through the Grafana datasource proxy"

        Confirm-Condition `
            -Condition ($queryResult.data.result.Count -gt 0) `
            -SuccessMessage "Query 'up' returned data through the Grafana datasource proxy" `
            -FailureMessage "Query 'up' returned no data through the Grafana datasource proxy"
    }

Write-Host "[ok] Grafana Prometheus datasource validation completed."
