# Runs the #153 autoscaling behavior rules against synthetic timelines.
# No cluster, no kubectl, no network, no load.
#
# This is the point of keeping the analysis in
# scripts/lib/PulseStreamAutoscalingBehavior.psm1 instead of inline in
# validate-autoscaling-behavior.ps1: the interesting cases are the ones a real
# cluster will not produce on demand. A run that scales past its ceiling, that
# drops below the availability floor mid-scale, that restarts a container under
# load, or that scales in before the stabilization window elapsed all have to be
# rejected, and none of them can be arranged by pointing load at a healthy
# cluster.
#
#   powershell -File scripts\tests\test-autoscaling-behavior-analysis.ps1
#   pwsh -File scripts/tests/test-autoscaling-behavior-analysis.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamAutoscalingBehavior.psm1") -Force

$script:Origin = [datetime]::SpecifyKind([datetime]"2026-01-01T12:00:00", [System.DateTimeKind]::Utc)

# Builds a timeline from a compact list of steps so each test reads as the shape
# it is asserting on rather than as a wall of sample construction.
#
# A step is @{ Offset = <seconds>; Replicas = n; Ready = n; Cpu = n|$null;
# RestartCounts = @{ '<pod-uid>/<container>' = n }; ScalingActive = 'True' }.
# `Restarts` remains a shorthand for the single stable test container, and
# ScalingActive defaults to 'True' so only the tests that are about the HPA's
# own condition have to mention it.
function New-Timeline {
    param(
        [Parameter(Mandatory)] [object[]] $Steps,
        [int] $MinReplicas = 2,
        [int] $MaxReplicas = 6,
        [int] $TargetPercent = 70
    )

    $samples = foreach ($step in $Steps) {
        $ready = $step.Replicas
        if ($step.ContainsKey("Ready")) {
            $ready = $step.Ready
        }

        $restartCounts = @{}
        if ($step.ContainsKey("RestartCounts")) {
            $restartCounts = $step.RestartCounts
        } else {
            $restarts = 0
            if ($step.ContainsKey("Restarts")) {
                $restarts = $step.Restarts
            }
            $restartCounts = @{ "pod-a/app" = $restarts }
        }

        # $null is a legitimate Cpu value (the HPA reporting <unknown>), so the
        # key's presence decides, not its truthiness.
        $cpu = $null
        if ($step.ContainsKey("Cpu")) {
            $cpu = $step.Cpu
        }

        # Same reasoning as Cpu: $null is a legitimate value (an HPA carrying no
        # ScalingActive condition yet), so presence decides.
        $scalingActive = "True"
        if ($step.ContainsKey("ScalingActive")) {
            $scalingActive = $step.ScalingActive
        }

        # Metrics besides CPU, as @{ Name = 'rps'; Target = 100; Current = 40 }.
        $additional = @()
        if ($step.ContainsKey("Metrics")) {
            $additional = @($step.Metrics | ForEach-Object {
                    $current = $null
                    if ($_.ContainsKey("Current")) {
                        $current = $_.Current
                    }
                    New-AutoscalingMetricReading -Name $_.Name -TargetValue $_.Target -CurrentValue $current
                })
        }

        New-AutoscalingSample `
            -Timestamp $script:Origin.AddSeconds($step.Offset) `
            -Replicas $step.Replicas `
            -ReadyReplicas $ready `
            -TargetPercent $TargetPercent `
            -UtilizationPercent $cpu `
            -RestartCounts $restartCounts `
            -ScalingActiveStatus $scalingActive `
            -AdditionalMetrics $additional
    }

    return Get-AutoscalingTimeline -Samples @($samples) -MinReplicas $MinReplicas -MaxReplicas $MaxReplicas
}

# A run that does everything #153 asks for: idle, load, scale-up to the ceiling,
# load removed, a full 300s of stabilization, then one step per minute back to
# the floor.
function New-HealthyTimeline {
    return New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3 },
        @{ Offset = 30; Replicas = 2; Cpu = 210 },
        @{ Offset = 60; Replicas = 4; Ready = 2; Cpu = 190 },
        @{ Offset = 90; Replicas = 4; Cpu = 160 },
        @{ Offset = 120; Replicas = 6; Ready = 4; Cpu = 140 },
        @{ Offset = 150; Replicas = 6; Cpu = 120 },
        @{ Offset = 180; Replicas = 6; Cpu = 4 },
        @{ Offset = 480; Replicas = 5; Cpu = 3 },
        @{ Offset = 540; Replicas = 4; Cpu = 3 },
        @{ Offset = 600; Replicas = 3; Cpu = 2 },
        @{ Offset = 660; Replicas = 2; Cpu = 2 }
    )
}

