# Timeline analysis for the end-to-end autoscaling validation (#153).
#
# The HPA structural checks (#150, #151) assert the shape of the object. This
# module asserts what the object *did*: that replicas rose under load, that the
# ceiling and floor held, that the configured scale-down stabilization window was
# actually waited out, and that the service stayed available while all of that
# happened.
#
# Everything here is pure. It takes a list of samples and returns a verdict, with
# no kubectl call and no clock of its own, which is what lets
# scripts/tests/test-autoscaling-behavior-analysis.ps1 drive it with synthetic
# timelines - including the failure timelines a real cluster run is unlikely to
# produce on demand. scripts/validate-autoscaling-behavior.ps1 is the half that
# needs a cluster: it collects the samples and hands them here.

# Imported without -Force on purpose. -Force removes and re-imports the module,
# which would unload the copy a calling script had already imported for its own
# use: a validator that imports PulseStreamValidation and then this module would
# lose Confirm-Condition the moment this line ran.
Import-Module (Join-Path $PSScriptRoot "PulseStreamValidation.psm1")

# One observation of the autoscaled workload at one instant.
#
# UtilizationPercent is deliberately nullable and deliberately not defaulted to
# 0: an HPA that cannot read its metric reports `<unknown>`, and recording that
# as 0% would turn "the autoscaler is blind" into "the service is idle" - the
# one failure mode that looks most like a healthy result.
function New-AutoscalingSample {
    param(
        [Parameter(Mandatory)] [datetime] $Timestamp,
        # Pods the Deployment currently has, and how many of them pass their
        # readiness probe. Both are needed: a scale-up that schedules pods which
        # never become Ready is not a successful scale-up.
        [Parameter(Mandatory)] [int] $Replicas,
        [Parameter(Mandatory)] [int] $ReadyReplicas,
        [Parameter(Mandatory)] [int] $TargetPercent,
        [nullable[int]] $UtilizationPercent = $null,
        # Counts keyed by immutable Pod UID and container name. Pod names and
        # aggregate totals are not safe here: a scaled-down pod can disappear
        # after a restart and hide an increase on a surviving pod.
        [hashtable] $RestartCounts = @{},
        # The HPA's own ScalingActive condition, recorded verbatim ("True",
        # "False", "Unknown") and left null when the HPA carries no such
        # condition yet. A CPU reading and a changing replica count do not by
        # themselves show that the autoscaler produced the change: a Deployment
        # can be resized by `kubectl scale`, by a rollout, or by another
        # controller while the HPA sits at ScalingActive=False.
        [string] $ScalingActiveStatus = $null
    )

    return [pscustomobject]@{
        Timestamp           = $Timestamp.ToUniversalTime()
        Replicas            = $Replicas
        ReadyReplicas       = $ReadyReplicas
        TargetPercent       = $TargetPercent
        UtilizationPercent  = $UtilizationPercent
        RestartCounts       = $RestartCounts
        ScalingActiveStatus = $ScalingActiveStatus
    }
}

# Samples must already be in timestamp order: the first one defines which
# containers predate the run.
function Get-RestartDelta {
    param([Parameter(Mandatory)] [object[]] $Samples)

    # Only the containers present in the FIRST sample get a historical baseline.
    # Those Pods predate the run and may legitimately carry restarts that have
    # nothing to do with it - the recorded #150 run had pods at 17 each before
    # any load was applied.
    #
    # A Pod the autoscaler created mid-run has no such history. Baselining it on
    # its first observation would forgive exactly the restarts this run exists
    # to catch: a new replica that crash-looped before it was ever sampled is
    # first seen at restartCount=1, and would otherwise be scored as zero.
    $baselines = @{}
    foreach ($key in $Samples[0].RestartCounts.Keys) {
        $baselines[$key] = [int] $Samples[0].RestartCounts[$key]
    }

    # Retain each container's greatest observed count even after its Pod has
    # been scaled away, so churn cannot erase a restart from the verdict.
    $maxima = @{}
    foreach ($sample in $Samples) {
        foreach ($key in $sample.RestartCounts.Keys) {
            $count = [int] $sample.RestartCounts[$key]
            if (-not $baselines.ContainsKey($key)) {
                $baselines[$key] = 0
            }
            if (-not $maxima.ContainsKey($key) -or $count -gt $maxima[$key]) {
                $maxima[$key] = $count
            }
        }
    }

    $delta = 0
    foreach ($key in $baselines.Keys) {
        $delta += $maxima[$key] - $baselines[$key]
    }
    return $delta
}

