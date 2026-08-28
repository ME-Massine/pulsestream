# Shared kubectl helpers for the PulseStream Kubernetes validation scripts.
#
# Extracted from validate-kafka-kubernetes.ps1 (#139) when the broker health and
# connectivity checks (#142) needed the same primitives: the stderr handling and
# the client-pod lifecycle below are subtle enough that a second copy would drift
# from this one.

# kubectl writes progress and warnings to stderr even on success (for example
# "Warning: spec.SessionAffinity is ignored for headless services"). PowerShell
# turns native stderr into error records, so every call is routed through this
# helper: stderr is merged into the output stream and only the process exit code
# decides success. See validate-dlq-pipeline.ps1 for the same pattern applied to
# docker exec.
function Invoke-Kubectl {
    param([Parameter(Mandatory)] [string[]] $KubectlArgs)

    # Merging stderr is not enough on its own: with $ErrorActionPreference set
    # to Stop, PowerShell turns each native stderr line into a terminating
    # error, so a harmless kubectl warning would abort the whole script. The
    # preference is relaxed for the duration of the call only; the exit code
    # below is what actually decides success.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & kubectl @KubectlArgs 2>&1 | ForEach-Object { $_.ToString() }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = (@($output) -join [Environment]::NewLine)
    }
}

function Invoke-KubectlChecked {
    param(
        [Parameter(Mandatory)] [string[]] $KubectlArgs,
        [Parameter(Mandatory)] [string] $ErrorContext
    )

    $result = Invoke-Kubectl -KubectlArgs $KubectlArgs
    if ($result.ExitCode -ne 0) {
        throw "$ErrorContext (exit $($result.ExitCode)). $($result.Output)"
    }

    return $result.Output
}

function Invoke-KubectlJsonChecked {
    param(
        [Parameter(Mandatory)] [string[]] $KubectlArgs,
        [Parameter(Mandatory)] [string] $ErrorContext,
        [ValidateRange(1, 10)] [int] $MaxAttempts = 3,
        [ValidateRange(0, 30)] [int] $RetryDelaySeconds = 2
    )

    $lastFailure = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-Kubectl -KubectlArgs $KubectlArgs
        if ($result.ExitCode -eq 0) {
            $raw = $result.Output.Trim()
            try {
                return $raw | ConvertFrom-Json -ErrorAction Stop
            } catch {
                # kubectl can emit a client warning on stderr while returning
                # valid JSON on stdout. Invoke-Kubectl merges those streams for
                # Windows PowerShell 5.1, so recover the JSON object if present.
                $firstBrace = $raw.IndexOf("{")
                $lastBrace = $raw.LastIndexOf("}")
                if ($firstBrace -ge 0 -and $lastBrace -gt $firstBrace) {
                    try {
                        return $raw.Substring($firstBrace, $lastBrace - $firstBrace + 1) |
                            ConvertFrom-Json -ErrorAction Stop
                    } catch {
                        # Retry below, preserving the full output for diagnosis.
                    }
                }

                $lastFailure = "kubectl returned invalid JSON: $raw"
            }
        } else {
            $lastFailure = "kubectl exited $($result.ExitCode): $($result.Output.Trim())"
        }

        if ($attempt -lt $MaxAttempts -and $RetryDelaySeconds -gt 0) {
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    throw "$ErrorContext after $MaxAttempts attempt(s). $lastFailure"
}

# Pods matching `app.kubernetes.io/name=$AppName` whose Ready condition is
# True. Used everywhere a check needs to compare "what should be scraped/
# metriced" against the workload's actual Ready replicas, rather than trusting
# a non-empty response - a target list or metric response that only covers
# some of them is a silent partial failure (see Confirm-PodsMetricCoverage,
# PulseStreamAutoscaling.psm1).
function Get-ReadyPodNames {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $AppName
    )

    $pods = Invoke-KubectlJsonChecked `
        -KubectlArgs @("get", "pods", "--namespace", $Namespace, "-l", "app.kubernetes.io/name=$AppName", "-o", "json") `
        -ErrorContext "Could not list '$AppName' pods in namespace '$Namespace'"

    return @($pods.items | Where-Object {
        $readyCondition = @($_.status.conditions | Where-Object { $_.type -eq "Ready" }) | Select-Object -First 1
        $null -ne $readyCondition -and $readyCondition.status -eq "True"
    } | ForEach-Object { $_.metadata.name })
}

