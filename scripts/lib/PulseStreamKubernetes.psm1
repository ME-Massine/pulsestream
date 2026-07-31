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

function Get-KubectlJsonPath {
    param(
        [Parameter(Mandatory)] [string[]] $KubectlArgs,
        [Parameter(Mandatory)] [string] $ErrorContext
    )

    (Invoke-KubectlChecked -KubectlArgs $KubectlArgs -ErrorContext $ErrorContext).Trim()
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
    $created = Invoke-Kubectl -KubectlArgs @(
        "run", $PodName,
        "--namespace", $Namespace,
        "--restart=Never",
        "--image", $Image,
        "--command", "--",
        "bash", "-c", "echo $encodedCommand | base64 -d | bash"
    )

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

Export-ModuleMember -Function Invoke-Kubectl, Invoke-KubectlChecked, Get-KubectlJsonPath, Invoke-KafkaClientCommand
