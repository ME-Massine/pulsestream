# Runs the Prometheus scrape-configuration checks against the committed Helm
# values. No cluster, no kubectl, no network, no Helm.
#
# The values file is read with scripts/lib/PulseStreamYaml.psm1, projected onto
# the shape the chart renders (ConvertFrom-PrometheusHelmValues) and handed to
# the same Confirm-PrometheusScrapeConfig that validate-prometheus-kubernetes.ps1
# calls on the applied ConfigMap. The committed configuration and the applied one
# therefore cannot drift apart in what they are allowed to be.
#
#   powershell -File scripts\tests\test-prometheus-scrape-config.ps1
#   pwsh -File scripts/tests/test-prometheus-scrape-config.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamYaml.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamPrometheus.psm1") -Force

$script:ValuesFile = Join-Path $PSScriptRoot "..\..\infrastructure\kubernetes\monitoring\prometheus-values.yaml"

function Get-Values {
    return ConvertFrom-KubernetesYaml -Path $script:ValuesFile
}

# Every case starts from a fresh parse, so a mutation cannot leak into the next
# one and no state has to be restored afterwards.
function Assert-ValidatorRejects {
    param(
        [scriptblock] $Mutation,
        [string] $ExpectedMessage,
        [string] $Description
    )

    $values = Get-Values
    & $Mutation $values

    try {
        Confirm-PrometheusScrapeConfig -Config (ConvertFrom-PrometheusHelmValues -Values $values)
    } catch {
        if ($_.Exception.Message -match $ExpectedMessage) {
            Write-Host "[ok] $Description"
            return
        }

        throw "Expected a rejection matching '$ExpectedMessage' for $Description, got: $($_.Exception.Message)"
    }

    throw "The structural validator accepted $Description."
}

$script:Config = ConvertFrom-PrometheusHelmValues -Values (Get-Values)
Confirm-PrometheusScrapeConfig -Config $script:Config

# The rendered job set must be exactly the documented one. The chart ships a
# large default `scrapeConfigs` map (API server, kubelet, cAdvisor,
# annotation-driven discovery) that survives unless each key is disabled in the
# values file, so an enabled default would show up here as an extra job.
$renderedJobs = @($script:Config.scrape_configs | ForEach-Object { $_.job_name })
$expectedJobs = @(Get-PrometheusSelfJobName) + @(Get-PrometheusServiceJobNames)

$unexpected = @($renderedJobs | Where-Object { $expectedJobs -notcontains $_ })
if ($unexpected.Count -gt 0) {
    throw "The values file enables scrape jobs that are not part of the documented target set: $($unexpected -join ', ')."
}

$missing = @($expectedJobs | Where-Object { $renderedJobs -notcontains $_ })
if ($missing.Count -gt 0) {
    throw "The values file does not enable the expected scrape job(s): $($missing -join ', ')."
}
Write-Host "[ok] the values file enables exactly the documented jobs: $($renderedJobs -join ', ')"

# telemetry-processor is deliberately absent: its actuator surface is on a
# loopback-bound management port, so a job for it would be a permanently failing
# target. This asserts the omission is the documented one rather than an
# oversight a later edit quietly "fixes".
if ($renderedJobs -contains "telemetry-processor") {
    throw "The values file scrapes telemetry-processor, whose /actuator/prometheus is not reachable from the pod network (see infrastructure/kubernetes/monitoring/README.md)."
}
Write-Host "[ok] telemetry-processor is not scraped while its management port stays loopback-bound"

# An entry disabled in the values file renders as no job at all, which is the
# same end state as deleting it. Both have to fail, and for the named job.
Assert-ValidatorRejects `
    -Mutation { param($values) $values.scrapeConfigs.'query-service'.enabled = $false } `
    -ExpectedMessage "no scrape job named 'query-service'" `
    -Description "a platform service job disabled in the values file was rejected"

Assert-ValidatorRejects `
    -Mutation { param($values) $values.scrapeConfigs.PSObject.Properties.Remove('prometheus') } `
    -ExpectedMessage "no 'prometheus' job" `
    -Description "a configuration that does not scrape Prometheus itself was rejected"

# A dropped key is valid YAML and installs cleanly - the chart just takes its
# own default - so each omission has to surface as a validation failure naming
# the field, not as a PowerShell error about a property on a null object.
Assert-ValidatorRejects `
    -Mutation { param($values) $values.server.global.PSObject.Properties.Remove('scrape_interval') } `
    -ExpectedMessage "no global scrape_interval" `
    -Description "a configuration without a global scrape_interval was rejected"

# The Actuator exposition lives at /actuator/prometheus only; the Prometheus
# default (/metrics) would 404 on every scrape.
Assert-ValidatorRejects `
    -Mutation { param($values) $values.scrapeConfigs.'ingestion-service'.metrics_path = "/metrics" } `
    -ExpectedMessage "not '/actuator/prometheus'" `
    -Description "a service job scraping the default metrics path was rejected"

# Static targets are the Compose shape. In a cluster they produce series with no
# pod identity, which is exactly what makes prometheus-adapter serve nothing.
Assert-ValidatorRejects `
    -Mutation { param($values) $values.scrapeConfigs.'ingestion-service'.PSObject.Properties.Remove('kubernetes_sd_configs') } `
    -ExpectedMessage "no kubernetes_sd_configs entry with role 'pod'" `
    -Description "a service job with no pod discovery was rejected"

# Losing the namespace/pod relabel rules is the failure this module exists to
# catch: scraping keeps working, queries keep working, and only the custom
# metrics path breaks - later, and somewhere else.
foreach ($labelCase in @(
    @{ Target = "namespace"; Description = "a service job that does not set the 'namespace' label was rejected" },
    @{ Target = "pod"; Description = "a service job that does not set the 'pod' label was rejected" }
)) {
    Assert-ValidatorRejects `
        -Mutation {
            param($values)
            $job = $values.scrapeConfigs.'ingestion-service'
            $job.relabel_configs = @($job.relabel_configs | Where-Object { $_.target_label -ne $labelCase.Target })
        } `
        -ExpectedMessage "copying __meta_kubernetes_\w+ to '$($labelCase.Target)'" `
        -Description $labelCase.Description
}

# Pod discovery returns every visible pod. Without the keep rules a job scrapes
# unrelated workloads, and their series arrive under this job's name.
Assert-ValidatorRejects `
    -Mutation {
        param($values)
        $job = $values.scrapeConfigs.'ingestion-service'
        $job.relabel_configs = @($job.relabel_configs | Where-Object { $_.action -ne "keep" })
    } `
    -ExpectedMessage "no keep rule on __meta_kubernetes_pod_label_app_kubernetes_io_name" `
    -Description "a service job that keeps every discovered pod was rejected"

Write-Host "[ok] Prometheus scrape configuration checks behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
