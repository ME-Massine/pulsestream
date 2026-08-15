# Validates the telemetry-processor HorizontalPodAutoscaler (#151) on a cluster.
#
# The assertions themselves live in scripts/lib/PulseStreamAutoscaling.psm1 so
# that the no-cluster structural test
# (scripts/tests/test-telemetry-processor-hpa-structure.ps1) runs the same
# checks against the committed manifest instead of a second copy of them. This
# script is the part that needs a cluster: it fetches the applied HPA.
#
# The checks are STRUCTURAL and deliberately cluster-load-independent, so they
# mean something without generating real traffic. Proving that the autoscaler
# actually reacts to load needs a running cluster with metrics-server and a load
# generator, and is tracked separately (#153).
[CmdletBinding()]
param(
    [string] $Namespace = "default"
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamKubernetes.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamAutoscaling.psm1") -Force

Write-Host "Validating telemetry-processor HorizontalPodAutoscaler in namespace '$Namespace'..."

$json = Invoke-KubectlChecked `
    -KubectlArgs @("get", "hpa", "telemetry-processor", "--namespace", $Namespace, "-o", "json") `
    -ErrorContext "HorizontalPodAutoscaler 'telemetry-processor' was not found in namespace '$Namespace'. Apply infrastructure/kubernetes/telemetry-processor/"

Confirm-TelemetryProcessorHpa -Hpa ($json | ConvertFrom-Json)

Write-Host "[ok] telemetry-processor HPA structural validation completed in namespace '$Namespace'."
