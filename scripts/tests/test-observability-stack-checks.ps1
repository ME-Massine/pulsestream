# Regression cases for the checks in validate-observability-stack.ps1 (#159).
#
# Every case here is a FAILURE the end-to-end validator has to catch and cannot
# be asked to demonstrate on a healthy cluster: a Deployment half-way through a
# rollout, a Prometheus job covering one replica twice and its sibling not at
# all, a `kubectl logs` that was denied, a port-forward whose readiness poll
# fails, a Grafana answering with a value from before the stimulus. A validator
# that gets any of these wrong reports a working stack, which is worse than no
# validator - so they are pinned down here, with no cluster.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamObservability.psm1") -Force

$failures = [System.Collections.Generic.List[string]]::new()
$assertionCount = 0

function Confirm-That {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Description
    )

    $script:assertionCount++

    if ($Condition) {
        Write-Host "  [ok] $Description"
    } else {
        Write-Host "  [FAIL] $Description"
        $script:failures.Add($Description) | Out-Null
    }
}

# `kubectl get deployment -o json`, reduced to the fields the check reads.
function New-Deployment {
    param(
        [int] $Desired = 2,
        [int] $Replicas = 2,
        [int] $Updated = 2,
        [int] $Ready = 2,
        [int] $Available = 2,
        [long] $Generation = 4,
        [long] $ObservedGeneration = 4,
        [switch] $NoSpecReplicas,
        [switch] $NoStatusCounters
    )

    $spec = if ($NoSpecReplicas) { [pscustomobject]@{} } else { [pscustomobject]@{ replicas = $Desired } }

    $status = if ($NoStatusCounters) {
        [pscustomobject]@{ observedGeneration = $ObservedGeneration }
    } else {
        [pscustomobject]@{
            replicas           = $Replicas
            updatedReplicas    = $Updated
            readyReplicas      = $Ready
            availableReplicas  = $Available
            observedGeneration = $ObservedGeneration
        }
    }

    return [pscustomobject]@{
        metadata = [pscustomobject]@{ name = "ingestion-service"; generation = $Generation }
        spec     = $spec
        status   = $status
    }
}

Write-Host "Validating the observability stack checks..."

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "1. A Deployment counts as Ready only when every desired replica is updated, Ready and available."

$state = Get-DeploymentRolloutState -Deployment (New-Deployment)
Confirm-That -Condition ($state.IsComplete) `
    -Description "2/2 updated, Ready and available is complete (reason: '$($state.Reason)')"

# The case `readyReplicas -ge 1` accepts and every per-pod assertion downstream
# then describes half a fleet.
$state = Get-DeploymentRolloutState -Deployment (New-Deployment -Ready 1)
Confirm-That -Condition (-not $state.IsComplete -and $state.Reason -match "1 of 2 replica\(s\) are Ready") `
    -Description "1 of 2 Ready is incomplete, and says so: '$($state.Reason)'"

# Mid rolling-update: the new pod is Ready, the old one is Ready too, and one of
# them is running the previous template.
$state = Get-DeploymentRolloutState -Deployment (New-Deployment -Updated 1)
Confirm-That -Condition (-not $state.IsComplete -and $state.Reason -match "running the current template") `
    -Description "a replica still on the previous template is incomplete: '$($state.Reason)'"

$state = Get-DeploymentRolloutState -Deployment (New-Deployment -Available 1)
Confirm-That -Condition (-not $state.IsComplete -and $state.Reason -match "are available") `
    -Description "a Ready-but-not-yet-available replica is incomplete: '$($state.Reason)'"

# Old ReplicaSet pods that have not terminated are scraped like any other pod.
$state = Get-DeploymentRolloutState -Deployment (New-Deployment -Replicas 3)
Confirm-That -Condition (-not $state.IsComplete -and $state.Reason -match "previous revision") `
    -Description "a surviving pod from a previous revision is incomplete: '$($state.Reason)'"

$state = Get-DeploymentRolloutState -Deployment (New-Deployment -Desired 0 -Replicas 0 -Updated 0 -Ready 0 -Available 0)
Confirm-That -Condition (-not $state.IsComplete -and $state.Reason -match "scaled to 0") `
    -Description "a Deployment scaled to zero is incomplete rather than trivially satisfied: '$($state.Reason)'"