function Assert-BehaviorRejects {
    param(
        [Parameter(Mandatory)] $Timeline,
        [Parameter(Mandatory)] [string] $ExpectedMessage,
        [Parameter(Mandatory)] [string] $Description,
        [switch] $RequireReturnToFloor
    )

    try {
        Confirm-AutoscalingBehavior `
            -Timeline $Timeline `
            -ExpectedScaleDownWindowSeconds 300 `
            -RequireReturnToFloor:$RequireReturnToFloor
    } catch {
        if ($_.Exception.Message -match $ExpectedMessage) {
            Write-Host "[ok] $Description"
            return
        }

        throw "Expected a rejection matching '$ExpectedMessage' for $Description, got: $($_.Exception.Message)"
    }

    throw "The behavior validator accepted $Description."
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)] $Expected,
        $Actual,
        [Parameter(Mandatory)] [string] $Description
    )

    if ($Expected -ne $Actual) {
        throw "$Description : expected '$Expected', got '$Actual'."
    }

    Write-Host "[ok] $Description"
}

# Separate from Assert-Equal because $null cannot be passed to a Mandatory
# parameter, and making Expected optional would let a mistyped call assert
# nothing at all. Null is a meaningful result here - "the HPA had no computable
# recommendation" - so it gets its own assertion.
function Assert-Null {
    param(
        $Actual,
        [Parameter(Mandatory)] [string] $Description
    )

    if ($null -ne $Actual) {
        throw "$Description : expected null, got '$Actual'."
    }

    Write-Host "[ok] $Description"
}

# --- Timeline reduction ------------------------------------------------------

$healthy = New-HealthyTimeline

Assert-Equal -Expected 2 -Actual $healthy.BaselineReplicas -Description "the baseline is taken from the first sample"
Assert-Equal -Expected 6 -Actual $healthy.PeakReplicas -Description "the peak replica count is the maximum across the run"
Assert-Equal -Expected 2 -Actual $healthy.FinalReplicas -Description "the final replica count is the last sample, not the peak"
Assert-Equal -Expected 210 -Actual $healthy.PeakUtilizationPercent -Description "peak utilization ignores the idle samples around the load"
Assert-Equal -Expected 2 -Actual $healthy.ScaleUpCount -Description "both scale-up steps are counted"
Assert-Equal -Expected 4 -Actual $healthy.ScaleDownCount -Description "all four scale-down steps are counted"
Assert-Equal -Expected 0 -Actual $healthy.RestartDelta -Description "a run with no restarts reports a zero restart delta"

# 180s is the first sample at which the HPA's own desired replica count drops
# below the running one (6 replicas at 4% of a 70% target recommends the floor);
# the first scale-down is at 480s. The window is measured between those two, not
# from the end of the load and not from the last at-or-above-target sample.
Assert-Equal -Expected 300 -Actual $healthy.ObservedScaleDownDelaySeconds `
    -Description "the observed scale-down delay is measured from the first scale-in recommendation"

# Ready pods lag the replica count during a scale-up, which is normal and must
# not be read as a failure - only a drop below the floor is.
Assert-Equal -Expected 2 -Actual $healthy.MinReadyObserved -Description "the worst-case Ready count is tracked across the run"

Confirm-AutoscalingBehavior -Timeline $healthy -ExpectedScaleDownWindowSeconds 300 -RequireReturnToFloor
Write-Host "[ok] a healthy scale-up/scale-down run passes every behavior assertion"

# --- Ordering ----------------------------------------------------------------
# Samples are appended in collection order by the harness, but a retried read can
# arrive out of order. Sorting has to happen before transitions are scored, or a
# late sample is counted as a scale event that never occurred.
$shuffled = New-Timeline -Steps @(
    @{ Offset = 60; Replicas = 4; Cpu = 190 },
    @{ Offset = 0; Replicas = 2; Cpu = 3 },
    @{ Offset = 30; Replicas = 2; Cpu = 210 }
)
Assert-Equal -Expected 2 -Actual $shuffled.BaselineReplicas -Description "out-of-order samples are sorted before the baseline is taken"
Assert-Equal -Expected 1 -Actual $shuffled.ScaleUpCount -Description "out-of-order samples do not invent extra scale events"

# --- Input guards ------------------------------------------------------------
try {
    New-Timeline -Steps @(@{ Offset = 0; Replicas = 2; Cpu = 3 }) | Out-Null
    throw "A single-sample timeline was accepted."
} catch {
    if ($_.Exception.Message -notmatch "at least 2 samples") {
        throw "Expected a single-sample timeline to be rejected, got: $($_.Exception.Message)"
    }
    Write-Host "[ok] a timeline with fewer than 2 samples is rejected, since it cannot contain a transition"
}

# --- Rejections --------------------------------------------------------------

# The failure that most resembles success: no metric at all reads as an idle,
# stable service. It has to fail before any conclusion is drawn from the rest.
Assert-BehaviorRejects `
    -Timeline (New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3 },
        @{ Offset = 30; Replicas = 2; Cpu = $null },
        @{ Offset = 60; Replicas = 4; Cpu = 190 }
    )) `
    -ExpectedMessage "reported <unknown> in 1 of 3 samples" `
    -Description "a run where the HPA could not read its metric was rejected"

# A <unknown> in the FIRST sample is the HPA waiting for its first scrape, not a
# broken metrics pipeline, so it must not fail the run.
$firstUnknown = New-Timeline -Steps @(
    @{ Offset = 0; Replicas = 2; Cpu = $null },
    @{ Offset = 30; Replicas = 2; Cpu = 210 },
    @{ Offset = 60; Replicas = 4; Cpu = 190 }
)
Assert-Equal -Expected 0 -Actual $firstUnknown.UnknownMetricSamples `
    -Description "an <unknown> reading in the first sample is not counted against the run"
Confirm-AutoscalingBehavior -Timeline $firstUnknown -ExpectedScaleDownWindowSeconds 300
Write-Host "[ok] a run whose first sample predates the first metrics scrape still passes"

Assert-BehaviorRejects `
    -Timeline (New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3 },
        @{ Offset = 30; Replicas = 2; Cpu = 12 },
        @{ Offset = 60; Replicas = 2; Cpu = 15 }
    )) `
    -ExpectedMessage "replicas never rose above the baseline of 2" `
    -Description "a run where the load never moved the replica count was rejected"

# The ceiling is a downstream-capacity decision, so exceeding it is a failure of
# the run even though every pod is healthy.
Assert-BehaviorRejects `
    -Timeline (New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3 },
        @{ Offset = 30; Replicas = 6; Cpu = 300 },
        @{ Offset = 60; Replicas = 7; Cpu = 280 }
    )) `
    -ExpectedMessage "reached 7 replicas, above the maxReplicas ceiling of 6" `
    -Description "a run that scaled past maxReplicas was rejected"

