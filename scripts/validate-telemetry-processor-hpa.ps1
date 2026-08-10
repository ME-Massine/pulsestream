# Validates the telemetry-processor HorizontalPodAutoscaler (#151).
#
# These checks are STRUCTURAL: they assert that the applied HPA targets the
# right Deployment, scales on CPU utilization at the documented 70% target,
# stays within the documented 2-3 replica range, and reacts fast on scale-up
# while damping scale-down. They are deliberately cluster-load-independent, so
# they mean something without generating real traffic. Proving that the
# autoscaler actually reacts to load needs a running cluster with
# metrics-server and a load generator, and is tracked separately (#153).
#
# The maxReplicas check is the important one here: 3 is the partition count of
# telemetry.events.raw, not a capacity guess, so a raised ceiling is a silent
# regression rather than a tuning change.
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
        -ErrorContext "HorizontalPodAutoscaler '$Name' was not found in namespace '$Namespace'. Apply infrastructure/kubernetes/telemetry-processor/"
    return $json | ConvertFrom-Json
}

function Get-CpuUtilizationMetric {
    param($Hpa)
    return @($Hpa.spec.metrics | Where-Object {
        $_.type -eq 'Resource' -and $_.resource.name -eq 'cpu' -and $_.resource.target.type -eq 'Utilization'
    })[0]
}

Write-Host "Validating telemetry-processor HorizontalPodAutoscaler in namespace '$Namespace'..."

$hpa = Get-HorizontalPodAutoscaler -Name "telemetry-processor"

Confirm-Condition `
    -Condition ($hpa.spec.scaleTargetRef.kind -eq 'Deployment' -and $hpa.spec.scaleTargetRef.name -eq 'telemetry-processor') `
    -SuccessMessage "HPA targets Deployment/telemetry-processor" `
    -FailureMessage "HPA scaleTargetRef is $($hpa.spec.scaleTargetRef.kind)/$($hpa.spec.scaleTargetRef.name), not Deployment/telemetry-processor. It would scale the wrong workload, or nothing"

Confirm-Condition `
    -Condition ($hpa.spec.minReplicas -eq 2) `
    -SuccessMessage "minReplicas is 2 (the availability floor also set in deployment.yaml)" `
    -FailureMessage "minReplicas is $($hpa.spec.minReplicas), not 2. A lower floor would undo the rolling-update/node-drain safety margin; a higher one contradicts the deployment's own replica count"

Confirm-Condition `
    -Condition ($hpa.spec.maxReplicas -eq 3) `
    -SuccessMessage "maxReplicas is 3 (the partition count of telemetry.events.raw)" `
    -FailureMessage "maxReplicas is $($hpa.spec.maxReplicas), not 3. Replicas beyond the partition count join the consumer group, are assigned no partition, and do no work; the ceiling only moves after the topic is repartitioned"

$cpuMetric = Get-CpuUtilizationMetric -Hpa $hpa
Confirm-Condition `
    -Condition ($null -ne $cpuMetric) `
    -SuccessMessage "HPA scales on Resource/cpu Utilization" `
    -FailureMessage "HPA has no Resource/cpu Utilization metric. Consumer lag is the preferred signal but needs a metrics adapter (#152) and exported lag metrics (#272); CPU-against-request is the only supported one today"

if ($null -ne $cpuMetric) {
    Confirm-Condition `
        -Condition ($cpuMetric.resource.target.averageUtilization -eq 70) `
        -SuccessMessage "CPU target is 70% of the pod's CPU request" `
        -FailureMessage "CPU averageUtilization is $($cpuMetric.resource.target.averageUtilization)%, not 70%. The target is defined relative to the 250m request in deployment.yaml; changing one without the other silently moves the real trigger point"
}

Confirm-Condition `
    -Condition ($hpa.spec.behavior.scaleUp.stabilizationWindowSeconds -eq 0) `
    -SuccessMessage "scale-up has no stabilization window (reacts on a sustained rise rather than waiting through it)" `
    -FailureMessage "scale-up stabilizationWindowSeconds is $($hpa.spec.behavior.scaleUp.stabilizationWindowSeconds), not 0. A delayed scale-up leaves the backlog growing while a new pod still needs ~15-30s to become ready and be assigned a partition"

Confirm-Condition `
    -Condition ($hpa.spec.behavior.scaleDown.stabilizationWindowSeconds -eq 300) `
    -SuccessMessage "scale-down has a 300s stabilization window (JVM CPU is spiky, and every scale-in rebalances the consumer group)" `
    -FailureMessage "scale-down stabilizationWindowSeconds is $($hpa.spec.behavior.scaleDown.stabilizationWindowSeconds), not 300. A shorter window turns a GC or JIT burst into a rebalance that pauses processing across the whole group"

Write-Host "[ok] telemetry-processor HPA structural validation completed in namespace '$Namespace'."
