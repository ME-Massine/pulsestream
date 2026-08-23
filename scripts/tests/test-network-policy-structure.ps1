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

# Each negative case below mutates one policy. Keeping a copy of the originals
# lets a case be undone before the next one runs, so every failure the validator
# reports is caused by the mutation under test and not by a leftover one.
$originalIngestion = $global:PulseStreamPolicyJson["ingestion-service"] | ConvertFrom-Json
$originalProcessor = $global:PulseStreamPolicyJson["telemetry-processor"] | ConvertFrom-Json
$originalQuery = $global:PulseStreamPolicyJson["query-service"] | ConvertFrom-Json

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

# Reads a policy back out of the serialized JSON so a case can mutate it.
function Get-PolicyObject {
    param([Parameter(Mandatory = $true)] [string] $Name)
    return $global:PulseStreamPolicyJson[$Name] | ConvertFrom-Json
}

# Writes a policy back, so the next validator run sees it.
function Set-PolicyObject {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] $Policy
    )
    $global:PulseStreamPolicyJson[$Name] = $Policy | ConvertTo-Json -Depth 20
}

# Runs the validator against the current in-memory policies and requires it to
# fail with a message matching $ExpectedMessage. A mutation the validator
# accepts is the failure this reports: the check it was meant to exercise is not
# asserting anything.
function Assert-ValidatorRejects {
    param(
        [Parameter(Mandatory = $true)] [string] $ExpectedMessage,
        [Parameter(Mandatory = $true)] [string] $Description
    )

    try {
        & $validator -Namespace "policy-test"
    } catch {
        if ($_.Exception.Message -match $ExpectedMessage) {
            Write-Host "[ok] $Description was rejected"
            return
        }
        throw
    }

    throw "The structural validator accepted $Description."
}

