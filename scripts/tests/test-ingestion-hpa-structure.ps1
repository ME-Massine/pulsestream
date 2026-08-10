# Exercises validate-ingestion-hpa.ps1 against the committed manifest without
# applying anything to a cluster. kubectl's client-side serializer supplies the
# same JSON shape that `kubectl get -o json` returns, then a local function
# serves that JSON to the validator.
#
#   powershell -File scripts\tests\test-ingestion-hpa-structure.ps1
#   pwsh -File scripts/tests/test-ingestion-hpa-structure.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$kubectlExecutable = (Get-Command kubectl -CommandType Application -ErrorAction Stop).Source
$manifest = Join-Path $PSScriptRoot "..\..\infrastructure\kubernetes\ingestion-service\hpa.yaml"
$validator = Join-Path $PSScriptRoot "..\validate-ingestion-hpa.ps1"

$json = & $kubectlExecutable create --dry-run=client --validate=false -o json -f $manifest 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "kubectl could not serialize '$manifest'. $(@($json) -join [Environment]::NewLine)"
}
$global:PulseStreamHpaJson = @($json) -join [Environment]::NewLine

function global:kubectl {
    param([Parameter(ValueFromRemainingArguments = $true)] [object[]] $Arguments)

    $stringArguments = [string[]] @($Arguments | ForEach-Object { $_.ToString() })
    $global:LASTEXITCODE = 0

    if ($stringArguments[0] -eq "get" -and $stringArguments[1] -eq "hpa" -and $stringArguments[2] -eq "ingestion-service") {
        $global:PulseStreamHpaJson
        return
    }

    $global:LASTEXITCODE = 1
    "unexpected kubectl operation: $($stringArguments -join ' ')"
}

try {
    & $validator -Namespace "hpa-test"

    # minReplicas must stay the documented floor. A lower value would let the
    # autoscaler undo the availability guarantee deployment.yaml relies on.
    $hpa = $global:PulseStreamHpaJson | ConvertFrom-Json
    $hpa.spec.minReplicas = 1
    $global:PulseStreamHpaJson = $hpa | ConvertTo-Json -Depth 20

    $rejectedLowerFloor = $false
    try {
        & $validator -Namespace "hpa-test"
    } catch {
        if ($_.Exception.Message -match "minReplicas is 1, not 2") {
            $rejectedLowerFloor = $true
            Write-Host "[ok] a minReplicas of 1 was rejected"
        } else {
            throw
        }
    }

    if (-not $rejectedLowerFloor) {
        throw "The structural validator accepted a minReplicas of 1."
    }
} finally {
    Remove-Item -LiteralPath Function:\kubectl -ErrorAction SilentlyContinue
    Remove-Variable -Name PulseStreamHpaJson -Scope Global -ErrorAction SilentlyContinue
}

Write-Host "[ok] ingestion-service HPA structure checks behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
