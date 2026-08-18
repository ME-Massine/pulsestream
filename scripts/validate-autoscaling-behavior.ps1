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
    # Concurrent load pods, and parallel request loops inside each one. The
    # defaults push a 250m-request pod well past its 70% target on a laptop-class
    # node; raise them if the peak utilization reported at the end never crosses
    # the target.
    [ValidateRange(1, 2147483647)] [int] $LoadPodCount = 3,
    [ValidateRange(1, 2147483647)] [int] $LoadConcurrency = 16,
    # How long to keep the load running. The scale-up policies allow one step per
    # 60s, so this needs to span several steps to show more than a single jump.
    [ValidateRange(1, 2147483647)] [int] $LoadDurationSeconds = 240,
    [ValidateRange(1, 2147483647)] [int] $SampleIntervalSeconds = 15,
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

$runId = [guid]::NewGuid().ToString("N").Substring(0, 6)
$loadPodLabel = "pulsestream.io/autoscaling-load=$runId"
$podSelector = "app.kubernetes.io/name=$Service"

# Same {{PLACEHOLDER}} idiom as validate-kafka-broker-health.ps1: a shell snippet
# written as an interpolated PowerShell string needs every `$` escaped, and one
# missed backtick silently produces an empty variable inside the pod.
function New-ShellCommand {
    param(
        [Parameter(Mandatory)] [string] $Template,
        [Parameter(Mandatory)] [hashtable] $Values
    )

    $command = $Template
    foreach ($key in $Values.Keys) {
        $command = $command.Replace("{{$key}}", [string] $Values[$key])
    }

    # These here-strings live in a *.ps1, which .gitattributes checks out with
    # CRLF on Windows. sh keeps the CR as part of the last token on each line and
    # fails with "syntax error near unexpected token $'do\r'".
    return $command -replace "`r`n", "`n" -replace "`r", "`n"
}

# --- Load generators ---------------------------------------------------------
# Both templates loop forever. The pod is deleted to stop the load, which is why
# neither needs a duration of its own - a load generator that stopped on its own
# schedule would drift out of step with the sampler and make the timeline lie
# about when the load ended.

$httpLoadTemplate = @'
set -u
n=0
while [ $n -lt {{CONCURRENCY}} ]; do
  n=$((n+1))
  (
    i=0
    successes=0
    while true; do
      i=$((i+1))
      if curl -fsS -o /dev/null -m 5 -X POST "http://{{TARGET}}:{{PORT}}/api/v1/events" \
        -H 'Content-Type: application/json' \
        -d "{\"eventId\":\"evt_{{RUN}}_${n}_${i}\",\"tenantId\":\"autoscaling_validation\",\"eventType\":\"telemetry.reading\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"source\":\"validate-autoscaling-behavior\",\"version\":\"1.0\",\"payload\":{\"deviceId\":\"load-{{RUN}}-${n}\",\"deviceType\":\"temperature-sensor\",\"metric\":\"temperature\",\"value\":21.5,\"unit\":\"celsius\",\"location\":\"validation-lab\"}}" 2>/dev/null; then
        successes=$((successes+1))
        if [ "$successes" -eq 1 ]; then echo "pulsestream-autoscaling-load ready http" >&2; fi
        if [ $((successes % 5)) -eq 0 ]; then echo "pulsestream-autoscaling-load heartbeat http $successes" >&2; fi
      else
        sleep 1
      fi
    done
  ) &
done
wait
'@

# Values alternate between 20.5 and 95.5 so each consecutive pair for a device
# crosses both the temperature threshold and the spike ratio in
# TelemetryAnomalyDetectionService. That keeps every event on the expensive path
# - anomaly detection, the Postgres insert, and the republish - rather than on
# the cheap one, which is what makes CPU move.
$kafkaLoadTemplate = @'
set -euo pipefail
# A successful one-message producer run proves the image, shell, base64-decoded
# command, bootstrap route, and producer before the continuous load begins.
printf '{"eventId":"probe-{{RUN}}","tenantId":"autoscaling_validation","eventType":"telemetry.reading","timestamp":"2026-01-01T00:00:00Z","source":"validate-autoscaling-behavior","version":"1.0","payload":{"deviceId":"probe-{{RUN}}","deviceType":"temperature-sensor","metric":"temperature","value":20.5,"unit":"celsius","location":"validation-lab"}}\n' | {{BIN}}/kafka-console-producer.sh \
  --bootstrap-server {{BOOTSTRAP}} --topic {{TOPIC}} \
  --producer-property acks=all --producer-property linger.ms=5
