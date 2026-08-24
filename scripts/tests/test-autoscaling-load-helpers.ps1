# Offline tests for the pure load-command and heartbeat helpers used by
# validate-autoscaling-behavior.ps1. No cluster is required.
#
#   pwsh -File scripts/tests/test-autoscaling-load-helpers.ps1
#   powershell -File scripts/tests/test-autoscaling-load-helpers.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamAutoscalingLoad.psm1") -Force

function Assert-Equal {
    param(
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] [string] $Description
    )

    if ($Expected -ne $Actual) {
        throw "$Description. Expected '$Expected', got '$Actual'."
    }
    Write-Host "[ok] $Description"
}

$rendered = New-AutoscalingShellCommand `
    -Template "run={{RUN}}`r`npod={{POD}}`r" `
    -Values @{ RUN = "abc123"; POD = 2 }
Assert-Equal `
    -Expected "run=abc123`npod=2`n" `
    -Actual $rendered `
    -Description "shell templates replace all placeholders and normalize CRLF"

$originalCommand = @'
printf '%s\n' '{"eventId":"evt_1","value":95.5}'
'@
$bootstrap = New-AutoscalingLoadBootstrapCommand -Command $originalCommand -Shell "sh"
if ($bootstrap -notmatch "command -v base64") {
    throw "The load bootstrap does not explicitly check its base64 prerequisite."
}
if ($bootstrap -notmatch "missing required command: base64") {
    throw "The load bootstrap does not provide a useful diagnostic for a minimal image without base64."
}

$encodedMatch = [regex]::Match($bootstrap, "printf '%s' '([A-Za-z0-9+/=]+)' \| base64 -d")
if (-not $encodedMatch.Success) {
    throw "Could not locate the encoded load command in the bootstrap: $bootstrap"
}
$decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedMatch.Groups[1].Value))
Assert-Equal `
    -Expected $originalCommand `
    -Actual $decoded `
    -Description "load bootstrap preserves multiline shell and embedded JSON exactly"

$timing = Get-AutoscalingTimingRequirements `
    -SampleIntervalSeconds 15 `
    -MinReplicas 2 `
    -MaxReplicas 6 `
    -ScaleDownWindowSeconds 300 `
    -ScaleUpPolicyPeriodsSeconds @(15, 60) `
    -ScaleDownPolicyPeriodsSeconds @(60)
Assert-Equal `
    -Expected 90 `
    -Actual $timing.MinimumLoadDurationSeconds `
    -Description "minimum load duration spans the slowest scale-up policy plus two samples"
Assert-Equal `
    -Expected 555 `
    -Actual $timing.MinimumScaleDownTimeoutSeconds `
    -Description "minimum scale-down timeout covers stabilization, every possible replica step, and a final sample"

$logs = @'
pulsestream-autoscaling-load heartbeat http 10
unrelated output
pulsestream-autoscaling-load heartbeat http 42
pulsestream-autoscaling-load heartbeat http 31
'@
Assert-Equal `
    -Expected ([long] 42) `
    -Actual (Get-AutoscalingHeartbeatCountFromLogs -Logs $logs) `
    -Description "heartbeat parsing returns the highest counter even when log lines arrive out of order"

$missing = Get-AutoscalingHeartbeatCountFromLogs -Logs "generator started but has no heartbeat"
if ($null -ne $missing) {
    throw "A log without a heartbeat returned '$missing' instead of null."
}
Write-Host "[ok] a missing heartbeat remains null rather than becoming zero"

$largeCounter = [long]::MaxValue - 1
Assert-Equal `
    -Expected $largeCounter `
    -Actual (Get-AutoscalingHeartbeatCountFromLogs -Logs "pulsestream-autoscaling-load heartbeat kafka $largeCounter") `
    -Description "heartbeat counters do not overflow the 32-bit range"

$observedAt = [datetime] "2026-08-24T00:00:00Z"
$largeState = New-AutoscalingHeartbeatState -InitialCount $largeCounter -ObservedAt $observedAt
Assert-Equal `
    -Expected $largeCounter `
    -Actual $largeState.First `
    -Description "heartbeat state preserves a 64-bit initial counter"
Assert-Equal `
    -Expected $largeCounter `
    -Actual $largeState.Last `
    -Description "heartbeat state preserves a 64-bit latest counter"
Assert-Equal `
    -Expected "System.Int64" `
    -Actual $largeState.First.GetType().FullName `
    -Description "heartbeat state does not narrow the initial counter to Int32"
Assert-Equal `
    -Expected $observedAt `
    -Actual $largeState.LastAdvancedAt `
    -Description "heartbeat state records the supplied observation time"

Write-Host "[ok] autoscaling load helpers behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
