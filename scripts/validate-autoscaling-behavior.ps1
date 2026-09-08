# End-to-end validation of autoscaling behavior under load (#153).
#
# The existing autoscaling scripts (validate-ingestion-hpa.ps1,
# validate-telemetry-processor-hpa.ps1) assert the SHAPE of the HorizontalPod-
# Autoscaler and are deliberately load-independent. This script asserts what the
# HPA actually DOES: it generates real load, samples the workload while the
# autoscaler reacts, removes the load, and then checks the recorded timeline.
#
# The judgement lives in scripts/lib/PulseStreamAutoscalingBehavior.psm1, which
# is pure and has no cluster dependency, so the pass/fail rules are exercised
# offline by scripts/tests/test-autoscaling-behavior-analysis.ps1 - including
# the failure timelines a real cluster will not produce on demand. This script
# is the half that needs a cluster: it collects samples and drives load.
#
# Load is real platform traffic, not a CPU burner, because a CPU burner would
# prove the HPA can read a number and nothing about the service under it:
#
#   ingestion-service    POST /api/v1/events from in-cluster curl pods, which
#                        goes through validation and a produce to Kafka.
#   telemetry-processor  valid TelemetryEvent JSON produced into
#                        telemetry.events.raw, which the consumer group then
#                        deserializes, checks for anomalies, persists, and
#                        republishes.
#
# Nothing here modifies a committed manifest. The load pods are labelled and
# removed in a finally block, so an interrupted run does not leave traffic
# generators behind.
#
#   pwsh -File scripts/validate-autoscaling-behavior.ps1
#   pwsh -File scripts/validate-autoscaling-behavior.ps1 -Service telemetry-processor
[CmdletBinding()]
param(
    [string] $Namespace = "default",
    # The autoscaled workload under test. Both are Deployment/HPA pairs with the
    # same name, so this one value selects the HPA, the Deployment, and the pod
    # label selector.
    [ValidateSet("ingestion-service", "telemetry-processor")]
    [string] $Service = "ingestion-service",
    # Concurrent load pods, and parallel request loops inside each one. Zero
    # selects the service-safe default of one generator pod. Increase it when
    # one pod cannot move the applied HPA past its target.
    [ValidateRange(0, 2147483647)] [int] $LoadPodCount = 0,
    [ValidateRange(1, 2147483647)] [int] $LoadConcurrency = 16,
    # The telemetry generator uses a short scale-up burst, then a sustainable
    # rate. An unthrottled producer measures backlog growth and node starvation,
    # not HPA behavior.
    [ValidateRange(1, 10000)] [int] $KafkaEventsPerSecond = 50,
    [ValidateRange(1, 10000)] [int] $KafkaBurstEventsPerSecond = 350,
    [ValidateRange(1, 3600)] [int] $KafkaBurstDurationSeconds = 45,
    # How long to keep the load running. The scale-up policies allow one step per
    # 60s, so this needs to span several steps to show more than a single jump.
    [ValidateRange(1, 2147483647)] [int] $LoadDurationSeconds = 240,
    [ValidateRange(1, 2147483647)] [int] $SampleIntervalSeconds = 15,
    # kube-controller-manager's --horizontal-pod-autoscaler-tolerance. The
    # scale-down verdict reproduces the controller's desired-replica arithmetic,
    # and that arithmetic ignores a metric within this fraction of its target, so
    # a cluster running a non-default tolerance has to say so here.
    [ValidateRange(0.0, 0.99)] [double] $HpaTolerance = 0.1,
    # Observe the return to minReplicas as well. Off by default because it costs
    # the full scale-down stabilization window (300s) plus one step per replica,
    # which roughly triples the runtime of the script.
    [switch] $IncludeScaleDown,
    # Bound on the scale-down phase. Default covers the 300s window plus four
    # 60s steps plus slack.
    [ValidateRange(1, 2147483647)] [int] $ScaleDownTimeoutSeconds = 900,
    # Written only when the run completes far enough to have a timeline. The
    # report is the "results are documented" half of #153; it is intended to be
    # committed next to the manifest it describes.
    [string] $ReportPath = "",
    [string] $HttpLoadImage = "curlimages/curl:8.11.1",
    [string] $KafkaLoadImage = "quay.io/strimzi/kafka:1.1.0-kafka-4.3.0",
    [string] $KafkaClusterName = "pulsestream",
    [int] $BootstrapPort = 9092,
    [string] $RawTopic = "telemetry.events.raw"
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamKubernetes.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamAutoscalingBehavior.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamAutoscalingLoad.psm1") -Force

$runId = [guid]::NewGuid().ToString("N").Substring(0, 6)
$loadPodLabel = "pulsestream.io/autoscaling-load=$runId"
$podSelector = "app.kubernetes.io/name=$Service"
$successfulRescaleEventCounts = @{}

# The structural validators predate this script and are not named uniformly
# after their workload, so the file name cannot be derived from $Service:
# ingestion-service's is validate-ingestion-hpa.ps1, not
# validate-ingestion-service-hpa.ps1.
$structuralValidators = @{
    "ingestion-service"   = "scripts/validate-ingestion-hpa.ps1"
    "telemetry-processor" = "scripts/validate-telemetry-processor-hpa.ps1"
}
$structuralValidator = $structuralValidators[$Service]
$effectiveLoadPodCount = if ($LoadPodCount -gt 0) { $LoadPodCount } else { 1 }

# --- Load generators ---------------------------------------------------------
# Both templates loop forever. The pod is deleted to stop the load, which is why
# neither needs a duration of its own - a load generator that stopped on its own
# schedule would drift out of step with the sampler and make the timeline lie
# about when the load ended.

#
# eventId carries {{POD}} as well as {{RUN}}: every load pod runs the same
# template with the same counters, so without the pod ordinal a multi-pod run
# posts each id more than once. The platform would then be exercising
# its persistence de-duplication path instead of carrying representative
# traffic, and what the HPA sees is the cost of rejecting duplicates.
#
# The heartbeat counter is pod-global rather than per request loop: each
# successful request appends one byte to a shared file (single-byte appends to
# an O_APPEND descriptor are atomic, so concurrent loops cannot corrupt it) and
# a separate reporter prints its size every 5 seconds. Per-loop counters would
# be 16 independent sequences interleaved in one log, and the sampler could not
# tell a rising counter from a slower loop's older one.
$httpLoadTemplate = @'
set -u
counter=/tmp/pulsestream-load-successes
: > $counter
n=0
while [ $n -lt {{CONCURRENCY}} ]; do
  n=$((n+1))
  (
    i=0
    while true; do
      i=$((i+1))
      if curl -fsS -o /dev/null -m 5 -X POST "http://{{TARGET}}:{{PORT}}/api/v1/events" \
        -H 'Content-Type: application/json' \
        -d "{\"eventId\":\"evt_{{RUN}}_{{POD}}_${n}_${i}\",\"tenantId\":\"autoscaling_validation\",\"eventType\":\"telemetry.reading\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"source\":\"validate-autoscaling-behavior\",\"version\":\"1.0\",\"payload\":{\"deviceId\":\"load-{{RUN}}-{{POD}}-${n}\",\"deviceType\":\"temperature-sensor\",\"metric\":\"temperature\",\"value\":21.5,\"unit\":\"celsius\",\"location\":\"validation-lab\"}}" 2>/dev/null; then
        printf '.' >> $counter
      else
        sleep 1
      fi
    done
  ) &
done
(
  announced=0
  while true; do
    total=$(wc -c < $counter | tr -d ' ')
    if [ "$total" -gt 0 ]; then
      if [ "$announced" -eq 0 ]; then
        echo "pulsestream-autoscaling-load ready http" >&2
        announced=1
      fi
      echo "pulsestream-autoscaling-load heartbeat http $total" >&2
    fi
    sleep 5
  done
) &
wait
'@

# Values alternate between 20.5 and 95.5 so each consecutive pair for a device
# crosses both the temperature threshold and the spike ratio in
# TelemetryAnomalyDetectionService. That keeps every event on the expensive path
# - anomaly detection, the Postgres insert, and the republish - rather than on
# the cheap one, which is what makes CPU move.
#
# eventId and deviceId both carry {{POD}}, for the same reason as the HTTP
# template: every pod runs the same counter from 1, so without the ordinal the
# pods produce identical ids and identical device streams.
#
# The heartbeat counter here is already pod-global - one producer per pod, one
# `i` - and it stops the moment the producer stops draining the pipe, which is
# exactly the hang the sampler watches for.
$kafkaLoadTemplate = @'
set -euo pipefail
# A successful one-message producer run proves the image, shell, base64-decoded
# command, bootstrap route, and producer before the continuous load begins.
printf '{"eventId":"probe-{{RUN}}-{{POD}}","tenantId":"autoscaling_validation","eventType":"telemetry.reading","timestamp":"2026-01-01T00:00:00Z","source":"validate-autoscaling-behavior","version":"1.0","payload":{"deviceId":"probe-{{RUN}}-{{POD}}","deviceType":"temperature-sensor","metric":"temperature","value":20.5,"unit":"celsius","location":"validation-lab"}}\n' | {{BIN}}/kafka-console-producer.sh \
  --bootstrap-server {{BOOTSTRAP}} --topic {{TOPIC}} \
  --producer-property acks=all --producer-property linger.ms=5
echo "pulsestream-autoscaling-load ready kafka" >&2
i=0
while true; do
  i=$((i+1))
  if [ $((i % 2)) -eq 0 ]; then v=20.5; else v=95.5; fi
  printf '{"eventId":"evt_{{RUN}}_{{POD}}_%s","tenantId":"autoscaling_validation","eventType":"telemetry.reading","timestamp":"2026-01-01T00:00:00Z","source":"validate-autoscaling-behavior","version":"1.0","payload":{"deviceId":"load-{{RUN}}-{{POD}}-%s","deviceType":"temperature-sensor","metric":"temperature","value":%s,"unit":"celsius","location":"validation-lab"}}\n' \
    "$i" "$((i % {{DEVICES}}))" "$v"
  if [ $((i % 100)) -eq 0 ]; then echo "pulsestream-autoscaling-load heartbeat kafka $i" >&2; fi
  rate={{BURST_RATE}}
  if [ "$i" -gt {{BURST_EVENTS}} ]; then rate={{RATE}}; fi
  if [ $((i % rate)) -eq 0 ]; then sleep 1; fi
done | {{BIN}}/kafka-console-producer.sh \
  --bootstrap-server {{BOOTSTRAP}} --topic {{TOPIC}} \
  --producer-property acks=all --producer-property linger.ms=5
'@

# --- Sampling ----------------------------------------------------------------
# Event collection is read first, then the workload resources: a controller
# event observed in a sample was emitted only after its scale update succeeded,
# so the later scale read should carry its target unless another writer changed
# it. A rescale racing the event read is allowed to appear one sample late.
# The HPA carries metrics and health status, the scale subresource carries the
# replica count that has
# been REQUESTED of the workload, the Deployment carries the authoritative
# ready count, the pods carry restart counts, and `kubectl top` says how many
# pods metrics-server had a CPU reading for. They are read back to back; the
# scale read keeps its own completion timestamp for decision bounds, and the
# recommendation evidence bundle keeps both edges of its collection interval.

function Get-SuccessfulRescaleEvidenceSnapshot {
    param(
        [Parameter(Mandatory)] [datetime] $ObservedAt,
        [switch] $EstablishBaseline
    )

    # The server-side selector reduces noise; exact HPA UID, kind, reporting
    # component, message shape, and occurrence deltas are still verified locally.
    # Any read failure aborts the run through Invoke-KubectlJsonChecked, because
    # a collection hole can hide either missing or ambiguous evidence.
    $eventList = Invoke-KubectlJsonChecked `
        -KubectlArgs @(
            "get", "events", "--namespace", $Namespace,
            "--field-selector", "reason=SuccessfulRescale", "-o", "json"
        ) `
        -ErrorContext "SuccessfulRescale event collection was interrupted for HPA '$Service'"

    return Get-NewHpaSuccessfulRescaleEvents `
        -Events @($eventList.items) `
        -HpaUid $script:hpaUid `
        -EventCounts $successfulRescaleEventCounts `
        -ObservedAt $ObservedAt `
        -EstablishBaseline:$EstablishBaseline
}

# How many pods of the workload metrics-server currently has a CPU value for.
#
# The HPA averages only the pods it has a metric for and publishes that average
# in status; a validator that divides it back out by the full replica count is
# computing something the controller never did. This count is attached only to
# the CPU reading. A custom-metrics adapter can have different Pod coverage, so
# its coverage stays unknown unless sampled independently.
#
# Null, not zero, when the read fails. A failed `kubectl top` is an absence of
# information, and an unknown count cannot establish a downscale anchor.
function Get-CpuMetricPodCount {
    $top = Invoke-Kubectl -KubectlArgs @(
        "top", "pods", "--namespace", $Namespace, "--selector", $podSelector, "--no-headers"
    )
    if ($top.ExitCode -ne 0) {
        return $null
    }

    $lines = @(($top.Output -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return $lines.Count
}

function Get-Sample {
    param([Parameter(Mandatory)] [int] $TargetPercent)

    # Read events before the other resources; see the sampling contract above.
    $eventObservedAt = (Get-Date).ToUniversalTime()
    $successfulRescaleEvents = Get-SuccessfulRescaleEvidenceSnapshot -ObservedAt $eventObservedAt

    $recommendationEvidenceStartedAt = (Get-Date).ToUniversalTime()
    $hpa = Invoke-KubectlJsonChecked `
            -KubectlArgs @("get", "hpa", $Service, "--namespace", $Namespace, "-o", "json") `
            -ErrorContext "HorizontalPodAutoscaler '$Service' disappeared mid-run"

    if ([string] $hpa.metadata.uid -ne $script:hpaUid) {
        throw "HorizontalPodAutoscaler '$Service' changed UID from '$script:hpaUid' to '$($hpa.metadata.uid)' during the run. A replacement HPA cannot inherit the baseline or rescale evidence."
    }
    $currentGeneration = $null
    if ($null -ne $hpa.metadata.generation) {
        $currentGeneration = [long] $hpa.metadata.generation
    }
    if ([string] $currentGeneration -ne [string] $script:hpaGeneration) {
        throw "HorizontalPodAutoscaler '$Service' changed generation from '$script:hpaGeneration' to '$currentGeneration' during the run. The tested HPA spec must remain fixed."
    }
    $currentSpecJson = $hpa.spec | ConvertTo-Json -Depth 100 -Compress
    if ($currentSpecJson -ne $script:hpaSpecJson) {
        throw "HorizontalPodAutoscaler '$Service' spec changed during the run even though the API did not expose a generation change. The validation only applies to one fixed HPA configuration."
    }

    $deployment = Invoke-KubectlJsonChecked `
            -KubectlArgs @("get", "deployment", $Service, "--namespace", $Namespace, "-o", "json") `
            -ErrorContext "Deployment '$Service' disappeared mid-run"

    # The scale subresource is where the HPA writes its decision, so its
    # spec.replicas moves at the decision; the Deployment's status.replicas
    # moves when the rollout catches up, which can be an entire rollout later.
    # Scale events are timestamped from this read.
    $scale = Invoke-KubectlJsonChecked `
            -KubectlArgs @("get", "deployment", $Service, "--namespace", $Namespace, "--subresource=scale", "-o", "json") `
            -ErrorContext "The scale subresource of Deployment '$Service' could not be read"
    $scaleObservedAt = (Get-Date).ToUniversalTime()

    $pods = Invoke-KubectlJsonChecked `
            -KubectlArgs @("get", "pods", "--namespace", $Namespace, "--selector", $podSelector, "-o", "json") `
            -ErrorContext "Could not list pods for '$Service'"

    $cpuMetricPodCount = Get-CpuMetricPodCount

    # Left null when the HPA has no reading yet or reports <unknown>. See
    # New-AutoscalingSample for why this must not become 0.
    $utilization = $null
    foreach ($metric in @($hpa.status.currentMetrics)) {
        if ($null -ne $metric -and $metric.type -eq "Resource" -and $metric.resource.name -eq "cpu") {
            $value = $metric.resource.current.averageUtilization
            if ($null -ne $value) {
                $utilization = [int] $value
            }
        }
    }

    # A Deployment reports no readyReplicas field at all when the count is zero,
    # so the coalesce below is a real case, not defensive noise.
    $ready = 0
    if ($null -ne $deployment.status.readyReplicas) {
        $ready = [int] $deployment.status.readyReplicas
    }

    $replicas = 0
    if ($null -ne $deployment.status.replicas) {
        $replicas = [int] $deployment.status.replicas
    }

    $restartCounts = @{}
    foreach ($pod in @($pods.items)) {
        foreach ($container in @($pod.status.containerStatuses)) {
            if ($null -ne $container) {
                $restartCounts["$($pod.metadata.uid)/$($container.name)"] = [int] $container.restartCount
            }
        }
    }

    # Recorded verbatim, and left null only when the HPA carries no ScalingActive
    # condition at all. This is a HEALTH signal - the autoscaler stating it can
    # compute a desired replica count from its metrics - and deliberately not an
    # attribution signal: a manual `kubectl scale` next to a healthy HPA leaves
    # it True. Attribution comes from the rescale evidence below.
    $scalingActive = $null
    $ableToScaleReason = $null
    foreach ($condition in @($hpa.status.conditions)) {
        if ($null -eq $condition) {
            continue
        }
        if ($condition.type -eq "ScalingActive") {
            $scalingActive = [string] $condition.status
        }
        # The AbleToScale reason reads "SucceededRescale" right after the
        # controller changes the target's scale. Recorded as supporting
        # evidence only: the next reconcile overwrites it, so its absence
        # proves nothing and attribution never requires it.
        if ($condition.type -eq "AbleToScale") {
            $ableToScaleReason = [string] $condition.reason
        }
    }

    # HPA status retained for diagnostics and controller-health reporting only.
    # Attribution comes exclusively from the run-local, target-specific
    # SuccessfulRescale occurrences collected at the start of this sample.
    $hpaDesired = $null
    if ($null -ne $hpa.status.desiredReplicas) {
        $hpaDesired = [int] $hpa.status.desiredReplicas
    }
    $hpaCurrent = $null
    if ($null -ne $hpa.status.currentReplicas) {
        $hpaCurrent = [int] $hpa.status.currentReplicas
    }
    # ConvertFrom-Json has usually already turned lastScaleTime into a
    # [datetime] carrying its own Kind, and stringifying that value drops the
    # timezone - a round-trip through [string] shifted the recorded rescale
    # times by the host's UTC offset. Use the value as-is when it is already a
    # datetime (New-AutoscalingSample normalizes the Kind), and parse a string
    # as UTC, which is the only timezone Kubernetes serializes.
    $hpaLastScaleTime = $null
    $rawLastScaleTime = $hpa.status.lastScaleTime
    if ($rawLastScaleTime -is [datetime]) {
        $hpaLastScaleTime = $rawLastScaleTime
    } elseif (-not [string]::IsNullOrWhiteSpace([string] $rawLastScaleTime)) {
        $hpaLastScaleTime = [datetime]::Parse(
            [string] $rawLastScaleTime,
            [System.Globalization.CultureInfo]::InvariantCulture,
            ([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal))
    }

    # Not optional, and not silently null: this field is what timestamps every
    # scale decision in the run. Without it the analysis falls back to
    # Deployment status.replicas, which moves when the rollout catches up rather
    # than when the HPA decided, and the verdict rejects the run anyway. Failing
    # here says why - an old kubectl without --subresource=scale support, or a
    # scale object the API served without spec.replicas - instead of failing
    # much later on evidence that never existed.
    if ($null -eq $scale.spec.replicas) {
        throw "The scale subresource of Deployment '$Service' carried no spec.replicas. That field is where the HPA writes its scaling decision and is what timestamps every scale event in this run; kubectl v1.27+ is required for 'kubectl get deployment --subresource=scale'."
    }
    $scaleDesired = [int] $scale.spec.replicas

    # Every metric the HPA is configured with beyond CPU, read at the same
    # instant. The scale-down verdict recomputes the HPA's desired replica count,
    # which is the maximum across all of its metrics: a second metric still
    # asking for the current count is what makes a low CPU reading not a scale-in
    # recommendation.
    $additionalMetrics = Get-HpaMetricReadings `
        -SpecMetrics @($hpa.spec.metrics) `
        -CurrentMetrics @($hpa.status.currentMetrics)

    # Keep both edges of the asynchronous bundle. Its completion remains the
    # sample timestamp and the conservative recommendation anchor; its start is
    # the conservative endpoint when proving how long the recommendation held.
    $timestamp = (Get-Date).ToUniversalTime()

    return New-AutoscalingSample `
        -Timestamp $timestamp `
        -RecommendationEvidenceStartedAt $recommendationEvidenceStartedAt `
        -Replicas $replicas `
        -ReadyReplicas $ready `
        -TargetPercent $TargetPercent `
        -UtilizationPercent $utilization `
        -RestartCounts $restartCounts `
        -ScalingActiveStatus $scalingActive `
        -AdditionalMetrics $additionalMetrics `
        -CpuMetricPodCount $cpuMetricPodCount `
        -ScaleDesiredReplicas $scaleDesired `
        -ScaleObservedAt $scaleObservedAt `
        -HpaDesiredReplicas $hpaDesired `
        -HpaCurrentReplicas $hpaCurrent `
        -HpaLastScaleTime $hpaLastScaleTime `
        -HpaAbleToScaleReason $ableToScaleReason `
        -HpaUid $script:hpaUid `
        -HpaGeneration $script:hpaGeneration `
        -HpaSuccessfulRescaleEvents $successfulRescaleEvents `
        -HpaEventCollectionSucceeded $true
}

function Write-SampleLine {
    param([Parameter(Mandatory)] $Sample)

    $utilization = "<unknown>"
    if ($null -ne $Sample.UtilizationPercent) {
        $utilization = "$($Sample.UtilizationPercent)%"
    }

    $scalingActive = "<none>"
    if (-not [string]::IsNullOrWhiteSpace($Sample.ScalingActiveStatus)) {
        $scalingActive = $Sample.ScalingActiveStatus
    }

    $scaleDesired = "-"
    if ($null -ne $Sample.ScaleDesiredReplicas) {
        $scaleDesired = "$($Sample.ScaleDesiredReplicas)"
    }
    $hpaDesired = "-"
    if ($null -ne $Sample.HpaDesiredReplicas) {
        $hpaDesired = "$($Sample.HpaDesiredReplicas)"
    }

    Write-Host ("  {0} cpu: {1,9}/{2}%  desired={3} hpaDesired={4} replicas={5} ready={6} scalingActive={7}" -f `
            $Sample.Timestamp.ToString("HH:mm:ssZ"), $utilization, $Sample.TargetPercent, $scaleDesired, $hpaDesired, $Sample.Replicas, $Sample.ReadyReplicas, $scalingActive)
}

