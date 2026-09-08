# Exercises validate-prometheus-kubernetes.ps1's Ready-pod coverage checks
# (#154) against a mocked cluster and a mocked Prometheus API. No real cluster,
# no kubectl, no network.
#
# `$jobTargets.Count -gt 0` and `up{job=...} -contains "1"` (what these checks
# replaced) both pass as soon as ONE replica out of several is being scraped -
# a real cluster only exercises that gap if it happens to have a partially
# scraped Deployment at the moment someone runs the validator. This arranges
# the gap deliberately: a Ready pod with a healthy target for every OTHER pod
# but not itself, and a Ready pod whose series appear twice.
#
#   powershell -File scripts\tests\test-prometheus-target-coverage.ps1
#   pwsh -File scripts/tests/test-prometheus-target-coverage.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$validator = Join-Path $PSScriptRoot "..\validate-prometheus-kubernetes.ps1"

$Namespace = "monitoring"
$WorkloadNamespace = "workloads"
$ReleaseName = "prometheus"
$serverName = "$ReleaseName-server"
$proxyBase = "/api/v1/namespaces/$Namespace/services/$($serverName):80/proxy"

# --- Fixed, always-valid pieces (deployment/service/configmap/self job) ------
$deploymentJson = [pscustomobject]@{
    status = [pscustomobject]@{ readyReplicas = 1; replicas = 1 }
} | ConvertTo-Json -Depth 10

$prometheusYaml = @'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: prometheus
    metrics_path: /metrics
  - job_name: ingestion-service
    metrics_path: /actuator/prometheus
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels:
          - __meta_kubernetes_pod_label_app_kubernetes_io_name
        action: keep
        regex: ingestion-service
      - source_labels:
          - __meta_kubernetes_pod_container_port_name
        action: keep
        regex: http
      - source_labels:
          - __meta_kubernetes_namespace
        target_label: namespace
      - source_labels:
          - __meta_kubernetes_pod_name
        target_label: pod
  - job_name: query-service
    metrics_path: /actuator/prometheus
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels:
          - __meta_kubernetes_pod_label_app_kubernetes_io_name
        action: keep
        regex: query-service
      - source_labels:
          - __meta_kubernetes_pod_container_port_name
        action: keep
        regex: http
      - source_labels:
          - __meta_kubernetes_namespace
        target_label: namespace
      - source_labels:
          - __meta_kubernetes_pod_name
        target_label: pod
'@

$configMapJson = [pscustomobject]@{
    data = [pscustomobject]@{ 'prometheus.yml' = $prometheusYaml }
} | ConvertTo-Json -Depth 10

function New-ReadyPodsJson {
    param([string[]] $PodNames)
    $items = @($PodNames | ForEach-Object {
        [pscustomobject]@{
            metadata = [pscustomobject]@{ name = $_ }
            status   = [pscustomobject]@{
                conditions = @([pscustomobject]@{ type = 'Ready'; status = 'True' })
            }
        }
    })
    return [pscustomobject]@{ items = $items } | ConvertTo-Json -Depth 10
}

function New-TargetsJson {
    # $PodsByJob: hashtable job name -> array of pod names to report a healthy
    # active target for. A pod name absent from the list has no target at all.
    param([hashtable] $PodsByJob)
    $activeTargets = @()
    foreach ($jobName in $PodsByJob.Keys) {
        foreach ($podName in $PodsByJob[$jobName]) {
            $targetNamespace = if ($global:PulseStreamTargetNamespaceOverrides.ContainsKey("$jobName/$podName")) {
                $global:PulseStreamTargetNamespaceOverrides["$jobName/$podName"]
            } else {
                $global:PulseStreamWorkloadNamespace
            }
            $activeTargets += [pscustomobject]@{
                scrapeUrl = "http://$podName/actuator/prometheus"
                health    = "up"
                labels    = [pscustomobject]@{ job = $jobName; namespace = $targetNamespace; pod = $podName }
            }
        }
    }
    return [pscustomobject]@{ data = [pscustomobject]@{ activeTargets = $activeTargets } } | ConvertTo-Json -Depth 10
}

