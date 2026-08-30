# Structural checks over the Grafana provisioning ConfigMaps (#156).
#
# Everything here reads committed files, so it needs no cluster and no Grafana.
# It exists because the failure mode this feature has is silent: a provisioned
# dashboard whose datasource UID, label selector or provider path is wrong does
# not error anywhere - Grafana starts, the dashboard opens, and every panel is
# empty. Each assertion below is one of the ways that happens.
#
# The last section is different in kind: it exercises
# Compare-GrafanaDashboardModel, the function ../validate-grafana-kubernetes.ps1
# uses to decide whether the dashboard Grafana has loaded is the dashboard this
# repository committed. Those cases (a stale model, a renamed panel, a query
# that never got reloaded) cannot be produced on demand against a live Grafana,
# so they are covered here against synthetic models instead.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$grafanaRoot = Join-Path $repositoryRoot "infrastructure/kubernetes/monitoring/grafana"
$composeDashboardRoot = Join-Path $repositoryRoot "observability/grafana/dashboards"
# #154. Present once this branch is rebased onto it; see section 5.
$prometheusValuesPath = Join-Path $repositoryRoot "infrastructure/kubernetes/monitoring/prometheus-values.yaml"

# Where dashboards-configmap.yaml has to be mounted for the provider in
# dashboard-provider-configmap.yaml to find it. The two files are applied
# independently, so nothing at apply time notices when they disagree.
$dashboardMountPath = "/etc/grafana/dashboards"

# The Service #154 publishes Prometheus on, spelled as a datasource URL.
$prometheusServiceUrl = "http://prometheus-server.monitoring.svc:80"

# The labels #154 puts on every platform series, when prometheus-values.yaml is
# not on disk to be read (i.e. before this branch is rebased onto it):
#
#   job, instance   written by Prometheus for every target, in every job
#   namespace, pod  relabelled from the pod's discovery meta labels
#   node            relabelled from the pod's node name
#
# There is deliberately no `service` here. #154 scrapes one job per workload and
# relabels three meta labels; the workload name is `job`.
$defaultClusterLabels = @("job", "instance", "namespace", "pod", "node")

# Labels that come from the application rather than from the scrape config -
# Micrometer tags on the HTTP server metrics. They are on the series regardless
# of how it is scraped, which is why they are legitimate in a cluster dashboard
# and are listed separately from the labels #154 produces.
$micrometerLabels = @("uri", "outcome", "status", "method", "exception")

$failures = [System.Collections.Generic.List[string]]::new()
$assertionCount = 0

function Confirm-That {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Description
    )

    $script:assertionCount++

    if ($Condition) {
        Write-Host "  [ok] $Description"
    } else {
        Write-Host "  [FAIL] $Description"
        $script:failures.Add($Description) | Out-Null
    }
}

# ConvertFrom-KubernetesYaml cannot read these manifests - it strips '#'
# comments and refuses block scalars, and a ConfigMap whose values are JSON is
# both. Get-ConfigMapDataKey/Get-ConfigMapDataValue in the same module handle
# that shape, and are shared with ../validate-grafana-kubernetes.ps1 so the two
# cannot disagree about what the manifests contain.
Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamYaml.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamGrafanaDashboards.psm1") -Force

# Every PromQL expression in a dashboard, in document order.
function Get-DashboardExpression {
    param([Parameter(Mandatory)] $Dashboard)

    return @(Get-GrafanaDashboardQuery -Dashboard $Dashboard | ForEach-Object { $_.Expression })
}

# A detached copy, so a test case can mutate a dashboard without the next case
# seeing the mutation.
function Copy-DashboardModel {
    param([Parameter(Mandatory)] $Dashboard)

    return ($Dashboard | ConvertTo-Json -Depth 100 | ConvertFrom-Json)
}

Write-Host "Validating Grafana provisioning manifests..."

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "1. Files are present and readable."

$datasourcePath = Join-Path $grafanaRoot "datasource-configmap.yaml"
$providerPath = Join-Path $grafanaRoot "dashboard-provider-configmap.yaml"
$dashboardsPath = Join-Path $grafanaRoot "dashboards-configmap.yaml"