# "Services remain healthy during scale events", measured as ready pods rather
# than scheduled ones.
Assert-BehaviorRejects `
    -Timeline (New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3 },
        @{ Offset = 30; Replicas = 4; Ready = 1; Cpu = 190 },
        @{ Offset = 60; Replicas = 4; Cpu = 160 }
    )) `
    -ExpectedMessage "only 1 pods were Ready at the worst sample" `
    -Description "a scale event that took the service below the availability floor was rejected"

# The #290 review's first finding. A replica count is a request; capacity is
# what became Ready. A run whose scaled-up pods stay Pending for want of node
# memory looks identical to a working scale-up in `spec.replicas` alone, and the
# floor assertion above cannot catch it - two Ready pods still clear a floor of
# two.
Assert-BehaviorRejects `
    -Timeline (New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3 },
        @{ Offset = 30; Replicas = 6; Ready = 2; Cpu = 300 },
        @{ Offset = 60; Replicas = 6; Ready = 2; Cpu = 280 }
    )) `
    -ExpectedMessage "reached 6 replicas but never had more than 2 of them Ready" `
    -Description "a scale-up whose new pods never became Ready was rejected"

# The same rule at the smaller margin the committed ingestion run hit: four
# replicas asked for, three ever Ready.
Assert-BehaviorRejects `
    -Timeline (New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3 },
        @{ Offset = 30; Replicas = 4; Ready = 3; Cpu = 190 },
        @{ Offset = 60; Replicas = 4; Ready = 3; Cpu = 160 }
    )) `
    -ExpectedMessage "reached 4 replicas but never had more than 3 of them Ready" `
    -Description "a scale-up one pod short of the capacity it asked for was rejected"

# Ready lagging the replica count DURING a scale-up is normal; only capacity
# that never arrives is a failure. The healthy timeline scales 2 -> 4 -> 6 with
# Ready trailing at each step and still passes.
Assert-Equal -Expected 6 -Actual $healthy.PeakReadyReplicas `
    -Description "the peak Ready count is the most capacity that ever served at once"

# A pod that is still Ready while it terminates must not make a scale-up look
# larger than the replica count it reached.
$readyAheadOfReplicas = New-Timeline -Steps @(
    @{ Offset = 0; Replicas = 2; Cpu = 3 },
    @{ Offset = 30; Replicas = 4; Ready = 4; Cpu = 190 },
    @{ Offset = 60; Replicas = 3; Ready = 4; Cpu = 60 }
)
Assert-Equal -Expected 4 -Actual $readyAheadOfReplicas.PeakReadyReplicas `
    -Description "the peak Ready count is capped by each sample's own replica count"

Assert-BehaviorRejects `
    -Timeline (New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3; Restarts = 4 },
        @{ Offset = 30; Replicas = 4; Cpu = 190; Restarts = 4 },
        @{ Offset = 60; Replicas = 4; Cpu = 160; Restarts = 6 }
    )) `
    -ExpectedMessage "restarts increased by 2 during the run" `
    -Description "a run where a container restarted under load was rejected"

# Aggregates can fall when a scaled-down pod disappears. Retaining counts per
# UID/container ensures that disappearance cannot hide a restart on a pod that
# remains part of the workload.
Assert-BehaviorRejects `
    -Timeline (New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3; RestartCounts = @{ "old/app" = 5; "survivor/app" = 0 } },
        @{ Offset = 30; Replicas = 4; Cpu = 190; RestartCounts = @{ "old/app" = 5; "survivor/app" = 0; "new-a/app" = 0; "new-b/app" = 0 } },
        @{ Offset = 60; Replicas = 2; Cpu = 160; RestartCounts = @{ "survivor/app" = 1; "new-a/app" = 0 } }
    )) `
    -ExpectedMessage "restarts increased by 1 during the run" `
    -Description "a scaled-down pod cannot hide a restart on a surviving pod"

# Restarts that predate the run belong to the pods, not to the scale event.
$preexistingRestarts = New-Timeline -Steps @(
    @{ Offset = 0; Replicas = 2; Cpu = 3; Restarts = 17 },
    @{ Offset = 30; Replicas = 4; Cpu = 190; Restarts = 17 },
    @{ Offset = 60; Replicas = 4; Cpu = 160; Restarts = 17 }
)
Confirm-AutoscalingBehavior -Timeline $preexistingRestarts -ExpectedScaleDownWindowSeconds 300
Write-Host "[ok] restart counts that predate the run are not attributed to it"

# The other half of that rule, and the one that hides a real failure rather than
# inventing one. Only the pods in the FIRST sample predate the run; a pod the
# autoscaler created under load has no history to forgive. Baselining it on its
# own first observation would score `new-a` as 1 - 1 = 0 and report a clean run,
# which is exactly the restart this validation exists to catch: the scale-up
# produced a replica that crash-looped before it was ever sampled.
Assert-BehaviorRejects `
    -Timeline (New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3; RestartCounts = @{ "old-a/app" = 17; "old-b/app" = 17 } },
        @{ Offset = 30; Replicas = 4; Cpu = 190; RestartCounts = @{ "old-a/app" = 17; "old-b/app" = 17; "new-a/app" = 1; "new-b/app" = 0 } },
        @{ Offset = 60; Replicas = 4; Cpu = 160; RestartCounts = @{ "old-a/app" = 17; "old-b/app" = 17; "new-a/app" = 1; "new-b/app" = 0 } }
    )) `
    -ExpectedMessage "restarts increased by 1 during the run" `
    -Description "a pod created after the baseline and first seen at restartCount=1 was counted as a restart"