function New-VectorJson {
    # $Samples: array of @{ pod = "..."; value = "1" }
    param([object[]] $Samples)
    $result = @($Samples | ForEach-Object {
        [pscustomobject]@{
            metric = [pscustomobject]@{ namespace = $global:PulseStreamWorkloadNamespace; pod = $_.pod }
            value  = @(0, $_.value)
        }
    })
    return [pscustomobject]@{ status = "success"; data = [pscustomobject]@{ resultType = "vector"; result = $result } } | ConvertTo-Json -Depth 10
}

$global:PulseStreamWorkloadNamespace = $WorkloadNamespace
$global:PulseStreamTargetNamespaceOverrides = @{}
$global:PulseStreamReadyPods = @{
    "ingestion-service" = @("ingestion-service-a", "ingestion-service-b")
    "query-service"     = @("query-service-a", "query-service-b")
}
# Mutated per scenario: which pods get a target/up=1/jvm_info sample, and how
# many times.
$global:PulseStreamCoverage = $null

function Reset-PulseStreamCoverage {
    $global:PulseStreamTargetNamespaceOverrides = @{}
    $global:PulseStreamCoverage = @{
        "ingestion-service" = @{
            Targets = @("ingestion-service-a", "ingestion-service-b")
            Up      = @("ingestion-service-a", "ingestion-service-b")
            Jvm     = @("ingestion-service-a", "ingestion-service-b")
        }
        "query-service" = @{
            Targets = @("query-service-a", "query-service-b")
            Up      = @("query-service-a", "query-service-b")
            Jvm     = @("query-service-a", "query-service-b")
        }
    }
}
Reset-PulseStreamCoverage

function global:kubectl {
    param([Parameter(ValueFromRemainingArguments = $true)] [object[]] $Arguments)

    $stringArguments = [string[]] @($Arguments | ForEach-Object { $_.ToString() })
    $global:LASTEXITCODE = 0

    if ($stringArguments[0] -eq "get" -and $stringArguments[1] -eq "deployment") {
        return $deploymentJson
    }
    if ($stringArguments[0] -eq "get" -and $stringArguments[1] -eq "service") {
        return "{}"
    }
    if ($stringArguments[0] -eq "get" -and $stringArguments[1] -eq "configmap") {
        return $configMapJson
    }
    if ($stringArguments[0] -eq "get" -and $stringArguments[1] -eq "pods") {
        $selector = $stringArguments[[Array]::IndexOf($stringArguments, "-l") + 1]
        $jobName = ($selector -split "=", 2)[1]
        return New-ReadyPodsJson -PodNames $global:PulseStreamReadyPods[$jobName]
    }
    if ($stringArguments[0] -eq "get" -and $stringArguments[1] -eq "--raw") {
        $path = $stringArguments[2]

        if ($path -like "*targets?state=active*") {
            $podsByJob = @{ "prometheus" = @("prometheus-server") }
            foreach ($jobName in $global:PulseStreamCoverage.Keys) {
                $podsByJob[$jobName] = $global:PulseStreamCoverage[$jobName].Targets
            }
            return New-TargetsJson -PodsByJob $podsByJob
        }

        if ($path -like "*query=up*job*") {
            foreach ($jobName in $global:PulseStreamCoverage.Keys) {
                if ($path -like "*job%3D%22$jobName%22*") {
                    $samples = @($global:PulseStreamCoverage[$jobName].Up | ForEach-Object { @{ pod = $_; value = "1" } })
                    return New-VectorJson -Samples $samples
                }
            }
            return New-VectorJson -Samples @(@{ pod = "prometheus-server"; value = "1" })
        }

        if ($path -like "*query=jvm_info*") {
            foreach ($jobName in $global:PulseStreamCoverage.Keys) {
                if ($path -like "*job%3D%22$jobName%22*") {
                    $samples = @($global:PulseStreamCoverage[$jobName].Jvm | ForEach-Object { @{ pod = $_; value = "1" } })
                    return New-VectorJson -Samples $samples
                }
            }
        }

        if ($path -like "*query=up") {
            return New-VectorJson -Samples @()
        }

        $global:LASTEXITCODE = 1
        return "unmocked Prometheus proxy path: $path"
    }

    $global:LASTEXITCODE = 1
    return "unexpected kubectl operation: $($stringArguments -join ' ')"
}

