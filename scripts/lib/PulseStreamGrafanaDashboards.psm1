# Dashboard-model helpers shared by the offline and the live validators (#156).
#
# Two things live here rather than inside validate-grafana-kubernetes.ps1:
#
#   * expression handling - flattening a dashboard into its panel queries and
#     interpolating the dashboard variables Grafana would interpolate before
#     sending PromQL to Prometheus;
#   * Compare-GrafanaDashboardModel, which says whether the dashboard Grafana
#     has loaded is the dashboard this repository committed.
#
# The comparison is a module function so the no-cluster tests can exercise it
# against synthetic "loaded" models - a stale copy, a renamed panel, a query
# that still selects on a label the cluster does not produce. Those cases are
# unreachable from a validator that only runs against a live Grafana, and they
# are exactly the cases the live validator has to catch.

# Everything a panel query needs to be executed and reported on, in document
# order. Dashboards nest panels one level inside a `row`, so rows are walked
# too; a row itself has no targets.
function Get-GrafanaDashboardQuery {
    param([Parameter(Mandatory)] $Dashboard)

    $queries = [System.Collections.Generic.List[object]]::new()

    function Add-PanelQuery {
        param($Panel)

        foreach ($target in $Panel.targets) {
            $expression = [string] $target.expr

            if ([string]::IsNullOrWhiteSpace($expression)) {
                continue
            }

            $queries.Add([pscustomobject]@{
                PanelId    = [int] $Panel.id
                PanelTitle = [string] $Panel.title
                RefId      = [string] $target.refId
                Expression = $expression
            }) | Out-Null
        }
    }

    foreach ($panel in $Dashboard.panels) {
        Add-PanelQuery -Panel $panel

        foreach ($nested in $panel.panels) {
            Add-PanelQuery -Panel $nested
        }
    }

    return , $queries.ToArray()
}

# Grafana interpolates dashboard variables before sending PromQL to Prometheus,
# so a committed expression is not valid PromQL as written. The substitutions
# are derived from the dashboard rather than hard-coded, and anything left
# unresolved afterwards is a hard failure in the caller - a validator that
# quietly skipped an expression it could not interpolate would report success
# over a panel nobody had checked.
function Get-GrafanaVariableSubstitution {
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

# Returns the interpolated expression, or $null when a variable this function
# does not know is left in it. The caller decides what an unknown variable
# means; both callers treat it as a failure, but the live validator has to
# report it through its own permanent-failure path.
function Resolve-GrafanaExpression {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Expression,
        [Parameter(Mandatory)] $Substitutions,
        [ref] $UnresolvedVariable
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
    $unresolved = [regex]::Match($resolved, '\$(?<variable>[A-Za-z_][A-Za-z0-9_]*)')
    if ($unresolved.Success) {
        if ($null -ne $UnresolvedVariable) {
            $UnresolvedVariable.Value = '$' + $unresolved.Groups['variable'].Value
        }
        return $null
    }

    return $resolved
}

# Every label a PromQL expression selects on, so a query can be held to the
# labels the scrape configuration actually produces. Matches `job=`, `job=~`,
# `job!=` and `job!~` inside a selector, and ignores metric names and functions.
function Get-GrafanaExpressionSelectorLabel {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Expression)

    $labels = [System.Collections.Generic.List[string]]::new()

    foreach ($match in [regex]::Matches($Expression, '(?<label>[A-Za-z_][A-Za-z0-9_]*)\s*(=~|!~|!=|=)\s*"')) {
        $label = $match.Groups['label'].Value
        if (-not $labels.Contains($label)) {
            $labels.Add($label) | Out-Null
        }
    }

    return , $labels.ToArray()
}

# The literal values an expression pins a label to: `job="ingestion-service"`
# yields `ingestion-service`. Used by the live validator to check that the
# scrape jobs the dashboards name exist in Prometheus before it blames a panel
# for returning nothing.
function Get-GrafanaExpressionLabelValue {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Expression,
        [Parameter(Mandatory)] [string] $Label
    )

    $values = [System.Collections.Generic.List[string]]::new()
    $pattern = [regex]::Escape($Label) + '\s*=\s*"(?<value>[^"]+)"'

    foreach ($match in [regex]::Matches($Expression, $pattern)) {
        $value = $match.Groups['value'].Value
        if (-not $values.Contains($value)) {
            $values.Add($value) | Out-Null
        }
    }

    return , $values.ToArray()
}

