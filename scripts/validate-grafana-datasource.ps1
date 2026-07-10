[CmdletBinding()]
param(
    [string] $GrafanaBaseUrl = "http://localhost:3000",
    [string] $DatasourceUid = "prometheus",
    [string] $GrafanaUser = "admin",
    [string] $GrafanaPassword = "admin",
    [int] $TimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force

$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("${GrafanaUser}:${GrafanaPassword}"))
}

Write-Host "Validating Grafana Prometheus datasource connectivity..."

# 1. The datasource is provisioned and reachable via the Grafana API.
#    Existence can lag on container startup, so retry the fetch; the structural
#    assertions below are permanent and fail fast.
$datasource = Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Grafana datasource '$DatasourceUid' was not found within $TimeoutSeconds seconds." `
    -Operation {
        Invoke-JsonGet "$GrafanaBaseUrl/api/datasources/uid/$DatasourceUid" -Headers $authHeader
    }

Confirm-Condition -Permanent `
    -Condition ($datasource.type -eq "prometheus") `
    -SuccessMessage "Grafana datasource '$DatasourceUid' is provisioned (type: prometheus)" `
    -FailureMessage "Grafana datasource '$DatasourceUid' is not a Prometheus datasource (type: $($datasource.type))"

Confirm-Condition -Permanent `
    -Condition ($datasource.isDefault -eq $true) `
    -SuccessMessage "Grafana datasource '$DatasourceUid' is the default datasource" `
    -FailureMessage "Grafana datasource '$DatasourceUid' is not the default datasource"

# 2. Acceptance criterion: the datasource is healthy.
Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Grafana datasource '$DatasourceUid' did not report a healthy status within $TimeoutSeconds seconds." `
    -Operation {
        $health = Invoke-JsonGet "$GrafanaBaseUrl/api/datasources/uid/$DatasourceUid/health" -Headers $authHeader

        Confirm-Condition `
            -Condition ($health.status -eq "OK") `
            -SuccessMessage "Grafana datasource health is OK: $($health.message)" `
            -FailureMessage "Grafana datasource health is $($health.status): $($health.message)"
    }

# 3. Acceptance criterion: queries return data. Uses the datasource resources
#    API (the numeric-id proxy route is deprecated) to reach Prometheus.
Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Grafana datasource '$DatasourceUid' did not return query data within $TimeoutSeconds seconds." `
    -Operation {
        $queryResult = Invoke-JsonGet `
            "$GrafanaBaseUrl/api/datasources/uid/$DatasourceUid/resources/api/v1/query?query=up" `
            -Headers $authHeader

        Confirm-Condition `
            -Condition ($queryResult.status -eq "success") `
            -SuccessMessage "Query 'up' succeeded through the Grafana datasource" `
            -FailureMessage "Query 'up' failed through the Grafana datasource"

        Confirm-Condition `
            -Condition ($queryResult.data.result.Count -gt 0) `
            -SuccessMessage "Query 'up' returned data through the Grafana datasource" `
            -FailureMessage "Query 'up' returned no data through the Grafana datasource"
    }

Write-Host "[ok] Grafana Prometheus datasource validation completed."
