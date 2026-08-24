# Validates the deployed Grafana base for issue #155 against a live cluster.
#
# This deliberately stops at deployment, storage, Service routing, health, and
# UI access. Prometheus datasource and dashboard validation belong to #156.
[CmdletBinding()]
param(
    [string] $Namespace = "monitoring",
    [string] $DeploymentName = "grafana",
    [string] $ServiceName = "grafana",
    [string] $PvcName = "grafana-data",
    [int] $RolloutTimeoutSeconds = 1500,
    [ValidateRange(5, 300)] [int] $StabilityWindowSeconds = 20
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamKubernetes.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamGrafana.psm1") -Force

function Assert-LiveCondition {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $SuccessMessage,
        [Parameter(Mandatory)] [string] $FailureMessage
    )

    if (-not $Condition) {
        throw $FailureMessage
    }

    Write-Host "[ok] $SuccessMessage"
}

function Get-KubernetesObject {
    param(
        [Parameter(Mandatory)] [string] $Kind,
        [Parameter(Mandatory)] [string] $Name
    )

    $json = Invoke-KubectlChecked `
        -KubectlArgs @("get", $Kind, $Name, "--namespace", $Namespace, "-o", "json") `
        -ErrorContext "Could not read $Kind/$Name from namespace '$Namespace'"
    return $json | ConvertFrom-Json
}

function Get-GrafanaPodSnapshot {
    $podListJson = Invoke-KubectlChecked `
        -KubectlArgs @(
            "get", "pods", "--namespace", $Namespace,
            "--selector", "app.kubernetes.io/name=grafana", "-o", "json"
        ) `
        -ErrorContext "Could not list Grafana pods"
    $pods = @(($podListJson | ConvertFrom-Json).items)

    Assert-LiveCondition `
        -Condition ($pods.Count -eq 1) `
        -SuccessMessage "exactly one Grafana pod exists" `
        -FailureMessage "Expected exactly one Grafana pod, found $($pods.Count)."

    $pod = $pods[0]
    $ready = @($pod.status.conditions | Where-Object { $_.type -eq "Ready" }) | Select-Object -First 1
    Assert-LiveCondition `
        -Condition ($pod.status.phase -eq "Running" -and $ready.status -eq "True") `
        -SuccessMessage "Grafana pod '$($pod.metadata.name)' is Running and Ready" `
        -FailureMessage "Grafana pod '$($pod.metadata.name)' is phase '$($pod.status.phase)' with Ready='$($ready.status)'."

    return [pscustomobject]@{
        Name         = [string] $pod.metadata.name
        Uid          = [string] $pod.metadata.uid
        RestartCount = [int] (@($pod.status.containerStatuses | Measure-Object -Property restartCount -Sum).Sum)
    }
}

