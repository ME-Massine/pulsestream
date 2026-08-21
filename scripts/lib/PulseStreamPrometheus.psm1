# Shared structural checks for the in-cluster Prometheus scrape configuration (#154).
#
# Two callers assert the same shape and must not drift:
#
#   - scripts/validate-prometheus-kubernetes.ps1 parses the `prometheus.yml`
#     key of the applied ConfigMap on a live cluster.
#   - scripts/tests/test-prometheus-scrape-config.ps1 parses the committed
#     Helm values file, with no cluster.
#
# Both hand the parsed `prometheus.yml` mapping to Confirm-PrometheusScrapeConfig
# below, so a scrape configuration that is edited in the repository but never
# applied - or applied but never committed - fails the same way in both places.

# Imported without -Force so a calling script that already imported
# PulseStreamValidation for its own use does not lose Confirm-Condition when
# this module loads (see PulseStreamAutoscaling.psm1).
Import-Module (Join-Path $PSScriptRoot "PulseStreamValidation.psm1")

# The jobs the platform services are scraped under. The names are also the
# `job` label on every resulting series, which is what
# scripts/validate-prometheus-metrics.ps1 and the queries in the README select
# on, so they are fixed here rather than spelled out per call site.
function Get-PrometheusServiceJobNames {
    return @("ingestion-service", "query-service")
}

# Prometheus scraping itself. Kept separate from the service jobs because it
# proves the server is collecting at all, independently of whether any platform
# workload is deployed.
function Get-PrometheusSelfJobName {
    return "prometheus"
}

function Get-PrometheusScrapeJob {
    param($Config, [string] $JobName)

    return @($Config.scrape_configs | Where-Object { $_.job_name -eq $JobName }) | Select-Object -First 1
}

# The Helm values and the applied ConfigMap describe the same configuration in
# two different shapes, and only one of them can be asserted about directly:
#
#   values file:  scrapeConfigs is a MAP keyed by job name, each entry carrying
#                 an `enabled` flag, and the interval lives under server.global
#   ConfigMap:    prometheus.yml is what the chart rendered - a `global` mapping
#                 and a flat `scrape_configs` LIST of `job_name` entries
#
# This projects the values file onto the rendered shape so both callers assert
# against the same object. Disabled entries are dropped exactly as the chart
# drops them, so a job switched off in the values file fails the checks here for
# the same reason it would be missing from the cluster.
function ConvertFrom-PrometheusHelmValues {
    param([Parameter(Mandatory)] $Values)

    $jobs = [System.Collections.Generic.List[object]]::new()

    foreach ($property in @($Values.scrapeConfigs.PSObject.Properties)) {
        $entry = $property.Value

        # `enabled` is optional and defaults to true (chart values.yaml), so
        # only an explicit false disables a job. The YAML reader hands back
        # either a boolean or the string form depending on how it is written.
        $enabled = $entry.enabled
        if ($enabled -eq $false -or "$enabled" -eq "false") {
            continue
        }

        # The chart uses the map key as the job name unless the entry overrides
        # it with a non-empty job_name.
        $jobName = if ([string]::IsNullOrWhiteSpace($entry.job_name)) { $property.Name } else { $entry.job_name }

        $job = [ordered]@{ job_name = $jobName }
        foreach ($field in @($entry.PSObject.Properties)) {
            if ($field.Name -in @("enabled", "job_name")) { continue }
            $job[$field.Name] = $field.Value
        }

        $jobs.Add([pscustomobject] $job) | Out-Null
    }

    return [pscustomobject]@{
        global         = $Values.server.global
        scrape_configs = $jobs.ToArray()
    }
}

# A relabel rule that copies a discovery meta label onto a stored label. Meta
# labels are discarded after relabeling, so `namespace` and `pod` only exist on
# the series if a rule like this puts them there - and prometheus-adapter can
# only attach a metric to a pod when both are present.
function Test-RelabelCopiesMetaLabel {
    param($Job, [string] $SourceLabel, [string] $TargetLabel)

    foreach ($rule in @($Job.relabel_configs)) {
        if ($null -eq $rule) { continue }
        if ($rule.target_label -ne $TargetLabel) { continue }
        # `action` defaults to `replace`, which is the copy this looks for; an
        # explicit different action with the same target_label is not one.
        if ($null -ne $rule.action -and $rule.action -ne "replace") { continue }
        if (@($rule.source_labels) -contains $SourceLabel) { return $true }
    }

    return $false
}

function Test-RelabelKeepsLabel {
    param($Job, [string] $SourceLabel, [string] $Regex)

    foreach ($rule in @($Job.relabel_configs)) {
        if ($null -eq $rule) { continue }
        if ($rule.action -ne "keep") { continue }
        if ((@($rule.source_labels) -contains $SourceLabel) -and $rule.regex -eq $Regex) { return $true }
    }

    return $false
}

