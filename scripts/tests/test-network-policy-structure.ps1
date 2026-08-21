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
    $originalProcessorJson = $global:PulseStreamPolicyJson["telemetry-processor"]
    $processor = $originalProcessorJson | ConvertFrom-Json
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
    $global:PulseStreamPolicyJson["telemetry-processor"] = $originalProcessorJson

    # The Prometheus scrape allowance on query-service (#154) must stay pinned
    # to the exact server-pod labels. Dropping one label widens the peer to
    # "any pod in monitoring carrying the other two labels" - the validator
    # must reject that, not treat it as close enough.
    $originalQueryJson = $global:PulseStreamPolicyJson["query-service"]
    $query = $originalQueryJson | ConvertFrom-Json
    $prometheusRule = @($query.spec.ingress) | Where-Object {
        @($_.from) | Where-Object { $null -ne $_.namespaceSelector -and $_.namespaceSelector.matchLabels.'kubernetes.io/metadata.name' -eq 'monitoring' }
    } | Select-Object -First 1
    if ($null -eq $prometheusRule) {
        throw "query-service.yaml has no ingress rule for the monitoring namespace to mutate; add the Prometheus scrape allowance first"
    }
    $prometheusPeer = @($prometheusRule.from) | Where-Object { $null -ne $_.namespaceSelector } | Select-Object -First 1
    $prometheusPeer.podSelector.matchLabels.PSObject.Properties.Remove('app.kubernetes.io/component')
    $global:PulseStreamPolicyJson["query-service"] = $query | ConvertTo-Json -Depth 20

    $rejectedWidenedPrometheusPeer = $false
    try {
        & $validator -Namespace "policy-test"
    } catch {
        if ($_.Exception.Message -match "monitoring-namespace Prometheus server pods") {
            $rejectedWidenedPrometheusPeer = $true
            Write-Host "[ok] query-service Prometheus ingress peer with a dropped label was rejected"
        } else {
            throw
        }
    }
    if (-not $rejectedWidenedPrometheusPeer) {
        throw "The structural validator accepted a query-service Prometheus ingress peer missing a required label."
    }
    $global:PulseStreamPolicyJson["query-service"] = $originalQueryJson

    # Removing the Prometheus allowance entirely must also fail - it is not
    # implied by the same-namespace rule.
    $queryNoPrometheus = $originalQueryJson | ConvertFrom-Json
    $queryNoPrometheus.spec.ingress = @($queryNoPrometheus.spec.ingress | Where-Object {
        -not (@($_.from) | Where-Object { $null -ne $_.namespaceSelector -and $_.namespaceSelector.matchLabels.'kubernetes.io/metadata.name' -eq 'monitoring' })
    })
    $global:PulseStreamPolicyJson["query-service"] = $queryNoPrometheus | ConvertTo-Json -Depth 20

    $rejectedMissingPrometheusRule = $false
    try {
        & $validator -Namespace "policy-test"
    } catch {
        if ($_.Exception.Message -match "monitoring-namespace Prometheus server pods") {
            $rejectedMissingPrometheusRule = $true
            Write-Host "[ok] query-service missing the Prometheus ingress allowance was rejected"
        } else {
            throw
        }
    }
    if (-not $rejectedMissingPrometheusRule) {
        throw "The structural validator accepted a query-service policy with no Prometheus scrape ingress rule."
    }
} finally {
    Remove-Item -LiteralPath Function:\kubectl -ErrorAction SilentlyContinue
    Remove-Variable -Name PulseStreamPolicyJson -Scope Global -ErrorAction SilentlyContinue
}

Write-Host "[ok] NetworkPolicy structure checks behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