foreach ($path in @($datasourcePath, $providerPath, $dashboardsPath)) {
    Confirm-That -Condition (Test-Path -LiteralPath $path -PathType Leaf) `
        -Description "manifest exists: $(Split-Path -Leaf $path)"
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "[FAIL] $($failures.Count) of $assertionCount assertions failed."
    exit 1
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "2. The datasource is the one every dashboard resolves."

$datasourceYaml = Get-ConfigMapDataValue -Path $datasourcePath -Key "prometheus.yaml"

Confirm-That -Condition ($datasourceYaml -match '(?m)^\s*uid:\s*prometheus\s*$') `
    -Description "datasource uid is 'prometheus' (the UID every dashboard panel references)"

Confirm-That -Condition ($datasourceYaml -match '(?m)^\s*type:\s*prometheus\s*$') `
    -Description "datasource type is 'prometheus'"

Confirm-That -Condition ($datasourceYaml -match '(?m)^\s*access:\s*proxy\s*$') `
    -Description "datasource access is 'proxy' (a browser cannot resolve a cluster Service itself)"

Confirm-That -Condition ($datasourceYaml -match ('(?m)^\s*url:\s*' + [regex]::Escape($prometheusServiceUrl) + '\s*$')) `
    -Description "datasource url is the #154 Prometheus Service: $prometheusServiceUrl"

Confirm-That -Condition ($datasourceYaml -match '(?m)^\s*isDefault:\s*true\s*$') `
    -Description "datasource is the default (a panel saved without an explicit datasource resolves to it)"

Confirm-That -Condition ($datasourceYaml -match '(?m)^\s*editable:\s*false\s*$') `
    -Description "datasource is not UI-editable (Grafana's database is on an emptyDir)"

Confirm-That -Condition ($datasourceYaml -match '(?m)^\s*timeInterval:\s*15s\s*$') `
    -Description "datasource timeInterval matches the Prometheus scrape_interval (15s)"

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "3. The provider looks where the dashboards are mounted."

$providerYaml = Get-ConfigMapDataValue -Path $providerPath -Key "pulsestream.yaml"

Confirm-That -Condition ($providerYaml -match ('(?m)^\s*path:\s*' + [regex]::Escape($dashboardMountPath) + '\s*$')) `
    -Description "provider path is the documented dashboard mount: $dashboardMountPath"

Confirm-That -Condition ($providerYaml -match '(?m)^\s*type:\s*file\s*$') `
    -Description "provider type is 'file'"

Confirm-That -Condition ($providerYaml -match '(?m)^\s*folder:\s*PulseStream\s*$') `
    -Description "provider folder is 'PulseStream'"

Confirm-That -Condition ($providerYaml -match '(?m)^\s*allowUiUpdates:\s*false\s*$') `
    -Description "provider disallows UI updates (a ConfigMap volume is read-only, so a UI save is silently lost)"

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "4. Every dashboard in the ConfigMap is valid, addressable JSON."

$dashboardKeys = Get-ConfigMapDataKey -Path $dashboardsPath

Confirm-That -Condition ($dashboardKeys.Count -gt 0) `
    -Description "dashboards ConfigMap has at least one entry"

$dashboards = [ordered]@{}

foreach ($key in $dashboardKeys) {
    Confirm-That -Condition ($key -like "*.json") `
        -Description "dashboard entry '$key' is named .json (the file provider ignores anything else)"

    $parsed = $null
    $parseError = ""
    try {
        $parsed = Get-ConfigMapDataValue -Path $dashboardsPath -Key $key | ConvertFrom-Json
    } catch {
        $parseError = ": " + $_.Exception.Message
    }

    Confirm-That -Condition ($null -ne $parsed) `
        -Description "dashboard entry '$key' parses as JSON$parseError"

    if ($null -ne $parsed) {
        $dashboards[$key] = $parsed
    }
}

foreach ($key in $dashboards.Keys) {
    $dashboard = $dashboards[$key]

    Confirm-That -Condition (-not [string]::IsNullOrWhiteSpace([string] $dashboard.uid)) `
        -Description "'$key' declares a uid (without one Grafana assigns a new one on every provisioning sweep)"

    Confirm-That -Condition (-not [string]::IsNullOrWhiteSpace([string] $dashboard.title)) `
        -Description "'$key' declares a title"

    $panelDatasourceUids = @()
    foreach ($panel in $dashboard.panels) {
        $panelDatasourceUids += [string] $panel.datasource.uid
    }

    $distinctUids = [string]::Join(', ', @($panelDatasourceUids | Sort-Object -Unique))
    $wrongUids = @($panelDatasourceUids | Where-Object { $_ -ne "prometheus" })

    Confirm-That -Condition ($wrongUids.Count -eq 0) `
        -Description "'$key' resolves every panel to uid 'prometheus' (found: $distinctUids)"

    $raw = Get-ConfigMapDataValue -Path $dashboardsPath -Key $key

    Confirm-That -Condition ($raw -notmatch '\$\{DS_') `
        -Description "'$key' has no DS_ datasource input variable ('export for sharing externally' breaks the stable UID)"
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "5. Queries select only on labels the in-cluster Prometheus produces."
#
# #154 scrapes one job per workload and relabels namespace, pod and node onto
# each series, so a workload is identified by `job` - the same selector the
# Compose dashboards use. A panel selecting on a label that scrape config never
# writes (`service`, say) is not an error: it matches nothing and draws an empty
# graph.
#
# The expected label set is READ FROM #154 when that file is on disk, so this
# test tracks the scrape config instead of restating it. Before this branch is
# rebased onto #154 the file is absent and the documented set above is used;
# the assertions are otherwise identical.

$clusterLabels = $defaultClusterLabels
$scrapeJobNames = @()
$labelSource = "the documented #154 contract (prometheus-values.yaml is not on this branch yet)"

if (Test-Path -LiteralPath $prometheusValuesPath -PathType Leaf) {
    $prometheusValues = ConvertFrom-KubernetesYaml -Path $prometheusValuesPath

    $derivedLabels = [System.Collections.Generic.List[string]]::new()
    # Written by Prometheus itself for every target in every job, so they are
    # never the output of a relabel rule.
    $derivedLabels.Add("job") | Out-Null
    $derivedLabels.Add("instance") | Out-Null

    $derivedJobs = [System.Collections.Generic.List[string]]::new()

    # ConvertFrom-KubernetesYaml returns each mapping as a PSCustomObject, so
    # the job names are properties rather than dictionary keys.
    foreach ($scrapeConfigProperty in $prometheusValues.scrapeConfigs.PSObject.Properties) {
        $jobName = $scrapeConfigProperty.Name
        $scrapeConfig = $scrapeConfigProperty.Value

        if ($scrapeConfig.enabled -ne $true) {
            continue
        }

        $derivedJobs.Add([string] $jobName) | Out-Null

        foreach ($rule in $scrapeConfig.relabel_configs) {
            $targetLabel = [string] $rule.target_label

            # `__address__`, `__metrics_path__` and friends are consumed by
            # Prometheus and dropped before storage; they never reach a query.
            if ([string]::IsNullOrWhiteSpace($targetLabel) -or $targetLabel.StartsWith("__")) {
                continue
            }

            if (-not $derivedLabels.Contains($targetLabel)) {
                $derivedLabels.Add($targetLabel) | Out-Null
            }
        }
    }

    $clusterLabels = $derivedLabels.ToArray()
    $scrapeJobNames = $derivedJobs.ToArray()
    $labelSource = "infrastructure/kubernetes/monitoring/prometheus-values.yaml (#154)"
}

Write-Host "  (label contract read from $labelSource)"
Write-Host "  (labels: $([string]::Join(', ', $clusterLabels)))"

$allowedLabels = @($clusterLabels) + $micrometerLabels

foreach ($key in $dashboards.Keys) {
    foreach ($expression in (Get-DashboardExpression -Dashboard $dashboards[$key])) {
        $selectors = Get-GrafanaExpressionSelectorLabel -Expression $expression
        $unknown = @($selectors | Where-Object { $allowedLabels -notcontains $_ })

        Confirm-That -Condition ($unknown.Count -eq 0) `
            -Description ("'$key' selects only on labels the cluster produces" +
                $(if ($unknown.Count -gt 0) { " (unknown: $([string]::Join(', ', $unknown)))" } else { "" }) +
                ": $expression")

        # The specific regression this PR was reviewed for: the dashboards were
        # written against a `service` label no scrape config in #154 creates.
        Confirm-That -Condition ($selectors -notcontains "service") `
            -Description "'$key' does not select on a 'service' label: $expression"

        # A literal job= selector has to name a job #154 actually defines, when
        # #154 is on disk to be checked against.
        if ($scrapeJobNames.Count -gt 0) {
            foreach ($jobValue in (Get-GrafanaExpressionLabelValue -Expression $expression -Label "job")) {
                Confirm-That -Condition ($scrapeJobNames -contains $jobValue) `
                    -Description "'$key' selects job=`"$jobValue`", which is a scrape job in prometheus-values.yaml"
            }
        }
    }

    foreach ($variable in $dashboards[$key].templating.list) {
        $query = [string] $variable.query
        $enumerated = [regex]::Match($query, 'label_values\(\s*(?:.+?,)?\s*(?<label>[A-Za-z_][A-Za-z0-9_]*)\s*\)')

        Confirm-That -Condition ($enumerated.Success -and $clusterLabels -contains $enumerated.Groups['label'].Value) `
            -Description "'$key' variable '$($variable.name)' enumerates a label the cluster has: $query"
    }
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "6. The cluster set and the Compose set describe the same dashboards."
#
# Both deployments identify a workload by `job`, so most expressions are now
# identical across the two sets; what still differs is the per-pod breakdown in
# Service Health, which has no meaning in Compose. The structure must not
# differ: a panel added to one and not the other is how the two environments
# start showing different things under the same dashboard name.