# Status counters describe the previous spec until the controller catches up, so
# a Deployment just scaled up otherwise reads as complete at its old size.
$state = Get-DeploymentRolloutState -Deployment (New-Deployment -Generation 5 -ObservedGeneration 4)
Confirm-That -Condition (-not $state.IsComplete -and $state.Reason -match "has not observed generation 5") `
    -Description "a spec the controller has not observed yet is incomplete: '$($state.Reason)'"

# The API server omits counters that are zero: absent must read as 0, not as
# "matches whatever was expected".
$state = Get-DeploymentRolloutState -Deployment (New-Deployment -NoStatusCounters)
Confirm-That -Condition (-not $state.IsComplete -and $state.Ready -eq 0) `
    -Description "a status with no counters at all is incomplete: '$($state.Reason)'"

$state = Get-DeploymentRolloutState -Deployment (New-Deployment -NoSpecReplicas -Replicas 1 -Updated 1 -Ready 1 -Available 1)
Confirm-That -Condition ($state.IsComplete -and $state.Desired -eq 1) `
    -Description "a spec with no replicas means one replica, and one Ready satisfies it"

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "2. Prometheus coverage is matched pod by pod, not counted."

$expected = @("ingestion-service-abc", "ingestion-service-def")

$problems = @(Compare-PodCoverage -Expected $expected -Observed $expected -Subject "job 'ingestion-service'")
Confirm-That -Condition ($problems.Count -eq 0) `
    -Description "one entry per Ready pod is a clean match (got: $($problems -join '; '))"

# The count is right and the coverage is not - a stale discovery entry after a
# rollout takes exactly this shape.
$doubled = @("ingestion-service-abc", "ingestion-service-abc")
$problems = @(Compare-PodCoverage -Expected $expected -Observed $doubled -Subject "job 'ingestion-service'")
Confirm-That -Condition (@($problems | Where-Object { $_ -match "2 entries for pod 'ingestion-service-abc'" }).Count -eq 1) `
    -Description "two entries for one pod are reported even though the total count matches"
Confirm-That -Condition (@($problems | Where-Object { $_ -match "nothing for pod 'ingestion-service-def'" }).Count -eq 1) `
    -Description "the replica with no entry is reported in the same comparison"

$problems = @(Compare-PodCoverage -Expected $expected -Observed @("ingestion-service-abc") -Subject "job 'ingestion-service'")
Confirm-That -Condition ($problems.Count -eq 1 -and $problems[0] -match "nothing for pod 'ingestion-service-def'") `
    -Description "a job that discovered one replica of two is reported"

$problems = @(Compare-PodCoverage -Expected $expected -Observed (@($expected) + @("ingestion-service-old")) -Subject "job 'ingestion-service'")
Confirm-That -Condition (@($problems | Where-Object { $_ -match "'ingestion-service-old', which is not a Ready pod" }).Count -eq 1) `
    -Description "a target for a pod that is no longer Ready is reported"

$problems = @(Compare-PodCoverage -Expected $expected -Observed @() -Subject "job 'ingestion-service'")
Confirm-That -Condition ($problems.Count -eq 2) `
    -Description "no entries at all reports every expected pod"

# Guards the assertion itself: comparing against an empty expectation would
# otherwise pass silently and prove nothing.
$problems = @(Compare-PodCoverage -Expected @() -Observed @("ingestion-service-abc") -Subject "job 'ingestion-service'")
Confirm-That -Condition ($problems.Count -eq 1 -and $problems[0] -match "no expected pods at all") `
    -Description "an empty expected set is itself reported, not treated as satisfied"

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "3. Pod labels are read from targets and series, duplicates kept."

$targets = @(
    [pscustomobject]@{ labels = [pscustomobject]@{ job = "ingestion-service"; pod = "ingestion-service-abc" } },
    [pscustomobject]@{ labels = [pscustomobject]@{ job = "ingestion-service"; pod = "ingestion-service-abc" } }
)
$podLabels = @(Get-PrometheusTargetLabel -Targets $targets -Label "pod")
Confirm-That -Condition ($podLabels.Count -eq 2 -and $podLabels[0] -eq "ingestion-service-abc") `
    -Description "duplicate targets are returned twice, so the coverage check can see them"

$series = @(
    [pscustomobject]@{ metric = [pscustomobject]@{ pod = "ingestion-service-abc" }; value = @(1700000000, "1") },
    [pscustomobject]@{ metric = [pscustomobject]@{ job = "ingestion-service" };     value = @(1700000000, "1") }
)
$seriesLabels = @(Get-PrometheusSeriesLabel -Series $series -Label "pod")
Confirm-That -Condition (@($seriesLabels | Where-Object { $_ -match "no 'pod' label" }).Count -eq 1) `
    -Description "a series that carries no pod label is reported as such, not dropped"