echo "pulsestream-autoscaling-load ready kafka" >&2
i=0
while true; do
  i=$((i+1))
  if [ $((i % 2)) -eq 0 ]; then v=20.5; else v=95.5; fi
  printf '{"eventId":"evt_{{RUN}}_%s","tenantId":"autoscaling_validation","eventType":"telemetry.reading","timestamp":"2026-01-01T00:00:00Z","source":"validate-autoscaling-behavior","version":"1.0","payload":{"deviceId":"load-{{RUN}}-%s","deviceType":"temperature-sensor","metric":"temperature","value":%s,"unit":"celsius","location":"validation-lab"}}\n' \
    "$i" "$((i % {{DEVICES}}))" "$v"
  if [ $((i % 100)) -eq 0 ]; then echo "pulsestream-autoscaling-load heartbeat kafka $i" >&2; fi
done | {{BIN}}/kafka-console-producer.sh \
  --bootstrap-server {{BOOTSTRAP}} --topic {{TOPIC}} \
  --producer-property acks=all --producer-property linger.ms=5
'@

function Start-LoadPod {
    param(
        [Parameter(Mandatory)] [string] $PodName,
        [Parameter(Mandatory)] [string] $Image,
        [Parameter(Mandatory)] [string] $Command,
        [Parameter(Mandatory)] [string] $Shell
    )

    # Base64 for the same reason Invoke-KafkaClientCommand uses it: Windows
    # PowerShell 5.1 does not escape embedded double quotes when it builds a
    # native command line, so the JSON payload above would reach the pod with
    # broken argument boundaries.
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Command))

    $result = Invoke-Kubectl -KubectlArgs @(
        "run", $PodName,
        "--namespace", $Namespace,
        "--restart=Never",
        "--labels", $loadPodLabel,
        "--image", $Image,
        "--command", "--",
        $Shell, "-c", "echo $encoded | base64 -d | $Shell"
    )

    if ($result.ExitCode -ne 0) {
        throw "Could not start load pod '$PodName'. $($result.Output)"
    }
}