# --- ScalingActive -----------------------------------------------------------
# A rising replica count and a CPU reading do not establish that the HPA caused
# the change: a rollout, a `kubectl scale`, or another controller resizes the
# Deployment just as visibly. ScalingActive is the autoscaler stating that it
# computed the desired count itself, so a run without it proves nothing.
Assert-BehaviorRejects `
    -Timeline (New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3 },
        @{ Offset = 30; Replicas = 4; Cpu = 190; ScalingActive = "False" },
        @{ Offset = 60; Replicas = 6; Cpu = 160 }
    )) `
    -ExpectedMessage "did not report ScalingActive=True in 1 of the 2 samples" `
    -Description "a run where the HPA was not the thing scaling the workload was rejected"

# An HPA reports FailedGetResourceMetric until its first scrape lands, so the
# first sample is excluded here for the same reason an <unknown> metric is.
$firstScalingActiveMissing = New-Timeline -Steps @(
    @{ Offset = 0; Replicas = 2; Cpu = $null; ScalingActive = $null },
    @{ Offset = 30; Replicas = 2; Cpu = 210 },
    @{ Offset = 60; Replicas = 4; Cpu = 190 }
)
Assert-Equal -Expected 2 -Actual $firstScalingActiveMissing.ScalingActiveTrueSamples `
    -Description "ScalingActive is counted across every sample after the first"
Assert-Equal -Expected 0 -Actual $firstScalingActiveMissing.ScalingActiveNotTrueSamples `
    -Description "a missing ScalingActive condition in the first sample is not counted against the run"
Confirm-AutoscalingBehavior -Timeline $firstScalingActiveMissing -ExpectedScaleDownWindowSeconds 300
Write-Host "[ok] a run whose first sample predates the HPA's first scrape still passes"

# --- Scale-down rejections ---------------------------------------------------

Assert-BehaviorRejects `
    -RequireReturnToFloor `
    -Timeline (New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3 },
        @{ Offset = 30; Replicas = 6; Cpu = 300 },
        @{ Offset = 60; Replicas = 6; Cpu = 4 }
    )) `
    -ExpectedMessage "no scale-down was observed" `
    -Description "a run that ended before any scale-in was rejected when the return to the floor was required"

Assert-BehaviorRejects `
    -RequireReturnToFloor `
    -Timeline (New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3 },
        @{ Offset = 30; Replicas = 6; Cpu = 300 },
        @{ Offset = 60; Replicas = 6; Cpu = 4 },
        @{ Offset = 420; Replicas = 5; Cpu = 3 },
        @{ Offset = 480; Replicas = 4; Cpu = 3 }
    )) `
    -ExpectedMessage "settled at 4 replicas rather than the minReplicas floor of 2" `
    -Description "a run that stopped scaling in above the floor was rejected"

# The one part of `behavior` no structural check can prove: that the configured
# window is actually waited out. 90s after the last at-or-above-target sample is
# not 300s, and no sampling grace covers that gap.
Assert-BehaviorRejects `
    -RequireReturnToFloor `
    -Timeline (New-Timeline -Steps @(
        @{ Offset = 0; Replicas = 2; Cpu = 3 },
        @{ Offset = 30; Replicas = 6; Cpu = 300 },
        @{ Offset = 60; Replicas = 6; Cpu = 4 },
        @{ Offset = 120; Replicas = 4; Cpu = 3 },
        @{ Offset = 180; Replicas = 2; Cpu = 2 }
    )) `
    -ExpectedMessage "short of the configured 300s stabilization window" `
    -Description "a scale-in that came before the stabilization window elapsed was rejected"

# --- Desired-replica arithmetic ----------------------------------------------
# Utilization below target is not a scale-in recommendation. The HPA computes
# ceil(replicas * current / target), skips any metric within its tolerance of
# 1.0, and clamps into [minReplicas, maxReplicas]; every one of those steps keeps
# a workload at its current size while CPU sits under the target.
function New-RecommendationSample {
    param(
        [Parameter(Mandatory)] [int] $Replicas,
        [nullable[int]] $Cpu,
        [int] $TargetPercent = 70,
        [object[]] $Metrics = @(),
        # Default to a fully Ready, fully measured workload so only the tests
        # that are about the controller's conservative adjustments mention it.
        [nullable[int]] $Ready = $null,
        [nullable[int]] $MetricPodCount = $null
    )

    $readyReplicas = $Replicas
    if ($null -ne $Ready) {
        $readyReplicas = [int] $Ready
    }

    $additional = @($Metrics | ForEach-Object {
            $current = $null
            if ($_.ContainsKey("Current")) {
                $current = $_.Current
            }
            New-AutoscalingMetricReading -Name $_.Name -TargetValue $_.Target -CurrentValue $current
        })

    return New-AutoscalingSample `
        -Timestamp $script:Origin `
        -Replicas $Replicas `
        -ReadyReplicas $readyReplicas `
        -TargetPercent $TargetPercent `
        -UtilizationPercent $Cpu `
        -ScalingActiveStatus "True" `
        -AdditionalMetrics $additional `
        -MetricPodCount $MetricPodCount
}

function Get-Recommendation {
    param(
        [Parameter(Mandatory)] $Sample,
        [int] $MinReplicas = 2,
        [int] $MaxReplicas = 6
    )

    return Get-HpaScaleRecommendation -Sample $Sample -MinReplicas $MinReplicas -MaxReplicas $MaxReplicas
}

# The exact case from the #290 review: 6 replicas at 69% against a 70% target.
# The ratio is inside the 0.1 tolerance, so the HPA proposes no change at all.
$borderline = Get-Recommendation -Sample (New-RecommendationSample -Replicas 6 -Cpu 69)
Assert-Equal -Expected 6 -Actual $borderline.DesiredReplicas -Description "6 replicas at 69% of a 70% target still desires 6 replicas"
Assert-Equal -Expected $false -Actual $borderline.RecommendsDownscale -Description "utilization just below target is not a scale-in recommendation"

# Outside the tolerance but still rounding back up: ceil(6 * 62 / 70) = 6.
$rounded = Get-Recommendation -Sample (New-RecommendationSample -Replicas 6 -Cpu 62)
Assert-Equal -Expected 6 -Actual $rounded.DesiredReplicas -Description "ceil() keeps 6 replicas at 62% of a 70% target"
Assert-Equal -Expected $false -Actual $rounded.RecommendsDownscale -Description "a reading outside the tolerance that still rounds up to the current count is not a scale-in recommendation"

# 58% is where the arithmetic finally produces a smaller count: ceil(6*58/70)=5.
$genuine = Get-Recommendation -Sample (New-RecommendationSample -Replicas 6 -Cpu 58)
Assert-Equal -Expected 5 -Actual $genuine.DesiredReplicas -Description "58% of a 70% target at 6 replicas desires 5"
Assert-Equal -Expected $true -Actual $genuine.RecommendsDownscale -Description "the first count below the running one is a scale-in recommendation"

# The HPA never recommends below its own floor, so an idle workload already at
# minReplicas is not waiting on a stabilization window.
$atFloor = Get-Recommendation -Sample (New-RecommendationSample -Replicas 2 -Cpu 1)
Assert-Equal -Expected 2 -Actual $atFloor.DesiredReplicas -Description "the desired count is clamped to the minReplicas floor"
Assert-Equal -Expected $false -Actual $atFloor.RecommendsDownscale -Description "an idle workload at the floor recommends no scale-in"

# The desired count is the maximum across metrics: a second metric at its target
# holds the replica count up no matter how low CPU falls.
$multiMetric = Get-Recommendation -Sample (New-RecommendationSample -Replicas 6 -Cpu 5 -Metrics @(
        @{ Name = "pods/http_requests_per_second"; Target = 100; Current = 100 }
    ))
Assert-Equal -Expected 6 -Actual $multiMetric.DesiredReplicas -Description "the desired count is the maximum across the HPA's metrics"
Assert-Equal -Expected $false -Actual $multiMetric.RecommendsDownscale -Description "idle CPU is not a scale-in recommendation while another configured metric sits at its target"

# An unreadable metric is not a low one. A controller that cannot see a metric
# does not scale in on it, so no recommendation can be attributed to the sample.
$unknownMetric = Get-Recommendation -Sample (New-RecommendationSample -Replicas 6 -Cpu 5 -Metrics @(
        @{ Name = "pods/http_requests_per_second"; Target = 100 }
    ))
Assert-Null -Actual $unknownMetric.DesiredReplicas -Description "an <unknown> metric leaves the desired replica count uncomputable"
Assert-Equal -Expected $false -Actual $unknownMetric.RecommendsDownscale -Description "an <unknown> metric is not treated as a scale-in recommendation"

# --- Unready and unmeasured pods ---------------------------------------------
# The #290 review's second finding. `status.currentMetrics` is the average over
# the pods the controller could read, published BEFORE the substitutions it
# makes for the pods it could not, so dividing it back out by the full replica
# count computes something the controller never did.
#
# The exact sample from the committed ingestion run: 4 replicas, 3 Ready, CPU
# 50% of a 70% target. Naively ceil(4 * 50/70) = 3, a scale-in. Treating the
# fourth pod as missing its metric - the world the controller is most
# conservative in - gives (0.714*3 + 1)/4 = 0.786 and ceil(0.786 * 4) = 4.
$oneUnready = Get-Recommendation -Sample (New-RecommendationSample -Replicas 4 -Ready 3 -Cpu 50)
Assert-Equal -Expected 4 -Actual $oneUnready.DesiredReplicas `
    -Description "4 replicas with 1 unready at 50% of a 70% target still desires 4"