function Get-GrafanaHealth {
    $proxyPath = Get-GrafanaServiceProxyPath `
        -Namespace $Namespace -ServiceName $ServiceName -Path "/api/health"
    $json = Invoke-KubectlChecked `
        -KubectlArgs @("get", "--raw", $proxyPath) `
        -ErrorContext "Grafana /api/health was not reachable through Service/$ServiceName"

    try {
        return $json | ConvertFrom-Json
    } catch {
        throw "Grafana /api/health did not return JSON. $($_.Exception.Message)"
    }
}

Write-Host "Validating Grafana Deployment/$DeploymentName in namespace '$Namespace'..."

$context = Invoke-KubectlChecked `
    -KubectlArgs @("config", "current-context") `
    -ErrorContext "kubectl has no usable current context"
Write-Host "[info] Kubernetes context: $($context.Trim())"

$namespaceObject = Invoke-Kubectl `
    -KubectlArgs @("get", "namespace", $Namespace, "-o", "name")
Assert-LiveCondition `
    -Condition ($namespaceObject.ExitCode -eq 0) `
    -SuccessMessage "namespace/$Namespace exists" `
    -FailureMessage "Namespace '$Namespace' does not exist. Apply infrastructure/kubernetes/monitoring/namespace.yaml first."

$deployment = Get-KubernetesObject -Kind "deployment" -Name $DeploymentName
$service = Get-KubernetesObject -Kind "service" -Name $ServiceName
$pvc = Get-KubernetesObject -Kind "pvc" -Name $PvcName
Confirm-GrafanaDeployment -Deployment $deployment
Confirm-GrafanaService -Service $service
Confirm-GrafanaPvc -Pvc $pvc

$secretJson = Invoke-KubectlChecked `
    -KubectlArgs @("get", "secret", "grafana", "--namespace", $Namespace, "-o", "json") `
    -ErrorContext "Secret/grafana is missing; create the bootstrap credentials described in DEPLOYMENT.md"
$secret = $secretJson | ConvertFrom-Json
$adminUser = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string] $secret.data.'admin-user'))
$adminPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string] $secret.data.'admin-password'))
Assert-LiveCondition `
    -Condition (-not [string]::IsNullOrWhiteSpace($adminUser)) `
    -SuccessMessage "Secret/grafana contains a non-empty admin-user" `
    -FailureMessage "Secret/grafana key 'admin-user' is missing or empty."
Assert-LiveCondition `
    -Condition (-not [string]::IsNullOrWhiteSpace($adminPassword) -and $adminPassword -notin @("admin", "REPLACE_ME", "changeme")) `
    -SuccessMessage "Secret/grafana contains a non-default admin password" `
    -FailureMessage "Secret/grafana key 'admin-password' is missing or uses an unsafe placeholder/default."
# Do not retain or print the decoded credentials beyond the checks above.
$adminUser = $null
$adminPassword = $null

$rollout = Invoke-KubectlChecked `
    -KubectlArgs @(
        "rollout", "status", "deployment/$DeploymentName", "--namespace", $Namespace,
        "--timeout=$($RolloutTimeoutSeconds)s"
    ) `
    -ErrorContext "Grafana Deployment did not complete its rollout"
Write-Host "[ok] $($rollout.Trim())"

$deployment = Get-KubernetesObject -Kind "deployment" -Name $DeploymentName
$pvc = Get-KubernetesObject -Kind "pvc" -Name $PvcName
Assert-LiveCondition `
    -Condition (
        $deployment.status.observedGeneration -eq $deployment.metadata.generation -and
        $deployment.status.updatedReplicas -eq 1 -and
        $deployment.status.readyReplicas -eq 1 -and
        $deployment.status.availableReplicas -eq 1 -and
        $deployment.status.unavailableReplicas -in @($null, 0)
    ) `
    -SuccessMessage "Deployment generation is observed with one updated, Ready, Available replica" `
    -FailureMessage "Grafana Deployment is not fully converged (generation=$($deployment.metadata.generation), observed=$($deployment.status.observedGeneration), updated=$($deployment.status.updatedReplicas), ready=$($deployment.status.readyReplicas), available=$($deployment.status.availableReplicas), unavailable=$($deployment.status.unavailableReplicas))."

Assert-LiveCondition `
    -Condition ($pvc.status.phase -eq "Bound") `
    -SuccessMessage "PersistentVolumeClaim/$PvcName is Bound" `
    -FailureMessage "PersistentVolumeClaim/$PvcName is '$($pvc.status.phase)', not Bound. Check the cluster's default StorageClass."

$firstSnapshot = Get-GrafanaPodSnapshot

$endpointSliceJson = Invoke-KubectlChecked `
    -KubectlArgs @(
        "get", "endpointslices", "--namespace", $Namespace,
        "--selector", "kubernetes.io/service-name=$ServiceName", "-o", "json"
    ) `
    -ErrorContext "Could not read EndpointSlices for Service/$ServiceName"
$endpointSlices = @(($endpointSliceJson | ConvertFrom-Json).items)
$readyEndpoints = @(
    $endpointSlices.endpoints |
        Where-Object { $_.conditions.ready -eq $true }
)
Assert-LiveCondition `
    -Condition ($readyEndpoints.Count -eq 1 -and $readyEndpoints[0].targetRef.name -eq $firstSnapshot.Name) `
    -SuccessMessage "Service/$ServiceName has exactly one Ready endpoint for pod '$($firstSnapshot.Name)'" `
    -FailureMessage "Service/$ServiceName must have exactly one Ready endpoint targeting '$($firstSnapshot.Name)'; found $($readyEndpoints.Count)."

$health = Get-GrafanaHealth
Assert-LiveCondition `
    -Condition ($health.database -eq "ok" -and -not [string]::IsNullOrWhiteSpace([string] $health.version)) `
    -SuccessMessage "Grafana API is healthy (database=$($health.database), version=$($health.version))" `
    -FailureMessage "Grafana health response is not healthy (database='$($health.database)', version='$($health.version)')."

$loginPath = Get-GrafanaServiceProxyPath `
    -Namespace $Namespace -ServiceName $ServiceName -Path "/login"
$loginPage = Invoke-KubectlChecked `
    -KubectlArgs @("get", "--raw", $loginPath) `
    -ErrorContext "Grafana login page was not reachable through Service/$ServiceName"
Assert-LiveCondition `
    -Condition ($loginPage -match "grafanaBootData|<title>Grafana</title>") `
    -SuccessMessage "Grafana UI login page is reachable through the Service" `
    -FailureMessage "Service/$ServiceName returned content that is not the Grafana login page."

Write-Host "[info] Sampling pod identity and restarts for $StabilityWindowSeconds seconds..."
Start-Sleep -Seconds $StabilityWindowSeconds
$secondSnapshot = Get-GrafanaPodSnapshot
Assert-LiveCondition `
    -Condition ($secondSnapshot.Uid -eq $firstSnapshot.Uid) `
    -SuccessMessage "Grafana pod UID stayed stable during the sample window" `
    -FailureMessage "Grafana pod was replaced during the $StabilityWindowSeconds-second stability window ('$($firstSnapshot.Uid)' -> '$($secondSnapshot.Uid)')."
Assert-LiveCondition `
    -Condition ($secondSnapshot.RestartCount -eq $firstSnapshot.RestartCount) `
    -SuccessMessage "Grafana container restart count stayed at $($secondSnapshot.RestartCount)" `
    -FailureMessage "Grafana restart count changed from $($firstSnapshot.RestartCount) to $($secondSnapshot.RestartCount) during the stability window."

$health = Get-GrafanaHealth
Assert-LiveCondition `
    -Condition ($health.database -eq "ok") `
    -SuccessMessage "Grafana remained healthy after the stability sample" `
    -FailureMessage "Grafana database health changed to '$($health.database)' after the stability sample."

Write-Host "[ok] Grafana Kubernetes deployment validation completed."
