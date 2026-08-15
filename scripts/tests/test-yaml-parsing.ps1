# Unit coverage for scripts/lib/PulseStreamYaml.psm1.
#
# The structural manifest tests only mean something if the reader underneath
# them is right, and a reader that quietly misparses is worse than one that
# refuses: half of these cases assert that unsupported YAML throws rather than
# returning a plausible-looking object.
#
#   powershell -File scripts\tests\test-yaml-parsing.ps1
#   pwsh -File scripts/tests/test-yaml-parsing.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$script:Failures = 0

Import-Module (Join-Path $PSScriptRoot "..\lib\PulseStreamYaml.psm1") -Force

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

function Assert-Throws {
    param(
        [Parameter(Mandatory)] [string] $What,
        [Parameter(Mandatory)] [string] $Yaml,
        [Parameter(Mandatory)] [string] $ExpectedMessage
    )

    try {
        ConvertFrom-KubernetesYaml -Text $Yaml | Out-Null
    } catch {
        if ($_.Exception.Message -match $ExpectedMessage) {
            Write-Host "[ok] $What"
            return
        }

        Write-Host "[fail] $What -> expected '$ExpectedMessage', got '$($_.Exception.Message)'"
        $script:Failures++
        return
    }

    Write-Host "[fail] $What -> the reader accepted it"
    $script:Failures++
}

$document = ConvertFrom-KubernetesYaml -Text @"
---
# leading comment
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: telemetry-processor
  labels:
    app.kubernetes.io/name: telemetry-processor
spec:
  minReplicas: 2          # trailing comment
  quoted: "3"
  hashInValue: "a # b"
  enabled: true
  absent: null
  ratio: 0.5
  podSelector: {}
  emptyList: []
  flushKeys:
  - first
  - second
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          averageUtilization: 70
"@

Assert-Equal -What "scalar at the document root" -Expected "autoscaling/v2" -Actual $document.apiVersion
Assert-Equal -What "nested mapping" -Expected "telemetry-processor" -Actual $document.metadata.name
Assert-Equal -What "dotted/slashed keys survive" -Expected "telemetry-processor" -Actual $document.metadata.labels."app.kubernetes.io/name"
Assert-Equal -What "trailing comments are stripped" -Expected 2 -Actual $document.spec.minReplicas
Assert-True -What "unquoted integers are numbers" -Condition ($document.spec.minReplicas -is [int])
Assert-True -What "quoted numbers stay strings" -Condition ($document.spec.quoted -is [string])
Assert-Equal -What "a hash inside a quoted value is kept" -Expected "a # b" -Actual $document.spec.hashInValue
Assert-True -What "booleans are booleans" -Condition ($document.spec.enabled -is [bool] -and $document.spec.enabled)
Assert-True -What "null is null" -Condition ($null -eq $document.spec.absent)
Assert-Equal -What "decimals are numbers" -Expected 0.5 -Actual $document.spec.ratio

# Sequences written flush with their key are as common in Kubernetes manifests
# as indented ones, and both have to produce the same shape.
Assert-Equal -What "flush sequence length" -Expected 2 -Actual @($document.spec.flushKeys).Count
Assert-Equal -What "flush sequence item" -Expected "second" -Actual @($document.spec.flushKeys)[1]

# A single-item sequence must stay an array: PowerShell unrolls collections on
# return, so `metrics[0]` would otherwise index into the object itself.
Assert-True -What "single-item sequence stays an array" -Condition ($document.spec.metrics -is [array])
Assert-Equal -What "sequence item mapping" -Expected "Resource" -Actual $document.spec.metrics[0].type
Assert-Equal -What "mapping nested under a sequence item" -Expected "cpu" -Actual $document.spec.metrics[0].resource.name
Assert-Equal -What "deep value under a sequence item" -Expected 70 -Actual $document.spec.metrics[0].resource.target.averageUtilization

$empty = ConvertFrom-KubernetesYaml -Text @"
spec:
  behavior:
"@
Assert-True -What "a key with no value is null" -Condition ($null -eq $empty.spec.behavior)

Assert-Throws -What "tab indentation is rejected" -ExpectedMessage "tabs are not valid YAML indentation" -Yaml @"
spec:
`tminReplicas: 2
"@

# `podSelector: {}` means "every pod in this namespace" in a NetworkPolicy, so
# the empty mapping has to survive as an object rather than as $null.
Assert-True -What "an empty flow mapping is an object" -Condition ($null -ne $document.spec.podSelector -and @($document.spec.podSelector.PSObject.Properties).Count -eq 0)
Assert-True -What "an empty flow sequence is an empty array" -Condition ($document.spec.emptyList -is [array] -and $document.spec.emptyList.Count -eq 0)

Assert-Throws -What "non-empty flow mappings are rejected" -ExpectedMessage "does not support" -Yaml @"
spec: { minReplicas: 2 }
"@

Assert-Throws -What "anchors are rejected" -ExpectedMessage "does not support" -Yaml @"
spec: &defaults
  minReplicas: 2
"@

Assert-Throws -What "block scalars are rejected" -ExpectedMessage "does not support" -Yaml @"
script: |
  echo hello
"@

Assert-Throws -What "a second document is rejected" -ExpectedMessage "single document per file" -Yaml @"
kind: A
---
kind: B
"@

Assert-Throws -What "duplicate keys are rejected" -ExpectedMessage "duplicate key" -Yaml @"
spec:
  minReplicas: 2
  minReplicas: 3
"@

Assert-Throws -What "stray indentation is rejected" -ExpectedMessage "unexpected indentation" -Yaml @"
kind: HorizontalPodAutoscaler
    name: telemetry-processor
"@

Assert-Throws -What "a non-mapping line is rejected" -ExpectedMessage "expected 'key: value'" -Yaml @"
kind: HorizontalPodAutoscaler
telemetry-processor
"@

Assert-Throws -What "an empty document is rejected" -ExpectedMessage "contains no YAML content" -Yaml @"
# only a comment
"@

# The committed manifests are the actual input, so they are parsed here too:
# a reader that handles the synthetic cases above but not the real files would
# still break the structural tests.
$manifestDirectory = Join-Path $PSScriptRoot "..\..\infrastructure\kubernetes"
foreach ($relativePath in @(
    "telemetry-processor\hpa.yaml",
    "telemetry-processor\deployment.yaml",
    "network-policies\telemetry-processor.yaml"
)) {
    $path = Join-Path $manifestDirectory $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        continue
    }

    $manifest = ConvertFrom-KubernetesYaml -Path $path
    Assert-True -What "$relativePath parses and has a kind" -Condition (-not [string]::IsNullOrWhiteSpace($manifest.kind))
}

if ($script:Failures -gt 0) {
    throw "$script:Failures YAML reader check(s) failed."
}

Write-Host "[ok] YAML reader behaves consistently on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