Assert-Equal -Expected $false -Actual $oneUnready.RecommendsDownscale `
    -Description "a status average taken over fewer pods than are running is not a scale-in recommendation on its own"

# Far enough below target and even the conservative world scales in:
# (0.143*3 + 1)/4 = 0.357, ceil(0.357 * 4) = 2.
$deeplyIdleUnready = Get-Recommendation -Sample (New-RecommendationSample -Replicas 4 -Ready 3 -Cpu 10)
Assert-Equal -Expected 2 -Actual $deeplyIdleUnready.DesiredReplicas `
    -Description "an unready pod does not hold the desired count up once the measured pods are far under target"
Assert-Equal -Expected $true -Actual $deeplyIdleUnready.RecommendsDownscale `
    -Description "a genuine scale-in is still recognised while a pod is unready"

# The same 4/3/50% shape, but metrics-server reports only two pods: the divisor
# the controller used is smaller still, and more of the replica set is filled in
# at target. (0.714*2 + 2)/4 = 0.857 is inside neither the tolerance nor a
# direction flip, and ceil(0.857 * 4) = 4.
$metricsBehindReadiness = Get-Recommendation -Sample (New-RecommendationSample -Replicas 4 -Ready 3 -Cpu 50 -MetricPodCount 2)
Assert-Equal -Expected 4 -Actual $metricsBehindReadiness.DesiredReplicas `
    -Description "a pod that is Ready but has no metric yet is treated as unmeasured, not as idle"
Assert-Equal -Expected $false -Actual $metricsBehindReadiness.RecommendsDownscale `
    -Description "missing metrics on a Ready pod do not produce a scale-in recommendation"

# The substitution can pull the ratio back inside the tolerance, which is where
# the controller abandons the change outright: 6 replicas, 5 measured, 58% of
# 70% gives (0.829*5 + 1)/6 = 0.857 - but with only one replica unmeasured out
# of six the arithmetic still lands on ceil(0.857*6) = 6, not the 5 that the
# same reading produces when every pod reports.
$fullyMeasured = Get-Recommendation -Sample (New-RecommendationSample -Replicas 6 -Cpu 58)
$partlyMeasured = Get-Recommendation -Sample (New-RecommendationSample -Replicas 6 -Ready 5 -Cpu 58)
Assert-Equal -Expected 5 -Actual $fullyMeasured.DesiredReplicas -Description "58% across six measured pods desires 5"
Assert-Equal -Expected 6 -Actual $partlyMeasured.DesiredReplicas -Description "the same 58% with one pod unmeasured desires 6"

# A workload with nothing Ready has no average behind its published metric at
# all, so no recommendation can be attributed to the sample.
$noneReady = Get-Recommendation -Sample (New-RecommendationSample -Replicas 4 -Ready 0 -Cpu 5)
Assert-Null -Actual $noneReady.DesiredReplicas `
    -Description "a sample with no Ready pod leaves the desired replica count uncomputable"
