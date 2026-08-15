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
# RestartCounts = @{ '<pod-uid>/<container>' = n } }. `Restarts` remains a
# shorthand for the single stable test container.
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

        New-AutoscalingSample `
            -Timestamp $script:Origin.AddSeconds($step.Offset) `
            -Replicas $step.Replicas `
            -ReadyReplicas $ready `
            -TargetPercent $TargetPercent `
            -UtilizationPercent $cpu `
            -RestartCounts $restartCounts
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

# --- Timeline reduction ------------------------------------------------------

$healthy = New-HealthyTimeline

Assert-Equal -Expected 2 -Actual $healthy.BaselineReplicas -Description "the baseline is taken from the first sample"
Assert-Equal -Expected 6 -Actual $healthy.PeakReplicas -Description "the peak replica count is the maximum across the run"
Assert-Equal -Expected 2 -Actual $healthy.FinalReplicas -Description "the final replica count is the last sample, not the peak"
Assert-Equal -Expected 210 -Actual $healthy.PeakUtilizationPercent -Description "peak utilization ignores the idle samples around the load"
Assert-Equal -Expected 2 -Actual $healthy.ScaleUpCount -Description "both scale-up steps are counted"
Assert-Equal -Expected 4 -Actual $healthy.ScaleDownCount -Description "all four scale-down steps are counted"
Assert-Equal -Expected 0 -Actual $healthy.RestartDelta -Description "a run with no restarts reports a zero restart delta"

# 150s is the last sample at or above the 70% target; the first scale-down is at
# 480s. The window is measured between those two, not from the end of the load.
Assert-Equal -Expected 330 -Actual $healthy.ObservedScaleDownDelaySeconds `
    -Description "the observed scale-down delay is measured from the last at-or-above-target sample"

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
        @{ Offset = 0; Replicas = 2; Cpu = 3; RestartCounts = @{ "old/app" = 0; "survivor/app" = 0 } },
        @{ Offset = 30; Replicas = 2; Cpu = 190; RestartCounts = @{ "old/app" = 0; "survivor/app" = 1 } },
        @{ Offset = 60; Replicas = 1; Ready = 1; Cpu = 160; RestartCounts = @{ "survivor/app" = 1 } }
    ) -MinReplicas 1) `
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

Assert-Equal -Expected 3 -Actual @($rendered -split "`r?`n").Count -Description "the rendered timeline has one line per sample"

Write-Host "[ok] autoscaling behavior analysis behaves consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