function Invoke-Validator {
    & $validator -Namespace $Namespace -WorkloadNamespace $WorkloadNamespace -ReleaseName $ReleaseName -TimeoutSeconds 3
}

try {
    Invoke-Validator | Out-Null
    Write-Host "[ok] full coverage across every Ready pod, every job, passes"

    # --- Missing pod: one of two Ready ingestion-service pods has no target -
    Reset-PulseStreamCoverage
    $global:PulseStreamCoverage["ingestion-service"].Targets = @("ingestion-service-a")
    $global:PulseStreamCoverage["ingestion-service"].Up = @("ingestion-service-a")
    $global:PulseStreamCoverage["ingestion-service"].Jvm = @("ingestion-service-a")

    $rejectedMissingTarget = $false
    try {
        Invoke-Validator | Out-Null
    } catch {
        if ($_.Exception.Message -match "missing for 1 of 2 Ready pod\(s\): ingestion-service-b") {
            $rejectedMissingTarget = $true
            Write-Host "[ok] a Ready pod with no active target was rejected"
        } else {
            throw
        }
    }
    if (-not $rejectedMissingTarget) {
        throw "validate-prometheus-kubernetes.ps1 accepted a job missing a target for a Ready pod."
    }

    # --- Namespace collision: same pod name, wrong workload namespace -------
    # Kubernetes permits identical pod names in different namespaces. Without
    # a namespace constraint, the target below would appear to cover pod B.
    Reset-PulseStreamCoverage
    $global:PulseStreamTargetNamespaceOverrides["ingestion-service/ingestion-service-b"] = "other-workloads"

    $rejectedWrongNamespaceTarget = $false
    try {
        Invoke-Validator | Out-Null
    } catch {
        if ($_.Exception.Message -match "missing for 1 of 2 Ready pod\(s\): ingestion-service-b") {
            $rejectedWrongNamespaceTarget = $true
            Write-Host "[ok] a same-named target from another namespace was rejected"
        } else {
            throw
        }
    }
    if (-not $rejectedWrongNamespaceTarget) {
        throw "validate-prometheus-kubernetes.ps1 accepted a same-named target from another namespace as coverage for a Ready pod."
    }

    # --- Duplicate pod: jvm_info reports one Ready query-service pod twice --
    Reset-PulseStreamCoverage
    $global:PulseStreamCoverage["query-service"].Jvm = @("query-service-a", "query-service-a", "query-service-b")

    $rejectedDuplicateSeries = $false
    try {
        Invoke-Validator | Out-Null
    } catch {
        if ($_.Exception.Message -match "more than one entry for 1 of 2 Ready pod\(s\): query-service-a \(2 entries\)") {
            $rejectedDuplicateSeries = $true
            Write-Host "[ok] a Ready pod with two jvm_info series was rejected"
        } else {
            throw
        }
    }
    if (-not $rejectedDuplicateSeries) {
        throw "validate-prometheus-kubernetes.ps1 accepted a jvm_info response with two series for one Ready pod."
    }

    # --- Missing pod, up query only: target healthy, but up never reaches 1 -
    Reset-PulseStreamCoverage
    $global:PulseStreamCoverage["query-service"].Up = @("query-service-a")

    $rejectedMissingUp = $false
    try {
        Invoke-Validator | Out-Null
    } catch {
        if ($_.Exception.Message -match "missing for 1 of 2 Ready pod\(s\): query-service-b") {
            $rejectedMissingUp = $true
            Write-Host "[ok] a Ready pod whose target is registered but never reports up=1 was rejected"
        } else {
            throw
        }
    }
    if (-not $rejectedMissingUp) {
        throw "validate-prometheus-kubernetes.ps1 accepted a job where up{job=...}=1 does not cover every Ready pod."
    }
} finally {
    Remove-Item -LiteralPath Function:\kubectl -ErrorAction SilentlyContinue
    Remove-Variable -Name PulseStreamReadyPods, PulseStreamCoverage, PulseStreamWorkloadNamespace, PulseStreamTargetNamespaceOverrides -Scope Global -ErrorAction SilentlyContinue
}

Write-Host "[ok] Prometheus target/pod coverage checks behave consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