Assert-Equal -Expected $false -Actual $noneReady.RecommendsDownscale `
    -Description "a workload with nothing Ready is not treated as recommending a scale-in"

# --- Quantity parsing ---------------------------------------------------------
# Non-utilization targets arrive as Kubernetes quantities, and their ratio is
# only meaningful once the suffixes are applied.
Assert-Equal -Expected 0.1 -Actual (ConvertFrom-KubernetesQuantity -Quantity "100m") -Description "a milli-suffixed quantity is scaled by 1/1000"
Assert-Equal -Expected 1500 -Actual (ConvertFrom-KubernetesQuantity -Quantity "1500") -Description "a bare quantity parses as itself"
Assert-Equal -Expected 2048 -Actual (ConvertFrom-KubernetesQuantity -Quantity "2Ki") -Description "a binary-suffixed quantity is scaled by 1024"
Assert-Equal -Expected 3000 -Actual (ConvertFrom-KubernetesQuantity -Quantity "3k") -Description "a decimal-suffixed quantity is scaled by 1000"

try {
    ConvertFrom-KubernetesQuantity -Quantity "12 requests" | Out-Null
    throw "A non-quantity string was accepted."
} catch {
    if ($_.Exception.Message -notmatch "is not a Kubernetes quantity") {
        throw "Expected a non-quantity string to be rejected, got: $($_.Exception.Message)"
    }
    Write-Host "[ok] a value that is not a Kubernetes quantity is rejected rather than silently treated as zero"
}

# --- HPA metric extraction ----------------------------------------------------
# The readings are built from the applied object, so a metric the HPA carries
# cannot be left out of the desired-replica calculation by the sampler.
$hpaSpecMetrics = @(
    [pscustomobject]@{ type = "Resource"; resource = [pscustomobject]@{ name = "cpu"; target = [pscustomobject]@{ averageUtilization = 70 } } },
    [pscustomobject]@{ type = "Pods"; pods = [pscustomobject]@{ metric = [pscustomobject]@{ name = "http_requests_per_second" }; target = [pscustomobject]@{ averageValue = "100" } } },
    [pscustomobject]@{ type = "Resource"; resource = [pscustomobject]@{ name = "memory"; target = [pscustomobject]@{ averageValue = "512Mi" } } }
)
$hpaCurrentMetrics = @(
    [pscustomobject]@{ type = "Resource"; resource = [pscustomobject]@{ name = "cpu"; current = [pscustomobject]@{ averageUtilization = 12 } } },
    [pscustomobject]@{ type = "Pods"; pods = [pscustomobject]@{ metric = [pscustomobject]@{ name = "http_requests_per_second" }; current = [pscustomobject]@{ averageValue = "40" } } }
)
$readings = Get-HpaMetricReadings -SpecMetrics $hpaSpecMetrics -CurrentMetrics $hpaCurrentMetrics

Assert-Equal -Expected 2 -Actual $readings.Count -Description "the CPU utilization metric is left to the sample and the other two are extracted"
Assert-Equal -Expected 100 -Actual $readings[0].TargetValue -Description "a Pods metric target is read from the applied HPA"
Assert-Equal -Expected 40 -Actual $readings[0].CurrentValue -Description "a Pods metric reading is paired with its target by type and name"
Assert-Equal -Expected 536870912 -Actual $readings[1].TargetValue -Description "a memory target written as a binary quantity is converted before it is divided"
Assert-Null -Actual $readings[1].CurrentValue `
    -Description "a configured metric with no reading in status is kept with a null value rather than dropped"

# --- Scale-down anchoring -----------------------------------------------------

# The #290 regression. Utilization sits at 69% - under the 70% target, but still
# desiring all 6 replicas - then collapses to 10%, and the workload scales in 60s
# later. Anchoring on "utilization last at or above target" measures 270s here
# and accepts the run against a 300s window with 30s of grace. The HPA's own
# recommendation only turned over at 240s, so the window observed is 60s.
$falsePassTimeline = New-Timeline -Steps @(
    @{ Offset = 0; Replicas = 2; Cpu = 3 },
    @{ Offset = 30; Replicas = 6; Cpu = 300 },
    @{ Offset = 90; Replicas = 6; Cpu = 69 },
    @{ Offset = 150; Replicas = 6; Cpu = 69 },
    @{ Offset = 210; Replicas = 6; Cpu = 69 },
    @{ Offset = 240; Replicas = 6; Cpu = 10 },
    @{ Offset = 300; Replicas = 5; Cpu = 8 },
    @{ Offset = 360; Replicas = 4; Cpu = 6 },
    @{ Offset = 420; Replicas = 3; Cpu = 5 },
    @{ Offset = 480; Replicas = 2; Cpu = 4 }
)
Assert-Equal -Expected 60 -Actual $falsePassTimeline.ObservedScaleDownDelaySeconds `
    -Description "a run that idled at 69% measures the window from the 10% sample, not from the last sample at or above target"
Assert-BehaviorRejects `
    -RequireReturnToFloor `
    -Timeline $falsePassTimeline `
    -ExpectedMessage "short of the configured 300s stabilization window" `
    -Description "a scale-in 60s after the first genuine scale-in recommendation, preceded by 150s of sub-target-but-not-scale-in utilization, was rejected"

# The window stabilizes the MAXIMUM recommendation it holds, so a recommendation
# that recovers restarts it. Measuring from the earlier, interrupted dip would
# credit the run with a window the controller never ran.
$interrupted = New-Timeline -Steps @(
    @{ Offset = 0; Replicas = 2; Cpu = 3 },
    @{ Offset = 30; Replicas = 6; Cpu = 300 },
    @{ Offset = 60; Replicas = 6; Cpu = 10 },
    @{ Offset = 120; Replicas = 6; Cpu = 300 },
    @{ Offset = 300; Replicas = 6; Cpu = 10 },
    @{ Offset = 360; Replicas = 5; Cpu = 8 },
    @{ Offset = 420; Replicas = 4; Cpu = 6 },
    @{ Offset = 480; Replicas = 3; Cpu = 5 },
    @{ Offset = 540; Replicas = 2; Cpu = 4 }
)
Assert-Equal -Expected 60 -Actual $interrupted.ObservedScaleDownDelaySeconds `
    -Description "a scale-in recommendation that recovered restarts the observed window"
