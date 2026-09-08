# Structural contracts shared by the offline and live Grafana validators.
#
# Keeping the assertions here makes a green manifest test mean the same thing as
# a green check against the objects the API server actually stored.

function Assert-GrafanaCondition {
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

function Get-GrafanaNamedItem {
    param(
        $Items,
        [Parameter(Mandatory)] [string] $Name
    )

    return @($Items | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
}

function Confirm-GrafanaProbe {
    param(
        [Parameter(Mandatory)] $Container,
        [Parameter(Mandatory)] [string] $PropertyName
    )

    $probe = $Container.$PropertyName
    Assert-GrafanaCondition `
        -Condition ($null -ne $probe) `
        -SuccessMessage "Grafana defines $PropertyName" `
        -FailureMessage "Grafana $PropertyName is missing."
    Assert-GrafanaCondition `
        -Condition ($probe.httpGet.path -eq "/api/health" -and $probe.httpGet.port -eq "http") `
        -SuccessMessage "$PropertyName checks /api/health on the named http port" `
        -FailureMessage "Grafana $PropertyName must check /api/health on port 'http'."
}

function Confirm-GrafanaDeployment {
    param([Parameter(Mandatory)] $Deployment)

    Assert-GrafanaCondition `
        -Condition ($Deployment.apiVersion -eq "apps/v1" -and $Deployment.kind -eq "Deployment") `
        -SuccessMessage "Grafana uses an apps/v1 Deployment" `
        -FailureMessage "Grafana must be an apps/v1 Deployment."
    Assert-GrafanaCondition `
        -Condition ($Deployment.metadata.name -eq "grafana" -and $Deployment.metadata.namespace -eq "monitoring") `
        -SuccessMessage "Deployment identity is monitoring/grafana" `
        -FailureMessage "Grafana Deployment must be named 'grafana' in namespace 'monitoring'."
    Assert-GrafanaCondition `
        -Condition ($Deployment.spec.replicas -eq 1) `
        -SuccessMessage "Grafana stays at one SQLite writer" `
        -FailureMessage "Grafana replicas is '$($Deployment.spec.replicas)', not 1; SQLite on a ReadWriteOnce PVC is not an HA backend."
    Assert-GrafanaCondition `
        -Condition ($Deployment.spec.strategy.type -eq "Recreate") `
        -SuccessMessage "Recreate prevents two pods from mounting the SQLite volume during an update" `
        -FailureMessage "Grafana strategy must be Recreate while it uses SQLite on one ReadWriteOnce PVC."
    Assert-GrafanaCondition `
        -Condition ($Deployment.spec.selector.matchLabels.'app.kubernetes.io/name' -eq "grafana" -and $Deployment.spec.template.metadata.labels.'app.kubernetes.io/name' -eq "grafana") `
        -SuccessMessage "Deployment selector matches the Grafana pod label" `
        -FailureMessage "Grafana selector and pod label must both use app.kubernetes.io/name=grafana."
    Assert-GrafanaCondition `
        -Condition ($Deployment.spec.template.spec.automountServiceAccountToken -eq $false) `
        -SuccessMessage "Grafana does not receive an unused Kubernetes API token" `
        -FailureMessage "Grafana must set automountServiceAccountToken to false."

    $podSecurity = $Deployment.spec.template.spec.securityContext
    Assert-GrafanaCondition `
        -Condition ($podSecurity.runAsNonRoot -eq $true -and $podSecurity.runAsUser -eq 472 -and $podSecurity.runAsGroup -eq 472) `
        -SuccessMessage "Grafana runs with non-root numeric uid/gid 472" `
        -FailureMessage "Grafana pod securityContext must run as non-root uid/gid 472."
    Assert-GrafanaCondition `
        -Condition ($podSecurity.fsGroup -eq 472 -and $podSecurity.fsGroupChangePolicy -eq "OnRootMismatch") `
        -SuccessMessage "PVC ownership is reconciled for group 472" `
        -FailureMessage "Grafana pod securityContext must set fsGroup 472 with OnRootMismatch."
    Assert-GrafanaCondition `
        -Condition ($podSecurity.seccompProfile.type -eq "RuntimeDefault") `
        -SuccessMessage "Grafana uses the runtime-default seccomp profile" `
        -FailureMessage "Grafana must use the RuntimeDefault seccomp profile."

    $containers = @($Deployment.spec.template.spec.containers)
    $container = Get-GrafanaNamedItem -Items $containers -Name "grafana"
    Assert-GrafanaCondition `
        -Condition ($containers.Count -eq 1 -and $null -ne $container) `
        -SuccessMessage "Deployment contains one Grafana container" `
        -FailureMessage "Grafana Deployment must contain exactly one container named 'grafana'."

    $image = [string] $container.image
    Assert-GrafanaCondition `
        -Condition ($image -match '^grafana/grafana:\d+\.\d+\.\d+@sha256:[0-9a-f]{64}$') `
        -SuccessMessage "Grafana's official versioned image is pinned by digest" `
        -FailureMessage "Grafana image '$image' must use grafana/grafana:<version>@sha256:<digest>, never a mutable tag."

    $httpPort = Get-GrafanaNamedItem -Items @($container.ports) -Name "http"
    Assert-GrafanaCondition `
        -Condition ($httpPort.containerPort -eq 3000 -and $httpPort.protocol -eq "TCP") `
        -SuccessMessage "Grafana publishes named TCP port http/3000" `
        -FailureMessage "Grafana container must publish TCP 3000 as the named port 'http'."

    $adminUser = Get-GrafanaNamedItem -Items @($container.env) -Name "GF_SECURITY_ADMIN_USER"
    $environmentSetting = Get-GrafanaNamedItem -Items @($container.env) -Name "GF_SECURITY_ADMIN_PASSWORD"
    Assert-GrafanaCondition `
        -Condition ($adminUser.valueFrom.secretKeyRef.name -eq "grafana" -and $adminUser.valueFrom.secretKeyRef.key -eq "admin-user" -and -not $adminUser.PSObject.Properties['value']) `
        -SuccessMessage "Admin username comes from Secret/grafana key admin-user" `
        -FailureMessage "GF_SECURITY_ADMIN_USER must come only from Secret/grafana key 'admin-user'."
    Assert-GrafanaCondition `
        -Condition ($environmentSetting.valueFrom.secretKeyRef.name -eq "grafana" -and $environmentSetting.valueFrom.secretKeyRef.key -eq "admin-password" -and -not $environmentSetting.PSObject.Properties['value']) `
        -SuccessMessage "Admin password comes from Secret/grafana key admin-password" `
        -FailureMessage "GF_SECURITY_ADMIN_PASSWORD must come only from Secret/grafana key 'admin-password'."

    $signup = Get-GrafanaNamedItem -Items @($container.env) -Name "GF_USERS_ALLOW_SIGN_UP"
    Assert-GrafanaCondition `
        -Condition ([string] $signup.value -eq "false") `
        -SuccessMessage "Anonymous self-registration is disabled" `
        -FailureMessage "GF_USERS_ALLOW_SIGN_UP must be 'false'."

    $preinstallDisabled = Get-GrafanaNamedItem -Items @($container.env) -Name "GF_PLUGINS_PREINSTALL_DISABLED"
    $preinstallAutoUpdate = Get-GrafanaNamedItem -Items @($container.env) -Name "GF_PLUGINS_PREINSTALL_AUTO_UPDATE"
    Assert-GrafanaCondition `
        -Condition ([string] $preinstallDisabled.value -eq "true" -and [string] $preinstallAutoUpdate.value -eq "false") `
        -SuccessMessage "Default plugin downloads and bundled-plugin auto-updates are disabled" `
        -FailureMessage "Grafana must set GF_PLUGINS_PREINSTALL_DISABLED='true' and GF_PLUGINS_PREINSTALL_AUTO_UPDATE='false' for deterministic read-only startup."

    foreach ($pathContract in @(
        @{ Name = "GF_PATHS_DATA"; Value = "/var/lib/grafana" },
        @{ Name = "GF_PATHS_LOGS"; Value = "/var/lib/grafana/logs" },
        @{ Name = "GF_PATHS_PLUGINS"; Value = "/var/lib/grafana/plugins" }
    )) {
        $setting = Get-GrafanaNamedItem -Items @($container.env) -Name $pathContract.Name
        Assert-GrafanaCondition `
            -Condition ($setting.value -eq $pathContract.Value) `
            -SuccessMessage "$($pathContract.Name) stays on the persistent data volume" `
            -FailureMessage "$($pathContract.Name) must be '$($pathContract.Value)'."
    }

    foreach ($probeName in @("startupProbe", "readinessProbe", "livenessProbe")) {
        Confirm-GrafanaProbe -Container $container -PropertyName $probeName
    }
    $startupBudgetSeconds = [int] $container.startupProbe.periodSeconds * [int] $container.startupProbe.failureThreshold
    $rolloutOverheadSeconds = 1200
    Assert-GrafanaCondition `
        -Condition ($startupBudgetSeconds -ge 1200 -and $Deployment.spec.progressDeadlineSeconds -ge ($startupBudgetSeconds + $rolloutOverheadSeconds)) `
        -SuccessMessage "Startup and rollout deadlines cover migrations plus scheduling, storage, and image-pull overhead" `
        -FailureMessage "Grafana needs at least a 1200-second startup budget and another $rolloutOverheadSeconds seconds in progressDeadlineSeconds for rollout overhead."

    Assert-GrafanaCondition `
        -Condition ($container.resources.requests.cpu -and $container.resources.requests.memory -and $container.resources.limits.cpu -and $container.resources.limits.memory) `
        -SuccessMessage "Grafana declares CPU and memory requests and limits" `
        -FailureMessage "Grafana must declare CPU and memory requests and limits."

    $containerSecurity = $container.securityContext
    Assert-GrafanaCondition `
        -Condition ($containerSecurity.allowPrivilegeEscalation -eq $false -and $containerSecurity.readOnlyRootFilesystem -eq $true -and @($containerSecurity.capabilities.drop) -contains "ALL") `
        -SuccessMessage "Grafana drops capabilities and keeps its root filesystem read-only" `
        -FailureMessage "Grafana must disable privilege escalation, use a read-only root filesystem, and drop ALL capabilities."

    $dataMount = Get-GrafanaNamedItem -Items @($container.volumeMounts) -Name "data"
    $tmpMount = Get-GrafanaNamedItem -Items @($container.volumeMounts) -Name "tmp"
    Assert-GrafanaCondition `
        -Condition ($dataMount.mountPath -eq "/var/lib/grafana" -and $tmpMount.mountPath -eq "/tmp") `
        -SuccessMessage "Writable data and temporary paths are mounted explicitly" `
        -FailureMessage "Grafana must mount 'data' at /var/lib/grafana and 'tmp' at /tmp."

    $dataVolume = Get-GrafanaNamedItem -Items @($Deployment.spec.template.spec.volumes) -Name "data"
    $tmpVolume = Get-GrafanaNamedItem -Items @($Deployment.spec.template.spec.volumes) -Name "tmp"
    Assert-GrafanaCondition `
        -Condition ($dataVolume.persistentVolumeClaim.claimName -eq "grafana-data") `
        -SuccessMessage "Grafana data uses PersistentVolumeClaim/grafana-data" `
        -FailureMessage "Grafana data volume must use PersistentVolumeClaim/grafana-data."
    Assert-GrafanaCondition `
        -Condition ($null -ne $tmpVolume.emptyDir) `
        -SuccessMessage "Grafana has a disposable writable /tmp volume" `
        -FailureMessage "Grafana tmp volume must be an emptyDir."
}

function Confirm-GrafanaService {
    param([Parameter(Mandatory)] $Service)

    Assert-GrafanaCondition `
        -Condition ($Service.apiVersion -eq "v1" -and $Service.kind -eq "Service") `
        -SuccessMessage "Grafana exposure uses a v1 Service" `
        -FailureMessage "Grafana Service must be a v1 Service."
    Assert-GrafanaCondition `
        -Condition ($Service.metadata.name -eq "grafana" -and $Service.metadata.namespace -eq "monitoring") `
        -SuccessMessage "Service identity is monitoring/grafana" `
        -FailureMessage "Grafana Service must be named 'grafana' in namespace 'monitoring'."
    Assert-GrafanaCondition `
        -Condition ($Service.spec.type -eq "ClusterIP") `
        -SuccessMessage "Grafana is exposed only through a ClusterIP" `
        -FailureMessage "Grafana Service type is '$($Service.spec.type)', not ClusterIP."
    Assert-GrafanaCondition `
        -Condition ($Service.spec.selector.'app.kubernetes.io/name' -eq "grafana") `
        -SuccessMessage "Service selects Grafana pods" `
        -FailureMessage "Grafana Service must select app.kubernetes.io/name=grafana."

    $ports = @($Service.spec.ports)
    $httpPort = Get-GrafanaNamedItem -Items $ports -Name "http"
    Assert-GrafanaCondition `
        -Condition ($ports.Count -eq 1 -and $httpPort.port -eq 80 -and $httpPort.targetPort -eq "http" -and $httpPort.protocol -eq "TCP" -and $null -eq $httpPort.nodePort) `
        -SuccessMessage "Service maps TCP 80 to Grafana's named http port without a NodePort" `
        -FailureMessage "Grafana Service must expose only TCP port 80 to targetPort 'http', without a nodePort."
}

function Confirm-GrafanaPvc {
    param([Parameter(Mandatory)] $Pvc)

    Assert-GrafanaCondition `
        -Condition ($Pvc.apiVersion -eq "v1" -and $Pvc.kind -eq "PersistentVolumeClaim") `
        -SuccessMessage "Grafana storage uses a v1 PersistentVolumeClaim" `
        -FailureMessage "Grafana storage must be a v1 PersistentVolumeClaim."
    Assert-GrafanaCondition `
        -Condition ($Pvc.metadata.name -eq "grafana-data" -and $Pvc.metadata.namespace -eq "monitoring") `
        -SuccessMessage "PVC identity is monitoring/grafana-data" `
        -FailureMessage "Grafana PVC must be named 'grafana-data' in namespace 'monitoring'."
    Assert-GrafanaCondition `
        -Condition (@($Pvc.spec.accessModes).Count -eq 1 -and @($Pvc.spec.accessModes) -contains "ReadWriteOnce") `
        -SuccessMessage "Grafana PVC is a single-writer ReadWriteOnce volume" `
        -FailureMessage "Grafana PVC must use only ReadWriteOnce access."
    Assert-GrafanaCondition `
        -Condition ($Pvc.spec.resources.requests.storage -eq "5Gi") `
        -SuccessMessage "Grafana requests 5Gi of persistent storage" `
        -FailureMessage "Grafana PVC storage request is '$($Pvc.spec.resources.requests.storage)', not 5Gi."
}

function Get-GrafanaServiceProxyPath {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $ServiceName,
        [Parameter(Mandatory)] [string] $Path
    )

    $normalizedPath = $Path.TrimStart('/')
    return "/api/v1/namespaces/${Namespace}/services/http:${ServiceName}:http/proxy/$normalizedPath"
}

Export-ModuleMember -Function Confirm-GrafanaDeployment, Confirm-GrafanaService, Confirm-GrafanaPvc, Get-GrafanaServiceProxyPath
