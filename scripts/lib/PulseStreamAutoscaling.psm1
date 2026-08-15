# Structural assertions for the telemetry-processor HorizontalPodAutoscaler (#151).
#
# Shared by validate-telemetry-processor-hpa.ps1, which reads a live HPA with
# kubectl, and scripts/tests/test-telemetry-processor-hpa-structure.ps1, which
# reads the committed manifest with no cluster at all. Both have to assert
# exactly the same thing; the test used to get there by replacing kubectl with a
# stub function in the global scope, which leaked into every other script that
# shared the session.
#
# The checks are cluster-load-independent on purpose: they mean something
# without generating traffic. Proving the autoscaler reacts to real load needs a
# cluster with metrics-server and a load generator, tracked separately (#153).

Import-Module (Join-Path $PSScriptRoot "PulseStreamValidation.psm1") -Force

# Walks a property path without assuming any level exists.
#
# A missing field is the interesting failure here rather than an impossible one:
# an HPA with no .spec.behavior is accepted by the API server and silently falls
# back to the default 300s scale-up stabilization window, and a manifest that
# drops .spec.metrics still applies. Reading those through `$hpa.spec.behavior.
# scaleUp.stabilizationWindowSeconds` turns the interesting case into a
# PowerShell error about a property on a null object - or, under Set-StrictMode,
# into a script that aborts before it can report anything useful.
function Get-ManifestValue {
    param(
        [Parameter(Position = 0)] $InputObject,
        [Parameter(Mandatory, Position = 1)] [string[]] $Path
    )

    $current = $InputObject
    foreach ($segment in $Path) {
        if ($null -eq $current) {
            return $null
        }

        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            return $null
        }

        $current = $property.Value
    }

    return $current
}

# Keeps failure messages readable when the field is absent: "is missing" rather
# than "is , not 300".
function Format-ManifestValue {
    param($Value)

    if ($null -eq $Value) {
        return "missing"
    }

    return "$Value"
}

function Get-CpuUtilizationMetric {
    param($Hpa)

    $metrics = @(Get-ManifestValue $Hpa @('spec', 'metrics'))

    return @($metrics | Where-Object {
        $null -ne $_ -and
        (Get-ManifestValue $_ @('type')) -eq 'Resource' -and
        (Get-ManifestValue $_ @('resource', 'name')) -eq 'cpu' -and
        (Get-ManifestValue $_ @('resource', 'target', 'type')) -eq 'Utilization'
    }) | Select-Object -First 1
}

function Confirm-TelemetryProcessorHpa {
    param([Parameter(Mandatory)] $Hpa)

    $targetKind = Get-ManifestValue $Hpa @('spec', 'scaleTargetRef', 'kind')
    $targetName = Get-ManifestValue $Hpa @('spec', 'scaleTargetRef', 'name')
    Confirm-Condition `
        -Condition ($targetKind -eq 'Deployment' -and $targetName -eq 'telemetry-processor') `
        -SuccessMessage "HPA targets Deployment/telemetry-processor" `
        -FailureMessage "HPA scaleTargetRef is $(Format-ManifestValue $targetKind)/$(Format-ManifestValue $targetName), not Deployment/telemetry-processor. It would scale the wrong workload, or nothing"

    $minReplicas = Get-ManifestValue $Hpa @('spec', 'minReplicas')
    Confirm-Condition `
        -Condition ($minReplicas -eq 2) `
        -SuccessMessage "minReplicas is 2 (the availability floor also set in deployment.yaml)" `
        -FailureMessage "minReplicas is $(Format-ManifestValue $minReplicas), not 2. A lower floor would undo the rolling-update/node-drain safety margin; a higher one contradicts the deployment's own replica count"

    # The important one: 3 is the partition count of telemetry.events.raw, not a
    # capacity guess, so a raised ceiling is a silent regression rather than a
    # tuning change.
    $maxReplicas = Get-ManifestValue $Hpa @('spec', 'maxReplicas')
    Confirm-Condition `
        -Condition ($maxReplicas -eq 3) `
        -SuccessMessage "maxReplicas is 3 (the partition count of telemetry.events.raw)" `
        -FailureMessage "maxReplicas is $(Format-ManifestValue $maxReplicas), not 3. Replicas beyond the partition count join the consumer group, are assigned no partition, and do no work; the ceiling only moves after the topic is repartitioned"

    $cpuMetric = Get-CpuUtilizationMetric -Hpa $Hpa
    Confirm-Condition `
        -Condition ($null -ne $cpuMetric) `
        -SuccessMessage "HPA scales on Resource/cpu Utilization" `
        -FailureMessage "HPA has no Resource/cpu Utilization metric. Consumer lag is the preferred signal but needs a metrics adapter (#152) and exported lag metrics (#272); CPU-against-request is the only supported one today"

    $cpuTarget = Get-ManifestValue $cpuMetric @('resource', 'target', 'averageUtilization')
    Confirm-Condition `
        -Condition ($cpuTarget -eq 70) `
        -SuccessMessage "CPU target is 70% of the pod's CPU request" `
        -FailureMessage "CPU averageUtilization is $(Format-ManifestValue $cpuTarget), not 70%. The target is defined relative to the 250m request in deployment.yaml; changing one without the other silently moves the real trigger point"

    $scaleUpWindow = Get-ManifestValue $Hpa @('spec', 'behavior', 'scaleUp', 'stabilizationWindowSeconds')
    Confirm-Condition `
        -Condition ($scaleUpWindow -eq 0) `
        -SuccessMessage "scale-up has no stabilization window (reacts on a sustained rise rather than waiting through it)" `
        -FailureMessage "scale-up stabilizationWindowSeconds is $(Format-ManifestValue $scaleUpWindow), not 0. Without the field the API server applies its own default, and a delayed scale-up leaves the backlog growing while a new pod still needs ~15-30s to become ready and be assigned a partition"

    $scaleDownWindow = Get-ManifestValue $Hpa @('spec', 'behavior', 'scaleDown', 'stabilizationWindowSeconds')
    Confirm-Condition `
        -Condition ($scaleDownWindow -eq 300) `
        -SuccessMessage "scale-down has a 300s stabilization window (JVM CPU is spiky, and every scale-in rebalances the consumer group)" `
        -FailureMessage "scale-down stabilizationWindowSeconds is $(Format-ManifestValue $scaleDownWindow), not 300. A shorter window turns a GC or JIT burst into a rebalance that pauses processing across the whole group"
}

Export-ModuleMember -Function Confirm-TelemetryProcessorHpa, Get-ManifestValue