# Dropping it would turn "this series cannot be attributed to a pod" into "one
# pod is missing", which points at the wrong component.
$problems = @(Compare-PodCoverage -Expected @("ingestion-service-abc") -Observed $seriesLabels -Subject "up{job=`"ingestion-service`"}")
Confirm-That -Condition (@($problems | Where-Object { $_ -match "no 'pod' label" }).Count -eq 1) `
    -Description "an unattributable series is reported as an unexpected entry"

$samples = @(Get-PrometheusSampleValue -Series $series -Label "pod")
Confirm-That -Condition ($samples.Count -eq 2 -and $samples[0].Value -eq "1") `
    -Description "sample values are read alongside their pod, for the per-pod value assertion"

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "4. The log sweep fails when it cannot read logs."

$collectorPattern = '(?m)\s(error|fatal|dpanic|panic)\s'
$grafanaPattern = '(?m)level=(error|eror|crit)'

$lines = @(Select-ComponentErrorLine -Component "otel-collector" -Pattern $collectorPattern -LogResult ([pscustomobject]@{
    ExitCode = 0
    Output   = "2026-08-25T10:00:00.000Z`tinfo`tService started`n2026-08-25T10:00:05.000Z`terror`tExporting failed"
}))
Confirm-That -Condition ($lines.Count -eq 1 -and $lines[0] -match "Exporting failed") `
    -Description "an error-level line in a healthy read is returned"

$lines = @(Select-ComponentErrorLine -Component "grafana" -Pattern $grafanaPattern -LogResult ([pscustomobject]@{
    ExitCode = 0
    Output   = 'logger=provisioning level=info msg="failed once, retrying" error=nil'
}))
Confirm-That -Condition ($lines.Count -eq 0) `
    -Description "the word 'error' inside an informational line is not an error line"

# The regression: kubectl exits non-zero when RBAC denies the read, the
# namespace is wrong, or the container's previous log is gone. Returning an
# empty list there makes the sweep pass hardest exactly when it saw least.
$threw = $false
$message = ""
try {
    Select-ComponentErrorLine -Component "jaeger" -Pattern $grafanaPattern -LogResult ([pscustomobject]@{
        ExitCode = 1
        Output   = 'Error from server (Forbidden): pods is forbidden'
    }) | Out-Null
} catch {
    $threw = $true
    $message = $_.Exception.Message
}

Confirm-That -Condition ($threw -and $message -match "cannot pass on logs it never read") `
    -Description "a failed kubectl logs throws instead of reporting a clean sweep"
Confirm-That -Condition ($message -match "Forbidden") `
    -Description "the kubectl output is carried into the failure, so the cause is visible"

$threw = $false
try {
    Select-ComponentErrorLine -Component "prometheus" -Pattern $grafanaPattern -LogResult $null | Out-Null
} catch {
    $threw = $true
}
Confirm-That -Condition $threw `
    -Description "a missing log result throws rather than reading as empty"

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "5. A port-forward whose readiness poll fails is stopped, not leaked."

$stopped = [System.Collections.Generic.List[object]]::new()
$handle = [pscustomobject]@{ Id = 4242; HasExited = $false }

$forward = Start-ManagedPortForward `
    -BaseUrl "http://localhost:13000" `
    -Description "port-forward to svc/grafana" `
    -Launcher { $handle }.GetNewClosure() `
    -ReadyProbe { param($BaseUrl) } `
    -Stopper { param($Process) $stopped.Add($Process) | Out-Null }.GetNewClosure()

Confirm-That -Condition ($forward.Process.Id -eq 4242 -and $forward.BaseUrl -eq "http://localhost:13000") `
    -Description "a tunnel that answers is handed back to the caller"
Confirm-That -Condition ($stopped.Count -eq 0) `
    -Description "a tunnel that answers is not stopped"

# The regression: the poll fails, so the function never returns - and the
# caller's `finally` has no handle to stop. Without the cleanup here the kubectl
# process outlives the run holding the local port, and the next run fails to
# bind it with an error naming the port rather than the reason.
$stopped.Clear()
$threw = $false
$message = ""
try {
    Start-ManagedPortForward `
        -BaseUrl "http://localhost:13000" `
        -Description "port-forward to svc/grafana" `
        -Log "C:\temp\grafana.log" `
        -Launcher { $handle }.GetNewClosure() `
        -ReadyProbe { param($BaseUrl) throw "svc/grafana did not answer within 30 seconds" } `
        -Stopper { param($Process) $stopped.Add($Process) | Out-Null }.GetNewClosure() | Out-Null
} catch {
    $threw = $true
    $message = $_.Exception.Message
}