# Does the dashboard Grafana loaded still describe what this repository
# committed? Returns one string per difference, empty when they agree.
#
# WHAT IS COMPARED, and why not the whole model. Grafana rewrites a provisioned
# dashboard on the way in: it stamps `id` and `version`, fills in `refId` and a
# datasource on every target, and expands defaults the committed JSON leaves
# out. Comparing the models verbatim would fail on every one of those. What is
# compared is what a panel needs in order to draw the right thing:
#
#   uid, title      identity - a stale dashboard usually keeps both, which is
#                   why identity alone proves nothing
#   panel ids       a panel added or removed since the ConfigMap was applied
#   panel titles    a panel renamed under a stable id
#   expressions     the queries themselves, whitespace-normalised - this is the
#                   one that catches a dashboard loaded before a label-contract
#                   change and never reloaded
#   variables       name and query of each template variable; `current` is
#                   excluded because a viewer changes it just by using the
#                   dashboard
function Compare-GrafanaDashboardModel {
    param(
        [Parameter(Mandatory)] $Committed,
        [Parameter(Mandatory)] $Loaded,
        [string] $Source = "dashboard"
    )

    $differences = [System.Collections.Generic.List[string]]::new()

    function Add-Difference {
        param([string] $Message)
        $differences.Add("${Source}: $Message") | Out-Null
    }

    # Comparing `sum(x) by (job)` with `sum(x)  by (job)` as different text
    # would be a false positive; every other character is significant.
    function Get-NormalizedExpression {
        param([AllowEmptyString()] [string] $Expression)
        return ([regex]::Replace([string] $Expression, '\s+', ' ')).Trim()
    }

    if ([string] $Loaded.uid -ne [string] $Committed.uid) {
        Add-Difference "loaded uid is '$($Loaded.uid)', committed uid is '$($Committed.uid)'"
    }

    if ([string] $Loaded.title -ne [string] $Committed.title) {
        Add-Difference "loaded title is '$($Loaded.title)', committed title is '$($Committed.title)'"
    }

    $committedPanels = @($Committed.panels)
    $loadedPanels = @($Loaded.panels)

    $committedIds = @($committedPanels | ForEach-Object { [int] $_.id } | Sort-Object)
    $loadedIds = @($loadedPanels | ForEach-Object { [int] $_.id } | Sort-Object)

    $missing = @($committedIds | Where-Object { $loadedIds -notcontains $_ })
    $extra = @($loadedIds | Where-Object { $committedIds -notcontains $_ })

    if ($missing.Count -gt 0) {
        Add-Difference "the loaded dashboard is missing panel(s) $([string]::Join(', ', $missing))"
    }

    if ($extra.Count -gt 0) {
        Add-Difference "the loaded dashboard has panel(s) $([string]::Join(', ', $extra)) that are not committed"
    }

    foreach ($committedPanel in $committedPanels) {
        $loadedPanel = @($loadedPanels | Where-Object { [int] $_.id -eq [int] $committedPanel.id })[0]

        if ($null -eq $loadedPanel) {
            continue
        }

        if ([string] $loadedPanel.title -ne [string] $committedPanel.title) {
            Add-Difference "panel $($committedPanel.id) is titled '$($loadedPanel.title)', committed as '$($committedPanel.title)'"
        }

        $committedExpressions = @(@($committedPanel.targets) | ForEach-Object { Get-NormalizedExpression $_.expr })
        $loadedExpressions = @(@($loadedPanel.targets) | ForEach-Object { Get-NormalizedExpression $_.expr })

        if ($committedExpressions.Count -ne $loadedExpressions.Count) {
            Add-Difference ("panel $($committedPanel.id) ('$($committedPanel.title)') has $($loadedExpressions.Count) " +
                "quer(y/ies) loaded, $($committedExpressions.Count) committed")
            continue
        }

        for ($index = 0; $index -lt $committedExpressions.Count; $index++) {
            if ($loadedExpressions[$index] -ne $committedExpressions[$index]) {
                Add-Difference ("panel $($committedPanel.id) ('$($committedPanel.title)') query $($index + 1) is loaded as " +
                    "'$($loadedExpressions[$index])', committed as '$($committedExpressions[$index])'")
            }
        }
    }

    $committedVariables = @($Committed.templating.list)
    $loadedVariables = @($Loaded.templating.list)

    $committedNames = @($committedVariables | ForEach-Object { [string] $_.name })
    $loadedNames = @($loadedVariables | ForEach-Object { [string] $_.name })

    foreach ($name in $committedNames) {
        if ($loadedNames -notcontains $name) {
            Add-Difference "the loaded dashboard has no template variable '$name'"
        }
    }

    foreach ($name in $loadedNames) {
        if ($committedNames -notcontains $name) {
            Add-Difference "the loaded dashboard has a template variable '$name' that is not committed"
        }
    }

    foreach ($committedVariable in $committedVariables) {
        $loadedVariable = @($loadedVariables | Where-Object { [string] $_.name -eq [string] $committedVariable.name })[0]

        if ($null -eq $loadedVariable) {
            continue
        }

        $committedQuery = Get-NormalizedExpression ([string] $committedVariable.query)
        $loadedQuery = Get-NormalizedExpression ([string] $loadedVariable.query)

        if ($loadedQuery -ne $committedQuery) {
            Add-Difference ("template variable '$($committedVariable.name)' is loaded as '$loadedQuery', " +
                "committed as '$committedQuery'")
        }
    }

    return , $differences.ToArray()
}

Export-ModuleMember -Function `
    Get-GrafanaDashboardQuery, `
    Get-GrafanaVariableSubstitution, `
    Resolve-GrafanaExpression, `
    Get-GrafanaExpressionSelectorLabel, `
    Get-GrafanaExpressionLabelValue, `
    Compare-GrafanaDashboardModel
