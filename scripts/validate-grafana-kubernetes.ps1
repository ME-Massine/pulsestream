# Validates the in-cluster Grafana against its provisioning (#156).
#
# The acceptance criteria this covers, in the order they can fail:
#
#   1. Grafana connects to Prometheus  -> the datasource is provisioned and its
#                                         health check reaches the #154 Service.
#   2. Dashboards load                 -> both dashboards are in the PulseStream
#                                         folder under the UIDs the JSON declares.
#   3. Queries return expected data    -> every expression committed in
#                                         dashboards-configmap.yaml is executed
#                                         through the datasource and must return
#                                         at least one series.
#
# Step 3 runs the real expressions rather than a stand-in like `up`, because the
# way this feature breaks is a query that is valid, returns 200, and matches
# nothing: the Compose dashboards select on `job`, the in-cluster Prometheus
# labels the same series with `service`, and a panel that has the wrong one just
# draws an empty graph.
#
# Prerequisites: #154 (Prometheus in the cluster) and #155 (Grafana in the
# cluster, mounting the three ConfigMaps - see
# infrastructure/kubernetes/monitoring/grafana/README.md). This script only
# reports on what is deployed; it applies nothing.
#
# Usage:
#   ./scripts/validate-grafana-kubernetes.ps1
#   ./scripts/validate-grafana-kubernetes.ps1 -GrafanaBaseUrl http://localhost:3000

[CmdletBinding()]
param(
    [string] $Namespace = "monitoring",
    [string] $GrafanaService = "grafana",
    [string] $GrafanaDeployment = "grafana",
    # When empty, the script opens (and closes) its own `kubectl port-forward`.
    # Pass a URL to reuse a port-forward or an ingress that is already up.
    [string] $GrafanaBaseUrl = "",
    [int] $LocalPort = 3000,
    [string] $DatasourceUid = "prometheus",
    [string] $GrafanaUser = "admin",
    [string] $GrafanaPassword = "admin",
    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamKubernetes.psm1") -Force
# Get-ConfigMapDataKey/Get-ConfigMapDataValue: ConvertFrom-KubernetesYaml in the
# same module cannot read a ConfigMap whose values are JSON. Shared with
# tests/test-grafana-dashboard-provisioning.ps1 so the cluster path and the
# no-cluster path cannot disagree about what the manifest contains.
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamYaml.psm1") -Force

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$grafanaRoot = Join-Path $repositoryRoot "infrastructure/kubernetes/monitoring/grafana"
$dashboardsManifest = Join-Path $grafanaRoot "dashboards-configmap.yaml"

$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("${GrafanaUser}:${GrafanaPassword}"))
}

# Grafana interpolates dashboard variables before sending PromQL to Prometheus,
# so the committed expressions are not valid PromQL as written. The
# substitutions are derived from each dashboard rather than hard-coded, and
# anything left unresolved afterwards is a hard failure (see below) - a
# validator that quietly skipped an expression it could not interpolate would
# report success over a panel nobody had checked.
function Get-DashboardVariableSubstitution {
    param([Parameter(Mandatory)] $Dashboard)

    $substitutions = [ordered]@{}

    foreach ($variable in $Dashboard.templating.list) {
        $value = [string] $variable.current.value

        # A multi-value variable sitting on "All" is sent as a match-anything
        # regex; anything else is sent as its selected value.
        if ($value -eq '$__all' -or [string]::IsNullOrWhiteSpace($value)) {
            $value = '.+'
        }

        $substitutions['$' + $variable.name] = $value
    }

    # $__range is the dashboard's own time range, which both dashboards declare
    # as `now-<range>`.
    $from = [string] $Dashboard.time.from
    if ($from -match '^now-(?<range>\d+[smhdwy])$') {
        $substitutions['$__range'] = $Matches['range']
    }

    return $substitutions
}