Write-Host "Validating autoscaling behavior for '$Service' in namespace '$Namespace' (run $runId)..."

# --- 0. Preflight ------------------------------------------------------------
# Each of these fails the run with a specific cause instead of letting the
# timeline come back empty and get read as "the autoscaler did nothing".
Invoke-KubectlChecked `
    -KubectlArgs @("cluster-info") `
    -ErrorContext "kubectl cannot reach a Kubernetes cluster" | Out-Null

$kubernetesVersion = Invoke-KubectlJsonChecked `
    -KubectlArgs @("version", "-o", "json") `
    -ErrorContext "Could not record Kubernetes client/server versions for the runtime evidence"
$kubernetesClientVersion = [string] $kubernetesVersion.clientVersion.gitVersion
$kubernetesServerVersion = [string] $kubernetesVersion.serverVersion.gitVersion

$metricsApi = Invoke-Kubectl -KubectlArgs @(
    "get", "apiservice", "v1beta1.metrics.k8s.io",
    "-o", "jsonpath={.status.conditions[?(@.type=='Available')].status}"
)
Confirm-Condition `
    -Condition ($metricsApi.ExitCode -eq 0 -and $metricsApi.Output.Trim() -eq "True") `
    -SuccessMessage "the metrics.k8s.io APIService is Available, so the HPA has a CPU metric to read" `
    -FailureMessage "the metrics.k8s.io APIService is not Available (kubectl said: $($metricsApi.Output.Trim())). Without metrics-server every HPA reports <unknown> and never scales; on kind or Docker Desktop it also needs --kubelet-insecure-tls" `
    -Permanent

