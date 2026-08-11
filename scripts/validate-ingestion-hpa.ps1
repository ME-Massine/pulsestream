# Validates the ingestion-service HorizontalPodAutoscaler (#150).
#
# These checks are STRUCTURAL: they assert that the applied HPA targets the
# right Deployment, scales on CPU utilization at the documented 70% target,
# stays within the documented 2-6 replica range, and reacts fast on scale-up
# while damping scale-down. They are deliberately cluster-load-independent, so
# they mean something without generating real traffic. Proving that the
# autoscaler actually reacts to load needs a running cluster with
# metrics-server and is tracked separately (#153).
[CmdletBinding()]
param(
    [string] $Namespace = "default"
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamKubernetes.psm1") -Force

function Get-HorizontalPodAutoscaler {
    param([string] $Name)
    $json = Invoke-KubectlChecked `
        -KubectlArgs @("get", "hpa", $Name, "--namespace", $Namespace, "-o", "json") `
        -ErrorContext "HorizontalPodAutoscaler '$Name' was not found in namespace '$Namespace'. Apply infrastructure/kubernetes/ingestion-service/"
    return $json | ConvertFrom-Json
}

function Get-CpuUtilizationMetric {
    param($Hpa)
    return @($Hpa.spec.metrics | Where-Object {
        $_.type -eq 'Resource' -and $_.resource.name -eq 'cpu' -and $_.resource.target.type -eq 'Utilization'
    })[0]
}

Write-Host "Validating ingestion-service HorizontalPodAutoscaler in namespace '$Namespace'..."

$hpa = Get-HorizontalPodAutoscaler -Name "ingestion-service"

Confirm-Condition `
    -Condition ($hpa.spec.scaleTargetRef.kind -eq 'Deployment' -and $hpa.spec.scaleTargetRef.name -eq 'ingestion-service') `
    -SuccessMessage "HPA targets Deployment/ingestion-service" `
    -FailureMessage "HPA scaleTargetRef is $($hpa.spec.scaleTargetRef.kind)/$($hpa.spec.scaleTargetRef.name), not Deployment/ingestion-service. It would scale the wrong workload, or nothing"

Confirm-Condition `
    -Condition ($hpa.spec.minReplicas -eq 2) `
    -SuccessMessage "minReplicas is 2 (the availability floor also set in deployment.yaml)" `
    -FailureMessage "minReplicas is $($hpa.spec.minReplicas), not 2. A lower floor would undo the rolling-update/node-drain safety margin; a higher one contradicts the deployment's own replica count"

Confirm-Condition `
    -Condition ($hpa.spec.maxReplicas -eq 6) `
    -SuccessMessage "maxReplicas is 6 (docs/architecture/autoscaling-strategy.md ceiling)" `
    -FailureMessage "maxReplicas is $($hpa.spec.maxReplicas), not 6. That ceiling exists so ingestion cannot out-produce the 3-partition topic; raising it silently invalidates that reasoning"

$cpuMetric = Get-CpuUtilizationMetric -Hpa $hpa
Confirm-Condition `
    -Condition ($null -ne $cpuMetric) `
    -SuccessMessage "HPA scales on Resource/cpu Utilization" `
    -FailureMessage "HPA has no Resource/cpu Utilization metric. Memory and request-rate are explicitly rejected signals (see autoscaling-strategy.md); CPU-against-request is the only one wired up today"

if ($null -ne $cpuMetric) {
    Confirm-Condition `
        -Condition ($cpuMetric.resource.target.averageUtilization -eq 70) `
        -SuccessMessage "CPU target is 70% of the pod's CPU request" `
        -FailureMessage "CPU averageUtilization is $($cpuMetric.resource.target.averageUtilization)%, not 70%. The target is defined relative to the 250m request in deployment.yaml; changing one without the other silently moves the real trigger point"
}

Confirm-Condition `
    -Condition ($hpa.spec.behavior.scaleUp.stabilizationWindowSeconds -eq 0) `
    -SuccessMessage "scale-up has no stabilization window (reacts on a sustained rise rather than waiting through it)" `
    -FailureMessage "scale-up stabilizationWindowSeconds is $($hpa.spec.behavior.scaleUp.stabilizationWindowSeconds), not 0. A delayed scale-up leaves the gateway saturated while a new pod still needs ~15-30s to become ready"

Confirm-Condition `
    -Condition ($hpa.spec.behavior.scaleDown.stabilizationWindowSeconds -eq 300) `
    -SuccessMessage "scale-down has a 300s stabilization window (JVM CPU is spiky: GC and JIT produce short bursts a shorter window would misread as load)" `
    -FailureMessage "scale-down stabilizationWindowSeconds is $($hpa.spec.behavior.scaleDown.stabilizationWindowSeconds), not 300"

Write-Host "[ok] ingestion-service HPA structural validation completed in namespace '$Namespace'."
