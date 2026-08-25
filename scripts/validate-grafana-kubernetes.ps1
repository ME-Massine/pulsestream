# Validates the in-cluster Grafana against its provisioning (#156).
#
# The acceptance criteria this covers, in the order they can fail:
#
#   1. Grafana connects to Prometheus  -> the datasource is provisioned and its
#                                         health check reaches the #154 Service.
#   2. Dashboards load                 -> both dashboards are in the PulseStream
#                                         folder under the UIDs the JSON declares,
#                                         AND the model Grafana serves for each
#                                         UID is the model this repository
#                                         committed.
#   3. Queries return expected data    -> every expression in the dashboard
#                                         Grafana actually has loaded is executed
#                                         through the datasource and must return
#                                         at least one series.
#
# WHY THE LOADED MODEL AND NOT THE MANIFEST. Identity is not content: a
# dashboard that was loaded before a change to dashboards-configmap.yaml keeps
# its UID, its title and its folder, so /api/search cannot tell it apart from a
# current one. Executing expressions read from the local manifest against that
# Grafana proves the queries are good and says nothing about the panels a user
# opens. So every dashboard is fetched with /api/dashboards/uid/<uid>, compared
# against the committed JSON panel by panel (Compare-GrafanaDashboardModel), and
# it is the fetched model's own expressions that are executed below.
#
# Step 3 runs the real expressions rather than a stand-in like `up`, because the
# way this feature breaks is a query that is valid, returns 200, and matches
# nothing: #154 labels the platform series with job/namespace/pod/node, and a
# panel selecting on any other label just draws an empty graph.
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
# Compare-GrafanaDashboardModel and the expression helpers. Shared with the same
# test, which exercises the comparison against synthetic stale models - the
# cases that cannot be produced against a live Grafana on demand.
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamGrafanaDashboards.psm1") -Force

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$grafanaRoot = Join-Path $repositoryRoot "infrastructure/kubernetes/monitoring/grafana"
$dashboardsManifest = Join-Path $grafanaRoot "dashboards-configmap.yaml"

$authHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("${GrafanaUser}:${GrafanaPassword}"))
}

function Invoke-PrometheusResource {
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $Path
    )

    # The datasource resources API proxies to Prometheus through Grafana, so a
    # result here proves the whole path the browser uses - not just that
    # Prometheus happens to be reachable from wherever this script runs.
    return Invoke-JsonGet "$BaseUrl/api/datasources/uid/$DatasourceUid/resources/$Path" -Headers $authHeader
}

function Invoke-PrometheusQuery {
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $Expression
    )

    return Invoke-PrometheusResource -BaseUrl $BaseUrl `
        -Path "api/v1/query?query=$([uri]::EscapeDataString($Expression))"
}

# Interpolation failure is reported through Confirm-Condition rather than a bare
# throw, because PermanentValidationError is declared inside
# PulseStreamValidation.psm1 and a PowerShell class does not leave its module for
# a plain Import-Module. Constructing it here would fail with "unable to find
# type" - and only on the path that was supposed to report the problem.
function Resolve-ExpressionOrFail {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Expression,
        [Parameter(Mandatory)] $Substitutions
    )

    $unresolved = ""
    $resolved = Resolve-GrafanaExpression `
        -Expression $Expression `
        -Substitutions $Substitutions `
        -UnresolvedVariable ([ref] $unresolved)

    if ($null -eq $resolved) {
        Confirm-Condition -Permanent -Condition $false -FailureMessage (
            "Expression uses the variable '$unresolved', which this validator cannot interpolate. " +
            "Add it to Get-GrafanaVariableSubstitution in lib/PulseStreamGrafanaDashboards.psm1. " +
            "Expression: $Expression")
    }

    return $resolved
}

Write-Host "Validating the in-cluster Grafana provisioning..."

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "1. The provisioning ConfigMaps are applied, and carry what is committed."

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

# Read as JSON rather than through jsonpath: a key containing a dot
# ('service-health.json') has to be escaped in a jsonpath expression, and the
# whole object is needed anyway to compare the applied content.
$appliedDashboards = (Get-KubectlJsonPath `
    -KubectlArgs @("get", "configmap", "grafana-dashboards", "-n", $Namespace, "-o", "json") `
    -ErrorContext "ConfigMap 'grafana-dashboards' was not found in namespace '$Namespace'" | ConvertFrom-Json).data