function Get-ScaleEvents {
    param([Parameter(Mandatory)] [object[]] $Samples)

    $events = @()
    for ($i = 1; $i -lt $Samples.Count; $i++) {
        $previous = $Samples[$i - 1].Replicas
        $current = $Samples[$i].Replicas
        if ($current -eq $previous) {
            continue
        }

        $direction = "up"
        if ($current -lt $previous) {
            $direction = "down"
        }

        $events += [pscustomobject]@{
            At        = $Samples[$i].Timestamp
            From      = $previous
            To        = $current
            Direction = $direction
        }
    }

    # Unary comma: without it an empty result is dropped by the pipeline and a
    # single event is unwrapped to a bare object, so the caller would have to
    # handle three shapes instead of one array.
    return , $events
}

# The last point at which utilization was at or above target, i.e. the moment
# the scale-down stabilization window starts running. Null when the workload was
# never observed at or above target, which means no scale-down delay can be
# attributed to the window.
function Get-LastAtOrAboveTarget {
    param([Parameter(Mandatory)] [object[]] $Samples)

    $last = $null
    foreach ($sample in $Samples) {
        if ($null -ne $sample.UtilizationPercent -and $sample.UtilizationPercent -ge $sample.TargetPercent) {
            $last = $sample
        }
    }

    return $last
}

# Reduces the raw samples to the facts the assertions are written against.
#
# Sorted by timestamp first: the caller appends samples in collection order, and
# a retried or out-of-order read would otherwise be scored as a scale event.
function Get-AutoscalingTimeline {
    param(
        [Parameter(Mandatory)] [object[]] $Samples,
        [Parameter(Mandatory)] [int] $MinReplicas,
        [Parameter(Mandatory)] [int] $MaxReplicas
    )

    if ($Samples.Count -lt 2) {
        throw "An autoscaling timeline needs at least 2 samples to contain a transition; got $($Samples.Count)."
    }

    $ordered = @($Samples | Sort-Object -Property Timestamp)
    # Assigned without an @() wrapper: Get-ScaleEvents already returns the array
    # itself (see the unary comma there), and re-wrapping it would produce an
    # array holding one array rather than the events.
    $scaleEvents = Get-ScaleEvents -Samples $ordered
    $scaleUps = @($scaleEvents | Where-Object { $_.Direction -eq "up" })
    $scaleDowns = @($scaleEvents | Where-Object { $_.Direction -eq "down" })

    $peak = ($ordered | Measure-Object -Property Replicas -Maximum).Maximum
    $restartDelta = Get-RestartDelta -Samples $ordered

    # Availability during the run is measured as ready pods, not scheduled pods.
    # The floor is what the platform promises; a scale event that leaves fewer
    # than MinReplicas pods serving has broken it regardless of replica count.
    $minReadyObserved = ($ordered | Measure-Object -Property ReadyReplicas -Minimum).Minimum

    # A `<unknown>` metric in the first sample is expected and not counted: the
    # HPA needs one metrics-server scrape interval after it is created before it
    # can report anything.
    $unknownAfterFirst = @($ordered | Select-Object -Skip 1 | Where-Object { $null -eq $_.UtilizationPercent }).Count

    # ScalingActive is the autoscaler stating that it computed a desired replica
    # count from the metric and wrote it to the scale subresource. It is what
    # attributes the replica changes below to the HPA rather than to whatever
    # else can resize a Deployment. The first sample is excluded for the same
    # reason as the metric: an HPA reports FailedGetResourceMetric until its
    # first scrape lands.
    $afterFirst = @($ordered | Select-Object -Skip 1)
    $scalingActiveTrue = @($afterFirst | Where-Object { $_.ScalingActiveStatus -eq "True" }).Count
    $scalingActiveNotTrue = $afterFirst.Count - $scalingActiveTrue

    # Time from the end of the load to the first pod actually being removed.
    # This is the observed stabilization window, and the only part of `behavior`
    # that a structural check cannot prove.
    $lastAtOrAboveTarget = Get-LastAtOrAboveTarget -Samples $ordered
    $observedScaleDownDelaySeconds = $null
    $firstScaleDown = $scaleDowns | Select-Object -First 1
    if ($null -ne $lastAtOrAboveTarget -and $null -ne $firstScaleDown -and $firstScaleDown.At -gt $lastAtOrAboveTarget.Timestamp) {
        $observedScaleDownDelaySeconds = [int] [math]::Round(($firstScaleDown.At - $lastAtOrAboveTarget.Timestamp).TotalSeconds)
    }

    return [pscustomobject]@{
        SampleCount                   = $ordered.Count
        StartTime                     = $ordered[0].Timestamp
        EndTime                       = $ordered[-1].Timestamp
        MinReplicas                   = $MinReplicas
        MaxReplicas                   = $MaxReplicas
        BaselineReplicas              = $ordered[0].Replicas
        PeakReplicas                  = $peak
        FinalReplicas                 = $ordered[-1].Replicas
        MinReadyObserved              = $minReadyObserved
        ScaleEvents                   = $scaleEvents
        ScaleUpCount                  = $scaleUps.Count
        ScaleDownCount                = $scaleDowns.Count
        PeakUtilizationPercent        = ($ordered | Where-Object { $null -ne $_.UtilizationPercent } |
            Measure-Object -Property UtilizationPercent -Maximum).Maximum
        UnknownMetricSamples          = $unknownAfterFirst
        ScalingActiveTrueSamples      = $scalingActiveTrue
        ScalingActiveNotTrueSamples   = $scalingActiveNotTrue
        RestartDelta                  = $restartDelta
        ObservedScaleDownDelaySeconds = $observedScaleDownDelaySeconds
        Samples                       = $ordered
    }
}

