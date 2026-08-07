# Regression coverage for optional labels on Invoke-KafkaClientCommand.
# The service-connectivity probe needs a stable NetworkPolicy identity, while
# the existing Kafka callers must remain unchanged when no labels are supplied.
#
# No cluster is used. A temporary PowerShell function stands in for kubectl and
# records the exact native argument arrays assembled by the module.
#
#   powershell -File scripts\tests\test-kubernetes-helper-labels.ps1
#   pwsh -File scripts/tests/test-kubernetes-helper-labels.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$script:Failures = 0
$global:PulseStreamKubectlCalls = [System.Collections.Generic.List[object]]::new()

function global:kubectl {
    param([Parameter(ValueFromRemainingArguments = $true)] [object[]] $Arguments)

    $stringArguments = [string[]] @($Arguments | ForEach-Object { $_.ToString() })
    $global:PulseStreamKubectlCalls.Add([pscustomobject]@{ Arguments = $stringArguments }) | Out-Null
    $global:LASTEXITCODE = 0

    switch ($stringArguments[0]) {
        "run" { "pod created" }
        "get" { "Succeeded" }
        "logs" { "PROBE-OK" }
        "delete" { "pod deleted" }
        default {
            $global:LASTEXITCODE = 1
            "unexpected kubectl operation: $($stringArguments -join ' ')"
        }
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)] [string] $What,
        $Expected,
        $Actual
    )

    if ($Expected -eq $Actual) {
        Write-Host "[ok] $What -> $Actual"
        return
    }

    Write-Host "[fail] $What -> expected '$Expected', got '$Actual'"
    $script:Failures++
}

function Assert-True {
    param(
        [Parameter(Mandatory)] [string] $What,
        [Parameter(Mandatory)] [bool] $Condition
    )

    if ($Condition) {
        Write-Host "[ok] $What"
        return
    }

    Write-Host "[fail] $What"
    $script:Failures++
}

try {
    Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamKubernetes.psm1") -Force

    $labels = Get-ServiceConnectivityProbeLabels
    Assert-Equal -What "probe identity has two labels" -Expected 2 -Actual $labels.Count
    $result = Invoke-KafkaClientCommand `
        -Namespace "default" `
        -PodName "labelled-probe" `
        -Image "curlimages/curl:8.11.1" `
        -Command "echo probe" `
        -PodLabels $labels `
        -Shell "sh" `
        -TimeoutSeconds 5

    Assert-Equal -What "labelled probe succeeds" -Expected 0 -Actual $result.ExitCode
    Assert-Equal -What "labelled probe logs are returned" -Expected "PROBE-OK" -Actual $result.Output

    $labelledRun = @($global:PulseStreamKubectlCalls |
        Where-Object { $_.Arguments[0] -eq "run" -and $_.Arguments[1] -eq "labelled-probe" })[0].Arguments
    $labelsIndex = [Array]::IndexOf($labelledRun, "--labels")
    Assert-True -What "kubectl run receives --labels" -Condition ($labelsIndex -ge 0)
    Assert-Equal `
        -What "labels are serialized deterministically" `
        -Expected "app.kubernetes.io/name=service-connectivity-probe,app.kubernetes.io/part-of=pulsestream" `
        -Actual $labelledRun[$labelsIndex + 1]

    $null = Invoke-KafkaClientCommand `
        -Namespace "default" `
        -PodName "unlabelled-probe" `
        -Image "strimzi/kafka:latest" `
        -Command "echo probe" `
        -TimeoutSeconds 5

    $unlabelledRun = @($global:PulseStreamKubectlCalls |
        Where-Object { $_.Arguments[0] -eq "run" -and $_.Arguments[1] -eq "unlabelled-probe" })[0].Arguments
    Assert-True -What "existing callers omit --labels by default" -Condition (-not ($unlabelledRun -contains "--labels"))

    $deletes = @($global:PulseStreamKubectlCalls | Where-Object { $_.Arguments[0] -eq "delete" })
    Assert-Equal -What "both temporary pods are cleaned up" -Expected 2 -Actual $deletes.Count
} finally {
    Remove-Item -LiteralPath Function:\kubectl -ErrorAction SilentlyContinue
    Remove-Variable -Name PulseStreamKubectlCalls -Scope Global -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    throw "$script:Failures Kubernetes helper label check(s) failed."
}

Write-Host "[ok] Kubernetes helper label handling is consistent on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