function Confirm-PrometheusScrapeConfig {
    param(
        [Parameter(Mandatory)] $Config,
        [string] $Description = "the Prometheus scrape configuration"
    )

    $scrapeInterval = $Config.global.scrape_interval
    Confirm-Condition `
        -Condition (-not [string]::IsNullOrWhiteSpace($scrapeInterval)) `
        -SuccessMessage "$Description sets a global scrape_interval ($scrapeInterval)" `
        -FailureMessage "$Description has no global scrape_interval. The prometheus-adapter rules rate over a 2m window and need several samples inside it"

    $selfJobName = Get-PrometheusSelfJobName
    $selfJob = Get-PrometheusScrapeJob -Config $Config -JobName $selfJobName
    Confirm-Condition `
        -Condition ($null -ne $selfJob) `
        -SuccessMessage "$Description scrapes Prometheus itself (job '$selfJobName')" `
        -FailureMessage "$Description has no '$selfJobName' job. Without it there is no target that proves the server is collecting when no platform workload is deployed"

    foreach ($jobName in Get-PrometheusServiceJobNames) {
        $job = Get-PrometheusScrapeJob -Config $Config -JobName $jobName

        Confirm-Condition `
            -Condition ($null -ne $job) `
            -SuccessMessage "$Description has a '$jobName' scrape job" `
            -FailureMessage "$Description has no scrape job named '$jobName'; that service's metrics would never be collected"

        Confirm-Condition `
            -Condition ($job.metrics_path -eq "/actuator/prometheus") `
            -SuccessMessage "'$jobName' scrapes /actuator/prometheus" `
            -FailureMessage "'$jobName' scrapes metrics_path '$($job.metrics_path)', not '/actuator/prometheus'. Spring Boot Actuator exposes the exposition format there and nowhere else, so every scrape would 404"

        # Pod discovery rather than a static or Service target: one target per
        # replica, each carrying the pod identity the adapter maps metrics onto.
        $roles = @(@($job.kubernetes_sd_configs) | ForEach-Object { $_.role })
        Confirm-Condition `
            -Condition ($roles -contains "pod") `
            -SuccessMessage "'$jobName' discovers targets with kubernetes_sd_configs role 'pod'" `
            -FailureMessage "'$jobName' has no kubernetes_sd_configs entry with role 'pod'. A static or Service target load-balances across replicas and produces series without pod identity, which prometheus-adapter cannot use"

        Confirm-Condition `
            -Condition (Test-RelabelKeepsLabel -Job $job -SourceLabel "__meta_kubernetes_pod_label_app_kubernetes_io_name" -Regex $jobName) `
            -SuccessMessage "'$jobName' keeps only pods labelled app.kubernetes.io/name=$jobName" `
            -FailureMessage "'$jobName' has no keep rule on __meta_kubernetes_pod_label_app_kubernetes_io_name matching '$jobName'. Pod discovery returns every visible pod, so without it the job would scrape unrelated workloads"

        Confirm-Condition `
            -Condition (Test-RelabelKeepsLabel -Job $job -SourceLabel "__meta_kubernetes_pod_container_port_name" -Regex "http") `
            -SuccessMessage "'$jobName' keeps only the 'http' container port" `
            -FailureMessage "'$jobName' has no keep rule on __meta_kubernetes_pod_container_port_name matching 'http'. A pod with several container ports becomes one target per port, and the extra targets fail every scrape"

        foreach ($labelPair in @(
            @{ Meta = "__meta_kubernetes_namespace"; Target = "namespace" },
            @{ Meta = "__meta_kubernetes_pod_name"; Target = "pod" }
        )) {
            Confirm-Condition `
                -Condition (Test-RelabelCopiesMetaLabel -Job $job -SourceLabel $labelPair.Meta -TargetLabel $labelPair.Target) `
                -SuccessMessage "'$jobName' copies $($labelPair.Meta) to the '$($labelPair.Target)' label" `
                -FailureMessage "'$jobName' has no relabel rule copying $($labelPair.Meta) to '$($labelPair.Target)'. Discovery meta labels are dropped after relabeling, and prometheus-adapter needs both 'namespace' and 'pod' on the series to attach a metric to a pod (infrastructure/kubernetes/autoscaling/README.md)"
        }
    }
}

Export-ModuleMember -Function Get-PrometheusServiceJobNames, Get-PrometheusSelfJobName, ConvertFrom-PrometheusHelmValues, Confirm-PrometheusScrapeConfig