Confirm-That -Condition ($threw) `
    -Description "a tunnel that never answers fails the run"
Confirm-That -Condition ($stopped.Count -eq 1 -and $stopped[0].Id -eq 4242) `
    -Description "the launched process is stopped exactly once before the failure is re-thrown"
Confirm-That -Condition ($message -match "did not answer within 30 seconds") `
    -Description "the readiness failure is carried into the error, not replaced by it"
Confirm-That -Condition ($message -match "C:\\temp\\grafana.log") `
    -Description "the port-forward log path is named, since kubectl wrote the reason there"

# A Stopper that throws (the process already exited, access denied) must not
# mask the readiness failure, which is the one that says what went wrong.
$threw = $false
$message = ""
try {
    Start-ManagedPortForward `
        -BaseUrl "http://localhost:13000" `
        -Description "port-forward to svc/grafana" `
        -Launcher { $handle }.GetNewClosure() `
        -ReadyProbe { param($BaseUrl) throw "svc/grafana did not answer within 30 seconds" } `
        -Stopper { param($Process) throw "Cannot find a process with the process identifier 4242" } | Out-Null
} catch {
    $threw = $true
    $message = $_.Exception.Message
}

Confirm-That -Condition ($threw -and $message -match "did not answer within 30 seconds") `
    -Description "a Stopper that throws does not replace the readiness failure"

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "6. Grafana has to serve this run's value, not any historical one."

function New-QueryResponse {
    param([string[]] $Values, [string] $Status = "success")

    return [pscustomobject]@{
        status = $Status
        error  = ""
        data   = [pscustomobject]@{
            result = @($Values | ForEach-Object {
                [pscustomobject]@{ metric = [pscustomobject]@{}; value = @(1700000000, $_) }
            })
        }
    }
}

$verdict = Test-PostStimulusMetric -Response (New-QueryResponse -Values @("42")) -Minimum 42 -Query "sum(...)"
Confirm-That -Condition ($verdict.Ok -and $verdict.Value -eq 42) `
    -Description "the post-stimulus value Prometheus reported is accepted"

$verdict = Test-PostStimulusMetric -Response (New-QueryResponse -Values @("43")) -Minimum 42 -Query "sum(...)"
Confirm-That -Condition ($verdict.Ok) `
    -Description "a value above it is accepted too - the counter keeps moving during the run"

# The regression: the counter is non-zero for as long as the pod lives, so a
# Grafana wired to a different Prometheus, or answering from before the
# stimulus, comes back non-empty and would pass a "returned something" check.
$verdict = Test-PostStimulusMetric -Response (New-QueryResponse -Values @("41")) -Minimum 42 -Query "sum(...)"
Confirm-That -Condition (-not $verdict.Ok -and $verdict.Reason -match "historical value") `
    -Description "a value from before the stimulus is rejected as historical: '$($verdict.Reason)'"

$verdict = Test-PostStimulusMetric -Response (New-QueryResponse -Values @()) -Minimum 42 -Query "sum(...)"
Confirm-That -Condition (-not $verdict.Ok -and $verdict.Reason -match "no series") `
    -Description "an empty result is rejected"

# The query aggregates to one series; more than one means it is not the query
# whose value was compared against Prometheus.
$verdict = Test-PostStimulusMetric -Response (New-QueryResponse -Values @("42", "43")) -Minimum 42 -Query "sum(...)"
Confirm-That -Condition (-not $verdict.Ok -and $verdict.Reason -match "2 series") `
    -Description "an unexpectedly split result is rejected rather than read as its first series"

$verdict = Test-PostStimulusMetric -Response (New-QueryResponse -Values @("42") -Status "error") -Minimum 42 -Query "sum(...)"
Confirm-That -Condition (-not $verdict.Ok -and $verdict.Reason -match "status 'error'") `
    -Description "a datasource error is rejected even when it carries a value"

$verdict = Test-PostStimulusMetric -Response $null -Minimum 42 -Query "sum(...)"
Confirm-That -Condition (-not $verdict.Ok) `
    -Description "no response at all is rejected"

# ---------------------------------------------------------------------------
Write-Host ""

if ($failures.Count -gt 0) {
    Write-Host "[FAIL] $($failures.Count) of $assertionCount assertions failed."
    exit 1
}

Write-Host "[ok] All $assertionCount assertions passed."