try {
    & $validator -Namespace "policy-test"

    # The telemetry exception must remain exact. An extra broad ingress rule
    # would allow ordinary pods and must make the structural validator fail.
    $processor = Get-PolicyObject -Name "telemetry-processor"
    $processor.spec.ingress = @($processor.spec.ingress) + [pscustomobject]@{
        ports = @([pscustomobject]@{ port = "http"; protocol = "TCP" })
    }
    Set-PolicyObject -Name "telemetry-processor" -Policy $processor

    Assert-ValidatorRejects `
        -ExpectedMessage "ingress is not limited" `
        -Description "an additional broad telemetry-processor ingress rule"

    Set-PolicyObject -Name "telemetry-processor" -Policy $originalProcessor

    # --- OTLP egress (#157) --------------------------------------------------
    # The collector peer ANDs its namespaceSelector and podSelector because both
    # sit on one peer element. Splitting them across two peers turns that AND
    # into an OR: the rule then reaches every pod in `observability` and every
    # pod labelled otel-collector in any other namespace. The port is still
    # 4318 and every label is still present, so only a check that inspects the
    # peer structure catches it.
    $ingestion = Get-PolicyObject -Name "ingestion-service"
    $otlpRules = @($ingestion.spec.egress | Where-Object {
        @($_.ports | Where-Object { "$($_.port)" -eq "4318" }).Count -ge 1
    })

    if ($otlpRules.Count -ne 1) {
        throw "Expected exactly one OTLP egress rule in the ingestion-service policy, found $($otlpRules.Count). The committed manifest changed shape and this case no longer exercises what it claims to."
    }

    $collectorPeer = @($otlpRules[0].to)[0]
    $otlpRules[0].to = @(
        [pscustomobject]@{ namespaceSelector = $collectorPeer.namespaceSelector },
        [pscustomobject]@{ podSelector = $collectorPeer.podSelector }
    )
    Set-PolicyObject -Name "ingestion-service" -Policy $ingestion

    Assert-ValidatorRejects `
        -ExpectedMessage "ingestion-service has no OTLP egress rule" `
        -Description "an ingestion-service OTLP rule whose namespace and pod selectors were split into separate peers"

    Set-PolicyObject -Name "ingestion-service" -Policy $originalIngestion

    # The committed narrow rule is KEPT here and a second, wider 4318 rule is
    # added beside it. This is the case a first-match check reports as sound:
    # the correct rule is present and matches, so anything that stops looking
    # once it finds one never sees the rule that opens the port to the whole
    # `observability` namespace.
    $ingestion = Get-PolicyObject -Name "ingestion-service"
    $ingestion.spec.egress = @($ingestion.spec.egress) + [pscustomobject]@{
        to    = @([pscustomobject]@{
            namespaceSelector = [pscustomobject]@{ matchLabels = [pscustomobject]@{ "kubernetes.io/metadata.name" = "observability" } }
        })
        ports = @([pscustomobject]@{ port = 4318; protocol = "TCP" })
    }
    Set-PolicyObject -Name "ingestion-service" -Policy $ingestion

    # Guard the premise: if the narrow rule stopped matching, this case would
    # pass for the wrong reason - a missing rule rather than the extra one.
    $ingestionCheck = Get-PolicyObject -Name "ingestion-service"
    $rules4318 = @($ingestionCheck.spec.egress | Where-Object {
        @($_.ports | Where-Object { "$($_.port)" -eq "4318" }).Count -ge 1
    })
    if ($rules4318.Count -ne 2) {
        throw "Expected the narrow rule plus the added broad rule (2 rules on 4318), found $($rules4318.Count). This case is no longer testing a valid-plus-broad policy."
    }

    Assert-ValidatorRejects `
        -ExpectedMessage "not exclusively scoped to the collector" `
        -Description "an ingestion-service policy carrying a valid narrow collector rule AND a namespace-wide 4318 rule"

    Set-PolicyObject -Name "ingestion-service" -Policy $originalIngestion

    # Same shape, widest possible peer: an egress rule with ports and no `to`
    # at all allows 4318 to every destination in the cluster and beyond.
    $ingestion = Get-PolicyObject -Name "ingestion-service"
    $ingestion.spec.egress = @($ingestion.spec.egress) + [pscustomobject]@{
        ports = @([pscustomobject]@{ port = 4318; protocol = "TCP" })
    }
    Set-PolicyObject -Name "ingestion-service" -Policy $ingestion

    Assert-ValidatorRejects `
        -ExpectedMessage "not exclusively scoped to the collector" `
        -Description "an ingestion-service policy carrying a valid narrow collector rule AND a 4318 rule with no 'to' peers"

    Set-PolicyObject -Name "ingestion-service" -Policy $originalIngestion

    # A dropped rule is the other failure mode, and the quiet one: the service
    # stays healthy and only its own log shows the export timing out.
    $processor = Get-PolicyObject -Name "telemetry-processor"
    $processor.spec.egress = @($processor.spec.egress | Where-Object {
        @($_.ports | Where-Object { "$($_.port)" -eq "4318" }).Count -eq 0
    })
    Set-PolicyObject -Name "telemetry-processor" -Policy $processor

    Assert-ValidatorRejects `
        -ExpectedMessage "telemetry-processor has no OTLP egress rule" `
        -Description "a telemetry-processor policy with its OTLP egress rule removed"

    Set-PolicyObject -Name "telemetry-processor" -Policy $originalProcessor

    # query-service exports no traces, so an OTLP hole there is a widening to
    # catch rather than a rule to require.
    $query = Get-PolicyObject -Name "query-service"
    $query.spec.egress = @($query.spec.egress) + [pscustomobject]@{
        to    = @([pscustomobject]@{
            namespaceSelector = [pscustomobject]@{ matchLabels = [pscustomobject]@{ "kubernetes.io/metadata.name" = "observability" } }
            podSelector       = [pscustomobject]@{ matchLabels = [pscustomobject]@{ "app.kubernetes.io/name" = "otel-collector" } }
        })
        ports = @([pscustomobject]@{ port = 4318; protocol = "TCP" })
    }
    Set-PolicyObject -Name "query-service" -Policy $query

    Assert-ValidatorRejects `
        -ExpectedMessage "query-service allows egress to 4318" `
        -Description "an OTLP egress rule on query-service, which emits no spans"

    Set-PolicyObject -Name "query-service" -Policy $originalQuery
} finally {
    Remove-Item -LiteralPath Function:\kubectl -ErrorAction SilentlyContinue
    Remove-Variable -Name PulseStreamPolicyJson -Scope Global -ErrorAction SilentlyContinue
}

Write-Host "[ok] NetworkPolicy structure checks behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
