# Load-pod orchestration for the autoscaling behavior validator (#153).
#
# Keeping these Kubernetes-side operations separate from the top-level phase
# runner makes the runner read as baseline -> load -> scale-down -> verdict and
# leaves the command rendering and heartbeat parsing independently testable.

Import-Module (Join-Path $PSScriptRoot "PulseStreamValidation.psm1")
Import-Module (Join-Path $PSScriptRoot "PulseStreamKubernetes.psm1")

function New-AutoscalingShellCommand {
    param(
        [Parameter(Mandatory)] [string] $Template,
        [Parameter(Mandatory)] [hashtable] $Values
    )

    $command = $Template
    foreach ($key in $Values.Keys) {
        $command = $command.Replace("{{$key}}", [string] $Values[$key])
    }

    # These templates live in a *.ps1, which .gitattributes checks out with
    # CRLF on Windows. sh keeps CR as part of the final token on each line.
    return $command -replace "`r`n", "`n" -replace "`r", "`n"
}

function New-AutoscalingLoadBootstrapCommand {
    param(
        [Parameter(Mandatory)] [string] $Command,
        [Parameter(Mandatory)] [string] $Shell
    )

    # Base64 preserves multiline shell and embedded JSON across Windows
    # PowerShell 5.1's native-command quoting. Check the dependency before using
    # it so an overridden minimal image fails with an exact prerequisite error.
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Command))
    return "command -v base64 >/dev/null 2>&1 || { echo 'pulsestream-autoscaling-load missing required command: base64' >&2; exit 127; }; printf '%s' '$encoded' | base64 -d | $Shell"
}

function Get-AutoscalingTimingRequirements {
    param(
        [Parameter(Mandatory)] [int] $SampleIntervalSeconds,
        [Parameter(Mandatory)] [int] $MinReplicas,
        [Parameter(Mandatory)] [int] $MaxReplicas,
        [Parameter(Mandatory)] [int] $ScaleDownWindowSeconds,
        [int[]] $ScaleUpPolicyPeriodsSeconds = @(60),
        [int[]] $ScaleDownPolicyPeriodsSeconds = @(60)
    )

    if ($SampleIntervalSeconds -le 0 -or $ScaleDownWindowSeconds -le 0 -or $MinReplicas -lt 1 -or $MaxReplicas -lt $MinReplicas) {
        throw "Autoscaling timing inputs must be positive and MaxReplicas must be at least MinReplicas."
    }

    $scaleUpPeriod = ($ScaleUpPolicyPeriodsSeconds | Measure-Object -Maximum).Maximum
    $scaleDownPeriod = ($ScaleDownPolicyPeriodsSeconds | Measure-Object -Maximum).Maximum
    if ($null -eq $scaleUpPeriod -or $scaleUpPeriod -le 0) { $scaleUpPeriod = 60 }
    if ($null -eq $scaleDownPeriod -or $scaleDownPeriod -le 0) { $scaleDownPeriod = 60 }

    # Load must span a complete configured scale-up policy interval and still
    # leave two samples in which to observe its result. Scale-down needs the
    # stabilization window, one conservative policy interval per possible
    # replica step, and a final sample after the return to the floor.
    return [pscustomobject]@{
        MinimumLoadDurationSeconds      = [int] $scaleUpPeriod + (2 * $SampleIntervalSeconds)
        MinimumScaleDownTimeoutSeconds  = $ScaleDownWindowSeconds + (($MaxReplicas - $MinReplicas) * [int] $scaleDownPeriod) + $SampleIntervalSeconds
        ScaleUpPolicyPeriodSeconds      = [int] $scaleUpPeriod
        ScaleDownPolicyPeriodSeconds    = [int] $scaleDownPeriod
    }
}

function Start-AutoscalingLoadPod {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [string] $LoadPodLabel,
        [Parameter(Mandatory)] [string] $PodName,
        [Parameter(Mandatory)] [string] $Image,
        [Parameter(Mandatory)] [string] $Command,
        [Parameter(Mandatory)] [string] $Shell
    )

    $bootstrap = New-AutoscalingLoadBootstrapCommand -Command $Command -Shell $Shell
    $result = Invoke-Kubectl -KubectlArgs @(
        "run", $PodName,
        "--namespace", $Namespace,
        "--restart=Never",
        "--labels", $LoadPodLabel,
        "--image", $Image,
        "--command", "--",
        $Shell, "-c", $bootstrap
    )

    if ($result.ExitCode -ne 0) {
        throw "Could not start load pod '$PodName' for run '$RunId'. $($result.Output)"
    }
}

