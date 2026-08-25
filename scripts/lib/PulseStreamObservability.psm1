# The checks validate-observability-stack.ps1 makes, as functions (#159).
#
# They live here rather than inline in the script for one reason: every one of
# them is a check whose FAILURE path is the interesting one, and none of those
# failures can be produced on demand against a live cluster. A half-finished
# rollout, a job that discovered one replica of two, a `kubectl logs` that is
# denied by RBAC, a Grafana answering with a value from before the stimulus - a
# validator that gets any of these wrong reports a healthy stack and is worse
# than no validator at all.
#
# scripts/tests/test-observability-stack-checks.ps1 drives each of them through
# those cases with no cluster.

# --- Deployment rollout ------------------------------------------------------

# Whether every replica the spec asks for is updated, Ready and available.
#
# `readyReplicas >= 1` is not that: during a rolling update one new pod is Ready
# while the rest of the fleet is still the old ReplicaSet, and a Deployment
# scaled to zero has no ready replicas and no problem either. Both look like a
# working component from the outside, and both make every metric assertion
# downstream describe a fleet that is not the one the manifests declare.
#
# Takes the object `kubectl get deployment -o json` returns.
function Get-DeploymentRolloutState {
    param([Parameter(Mandatory)] $Deployment)

    # A spec with no `replicas` means one; a status field that is absent means
    # zero (the API server omits counters that are zero).
    $desired = if ($null -eq $Deployment.spec.replicas) { 1 } else { [int] $Deployment.spec.replicas }
    $current = [int] ("0" + [string] $Deployment.status.replicas)
    $updated = [int] ("0" + [string] $Deployment.status.updatedReplicas)
    $ready = [int] ("0" + [string] $Deployment.status.readyReplicas)
    $available = [int] ("0" + [string] $Deployment.status.availableReplicas)

    $generation = [long] ("0" + [string] $Deployment.metadata.generation)
    $observedGeneration = [long] ("0" + [string] $Deployment.status.observedGeneration)

    $reasons = [System.Collections.Generic.List[string]]::new()

    if ($desired -lt 1) {
        $reasons.Add("it is scaled to $desired replica(s)") | Out-Null
    }

    # Every status counter below belongs to the previous spec until the
    # controller catches up, so this is checked first: without it, a Deployment
    # that was just scaled up reads as complete at its old size.
    if ($observedGeneration -lt $generation) {
        $reasons.Add("the controller has not observed generation $generation yet (observed $observedGeneration)") | Out-Null
    }

    if ($updated -ne $desired) {
        $reasons.Add("$updated of $desired replica(s) are running the current template") | Out-Null
    }

    if ($ready -ne $desired) {
        $reasons.Add("$ready of $desired replica(s) are Ready") | Out-Null
    }

    if ($available -ne $desired) {
        $reasons.Add("$available of $desired replica(s) are available") | Out-Null
    }

    # Surplus pods are old replicas that have not terminated, i.e. a rollout
    # still in flight. They are scraped like any other pod while they last.
    if ($current -gt $desired) {
        $reasons.Add("$($current - $desired) replica(s) from a previous revision are still running") | Out-Null
    }

    return [pscustomobject]@{
        Desired            = $desired
        Current            = $current
        Updated            = $updated
        Ready              = $ready
        Available          = $available
        Generation         = $generation
        ObservedGeneration = $observedGeneration
        IsComplete         = ($reasons.Count -eq 0)
        Reason             = [string]::Join("; ", $reasons.ToArray())
    }
}

# --- Per-pod coverage --------------------------------------------------------

# Does an observed set of pod names cover an expected set exactly once each?
#
# Counting is not enough. Two targets for one pod and none for its replica is
# the same count as one target each, and it is the shape a stale discovery entry
# after a rollout actually takes: the dashboards keep drawing a line and the
# unscraped replica is invisible.
#
# Returns one string per problem; empty means an exact one-to-one match.
function Compare-PodCoverage {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Expected,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Observed,
        [string] $Subject = "the observed set"
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    if ($Expected.Count -eq 0) {
        $problems.Add("$Subject was compared against no expected pods at all") | Out-Null
        return $problems.ToArray()
    }

    foreach ($pod in $Expected) {
        $matched = @($Observed | Where-Object { $_ -eq $pod }).Count

        if ($matched -eq 0) {
            $problems.Add("$Subject has nothing for pod '$pod'") | Out-Null
        } elseif ($matched -gt 1) {
            $problems.Add("$Subject has $matched entries for pod '$pod', expected exactly one") | Out-Null
        }
    }

    foreach ($pod in @($Observed | Select-Object -Unique)) {
        if ($Expected -notcontains $pod) {
            $problems.Add("$Subject has an entry for '$pod', which is not a Ready pod of this workload") | Out-Null
        }
    }

    # Emitted unrolled rather than as a single array object: every caller wraps
    # the result in @(), and a `, $array` return would nest inside that instead
    # of counting the problems.
    return $problems.ToArray()
}

# The value of one label across a Prometheus query result, duplicates kept -
# Compare-PodCoverage needs them to see a doubled series.
#
# A series that does not carry the label is reported as a placeholder rather
# than dropped: dropping it would turn "this series cannot be attributed to a
# pod" into "one pod is missing", which points at the wrong component.
function Get-PrometheusSeriesLabel {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] $Series,
        [Parameter(Mandatory)] [string] $Label
    )

    return @(@($Series) | ForEach-Object {
        $value = [string] $_.metric.$Label
        if ([string]::IsNullOrWhiteSpace($value)) { "<series with no '$Label' label>" } else { $value }
    })
}

