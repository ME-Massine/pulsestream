# Offline structure and failure-shield checks for the Grafana Kubernetes base.
# No cluster, kubectl, Docker, or network is required.
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamYaml.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamGrafana.psm1") -Force

$script:DeploymentManifest = Join-Path $PSScriptRoot "..\..\infrastructure\kubernetes\monitoring\grafana\deployment.yaml"
$script:ServiceManifest = Join-Path $PSScriptRoot "..\..\infrastructure\kubernetes\monitoring\grafana\service.yaml"
$script:PvcManifest = Join-Path $PSScriptRoot "..\..\infrastructure\kubernetes\monitoring\grafana\pvc.yaml"
$script:DeploymentGuide = Join-Path $PSScriptRoot "..\..\infrastructure\kubernetes\monitoring\grafana\DEPLOYMENT.md"
$script:LiveValidator = Join-Path $PSScriptRoot "..\validate-grafana-deployment.ps1"

function Assert-ValidatorRejects {
    param(
        [Parameter(Mandatory)] [ValidateSet("Deployment", "Service", "Pvc")] [string] $Manifest,
        [Parameter(Mandatory)] [scriptblock] $Mutation,
        [Parameter(Mandatory)] [string] $ExpectedMessage,
        [Parameter(Mandatory)] [string] $Description
    )

    $path = switch ($Manifest) {
        "Deployment" { $script:DeploymentManifest }
        "Service" { $script:ServiceManifest }
        "Pvc" { $script:PvcManifest }
    }
    $object = ConvertFrom-KubernetesYaml -Path $path
    & $Mutation $object

    try {
        switch ($Manifest) {
            "Deployment" { Confirm-GrafanaDeployment -Deployment $object }
            "Service" { Confirm-GrafanaService -Service $object }
            "Pvc" { Confirm-GrafanaPvc -Pvc $object }
        }
    } catch {
        if ($_.Exception.Message -match $ExpectedMessage) {
            Write-Host "[ok] $Description"
            return
        }

        throw "Expected a rejection matching '$ExpectedMessage' for $Description, got: $($_.Exception.Message)"
    }

    throw "The Grafana validator accepted $Description."
}

Confirm-GrafanaDeployment -Deployment (ConvertFrom-KubernetesYaml -Path $script:DeploymentManifest)
Confirm-GrafanaService -Service (ConvertFrom-KubernetesYaml -Path $script:ServiceManifest)
Confirm-GrafanaPvc -Pvc (ConvertFrom-KubernetesYaml -Path $script:PvcManifest)

$healthProxyPath = Get-GrafanaServiceProxyPath `
    -Namespace "monitoring" -ServiceName "grafana" -Path "/api/health"
if ($healthProxyPath -ne "/api/v1/namespaces/monitoring/services/http:grafana:http/proxy/api/health") {
    throw "Grafana Service proxy path is malformed: '$healthProxyPath'."
}
Write-Host "[ok] Grafana Service proxy path preserves the service name between colons"

Assert-ValidatorRejects -Manifest Deployment `
    -Mutation { param($deployment) $deployment.spec.replicas = 2 } `
    -ExpectedMessage "replicas is '2', not 1" `
    -Description "a second SQLite writer was rejected"

Assert-ValidatorRejects -Manifest Deployment `
    -Mutation { param($deployment) $deployment.spec.strategy.type = "RollingUpdate" } `
    -ExpectedMessage "strategy must be Recreate" `
    -Description "a rolling update against the single-writer volume was rejected"

Assert-ValidatorRejects -Manifest Deployment `
    -Mutation { param($deployment) $deployment.spec.progressDeadlineSeconds = 2399 } `
    -ExpectedMessage "another 1200 seconds in progressDeadlineSeconds" `
    -Description "a rollout deadline without the required startup overhead was rejected"