Assert-BehaviorRejects `
    -RequireReturnToFloor `
    -Timeline $interrupted `
    -ExpectedMessage "short of the configured 300s stabilization window" `
    -Description "a run whose earlier scale-in recommendation recovered before the scale-in was rejected"

# A second metric holding at its target means the HPA wanted every replica it
# had, however idle the CPU looked. The window cannot start until that metric
# falls too.
$secondMetricHeld = New-Timeline -Steps @(
    @{ Offset = 0; Replicas = 2; Cpu = 3; Metrics = @(@{ Name = "pods/rps"; Target = 100; Current = 20 }) },
    @{ Offset = 30; Replicas = 6; Cpu = 300; Metrics = @(@{ Name = "pods/rps"; Target = 100; Current = 300 }) },
    @{ Offset = 90; Replicas = 6; Cpu = 5; Metrics = @(@{ Name = "pods/rps"; Target = 100; Current = 100 }) },
    @{ Offset = 210; Replicas = 6; Cpu = 5; Metrics = @(@{ Name = "pods/rps"; Target = 100; Current = 100 }) },
    @{ Offset = 300; Replicas = 6; Cpu = 5; Metrics = @(@{ Name = "pods/rps"; Target = 100; Current = 5 }) },
    @{ Offset = 360; Replicas = 5; Cpu = 4; Metrics = @(@{ Name = "pods/rps"; Target = 100; Current = 4 }) },
    @{ Offset = 420; Replicas = 4; Cpu = 4; Metrics = @(@{ Name = "pods/rps"; Target = 100; Current = 4 }) },
    @{ Offset = 480; Replicas = 3; Cpu = 3; Metrics = @(@{ Name = "pods/rps"; Target = 100; Current = 3 }) },
    @{ Offset = 540; Replicas = 2; Cpu = 3; Metrics = @(@{ Name = "pods/rps"; Target = 100; Current = 3 }) }
)
Assert-Equal -Expected 60 -Actual $secondMetricHeld.ObservedScaleDownDelaySeconds `
    -Description "the window is measured from the point where the LAST configured metric stopped asking for the current replica count"
Assert-BehaviorRejects `
    -RequireReturnToFloor `
    -Timeline $secondMetricHeld `
    -ExpectedMessage "short of the configured 300s stabilization window" `
    -Description "a run judged on CPU alone would have passed, but the second metric held the desired count up until 60s before the scale-in"

# A scale-in with no preceding scale-in recommendation at all is not a window
# that held; it is a replica change the autoscaler did not ask for.
$unexplainedScaleIn = New-Timeline -Steps @(
    @{ Offset = 0; Replicas = 2; Cpu = 3 },
    @{ Offset = 30; Replicas = 6; Cpu = 300 },
    @{ Offset = 90; Replicas = 6; Cpu = 300 },
    @{ Offset = 150; Replicas = 2; Cpu = 300 }
)
Assert-Null -Actual $unexplainedScaleIn.ObservedScaleDownDelaySeconds `
    -Description "no delay is reported for a scale-in the HPA never recommended"
Assert-BehaviorRejects `
    -RequireReturnToFloor `
    -Timeline $unexplainedScaleIn `
    -ExpectedMessage "without a single preceding sample in which the HPA's desired replica count was below the running one" `
    -Description "a scale-in that no recommendation preceded was rejected instead of being credited to the window"

# The sampling grace is a tolerance for observation quantization, never an
# alternative stabilization window. A grace equal to the window used to make
# the threshold zero and let any early scale-in pass.
try {
    Confirm-AutoscalingBehavior -Timeline $healthy -ExpectedScaleDownWindowSeconds 300 -ScaleDownGraceSeconds 300 -RequireReturnToFloor
    throw "A sampling grace equal to the stabilization window was accepted."
} catch {
    if ($_.Exception.Message -notmatch "must be non-negative and smaller") {
        throw "Expected invalid sampling grace to be rejected, got: $($_.Exception.Message)"
    }
    Write-Host "[ok] sampling grace equal to the stabilization window is rejected"
}