function Resolve-DashboardExpression {
    param(
        [Parameter(Mandatory)] [string] $Expression,
        [Parameter(Mandatory)] $Substitutions
    )

    $resolved = $Expression
    foreach ($variable in $Substitutions.Keys) {
        $resolved = $resolved.Replace($variable, [string] $Substitutions[$variable])
    }

    # Grafana has more built-ins than the two these dashboards use
    # ($__interval, $__rate_interval, $__to, ...). Rather than guess at a value
    # for one that appears later, refuse: an un-substituted variable would be
    # sent to Prometheus as a syntax error and reported as "the panel is broken"
    # instead of "this validator does not know that variable yet".
    #
    # Raised through Confirm-Condition rather than as a bare throw, because
    # PermanentValidationError is declared inside PulseStreamValidation.psm1 and
    # a PowerShell class does not leave its module for a plain Import-Module.
    # Constructing it here would fail with "unable to find type" - and only on
    # the path that was supposed to report the problem.
    $unresolved = [regex]::Match($resolved, '\$(?<variable>[A-Za-z_][A-Za-z0-9_]*)')
    if ($unresolved.Success) {
        Confirm-Condition -Permanent -Condition $false -FailureMessage (
            "Expression uses the variable '`$$($unresolved.Groups['variable'].Value)', which this validator " +
            "cannot interpolate. Add it to Get-DashboardVariableSubstitution. Expression: $Expression")
    }

    return $resolved
}

function Invoke-PrometheusQuery {
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $Expression
    )

    # The datasource resources API proxies to Prometheus through Grafana, so a
    # result here proves the whole path the browser uses - not just that
    # Prometheus happens to be reachable from wherever this script runs.
    $uri = "$BaseUrl/api/datasources/uid/$DatasourceUid/resources/api/v1/query" +
        "?query=$([uri]::EscapeDataString($Expression))"

    return Invoke-JsonGet $uri -Headers $authHeader
}

Write-Host "Validating the in-cluster Grafana provisioning..."

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "1. The provisioning ConfigMaps are applied."

$expectedConfigMaps = @(
    @{ Name = "grafana-datasource";         Key = "prometheus.yaml" },
    @{ Name = "grafana-dashboard-provider"; Key = "pulsestream.yaml" }
)