# The same, for an entry of /api/v1/targets, where labels sit one level up.
function Get-PrometheusTargetLabel {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] $Targets,
        [Parameter(Mandatory)] [string] $Label
    )

    return @(@($Targets) | ForEach-Object {
        $value = [string] $_.labels.$Label
        if ([string]::IsNullOrWhiteSpace($value)) { "<target with no '$Label' label>" } else { $value }
    })
}

# The samples of a query, as pod -> value, for asserting a per-pod metric.
function Get-PrometheusSampleValue {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] $Series,
        [Parameter(Mandatory)] [string] $Label
    )

    return @(@($Series) | ForEach-Object {
        [pscustomobject]@{
            Pod   = [string] $_.metric.$Label
            Value = [string] $_.value[1]
        }
    })
}

# --- Log sweep ---------------------------------------------------------------

# Error-level lines from one component's logs.
#
# Takes the result of Invoke-Kubectl ({ ExitCode, Output }) rather than running
# kubectl itself, so the tests can drive the failure paths.
#
# A NON-ZERO EXIT IS A FAILURE, not an empty result. `kubectl logs` exits
# non-zero when the namespace is wrong, when RBAC denies it, when the container
# has restarted and its previous log is gone - and treating that as "no errors
# were logged" turns the one step that inspects the components' own view of
# themselves into a step that passes hardest exactly when it can see least.
function Select-ComponentErrorLine {
    param(
        [Parameter(Mandatory)] $LogResult,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Component
    )

    if ($null -eq $LogResult -or $LogResult.ExitCode -ne 0) {
        throw ("Could not read the $Component logs (kubectl exit $($LogResult.ExitCode)). " +
            "The log sweep cannot pass on logs it never read. $($LogResult.Output)")
    }

    return @([string] $LogResult.Output -split "`r?`n" | Where-Object { $_ -match $Pattern })
}

# --- Port-forward ------------------------------------------------------------

# Start a port-forward and hand back a handle only once it answers.
#
# The cleanup is the point. The readiness poll can fail - the local port is
# already bound, the Service has no endpoints, kubectl exits immediately - and
# on that path the caller never receives a handle, so its `finally` has nothing
# to stop and the kubectl process outlives the run holding the port. The next
# run then fails to bind it, with an error that names the port rather than the
# reason. So the process is stopped here, before the failure is re-thrown.
#
# Launcher, ReadyProbe and Stopper are injected so the tests can drive that path
# without a cluster: Launcher returns a process handle, ReadyProbe is called
# with the base URL and throws until the tunnel answers, Stopper is called with
# the handle.
function Start-ManagedPortForward {
    param(
        [Parameter(Mandatory)] [scriptblock] $Launcher,
        [Parameter(Mandatory)] [scriptblock] $ReadyProbe,
        [Parameter(Mandatory)] [scriptblock] $Stopper,
        [Parameter(Mandatory)] [string] $BaseUrl,
        [string] $Description = "port-forward",
        [string] $Log = ""
    )

    $process = & $Launcher

    try {
        & $ReadyProbe $BaseUrl
    } catch {
        # Best-effort: a Stopper that throws must not mask the readiness failure,
        # which is the one that says what went wrong.
        try { & $Stopper $process } catch { }

        $logHint = if ([string]::IsNullOrWhiteSpace($Log)) { "" } else { " Log: $Log" }
        throw "The $Description did not start listening on $BaseUrl, and was stopped. $($_.Exception.Message)$logHint"
    }

    return [pscustomobject]@{
        Process = $process
        BaseUrl = $BaseUrl
        Log     = $Log
    }
}

# --- Post-stimulus value -----------------------------------------------------

# Is this query result the value the stimulus produced, or an older one?
#
# "Grafana returned something" is not the assertion this step needs. The counter
# it queries is non-zero for as long as the pod lives, so a Grafana pointed at a
# second Prometheus, or serving a cached response from before the request, comes
# back non-empty and passes. The value has to be at least what Prometheus
# reported AFTER the stimulus for the answer to be this run's.
function Test-PostStimulusMetric {
    param(
        [Parameter(Mandatory)] [AllowNull()] $Response,
        [Parameter(Mandatory)] [double] $Minimum,
        [string] $Query = "the query"
    )

    $fail = {
        param([string] $Reason)
        [pscustomobject]@{ Ok = $false; Value = [double] 0; Reason = $Reason }
    }

    if ($null -eq $Response -or $Response.status -ne "success") {
        return & $fail "the datasource answered status '$($Response.status)': $($Response.error)"
    }

    $series = @($Response.data.result)

    if ($series.Count -eq 0) {
        return & $fail "the datasource returned no series for $Query, although Prometheus does"
    }

    if ($series.Count -gt 1) {
        return & $fail ("the datasource returned $($series.Count) series for $Query, which aggregates to one; " +
            "the answer cannot be attributed to this run")
    }

    $value = [double] $series[0].value[1]

    if ($value -lt $Minimum) {
        return & $fail ("the datasource returned $value for $Query, below the $Minimum Prometheus reported after " +
            "the stimulus - this is a historical value, not this run's")
    }

    return [pscustomobject]@{ Ok = $true; Value = $value; Reason = "" }
}

Export-ModuleMember -Function `
    Get-DeploymentRolloutState, `
    Compare-PodCoverage, `
    Get-PrometheusSeriesLabel, `
    Get-PrometheusTargetLabel, `
    Get-PrometheusSampleValue, `
    Select-ComponentErrorLine, `
    Start-ManagedPortForward, `
    Test-PostStimulusMetric
