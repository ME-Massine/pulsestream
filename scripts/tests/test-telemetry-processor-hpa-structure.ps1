# Exercises validate-telemetry-processor-hpa.ps1 against the committed manifest
# without applying anything to a cluster. kubectl's client-side serializer
# supplies the same JSON shape that `kubectl get -o json` returns, then a local
# function serves that JSON to the validator.
#
#   powershell -File scripts\tests\test-telemetry-processor-hpa-structure.ps1
#   pwsh -File scripts/tests/test-telemetry-processor-hpa-structure.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$kubectlExecutable = (Get-Command kubectl -CommandType Application -ErrorAction Stop).Source
$manifest = Join-Path $PSScriptRoot "..\..\infrastructure\kubernetes\telemetry-processor\hpa.yaml"
$validator = Join-Path $PSScriptRoot "..\validate-telemetry-processor-hpa.ps1"

$json = & $kubectlExecutable create --dry-run=client --validate=false -o json -f $manifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "kubectl could not serialize '$manifest'. $(@($json) -join [Environment]::NewLine)"
}
$global:PulseStreamHpaJson = @($json) -join [Environment]::NewLine

function global:kubectl {
    param([Parameter(ValueFromRemainingArguments = $true)] [object[]] $Arguments)

    $stringArguments = [string[]] @($Arguments | ForEach-Object { $_.ToString() })
    $global:LASTEXITCODE = 0

    if ($stringArguments[0] -eq "get" -and $stringArguments[1] -eq "hpa" -and $stringArguments[2] -eq "telemetry-processor") {
        $global:PulseStreamHpaJson
        return
    }

    $global:LASTEXITCODE = 1
    "unexpected kubectl operation: $($stringArguments -join ' ')"
}

function Assert-ValidatorRejects {
    param(
        [scriptblock] $Mutation,
        [string] $ExpectedMessage,
        [string] $Description
    )

    $original = $global:PulseStreamHpaJson
    try {
        $hpa = $original | ConvertFrom-Json
        & $Mutation $hpa
        $global:PulseStreamHpaJson = $hpa | ConvertTo-Json -Depth 20

        $rejected = $false
        try {
            & $validator -Namespace "hpa-test"
        } catch {
            if ($_.Exception.Message -match $ExpectedMessage) {
                $rejected = $true
                Write-Host "[ok] $Description"
            } else {
                throw
            }
        }

        if (-not $rejected) {
            throw "The structural validator accepted $Description."
        }
    } finally {
        $global:PulseStreamHpaJson = $original
    }
}

try {
    & $validator -Namespace "hpa-test"

    # minReplicas must stay the documented floor. A lower value would let the
    # autoscaler undo the availability guarantee deployment.yaml relies on.
    Assert-ValidatorRejects `
        -Mutation { param($hpa) $hpa.spec.minReplicas = 1 } `
        -ExpectedMessage "minReplicas is 1, not 2" `
        -Description "a minReplicas of 1 was rejected"

    # maxReplicas is the partition count of telemetry.events.raw. A higher
    # ceiling adds replicas that are assigned no partition and do no work, so it
    # has to fail structurally rather than be discovered on a live cluster.
    Assert-ValidatorRejects `
        -Mutation { param($hpa) $hpa.spec.maxReplicas = 6 } `
        -ExpectedMessage "maxReplicas is 6, not 3" `
        -Description "a maxReplicas above the 3-partition ceiling was rejected"
} finally {
    Remove-Item -LiteralPath Function:\kubectl -ErrorAction SilentlyContinue
    Remove-Variable -Name PulseStreamHpaJson -Scope Global -ErrorAction SilentlyContinue
}

Write-Host "[ok] telemetry-processor HPA structure checks behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
