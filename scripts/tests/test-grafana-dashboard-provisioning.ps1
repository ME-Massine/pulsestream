# Structural checks over the Grafana provisioning ConfigMaps (#156).
#
# Everything here reads committed files, so it needs no cluster and no Grafana.
# It exists because the failure mode this feature has is silent: a provisioned
# dashboard whose datasource UID, label selector or provider path is wrong does
# not error anywhere - Grafana starts, the dashboard opens, and every panel is
# empty. Each assertion below is one of the ways that happens.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$grafanaRoot = Join-Path $repositoryRoot "infrastructure/kubernetes/monitoring/grafana"
$composeDashboardRoot = Join-Path $repositoryRoot "observability/grafana/dashboards"

# Where dashboards-configmap.yaml has to be mounted for the provider in
# dashboard-provider-configmap.yaml to find it. The two files are applied
# independently, so nothing at apply time notices when they disagree.
$dashboardMountPath = "/etc/grafana/dashboards"

# The Service #154 publishes Prometheus on, spelled as a datasource URL.
$prometheusServiceUrl = "http://prometheus-server.monitoring.svc:80"

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

# The repository's YAML reader (scripts/lib/PulseStreamYaml.psm1) strips
# everything after a '#' and has no literal block scalar support, so it cannot
# read a ConfigMap whose values are JSON. These two readers handle the shape
# this file actually has: a 'key: |' line followed by an indented block.
function Get-ConfigMapDataKeys {
    param([Parameter(Mandatory)] [string] $Path)

    $keys = [System.Collections.Generic.List[string]]::new()
    $inData = $false

    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^data:\s*$') {
            $inData = $true
            continue
        }

        if (-not $inData) {
            continue
        }

        # A non-indented, non-blank line ends the 'data' mapping.
        if ($line.Trim().Length -gt 0 -and $line -notmatch '^\s') {
            break
        }

        if ($line -match '^  (?<key>[A-Za-z0-9][A-Za-z0-9._-]*):\s*\|\s*$') {
            $keys.Add($Matches['key']) | Out-Null
        }
    }

    return $keys.ToArray()
}

function Get-ConfigMapDataValue {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Key
    )

    $lines = @(Get-Content -LiteralPath $Path)
    $start = -1

    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match ('^  ' + [regex]::Escape($Key) + ':\s*\|\s*$')) {
            $start = $index + 1
            break
        }
    }

    if ($start -lt 0) {
        throw "ConfigMap '$Path' has no literal block entry named '$Key'."
    }

    $collected = [System.Collections.Generic.List[string]]::new()

    for ($index = $start; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]

        if ($line.Trim().Length -eq 0) {
            $collected.Add("") | Out-Null
            continue
        }

        if ($line -notmatch '^    ') {
            break
        }

        $collected.Add($line.Substring(4)) | Out-Null
    }

    return [string]::Join([Environment]::NewLine, $collected.ToArray())
}

# Every PromQL expression in a dashboard, in document order.
function Get-DashboardExpression {
    param([Parameter(Mandatory)] $Dashboard)

    $expressions = [System.Collections.Generic.List[string]]::new()

    foreach ($panel in $Dashboard.panels) {
        foreach ($target in $panel.targets) {
            $expressions.Add([string] $target.expr) | Out-Null
        }
    }

    return $expressions.ToArray()
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

$dashboardKeys = Get-ConfigMapDataKeys -Path $dashboardsPath

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
Write-Host "5. Queries select on the label the in-cluster Prometheus produces."
#
# ../configmap.yaml gives every pod-discovered series job="kubernetes-pods" and
# relabels the workload name into 'service'. A panel that kept the Compose
# selector job="ingestion-service" matches nothing and draws an empty graph
# without reporting an error anywhere.

foreach ($key in $dashboards.Keys) {
    foreach ($expression in (Get-DashboardExpression -Dashboard $dashboards[$key])) {
        Confirm-That -Condition ($expression -notmatch 'job\s*=') `
            -Description "'$key' does not select on the 'job' label: $expression"

        Confirm-That -Condition ($expression -match 'service\s*=~?') `
            -Description "'$key' selects on the 'service' label: $expression"
    }

    foreach ($variable in $dashboards[$key].templating.list) {
        Confirm-That -Condition ([string] $variable.query -notmatch ',\s*job\s*\)') `
            -Description "'$key' variable '$($variable.name)' enumerates a label the cluster has: $($variable.query)"
    }
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "6. The cluster set and the Compose set describe the same dashboards."
#
# The queries differ by design (see the header of dashboards-configmap.yaml).
# The structure must not: a panel added to one and not the other is how the two
# environments start showing different things under the same dashboard name.

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

if ($failures.Count -gt 0) {
    Write-Host "[FAIL] $($failures.Count) of $assertionCount assertions failed."
    exit 1
}

Write-Host "[ok] All $assertionCount assertions passed."