function Stop-AutoscalingLoadPods {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [string] $LoadPodLabel
    )

    # --wait=false keeps cleanup bounded here; the loop below verifies actual
    # deletion and turns a stuck terminating pod into a failed run.
    $delete = Invoke-Kubectl -KubectlArgs @(
        "delete", "pod",
        "--namespace", $Namespace,
        "--selector", $LoadPodLabel,
        # Load generators hold no workload state and must stop promptly so the
        # first post-load recommendation can be sampled instead of disappearing
        # inside the Pod's default 30-second termination grace. Cleanup is still
        # verified below; this changes observation coverage, not verdict grace.
        "--grace-period=1", "--ignore-not-found", "--wait=false"
    )
    if ($delete.ExitCode -ne 0) {
        throw "Could not delete autoscaling load pods for run '$RunId'. $($delete.Output)"
    }

    $deadline = (Get-Date).AddSeconds(60)
    do {
        $remaining = Invoke-KubectlJsonChecked `
                -KubectlArgs @("get", "pods", "--namespace", $Namespace, "--selector", $LoadPodLabel, "-o", "json") `
                -ErrorContext "Could not confirm cleanup of autoscaling load pods for run '$RunId'"
        if (@($remaining.items).Count -eq 0) {
            Write-Host "[ok] All run-labelled load pods were deleted."
            return
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    $names = @($remaining.items | ForEach-Object { $_.metadata.name }) -join ", "
    throw "Load-pod cleanup timed out: run-labelled pod(s) still exist after 60 seconds: $names."
}

function Confirm-AutoscalingLoadPodRunning {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $PodName
    )

    Invoke-KubectlChecked `
        -KubectlArgs @("wait", "--namespace", $Namespace, "--for=condition=Ready", "pod/$PodName", "--timeout=120s") `
        -ErrorContext "Load pod '$PodName' did not become Ready; check its image, shell, bootstrap prerequisites, and startup command" | Out-Null

    $pod = Invoke-KubectlJsonChecked `
            -KubectlArgs @("get", "pod", $PodName, "--namespace", $Namespace, "-o", "json") `
            -ErrorContext "Could not read load pod '$PodName' after it became Ready"
    $statuses = @($pod.status.containerStatuses)
    $allRunning = $statuses.Count -gt 0 -and @($statuses | Where-Object { $_.state.running }).Count -eq $statuses.Count
    Confirm-Condition `
        -Condition ($pod.status.phase -eq "Running" -and $allRunning) `
        -SuccessMessage "load pod '$PodName' is Running" `
        -FailureMessage "load pod '$PodName' became Ready but is no longer Running; inspect its logs before trusting this run" `
        -Permanent
}

function Get-AutoscalingHeartbeatCountFromLogs {
    param([AllowEmptyString()] [string] $Logs = "")

    $highest = $null
    foreach ($match in [regex]::Matches($Logs, "pulsestream-autoscaling-load heartbeat \S+ (\d+)")) {
        $value = [long] $match.Groups[1].Value
        if ($null -eq $highest -or $value -gt $highest) {
            $highest = $value
        }
    }

    return $highest
}

function New-AutoscalingHeartbeatState {
    param(
        [Parameter(Mandatory)] [long] $InitialCount,
        [datetime] $ObservedAt = (Get-Date)
    )

    return @{
        First          = [long] $InitialCount
        Last           = [long] $InitialCount
        LastAdvancedAt = $ObservedAt
    }
}

function Get-AutoscalingLoadPodHeartbeatCount {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $PodName
    )

    $logs = Invoke-KubectlChecked `
        -KubectlArgs @("logs", "--namespace", $Namespace, $PodName, "--tail", "20") `
        -ErrorContext "Could not read load pod '$PodName' logs to verify traffic generation"
    return Get-AutoscalingHeartbeatCountFromLogs -Logs ([string] $logs)
}

function Confirm-AutoscalingLoadPodTraffic {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $PodName
    )

    $deadline = (Get-Date).AddSeconds(60)
    $logs = ""
    do {
        $logs = Invoke-KubectlChecked `
            -KubectlArgs @("logs", "--namespace", $Namespace, $PodName, "--tail", "100") `
            -ErrorContext "Could not read load pod '$PodName' logs to verify traffic generation"
        if ($logs -match "pulsestream-autoscaling-load heartbeat") {
            Confirm-AutoscalingLoadPodRunning -Namespace $Namespace -PodName $PodName
            Write-Host "[ok] load pod '$PodName' reached its real traffic path and is generating traffic"
            return (Get-AutoscalingHeartbeatCountFromLogs -Logs ([string] $logs))
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    Confirm-Condition `
        -Condition $false `
        -SuccessMessage "load pod '$PodName' reached its real traffic path and is generating traffic" `
        -FailureMessage "load pod '$PodName' has not emitted a traffic heartbeat. Its image, shell, base64 prerequisite, service/Kafka route, or producer may have failed. Last logs: $logs" `
        -Permanent
}

function Assert-AutoscalingLoadPodHeartbeatAdvancing {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $PodName,
        [Parameter(Mandatory)] [hashtable] $State,
        [Parameter(Mandatory)] [int] $StallSeconds
    )

    $entry = $State[$PodName]
    $count = Get-AutoscalingLoadPodHeartbeatCount -Namespace $Namespace -PodName $PodName
    $now = Get-Date

    if ($null -ne $count -and $count -gt $entry.Last) {
        $entry.Last = $count
        $entry.LastAdvancedAt = $now
        return
    }

    $stalledSeconds = [int] [math]::Round(($now - $entry.LastAdvancedAt).TotalSeconds)
    if ($stalledSeconds -le $StallSeconds) {
        return
    }

    Confirm-Condition `
        -Condition $false `
        -SuccessMessage "load pod '$PodName' is still generating traffic" `
        -FailureMessage "load pod '$PodName' has not advanced its traffic counter past $($entry.Last) for ${stalledSeconds}s, over the ${StallSeconds}s budget. The generator started but stopped producing, so later samples measure an idle service rather than one under load" `
        -Permanent
}

Export-ModuleMember -Function `
    New-AutoscalingShellCommand, `
    New-AutoscalingLoadBootstrapCommand, `
    Get-AutoscalingTimingRequirements, `
    Start-AutoscalingLoadPod, `
    Stop-AutoscalingLoadPods, `
    Confirm-AutoscalingLoadPodRunning, `
    Get-AutoscalingHeartbeatCountFromLogs, `
    New-AutoscalingHeartbeatState, `
    Get-AutoscalingLoadPodHeartbeatCount, `
    Confirm-AutoscalingLoadPodTraffic, `
    Assert-AutoscalingLoadPodHeartbeatAdvancing
