# Validates the custom-metrics autoscaling path on a cluster (#152).
#
# The chain has four links and a break in any one of them shows up the same way
# on the HPA - `<unknown>` for the metric - so each is checked separately:
#
#   1. custom.metrics.k8s.io is registered and Available (prometheus-adapter)
#   2. http_requests_per_second actually resolves for the service's pods
#   3. exactly one HPA targets the Deployment (two of them fight)
#   4. the applied HPA has the shape documented in
#      docs/architecture/custom-metrics-autoscaling.md
#   5. the HPA is reading the metric rather than reporting it as unknown
#
# The assertions for step 4 are shared with the no-cluster structural test
# (scripts/tests/test-custom-metrics-hpa-structure.ps1), which runs the same
# checks against the committed manifest.
#
# These checks are load-independent: they prove the metric is wired up, not that
# scaling reacts to real traffic. That is #153.
[CmdletBinding()]
param(
    [string] $Namespace = "default"
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamKubernetes.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamAutoscaling.psm1") -Force

Write-Host "Validating custom-metrics autoscaling for ingestion-service in namespace '$Namespace'..."

# 1. The metrics API itself.
#
# Registration and availability are separate failures: the APIService exists as
# soon as the chart is installed, but it is only Available once the adapter's
# pods pass their health checks and the aggregation layer can reach them.
$apiServiceResult = Invoke-Kubectl -KubectlArgs @("get", "apiservices", "v1beta1.custom.metrics.k8s.io", "-o", "json")
Confirm-Condition `
    -Condition ($apiServiceResult.ExitCode -eq 0) `
    -SuccessMessage "custom.metrics.k8s.io/v1beta1 is registered" `
    -FailureMessage "No APIService serves custom.metrics.k8s.io/v1beta1. prometheus-adapter is not installed; see infrastructure/kubernetes/autoscaling/README.md. $($apiServiceResult.Output)"

$apiService = $apiServiceResult.Output | ConvertFrom-Json
$available = @($apiService.status.conditions | Where-Object { $_.type -eq 'Available' }) | Select-Object -First 1
Confirm-Condition `
    -Condition ($null -ne $available -and $available.status -eq 'True') `
    -SuccessMessage "the custom metrics APIService is Available (backed by $(Get-ManifestValue $apiService @('spec','service','namespace'))/$(Get-ManifestValue $apiService @('spec','service','name')))" `
    -FailureMessage "The custom metrics APIService is registered but not Available: $(if ($null -eq $available) { 'no Available condition' } else { "$($available.reason) - $($available.message)" }). The HPA will report <unknown> for every custom metric until the aggregation layer can reach the adapter"

# 2. The metric resolves.
#
# An adapter rule that matches no series is not an error on either side: the API
# answers with an empty list and the HPA reports <unknown>. The usual causes are
# Prometheus not scraping the pods, series without `namespace`/`pod` labels, or
# a Micrometer upgrade that renamed the counter.
$metricPath = "/apis/custom.metrics.k8s.io/v1beta1/namespaces/$Namespace/pods/*/http_requests_per_second"
$metricResult = Invoke-Kubectl -KubectlArgs @("get", "--raw", $metricPath)
Confirm-Condition `
    -Condition ($metricResult.ExitCode -eq 0) `
    -SuccessMessage "the custom metrics API answers for http_requests_per_second" `
    -FailureMessage "GET $metricPath failed. The adapter is serving the API but has no rule producing http_requests_per_second, or Prometheus is unreachable from it. $($metricResult.Output)"

$metricItems = @(($metricResult.Output | ConvertFrom-Json).items)
Confirm-Condition `
    -Condition ($metricItems.Count -gt 0) `
    -SuccessMessage "http_requests_per_second resolves for $($metricItems.Count) pod(s) in '$Namespace'" `
    -FailureMessage "http_requests_per_second resolved to an empty list in '$Namespace'. The rule matched no series: check that Prometheus scrapes /actuator/prometheus on the ingestion-service pods and that the series carry namespace and pod labels"

foreach ($item in $metricItems) {
    Write-Host "       $($item.describedObject.name) = $($item.value)"
}

# 3. Exactly one HPA targets the Deployment.
#
# Two HPAs on one target are not additive: each computes its own desired
# replica count and writes it, so they undo each other and the deployment
# oscillates. ingestion-service/hpa.yaml and autoscaling/ingestion-service-hpa-custom-metrics.yaml are alternatives, and this is
# the check that catches an apply of the directory on top of the switched-over
# HPA.
$hpaListJson = Invoke-KubectlChecked `
    -KubectlArgs @("get", "hpa", "--namespace", $Namespace, "-o", "json") `
    -ErrorContext "Could not list HorizontalPodAutoscalers in namespace '$Namespace'"

$targeting = @(($hpaListJson | ConvertFrom-Json).items | Where-Object {
    (Get-ManifestValue $_ @('spec', 'scaleTargetRef', 'kind')) -eq 'Deployment' -and
    (Get-ManifestValue $_ @('spec', 'scaleTargetRef', 'name')) -eq 'ingestion-service'
})

Confirm-Condition `
    -Condition ($targeting.Count -eq 1) `
    -SuccessMessage "exactly one HPA targets Deployment/ingestion-service" `
    -FailureMessage "$($targeting.Count) HPAs target Deployment/ingestion-service ($(@($targeting | ForEach-Object { $_.metadata.name }) -join ', ')). Two autoscalers on one Deployment overwrite each other's decisions; ingestion-service/hpa.yaml and autoscaling/ingestion-service-hpa-custom-metrics.yaml are alternatives, not additions"

# 4. The applied HPA has the documented shape.
$hpa = $targeting[0]
Confirm-IngestionServiceCustomMetricsHpa -Hpa $hpa

# 5. The HPA is reading the metric.
#
# Everything above can pass while the HPA itself still reports <unknown>: it
# caches its own metric reads and reports the outcome in ScalingActive. A False
# condition here means the HPA is refusing to scale down, which is the failure
# mode that hides behind a healthy-looking adapter.
$scalingActive = @($hpa.status.conditions | Where-Object { $_.type -eq 'ScalingActive' }) | Select-Object -First 1
Confirm-Condition `
    -Condition ($null -ne $scalingActive -and $scalingActive.status -eq 'True') `
    -SuccessMessage "the HPA reports ScalingActive=True (it can compute a replica count from every metric)" `
    -FailureMessage "The HPA's ScalingActive condition is $(if ($null -eq $scalingActive) { 'absent - the HPA has not completed a sync yet' } else { "$($scalingActive.status): $($scalingActive.reason) - $($scalingActive.message)" }). While this is False the HPA will not scale down, though it can still scale up on the metrics it did read"

$currentPodsMetric = @($hpa.status.currentMetrics | Where-Object {
    (Get-ManifestValue $_ @('type')) -eq 'Pods' -and
    (Get-ManifestValue $_ @('pods', 'metric', 'name')) -eq 'http_requests_per_second'
}) | Select-Object -First 1

$currentValue = Get-ManifestValue $currentPodsMetric @('pods', 'current', 'averageValue')
Confirm-Condition `
    -Condition ($null -ne $currentValue) `
    -SuccessMessage "the HPA has a current value for http_requests_per_second ($currentValue against the 50/replica target)" `
    -FailureMessage "The HPA reports no current value for http_requests_per_second. The metric exists in the API but this HPA has not read it: check that the metric name in the manifest matches the adapter rule exactly"

Write-Host "[ok] custom-metrics autoscaling validation completed in namespace '$Namespace'."
Write-Host "     Consumer lag (kafka_consumergroup_lag) is not expected to resolve yet: nothing exports it until #272, and no HPA consumes it until #269."