$committedDashboards = [ordered]@{}

foreach ($key in $dashboardKeys) {
    $committed = Get-ConfigMapDataValue -Path $dashboardsManifest -Key $key | ConvertFrom-Json
    $committedDashboards[$key] = $committed

    $applied = $appliedDashboards.$key

    Confirm-Condition -Permanent `
        -Condition (-not [string]::IsNullOrWhiteSpace([string] $applied)) `
        -SuccessMessage "ConfigMap 'grafana-dashboards' carries '$key'" `
        -FailureMessage "ConfigMap 'grafana-dashboards' has no '$key' entry - the applied ConfigMap is older than the committed manifest"

    # The applied ConfigMap and the loaded dashboard are two different kinds of
    # stale, and they are separated here so the report says which: a difference
    # at this step means `kubectl apply` was not re-run, a difference at step 5
    # means it was but Grafana has not picked it up.
    $differences = Compare-GrafanaDashboardModel `
        -Committed $committedDashboards[$key] `
        -Loaded ($applied | ConvertFrom-Json) `
        -Source "applied ConfigMap entry '$key'"

    Confirm-Condition -Permanent `
        -Condition ($differences.Count -eq 0) `
        -SuccessMessage "ConfigMap entry '$key' matches the committed manifest" `
        -FailureMessage ("The applied ConfigMap entry '$key' differs from the committed manifest - re-run " +
            "``kubectl apply -f infrastructure/kubernetes/monitoring/grafana/``:" +
            [Environment]::NewLine + "  " + [string]::Join([Environment]::NewLine + "  ", $differences))
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
    Write-Host "5. The dashboards are loaded, and are the committed ones (acceptance criterion 2)."

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

    # The models Grafana serves, keyed by ConfigMap entry. Step 6 executes the
    # expressions found in these, not the ones in the manifest.
    $loadedDashboards = [ordered]@{}

    foreach ($key in $dashboardKeys) {
        $committed = $committedDashboards[$key]

        # Search first, for the error message: "the dashboard is not loaded" and
        # "the dashboard is loaded but GET by uid failed" are different problems
        # and the second one is rare enough to be worth naming.
        $listed = @($search | Where-Object { $_.uid -eq $committed.uid })[0]

        Confirm-Condition -Permanent `
            -Condition ($null -ne $listed) `
            -SuccessMessage "Dashboard '$($committed.title)' is loaded (uid $($committed.uid))" `
            -FailureMessage "Dashboard uid '$($committed.uid)' from '$key' is not loaded in Grafana"

        $fetched = Invoke-WithRetry `
            -TimeoutSeconds $TimeoutSeconds `
            -FailureMessage "Grafana did not serve dashboard uid '$($committed.uid)' within $TimeoutSeconds seconds." `
            -Operation {
                Invoke-JsonGet "$GrafanaBaseUrl/api/dashboards/uid/$($committed.uid)" -Headers $authHeader
            }

        $loaded = $fetched.dashboard

        Confirm-Condition -Permanent `
            -Condition ($null -ne $loaded) `
            -SuccessMessage "Grafana served the dashboard model for uid '$($committed.uid)'" `
            -FailureMessage "Grafana returned no dashboard model for uid '$($committed.uid)'"

        Confirm-Condition -Permanent `
            -Condition ($fetched.meta.folderTitle -eq "PulseStream") `
            -SuccessMessage "Dashboard '$($committed.uid)' is in the PulseStream folder" `
            -FailureMessage "Dashboard '$($committed.uid)' is in folder '$($fetched.meta.folderTitle)', expected 'PulseStream'"

        # provisioned=false means the dashboard in front of us was imported or
        # saved through the UI and lives in Grafana's database, where nothing in
        # this repository updates it.
        Confirm-Condition -Permanent `
            -Condition ($fetched.meta.provisioned -eq $true) `
            -SuccessMessage "Dashboard '$($committed.uid)' is file-provisioned" `
            -FailureMessage "Dashboard '$($committed.uid)' is not file-provisioned (meta.provisioned=$($fetched.meta.provisioned)) - it came from Grafana's database, not the ConfigMap"

        # The check /api/search cannot make. Identity is unchanged by every
        # interesting kind of staleness; content is not.
        $differences = Compare-GrafanaDashboardModel `
            -Committed $committed `
            -Loaded $loaded `
            -Source "loaded dashboard '$($committed.uid)'"

        Confirm-Condition -Permanent `
            -Condition ($differences.Count -eq 0) `
            -SuccessMessage "Dashboard '$($committed.uid)' matches the committed model ($(@(Get-GrafanaDashboardQuery -Dashboard $loaded).Count) quer(y/ies) over $(@($loaded.panels).Count) panel(s))" `
            -FailureMessage ("Dashboard '$($committed.uid)' is loaded, but is not the committed dashboard. Grafana " +
                "re-reads the provisioning directory every 30s; if this persists, the mounted ConfigMap is stale or " +
                "the dashboard was overwritten through the UI:" +
                [Environment]::NewLine + "  " + [string]::Join([Environment]::NewLine + "  ", $differences))

        $loadedDashboards[$key] = $loaded
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "6. The loaded panel queries return data (acceptance criterion 3)."

    # Checked first and separately: if the scrape jobs the dashboards name are
    # not in Prometheus, every expression that pins one fails identically and
    # the reason is not visible in any of them. The job names come from the
    # dashboards themselves rather than a hard-coded list, so this follows a
    # panel that starts selecting a new workload.
    $requiredJobs = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $dashboardKeys) {
        foreach ($query in (Get-GrafanaDashboardQuery -Dashboard $loadedDashboards[$key])) {
            foreach ($value in (Get-GrafanaExpressionLabelValue -Expression $query.Expression -Label "job")) {
                if (-not $requiredJobs.Contains($value)) {
                    $requiredJobs.Add($value) | Out-Null
                }
            }
        }
    }

    Invoke-WithRetry `
        -TimeoutSeconds $TimeoutSeconds `
        -FailureMessage "Prometheus did not report the expected scrape jobs within $TimeoutSeconds seconds." `
        -Operation {
            $labelValues = Invoke-PrometheusResource -BaseUrl $GrafanaBaseUrl -Path "api/v1/label/job/values"
            $jobs = @($labelValues.data)

            Confirm-Condition `
                -Condition ($jobs.Count -gt 0) `
                -SuccessMessage "Prometheus knows these 'job' label values: $([string]::Join(', ', $jobs))" `
                -FailureMessage "Prometheus has no series carrying a 'job' label"

            $missingJobs = @($requiredJobs | Where-Object { $jobs -notcontains $_ })

            Confirm-Condition `
                -Condition ($missingJobs.Count -eq 0) `
                -SuccessMessage "Every job the dashboards select on is being scraped: $([string]::Join(', ', $requiredJobs))" `
                -FailureMessage ("Prometheus has no series for job(s) $([string]::Join(', ', $missingJobs)). Those are " +
                    "scrape jobs in infrastructure/kubernetes/monitoring/prometheus-values.yaml (#154); check the " +
                    "targets there before blaming a panel.")
        }

    foreach ($key in $dashboardKeys) {
        $dashboard = $loadedDashboards[$key]
        $substitutions = Get-GrafanaVariableSubstitution -Dashboard $dashboard

        foreach ($query in (Get-GrafanaDashboardQuery -Dashboard $dashboard)) {
            $expression = Resolve-ExpressionOrFail `
                -Expression $query.Expression `
                -Substitutions $substitutions

            Invoke-WithRetry `
                -TimeoutSeconds $TimeoutSeconds `
                -FailureMessage "'$($dashboard.title)' panel $($query.PanelId) ('$($query.PanelTitle)') returned no data within $TimeoutSeconds seconds. Query: $expression" `
                -Operation {
                    $result = Invoke-PrometheusQuery -BaseUrl $GrafanaBaseUrl -Expression $expression

                    # A malformed query is a permanent failure; an empty
                    # result is not, because a freshly started service has
                    # not been scraped yet.
                    Confirm-Condition -Permanent `
                        -Condition ($result.status -eq "success") `
                        -SuccessMessage "'$($dashboard.title)' panel $($query.PanelId) query is valid PromQL" `
                        -FailureMessage "'$($dashboard.title)' panel $($query.PanelId) query failed: $($result.error). Query: $expression"

                    Confirm-Condition `
                        -Condition (@($result.data.result).Count -gt 0) `
                        -SuccessMessage "'$($dashboard.title)' panel $($query.PanelId) ('$($query.PanelTitle)') returned $(@($result.data.result).Count) series" `
                        -FailureMessage "'$($dashboard.title)' panel $($query.PanelId) ('$($query.PanelTitle)') returned no series"
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