$hpaJson = Invoke-KubectlJsonChecked `
        -KubectlArgs @("get", "hpa", $Service, "--namespace", $Namespace, "-o", "json") `
        -ErrorContext "HorizontalPodAutoscaler '$Service' was not found in namespace '$Namespace'. Apply infrastructure/kubernetes/$Service/"

$script:hpaUid = [string] $hpaJson.metadata.uid
if ([string]::IsNullOrWhiteSpace($script:hpaUid)) {
    throw "HorizontalPodAutoscaler '$Service' carried no metadata.uid. Events cannot be tied to the exact HPA incarnation, so attribution must fail closed."
}
$script:hpaGeneration = $null
if ($null -ne $hpaJson.metadata.generation) {
    $script:hpaGeneration = [long] $hpaJson.metadata.generation
}
$script:hpaSpecJson = $hpaJson.spec | ConvertTo-Json -Depth 100 -Compress
$hpaGenerationDisplay = if ($null -eq $script:hpaGeneration) { "<not reported by API>" } else { [string] $script:hpaGeneration }

# Establish occurrence-count baselines before any behavioral sample. Existing
# same-size SuccessfulRescale events are historical and will never be returned
# as run-local evidence unless their count advances after this snapshot.
$eventBaselineAt = (Get-Date).ToUniversalTime()
Get-SuccessfulRescaleEvidenceSnapshot -ObservedAt $eventBaselineAt -EstablishBaseline | Out-Null