# The acceptance criteria of #153, one Confirm-Condition each.
#
# ScaleDownGraceSeconds exists because the sampling interval quantizes the
# observed delay: a pod removed 299s after the load stopped, seen by a sampler
# running every 15s, is the 300s window working. The grace is subtracted from
# the expected window, never added to it, so a window that is genuinely too
# short still fails.
function Confirm-AutoscalingBehavior {
    param(
        [Parameter(Mandatory)] $Timeline,
        [Parameter(Mandatory)] [int] $ExpectedScaleDownWindowSeconds,
        [int] $ScaleDownGraceSeconds = 30,
        # Off by default: proving the return to the floor requires waiting out
        # the stabilization window plus one scale-down step per replica, so a
        # run that only exercises scale-up opts out rather than failing on a
        # timeline it never intended to collect.
        [switch] $RequireReturnToFloor
    )

    if ($ExpectedScaleDownWindowSeconds -le 0) {
        throw "ExpectedScaleDownWindowSeconds must be positive; got $ExpectedScaleDownWindowSeconds."
    }
    if ($ScaleDownGraceSeconds -lt 0 -or $ScaleDownGraceSeconds -ge $ExpectedScaleDownWindowSeconds) {
        throw "ScaleDownGraceSeconds ($ScaleDownGraceSeconds) must be non-negative and smaller than the configured stabilization window ($ExpectedScaleDownWindowSeconds)."
    }

    Confirm-Condition `
        -Condition ($Timeline.UnknownMetricSamples -eq 0) `
        -SuccessMessage "the HPA reported a CPU utilization value in every sample after the first (peak $($Timeline.PeakUtilizationPercent)% against a $($Timeline.Samples[0].TargetPercent)% target)" `
        -FailureMessage "the HPA reported <unknown> in $($Timeline.UnknownMetricSamples) of $($Timeline.SampleCount) samples. An HPA that cannot read its metric does not scale at all, so the rest of this run proves nothing; check that metrics-server is installed and Available"

    # Ordered before the replica assertions on purpose: without this, a run that
    # scaled for some other reason - a rollout, a manual `kubectl scale`, a
    # second controller - reads exactly like a working autoscaler.
    Confirm-Condition `
        -Condition ($Timeline.ScalingActiveNotTrueSamples -eq 0 -and $Timeline.ScalingActiveTrueSamples -gt 0) `
        -SuccessMessage "the HPA reported ScalingActive=True in all $($Timeline.ScalingActiveTrueSamples) samples after the first, so it was the autoscaler that calculated and applied the replica counts below" `
        -FailureMessage "the HPA did not report ScalingActive=True in $($Timeline.ScalingActiveNotTrueSamples) of the $($Timeline.SampleCount - 1) samples after the first. ScalingActive=False means the HPA computed no desired replica count, so any replica change in this run came from something else - a rollout, a manual scale, or another controller - and proves nothing about the autoscaler. Check 'kubectl describe hpa' for the condition's reason"

    Confirm-Condition `
        -Condition ($Timeline.PeakReplicas -gt $Timeline.BaselineReplicas) `
        -SuccessMessage "replicas rose under load, from $($Timeline.BaselineReplicas) to a peak of $($Timeline.PeakReplicas)" `
        -FailureMessage "replicas never rose above the baseline of $($Timeline.BaselineReplicas). Either the load did not push utilization past the target (peak observed: $($Timeline.PeakUtilizationPercent)%) or the autoscaler did not act on it"

    Confirm-Condition `
        -Condition ($Timeline.PeakReplicas -le $Timeline.MaxReplicas) `
        -SuccessMessage "the replica count stayed within the maxReplicas ceiling of $($Timeline.MaxReplicas)" `
        -FailureMessage "the workload reached $($Timeline.PeakReplicas) replicas, above the maxReplicas ceiling of $($Timeline.MaxReplicas). The ceiling is a downstream-capacity decision from docs/architecture/autoscaling-strategy.md, not a soft target"

    Confirm-Condition `
        -Condition ($Timeline.MinReadyObserved -ge $Timeline.MinReplicas) `
        -SuccessMessage "at least $($Timeline.MinReplicas) pods were Ready in every sample, including during scale events" `
        -FailureMessage "only $($Timeline.MinReadyObserved) pods were Ready at the worst sample, below the minReplicas floor of $($Timeline.MinReplicas). A scale event is not allowed to take the service below the availability floor it starts from"

    Confirm-Condition `
        -Condition ($Timeline.RestartDelta -eq 0) `
        -SuccessMessage "no container restarted during the run" `
        -FailureMessage "container restarts increased by $($Timeline.RestartDelta) during the run. A restart under load means the scale event did not keep the existing pods healthy - check the liveness probe timings and memory limits before trusting any other result here"

    if (-not $RequireReturnToFloor) {
        return
    }

    Confirm-Condition `
        -Condition ($Timeline.ScaleDownCount -gt 0) `
        -SuccessMessage "the autoscaler scaled the workload back down after the load stopped" `
        -FailureMessage "no scale-down was observed. Either the run ended before the $ExpectedScaleDownWindowSeconds-second stabilization window elapsed, or utilization never fell below target"

    Confirm-Condition `
        -Condition ($Timeline.FinalReplicas -eq $Timeline.MinReplicas) `
        -SuccessMessage "the workload returned to the minReplicas floor of $($Timeline.MinReplicas)" `
        -FailureMessage "the workload settled at $($Timeline.FinalReplicas) replicas rather than the minReplicas floor of $($Timeline.MinReplicas). Scaling in that stops short of the floor leaves capacity allocated that nothing is using"

    $threshold = $ExpectedScaleDownWindowSeconds - $ScaleDownGraceSeconds
    if ($null -eq $Timeline.ObservedScaleDownDelaySeconds) {
        $scaleDownDelayFailureMessage = "no scale-down delay could be computed because no qualifying sample existed or no scale-down occurred during the run. Either the run ended before the ${ExpectedScaleDownWindowSeconds}s stabilization window elapsed, or utilization never fell below target"
    } else {
        $scaleDownDelayFailureMessage = "the first scale-down came $($Timeline.ObservedScaleDownDelaySeconds)s after utilization last sat at or above target, short of the configured ${ExpectedScaleDownWindowSeconds}s stabilization window (minus ${ScaleDownGraceSeconds}s of sampling grace). A window that does not hold turns a GC or JIT dip into a scale-in"
    }
    Confirm-Condition `
        -Condition ($null -ne $Timeline.ObservedScaleDownDelaySeconds -and $Timeline.ObservedScaleDownDelaySeconds -ge $threshold) `
        -SuccessMessage "the first scale-down came $($Timeline.ObservedScaleDownDelaySeconds)s after utilization last sat at or above target, consistent with the configured ${ExpectedScaleDownWindowSeconds}s stabilization window" `
        -FailureMessage $scaleDownDelayFailureMessage
}

# Renders the timeline in the same shape as the recorded run in
# infrastructure/kubernetes/ingestion-service/hpa-runtime-verification.md, so a
# report produced by the harness can be pasted next to the earlier ones and read
# the same way.
function Format-AutoscalingTimeline {
    param(
        [Parameter(Mandatory)] $Timeline,
        # Annotations keyed by the sample timestamp, e.g. "<- load starts".
        [hashtable] $Markers = @{}
    )

    $lines = @()
    foreach ($sample in $Timeline.Samples) {
        $utilization = "<unknown>"
        if ($null -ne $sample.UtilizationPercent) {
            $utilization = "$($sample.UtilizationPercent)%"
        }

        # Rendered per sample rather than only summarised, so the recorded run is
        # evidence that the autoscaler was live throughout it and not merely at
        # the moment the verdict was computed.
        $scalingActive = "<none>"
        if (-not [string]::IsNullOrWhiteSpace($sample.ScalingActiveStatus)) {
            $scalingActive = $sample.ScalingActiveStatus
        }

        $line = "{0} | cpu: {1,9}/{2}%  {3}  {4}  {5} | ready={6} scalingActive={7}" -f `
            $sample.Timestamp.ToString("HH:mm:ssZ"),
            $utilization,
            $sample.TargetPercent,
            $Timeline.MinReplicas,
            $Timeline.MaxReplicas,
            $sample.Replicas,
            $sample.ReadyReplicas,
            $scalingActive

        $marker = $Markers[$sample.Timestamp]
        if (-not [string]::IsNullOrWhiteSpace($marker)) {
            $line = "$line    $marker"
        }

        $lines += $line
    }

    return ($lines -join [Environment]::NewLine)
}

Export-ModuleMember -Function New-AutoscalingSample, Get-ScaleEvents, Get-LastAtOrAboveTarget, Get-AutoscalingTimeline, Confirm-AutoscalingBehavior, Format-AutoscalingTimeline