function Stop-LoadPods {
    # --wait=false: the caller is either finished sampling or unwinding an
    # error, and neither should block on pod teardown. The label is unique per
    # run, so this cannot delete another run's generators.
    $delete = Invoke-Kubectl -KubectlArgs @(
        "delete", "pod",
        "--namespace", $Namespace,
        "--selector", $loadPodLabel,
        "--ignore-not-found", "--wait=false"
    )
    if ($delete.ExitCode -ne 0) {
        throw "Could not delete autoscaling load pods for run '$runId'. $($delete.Output)"
    }

    $deadline = (Get-Date).AddSeconds(60)
    do {
        $remaining = (Invoke-KubectlChecked `
                -KubectlArgs @("get", "pods", "--namespace", $Namespace, "--selector", $loadPodLabel, "-o", "json") `
                -ErrorContext "Could not confirm cleanup of autoscaling load pods for run '$runId'") | ConvertFrom-Json
        if (@($remaining.items).Count -eq 0) {
            Write-Host "[ok] All run-labelled load pods were deleted."
            return
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    $names = @($remaining.items | ForEach-Object { $_.metadata.name }) -join ", "
    throw "Load-pod cleanup timed out: run-labelled pod(s) still exist after 60 seconds: $names."
}

function Confirm-LoadPodRunning {
    param([Parameter(Mandatory)] [string] $PodName)

    Invoke-KubectlChecked `
        -KubectlArgs @("wait", "--namespace", $Namespace, "--for=condition=Ready", "pod/$PodName", "--timeout=120s") `
        -ErrorContext "Load pod '$PodName' did not become Ready; check its image, shell, and startup command" | Out-Null

    $pod = (Invoke-KubectlChecked `
            -KubectlArgs @("get", "pod", $PodName, "--namespace", $Namespace, "-o", "json") `
            -ErrorContext "Could not read load pod '$PodName' after it became Ready") | ConvertFrom-Json
    $allRunning = @($pod.status.containerStatuses | Where-Object { $_.state.running }).Count -eq @($pod.status.containerStatuses).Count
    Confirm-Condition `
        -Condition ($pod.status.phase -eq "Running" -and $allRunning) `
        -SuccessMessage "load pod '$PodName' is Running" `
        -FailureMessage "load pod '$PodName' became Ready but is no longer Running; inspect its logs before trusting this run" `
        -Permanent
}

function Confirm-LoadPodTraffic {
    param([Parameter(Mandatory)] [string] $PodName)

    $deadline = (Get-Date).AddSeconds(60)
    $logs = ""
    do {
        $logs = Invoke-KubectlChecked `
            -KubectlArgs @("logs", "--namespace", $Namespace, $PodName, "--tail", "100") `
            -ErrorContext "Could not read load pod '$PodName' logs to verify traffic generation"
        if ($logs -match "pulsestream-autoscaling-load ready" -and $logs -match "pulsestream-autoscaling-load heartbeat") {
            Confirm-LoadPodRunning -PodName $PodName
            Write-Host "[ok] load pod '$PodName' reached its real traffic path and is still generating traffic"
            return
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    Confirm-Condition `
        -Condition $false `
        -SuccessMessage "load pod '$PodName' reached its real traffic path and is still generating traffic" `
        -FailureMessage "load pod '$PodName' has not emitted both ready and heartbeat markers. Its image, shell, base64 decoder, service/Kafka route, or producer may have failed. Last logs: $logs" `
        -Permanent
}

# --- Sampling ----------------------------------------------------------------
# Three reads per sample rather than one: the HPA carries the metric, the
# Deployment carries the authoritative ready count, and the pods carry restart
# counts. They are read back to back and stamped with a single timestamp.
function Get-Sample {
    param([Parameter(Mandatory)] [int] $TargetPercent)

    $timestamp = (Get-Date).ToUniversalTime()

    $hpa = (Invoke-KubectlChecked `
            -KubectlArgs @("get", "hpa", $Service, "--namespace", $Namespace, "-o", "json") `
            -ErrorContext "HorizontalPodAutoscaler '$Service' disappeared mid-run") | ConvertFrom-Json

    $deployment = (Invoke-KubectlChecked `
            -KubectlArgs @("get", "deployment", $Service, "--namespace", $Namespace, "-o", "json") `
            -ErrorContext "Deployment '$Service' disappeared mid-run") | ConvertFrom-Json

    $pods = (Invoke-KubectlChecked `
            -KubectlArgs @("get", "pods", "--namespace", $Namespace, "--selector", $podSelector, "-o", "json") `
            -ErrorContext "Could not list pods for '$Service'") | ConvertFrom-Json

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

    return New-AutoscalingSample `
        -Timestamp $timestamp `
        -Replicas $replicas `
        -ReadyReplicas $ready `
        -TargetPercent $TargetPercent `
        -UtilizationPercent $utilization `
        -RestartCounts $restartCounts
}

function Write-SampleLine {
    param([Parameter(Mandatory)] $Sample)

    $utilization = "<unknown>"
    if ($null -ne $Sample.UtilizationPercent) {
        $utilization = "$($Sample.UtilizationPercent)%"
    }

    Write-Host ("  {0} cpu: {1,9}/{2}%  replicas={3} ready={4}" -f `
            $Sample.Timestamp.ToString("HH:mm:ssZ"), $utilization, $Sample.TargetPercent, $Sample.Replicas, $Sample.ReadyReplicas)
}

Write-Host "Validating autoscaling behavior for '$Service' in namespace '$Namespace' (run $runId)..."

# --- 0. Preflight ------------------------------------------------------------
# Each of these fails the run with a specific cause instead of letting the
# timeline come back empty and get read as "the autoscaler did nothing".
Invoke-KubectlChecked `
    -KubectlArgs @("cluster-info") `
    -ErrorContext "kubectl cannot reach a Kubernetes cluster" | Out-Null

$metricsApi = Invoke-Kubectl -KubectlArgs @(
    "get", "apiservice", "v1beta1.metrics.k8s.io",
    "-o", "jsonpath={.status.conditions[?(@.type=='Available')].status}"
)
Confirm-Condition `
    -Condition ($metricsApi.ExitCode -eq 0 -and $metricsApi.Output.Trim() -eq "True") `
    -SuccessMessage "the metrics.k8s.io APIService is Available, so the HPA has a CPU metric to read" `
    -FailureMessage "the metrics.k8s.io APIService is not Available (kubectl said: $($metricsApi.Output.Trim())). Without metrics-server every HPA reports <unknown> and never scales; on kind or Docker Desktop it also needs --kubelet-insecure-tls" `
    -Permanent

$hpaJson = (Invoke-KubectlChecked `
        -KubectlArgs @("get", "hpa", $Service, "--namespace", $Namespace, "-o", "json") `
        -ErrorContext "HorizontalPodAutoscaler '$Service' was not found in namespace '$Namespace'. Apply infrastructure/kubernetes/$Service/") | ConvertFrom-Json

$minReplicas = [int] $hpaJson.spec.minReplicas
$maxReplicas = [int] $hpaJson.spec.maxReplicas

$cpuMetric = @($hpaJson.spec.metrics | Where-Object { $_.type -eq "Resource" -and $_.resource.name -eq "cpu" })[0]
Confirm-Condition `
    -Condition ($null -ne $cpuMetric -and $null -ne $cpuMetric.resource.target.averageUtilization) `
    -SuccessMessage "the applied HPA scales '$Service' on CPU utilization within [$minReplicas, $maxReplicas]" `
    -FailureMessage "the applied HPA for '$Service' has no Resource/cpu Utilization metric. Run scripts/validate-$Service-hpa.ps1 first: this script assumes the structural checks already pass" `
    -Permanent

$targetPercent = [int] $cpuMetric.resource.target.averageUtilization

# The window this run is about to measure is read from the cluster rather than
# hardcoded, so the assertion tracks the manifest instead of drifting from it.
$scaleDownWindow = 300
if ($null -ne $hpaJson.spec.behavior.scaleDown.stabilizationWindowSeconds) {
    $scaleDownWindow = [int] $hpaJson.spec.behavior.scaleDown.stabilizationWindowSeconds
}
$scaleDownGraceSeconds = [math]::Max(30, $SampleIntervalSeconds * 2)
if ($scaleDownGraceSeconds -ge $scaleDownWindow) {
    throw "SampleIntervalSeconds ($SampleIntervalSeconds) produces ${scaleDownGraceSeconds}s of sampling grace, which must be smaller than the configured ${scaleDownWindow}s stabilization window. Reduce SampleIntervalSeconds or increase the HPA window."
}
if ($IncludeScaleDown -and $ScaleDownTimeoutSeconds -le $scaleDownWindow) {
    throw "ScaleDownTimeoutSeconds ($ScaleDownTimeoutSeconds) must exceed the configured ${scaleDownWindow}s stabilization window when -IncludeScaleDown is used."
}

$samples = @()
$markers = @{}

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

    # --- 2. Load -------------------------------------------------------------
    if ($Service -eq "ingestion-service") {
        $loadImage = $HttpLoadImage
        # curlimages/curl is Alpine and ships no bash.
        $loadShell = "sh"
        $loadCommand = New-ShellCommand -Template $httpLoadTemplate -Values @{
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
        $loadCommand = New-ShellCommand -Template $kafkaLoadTemplate -Values @{
            RUN       = $runId
            BIN       = "/opt/kafka/bin"
            BOOTSTRAP = "$KafkaClusterName-kafka-bootstrap:$BootstrapPort"
            TOPIC     = $RawTopic
            # Odd on purpose. The value alternates on the parity of `i` and the
            # device is `i % DEVICES`, so an even count would give every device
            # the same parity forever and every reading for it the same value -
            # no deviation, no spike, and the expensive path never taken.
            DEVICES   = 63
        }
    }

    Write-Host "Starting $LoadPodCount load pod(s) against '$Service'..."
    $loadPodNames = @()
    for ($i = 1; $i -le $LoadPodCount; $i++) {
        $loadPodName = "autoscaling-load-$runId-$i"
        Start-LoadPod -PodName $loadPodName -Image $loadImage -Command $loadCommand -Shell $loadShell
        Confirm-LoadPodRunning -PodName $loadPodName
        $loadPodNames += $loadPodName
    }
    Start-Sleep -Seconds ([math]::Min(15, $SampleIntervalSeconds))
    foreach ($loadPodName in $loadPodNames) {
        Confirm-LoadPodTraffic -PodName $loadPodName
    }
    $markers[$baseline.Timestamp] = "<- baseline, before load"

    # --- 3. Sample under load ------------------------------------------------
    Write-Host "Sampling for ${LoadDurationSeconds}s under load:"
    $loadDeadline = (Get-Date).AddSeconds($LoadDurationSeconds)
    while ((Get-Date) -lt $loadDeadline) {
        Start-Sleep -Seconds $SampleIntervalSeconds
        $sample = Get-Sample -TargetPercent $targetPercent
        Write-SampleLine -Sample $sample
        $samples += $sample
    }

    # --- 4. Remove load ------------------------------------------------------
    Write-Host "Removing load pods..."
    Stop-LoadPods
    $loadStopped = (Get-Date).ToUniversalTime()

    if ($IncludeScaleDown) {
        # Sampling continues until the workload is back at the floor or the
        # timeout expires. The timeout is not a failure on its own: the
        # assertions below judge the timeline, so a run that ran out of time
        # fails with "no scale-down was observed" rather than with a bare
        # timeout message that says nothing about the autoscaler.
        Write-Host "Waiting for the ${scaleDownWindow}s stabilization window and the return to minReplicas..."
        $scaleDownDeadline = (Get-Date).AddSeconds($ScaleDownTimeoutSeconds)
        while ((Get-Date) -lt $scaleDownDeadline) {
            Start-Sleep -Seconds $SampleIntervalSeconds
            $sample = Get-Sample -TargetPercent $targetPercent
            Write-SampleLine -Sample $sample
            $samples += $sample

            if ($sample.Replicas -eq $minReplicas -and $sample.ReadyReplicas -eq $minReplicas) {
                break
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
} finally {
    # Runs on Ctrl-C and on any assertion failure above. Load pods left running
    # would keep the cluster under load indefinitely and poison the next run.
    Stop-LoadPods
}

# --- 5. Verdict --------------------------------------------------------------
Write-Host ""
Write-Host "Timeline ($($samples.Count) samples):"
$timeline = Get-AutoscalingTimeline -Samples $samples -MinReplicas $minReplicas -MaxReplicas $maxReplicas
$rendered = Format-AutoscalingTimeline -Timeline $timeline -Markers $markers
Write-Host $rendered
Write-Host ""

Confirm-AutoscalingBehavior `
    -Timeline $timeline `
    -ExpectedScaleDownWindowSeconds $scaleDownWindow `
    -ScaleDownGraceSeconds $scaleDownGraceSeconds `
    -RequireReturnToFloor:$IncludeScaleDown

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $scaleEventLines = @($timeline.ScaleEvents | ForEach-Object {
            "| {0} | {1} | {2} -> {3} |" -f $_.At.ToString("HH:mm:ssZ"), $_.Direction, $_.From, $_.To
        })

    $report = @(
        "# $Service autoscaling behavior (#153)",
        "",
        "Recorded by ``scripts/validate-autoscaling-behavior.ps1`` (run ``$runId``).",
        "",
        "| Item | Value |",
        "| --- | --- |",
        "| Workload | ``$Service`` in namespace ``$Namespace`` |",
        "| HPA bounds | ``[$minReplicas, $maxReplicas]`` at a $targetPercent% CPU target |",
        "| Scale-down window | ``${scaleDownWindow}s`` (read from the applied HPA) |",
        "| Load | $LoadPodCount pod(s), $(if ($Service -eq 'ingestion-service') { "$LoadConcurrency concurrent POST /api/v1/events loops each" } else { "one kafka-console-producer each into $RawTopic" }) |",
        "| Peak utilization | $($timeline.PeakUtilizationPercent)% |",
        "| Peak replicas | $($timeline.PeakReplicas) |",
        "| Container restarts | $($timeline.RestartDelta) |",
        "| Load-pod cleanup | Confirmed: no run-labelled pods remain |",
        "",
        "## Timeline",
        "",
        '```text',
        "timestamp | cpu: current/target  min  max  replicas | ready",
        $rendered,
        '```',
        "",
        "## Scale events",
        ""
    )

    if ($scaleEventLines.Count -gt 0) {
        $report += @("| At | Direction | Replicas |", "| --- | --- | --- |") + $scaleEventLines
    } else {
        $report += "No scale event was recorded in this run."
    }

    $report += @("", "Structural assertions stay the responsibility of ``scripts/validate-$Service-hpa.ps1``.")

    $reportDirectory = Split-Path -Parent $ReportPath
    if (-not [string]::IsNullOrWhiteSpace($reportDirectory) -and -not (Test-Path $reportDirectory)) {
        New-Item -ItemType Directory -Path $reportDirectory | Out-Null
    }

    Set-Content -Path $ReportPath -Value ($report -join [Environment]::NewLine) -Encoding UTF8
    Write-Host "[ok] Wrote the run report to '$ReportPath'."
}

Write-Host "[ok] Autoscaling behavior validation completed for '$Service' in namespace '$Namespace'."