$minReplicas = [int] $hpaJson.spec.minReplicas
$maxReplicas = [int] $hpaJson.spec.maxReplicas

$cpuMetric = @($hpaJson.spec.metrics | Where-Object { $_.type -eq "Resource" -and $_.resource.name -eq "cpu" })[0]
Confirm-Condition `
    -Condition ($null -ne $cpuMetric -and $null -ne $cpuMetric.resource.target.averageUtilization) `
    -SuccessMessage "the applied HPA scales '$Service' on CPU utilization within [$minReplicas, $maxReplicas]" `
    -FailureMessage "the applied HPA for '$Service' has no Resource/cpu Utilization metric. Run $structuralValidator first: this script assumes the structural checks already pass" `
    -Permanent

$targetPercent = [int] $cpuMetric.resource.target.averageUtilization

# The window this run is about to measure is read from the cluster rather than
# hardcoded, so the assertion tracks the manifest instead of drifting from it.
$scaleDownWindow = 300
if ($null -ne $hpaJson.spec.behavior.scaleDown.stabilizationWindowSeconds) {
    $scaleDownWindow = [int] $hpaJson.spec.behavior.scaleDown.stabilizationWindowSeconds
}

$scaleUpPolicyPeriods = @($hpaJson.spec.behavior.scaleUp.policies | ForEach-Object { [int] $_.periodSeconds })
$scaleDownPolicyPeriods = @($hpaJson.spec.behavior.scaleDown.policies | ForEach-Object { [int] $_.periodSeconds })
$timingRequirements = Get-AutoscalingTimingRequirements `
    -SampleIntervalSeconds $SampleIntervalSeconds `
    -MinReplicas $minReplicas `
    -MaxReplicas $maxReplicas `
    -ScaleDownWindowSeconds $scaleDownWindow `
    -ScaleUpPolicyPeriodsSeconds $scaleUpPolicyPeriods `
    -ScaleDownPolicyPeriodsSeconds $scaleDownPolicyPeriods

