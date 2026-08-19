# Validates the in-cluster Prometheus deployment (#154).
#
# Four things have to hold before anything downstream (dashboards, the
# prometheus-adapter custom metrics path) can work, and each fails differently:
#
#   1. the server is running and its Service exists in the monitoring namespace
#   2. the APPLIED scrape configuration has the documented shape - the same
#      assertions the no-cluster test runs against the committed Helm values
#      (scripts/tests/test-prometheus-scrape-config.ps1)
#   3. Prometheus is reachable and answering queries
#   4. every configured job has healthy targets and real samples
#
# Reachability goes through the API server's Service proxy rather than
# `kubectl port-forward`: the proxy is a synchronous request, while a
# port-forward is a background process that has to be started, waited on and
# torn down, and leaks if the script fails in between. Nothing is exposed
# outside the cluster for this check.
[CmdletBinding()]
param(
    [string] $Namespace = "monitoring",
    [string] $ReleaseName = "prometheus",
    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamKubernetes.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamYaml.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamPrometheus.psm1") -Force

# The chart names the server workload, ConfigMap and Service <release>-server.
$serverName = "$ReleaseName-server"
$proxyBase = "/api/v1/namespaces/$Namespace/services/$($serverName):80/proxy"

function Invoke-PrometheusApi {
    param([Parameter(Mandatory)] [string] $Path)

    $raw = Invoke-KubectlChecked `
        -KubectlArgs @("get", "--raw", "$proxyBase$Path") `
        -ErrorContext "Could not reach Prometheus through the API server proxy at $proxyBase$Path. The Service '$serverName' must exist in namespace '$Namespace' (see infrastructure/kubernetes/monitoring/README.md)"

    return $raw | ConvertFrom-Json
}

function Invoke-PrometheusQuery {
    param([Parameter(Mandatory)] [string] $Query)

    $encodedQuery = [System.Uri]::EscapeDataString($Query)
    $result = Invoke-PrometheusApi -Path "/api/v1/query?query=$encodedQuery"

    Confirm-Condition `
        -Condition ($result.status -eq "success") `
        -SuccessMessage "Prometheus query succeeded: $Query" `
        -FailureMessage "Prometheus query failed: $Query"

    return @($result.data.result)
}

Write-Host "Validating the in-cluster Prometheus (release '$ReleaseName') in namespace '$Namespace'..."

# --- 1. The server is running ------------------------------------------------
$deploymentResult = Invoke-Kubectl -KubectlArgs @("get", "deployment", $serverName, "--namespace", $Namespace, "-o", "json")
Confirm-Condition `
    -Condition ($deploymentResult.ExitCode -eq 0) `
    -SuccessMessage "Deployment '$serverName' exists in namespace '$Namespace'" `
    -FailureMessage "Deployment '$serverName' was not found in namespace '$Namespace'. Install it with the Helm command in infrastructure/kubernetes/monitoring/README.md. $($deploymentResult.Output)"

# Readiness is polled: a fresh install answers `kubectl get` immediately but
# needs a moment before its pod passes the readiness probe, and every check
# below would fail during that window for a deployment that is merely young.
Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Deployment '$serverName' had no ready replica within $TimeoutSeconds seconds." `
    -Operation {
        $current = (Invoke-KubectlChecked `
            -KubectlArgs @("get", "deployment", $serverName, "--namespace", $Namespace, "-o", "json") `
            -ErrorContext "Could not read Deployment '$serverName'") | ConvertFrom-Json

        $readyReplicas = [int] $current.status.readyReplicas
        Confirm-Condition `
            -Condition ($readyReplicas -ge 1) `
            -SuccessMessage "Deployment '$serverName' has $readyReplicas ready replica(s)" `
            -FailureMessage "Deployment '$serverName' has no ready replica yet (desired $($current.status.replicas))"
    } | Out-Null

$serviceResult = Invoke-Kubectl -KubectlArgs @("get", "service", $serverName, "--namespace", $Namespace, "-o", "json")
Confirm-Condition `
    -Condition ($serviceResult.ExitCode -eq 0) `
    -SuccessMessage "Service '$serverName' exists (in-cluster endpoint $serverName.$Namespace.svc)" `
    -FailureMessage "Service '$serverName' was not found in namespace '$Namespace'. prometheus-adapter points at http://prometheus-server.monitoring.svc and would report every custom metric as <unknown>. $($serviceResult.Output)"

# --- 2. The applied scrape configuration has the documented shape ------------
# Read from the ConfigMap rather than from Prometheus' /api/v1/status/config,
# so a configuration that was edited in the cluster but never committed - or
# committed and never applied - is caught here rather than surfacing later as a
# missing target.
$configMapJson = Invoke-KubectlChecked `
    -KubectlArgs @("get", "configmap", $serverName, "--namespace", $Namespace, "-o", "json") `
    -ErrorContext "ConfigMap '$serverName' was not found in namespace '$Namespace'"

$promConfigText = ($configMapJson | ConvertFrom-Json).data.'prometheus.yml'
Confirm-Condition `
    -Condition (-not [string]::IsNullOrWhiteSpace($promConfigText)) `
    -SuccessMessage "ConfigMap '$serverName' carries a prometheus.yml key" `
    -FailureMessage "ConfigMap '$serverName' has no 'prometheus.yml' key; the applied scrape configuration cannot be checked"

Confirm-PrometheusScrapeConfig `
    -Config (ConvertFrom-KubernetesYaml -Text $promConfigText) `
    -Description "the applied scrape configuration"

# --- 3. Prometheus is reachable ----------------------------------------------
Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Prometheus did not answer a query through the API server proxy within $TimeoutSeconds seconds." `
    -Operation {
        $result = Invoke-PrometheusApi -Path "/api/v1/query?query=up"
        Confirm-Condition `
            -Condition ($result.status -eq "success") `
            -SuccessMessage "Prometheus is reachable at $serverName.$Namespace.svc and answering queries" `
            -FailureMessage "Prometheus answered the proxy but reported status '$($result.status)'"
    } | Out-Null

# --- 4. Targets are healthy and produce samples ------------------------------
$expectedJobs = @(Get-PrometheusSelfJobName) + @(Get-PrometheusServiceJobNames)

Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Prometheus targets were not all healthy within $TimeoutSeconds seconds." `
    -Operation {
        $targets = Invoke-PrometheusApi -Path "/api/v1/targets?state=active"

        foreach ($jobName in $expectedJobs) {
            $jobTargets = @($targets.data.activeTargets | Where-Object { $_.labels.job -eq $jobName })

            Confirm-Condition `
                -Condition ($jobTargets.Count -gt 0) `
                -SuccessMessage "job '$jobName' has $($jobTargets.Count) active target(s)" `
                -FailureMessage "job '$jobName' has no active target. For a service job this means no pod carries app.kubernetes.io/name=$jobName - deploy infrastructure/kubernetes/$jobName/ first"

            foreach ($target in $jobTargets) {
                Confirm-Condition `
                    -Condition ($target.health -eq "up") `
                    -SuccessMessage "target $($target.scrapeUrl) is up" `
                    -FailureMessage "target $($target.scrapeUrl) is '$($target.health)': $($target.lastError)"
            }
        }
    } | Out-Null

# up == 1 per job proves collection, not just target registration: a target is
# reported healthy from its first successful scrape, and this is the query a
# reader would run to confirm the same thing by hand.
foreach ($jobName in $expectedJobs) {
    Invoke-WithRetry `
        -TimeoutSeconds $TimeoutSeconds `
        -FailureMessage "Prometheus did not report up{job=""$jobName""} = 1 within $TimeoutSeconds seconds." `
        -Operation {
            $upValues = @(Invoke-PrometheusQuery "up{job=""$jobName""}" | ForEach-Object { $_.value[1] })
            Confirm-Condition `
                -Condition ($upValues -contains "1") `
                -SuccessMessage "up{job=""$jobName""} = 1" `
                -FailureMessage "Prometheus has no up{job=""$jobName""} = 1 sample"
        } | Out-Null
}

# Application-level series, not just the scrape's own `up`: this is what proves
# the Actuator exposition is being parsed and stored. jvm_info is exported by
# every Spring Boot service and is the same metric the Compose validator
# (validate-prometheus-metrics.ps1) checks.
foreach ($jobName in Get-PrometheusServiceJobNames) {
    Invoke-WithRetry `
        -TimeoutSeconds $TimeoutSeconds `
        -FailureMessage "Prometheus returned no jvm_info series for job '$jobName' within $TimeoutSeconds seconds." `
        -Operation {
            $series = Invoke-PrometheusQuery "jvm_info{job=""$jobName""}"
            Confirm-Condition `
                -Condition ($series.Count -gt 0) `
                -SuccessMessage "job '$jobName' produces application metrics (jvm_info)" `
                -FailureMessage "job '$jobName' has healthy targets but no jvm_info series; the scrape is reaching something other than /actuator/prometheus"

            # The labels prometheus-adapter maps a metric onto a pod with. A
            # series without them is collected but invisible to the custom
            # metrics API, which surfaces much later as an HPA reporting
            # <unknown> (infrastructure/kubernetes/autoscaling/README.md).
            foreach ($sample in $series) {
                Confirm-Condition `
                    -Condition ((-not [string]::IsNullOrWhiteSpace($sample.metric.namespace)) -and (-not [string]::IsNullOrWhiteSpace($sample.metric.pod))) `
                    -SuccessMessage "job '$jobName' series carry namespace='$($sample.metric.namespace)' and pod='$($sample.metric.pod)'" `
                    -FailureMessage "a job '$jobName' series is missing the 'namespace' or 'pod' label; prometheus-adapter cannot attach such a metric to a pod"
            }
        } | Out-Null
}

Write-Host "[ok] In-cluster Prometheus validation completed in namespace '$Namespace'."