# --- Where the sampling grace comes from --------------------------------------
# The #290 review's third finding. The grace used to be widened to the widest
# gap ANYWHERE in the timeline, so an unrelated 299s stall in the idle stretch
# after the load bought a 60s scale-in a pass against a 300s window. Only the
# gap the recommendation could have turned over inside - the one ending at the
# anchor sample - makes the measurement too short, so only that gap is forgiven.
$unrelatedStall = New-Timeline -Steps @(
    @{ Offset = 0; Replicas = 2; Cpu = 3 },
    @{ Offset = 30; Replicas = 6; Cpu = 300 },
    @{ Offset = 60; Replicas = 6; Cpu = 300 },
    # 299s with the recommendation still at the ceiling: a long gap that says
    # nothing at all about when the recommendation later turned over.
    @{ Offset = 359; Replicas = 6; Cpu = 300 },
    @{ Offset = 374; Replicas = 6; Cpu = 10 },
    @{ Offset = 434; Replicas = 5; Cpu = 8 },
    @{ Offset = 494; Replicas = 4; Cpu = 6 },
    @{ Offset = 554; Replicas = 3; Cpu = 5 },
    @{ Offset = 614; Replicas = 2; Cpu = 4 }
)
Assert-Equal -Expected 60 -Actual $unrelatedStall.ObservedScaleDownDelaySeconds `
    -Description "the observed window is measured from the anchor regardless of gaps elsewhere in the run"
Assert-Equal -Expected 15 -Actual $unrelatedStall.DownscaleRecommendationGapSeconds `
    -Description "the reported anchor gap is the interval ending at the first scale-in recommendation"

$stallGrace = Get-ScaleDownSamplingGrace -Timeline $unrelatedStall -RequestedGraceSeconds 30 -ExpectedScaleDownWindowSeconds 300
Assert-Equal -Expected 30 -Actual $stallGrace.GraceSeconds `
    -Description "a 299s gap elsewhere in the timeline does not widen the sampling grace"
Assert-BehaviorRejects `
    -RequireReturnToFloor `
    -Timeline $unrelatedStall `
    -ExpectedMessage "short of the configured 300s stabilization window" `
    -Description "a 60s scale-down preceded by an unrelated 299s sampling gap was rejected"

# The gap that IS the measurement's uncertainty still widens the grace, since a
# recommendation seen 58s late makes the observed window up to 58s too short.
$slowAnchor = New-Timeline -Steps @(
    @{ Offset = 0; Replicas = 2; Cpu = 3 },
    @{ Offset = 30; Replicas = 6; Cpu = 300 },
    @{ Offset = 90; Replicas = 6; Cpu = 300 },
    @{ Offset = 148; Replicas = 6; Cpu = 10 },
    @{ Offset = 400; Replicas = 5; Cpu = 8 },
    @{ Offset = 460; Replicas = 4; Cpu = 6 },
    @{ Offset = 520; Replicas = 3; Cpu = 5 },
    @{ Offset = 580; Replicas = 2; Cpu = 4 }
)
$slowAnchorGrace = Get-ScaleDownSamplingGrace -Timeline $slowAnchor -RequestedGraceSeconds 30 -ExpectedScaleDownWindowSeconds 300
Assert-Equal -Expected 58 -Actual $slowAnchorGrace.GraceSeconds `
    -Description "the gap ending at the anchor widens the grace beyond the requested minimum"
Confirm-AutoscalingBehavior `
    -Timeline $slowAnchor `
    -ExpectedScaleDownWindowSeconds 300 `
    -ScaleDownGraceSeconds $slowAnchorGrace.GraceSeconds `
    -RequireReturnToFloor
Write-Host "[ok] a 252s observed window is accepted against a 300s one when the anchor itself was sampled 58s late"

# Past half the window the run has stopped being evidence about the window, so
# the grace is capped and the caller is told to reject rather than to pass on a
# grace that forgives most of what it is measuring.
$blindAnchor = New-Timeline -Steps @(
    @{ Offset = 0; Replicas = 2; Cpu = 3 },
    @{ Offset = 30; Replicas = 6; Cpu = 300 },
    @{ Offset = 230; Replicas = 6; Cpu = 10 },
    @{ Offset = 500; Replicas = 5; Cpu = 8 },
    @{ Offset = 560; Replicas = 4; Cpu = 6 },
    @{ Offset = 620; Replicas = 3; Cpu = 5 },
    @{ Offset = 680; Replicas = 2; Cpu = 4 }
)
$blindGrace = Get-ScaleDownSamplingGrace -Timeline $blindAnchor -RequestedGraceSeconds 30 -ExpectedScaleDownWindowSeconds 300
Assert-Equal -Expected $true -Actual $blindGrace.ExceedsCeiling `
    -Description "an anchor gap above half the window is reported as beyond what a verdict may forgive"
Assert-Equal -Expected 150 -Actual $blindGrace.GraceSeconds `
    -Description "the grace handed to the verdict is capped at half the stabilization window"

# --- Rendering ---------------------------------------------------------------
# The report is the deliverable of #153, so the renderer is asserted too: an
# <unknown> must survive as <unknown>, and markers must land on their sample.
$rendered = Format-AutoscalingTimeline `
    -Timeline $firstUnknown `
    -Markers @{ $script:Origin = "<- baseline, before load" }

$firstLine = @($rendered -split "`r?`n")[0]
if ($firstLine -notmatch "<unknown>") {
    throw "Expected the rendered timeline to show <unknown> for a missing metric, got: $firstLine"
}
if ($firstLine -notmatch [regex]::Escape("<- baseline, before load")) {
    throw "Expected the marker to be rendered on its own sample line, got: $firstLine"
}
Write-Host "[ok] the rendered timeline preserves <unknown> readings and places markers on their sample"

# ScalingActive is rendered per sample, not only summarised in the verdict, so a
# committed report is evidence that the autoscaler was live for the whole run.
if ($firstLine -notmatch "scalingActive=") {
    throw "Expected the rendered timeline to carry the HPA's ScalingActive status per sample, got: $firstLine"
}
$secondLine = @($rendered -split "`r?`n")[1]
if ($secondLine -notmatch "scalingActive=True") {
    throw "Expected the rendered timeline to show ScalingActive=True once the HPA reports it, got: $secondLine"
}
Write-Host "[ok] the rendered timeline records the HPA's ScalingActive status on every sample"

Assert-Equal -Expected 3 -Actual @($rendered -split "`r?`n").Count -Description "the rendered timeline has one line per sample"

Write-Host "[ok] autoscaling behavior analysis behaves consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