if ($LoadDurationSeconds -lt $timingRequirements.MinimumLoadDurationSeconds) {
    throw "LoadDurationSeconds ($LoadDurationSeconds) is too short for this HPA. It must be at least $($timingRequirements.MinimumLoadDurationSeconds)s to cover the slowest $($timingRequirements.ScaleUpPolicyPeriodSeconds)s scale-up policy interval and two ${SampleIntervalSeconds}s observations."
}

$scaleDownGraceSeconds = [math]::Max(30, $SampleIntervalSeconds * 2)
$scaleDownGraceCeilingSeconds = [int] [math]::Floor($scaleDownWindow / 2)
if ($scaleDownGraceSeconds -gt $scaleDownGraceCeilingSeconds) {
    throw "SampleIntervalSeconds ($SampleIntervalSeconds) produces ${scaleDownGraceSeconds}s of sampling grace, more than half of the configured ${scaleDownWindow}s stabilization window (${scaleDownGraceCeilingSeconds}s). A verdict that forgives that much of the window cannot say whether it held. Reduce SampleIntervalSeconds or increase the HPA window."
}
if ($IncludeScaleDown -and $ScaleDownTimeoutSeconds -lt $timingRequirements.MinimumScaleDownTimeoutSeconds) {
    throw "ScaleDownTimeoutSeconds ($ScaleDownTimeoutSeconds) is too short for this HPA. It must be at least $($timingRequirements.MinimumScaleDownTimeoutSeconds)s to cover the ${scaleDownWindow}s stabilization window, every possible $($timingRequirements.ScaleDownPolicyPeriodSeconds)s scale-down step, and a final sample at the floor."
}

$samples = @()
$markers = @{}
$runFailure = $null
$cleanupConfirmed = $false