foreach ($key in $dashboards.Keys) {
    $composePath = Join-Path $composeDashboardRoot $key

    Confirm-That -Condition (Test-Path -LiteralPath $composePath -PathType Leaf) `
        -Description "'$key' has a Compose counterpart at observability/grafana/dashboards/$key"

    if (-not (Test-Path -LiteralPath $composePath -PathType Leaf)) {
        continue
    }

    $compose = Get-Content -LiteralPath $composePath -Raw | ConvertFrom-Json
    $cluster = $dashboards[$key]

    Confirm-That -Condition ($cluster.uid -eq $compose.uid) `
        -Description "'$key' keeps the shared uid '$($compose.uid)'"

    Confirm-That -Condition ($cluster.title -eq $compose.title) `
        -Description "'$key' keeps the shared title '$($compose.title)'"

    $clusterPanelIds = [string]::Join(',', @($cluster.panels | ForEach-Object { [int] $_.id } | Sort-Object))
    $composePanelIds = [string]::Join(',', @($compose.panels | ForEach-Object { [int] $_.id } | Sort-Object))

    Confirm-That -Condition ($clusterPanelIds -eq $composePanelIds) `
        -Description "'$key' has the same panel ids as the Compose copy (cluster: $clusterPanelIds; compose: $composePanelIds)"

    foreach ($composePanel in $compose.panels) {
        $clusterPanel = @($cluster.panels | Where-Object { [int] $_.id -eq [int] $composePanel.id })[0]

        if ($null -eq $clusterPanel) {
            continue
        }

        Confirm-That -Condition ($clusterPanel.title -eq $composePanel.title) `
            -Description "'$key' panel $($composePanel.id) keeps the title '$($composePanel.title)'"

        Confirm-That -Condition (@($clusterPanel.targets).Count -eq @($composePanel.targets).Count) `
            -Description "'$key' panel $($composePanel.id) has the same number of queries as the Compose copy"
    }
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "7. A stale or edited dashboard in Grafana is detected as stale."
#
# ../validate-grafana-kubernetes.ps1 fetches each dashboard from
# /api/dashboards/uid/<uid> and compares the served model with the committed
# JSON, because identity does not prove content: a dashboard loaded before a
# change to dashboards-configmap.yaml keeps its uid, title and folder, so
# /api/search cannot tell it apart from a current one. These cases pin down what
# that comparison catches - and, as importantly, what it must not flag, since a
# false positive there would fail every run against a healthy cluster.

$reference = $dashboards["service-health.json"]

Confirm-That -Condition ($null -ne $reference) `
    -Description "the comparison cases have a dashboard to work from (service-health.json)"

if ($null -ne $reference) {
    # --- must not flag ----------------------------------------------------
    $identical = Copy-DashboardModel -Dashboard $reference
    $differences = Compare-GrafanaDashboardModel -Committed $reference -Loaded $identical

    Confirm-That -Condition ($differences.Count -eq 0) `
        -Description "an unchanged dashboard reports no differences (got: $([string]::Join('; ', $differences)))"

    # What Grafana actually serves back: it stamps id/version onto the model,
    # fills in refId and a datasource on every target, and normalises
    # whitespace-insignificant formatting. None of that is a difference.
    $normalized = Copy-DashboardModel -Dashboard $reference
    $normalized | Add-Member -NotePropertyName "id" -NotePropertyValue 42 -Force
    $normalized | Add-Member -NotePropertyName "version" -NotePropertyValue 7 -Force
    $refIds = @("A", "B", "C")
    $refIdIndex = 0
    foreach ($panel in $normalized.panels) {
        foreach ($target in $panel.targets) {
            $target | Add-Member -NotePropertyName "refId" -NotePropertyValue $refIds[$refIdIndex % $refIds.Count] -Force
            $target | Add-Member -NotePropertyName "datasource" `
                -NotePropertyValue ([pscustomobject]@{ type = "prometheus"; uid = "prometheus" }) -Force
            $target.expr = "  " + ($target.expr -replace ' by \(', "  by  (") + " "
            $refIdIndex++
        }
    }

    $differences = Compare-GrafanaDashboardModel -Committed $reference -Loaded $normalized

    Confirm-That -Condition ($differences.Count -eq 0) `
        -Description "Grafana's own additions (id, version, refId, datasource, whitespace) are not differences (got: $([string]::Join('; ', $differences)))"

    # A viewer selecting a value in a template variable changes `current`, and
    # that is not staleness.
    $viewed = Copy-DashboardModel -Dashboard $reference
    $viewed.templating.list[0].current = [pscustomobject]@{ text = "ingestion-service"; value = "ingestion-service" }

    $differences = Compare-GrafanaDashboardModel -Committed $reference -Loaded $viewed

    Confirm-That -Condition ($differences.Count -eq 0) `
        -Description "a variable left on a different selected value is not a difference (got: $([string]::Join('; ', $differences)))"

    # --- must flag --------------------------------------------------------
    # The exact regression this PR was reviewed for: a dashboard loaded before
    # the label contract was corrected. Same uid, same title, same folder, same
    # panel ids - and every panel empty.
    $stale = Copy-DashboardModel -Dashboard $reference
    foreach ($panel in $stale.panels) {
        foreach ($target in $panel.targets) {
            $target.expr = $target.expr.Replace('job=~"$job"', 'service=~"$service"')
        }
    }
    $stale.templating.list[0].name = "service"
    $stale.templating.list[0].query = "label_values(process_uptime_seconds, service)"

    $differences = Compare-GrafanaDashboardModel -Committed $reference -Loaded $stale

    Confirm-That -Condition ($differences.Count -gt 0) `
        -Description "a dashboard still carrying the old 'service' selector is reported as stale"

    Confirm-That -Condition (@($differences | Where-Object { $_ -match "service=~" }).Count -gt 0) `
        -Description "the report names the query that drifted (got: $([string]::Join('; ', $differences)))"

    Confirm-That -Condition (@($differences | Where-Object { $_ -match "template variable" }).Count -gt 0) `
        -Description "the report names the template variable that drifted"

    # One panel silently reverted to an older query, the rest current: the
    # partial case a whole-document equality check would catch but a
    # per-dashboard checksum in the ConfigMap would not explain.
    $onePanelStale = Copy-DashboardModel -Dashboard $reference
    $onePanelStale.panels[0].targets[0].expr = 'sum(jvm_memory_used_bytes{job=~"$job"}) by (job)'

    $differences = Compare-GrafanaDashboardModel -Committed $reference -Loaded $onePanelStale

    Confirm-That -Condition (@($differences | Where-Object { $_ -match "panel $($reference.panels[0].id)" }).Count -eq 1) `
        -Description "a single drifted query is reported once, against its own panel (got: $([string]::Join('; ', $differences)))"

    # A dashboard someone edited and saved through the UI under the same uid.
    $renamed = Copy-DashboardModel -Dashboard $reference
    $renamed.panels[1].title = "CPU"

    $differences = Compare-GrafanaDashboardModel -Committed $reference -Loaded $renamed

    Confirm-That -Condition (@($differences | Where-Object { $_ -match "is titled 'CPU'" }).Count -eq 1) `
        -Description "a renamed panel is reported (got: $([string]::Join('; ', $differences)))"

    # A dashboard loaded from a ConfigMap that predates a panel being added.
    $missingPanel = Copy-DashboardModel -Dashboard $reference
    $droppedId = [int] $missingPanel.panels[-1].id
    $missingPanel.panels = @($missingPanel.panels | Select-Object -SkipLast 1)

    $differences = Compare-GrafanaDashboardModel -Committed $reference -Loaded $missingPanel

    Confirm-That -Condition (@($differences | Where-Object { $_ -match "missing panel\(s\) $droppedId" }).Count -eq 1) `
        -Description "a panel missing from the loaded dashboard is reported (got: $([string]::Join('; ', $differences)))"

    # A panel added in the UI, or left behind by an older ConfigMap.
    $extraPanel = Copy-DashboardModel -Dashboard $reference
    $extraPanel.panels = @($extraPanel.panels) + @([pscustomobject]@{
        id      = 99
        title   = "Scratch"
        targets = @([pscustomobject]@{ expr = "up" })
    })

    $differences = Compare-GrafanaDashboardModel -Committed $reference -Loaded $extraPanel

    Confirm-That -Condition (@($differences | Where-Object { $_ -match "panel\(s\) 99 that are not committed" }).Count -eq 1) `
        -Description "an uncommitted panel in the loaded dashboard is reported"

    # An extra query added to an existing panel: same panel id, same title.
    $extraQuery = Copy-DashboardModel -Dashboard $reference
    $extraQuery.panels[0].targets = @($extraQuery.panels[0].targets) + @([pscustomobject]@{ expr = "up" })

    $differences = Compare-GrafanaDashboardModel -Committed $reference -Loaded $extraQuery

    Confirm-That -Condition (@($differences | Where-Object { $_ -match "quer\(y/ies\) loaded" }).Count -eq 1) `
        -Description "an added query on an unchanged panel is reported"

    # A different dashboard served under the requested uid - what a UID
    # collision between two provisioning sources looks like.
    $wrongDashboard = Copy-DashboardModel -Dashboard $dashboards["ingestion-metrics.json"]
    $wrongDashboard.uid = $reference.uid

    $differences = Compare-GrafanaDashboardModel -Committed $reference -Loaded $wrongDashboard

    Confirm-That -Condition (@($differences | Where-Object { $_ -match "loaded title is" }).Count -eq 1) `
        -Description "a different dashboard served under the committed uid is reported"

    # The source prefix is what makes a failure message point at one dashboard
    # when both are being checked in the same run.
    $differences = Compare-GrafanaDashboardModel -Committed $reference -Loaded $renamed -Source "loaded dashboard 'x'"

    Confirm-That -Condition (@($differences | Where-Object { $_.StartsWith("loaded dashboard 'x': ") }).Count -eq $differences.Count) `
        -Description "every difference is prefixed with the source it was found in"
}

# ---------------------------------------------------------------------------
Write-Host ""

if ($failures.Count -gt 0) {
    Write-Host "[FAIL] $($failures.Count) of $assertionCount assertions failed."
    exit 1
}

Write-Host "[ok] All $assertionCount assertions passed."
