# Runs the custom-metrics HPA structural checks against the committed manifest
# (#152). No cluster, no kubectl, no network.
#
# infrastructure/kubernetes/autoscaling/ingestion-service-hpa-custom-metrics.yaml
# is read
# with scripts/lib/PulseStreamYaml.psm1 and handed to the same
# Confirm-IngestionServiceCustomMetricsHpa that
# validate-custom-metrics-autoscaling.ps1 calls on the applied object, so the
# manifest and the cluster check cannot drift.
#
#   powershell -File scripts\tests\test-custom-metrics-hpa-structure.ps1
#   pwsh -File scripts/tests/test-custom-metrics-hpa-structure.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamYaml.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamAutoscaling.psm1") -Force

$script:Manifest = Join-Path $PSScriptRoot "..\..\infrastructure\kubernetes\autoscaling\ingestion-service-hpa-custom-metrics.yaml"
$script:CpuOnlyManifest = Join-Path $PSScriptRoot "..\..\infrastructure\kubernetes\ingestion-service\hpa.yaml"

# Every case starts from a fresh parse, so a mutation cannot leak into the next
# one and no state has to be restored afterwards.
function Assert-ValidatorRejects {
    param(
        [scriptblock] $Mutation,
        [string] $ExpectedMessage,
        [string] $Description
    )

    $hpa = ConvertFrom-KubernetesYaml -Path $script:Manifest
    & $Mutation $hpa

    try {
        Confirm-IngestionServiceCustomMetricsHpa -Hpa $hpa
    } catch {
        if ($_.Exception.Message -match $ExpectedMessage) {
            Write-Host "[ok] $Description"
            return
        }

        throw "Expected a rejection matching '$ExpectedMessage' for $Description, got: $($_.Exception.Message)"
    }

    throw "The structural validator accepted $Description."
}

Confirm-IngestionServiceCustomMetricsHpa -Hpa (ConvertFrom-KubernetesYaml -Path $script:Manifest)

# The two manifests are alternatives for the same Deployment, so they must agree
# on everything that is not the metric. A custom-metrics rollout that also moved
# the replica bounds would make a capacity change look like a metrics change,
# and rolling back to hpa.yaml would silently move them again.
$customMetricsHpa = ConvertFrom-KubernetesYaml -Path $script:Manifest
$cpuOnlyHpa = ConvertFrom-KubernetesYaml -Path $script:CpuOnlyManifest

foreach ($field in @('minReplicas', 'maxReplicas')) {
    $custom = Get-ManifestValue $customMetricsHpa @('spec', $field)
    $cpuOnly = Get-ManifestValue $cpuOnlyHpa @('spec', $field)
    if ($custom -ne $cpuOnly) {
        throw "ingestion-service-hpa-custom-metrics.yaml sets $field to $custom but hpa.yaml sets it to $cpuOnly. The two manifests target the same Deployment and switching between them must not change the replica bounds."
    }

    Write-Host "[ok] $field matches the CPU-only hpa.yaml ($custom)"
}

$customTargetName = Get-ManifestValue $customMetricsHpa @('spec', 'scaleTargetRef', 'name')
$cpuOnlyTargetName = Get-ManifestValue $cpuOnlyHpa @('spec', 'scaleTargetRef', 'name')
if ($customTargetName -ne $cpuOnlyTargetName) {
    throw "ingestion-service-hpa-custom-metrics.yaml targets '$customTargetName' but hpa.yaml targets '$cpuOnlyTargetName'. They are meant to be alternatives for one Deployment."
}
Write-Host "[ok] both manifests target the same Deployment ($customTargetName)"

# The same object name is what makes switching an apply rather than a
# delete-and-create: the Deployment is never left without an autoscaler, and
# rolling back cannot leave two HPAs behind.
$customObjectName = Get-ManifestValue $customMetricsHpa @('metadata', 'name')
$cpuOnlyObjectName = Get-ManifestValue $cpuOnlyHpa @('metadata', 'name')
if ($customObjectName -ne $cpuOnlyObjectName) {
    throw "ingestion-service-hpa-custom-metrics.yaml is named '$customObjectName' but hpa.yaml is named '$cpuOnlyObjectName'. Different names mean applying one does not replace the other, and both HPAs end up scaling the same Deployment."
}
Write-Host "[ok] both manifests describe the same HPA object ($customObjectName)"

# The metric name is the contract with the prometheus-adapter rules. A rename on
# either side resolves to nothing rather than to an error, so the HPA would
# report <unknown> and quietly stop scaling down.
Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.metrics[1].pods.metric.name = 'http_requests_total' } `
    -ExpectedMessage "no Pods metric named http_requests_per_second" `
    -Description "a renamed custom metric was rejected"

# A Value target compares the whole deployment's rate against a per-replica
# number, so it scales to maxReplicas as soon as traffic arrives.
Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.metrics[1].pods.target.type = 'Value' } `
    -ExpectedMessage "not AverageValue" `
    -Description "a Value target instead of AverageValue was rejected"

Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.metrics[1].pods.target.averageValue = "500" } `
    -ExpectedMessage "averageValue is 500, not 50" `
    -Description "an undocumented request-rate target was rejected"

# Dropping CPU turns prometheus-adapter into a hard dependency of autoscaling.
Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.metrics = @($hpa.spec.metrics[1]) } `
    -ExpectedMessage "no Resource/cpu Utilization metric" `
    -Description "an HPA without the CPU fallback metric was rejected"

# Only the custom metric, missing entirely - the manifest reduced to the CPU-only
# HPA under a name that claims otherwise.
Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.metrics = @($hpa.spec.metrics[0]) } `
    -ExpectedMessage "no Pods metric named http_requests_per_second" `
    -Description "an HPA without the custom metric was rejected"

Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.maxReplicas = 12 } `
    -ExpectedMessage "maxReplicas is 12, not 6" `
    -Description "a raised ceiling was rejected"

# A dropped section is valid to the API server - the defaults just take over -
# so each one has to surface as a validation failure naming the field, not as a
# PowerShell error about a property on a null object.
Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.PSObject.Properties.Remove('behavior') } `
    -ExpectedMessage "scale-up stabilizationWindowSeconds is missing" `
    -Description "a manifest without .spec.behavior was rejected"

Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.metrics[1].pods.PSObject.Properties.Remove('target') } `
    -ExpectedMessage "target type is missing" `
    -Description "a custom metric with no target was rejected"

Write-Host "[ok] custom-metrics HPA structure checks behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
