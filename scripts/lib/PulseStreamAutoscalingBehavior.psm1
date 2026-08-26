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
        [nullable[double]] $CurrentValue = $null,
        # Resource, container-resource, and Pods averages are calculated from
        # individual Pod readings. Their coverage is metric-specific: a CPU
        # scrape says nothing about which Pods a custom-metrics adapter saw.
        [bool] $RequiresPodMetricCoverage = $false,
        [nullable[int]] $MetricPodCount = $null,
        # Normalized value assigned to a Pod whose metric is missing during a
        # downscale calculation. Most per-Pod metrics use the target (1.0).
        # Resource utilization is special: Kubernetes uses max(100%, target)
        # of the Pod request, which is max(100, target)/target after normalizing.
        [double] $MissingPodFallbackRatio = 1.0
    )

    if ($TargetValue -le 0) {
        throw "Metric '$Name' has a target of $TargetValue. An HPA target is the denominator of the desired-replica calculation and must be positive."
    }

    return [pscustomobject]@{
        Name                      = $Name
        TargetValue               = $TargetValue
        CurrentValue              = $CurrentValue
        RequiresPodMetricCoverage = $RequiresPodMetricCoverage
        MetricPodCount            = $MetricPodCount
        MissingPodFallbackRatio   = $MissingPodFallbackRatio
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

        $requiresPodMetricCoverage = $type -in @("Resource", "ContainerResource", "Pods")
        $missingPodFallbackRatio = 1.0
        if ($requiresPodMetricCoverage -and $field -eq "averageUtilization") {
            $missingPodFallbackRatio = [math]::Max(100.0, $targetValue) / $targetValue
        }

        $readings += New-AutoscalingMetricReading `
            -Name "$($type.ToLowerInvariant())/$name ($field)" `
            -TargetValue $targetValue `
            -CurrentValue $currentValue `
            -RequiresPodMetricCoverage $requiresPodMetricCoverage `
            -MissingPodFallbackRatio $missingPodFallbackRatio
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
        # How many Pods metrics-server had a CPU reading for at this instant, or
        # null when the sampler could not find out. This count belongs only to
        # the CPU reading; custom metrics carry their own coverage state. The
        # HPA reports an average before conservative missing-Pod substitutions,
        # so unknown coverage cannot safely establish a downscale anchor.
        [Alias("MetricPodCount")] [nullable[int]] $CpuMetricPodCount = $null,
        # spec.replicas of the workload's scale subresource: the replica count
        # that has been REQUESTED of the workload, which is where the HPA writes
        # its decision. Deployment status.replicas (the Replicas parameter
        # above) can lag this by the whole rollout of the change, so scale
        # events are timestamped from this field when it was sampled. Null means
        # the sampler did not read the scale subresource; the two fields are
        # deliberately not collapsed into one.
        [nullable[int]] $ScaleDesiredReplicas = $null,
        # The HPA's own status at the same instant. desiredReplicas is the count
        # the HPA wants; lastScaleTime is the controller's own record of when it
        # last changed the target's scale. Together they are what attributes a
        # replica transition to the HPA: the transition's new count must match
        # the HPA's desired count AND lastScaleTime must have advanced across
        # the transition. Null means unsampled, which conservatively attributes
        # nothing.
        [nullable[int]] $HpaDesiredReplicas = $null,
        [nullable[int]] $HpaCurrentReplicas = $null,
        [nullable[datetime]] $HpaLastScaleTime = $null,
        # The reason of the HPA's AbleToScale condition, recorded verbatim
        # ("SucceededRescale", "ReadyForNewScale", "BackoffDownscale", ...).
        # Reported as supporting evidence only: the reason is overwritten by the
        # next reconcile, so its absence at a sample proves nothing.
        [string] $HpaAbleToScaleReason = $null
    )

    $metrics = @(New-AutoscalingMetricReading `
            -Name "cpu utilization" `
            -TargetValue $TargetPercent `
            -CurrentValue $UtilizationPercent `
            -RequiresPodMetricCoverage $true `
            -MetricPodCount $CpuMetricPodCount `
            -MissingPodFallbackRatio ([math]::Max(100.0, [double] $TargetPercent) / [double] $TargetPercent))
    foreach ($metric in @($AdditionalMetrics)) {
        if ($null -eq $metric) {
            continue
        }
        $metrics += $metric
    }

    $lastScaleTime = $null
    if ($null -ne $HpaLastScaleTime) {
        # PowerShell unwraps the nullable to a plain [datetime] on binding.
        $lastScaleTime = ([datetime] $HpaLastScaleTime).ToUniversalTime()
    }

    return [pscustomobject]@{
        Timestamp            = $Timestamp.ToUniversalTime()
        Replicas             = $Replicas
        ReadyReplicas        = $ReadyReplicas
        TargetPercent        = $TargetPercent
        UtilizationPercent   = $UtilizationPercent
        RestartCounts        = $RestartCounts
        ScalingActiveStatus  = $ScalingActiveStatus
        Metrics              = $metrics
        ScaleDesiredReplicas = $ScaleDesiredReplicas
        HpaDesiredReplicas   = $HpaDesiredReplicas
        HpaCurrentReplicas   = $HpaCurrentReplicas
        HpaLastScaleTime     = $lastScaleTime
        HpaAbleToScaleReason = $HpaAbleToScaleReason
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

# The replica count a sample proves was REQUESTED of the workload at that
# instant: the scale subresource's desired count when it was sampled, and
# Deployment status.replicas otherwise. The scale subresource is where the HPA
# writes its decision, so it moves at the decision; status.replicas moves when
# the rollout catches up, which can be many seconds later.
function Get-ObservedDesiredReplicas {
    param([Parameter(Mandatory)] $Sample)

    if ($null -ne $Sample.ScaleDesiredReplicas) {
        return [int] $Sample.ScaleDesiredReplicas
    }
    return [int] $Sample.Replicas
}

function Get-ScaleEvents {
    param([Parameter(Mandatory)] [object[]] $Samples)

    $events = @()
    for ($i = 1; $i -lt $Samples.Count; $i++) {
        $previous = Get-ObservedDesiredReplicas -Sample $Samples[$i - 1]
        $current = Get-ObservedDesiredReplicas -Sample $Samples[$i]
        if ($current -eq $previous) {
            continue
        }

        $direction = "up"
        if ($current -lt $previous) {
            $direction = "down"
        }

        $decisionSource = "status.replicas"
        if ($null -ne $Samples[$i].ScaleDesiredReplicas -and $null -ne $Samples[$i - 1].ScaleDesiredReplicas) {
            $decisionSource = "scale subresource"
        }

        # Attribution. ScalingActive=True says the HPA COULD compute a desired
        # count; it says nothing about who resized the workload, since a manual
        # `kubectl scale`, a rollout, or another controller changes the same
        # field while the HPA sits idle. A transition is credited to the HPA
        # only on the controller's own rescale evidence:
        #
        #   * the HPA's status.desiredReplicas equals the transition's new
        #     count - the HPA wanted exactly this many replicas; and
        #   * the HPA's status.lastScaleTime ADVANCED across the transition -
        #     the controller states it changed the target's scale in this
        #     interval. lastScaleTime values are compared only against each
        #     other, never against the sampler's clock, so clock skew between
        #     the harness and the control plane cannot manufacture or destroy
        #     an advance.
        #
        # The evidence may land one sample late: the HPA can rescale between
        # one sample's HPA read and its scale read, so that sample carries the
        # new scale count with the old HPA status. The next sample is therefore
        # also consulted - but only while the scale target still holds this
        # transition's count, because once it has moved on the newer evidence
        # belongs to a different transition. Anything less than this evidence
        # leaves the transition unattributed, which the verdict treats as a
        # failure: ambiguity must not credit the HPA.
        $baselineLastScale = $Samples[$i - 1].HpaLastScaleTime
        $attributed = $false
        $evidence = $null
        foreach ($j in @($i, ($i + 1))) {
            if ($j -ge $Samples.Count) {
                break
            }
            if ($j -gt $i -and (Get-ObservedDesiredReplicas -Sample $Samples[$j]) -ne $current) {
                break
            }

            $hpaDesired = $Samples[$j].HpaDesiredReplicas
            $lastScale = $Samples[$j].HpaLastScaleTime
            $advanced = ($null -ne $lastScale) -and (($null -eq $baselineLastScale) -or ($lastScale -gt $baselineLastScale))
            if ($null -ne $hpaDesired -and [int] $hpaDesired -eq $current -and $advanced) {
                $attributed = $true
                $evidence = "HPA desiredReplicas=$hpaDesired with lastScaleTime advanced to $($lastScale.ToString('HH:mm:ssZ')), read at the $($Samples[$j].Timestamp.ToString('HH:mm:ssZ')) sample"
                if (-not [string]::IsNullOrWhiteSpace($Samples[$j].HpaAbleToScaleReason)) {
                    $evidence = "$evidence (AbleToScale: $($Samples[$j].HpaAbleToScaleReason))"
                }
                break
            }
        }

        $events += [pscustomobject]@{
            At               = $Samples[$i].Timestamp
            # The last sample that still showed the old count. The decision
            # happened strictly after this instant, which is what makes it the
            # conservative end of the stabilization-window bound.
            PreviousSampleAt = $Samples[$i - 1].Timestamp
            From             = $previous
            To               = $current
            Direction        = $direction
            DecisionSource   = $decisionSource
            HpaAttributed    = $attributed
            HpaEvidence      = $evidence
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
#   * on the way down, substitutes the metric-specific fallback for every Pod
#     whose metric is missing. For CPU utilization that is max(100%, target)
#     of the Pod request, not merely the target;
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
# Worked example, from the review that prompted this: all 4 replicas are Ready,
# CPU is 40% against a 70% target, and only 3 Pods reported. The naive form
# proposes ceil(4 * 40/70) = 3. The controller fills the missing Pod at 100% of
# its request, or 100/70 of target: (0.571*3 + 1.429)/4 = 0.786, and
# ceil(0.786 * 4) = 4 - no scale-in at all.
#
# Null DesiredReplicas means the HPA had no computable recommendation for this
# sample - a metric read `<unknown>`, the workload reported zero replicas, or no
# Pod was both Ready and reporting. That is deliberately not folded into
# "recommends a scale-in": a controller with nothing to average does not scale
# down.
#
# UncoveredMetric names the metric when the reason was specifically that its
# per-Pod coverage was never sampled. That reason is a limit of this harness and
# not an observation about the cluster - the sampler obtains coverage for CPU
# alone - and it has to be told apart from the others, because it produces an
# identical timeline and needs completely different advice.
# Get-AutoscalingTimeline carries the name up so the verdict can say which of
# the two happened.
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
            UncoveredMetric     = $null
        }
    }

    $desired = $null
    $details = @()
    foreach ($metric in @($Sample.Metrics)) {
        if ($null -eq $metric.CurrentValue) {
            return [pscustomobject]@{
                DesiredReplicas     = $null
                RecommendsDownscale = $false
                Detail              = "metric '$($metric.Name)' read <unknown>, so the HPA computed no desired replica count"
                UncoveredMetric     = $null
            }
        }

        # Coverage belongs to this metric, not to the sample as a whole. CPU's
        # `kubectl top` count cannot be reused for a Pods/custom metric. When a
        # per-Pod metric's coverage is unknown, there is no safe way to recover
        # the controller's conservative missing-Pod adjustment from HPA status,
        # so this sample cannot establish a downscale anchor.
        if ($metric.RequiresPodMetricCoverage) {
            if ($null -eq $metric.MetricPodCount) {
                return [pscustomobject]@{
                    DesiredReplicas     = $null
                    RecommendsDownscale = $false
                    Detail              = "metric '$($metric.Name)' has unknown Pod coverage, so it cannot establish a downscale recommendation"
                    UncoveredMetric     = $metric.Name
                }
            }
            $measured = [math]::Min([int] $Sample.ReadyReplicas, $current)
            $measured = [math]::Min($measured, [int] $metric.MetricPodCount)
            if ($measured -le 0) {
                return [pscustomobject]@{
                    DesiredReplicas     = $null
                    RecommendsDownscale = $false
                    Detail              = "no Pod was both Ready and reporting metric '$($metric.Name)', so the HPA had nothing to average"
                    UncoveredMetric     = $null
                }
            }
        } else {
            # Object/external value metrics are not averages over a set of Pods.
            $measured = $current
        }
        $unmeasured = $current - $measured

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
                $substitute = [double] $metric.MissingPodFallbackRatio
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

        $details += "$($metric.Name) $($metric.CurrentValue)/$($metric.TargetValue) ($measured measured) -> $proposal"
        if ($null -eq $desired -or $proposal -gt $desired) {
            $desired = $proposal
        }
    }

    if ($null -eq $desired) {
        return [pscustomobject]@{
            DesiredReplicas     = $null
            RecommendsDownscale = $false
            Detail              = "the sample carried no metric readings"
            UncoveredMetric     = $null
        }
    }

    # The HPA never recommends outside its own bounds, so a workload sitting at
    # the floor is not "recommending a scale-in" no matter how idle it is.
    $desired = [math]::Max($MinReplicas, [math]::Min($MaxReplicas, $desired))

    return [pscustomobject]@{
        DesiredReplicas     = $desired
        RecommendsDownscale = ($desired -lt $current)
        Detail              = "$current replicas, $($details -join '; '), clamped to [$MinReplicas, $MaxReplicas] -> $desired"
        UncoveredMetric     = $null
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

    # Time from the HPA first recommending fewer replicas to the scale-down
    # decision. This is the observed stabilization window, and the only part of
    # `behavior` that a structural check cannot prove.
    #
    # Measured from the recommendation and not from the end of the load or from
    # utilization crossing the target: the controller stabilizes recommendations,
    # so those are the wrong clocks. See Get-HpaScaleRecommendation.
    #
    # Two numbers are computed, because the samples bound the true window
    # rather than measure it:
    #
    #   * ObservedScaleDownDelaySeconds - anchor sample to the sample that
    #     first observed the reduced desired count. The recommendation turned
    #     over at or before the anchor and the decision happened at or before
    #     its observation, so this value can OVERSTATE the true window by up to
    #     the gap ending at the anchor. Reported, never asserted on.
    #   * ProvenScaleDownDelaySeconds - anchor sample to the LAST sample that
    #     still showed the old desired count. The recommendation was proven to
    #     hold from the anchor, and the decision came strictly after that last
    #     old-count sample, so the true window is strictly LONGER than this
    #     bound. This is what the verdict compares against the configured
    #     window: sampling gaps around either transition shrink the bound and
    #     fail the assertion instead of being credited as stabilization time.
    $firstScaleDown = $scaleDowns | Select-Object -First 1
    $downscaleRecommendedFrom = $null
    $downscaleRecommendationDetail = $null
    $observedScaleDownDelaySeconds = $null
    $provenScaleDownDelaySeconds = $null
    $downscaleRecommendationGapSeconds = $null
    $downscaleAnchorBlockedByMetric = $null
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
            # Floored, not rounded: this is the lower bound the verdict trusts,
            # and rounding up would credit sub-second time that was not proven.
            $provenScaleDownDelaySeconds = [int] [math]::Floor(($firstScaleDown.PreviousSampleAt - $downscaleRecommendedFrom.Timestamp).TotalSeconds)

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
        } else {
            # No anchor at all, which has two causes that produce the same
            # timeline and need opposite advice. Either the HPA genuinely never
            # recommended fewer replicas before the scale-in - something other
            # than the autoscaler resized the workload - or this harness could
            # not compute the recommendation because a configured per-Pod
            # metric's coverage was never sampled, which blocks every sample and
            # says nothing at all about the autoscaler. Recording which one it
            # was costs a second pass over a timeline that has already failed.
            foreach ($sample in $ordered) {
                if ($sample.Timestamp -ge $firstScaleDown.At) {
                    break
                }

                $blocked = Get-HpaScaleRecommendation `
                    -Sample $sample `
                    -MinReplicas $MinReplicas `
                    -MaxReplicas $MaxReplicas `
                    -Tolerance $Tolerance
                if ($null -ne $blocked.UncoveredMetric) {
                    $downscaleAnchorBlockedByMetric = $blocked.UncoveredMetric
                    break
                }
            }
        }
    }

    $unattributedScaleEvents = @($scaleEvents | Where-Object { -not $_.HpaAttributed })

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
        UnattributedScaleEvents       = $unattributedScaleEvents
        ScaleUpCount                  = $scaleUps.Count
        ScaleDownCount                = $scaleDowns.Count
        PeakUtilizationPercent        = ($ordered | Where-Object { $null -ne $_.UtilizationPercent } |
            Measure-Object -Property UtilizationPercent -Maximum).Maximum
        UnknownMetricSamples          = $unknownAfterFirst
        ScalingActiveTrueSamples      = $scalingActiveTrue
        ScalingActiveNotTrueSamples   = $scalingActiveNotTrue
        RestartDelta                  = $restartDelta
        ObservedScaleDownDelaySeconds = $observedScaleDownDelaySeconds
        ProvenScaleDownDelaySeconds   = $provenScaleDownDelaySeconds
        DownscaleRecommendedAt        = $(if ($null -ne $downscaleRecommendedFrom) { $downscaleRecommendedFrom.Timestamp } else { $null })
        DownscaleRecommendationDetail = $downscaleRecommendationDetail
        DownscaleRecommendationGapSeconds = $downscaleRecommendationGapSeconds
        DownscaleAnchorBlockedByMetric = $downscaleAnchorBlockedByMetric
        FirstScaleDownAt              = $(if ($null -ne $firstScaleDown) { $firstScaleDown.At } else { $null })
        FirstScaleDownPreviousSampleAt = $(if ($null -ne $firstScaleDown) { $firstScaleDown.PreviousSampleAt } else { $null })
        Tolerance                     = $Tolerance
        Samples                       = $ordered
    }
}

# How much of the configured stabilization window the verdict is allowed to
# forgive.
#
# The grace is the fixed quantization allowance of the REQUESTED sampling
# interval, and nothing about how the run actually sampled ever widens it. The
# verdict compares the conservative proven bound - anchor sample to the last
# sample still showing the old desired count - and even a perfectly compliant
# window loses up to one requested interval at each end of that bound, which is
# what the requested grace covers.
#
# The run's OBSERVED gaps must not feed this number, and #290's review is why:
# a gap around either transition means the evidence proves less, and forgiving
# it would let sampling uncertainty manufacture stabilization time. Under the
# proven bound those gaps already do the conservative thing on their own - they
# shrink the bound and fail the assertion. AnchorGapSeconds is carried in the
# result for reporting only, so a reader can see how sparse the sampling around
# the anchor was; it buys the verdict nothing.
#
# The ceiling is the second guard. A grace worth more than half the window
# means the requested sampling was too coarse to say whether the window held at
# all, which is a run to reject rather than to pass on a technicality; the
# caller turns ExceedsCeiling into that rejection, and GraceSeconds stays
# capped either way so the value handed to Confirm-AutoscalingBehavior is
# always a legal one.
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

    return [pscustomobject]@{
        GraceSeconds         = [math]::Min($RequestedGraceSeconds, $ceiling)
        UncappedGraceSeconds = $RequestedGraceSeconds
        AnchorGapSeconds     = $anchorGap
        CeilingSeconds       = $ceiling
        ExceedsCeiling       = ($RequestedGraceSeconds -gt $ceiling)
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

    # A health check, not an attribution check: ScalingActive=True says the HPA
    # could read its metrics and compute a desired count throughout the run. It
    # does NOT say the HPA performed any particular replica change - a manual
    # `kubectl scale` next to a healthy HPA keeps this condition True. Who
    # performed each transition is the next assertion's job.
    Confirm-Condition `
        -Condition ($Timeline.ScalingActiveNotTrueSamples -eq 0 -and $Timeline.ScalingActiveTrueSamples -gt 0) `
        -SuccessMessage "the HPA reported ScalingActive=True in all $($Timeline.ScalingActiveTrueSamples) samples after the first, so the autoscaler was computing desired replica counts throughout the run" `
        -FailureMessage "the HPA did not report ScalingActive=True in $($Timeline.ScalingActiveNotTrueSamples) of the $($Timeline.SampleCount - 1) samples after the first. ScalingActive=False means the HPA computed no desired replica count, so for those samples any replica change came from something else - a rollout, a manual scale, or another controller - and proves nothing about the autoscaler. Check 'kubectl describe hpa' for the condition's reason"

    # Attribution. Every replica transition the run recorded must correlate
    # with the HPA's own rescale evidence: the HPA's desiredReplicas matching
    # the transition's new count, and its lastScaleTime advancing across the
    # transition. A transition without that evidence may be a manual resize, a
    # rollout, or another controller - and every assertion below reads the
    # replica numbers as the autoscaler's work, so one unattributed transition
    # poisons the run. Ordered before the replica assertions for that reason.
    $unattributedDetail = @($Timeline.UnattributedScaleEvents | ForEach-Object {
            "$($_.From) -> $($_.To) at $($_.At.ToString('HH:mm:ssZ'))"
        }) -join "; "
    Confirm-Condition `
        -Condition ($Timeline.UnattributedScaleEvents.Count -eq 0) `
        -SuccessMessage "every replica transition ($($Timeline.ScaleEvents.Count) of them) correlates with the HPA's own rescale evidence: desiredReplicas matched the new count and lastScaleTime advanced across the transition" `
        -FailureMessage "$($Timeline.UnattributedScaleEvents.Count) of $($Timeline.ScaleEvents.Count) replica transition(s) carry no correlated successful HPA rescale evidence: $unattributedDetail. ScalingActive=True only says the HPA could compute a desired count, not that it performed these rescales; a manual 'kubectl scale', a rollout, or another controller produces the same replica change. A transition is credited to the HPA only when the HPA's desiredReplicas matches the new count and its lastScaleTime advanced across the transition, so this run cannot prove the autoscaler produced the timeline below"

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

    # The verdict compares the PROVEN bound, not the observed spacing. The
    # true window lies somewhere inside an interval: the recommendation turned
    # over at or before the anchor sample, and the decision came strictly
    # after the last sample still showing the old desired count. Judging the
    # optimistic end of that interval would let a sampling gap around either
    # transition manufacture stabilization time - the #290 false positive - so
    # the conservative end is what must clear the window, and a gap that makes
    # the window unprovable fails here instead of being forgiven.
    $threshold = $ExpectedScaleDownWindowSeconds - $ScaleDownGraceSeconds
    # Both messages are built up front because both are evaluated on every
    # call, and the success one dereferences fields that are null when no
    # anchor exists.
    $scaleDownDelaySuccessMessage = "the scale-down window was proven"
    if ($null -eq $Timeline.ProvenScaleDownDelaySeconds) {
        if ($null -eq $Timeline.FirstScaleDownAt) {
            $scaleDownDelayFailureMessage = "no scale-down delay could be computed because no scale-down occurred during the run. Either the run ended before the ${ExpectedScaleDownWindowSeconds}s stabilization window elapsed, or the HPA never recommended fewer replicas"
        } elseif ($null -ne $Timeline.DownscaleAnchorBlockedByMetric) {
            # Distinguished from the message below on purpose. Both arrive with
            # no anchor, but this one is a gap in the harness rather than a
            # finding about the autoscaler, and sending the reader to look for a
            # second controller resizing the Deployment would waste the search.
            $scaleDownDelayFailureMessage = "the scale-down window could not be measured: the applied HPA carries the per-Pod metric '$($Timeline.DownscaleAnchorBlockedByMetric)', whose Pod coverage this run never sampled, so no sample could produce the HPA's desired replica count and nothing could anchor the window. This harness samples Pod coverage for CPU alone, from 'kubectl top', and never lends that count to another metric, because metrics-server and a custom-metrics adapter can see different Pods. That is a limit of this run rather than a result about the autoscaler: judge scale-down against a CPU-only HPA, or sample this metric's coverage independently. Every assertion above this one is unaffected"
        } else {
            $scaleDownDelayFailureMessage = "the workload scaled in at $($Timeline.FirstScaleDownAt.ToString('HH:mm:ssZ')) without a single preceding sample in which the HPA's desired replica count was below the running one. No stabilization window explains that scale-in; check whether something other than the autoscaler resized the Deployment, or whether the sampling interval is coarse enough to have missed the recommendation entirely"
        }
    } else {
        $scaleDownDelayFailureMessage = "the evidence proves a recommendation duration of only >= $($Timeline.ProvenScaleDownDelaySeconds)s before the scale-down decision - the HPA recommended fewer replicas continuously from $($Timeline.DownscaleRecommendedAt.ToString('HH:mm:ssZ')) ($($Timeline.DownscaleRecommendationDetail)) and the decision came after the last old-count sample at $($Timeline.FirstScaleDownPreviousSampleAt.ToString('HH:mm:ssZ')) - which does not establish the configured ${ExpectedScaleDownWindowSeconds}s stabilization window (threshold ${threshold}s after ${ScaleDownGraceSeconds}s of sampling grace; anchor-to-decision-observation spacing $($Timeline.ObservedScaleDownDelaySeconds)s). Either the HPA scaled in early, or the sampling around the recommendation turnover or the decision was too sparse to prove the window held; sampling uncertainty is never credited as stabilization time"
        $scaleDownDelaySuccessMessage = "the scale-down decision came after a proven recommendation duration >= $($Timeline.ProvenScaleDownDelaySeconds)s: the HPA recommended fewer replicas continuously from $($Timeline.DownscaleRecommendedAt.ToString('HH:mm:ssZ')) ($($Timeline.DownscaleRecommendationDetail)) through the last old-count sample at $($Timeline.FirstScaleDownPreviousSampleAt.ToString('HH:mm:ssZ')), consistent with the configured ${ExpectedScaleDownWindowSeconds}s stabilization window (threshold ${threshold}s after ${ScaleDownGraceSeconds}s of sampling grace)"
    }
    Confirm-Condition `
        -Condition ($null -ne $Timeline.ProvenScaleDownDelaySeconds -and $Timeline.ProvenScaleDownDelaySeconds -ge $threshold) `
        -SuccessMessage $scaleDownDelaySuccessMessage `
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

        # The three replica concepts stay separate on every line: desired is
        # the scale subresource (where the HPA writes its decision), hpaDesired
        # is the HPA's own status, and replicas/ready are what the workload
        # realized. "-" means the field was not sampled, which is different
        # from any number.
        $scaleDesired = "-"
        if ($null -ne $sample.ScaleDesiredReplicas) {
            $scaleDesired = "$($sample.ScaleDesiredReplicas)"
        }
        $hpaDesired = "-"
        if ($null -ne $sample.HpaDesiredReplicas) {
            $hpaDesired = "$($sample.HpaDesiredReplicas)"
        }
        $lastScale = "-"
        if ($null -ne $sample.HpaLastScaleTime) {
            $lastScale = $sample.HpaLastScaleTime.ToString("HH:mm:ssZ")
        }

        $line = "{0} | cpu: {1,9}/{2}%  {3}  {4}  {5} | desired={6} hpaDesired={7} lastScale={8} ready={9} scalingActive={10}" -f `
            $sample.Timestamp.ToString("HH:mm:ssZ"),
            $utilization,
            $sample.TargetPercent,
            $Timeline.MinReplicas,
            $Timeline.MaxReplicas,
            $sample.Replicas,
            $scaleDesired,
            $hpaDesired,
            $lastScale,
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