Assert-ValidatorRejects -Manifest Deployment `
    -Mutation { param($deployment) $deployment.spec.template.spec.containers[0].image = "grafana/grafana:latest" } `
    -ExpectedMessage "must use grafana/grafana:<version>@sha256:<digest>" `
    -Description "a mutable Grafana image was rejected"

Assert-ValidatorRejects -Manifest Deployment `
    -Mutation {
        param($deployment)
        $password = @($deployment.spec.template.spec.containers[0].env | Where-Object { $_.name -eq "GF_SECURITY_ADMIN_PASSWORD" })[0]
        $password.PSObject.Properties.Remove('valueFrom')
        $password | Add-Member -NotePropertyName value -NotePropertyValue "admin"
    } `
    -ExpectedMessage "GF_SECURITY_ADMIN_PASSWORD must come only from Secret/grafana" `
    -Description "a plaintext admin password was rejected"

Assert-ValidatorRejects -Manifest Deployment `
    -Mutation {
        param($deployment)
        $setting = @($deployment.spec.template.spec.containers[0].env | Where-Object { $_.name -eq "GF_PLUGINS_PREINSTALL_AUTO_UPDATE" })[0]
        $setting.value = "true"
    } `
    -ExpectedMessage "GF_PLUGINS_PREINSTALL_DISABLED='true'" `
    -Description "automatic mutation of bundled plugins was rejected"

Assert-ValidatorRejects -Manifest Deployment `
    -Mutation {
        param($deployment)
        $data = @($deployment.spec.template.spec.volumes | Where-Object { $_.name -eq "data" })[0]
        $data.PSObject.Properties.Remove('persistentVolumeClaim')
        $data | Add-Member -NotePropertyName emptyDir -NotePropertyValue ([pscustomobject] @{})
    } `
    -ExpectedMessage "data volume must use PersistentVolumeClaim/grafana-data" `
    -Description "ephemeral Grafana state was rejected"

Assert-ValidatorRejects -Manifest Service `
    -Mutation { param($service) $service.spec.type = "NodePort" } `
    -ExpectedMessage "not ClusterIP" `
    -Description "an externally exposed Grafana Service was rejected"

Assert-ValidatorRejects -Manifest Pvc `
    -Mutation { param($pvc) $pvc.spec.accessModes = @("ReadWriteMany") } `
    -ExpectedMessage "must use only ReadWriteOnce" `
    -Description "a PVC contract inconsistent with the SQLite deployment was rejected"

$deploymentGuide = Get-Content -Raw $script:DeploymentGuide
if ($deploymentGuide -match '--from-literal') {
    throw "Grafana bootstrap documentation must not place credentials in kubectl process arguments."
}
if ($deploymentGuide -notmatch 'ConvertTo-Json[\s\S]*kubectl apply -f -') {
    throw "Grafana bootstrap documentation must send an in-memory Secret manifest to kubectl over stdin."
}
if ($deploymentGuide -notmatch '\$OutputEncoding = \[Text\.UTF8Encoding\]::new\(\$false\)') {
    throw "Grafana bootstrap documentation must preserve non-ASCII credentials when writing to native stdin."
}
Write-Host "[ok] Grafana bootstrap credentials are documented without password-bearing process arguments"

$tokens = $null
$parseErrors = $null
$validatorAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $script:LiveValidator,
    [ref] $tokens,
    [ref] $parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Grafana live validator has parser errors: $($parseErrors.Message -join '; ')"
}
$endpointRetries = @($validatorAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq "Invoke-WithRetry" -and
        $node.Extent.Text -match 'EndpointTimeoutSeconds' -and
        $node.Extent.Text -match 'endpointslices'
}, $true))
if ($endpointRetries.Count -ne 1) {
    throw "Grafana live validator must poll EndpointSlices once with the bounded endpoint timeout."
}
Write-Host "[ok] Grafana live validation polls EndpointSlices with a bounded timeout"

Write-Host "[ok] Grafana deployment structure checks behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
