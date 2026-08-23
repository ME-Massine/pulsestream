# Validates the platform-isolation NetworkPolicies (#147), including the OTLP
# egress rules added for the in-cluster collector (#157).
#
# These checks are STRUCTURAL: they assert that the applied policies are shaped
# correctly - the right pods are selected, both directions are default-denied,
# DNS is allowed, and each service's required paths are present while the ones it
# must not have are absent. They are deliberately CNI-independent, so they are
# the checks that mean something on a dev cluster whose CNI does not enforce
# NetworkPolicy (kindnet, Docker Desktop). Proving that traffic is actually
# blocked needs an enforcing CNI and is documented as a manual step in
# infrastructure/kubernetes/network-policies/README.md.
[CmdletBinding()]
param(
    [string] $Namespace = "default"
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamKubernetes.psm1") -Force

# --- Predicates over a parsed NetworkPolicy ----------------------------------
# kubectl -o json gives each rule's ports as {port, protocol}, where `port` is an
# integer (9092) or a named string ("http"). Stringifying both sides makes the
# two cases comparable with one test.
function Test-RuleHasPort {
    param($Rule, $Port, $Protocol)
    if ($null -eq $Rule.ports) { return $false }
    return @($Rule.ports | Where-Object { "$($_.port)" -eq "$Port" -and $_.protocol -eq $Protocol }).Count -ge 1
}

function Test-PeerIsKubeDns {
    param($Peer)
    return ($Peer.namespaceSelector.matchLabels.'kubernetes.io/metadata.name' -eq 'kube-system') -and
           ($Peer.podSelector.matchLabels.'k8s-app' -eq 'kube-dns')
}

function Test-PeerIsKafka {
    param($Peer)
    return ($Peer.podSelector.matchLabels.'strimzi.io/cluster' -eq 'pulsestream')
}

# The OTLP collector peer (#157). Both selectors have to sit on the SAME peer
# element: within one peer they are ANDed, so this reaches the collector pods in
# `observability` and nothing else there. Split across two peers they are ORed,
# which silently widens the hole to every pod in that namespace plus every pod
# named otel-collector in any namespace.
function Test-PeerIsOtelCollector {
    param($Peer)
    return ($Peer.namespaceSelector.matchLabels.'kubernetes.io/metadata.name' -eq 'observability') -and
           ($Peer.podSelector.matchLabels.'app.kubernetes.io/name' -eq 'otel-collector')
}

# A 4318 rule is acceptable only if EVERY one of its peers is the collector.
# One unscoped peer is enough to widen the whole rule, because peers within a
# rule are ORed.
function Test-RuleIsScopedToOtelCollector {
    param($Rule)

    $peers = @($Rule.to | Where-Object { $null -ne $_ })
    # An egress rule carrying ports but no `to` allows those ports to EVERY
    # destination. That is the widest shape there is, and an absent `to`
    # serializes to null rather than an empty array, so it has to be rejected
    # here explicitly instead of falling through the all-peers-match test below
    # (which an empty collection would pass vacuously).
    if ($peers.Count -eq 0) { return $false }

    return @($peers | Where-Object { Test-PeerIsOtelCollector $_ }).Count -eq $peers.Count
}

# Every rule that opens TCP 4318, including one that opens it as part of a
# range. A NetworkPolicy port entry may carry `endPort`, so {port: 4000,
# endPort: 5000} reaches the collector port while its `port` field reads 4000 -
# matching on `port` alone would walk straight past it.
function Test-RuleOpensOtlpPort {
    param($Rule)
    if ($null -eq $Rule.ports) { return $false }
    return @($Rule.ports | Where-Object {
        if ($_.protocol -ne 'TCP') { return $false }
        $start = $_.port -as [int]
        if ($null -eq $start) { return $false }   # named port ("http"), not 4318
        $end = if ($null -ne $_.endPort) { [int] $_.endPort } else { $start }
        return (4318 -ge $start) -and (4318 -le $end)
    }).Count -ge 1
}

function Get-OtlpEgressRules {
    param($Policy)
    return @($Policy.spec.egress | Where-Object { Test-RuleOpensOtlpPort $_ })
}

# The OTLP hole is correct only when BOTH facts hold, which is why they are two
# assertions and not one. "A collector rule exists" is not sufficient on its
# own: a policy can carry a correctly narrow rule AND a second unrestricted
# 4318 rule beside it, and stopping at the first acceptable rule would report
# that policy as sound. So every 4318 rule is inspected, and any rule not
# exclusively scoped to the collector fails the policy no matter what else it
# contains.
function Test-OtlpEgressToCollector {
    param($Policy)
    return @(Get-OtlpEgressRules $Policy | Where-Object { Test-RuleIsScopedToOtelCollector $_ }).Count -ge 1
}

function Get-UnscopedOtlpEgressRules {
    param($Policy)
    return @(Get-OtlpEgressRules $Policy | Where-Object { -not (Test-RuleIsScopedToOtelCollector $_) })
}

# A DNS egress hole is only correct if it reaches the kube-dns pods on BOTH
# UDP/53 and TCP/53 (large answers and zone transfers fall back to TCP).
function Test-DnsEgress {
    param($Policy)
    foreach ($rule in @($Policy.spec.egress)) {
        $toKubeDns = @($rule.to | Where-Object { Test-PeerIsKubeDns $_ }).Count -ge 1
        if ($toKubeDns -and (Test-RuleHasPort $rule 53 'UDP') -and (Test-RuleHasPort $rule 53 'TCP')) {
            return $true
        }
    }
    return $false
}

function Test-KafkaEgress {
    param($Policy)
    foreach ($rule in @($Policy.spec.egress)) {
        $toKafka = @($rule.to | Where-Object { Test-PeerIsKafka $_ }).Count -ge 1
        if ($toKafka -and (Test-RuleHasPort $rule 9092 'TCP')) { return $true }
    }
    return $false
}

function Test-EgressHasPort {
    param($Policy, $Port, $Protocol)
    foreach ($rule in @($Policy.spec.egress)) {
        if (Test-RuleHasPort $rule $Port $Protocol) { return $true }
    }
    return $false
}

# Ingress rule that admits every peer on a port: a rule with matching ports and
# no `from` peers at all. An absent `from` serializes to null (not an empty
# array), so the null test is what distinguishes "all peers" from "these peers".
function Test-IngressAllPeersOnPort {
    param($Policy, $Port, $Protocol)
    foreach ($rule in @($Policy.spec.ingress)) {
        if ((Test-RuleHasPort $rule $Port $Protocol) -and ($null -eq $rule.from)) { return $true }
    }
    return $false
}

# Ingress rule that admits only the policy's own namespace on a port: a `from`
# peer that is an empty podSelector ({}) with no namespaceSelector/ipBlock. An
# empty podSelector has no matchLabels, which is how it means "all pods in this
# namespace" rather than a specific set.
function Test-IngressFromSameNamespaceOnPort {
    param($Policy, $Port, $Protocol)
    foreach ($rule in @($Policy.spec.ingress)) {
        if (-not (Test-RuleHasPort $rule $Port $Protocol)) { continue }
        foreach ($peer in @($rule.from)) {
            $emptyPodSelector = ($null -ne $peer.podSelector) -and ($null -eq $peer.podSelector.matchLabels)
            if ($emptyPodSelector -and ($null -eq $peer.namespaceSelector) -and ($null -eq $peer.ipBlock)) {
                return $true
            }
        }
    }
    return $false
}

# Exact ingress shape for telemetry-processor's operational connectivity probe:
# one rule, one named port, and one same-namespace peer carrying both fixed
# labels. Requiring the complete shape prevents an additional broad peer or port
# from being mistaken for the narrow exception.
function Test-IngressOnlyFromConnectivityProbe {
    param($Policy)

    $rules = @($Policy.spec.ingress | Where-Object { $null -ne $_ })
    if ($rules.Count -ne 1) { return $false }

    $rule = $rules[0]
    if (@($rule.ports).Count -ne 1 -or -not (Test-RuleHasPort $rule "http" "TCP")) {
        return $false
    }

    $peers = @($rule.from | Where-Object { $null -ne $_ })
    if ($peers.Count -ne 1) { return $false }

    $peer = $peers[0]
    $labels = $peer.podSelector.matchLabels
    $expectedLabels = Get-ServiceConnectivityProbeLabels
    return ($null -ne $peer.podSelector) -and
           ($null -eq $peer.podSelector.matchExpressions) -and
           (@($labels.PSObject.Properties).Count -eq $expectedLabels.Count) -and
           ($labels.'app.kubernetes.io/name' -eq $expectedLabels.'app.kubernetes.io/name') -and
           ($labels.'app.kubernetes.io/part-of' -eq $expectedLabels.'app.kubernetes.io/part-of') -and
           ($null -eq $peer.namespaceSelector) -and
           ($null -eq $peer.ipBlock)
}

# --- Load a policy -----------------------------------------------------------
function Get-NetworkPolicy {
    param([string] $Name)
    $json = Invoke-KubectlChecked `
        -KubectlArgs @("get", "networkpolicy", $Name, "--namespace", $Namespace, "-o", "json") `
        -ErrorContext "NetworkPolicy '$Name' was not found in namespace '$Namespace'. Apply infrastructure/kubernetes/network-policies/"
    return $json | ConvertFrom-Json
}

function Assert-CommonShape {
    param($Policy, [string] $Name, [string] $ExpectedAppLabel)

    Confirm-Condition `
        -Condition ($Policy.spec.podSelector.matchLabels.'app.kubernetes.io/name' -eq $ExpectedAppLabel) `
        -SuccessMessage "$Name selects the '$ExpectedAppLabel' pods" `
        -FailureMessage "$Name podSelector is app.kubernetes.io/name='$($Policy.spec.podSelector.matchLabels.'app.kubernetes.io/name')', not '$ExpectedAppLabel'. A wrong selector would police the wrong workload (or none)"

    Confirm-Condition `
        -Condition ((@($Policy.spec.policyTypes) -contains 'Ingress') -and (@($Policy.spec.policyTypes) -contains 'Egress')) `
        -SuccessMessage "$Name default-denies both directions (policyTypes: Ingress, Egress)" `
        -FailureMessage "$Name policyTypes is '$(@($Policy.spec.policyTypes) -join ', ')'; both Ingress and Egress are required so unlisted traffic is denied in both directions"

    Confirm-Condition `
        -Condition (Test-DnsEgress $Policy) `
        -SuccessMessage "$Name allows DNS egress (UDP/TCP 53 to kube-dns)" `
        -FailureMessage "$Name has no DNS egress rule to kube-dns on UDP and TCP 53. With egress default-denied, the pod could not resolve any name and every outbound connection would fail at lookup"
}

# Two assertions, because the required path and the absence of a wider one are
# separate failures with separate causes.
function Assert-OtlpEgress {
    param($Policy, [string] $Name)

    Confirm-Condition `
        -Condition (Test-OtlpEgressToCollector $Policy) `
        -SuccessMessage "$Name allows OTLP egress (TCP 4318 to app.kubernetes.io/name=otel-collector in the 'observability' namespace)" `
        -FailureMessage "$Name has no OTLP egress rule scoped to the collector on TCP 4318. Either the rule is missing - egress default-deny then drops every span, and the workload keeps running while only its own log reports the export timing out - or its namespace and pod selectors are split across separate peers, which ORs them instead of ANDing them"

    $unscoped = @(Get-UnscopedOtlpEgressRules $Policy)
    Confirm-Condition `
        -Condition ($unscoped.Count -eq 0) `
        -SuccessMessage "$Name opens TCP 4318 to the collector and nothing else" `
        -FailureMessage "$Name has $($unscoped.Count) TCP 4318 egress rule(s) that are not exclusively scoped to the collector. A rule with no 'to' reaches every destination, and a rule carrying any non-collector peer reaches that peer too - beside a correct rule this is invisible unless every 4318 rule is inspected"
}

Write-Host "Validating platform-isolation NetworkPolicies in namespace '$Namespace'..."

# --- ingestion-service -------------------------------------------------------
$ingestion = Get-NetworkPolicy -Name "ingestion-service"
Assert-CommonShape -Policy $ingestion -Name "ingestion-service" -ExpectedAppLabel "ingestion-service"

Confirm-Condition `
    -Condition (Test-IngressAllPeersOnPort $ingestion "http" "TCP") `
    -SuccessMessage "ingestion-service admits the 'http' port from any peer (NodePort/probe traffic arrives as a node IP no selector can match)" `
    -FailureMessage "ingestion-service has no ingress rule opening the 'http' port to all peers. External NodePort clients (#145) are SNATed to a node IP and would be blocked"

Confirm-Condition `
    -Condition (Test-KafkaEgress $ingestion) `
    -SuccessMessage "ingestion-service allows Kafka egress (9092 to strimzi.io/cluster=pulsestream)" `
    -FailureMessage "ingestion-service has no Kafka egress rule; it could not publish to telemetry.events.raw"

Assert-OtlpEgress -Policy $ingestion -Name "ingestion-service"

Confirm-Condition `
    -Condition (-not (Test-EgressHasPort $ingestion 5432 'TCP')) `
    -SuccessMessage "ingestion-service has no Postgres egress (5432 stays denied - it holds no datasource)" `
    -FailureMessage "ingestion-service allows egress to 5432, an unnecessary path: the ingest gateway has no datasource"

# --- telemetry-processor -----------------------------------------------------
$processor = Get-NetworkPolicy -Name "telemetry-processor"
Assert-CommonShape -Policy $processor -Name "telemetry-processor" -ExpectedAppLabel "telemetry-processor"

Confirm-Condition `
    -Condition (Test-IngressOnlyFromConnectivityProbe $processor) `
    -SuccessMessage "telemetry-processor admits only the labelled service-connectivity probe on the 'http' port" `
    -FailureMessage "telemetry-processor ingress is not limited to one same-namespace service-connectivity-probe peer on the 'http' port"

Confirm-Condition `
    -Condition (Test-KafkaEgress $processor) `
    -SuccessMessage "telemetry-processor allows Kafka egress (9092 to strimzi.io/cluster=pulsestream)" `
    -FailureMessage "telemetry-processor has no Kafka egress rule; it could not consume or produce its streams"

Confirm-Condition `
    -Condition (Test-EgressHasPort $processor 5432 'TCP') `
    -SuccessMessage "telemetry-processor allows Postgres egress (TCP 5432)" `
    -FailureMessage "telemetry-processor has no egress rule to 5432; it could not persist processed events"

Assert-OtlpEgress -Policy $processor -Name "telemetry-processor"

# --- query-service -----------------------------------------------------------
$query = Get-NetworkPolicy -Name "query-service"
Assert-CommonShape -Policy $query -Name "query-service" -ExpectedAppLabel "query-service"

Confirm-Condition `
    -Condition (Test-IngressFromSameNamespaceOnPort $query "http" "TCP") `
    -SuccessMessage "query-service admits the 'http' port from the same namespace only" `
    -FailureMessage "query-service has no ingress rule admitting the 'http' port from same-namespace pods (empty podSelector). In-cluster read clients would be blocked, or the rule is broader than intended"

Confirm-Condition `
    -Condition ((-not (Test-EgressHasPort $query 9092 'TCP')) -and (-not (Test-EgressHasPort $query 5432 'TCP'))) `
    -SuccessMessage "query-service has no Kafka or Postgres egress (it reads no datastore today; both paths stay denied)" `
    -FailureMessage "query-service allows egress to Kafka (9092) or Postgres (5432); it consumes neither today, so those paths are unnecessary and should stay denied"

Confirm-Condition `
    -Condition (@(Get-OtlpEgressRules $query).Count -eq 0) `
    -SuccessMessage "query-service has no OTLP egress (4318 stays denied - it carries no 'otel' configuration and emits no spans)" `
    -FailureMessage "query-service allows egress to 4318; it has no OpenTelemetry configuration in application.yml and exports no traces, so that path is unnecessary and should stay denied"

# --- Optional: are the selected workloads present? ---------------------------
# Non-fatal. Policies are valid to apply before their workloads exist, so a
# missing Deployment is a heads-up, not a failure.
foreach ($app in @("ingestion-service", "telemetry-processor", "query-service")) {
    $pods = Invoke-KubectlChecked `
        -KubectlArgs @("get", "pods", "--namespace", $Namespace, "-l", "app.kubernetes.io/name=$app", "-o", "name") `
        -ErrorContext "Could not list pods for '$app'"
    $count = @($pods -split "`n" | Where-Object { $_.Trim() }).Count
    if ($count -eq 0) {
        Write-Host "[warn] no pods currently match app.kubernetes.io/name=$app; the '$app' policy will take effect once the workload is deployed"
    } else {
        Write-Host "[ok] $count pod(s) match the '$app' policy selector"
    }
}

Write-Host "[ok] NetworkPolicy structural validation completed in namespace '$Namespace'."
