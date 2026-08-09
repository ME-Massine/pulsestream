# Exercises validate-network-policies.ps1 against the committed manifests
# without applying anything to a cluster. kubectl's client-side serializer
# supplies the same JSON shape that `kubectl get -o json` returns, then a local
# function serves that JSON to the validator.
#
#   powershell -File scripts\tests\test-network-policy-structure.ps1
#   pwsh -File scripts/tests/test-network-policy-structure.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$kubectlExecutable = (Get-Command kubectl -CommandType Application -ErrorAction Stop).Source
$policyDirectory = Join-Path $PSScriptRoot "..\..\infrastructure\kubernetes\network-policies"
$validator = Join-Path $PSScriptRoot "..\validate-network-policies.ps1"
$global:PulseStreamPolicyJson = @{}

foreach ($name in @("ingestion-service", "telemetry-processor", "query-service")) {
    $manifest = Join-Path $policyDirectory "$name.yaml"
    $json = & $kubectlExecutable create --dry-run=client --validate=false -o json -f $manifest 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl could not serialize '$manifest'. $(@($json) -join [Environment]::NewLine)"
    }
    $global:PulseStreamPolicyJson[$name] = @($json) -join [Environment]::NewLine
}

function global:kubectl {
    param([Parameter(ValueFromRemainingArguments = $true)] [object[]] $Arguments)

    $stringArguments = [string[]] @($Arguments | ForEach-Object { $_.ToString() })
    $global:LASTEXITCODE = 0

    if ($stringArguments[0] -eq "get" -and $stringArguments[1] -eq "networkpolicy") {
        $name = $stringArguments[2]
        if ($global:PulseStreamPolicyJson.ContainsKey($name)) {
            $global:PulseStreamPolicyJson[$name]
            return
        }
    }

    if ($stringArguments[0] -eq "get" -and $stringArguments[1] -eq "pods") {
        return
    }

    $global:LASTEXITCODE = 1
    "unexpected kubectl operation: $($stringArguments -join ' ')"
}

try {
    & $validator -Namespace "policy-test"

    # The telemetry exception must remain exact. An extra broad ingress rule
    # would allow ordinary pods and must make the structural validator fail.
    $processor = $global:PulseStreamPolicyJson["telemetry-processor"] | ConvertFrom-Json
    $processor.spec.ingress = @($processor.spec.ingress) + [pscustomobject]@{
        ports = @([pscustomobject]@{ port = "http"; protocol = "TCP" })
    }
    $global:PulseStreamPolicyJson["telemetry-processor"] = $processor | ConvertTo-Json -Depth 20

    $rejectedBroadIngress = $false
    try {
        & $validator -Namespace "policy-test"
    } catch {
        if ($_.Exception.Message -match "ingress is not limited") {
            $rejectedBroadIngress = $true
            Write-Host "[ok] telemetry-processor broad ingress was rejected"
        } else {
            throw
        }
    }

    if (-not $rejectedBroadIngress) {
        throw "The structural validator accepted an additional broad telemetry-processor ingress rule."
    }
} finally {
    Remove-Item -LiteralPath Function:\kubectl -ErrorAction SilentlyContinue
    Remove-Variable -Name PulseStreamPolicyJson -Scope Global -ErrorAction SilentlyContinue
}

Write-Host "[ok] NetworkPolicy structure checks behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