function Get-KubectlJsonPath {
    param(
        [Parameter(Mandatory)] [string[]] $KubectlArgs,
        [Parameter(Mandatory)] [string] $ErrorContext
    )

    (Invoke-KubectlChecked -KubectlArgs $KubectlArgs -ErrorContext $ErrorContext).Trim()
}

# Stable identity shared by the #146 connectivity validator and the #147
# NetworkPolicy structural checks. Keeping it here prevents the producer and
# consumer of the labels from drifting independently.
function Get-ServiceConnectivityProbeLabels {
    return @{
        "app.kubernetes.io/name"    = "service-connectivity-probe"
        "app.kubernetes.io/part-of" = "pulsestream"
    }
}

# Runs a command from a short-lived pod that is NOT one of the pods under test.
# This is the point of the connectivity checks: running a Kafka CLI command
# inside a broker pod would pass even if the Services were broken, because the
# broker would be talking to itself over localhost.
function Invoke-KafkaClientCommand {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $PodName,
        [Parameter(Mandatory)] [string] $Image,
        [Parameter(Mandatory)] [string] $Command,
        # Optional labels for callers whose temporary pod needs an explicit
        # NetworkPolicy identity. Sorted before serialization so diagnostics
        # and tests stay deterministic across PowerShell editions.
        [hashtable] $PodLabels = @{},
        # Interpreter inside the pod. bash is the default because the Strimzi
        # Kafka image the connectivity checks use carries it, but a minimal debug
        # image (e.g. curlimages/curl, which is Alpine and ships only sh) has no
        # bash, so validate-service-connectivity.ps1 runs its probes with sh.
        # base64 is a busybox applet there, so the decode below still works.
        [string] $Shell = "bash",
        [int] $TimeoutSeconds = 300
    )

    # The command is handed to the pod base64-encoded rather than as literal
    # shell text. Windows PowerShell 5.1 does not escape embedded double quotes
    # when it builds the command line for a native executable, so a snippet
    # containing `cluster_id="$(...)"` reaches kubectl with broken argument
    # boundaries: bash then receives the fragments as separate words and fails
    # with `unexpected EOF while looking for matching ')'`. Base64 output is
    # alphanumerics, `+`, `/` and `=` only, so nothing in it can be re-split.
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Command))

    # Deliberately not `kubectl run --rm --attach`: attaching races the
    # container start, so the command's first lines are sometimes lost and the
    # check fails intermittently on output it never received. Creating the pod,
    # waiting for it to terminate, and then reading its logs is deterministic.
    $labelArgs = @()
    if ($PodLabels.Count -gt 0) {
        $serializedLabels = @($PodLabels.GetEnumerator() |
            Sort-Object -Property Key |
            ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ","
        $labelArgs = @("--labels", $serializedLabels)
    }

    $createArgs = @(
        "run", $PodName,
        "--namespace", $Namespace,
        "--restart=Never"
    ) + $labelArgs + @(
        "--image", $Image,
        "--command", "--",
        $Shell, "-c", "echo $encodedCommand | base64 -d | $Shell"
    )
    $created = Invoke-Kubectl -KubectlArgs $createArgs

    if ($created.ExitCode -ne 0) {
        return [pscustomobject]@{ ExitCode = $created.ExitCode; Output = $created.Output }
    }

    try {
        $phase = $null
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

        while ((Get-Date) -lt $deadline) {
            $phaseResult = Invoke-Kubectl -KubectlArgs @(
                "get", "pod", $PodName, "--namespace", $Namespace, "-o", "jsonpath={.status.phase}"
            )

            $phase = $phaseResult.Output.Trim()
            if ($phase -eq "Succeeded" -or $phase -eq "Failed") {
                break
            }

            Start-Sleep -Seconds 2
        }

        $logs = Invoke-Kubectl -KubectlArgs @("logs", $PodName, "--namespace", $Namespace)

        # A pod that never terminated is reported as a failure rather than
        # letting the caller parse partial output as if the command had run.
        $exitCode = if ($phase -eq "Succeeded") { 0 } else { 1 }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $logs.Output
        }
    } finally {
        Invoke-Kubectl -KubectlArgs @(
            "delete", "pod", $PodName, "--namespace", $Namespace, "--ignore-not-found", "--wait=false"
        ) | Out-Null
    }
}

Export-ModuleMember -Function Invoke-Kubectl, Invoke-KubectlChecked, Invoke-KubectlJsonChecked, Get-KubectlJsonPath, Get-ReadyPodNames, Get-ServiceConnectivityProbeLabels, Invoke-KafkaClientCommand
