[CmdletBinding()]
<#
.SYNOPSIS
    Validates the Kubernetes ConfigMap / Secret / Deployment wiring for the
    platform services (#136).

.DESCRIPTION
    Static, offline checks that the externalized-configuration contract holds for
    each service that has a Deployment manifest:

      * a ConfigMap and a Secret manifest exist next to the Deployment;
      * the Deployment sources non-sensitive config from its ConfigMap via
        `envFrom.configMapRef`;
      * no sensitive value is hardcoded inline in the Deployment (sensitive keys
        must come from a Secret, not a plaintext `value:`);
      * the Secret is a placeholder template (type Opaque, REPLACE_ME values,
        no committed base64 `data:` block).

    When `kubectl` is available, each manifest is additionally schema-validated
    with a client-side dry run. When it is not, that step is skipped with a
    notice rather than failing — the static checks above still run offline.

    Exits non-zero on the first failed check.
#>
param(
    # Services to validate. Each must have a directory under
    # infrastructure/kubernetes/<name> containing deployment/configmap/secret.
    [string[]] $Services = @("ingestion-service", "query-service")
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$manifestRoot = Join-Path $repoRoot "infrastructure\kubernetes"

# Active (non-comment, non-blank) lines of a manifest. Comment-only lines are
# excluded so commented-out examples (e.g. the optional secretRef) never trip a
# content assertion.
function Get-ActiveLines {
    param([string] $Path)
    Get-Content -Path $Path | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne "" }
}

# Env names that must never be set with an inline plaintext `value:` in a
# Deployment. Such config has to flow through a Secret reference instead.
$sensitivePattern = '(?i)(password|passwd|secret|token|credential|api[-_]?key)'

function Test-ServiceConfig {
    param([string] $Service)

    $dir = Join-Path $manifestRoot $Service
    $deployPath = Join-Path $dir "deployment.yaml"
    $configPath = Join-Path $dir "configmap.yaml"
    $secretPath = Join-Path $dir "secret.yaml"

    foreach ($p in @($deployPath, $configPath, $secretPath)) {
        Confirm-Condition -Permanent `
            -Condition (Test-Path $p) `
            -SuccessMessage "manifest present: $(Split-Path $p -Leaf)" `
            -FailureMessage "missing manifest for '$Service': $p"
    }

    $configName = "$Service-config"
    $secretName = "$Service-secret"

    # --- ConfigMap ---
    $configLines = Get-ActiveLines $configPath
    Confirm-Condition -Permanent `
        -Condition ([bool]($configLines -match '^\s*kind:\s*ConfigMap\s*$')) `
        -SuccessMessage "$Service configmap.yaml declares kind ConfigMap" `
        -FailureMessage "$Service configmap.yaml must declare 'kind: ConfigMap'."
    Confirm-Condition -Permanent `
        -Condition ([bool]($configLines -match "^\s*name:\s*$([regex]::Escape($configName))\s*$")) `
        -SuccessMessage "$Service ConfigMap is named '$configName'" `
        -FailureMessage "$Service configmap.yaml metadata.name must be '$configName'."

    # --- Secret template ---
    $secretLines = Get-ActiveLines $secretPath
    Confirm-Condition -Permanent `
        -Condition ([bool]($secretLines -match '^\s*kind:\s*Secret\s*$')) `
        -SuccessMessage "$Service secret.yaml declares kind Secret" `
        -FailureMessage "$Service secret.yaml must declare 'kind: Secret'."
    Confirm-Condition -Permanent `
        -Condition ([bool]($secretLines -match "^\s*name:\s*$([regex]::Escape($secretName))\s*$")) `
        -SuccessMessage "$Service Secret is named '$secretName'" `
        -FailureMessage "$Service secret.yaml metadata.name must be '$secretName'."
    Confirm-Condition -Permanent `
        -Condition ([bool]($secretLines -match '^\s*type:\s*Opaque\s*$')) `
        -SuccessMessage "$Service Secret is type Opaque" `
        -FailureMessage "$Service secret.yaml must set 'type: Opaque'."
    # The Secret is a committed template: it must carry only placeholders, never
    # a base64 `data:` block that could smuggle a real credential into git.
    Confirm-Condition -Permanent `
        -Condition (-not ($secretLines -match '^\s*data:\s*$')) `
        -SuccessMessage "$Service Secret has no committed base64 data block" `
        -FailureMessage "$Service secret.yaml must not commit a 'data:' block; use stringData placeholders."
    Confirm-Condition -Permanent `
        -Condition ([bool]($secretLines -match 'REPLACE_ME')) `
        -SuccessMessage "$Service Secret uses REPLACE_ME placeholders" `
        -FailureMessage "$Service secret.yaml must use REPLACE_ME placeholders, not real values."

    # --- Deployment wiring ---
    $deployLines = Get-ActiveLines $deployPath
    $deployText = ($deployLines -join "`n")
    Confirm-Condition -Permanent `
        -Condition ($deployText -match "envFrom[\s\S]*?configMapRef[\s\S]*?name:\s*$([regex]::Escape($configName))") `
        -SuccessMessage "$Service Deployment sources config from '$configName' via envFrom" `
        -FailureMessage "$Service deployment.yaml must reference ConfigMap '$configName' via envFrom.configMapRef."

    # No sensitive env may be set inline. Flag any active `- name: <sensitive>`
    # immediately followed by a plaintext `value:` (as opposed to a Secret ref).
    for ($i = 0; $i -lt $deployLines.Count; $i++) {
        $line = $deployLines[$i]
        if ($line -match "^\s*-?\s*name:\s*\S*$sensitivePattern" -and $i + 1 -lt $deployLines.Count) {
            $next = $deployLines[$i + 1]
            Confirm-Condition -Permanent `
                -Condition (-not ($next -match '^\s*value:')) `
                -SuccessMessage "$Service Deployment does not hardcode a sensitive value on line $($i + 1)" `
                -FailureMessage "$Service deployment.yaml hardcodes a sensitive value: '$($line.Trim())'. Source it from the Secret instead."
        }
    }
    Write-Host "[ok] $Service Deployment has no inline sensitive values"
}