try {
    # --- 1. Baseline ---------------------------------------------------------
    # One sample before any load, so the timeline contains the "before" the
    # scale-up is measured against and the restart baseline is taken from a pod
    # set that has not been touched yet.
    Write-Host "Baseline (no load):"
    $baseline = Get-Sample -TargetPercent $targetPercent
    Write-SampleLine -Sample $baseline
    $samples += $baseline

    Confirm-Condition `
        -Condition ($baseline.ReadyReplicas -ge $minReplicas) `
        -SuccessMessage "the workload starts from a healthy floor of $($baseline.ReadyReplicas) Ready replicas" `
        -FailureMessage "only $($baseline.ReadyReplicas) replicas are Ready before any load is applied, below the minReplicas floor of $minReplicas. Fix the deployment before measuring how it scales" `
        -Permanent

    Confirm-Condition `
        -Condition ($baseline.ScaleDesiredReplicas -eq $minReplicas) `
        -SuccessMessage "the no-load baseline scale target is the minReplicas floor of $minReplicas" `
        -FailureMessage "the no-load baseline scale target is $($baseline.ScaleDesiredReplicas), not the minReplicas floor of $minReplicas. Residual or externally written scale state cannot establish a clean HPA scale-up baseline" `
        -Permanent

    # --- 2. Load -------------------------------------------------------------
    if ($Service -eq "ingestion-service") {
        $loadImage = $HttpLoadImage
        # curlimages/curl is Alpine and ships no bash.
        $loadShell = "sh"
        $loadTemplate = $httpLoadTemplate
        $loadValues = @{
            CONCURRENCY = $LoadConcurrency
            TARGET      = $Service
            PORT        = 8081
            RUN         = $runId
        }
    } else {
        $loadImage = $KafkaLoadImage
        $loadShell = "bash"
        # One producer per pod rather than $LoadConcurrency of them: a single
        # kafka-console-producer already saturates a 3-partition topic, and
        # parallel producers inside one pod would compete for its CPU instead of
        # the consumer's.
        $loadTemplate = $kafkaLoadTemplate
        $loadValues = @{
            RUN       = $runId
            BIN       = "/opt/kafka/bin"
            BOOTSTRAP = "$KafkaClusterName-kafka-bootstrap:$BootstrapPort"
            TOPIC     = $RawTopic
            RATE      = $KafkaEventsPerSecond
            BURST_RATE = $KafkaBurstEventsPerSecond
            BURST_EVENTS = [long] $KafkaBurstEventsPerSecond * $KafkaBurstDurationSeconds
            # Odd on purpose. The value alternates on the parity of `i` and the
            # device is `i % DEVICES`, so an even count would give every device
            # the same parity forever and every reading for it the same value -
            # no deviation, no spike, and the expensive path never taken.
            DEVICES   = 63
        }
    }

    Write-Host "Starting $effectiveLoadPodCount load pod(s) against '$Service'..."
    $loadPodNames = @()
    $heartbeats = @{}
    for ($i = 1; $i -le $effectiveLoadPodCount; $i++) {
        $loadPodName = "autoscaling-load-$runId-$i"
        # Rendered per pod: POD is what keeps the generated eventId values
        # distinct across the pods of one run.
        $loadValues["POD"] = $i
        $loadCommand = New-AutoscalingShellCommand -Template $loadTemplate -Values $loadValues
        Start-AutoscalingLoadPod `
            -Namespace $Namespace `
            -RunId $runId `
            -LoadPodLabel $loadPodLabel `
            -PodName $loadPodName `
            -Image $loadImage `
            -Command $loadCommand `
            -Shell $loadShell
        Confirm-AutoscalingLoadPodRunning -Namespace $Namespace -PodName $loadPodName
        $loadPodNames += $loadPodName
    }
    Start-Sleep -Seconds ([math]::Min(15, $SampleIntervalSeconds))
    foreach ($loadPodName in $loadPodNames) {
        $firstCount = Confirm-AutoscalingLoadPodTraffic -Namespace $Namespace -PodName $loadPodName
        $heartbeats[$loadPodName] = New-AutoscalingHeartbeatState -InitialCount $firstCount
    }

    # A pod that has not moved its counter for this long has stopped generating
    # traffic. Two sampling intervals, floored at 60s: the HTTP generator prints
    # every 5s and the Kafka one every 100 messages, so a working pod advances
    # many times over within the budget, while a hung one is caught within one
    # or two samples rather than at the end of the phase.
    $heartbeatStallSeconds = [math]::Max(60, $SampleIntervalSeconds * 2)
    $markers[$baseline.Timestamp] = "<- baseline, before load"

    # --- 3. Sample under load ------------------------------------------------
    Write-Host "Sampling for ${LoadDurationSeconds}s under load:"
    $loadDeadline = (Get-Date).AddSeconds($LoadDurationSeconds)
    while ((Get-Date) -lt $loadDeadline) {
        Start-Sleep -Seconds $SampleIntervalSeconds
        $sample = Get-Sample -TargetPercent $targetPercent
        Write-SampleLine -Sample $sample
        $samples += $sample

        # Checked alongside every sample, not once before the phase: the whole
        # timeline below is only meaningful if the load was still running while
        # it was collected.
        foreach ($loadPodName in $loadPodNames) {
            Assert-AutoscalingLoadPodHeartbeatAdvancing `
                -Namespace $Namespace `
                -PodName $loadPodName `
                -State $heartbeats `
                -StallSeconds $heartbeatStallSeconds
        }
    }

    # The per-sample check tolerates a stall shorter than its budget, so the
    # phase also has to end with every pod ahead of where it started. A pod that
    # heartbeat once and hung immediately would otherwise pass a short phase.
    foreach ($loadPodName in $loadPodNames) {
        $entry = $heartbeats[$loadPodName]
        Confirm-Condition `
            -Condition ($entry.Last -gt $entry.First) `
            -SuccessMessage "load pod '$loadPodName' advanced its traffic counter from $($entry.First) to $($entry.Last) across the load phase" `
            -FailureMessage "load pod '$loadPodName' finished the load phase still at traffic counter $($entry.Last), where it started. It generated no traffic while the samples above were collected" `
            -Permanent
    }

    # --- 4. Remove load ------------------------------------------------------
    Write-Host "Removing load pods..."
    $loadStopped = (Get-Date).ToUniversalTime()
    Stop-AutoscalingLoadPods -Namespace $Namespace -RunId $runId -LoadPodLabel $loadPodLabel
    $cleanupConfirmed = $true

    if ($IncludeScaleDown) {
        # Sampling continues until the workload is back at the floor or the
        # timeout expires. The timeout is not a failure on its own: the
        # assertions below judge the timeline, so a run that ran out of time
        # fails with "no scale-down was observed" rather than with a bare
        # timeout message that says nothing about the autoscaler.
        Write-Host "Waiting for the ${scaleDownWindow}s stabilization window and the return to minReplicas..."
        $scaleDownDeadline = (Get-Date).AddSeconds($ScaleDownTimeoutSeconds)
        $floorObservedOnce = $false
        $firstPostLoadSample = $true
        while ((Get-Date) -lt $scaleDownDeadline) {
            if ($firstPostLoadSample) {
                # Cleanup is verified before this point and uses a one-second
                # termination grace. Sample immediately so the beginning of a
                # scale-in recommendation is observed rather than hidden inside
                # an artificial cleanup-plus-sleep gap.
                $firstPostLoadSample = $false
            } else {
                Start-Sleep -Seconds $SampleIntervalSeconds
            }
            $sample = Get-Sample -TargetPercent $targetPercent
            Write-SampleLine -Sample $sample
            $samples += $sample

            if ($sample.ScaleDesiredReplicas -eq $minReplicas -and
                $sample.Replicas -eq $minReplicas -and
                $sample.ReadyReplicas -eq $minReplicas) {
                if ($floorObservedOnce) {
                    break
                }
                # The event read comes first in a sample. If the final rescale
                # raced that read, its target-specific event can only appear in
                # the next sample. Require one unchanged floor confirmation so
                # legitimate one-sample-late evidence is collectable without
                # enlarging any timing grace.
                $floorObservedOnce = $true
            } else {
                $floorObservedOnce = $false
            }
        }
    } else {
        # One sample after the load stops even without the scale-down phase, so
        # the recorded timeline ends on a known state rather than mid-load.
        Start-Sleep -Seconds $SampleIntervalSeconds
        $sample = Get-Sample -TargetPercent $targetPercent
        Write-SampleLine -Sample $sample
        $samples += $sample
    }

    # Attached after the fact so the marker lands on the first sample at or
    # after the load stopped, whichever that turned out to be.
    $firstAfterLoad = @($samples | Where-Object { $_.Timestamp -ge $loadStopped } | Sort-Object Timestamp)[0]
    if ($null -ne $firstAfterLoad) {
        $markers[$firstAfterLoad.Timestamp] = "<- load removed"
    }
} catch {
    $runFailure = $_
} finally {
    # Runs on Ctrl-C and on any assertion failure above. Load pods left running
    # would keep the cluster under load indefinitely and poison the next run.
    if (-not $cleanupConfirmed) {
        try {
            Stop-AutoscalingLoadPods -Namespace $Namespace -RunId $runId -LoadPodLabel $loadPodLabel
        } catch {
            if ($null -ne $runFailure) {
                throw "$($runFailure.Exception.Message) Cleanup also failed: $($_.Exception.Message)"
            }
            throw
        }
    }
}

if ($null -ne $runFailure) {
    throw $runFailure
}

# --- 5. Verdict --------------------------------------------------------------
Write-Host ""
Write-Host "Timeline ($($samples.Count) samples):"
# The widest spacing between two consecutive samples that the stabilization
# stretch may contain and still count as continuously observed, derived from the
# REQUESTED interval exactly like the sampling grace: a run that stalls proves
# less, and what it actually did must never widen its own allowance. A stretch
# containing a wider hole is trimmed to the observed part, because the
# recommendation could have been interrupted in the hole and the controller's
# window restarted without this run seeing it.
$maxObservationGapSeconds = [math]::Max(60, $SampleIntervalSeconds * 2)
$timeline = Get-AutoscalingTimeline `
    -Samples $samples `
    -MinReplicas $minReplicas `
    -MaxReplicas $maxReplicas `
    -Tolerance $HpaTolerance `
    -MaxObservationGapSeconds $maxObservationGapSeconds
$rendered = Format-AutoscalingTimeline -Timeline $timeline -Markers $markers
Write-Host $rendered
Write-Host ""

# The grace is the fixed quantization allowance of the REQUESTED sampling
# interval, and nothing the run actually did widens it: the verdict judges the
# conservative proven bound (anchor sample to the last sample still at the old
# desired count), so a sampling gap around either transition shrinks what the
# evidence proves and fails the assertion instead of being forgiven. See
# Get-ScaleDownSamplingGrace, which owns this rule so that
# test-autoscaling-behavior-analysis.ps1 can hold it to it offline.
#
# The widest conservative evidence gap and widest in-sample collection interval
# are still reported, but never widen the verdict's grace.
$observedGapSeconds = $timeline.WidestRecommendationEvidenceGapSeconds

$graceDecision = Get-ScaleDownSamplingGrace `
    -Timeline $timeline `
    -RequestedGraceSeconds $scaleDownGraceSeconds `
    -ExpectedScaleDownWindowSeconds $scaleDownWindow
$effectiveGraceSeconds = $graceDecision.GraceSeconds

Confirm-AutoscalingBehavior `
    -Timeline $timeline `
    -ExpectedScaleDownWindowSeconds $scaleDownWindow `
    -ScaleDownGraceSeconds $effectiveGraceSeconds `
    -RequireReturnToFloor:$IncludeScaleDown

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    # Recorded by the script rather than typed into the report by hand: a run is
    # only evidence for the commit it actually ran from, and a dirty tree means
    # the recorded commit is not what was tested.
    $revision = "unknown (not a git working tree)"
    try {
        $head = (& git -C $PSScriptRoot rev-parse HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($head)) {
            $revision = ([string] $head).Trim()
            $gitStatus = @(& git -C $PSScriptRoot status --porcelain=v1 --untracked-files=all 2>$null)
            if ($LASTEXITCODE -ne 0 -or $gitStatus.Count -gt 0) {
                $revision = "$revision (working tree dirty at run time)"
            }
        }
    } catch {
        $revision = "unknown (git unavailable: $($_.Exception.Message))"
    }

    # Named from the last sample so the report states what the verdict actually
    # judged: every metric the HPA weighed, not just the CPU one in the timeline.
    $metricSummary = (@($samples[-1].Metrics | ForEach-Object { "``$($_.Name)`` at $($_.TargetValue)" }) -join ", ")
    $heartbeatSummary = @($heartbeats.Keys | Sort-Object | ForEach-Object {
            $entry = $heartbeats[$_]
            "``$_`` advanced from ``$($entry.First)`` to ``$($entry.Last)``"
        }) -join "; "

    # The scale-down assertion is anchored to the HPA's own recommendation and
    # judged on the conservative proven bound, so the report carries both ends
    # of the interval the samples establish rather than one optimistic number.
    # A stretch that had to be trimmed past an unobserved interval is disclosed
    # in the report as well as in the verdict: the anchor the reader sees is
    # then not the first sample that recommended the scale-in, and the reason
    # belongs next to it.
    $trimNote = ""
    if ($null -ne $timeline.ProvenStretchGapSeconds) {
        $trimNote = " The stretch starts there rather than at the first recommending sample ($($timeline.DownscaleRecommendationObservedFrom.ToString('HH:mm:ssZ'))): the widest possible spacing between two consecutive recommendation-evidence intervals was ``$($timeline.ProvenStretchGapSeconds)s``, wider than the ``$($timeline.MaxObservationGapSeconds)s`` this harness treats as continuous observation."
    }
    if ($null -ne $timeline.ProvenScaleDownDelaySeconds) {
        $scaleDownAnchorRow = "| Scale-down window | proven recommendation duration ``>= $($timeline.ProvenScaleDownDelaySeconds)s``: from completion of the anchor evidence bundle at $($timeline.DownscaleRecommendedAt.ToString('HH:mm:ssZ')) ($($timeline.DownscaleRecommendationDetail)) through the start of the last recommending bundle at $($timeline.ProvenRecommendationThrough.ToString('HH:mm:ssZ')); its old desired count was observed at $($timeline.FirstScaleDownPreviousSampleAt.ToString('HH:mm:ssZ')), and the decision at $($timeline.FirstScaleDownAt.ToString('HH:mm:ssZ')) (anchor-to-observation spacing ``$($timeline.ObservedScaleDownDelaySeconds)s``, recommendation turnover uncertain by the ``$($graceDecision.AnchorGapSeconds)s`` conservative evidence gap ending at the anchor).$trimNote |"
    } else {
        $scaleDownAnchorRow = "| Scale-down window | not measured: this run recorded no scale-in preceded by a scale-in recommendation |"
    }

    # Per-event attribution evidence, so a reviewer can see WHY each transition
    # is credited to the HPA instead of taking the verdict's word for it.
    $scaleEventLines = @($timeline.ScaleEvents | ForEach-Object {
            $evidence = "none: not attributed to the HPA"
            if ($_.HpaAttributed) {
                $evidence = $_.HpaEvidence
            }
            "| {0} | {1} | {2} -> {3} | {4} | {5} |" -f $_.At.ToString("HH:mm:ssZ"), $_.Direction, $_.From, $_.To, $_.DecisionSource, $evidence
        })

    $report = @(
        "# $Service autoscaling behavior (#153)",
        "",
        "Recorded by ``scripts/validate-autoscaling-behavior.ps1`` (run ``$runId``).",
        "",
        "| Item | Value |",
        "| --- | --- |",
        "| Workload | ``$Service`` in namespace ``$Namespace`` |",
        "| Tested revision | ``$revision`` |",
        "| Kubernetes versions | client ``$kubernetesClientVersion``; server ``$kubernetesServerVersion`` |",
        "| HPA identity | ``$Service`` UID ``$script:hpaUid``, generation ``$hpaGenerationDisplay``; UID, generation, and spec remained fixed throughout the run |",
        "| SuccessfulRescale baseline | Established at $($eventBaselineAt.ToString('yyyy-MM-ddTHH:mm:ssZ')); pre-existing event UIDs/counts were excluded, and collection succeeded in all $($timeline.SampleCount) samples |",
        "| HPA bounds | ``[$minReplicas, $maxReplicas]`` at a $targetPercent% CPU target |",
        "| Scale-down window | ``${scaleDownWindow}s`` (read from the applied HPA) |",
        "| Sampling | requested every ``${SampleIntervalSeconds}s``; recommendation evidence collected over intervals shown below (widest ``$($timeline.WidestRecommendationEvidenceCollectionSeconds)s``); widest conservative evidence gap ``$([int] $observedGapSeconds)s``, gap before the scale-in recommendation ``$($graceDecision.AnchorGapSeconds)s``; window judged with ``${effectiveGraceSeconds}s`` of fixed grace (ceiling ``$($graceDecision.CeilingSeconds)s``; observed gaps shrink the proven bound instead of widening the grace; evidence intervals separated by more than ``${maxObservationGapSeconds}s`` stop counting as continuous observation) |",
        "| Load | $effectiveLoadPodCount pod(s), $(if ($Service -eq 'ingestion-service') { "$LoadConcurrency concurrent POST /api/v1/events loops each" } else { "one kafka-console-producer each into $RawTopic, $KafkaBurstEventsPerSecond events/s for ${KafkaBurstDurationSeconds}s then $KafkaEventsPerSecond events/s per pod" }) |",
        "| Load heartbeat | $heartbeatSummary |",
        "| HPA ScalingActive | ``True`` in all $($timeline.ScalingActiveTrueSamples) samples after the first (health signal only; attribution is per scale event below) |",
        "| HPA rescale attribution | $($timeline.ScaleEvents.Count - $timeline.UnattributedScaleEvents.Count) of $($timeline.ScaleEvents.Count) replica transitions mapped one-to-one to post-baseline SuccessfulRescale occurrences from the exact HPA UID with an exact matching ``New size``; $($timeline.UnmatchedSuccessfulRescaleEvents.Count) unmatched occurrence(s) |",
        "| HPA metrics | $($metricSummary) (desired replicas = max across metrics, tolerance ``$HpaTolerance``) |",
        $scaleDownAnchorRow,
        "| Peak utilization | $($timeline.PeakUtilizationPercent)% |",
        "| Peak replicas | $($timeline.PeakReplicas), all Ready at the peak (highest Ready count observed: $($timeline.PeakReadyReplicas)) |",
        "| Container restarts | $($timeline.RestartDelta) |",
        "| Load-pod cleanup | Confirmed: no run-labelled pods remain |",
        "",
        "## Timeline",
        "",
        '```text',
        "completed | evidence started | cpu: current/target  min  max  replicas | scale-subresource desired  HPA desired  HPA lastScaleTime  ready  hpa ScalingActive  newly observed SuccessfulRescale events",
        $rendered,
        '```',
        "",
        "## Scale events",
        "",
        "``desired`` in the timeline is the scale subresource's requested count, which is where the HPA writes its decision; ``replicas``/``ready`` are what the workload realized, and can lag it. Each transition is credited only when one run-local SuccessfulRescale occurrence from HPA UID ``$script:hpaUid`` names its exact target count. HPA status fields remain diagnostics, not causation evidence.",
        ""
    )

    if ($scaleEventLines.Count -gt 0) {
        $report += @("| Decision observed | Direction | Desired replicas | Decision source | HPA rescale evidence |", "| --- | --- | --- | --- | --- |") + $scaleEventLines
    } else {
        $report += "No scale event was recorded in this run."
    }

    $report += @("", "Structural assertions stay the responsibility of ``$structuralValidator``.")

    $reportDirectory = Split-Path -Parent $ReportPath
    if (-not [string]::IsNullOrWhiteSpace($reportDirectory) -and -not (Test-Path $reportDirectory)) {
        New-Item -ItemType Directory -Path $reportDirectory | Out-Null
    }

    Set-Content -Path $ReportPath -Value ($report -join [Environment]::NewLine) -Encoding UTF8
    Write-Host "[ok] Wrote the run report to '$ReportPath'."
}

Write-Host "[ok] Autoscaling behavior validation completed for '$Service' in namespace '$Namespace'."
