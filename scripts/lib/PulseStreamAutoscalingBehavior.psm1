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

# One metric of an HPA as read at one instant: what the metric currently is and
# what the HPA is configured to hold it at.
#
# Both values are plain numbers in whatever unit the metric uses (percent for a
# Utilization target, a resource quantity converted to its base unit for an
# AverageValue one). Only their ratio is ever used, so the unit does not need to
# be carried, but the two values of a single reading must share it.
#
# CurrentValue is nullable for the same reason UtilizationPercent is: an HPA
# that cannot read a metric reports `<unknown>`, which is not zero.
function New-AutoscalingMetricReading {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [double] $TargetValue,
        [nullable[double]] $CurrentValue = $null
    )

    if ($TargetValue -le 0) {
        throw "Metric '$Name' has a target of $TargetValue. An HPA target is the denominator of the desired-replica calculation and must be positive."
    }

    return [pscustomobject]@{
        Name         = $Name
        TargetValue  = $TargetValue
        CurrentValue = $CurrentValue
    }
}

# Kubernetes resource quantities as a plain number, so that metric targets
# written as "100m", "1500", or "2Ki" can be divided by each other.
#
# Only the ratio of a current value to its target is ever used, so any consistent
# base unit works; this returns the value in the metric's own base unit (cores,
# bytes, requests, ...) with the SI and binary suffixes applied.
function ConvertFrom-KubernetesQuantity {
    param([Parameter(Mandatory)] [string] $Quantity)

    $text = $Quantity.Trim()
    if ($text -notmatch '^(?<number>[+-]?[0-9.]+(?:[eE][+-]?[0-9]+)?)(?<suffix>[a-zA-Z]*)$') {
        throw "'$Quantity' is not a Kubernetes quantity. The HPA metric it came from cannot be turned into a desired-replica calculation."
    }

    $number = [double]::Parse($Matches["number"], [System.Globalization.CultureInfo]::InvariantCulture)
    $suffix = $Matches["suffix"]

    # -CaseSensitive is load-bearing, not style: "m" is milli and "M" is mega,
    # and a PowerShell hashtable would fold them onto one key. A memory target of
    # 512M read as 512m is a ratio wrong by nine orders of magnitude.
    $multiplier = switch -CaseSensitive ($suffix) {
        "" { 1.0 }
        "n" { 1e-9 }
        "u" { 1e-6 }
        "m" { 1e-3 }
        "k" { 1e3 }
        "M" { 1e6 }
        "G" { 1e9 }
        "T" { 1e12 }
        "P" { 1e15 }
        "E" { 1e18 }
        "Ki" { 1024.0 }
        "Mi" { 1048576.0 }
        "Gi" { 1073741824.0 }
        "Ti" { 1099511627776.0 }
        "Pi" { 1125899906842624.0 }
        "Ei" { 1152921504606846976.0 }
        default { throw "Quantity '$Quantity' carries the unrecognised suffix '$suffix'." }
    }

    return $number * [double] $multiplier
}