# Run a native validator and capture its exit code without letting native
# stderr (promoted to a terminating error under $ErrorActionPreference=Stop in
# Windows PowerShell) abort the script.
function Invoke-Native {
    param([Parameter(ValueFromRemainingArguments = $true)] $NativeArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $NativeArgs[0] @($NativeArgs[1..($NativeArgs.Count - 1)]) 2>&1 | Out-Null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

# Even a client-side `kubectl apply --dry-run=client` needs a reachable cluster
# to build its REST mapper, so it cannot schema-validate offline. Prefer an
# offline validator (kubeconform); fall back to a cluster dry-run only when a
# cluster is actually reachable.
function Resolve-SchemaValidator {
    if (Get-Command kubeconform -ErrorAction SilentlyContinue) { return "kubeconform" }
    if (Get-Command kubectl -ErrorAction SilentlyContinue) {
        if ((Invoke-Native kubectl cluster-info) -eq 0) { return "kubectl" }
    }
    return $null
}

function Invoke-SchemaValidation {
    param([string] $Service, [string] $Validator)

    $dir = Join-Path $manifestRoot $Service
    foreach ($leaf in @("configmap.yaml", "secret.yaml", "deployment.yaml")) {
        $path = Join-Path $dir $leaf
        $exit = switch ($Validator) {
            "kubeconform" { Invoke-Native kubeconform -strict -summary $path }
            "kubectl"     { Invoke-Native kubectl apply --dry-run=client -f $path }
        }
        Confirm-Condition -Permanent `
            -Condition ($exit -eq 0) `
            -SuccessMessage "$Service $leaf passed $Validator schema validation" `
            -FailureMessage "$Service $leaf failed $Validator schema validation (exit $exit)."
    }
}

Write-Host "Validating Kubernetes config wiring: $($Services -join ', ')"
Write-Host ""

$validator = Resolve-SchemaValidator
if (-not $validator) {
    Write-Host "[note] no offline validator (kubeconform) and no reachable cluster; schema validation skipped. Static checks still run." -ForegroundColor Yellow
    Write-Host ""
}

foreach ($service in $Services) {
    Write-Host "=== $service ===" -ForegroundColor Cyan
    Test-ServiceConfig $service

    if ($validator) {
        Invoke-SchemaValidation $service $validator
    } else {
        Write-Host "[skip] schema validation skipped for $service (no validator available)." -ForegroundColor Yellow
    }
    Write-Host ""
}

Write-Host "[ok] All targeted services have valid ConfigMap/Secret/Deployment wiring." -ForegroundColor Green

# A failed check throws (non-zero exit). Reaching here means success; set the
# code explicitly so a leftover $LASTEXITCODE from the cluster probe cannot leak.
exit 0
