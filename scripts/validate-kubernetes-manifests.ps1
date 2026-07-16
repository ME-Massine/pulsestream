[CmdletBinding()]
param(
    [string] $KustomizationDir = (Join-Path $PSScriptRoot "..\infrastructure\kubernetes")
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force

# Static validation of the Kubernetes manifests: no cluster required. Builds
# the kustomization the same way `kubectl apply -k` would and checks that the
# expected resources come out the other side. Catches YAML/kustomize errors
# and missing resources before they reach a real cluster.

Write-Host "Validating Kubernetes manifests in '$KustomizationDir'..."

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw "kubectl is required to validate the kustomization (uses 'kubectl kustomize')."
}

$rendered = kubectl kustomize $KustomizationDir 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "kubectl kustomize failed:`n$rendered"
}

Confirm-Condition -Permanent `
    -Condition ($LASTEXITCODE -eq 0) `
    -SuccessMessage "kustomization builds successfully" `
    -FailureMessage "kustomization failed to build"

$renderedText = $rendered -join "`n"

# One entry per "kind: Name" pair we expect in the rendered output.
$expectedResources = @(
    @{ Kind = "Namespace"; Name = "pulsestream" },
    @{ Kind = "StatefulSet"; Name = "postgres" },
    @{ Kind = "StatefulSet"; Name = "zookeeper" },
    @{ Kind = "StatefulSet"; Name = "kafka" },
    @{ Kind = "Deployment"; Name = "redis" },
    @{ Kind = "Job"; Name = "kafka-topics-init" },
    @{ Kind = "Deployment"; Name = "ingestion-service" },
    @{ Kind = "Deployment"; Name = "telemetry-processor" },
    @{ Kind = "Service"; Name = "ingestion-service" },
    @{ Kind = "Service"; Name = "telemetry-processor" },
    @{ Kind = "HorizontalPodAutoscaler"; Name = "ingestion-service" },
    @{ Kind = "HorizontalPodAutoscaler"; Name = "telemetry-processor" },
    @{ Kind = "Ingress"; Name = "ingestion-service" },
    @{ Kind = "Deployment"; Name = "prometheus" },
    @{ Kind = "Deployment"; Name = "grafana" },
    @{ Kind = "Deployment"; Name = "jaeger" }
)

# kustomize orders `kind:` before `metadata:` / `name:` within each document,
# so match documents rather than assuming line adjacency.
$documents = $renderedText -split "(?m)^---\s*$"

foreach ($resource in $expectedResources) {
    $kind = $resource.Kind
    $name = $resource.Name

    $found = $documents | Where-Object {
        $_ -match "(?m)^kind:\s*$([regex]::Escape($kind))\s*$" -and
        $_ -match "(?m)^\s*name:\s*$([regex]::Escape($name))\s*$"
    }

    Confirm-Condition -Permanent `
        -Condition ([bool]$found) `
        -SuccessMessage "$kind/$name is present in the rendered manifests" `
        -FailureMessage "$kind/$name was not found in the rendered manifests"
}

# Every Deployment/StatefulSet must declare resource requests and limits, and
# every container port must be backed by a readiness probe, so the cluster
# can schedule and health-check the platform correctly.
$workloadDocuments = $documents | Where-Object { $_ -match "(?m)^kind:\s*(Deployment|StatefulSet)\s*$" }

foreach ($doc in $workloadDocuments) {
    $nameMatch = [regex]::Match($doc, "(?m)^\s*name:\s*(\S+)\s*$")
    $name = $nameMatch.Groups[1].Value

    Confirm-Condition -Permanent `
        -Condition ($doc -match "readinessProbe:") `
        -SuccessMessage "$name defines a readinessProbe" `
        -FailureMessage "$name is missing a readinessProbe"

    Confirm-Condition -Permanent `
        -Condition ($doc -match "resources:") `
        -SuccessMessage "$name defines resource requests/limits" `
        -FailureMessage "$name is missing resource requests/limits"
}

Write-Host "[ok] Kubernetes manifest validation completed."
