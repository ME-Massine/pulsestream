# Exercises Confirm-PodsMetricCoverage (scripts/lib/PulseStreamAutoscaling.psm1)
# against synthetic pod lists. No cluster, no kubectl, no network.
#
# The function is what closes the gap validate-custom-metrics-autoscaling.ps1
# used to have: comparing the metric's non-empty pod list against the
# Deployment's actual Ready pods, instead of accepting any response with at
# least one item. That gap can only be arranged offline - a real cluster with
# a partially-scraped Deployment is not something a validation run can produce
# on demand.
#
#   powershell -File scripts\tests\test-custom-metrics-pod-coverage.ps1
#   pwsh -File scripts/tests/test-custom-metrics-pod-coverage.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamAutoscaling.psm1") -Force

Confirm-PodsMetricCoverage `
    -ReadyPodNames @("ingestion-service-a", "ingestion-service-b") `
    -MetricPodNames @("ingestion-service-a", "ingestion-service-b") `
    -MetricName "http_requests_per_second"
Write-Host "[ok] full coverage across every Ready pod passes"

$rejectedMissingPod = $false
try {
    Confirm-PodsMetricCoverage `
        -ReadyPodNames @("ingestion-service-a", "ingestion-service-b") `
        -MetricPodNames @("ingestion-service-a") `
        -MetricName "http_requests_per_second"
} catch {
    if ($_.Exception.Message -match "missing for 1 of 2 Ready pod\(s\): ingestion-service-b") {
        $rejectedMissingPod = $true
        Write-Host "[ok] a Ready pod missing from the metric response was rejected"
    } else {
        throw
    }
}
if (-not $rejectedMissingPod) {
    throw "Confirm-PodsMetricCoverage accepted a metric response missing a Ready pod."
}

$rejectedAllMissing = $false
try {
    Confirm-PodsMetricCoverage `
        -ReadyPodNames @("ingestion-service-a") `
        -MetricPodNames @() `
        -MetricName "http_requests_per_second"
} catch {
    if ($_.Exception.Message -match "missing for 1 of 1 Ready pod\(s\): ingestion-service-a") {
        $rejectedAllMissing = $true
        Write-Host "[ok] an empty metric response against a Ready pod was rejected"
    } else {
        throw
    }
}
if (-not $rejectedAllMissing) {
    throw "Confirm-PodsMetricCoverage accepted an empty metric response with a Ready pod outstanding."
}

# One Ready pod carrying two metric entries is still "present" by name, but
# the HPA averages both, so the pod is weighted twice. Presence alone cannot
# see that - only counting the entries per pod can.
$rejectedDuplicate = $false
try {
    Confirm-PodsMetricCoverage `
        -ReadyPodNames @("ingestion-service-a", "ingestion-service-b") `
        -MetricPodNames @("ingestion-service-a", "ingestion-service-a", "ingestion-service-b") `
        -MetricName "http_requests_per_second"
} catch {
    if ($_.Exception.Message -match "more than one entry for 1 of 2 Ready pod\(s\): ingestion-service-a \(2 entries\)") {
        $rejectedDuplicate = $true
        Write-Host "[ok] a Ready pod with two metric entries was rejected"
    } else {
        throw
    }
}
if (-not $rejectedDuplicate) {
    throw "Confirm-PodsMetricCoverage accepted two metric entries for the same Ready pod."
}

# A metric entry for a pod that is no longer Ready (mid-termination, or
# scraped a moment before it failed its probe) is not this check's problem -
# every Ready pod is still covered, so it must not fail.
Confirm-PodsMetricCoverage `
    -ReadyPodNames @("ingestion-service-a") `
    -MetricPodNames @("ingestion-service-a", "ingestion-service-terminating") `
    -MetricName "http_requests_per_second"
Write-Host "[ok] a metric entry for a pod that is not Ready is not rejected"

Write-Host "[ok] custom-metrics pod coverage checks behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