foreach ($configMap in $expectedConfigMaps) {
    $keys = Get-KubectlJsonPath `
        -KubectlArgs @("get", "configmap", $configMap.Name, "-n", $Namespace, "-o", "jsonpath={.data}") `
        -ErrorContext "ConfigMap '$($configMap.Name)' was not found in namespace '$Namespace'. Apply infrastructure/kubernetes/monitoring/grafana/ first"

    Confirm-Condition -Permanent `
        -Condition ($keys -match [regex]::Escape($configMap.Key)) `
        -SuccessMessage "ConfigMap '$($configMap.Name)' carries '$($configMap.Key)'" `
        -FailureMessage "ConfigMap '$($configMap.Name)' has no '$($configMap.Key)' entry"
}

$dashboardKeys = Get-ConfigMapDataKey -Path $dashboardsManifest
$appliedDashboards = Get-KubectlJsonPath `
    -KubectlArgs @("get", "configmap", "grafana-dashboards", "-n", $Namespace, "-o", "jsonpath={.data}") `
    -ErrorContext "ConfigMap 'grafana-dashboards' was not found in namespace '$Namespace'"

foreach ($key in $dashboardKeys) {
    Confirm-Condition -Permanent `
        -Condition ($appliedDashboards -match [regex]::Escape($key)) `
        -SuccessMessage "ConfigMap 'grafana-dashboards' carries '$key'" `
        -FailureMessage "ConfigMap 'grafana-dashboards' has no '$key' entry - the applied ConfigMap is older than the committed manifest"
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "2. Grafana is running."

Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Deployment '$GrafanaDeployment' did not become available within $TimeoutSeconds seconds." `
    -Operation {
        $ready = Get-KubectlJsonPath `
            -KubectlArgs @("get", "deployment", $GrafanaDeployment, "-n", $Namespace, "-o", "jsonpath={.status.readyReplicas}") `
            -ErrorContext "Deployment '$GrafanaDeployment' was not found in namespace '$Namespace'. It is deployed by #155"

        Confirm-Condition `
            -Condition ([int] ("0" + $ready) -ge 1) `
            -SuccessMessage "Deployment '$GrafanaDeployment' has $ready ready replica(s)" `
            -FailureMessage "Deployment '$GrafanaDeployment' has no ready replicas yet"
    }

# ---------------------------------------------------------------------------
$portForward = $null
$portForwardLog = $null

try {
    if ([string]::IsNullOrWhiteSpace($GrafanaBaseUrl)) {
        Write-Host ""
        Write-Host "3. Opening a port-forward to svc/$GrafanaService."

        $GrafanaBaseUrl = "http://localhost:$LocalPort"
        $portForwardLog = Join-Path ([System.IO.Path]::GetTempPath()) "pulsestream-grafana-port-forward.log"

        $portForward = Start-Process `
            -FilePath "kubectl" `
            -ArgumentList @("port-forward", "-n", $Namespace, "svc/$GrafanaService", "${LocalPort}:80") `
            -PassThru -NoNewWindow `
            -RedirectStandardOutput $portForwardLog `
            -RedirectStandardError "$portForwardLog.err"

        Write-Host "[ok] kubectl port-forward started (pid $($portForward.Id)), log: $portForwardLog"
    } else {
        Write-Host ""
        Write-Host "3. Using the supplied Grafana URL: $GrafanaBaseUrl"
    }

    Invoke-WithRetry `
        -TimeoutSeconds $TimeoutSeconds `
        -FailureMessage "Grafana did not answer at $GrafanaBaseUrl within $TimeoutSeconds seconds." `
        -Operation {
            $health = Invoke-JsonGet "$GrafanaBaseUrl/api/health"

            Confirm-Condition `
                -Condition ($health.database -eq "ok") `
                -SuccessMessage "Grafana is healthy (version $($health.version))" `
                -FailureMessage "Grafana health reports database=$($health.database)"
        }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "4. The Prometheus datasource is provisioned (acceptance criterion 1)."

    $datasource = Invoke-WithRetry `
        -TimeoutSeconds $TimeoutSeconds `
        -FailureMessage "Datasource '$DatasourceUid' was not found within $TimeoutSeconds seconds. Grafana only reads provisioning at startup - restart it after applying the ConfigMap." `
        -Operation {
            Invoke-JsonGet "$GrafanaBaseUrl/api/datasources/uid/$DatasourceUid" -Headers $authHeader
        }

    Confirm-Condition -Permanent `
        -Condition ($datasource.type -eq "prometheus") `
        -SuccessMessage "Datasource '$DatasourceUid' is a Prometheus datasource" `
        -FailureMessage "Datasource '$DatasourceUid' is of type '$($datasource.type)'"

    Confirm-Condition -Permanent `
        -Condition ($datasource.isDefault -eq $true) `
        -SuccessMessage "Datasource '$DatasourceUid' is the default datasource" `
        -FailureMessage "Datasource '$DatasourceUid' is not the default datasource"

    # readOnly is how the API reports `editable: false`. If it is false, the
    # datasource in front of us came from the database (someone added it in the
    # UI) rather than from the ConfigMap, and everything below would be
    # validating an object this repository does not describe.
    Confirm-Condition -Permanent `
        -Condition ($datasource.readOnly -eq $true) `
        -SuccessMessage "Datasource '$DatasourceUid' is provisioned from a file, not the UI" `
        -FailureMessage "Datasource '$DatasourceUid' is UI-managed (readOnly=false) - it was not created by the provisioning ConfigMap"

    $expectedUrl = "http://prometheus-server.$Namespace.svc:80"
    Confirm-Condition -Permanent `
        -Condition ($datasource.url -eq $expectedUrl) `
        -SuccessMessage "Datasource '$DatasourceUid' points at $expectedUrl" `
        -FailureMessage "Datasource '$DatasourceUid' points at '$($datasource.url)', expected '$expectedUrl'"

    Invoke-WithRetry `
        -TimeoutSeconds $TimeoutSeconds `
        -FailureMessage "Datasource '$DatasourceUid' did not report a healthy status within $TimeoutSeconds seconds." `
        -Operation {
            $health = Invoke-JsonGet "$GrafanaBaseUrl/api/datasources/uid/$DatasourceUid/health" -Headers $authHeader

            Confirm-Condition `
                -Condition ($health.status -eq "OK") `
                -SuccessMessage "Grafana reaches Prometheus: $($health.message)" `
                -FailureMessage "Datasource health is $($health.status): $($health.message)"
        }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "5. The dashboards are loaded (acceptance criterion 2)."

    $search = Invoke-WithRetry `
        -TimeoutSeconds $TimeoutSeconds `
        -FailureMessage "Grafana returned no dashboards within $TimeoutSeconds seconds. The file provider re-reads its directory every 30s." `
        -Operation {
            $found = Invoke-JsonGet "$GrafanaBaseUrl/api/search?type=dash-db" -Headers $authHeader

            Confirm-Condition `
                -Condition (@($found).Count -gt 0) `
                -SuccessMessage "Grafana lists $(@($found).Count) dashboard(s)" `
                -FailureMessage "Grafana lists no dashboards"

            $found
        }

    foreach ($key in $dashboardKeys) {
        $committed = Get-ConfigMapDataValue -Path $dashboardsManifest -Key $key | ConvertFrom-Json
        $loaded = @($search | Where-Object { $_.uid -eq $committed.uid })[0]

        Confirm-Condition -Permanent `
            -Condition ($null -ne $loaded) `
            -SuccessMessage "Dashboard '$($committed.title)' is loaded (uid $($committed.uid))" `
            -FailureMessage "Dashboard uid '$($committed.uid)' from '$key' is not loaded in Grafana"

        Confirm-Condition -Permanent `
            -Condition ($loaded.title -eq $committed.title) `
            -SuccessMessage "Dashboard '$($committed.uid)' has the committed title" `
            -FailureMessage "Dashboard '$($committed.uid)' is titled '$($loaded.title)', expected '$($committed.title)'"

        Confirm-Condition -Permanent `
            -Condition ($loaded.folderTitle -eq "PulseStream") `
            -SuccessMessage "Dashboard '$($committed.uid)' is in the PulseStream folder" `
            -FailureMessage "Dashboard '$($committed.uid)' is in folder '$($loaded.folderTitle)', expected 'PulseStream'"
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "6. The panel queries return data (acceptance criterion 3)."

    # Checked first and separately: if the relabel rule in ../configmap.yaml is
    # missing, every expression below fails identically and the reason is not
    # visible in any of them.
    Invoke-WithRetry `
        -TimeoutSeconds $TimeoutSeconds `
        -FailureMessage "Prometheus has no 'service' label values within $TimeoutSeconds seconds. The dashboards select on it; it comes from the relabel rule in infrastructure/kubernetes/monitoring/configmap.yaml." `
        -Operation {
            $labelValues = Invoke-JsonGet `
                "$GrafanaBaseUrl/api/datasources/uid/$DatasourceUid/resources/api/v1/label/service/values" `
                -Headers $authHeader

            Confirm-Condition `
                -Condition (@($labelValues.data).Count -gt 0) `
                -SuccessMessage "Prometheus knows these 'service' label values: $([string]::Join(', ', @($labelValues.data)))" `
                -FailureMessage "Prometheus has no series carrying a 'service' label"
        }

    foreach ($key in $dashboardKeys) {
        $dashboard = Get-ConfigMapDataValue -Path $dashboardsManifest -Key $key | ConvertFrom-Json
        $substitutions = Get-DashboardVariableSubstitution -Dashboard $dashboard

        foreach ($panel in $dashboard.panels) {
            foreach ($target in $panel.targets) {
                $expression = Resolve-DashboardExpression `
                    -Expression ([string] $target.expr) `
                    -Substitutions $substitutions

                Invoke-WithRetry `
                    -TimeoutSeconds $TimeoutSeconds `
                    -FailureMessage "'$($dashboard.title)' panel $($panel.id) ('$($panel.title)') returned no data within $TimeoutSeconds seconds. Query: $expression" `
                    -Operation {
                        $result = Invoke-PrometheusQuery -BaseUrl $GrafanaBaseUrl -Expression $expression

                        # A malformed query is a permanent failure; an empty
                        # result is not, because a freshly started service has
                        # not been scraped yet.
                        Confirm-Condition -Permanent `
                            -Condition ($result.status -eq "success") `
                            -SuccessMessage "'$($dashboard.title)' panel $($panel.id) query is valid PromQL" `
                            -FailureMessage "'$($dashboard.title)' panel $($panel.id) query failed: $($result.error). Query: $expression"

                        Confirm-Condition `
                            -Condition (@($result.data.result).Count -gt 0) `
                            -SuccessMessage "'$($dashboard.title)' panel $($panel.id) ('$($panel.title)') returned $(@($result.data.result).Count) series" `
                            -FailureMessage "'$($dashboard.title)' panel $($panel.id) ('$($panel.title)') returned no series"
                    }
            }
        }
    }
} finally {
    if ($null -ne $portForward -and -not $portForward.HasExited) {
        Stop-Process -Id $portForward.Id -Force -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "[ok] kubectl port-forward stopped."
    }
}

Write-Host ""
Write-Host "[ok] Grafana Kubernetes provisioning validation completed."
