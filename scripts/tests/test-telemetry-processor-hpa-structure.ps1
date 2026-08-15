# Runs the telemetry-processor HPA structural checks against the committed
# manifest. No cluster, no kubectl, no network.
#
# The manifest is read with scripts/lib/PulseStreamYaml.psm1 and handed to the
# same Confirm-TelemetryProcessorHpa that validate-telemetry-processor-hpa.ps1
# calls on a live HPA, so the two cannot drift. Nothing here is defined in the
# global scope: an earlier version stubbed out kubectl as a global function and
# parked the manifest JSON in a global variable, which every other script in the
# same session then inherited.
#
#   powershell -File scripts\tests\test-telemetry-processor-hpa-structure.ps1
#   pwsh -File scripts/tests/test-telemetry-processor-hpa-structure.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamYaml.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamAutoscaling.psm1") -Force

$script:Manifest = Join-Path $PSScriptRoot "..\..\infrastructure\kubernetes\telemetry-processor\hpa.yaml"

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
        Confirm-TelemetryProcessorHpa -Hpa $hpa
    } catch {
        if ($_.Exception.Message -match $ExpectedMessage) {
            Write-Host "[ok] $Description"
            return
        }

        throw "Expected a rejection matching '$ExpectedMessage' for $Description, got: $($_.Exception.Message)"
    }

    throw "The structural validator accepted $Description."
}

Confirm-TelemetryProcessorHpa -Hpa (ConvertFrom-KubernetesYaml -Path $script:Manifest)

# minReplicas must stay the documented floor. A lower value would let the
# autoscaler undo the availability guarantee deployment.yaml relies on.
Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.minReplicas = 1 } `
    -ExpectedMessage "minReplicas is 1, not 2" `
    -Description "a minReplicas of 1 was rejected"

# maxReplicas is the partition count of telemetry.events.raw. A higher ceiling
# adds replicas that are assigned no partition and do no work, so it has to fail
# structurally rather than be discovered on a live cluster.
Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.maxReplicas = 6 } `
    -ExpectedMessage "maxReplicas is 6, not 3" `
    -Description "a maxReplicas above the 3-partition ceiling was rejected"

# A dropped section is valid to the API server - the defaults just take over -
# so each one has to surface as a validation failure naming the field, not as a
# PowerShell error about a property on a null object.
Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.PSObject.Properties.Remove('behavior') } `
    -ExpectedMessage "scale-up stabilizationWindowSeconds is missing" `
    -Description "a manifest without .spec.behavior was rejected"

Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.behavior.PSObject.Properties.Remove('scaleDown') } `
    -ExpectedMessage "scale-down stabilizationWindowSeconds is missing" `
    -Description "a manifest without .spec.behavior.scaleDown was rejected"

Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.PSObject.Properties.Remove('metrics') } `
    -ExpectedMessage "no Resource/cpu Utilization metric" `
    -Description "a manifest without .spec.metrics was rejected"

Assert-ValidatorRejects `
    -Mutation { param($hpa) $hpa.spec.metrics[0].resource.target.PSObject.Properties.Remove('averageUtilization') } `
    -ExpectedMessage "CPU averageUtilization is missing" `
    -Description "a CPU metric without a target utilization was rejected"

Write-Host "[ok] telemetry-processor HPA structure checks behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