# The metric readings of an applied HPA, paired spec target against status
# current, for every metric EXCEPT the CPU utilization one that
# New-AutoscalingSample builds from its own parameters.
#
# Pure: it takes the two JSON fragments, not a cluster. The HPA's desired replica
# count is the maximum across all of its metrics, so a validator that samples
# only CPU on a multi-metric HPA can conclude the autoscaler wanted to scale in
# when it did not.
#
# A configured metric with no reading in status yields a reading with a null
# CurrentValue rather than being dropped: "the HPA cannot see this metric" has to
# reach Get-HpaScaleRecommendation, which refuses to call anything a scale-in
# recommendation while a metric is unreadable.
function Get-HpaMetricReadings {
    param(
        [object[]] $SpecMetrics = @(),
        [object[]] $CurrentMetrics = @()
    )

    $readings = @()
    foreach ($spec in @($SpecMetrics)) {
        if ($null -eq $spec) {
            continue
        }

        $type = [string] $spec.type
        # Identity of a metric within one HPA: type, plus the name of whatever
        # the type keys on. Two Pods metrics differ only by metric name, and two
        # ContainerResource metrics only by container.
        switch ($type) {
            "Resource" { $body = $spec.resource; $name = [string] $spec.resource.name }
            "ContainerResource" { $body = $spec.containerResource; $name = "$($spec.containerResource.name)/$($spec.containerResource.container)" }
            "Pods" { $body = $spec.pods; $name = [string] $spec.pods.metric.name }
            "Object" { $body = $spec.object; $name = [string] $spec.object.metric.name }
            "External" { $body = $spec.external; $name = [string] $spec.external.metric.name }
            default { throw "The applied HPA carries a metric of unsupported type '$type'. This validator computes the HPA's own desired replica count, and cannot do that for a metric it does not understand" }
        }

        # Which field the target uses decides which status field it must be read
        # against: an averageUtilization target compared against an averageValue
        # reading is a ratio between two different units.
        $field = $null
        $target = $null
        foreach ($candidate in @("averageUtilization", "averageValue", "value")) {
            if ($null -ne $body.target.$candidate) {
                $field = $candidate
                $target = $body.target.$candidate
                break
            }
        }
        if ($null -eq $field) {
            throw "Metric '$name' of type '$type' in the applied HPA has no averageUtilization, averageValue, or value target."
        }

        if ($type -eq "Resource" -and $name -eq "cpu" -and $field -eq "averageUtilization") {
            # Carried by the sample itself; see New-AutoscalingSample.
            continue
        }

        $current = $null
        foreach ($status in @($CurrentMetrics)) {
            if ($null -eq $status -or [string] $status.type -ne $type) {
                continue
            }

            switch ($type) {
                "Resource" { $statusBody = $status.resource; $statusName = [string] $status.resource.name }
                "ContainerResource" { $statusBody = $status.containerResource; $statusName = "$($status.containerResource.name)/$($status.containerResource.container)" }
                "Pods" { $statusBody = $status.pods; $statusName = [string] $status.pods.metric.name }
                "Object" { $statusBody = $status.object; $statusName = [string] $status.object.metric.name }
                "External" { $statusBody = $status.external; $statusName = [string] $status.external.metric.name }
            }

            if ($statusName -ne $name) {
                continue
            }
            if ($null -ne $statusBody.current.$field) {
                $current = $statusBody.current.$field
            }
            break
        }

        $targetValue = if ($field -eq "averageUtilization") { [double] $target } else { ConvertFrom-KubernetesQuantity -Quantity ([string] $target) }
        $currentValue = $null
        if ($null -ne $current) {
            $currentValue = if ($field -eq "averageUtilization") { [double] $current } else { ConvertFrom-KubernetesQuantity -Quantity ([string] $current) }
        }

        $readings += New-AutoscalingMetricReading `
            -Name "$($type.ToLowerInvariant())/$name ($field)" `
            -TargetValue $targetValue `
            -CurrentValue $currentValue
    }

    return , $readings
}

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
        [string] $ScalingActiveStatus = $null,
        # Every metric the HPA is configured with BESIDES the CPU utilization
        # one, which is built from TargetPercent/UtilizationPercent above.
        #
        # These are not decoration: the HPA's desired replica count is the
        # maximum of the per-metric proposals, so a second metric still asking
        # for the current replica count is the difference between "the
        # autoscaler wants to scale in" and "it does not". Judging the
        # stabilization window on CPU alone, on an HPA that also scales on
        # requests-per-second, measures a window that never started.
        [object[]] $AdditionalMetrics = @(),
        # How many Pods of the workload the metrics pipeline actually had a
        # reading for at this instant, or null when the sampler could not find
        # out. The HPA averages only the Pods it has a metric for, and reports
        # that average in status BEFORE the conservative substitutions it makes
        # for the Pods it does not - so without this count, a status average can
        # be divided by more Pods than produced it. See
        # Get-HpaScaleRecommendation.
        [nullable[int]] $MetricPodCount = $null
    )

    $metrics = @(New-AutoscalingMetricReading `
            -Name "cpu utilization" `
            -TargetValue $TargetPercent `
            -CurrentValue $UtilizationPercent)
    foreach ($metric in @($AdditionalMetrics)) {
        if ($null -eq $metric) {
            continue
        }
        $metrics += $metric
    }

    return [pscustomobject]@{
        Timestamp           = $Timestamp.ToUniversalTime()
        Replicas            = $Replicas
        ReadyReplicas       = $ReadyReplicas
        TargetPercent       = $TargetPercent
        UtilizationPercent  = $UtilizationPercent
        RestartCounts       = $RestartCounts
        ScalingActiveStatus = $ScalingActiveStatus
        Metrics             = $metrics
        MetricPodCount      = $MetricPodCount
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

# An UPPER BOUND on the replica count the HPA would compute from one sample, and
# whether even that bound is a scale-in.
#
# The naive form of this is the arithmetic everyone quotes:
#
#   desiredReplicas = ceil(currentReplicas * currentMetricValue / targetValue)
#
# evaluated per metric, with the maximum taken across metrics and the result
# clamped into [minReplicas, maxReplicas]. A ratio within the controller's
# tolerance of 1.0 (kube-controller-manager's
# --horizontal-pod-autoscaler-tolerance, 0.1 by default) is treated as "no
# change" and proposes the current count.
#
# Utilization below the target is NOT the same as a scale-in recommendation, and
# that gap is the first reason this function exists. At 6 replicas and 69%
# against a 70% target the ratio is inside the tolerance and the proposal is
# still 6; even at 62% it is ceil(6 * 62 / 70) = 6. The first count below 6
# arrives at 58%. Anchoring the stabilization window to "utilization dropped
# under target" would start the clock minutes before the HPA had any lower
# number to stabilize, and accept a window far shorter than the configured one.
#
# The second reason is that the naive form is not what the controller runs when
# some Pods are unready or missing a metric, and `status.currentMetrics` reports
# the average from BEFORE those adjustments. `replica_calculator.go` averages
# only the Pods that are ready AND have a metric, publishes exactly that number,
# and then:
#
#   * divides by the number of Pods it averaged (readyPodCount), not by
#     currentReplicas;
#   * on the way down, substitutes the full target for every Pod whose metric is
#     missing, which pulls the ratio back towards 1;
#   * re-checks the tolerance on the adjusted ratio, and abandons the change
#     entirely if the adjustment flipped the direction of the scale.
#
# Nothing in the HPA's status says which of "unready" or "missing a metric"
# applies to the Pods the average left out, and the two lead to different
# numbers. So both worlds are evaluated and the LARGER proposal is taken. The
# result is an upper bound on the controller's own recommendation, which makes
# RecommendsDownscale one-sided in the only direction that matters here: it is
# never true unless the controller would have recommended a scale-in too. An
# over-eager scale-in recommendation would anchor the stabilization window early
# and pass a window that never held.
#
# Worked example, from the run that prompted this: 4 replicas, 3 of them Ready,
# CPU 50% against a 70% target. The naive form proposes ceil(4 * 50/70) = 3 and
# calls it a scale-in. The controller, treating the fourth Pod as missing a
# metric, computes (0.714*3 + 1)/4 = 0.786 and ceil(0.786 * 4) = 4 - no scale-in
# at all.
#
# Null DesiredReplicas means the HPA had no computable recommendation for this
# sample - a metric read `<unknown>`, the workload reported zero replicas, or no
# Pod was both Ready and reporting. That is deliberately not folded into
# "recommends a scale-in": a controller with nothing to average does not scale
# down.
function Get-HpaScaleRecommendation {
    param(
        [Parameter(Mandatory)] $Sample,
        [Parameter(Mandatory)] [int] $MinReplicas,
        [Parameter(Mandatory)] [int] $MaxReplicas,
        [double] $Tolerance = 0.1
    )

    $current = [int] $Sample.Replicas
    if ($current -le 0) {
        return [pscustomobject]@{
            DesiredReplicas     = $null
            RecommendsDownscale = $false
            Detail              = "the workload reported 0 replicas, so the HPA had nothing to scale"
        }
    }

    # The most Pods the reported average can have been taken over. The
    # Deployment's readyReplicas bounds it (the controller drops unready Pods),
    # and the metrics pipeline's own Pod count bounds it again when the sampler
    # managed to read one.
    $measured = [math]::Min([int] $Sample.ReadyReplicas, $current)
    if ($null -ne $Sample.MetricPodCount) {
        $measured = [math]::Min($measured, [int] $Sample.MetricPodCount)
    }
    if ($measured -le 0) {
        return [pscustomobject]@{
            DesiredReplicas     = $null
            RecommendsDownscale = $false
            Detail              = "no Pod was both Ready and reporting a metric, so the HPA had nothing to average and computed no desired replica count"
        }
    }
    $unmeasured = $current - $measured

    $desired = $null
    $details = @()
    foreach ($metric in @($Sample.Metrics)) {
        if ($null -eq $metric.CurrentValue) {
            return [pscustomobject]@{
                DesiredReplicas     = $null
                RecommendsDownscale = $false
                Detail              = "metric '$($metric.Name)' read <unknown>, so the HPA computed no desired replica count"
            }
        }

        $ratio = [double] $metric.CurrentValue / [double] $metric.TargetValue

        # World one: every unmeasured Pod is unready. The controller drops them
        # from the average and from the divisor alike, so the proposal is the
        # published ratio applied to the Pods that reported.
        if ([math]::Abs($ratio - 1.0) -le $Tolerance) {
            # Inside the tolerance band the controller skips scaling entirely,
            # so this metric asks for exactly what is already running.
            $unreadyWorld = $current
        } else {
            $unreadyWorld = [int] [math]::Ceiling($ratio * $measured)
        }

        # World two: every unmeasured Pod is missing its metric. The controller
        # fills each one in - at the target on the way down, at zero on the way
        # up - and then divides by the whole Pod set.
        if ($unmeasured -eq 0) {
            $missingWorld = $unreadyWorld
        } else {
            $substitute = 0.0
            if ($ratio -lt 1.0) {
                $substitute = 1.0
            }
            $adjusted = (($ratio * $measured) + ($substitute * $unmeasured)) / $current

            $flipped = ($ratio -lt 1.0 -and $adjusted -gt 1.0) -or ($ratio -gt 1.0 -and $adjusted -lt 1.0)
            if ([math]::Abs($adjusted - 1.0) -le $Tolerance -or $flipped) {
                # The substitution either erased the change or reversed its
                # direction; the controller then keeps what is running.
                $missingWorld = $current
            } else {
                $missingWorld = [int] [math]::Ceiling($adjusted * $current)
                if (($adjusted -lt 1.0 -and $missingWorld -gt $current) -or ($adjusted -gt 1.0 -and $missingWorld -lt $current)) {
                    $missingWorld = $current
                }
            }
        }

        # The upper bound across the two worlds. Under-reading the controller
        # here would invent a scale-in recommendation it never made.
        $proposal = [math]::Max($unreadyWorld, $missingWorld)

        $details += "$($metric.Name) $($metric.CurrentValue)/$($metric.TargetValue) -> $proposal"
        if ($null -eq $desired -or $proposal -gt $desired) {
            $desired = $proposal
        }
    }

    if ($null -eq $desired) {
        return [pscustomobject]@{
            DesiredReplicas     = $null
            RecommendsDownscale = $false
            Detail              = "the sample carried no metric readings"
        }
    }

    # The HPA never recommends outside its own bounds, so a workload sitting at
    # the floor is not "recommending a scale-in" no matter how idle it is.
    $desired = [math]::Max($MinReplicas, [math]::Min($MaxReplicas, $desired))

    return [pscustomobject]@{
        DesiredReplicas     = $desired
        RecommendsDownscale = ($desired -lt $current)
        Detail              = "$current replicas ($measured of them measured), $($details -join '; '), clamped to [$MinReplicas, $MaxReplicas] -> $desired"
    }
}

# The first sample of the unbroken run of scale-in recommendations that ends at
# $Before, i.e. the earliest observed moment at which the stabilization window
# could have started running.
#
# Only the run immediately preceding the scale-in counts. A recommendation that
# dips and recovers restarts the window - the controller stabilizes on the
# MAXIMUM recommendation within the window - so an earlier, interrupted dip says
# nothing about the window that produced this scale-in.
#
# The anchor is the first sample that recommends the scale-in rather than the
# last one that does not, which understates the delay by up to one sampling
# interval: the recommendation may have turned over at any point between the two
# samples. Understating is the safe direction, and the caller's sampling grace is
# sized to exactly that quantization.
#
# Null when no sample before $Before recommended a scale-in at all, which means
# the workload was scaled in while the HPA still wanted at least the replicas it
# had - a result no stabilization window explains.
function Get-DownscaleRecommendationStart {
    param(
        [Parameter(Mandatory)] [object[]] $Samples,
        [Parameter(Mandatory)] [int] $MinReplicas,
        [Parameter(Mandatory)] [int] $MaxReplicas,
        [Parameter(Mandatory)] [datetime] $Before,
        [double] $Tolerance = 0.1
    )

    $anchor = $null
    foreach ($sample in $Samples) {
        if ($sample.Timestamp -ge $Before) {
            break
        }

        $recommendation = Get-HpaScaleRecommendation `
            -Sample $sample `
            -MinReplicas $MinReplicas `
            -MaxReplicas $MaxReplicas `
            -Tolerance $Tolerance
        if ($recommendation.RecommendsDownscale) {
            # Keep the earliest sample of the current run; any later run of
            # scale-in recommendations starts over below.
            if ($null -eq $anchor) {
                $anchor = $sample
            }
        } else {
            $anchor = $null
        }
    }

    return $anchor
}

# Reduces the raw samples to the facts the assertions are written against.
#
# Sorted by timestamp first: the caller appends samples in collection order, and
# a retried or out-of-order read would otherwise be scored as a scale event.
function Get-AutoscalingTimeline {
    param(
        [Parameter(Mandatory)] [object[]] $Samples,
        [Parameter(Mandatory)] [int] $MinReplicas,
        [Parameter(Mandatory)] [int] $MaxReplicas,
        # kube-controller-manager's --horizontal-pod-autoscaler-tolerance. It is
        # a parameter rather than a constant because a cluster that runs a
        # different tolerance computes different recommendations, and this
        # module's whole claim is that it reproduces the controller's arithmetic.
        [double] $Tolerance = 0.1
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

    # The most capacity that was ever actually serving at one instant. Capped at
    # the sample's own replica count so a Pod that is still Ready while it
    # terminates cannot make a scale-up look larger than it was. Compared
    # against PeakReplicas, this is what separates "the autoscaler added four
    # Pods" from "the autoscaler asked for four Pods and the cluster ran three".
    $peakReadyObserved = 0
    foreach ($sample in $ordered) {
        $serving = [math]::Min([int] $sample.ReadyReplicas, [int] $sample.Replicas)
        if ($serving -gt $peakReadyObserved) {
            $peakReadyObserved = $serving
        }
    }

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

    # Time from the HPA first recommending fewer replicas to the first pod
    # actually being removed. This is the observed stabilization window, and the
    # only part of `behavior` that a structural check cannot prove.
    #
    # Measured from the recommendation and not from the end of the load or from
    # utilization crossing the target: the controller stabilizes recommendations,
    # so those are the wrong clocks. See Get-HpaScaleRecommendation.
    $firstScaleDown = $scaleDowns | Select-Object -First 1
    $downscaleRecommendedFrom = $null
    $downscaleRecommendationDetail = $null
    $observedScaleDownDelaySeconds = $null
    $downscaleRecommendationGapSeconds = $null
    if ($null -ne $firstScaleDown) {
        $downscaleRecommendedFrom = Get-DownscaleRecommendationStart `
            -Samples $ordered `
            -MinReplicas $MinReplicas `
            -MaxReplicas $MaxReplicas `
            -Before $firstScaleDown.At `
            -Tolerance $Tolerance
        if ($null -ne $downscaleRecommendedFrom) {
            $downscaleRecommendationDetail = (Get-HpaScaleRecommendation `
                    -Sample $downscaleRecommendedFrom `
                    -MinReplicas $MinReplicas `
                    -MaxReplicas $MaxReplicas `
                    -Tolerance $Tolerance).Detail
            $observedScaleDownDelaySeconds = [int] [math]::Round(($firstScaleDown.At - $downscaleRecommendedFrom.Timestamp).TotalSeconds)

            # The one interval the observed delay is genuinely uncertain over:
            # the recommendation turned over somewhere between the sample before
            # the anchor and the anchor itself, so the true window can be up to
            # that gap LONGER than what was measured. Zero when the anchor is
            # the first sample of the run, where there is no earlier sample the
            # recommendation could have turned over in.
            #
            # Gaps anywhere else in the timeline are not uncertainty about this
            # measurement. See Get-ScaleDownSamplingGrace.
            $downscaleRecommendationGapSeconds = 0
            for ($i = 1; $i -lt $ordered.Count; $i++) {
                if ($ordered[$i].Timestamp -eq $downscaleRecommendedFrom.Timestamp) {
                    $downscaleRecommendationGapSeconds = [int] [math]::Ceiling(
                        ($ordered[$i].Timestamp - $ordered[$i - 1].Timestamp).TotalSeconds)
                    break
                }
            }
        }
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
        PeakReadyReplicas             = $peakReadyObserved
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
        DownscaleRecommendedAt        = $(if ($null -ne $downscaleRecommendedFrom) { $downscaleRecommendedFrom.Timestamp } else { $null })
        DownscaleRecommendationDetail = $downscaleRecommendationDetail
        DownscaleRecommendationGapSeconds = $downscaleRecommendationGapSeconds
        FirstScaleDownAt              = $(if ($null -ne $firstScaleDown) { $firstScaleDown.At } else { $null })
        Tolerance                     = $Tolerance
        Samples                       = $ordered
    }
}

# How much of the configured stabilization window the verdict is allowed to
# forgive, given how this particular run was sampled.
#
# The observed delay runs from the anchor sample to the scale-in sample, and is
# uncertain in exactly one direction: the recommendation turned over somewhere
# inside the gap that ENDS at the anchor, so the real window can be up to that
# gap longer than the measurement. Everything else about the sampling is either
# irrelevant to this measurement or biases it the other way (the scale-in
# happened at or before the sample that first saw it, which makes the observed
# delay too LONG, and is not forgiven).
#
# That is why the widest gap anywhere in the timeline is the wrong number. A run
# that stalled for 299s between two idle post-load samples, and then scaled in
# 60s after the recommendation turned over, has told us nothing about the 300s
# window - but a grace taken from the widest gap would forgive the entire window
# and pass it.
#
# The ceiling is the second guard. A grace worth more than half the window means
# the sampler was too coarse to say whether the window held at all, which is a
# run to reject rather than to pass on a technicality; the caller turns
# ExceedsCeiling into that rejection, and GraceSeconds stays capped either way so
# the value handed to Confirm-AutoscalingBehavior is always a legal one.
function Get-ScaleDownSamplingGrace {
    param(
        [Parameter(Mandatory)] $Timeline,
        # Grace the caller wants regardless of what the run did, normally
        # derived from the requested sampling interval.
        [Parameter(Mandatory)] [int] $RequestedGraceSeconds,
        [Parameter(Mandatory)] [int] $ExpectedScaleDownWindowSeconds
    )

    if ($ExpectedScaleDownWindowSeconds -le 0) {
        throw "ExpectedScaleDownWindowSeconds must be positive; got $ExpectedScaleDownWindowSeconds."
    }
    if ($RequestedGraceSeconds -lt 0) {
        throw "RequestedGraceSeconds must be non-negative; got $RequestedGraceSeconds."
    }

    $ceiling = [int] [math]::Floor($ExpectedScaleDownWindowSeconds / 2)
    $anchorGap = 0
    if ($null -ne $Timeline.DownscaleRecommendationGapSeconds) {
        $anchorGap = [int] $Timeline.DownscaleRecommendationGapSeconds
    }

    $uncapped = [math]::Max($RequestedGraceSeconds, $anchorGap)
    return [pscustomobject]@{
        GraceSeconds         = [math]::Min($uncapped, $ceiling)
        UncappedGraceSeconds = $uncapped
        AnchorGapSeconds     = $anchorGap
        CeilingSeconds       = $ceiling
        ExceedsCeiling       = ($uncapped -gt $ceiling)
    }
}

# The acceptance criteria of #153, one Confirm-Condition each.
#
# ScaleDownGraceSeconds exists because the sampling interval quantizes the
# observed delay: a pod removed 299s after the load stopped, seen by a sampler
# running every 15s, is the 300s window working. The grace is subtracted from
# the expected window, never added to it, so a window that is genuinely too
# short still fails. Get-ScaleDownSamplingGrace derives the value a run is
# entitled to.
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

    # A replica count is a request, not capacity. Pods that stay Pending for
    # want of a node, or that never pass their readiness probe, are counted by
    # `spec.replicas` and serve nothing - so a run that "scaled" 2 -> 6 while
    # Ready stayed at 2 has proved the HPA can write a number and nothing about
    # the platform's ability to absorb load.
    Confirm-Condition `
        -Condition ($Timeline.PeakReadyReplicas -ge $Timeline.PeakReplicas) `
        -SuccessMessage "all $($Timeline.PeakReplicas) replicas of the peak became Ready, so the capacity the autoscaler asked for was capacity the cluster actually served with" `
        -FailureMessage "the workload reached $($Timeline.PeakReplicas) replicas but never had more than $($Timeline.PeakReadyReplicas) of them Ready at once. Scaled-up Pods that stay Pending or fail readiness carry no traffic, so this is a scale-up the cluster did not deliver rather than one the autoscaler got right - check node CPU/memory headroom for $($Timeline.PeakReplicas) times the pod's requests, and the readiness probe, before reading anything else in this run"

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
        if ($null -eq $Timeline.FirstScaleDownAt) {
            $scaleDownDelayFailureMessage = "no scale-down delay could be computed because no scale-down occurred during the run. Either the run ended before the ${ExpectedScaleDownWindowSeconds}s stabilization window elapsed, or the HPA never recommended fewer replicas"
        } else {
            $scaleDownDelayFailureMessage = "the workload scaled in at $($Timeline.FirstScaleDownAt.ToString('HH:mm:ssZ')) without a single preceding sample in which the HPA's desired replica count was below the running one. No stabilization window explains that scale-in; check whether something other than the autoscaler resized the Deployment, or whether the sampling interval is coarse enough to have missed the recommendation entirely"
        }
    } else {
        $scaleDownDelayFailureMessage = "the first scale-down came $($Timeline.ObservedScaleDownDelaySeconds)s after the HPA first recommended fewer replicas ($($Timeline.DownscaleRecommendationDetail), at $($Timeline.DownscaleRecommendedAt.ToString('HH:mm:ssZ'))), short of the configured ${ExpectedScaleDownWindowSeconds}s stabilization window (minus ${ScaleDownGraceSeconds}s of sampling grace). A window that does not hold turns a GC or JIT dip into a scale-in"
    }
    Confirm-Condition `
        -Condition ($null -ne $Timeline.ObservedScaleDownDelaySeconds -and $Timeline.ObservedScaleDownDelaySeconds -ge $threshold) `
        -SuccessMessage "the first scale-down came $($Timeline.ObservedScaleDownDelaySeconds)s after the HPA first recommended fewer replicas ($($Timeline.DownscaleRecommendationDetail)), consistent with the configured ${ExpectedScaleDownWindowSeconds}s stabilization window" `
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

Export-ModuleMember -Function ConvertFrom-KubernetesQuantity, New-AutoscalingMetricReading, Get-HpaMetricReadings, New-AutoscalingSample, Get-ScaleEvents, Get-HpaScaleRecommendation, Get-DownscaleRecommendationStart, Get-AutoscalingTimeline, Get-ScaleDownSamplingGrace, Confirm-AutoscalingBehavior, Format-AutoscalingTimeline
