# Structural assertions for the PulseStream HorizontalPodAutoscalers:
# telemetry-processor (#151) and the custom-metrics ingestion-service HPA
# (#152).
#
# Each set is shared by two callers - a validate-*.ps1 script that reads the
# applied object from a cluster with kubectl, and a scripts/tests/test-*.ps1
# that reads the committed manifest with no cluster at all. Both have to assert
# exactly the same thing; the tests used to get there by replacing kubectl with
# a stub function in the global scope, which leaked into every other script that
# shared the session.
#
# The checks are cluster-load-independent on purpose: they mean something
# without generating traffic. Proving the autoscaler reacts to real load needs a
# cluster with metrics-server and a load generator, tracked separately (#153).

# Imported without -Force on purpose. -Force removes and re-imports the module,
# which would unload the copy a calling script had already imported for its own
# use: a validator that imports PulseStreamValidation and then this module would
# lose Confirm-Condition the moment this line ran.
Import-Module (Join-Path $PSScriptRoot "PulseStreamValidation.psm1")

# Walks a property path without assuming any level exists.
#
# A missing field is the interesting failure here rather than an impossible one:
# an HPA with no .spec.behavior is accepted by the API server and silently falls
# back to the default 300s scale-up stabilization window, and a manifest that
# drops .spec.metrics still applies. Reading those through `$hpa.spec.behavior.
# scaleUp.stabilizationWindowSeconds` turns the interesting case into a
# PowerShell error about a property on a null object - or, under Set-StrictMode,
# into a script that aborts before it can report anything useful.
function Get-ManifestValue {
    param(
        [Parameter(Position = 0)] $InputObject,
        [Parameter(Mandatory, Position = 1)] [string[]] $Path
    )

    $current = $InputObject
    foreach ($segment in $Path) {
        if ($null -eq $current) {
            return $null
        }

        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            return $null
        }

        $current = $property.Value
    }

    return $current
}

# Keeps failure messages readable when the field is absent: "is missing" rather
# than "is , not 300".
function Format-ManifestValue {
    param($Value)

    if ($null -eq $Value) {
        return "missing"
    }

    return "$Value"
}

function Get-CpuUtilizationMetric {
    param($Hpa)

    $metrics = @(Get-ManifestValue $Hpa @('spec', 'metrics'))

    return @($metrics | Where-Object {
        $null -ne $_ -and
        (Get-ManifestValue $_ @('type')) -eq 'Resource' -and
        (Get-ManifestValue $_ @('resource', 'name')) -eq 'cpu' -and
        (Get-ManifestValue $_ @('resource', 'target', 'type')) -eq 'Utilization'
    }) | Select-Object -First 1
}

function Confirm-TelemetryProcessorHpa {
    param([Parameter(Mandatory)] $Hpa)

    $targetKind = Get-ManifestValue $Hpa @('spec', 'scaleTargetRef', 'kind')
    $targetName = Get-ManifestValue $Hpa @('spec', 'scaleTargetRef', 'name')
    Confirm-Condition `
        -Condition ($targetKind -eq 'Deployment' -and $targetName -eq 'telemetry-processor') `
        -SuccessMessage "HPA targets Deployment/telemetry-processor" `
        -FailureMessage "HPA scaleTargetRef is $(Format-ManifestValue $targetKind)/$(Format-ManifestValue $targetName), not Deployment/telemetry-processor. It would scale the wrong workload, or nothing"

    $minReplicas = Get-ManifestValue $Hpa @('spec', 'minReplicas')
    Confirm-Condition `
        -Condition ($minReplicas -eq 2) `
        -SuccessMessage "minReplicas is 2 (the availability floor also set in deployment.yaml)" `
        -FailureMessage "minReplicas is $(Format-ManifestValue $minReplicas), not 2. A lower floor would undo the rolling-update/node-drain safety margin; a higher one contradicts the deployment's own replica count"

    # The important one: 3 is the partition count of telemetry.events.raw, not a
    # capacity guess, so a raised ceiling is a silent regression rather than a
    # tuning change.
    $maxReplicas = Get-ManifestValue $Hpa @('spec', 'maxReplicas')
    Confirm-Condition `
        -Condition ($maxReplicas -eq 3) `
        -SuccessMessage "maxReplicas is 3 (the partition count of telemetry.events.raw)" `
        -FailureMessage "maxReplicas is $(Format-ManifestValue $maxReplicas), not 3. Replicas beyond the partition count join the consumer group, are assigned no partition, and do no work; the ceiling only moves after the topic is repartitioned"

    $cpuMetric = Get-CpuUtilizationMetric -Hpa $Hpa
    Confirm-Condition `
        -Condition ($null -ne $cpuMetric) `
        -SuccessMessage "HPA scales on Resource/cpu Utilization" `
        -FailureMessage "HPA has no Resource/cpu Utilization metric. Consumer lag is the preferred signal but needs a metrics adapter (#152) and exported lag metrics (#272); CPU-against-request is the only supported one today"

    $cpuTarget = Get-ManifestValue $cpuMetric @('resource', 'target', 'averageUtilization')
    Confirm-Condition `
        -Condition ($cpuTarget -eq 70) `
        -SuccessMessage "CPU target is 70% of the pod's CPU request" `
        -FailureMessage "CPU averageUtilization is $(Format-ManifestValue $cpuTarget), not 70%. The target is defined relative to the 250m request in deployment.yaml; changing one without the other silently moves the real trigger point"

    $scaleUpWindow = Get-ManifestValue $Hpa @('spec', 'behavior', 'scaleUp', 'stabilizationWindowSeconds')
    Confirm-Condition `
        -Condition ($scaleUpWindow -eq 0) `
        -SuccessMessage "scale-up has no stabilization window (reacts on a sustained rise rather than waiting through it)" `
        -FailureMessage "scale-up stabilizationWindowSeconds is $(Format-ManifestValue $scaleUpWindow), not 0. Without the field the API server applies its own default, and a delayed scale-up leaves the backlog growing while a new pod still needs ~15-30s to become ready and be assigned a partition"

    $scaleDownWindow = Get-ManifestValue $Hpa @('spec', 'behavior', 'scaleDown', 'stabilizationWindowSeconds')
    Confirm-Condition `
        -Condition ($scaleDownWindow -eq 300) `
        -SuccessMessage "scale-down has a 300s stabilization window (JVM CPU is spiky, and every scale-in rebalances the consumer group)" `
        -FailureMessage "scale-down stabilizationWindowSeconds is $(Format-ManifestValue $scaleDownWindow), not 300. A shorter window turns a GC or JIT burst into a rebalance that pauses processing across the whole group"
}

function Get-PodsMetric {
    param($Hpa, [string] $Name)

    $metrics = @(Get-ManifestValue $Hpa @('spec', 'metrics'))

    return @($metrics | Where-Object {
        $null -ne $_ -and
        (Get-ManifestValue $_ @('type')) -eq 'Pods' -and
        (Get-ManifestValue $_ @('pods', 'metric', 'name')) -eq $Name
    }) | Select-Object -First 1
}

# The ingestion-service HPA that scales on request rate as well as CPU (#152).
#
# Shared by validate-custom-metrics-autoscaling.ps1, which reads the applied
# object from a cluster, and tests/test-custom-metrics-hpa-structure.ps1, which
# reads the committed manifest with no cluster.
function Confirm-IngestionServiceCustomMetricsHpa {
    param([Parameter(Mandatory)] $Hpa)

    $targetKind = Get-ManifestValue $Hpa @('spec', 'scaleTargetRef', 'kind')
    $targetName = Get-ManifestValue $Hpa @('spec', 'scaleTargetRef', 'name')
    Confirm-Condition `
        -Condition ($targetKind -eq 'Deployment' -and $targetName -eq 'ingestion-service') `
        -SuccessMessage "HPA targets Deployment/ingestion-service" `
        -FailureMessage "HPA scaleTargetRef is $(Format-ManifestValue $targetKind)/$(Format-ManifestValue $targetName), not Deployment/ingestion-service. It would scale the wrong workload, or nothing"

    # The bounds do not depend on which metric drives the decision, so they must
    # match the CPU-only hpa.yaml this manifest replaces. A switch to custom
    # metrics that also moved the ceiling would hide a capacity change behind a
    # metrics change.
    $minReplicas = Get-ManifestValue $Hpa @('spec', 'minReplicas')
    Confirm-Condition `
        -Condition ($minReplicas -eq 2) `
        -SuccessMessage "minReplicas is 2 (the availability floor also set in deployment.yaml)" `
        -FailureMessage "minReplicas is $(Format-ManifestValue $minReplicas), not 2. A lower floor would undo the rolling-update/node-drain safety margin that the fixed replica count provides"

    $maxReplicas = Get-ManifestValue $Hpa @('spec', 'maxReplicas')
    Confirm-Condition `
        -Condition ($maxReplicas -eq 6) `
        -SuccessMessage "maxReplicas is 6 (unchanged from the CPU-only HPA)" `
        -FailureMessage "maxReplicas is $(Format-ManifestValue $maxReplicas), not 6. The ceiling is a cluster-capacity and downstream-partition decision from docs/architecture/autoscaling-strategy.md, not a property of the metric being scaled on"

    # CPU has to stay on this HPA. It is what makes the custom metric an
    # addition rather than a dependency: if the adapter stops serving the rate
    # metric, the HPA still scales up on CPU instead of stopping.
    $cpuMetric = Get-CpuUtilizationMetric -Hpa $Hpa
    Confirm-Condition `
        -Condition ($null -ne $cpuMetric) `
        -SuccessMessage "CPU utilization is still a metric on this HPA (the fallback signal if the adapter is unavailable)" `
        -FailureMessage "HPA has no Resource/cpu Utilization metric. Dropping CPU makes prometheus-adapter a hard dependency of autoscaling: an adapter outage would leave the HPA with no readable metric at all"

    $cpuTarget = Get-ManifestValue $cpuMetric @('resource', 'target', 'averageUtilization')
    Confirm-Condition `
        -Condition ($cpuTarget -eq 70) `
        -SuccessMessage "CPU target is 70% of the pod's CPU request" `
        -FailureMessage "CPU averageUtilization is $(Format-ManifestValue $cpuTarget), not 70%. The target is defined relative to the 250m request in deployment.yaml; changing one without the other silently moves the real trigger point"

    # The metric name is the contract with the adapter rules in
    # infrastructure/kubernetes/autoscaling/prometheus-adapter-values.yaml. A
    # name that does not match a rule is not an error on either side: the API
    # simply serves nothing and the HPA reports <unknown>.
    $rateMetric = Get-PodsMetric -Hpa $Hpa -Name 'http_requests_per_second'
    Confirm-Condition `
        -Condition ($null -ne $rateMetric) `
        -SuccessMessage "HPA scales on the Pods metric http_requests_per_second" `
        -FailureMessage "HPA has no Pods metric named http_requests_per_second. That name is what prometheus-adapter serves from custom.metrics.k8s.io; any other name resolves to nothing and the HPA reports <unknown>"

    # AverageValue, not Value: the target is per replica, so the HPA divides the
    # summed rate by the current replica count. A `Value` target would compare
    # the total against 50 and scale to the ceiling on the first busy minute.
    $rateTargetType = Get-ManifestValue $rateMetric @('pods', 'target', 'type')
    Confirm-Condition `
        -Condition ($rateTargetType -eq 'AverageValue') `
        -SuccessMessage "the request-rate target is an AverageValue (per replica)" `
        -FailureMessage "the request-rate target type is $(Format-ManifestValue $rateTargetType), not AverageValue. A Value target compares the whole deployment's rate against the per-replica number and scales to maxReplicas as soon as traffic arrives"

    $rateTarget = Get-ManifestValue $rateMetric @('pods', 'target', 'averageValue')
    Confirm-Condition `
        -Condition ("$rateTarget" -eq '50') `
        -SuccessMessage "the request-rate target is 50 requests per second per replica" `
        -FailureMessage "the request-rate averageValue is $(Format-ManifestValue $rateTarget), not 50. The number is derived from the CPU target (70% of a 250m request is ~175m, i.e. ~3.5ms per request at 50 rps) so the two metrics cross at roughly the same load; #153 replaces it with a measured value"

    $scaleUpWindow = Get-ManifestValue $Hpa @('spec', 'behavior', 'scaleUp', 'stabilizationWindowSeconds')
    Confirm-Condition `
        -Condition ($scaleUpWindow -eq 0) `
        -SuccessMessage "scale-up has no stabilization window (reacts on a sustained rise rather than waiting through it)" `
        -FailureMessage "scale-up stabilizationWindowSeconds is $(Format-ManifestValue $scaleUpWindow), not 0. Without the field the API server applies its own default, and the rate metric already arrives through a scrape and a 2-minute rate window - a second delay on top of that leaves the gateway saturated"

    $scaleDownWindow = Get-ManifestValue $Hpa @('spec', 'behavior', 'scaleDown', 'stabilizationWindowSeconds')
    Confirm-Condition `
        -Condition ($scaleDownWindow -eq 300) `
        -SuccessMessage "scale-down has a 300s stabilization window (JVM CPU is spiky, and a passed burst can still sit inside the rate window)" `
        -FailureMessage "scale-down stabilizationWindowSeconds is $(Format-ManifestValue $scaleDownWindow), not 300. A shorter window misreads a GC or JIT burst, or the tail of the 2-minute rate window, as sustained load"
}

# A custom metric can resolve for *some* pods and still leave the HPA scaling
# on a partial view: the adapter's Prometheus query matches whatever series
# exist, and a pod Prometheus has not scraped yet (or has stopped scraping,
# because service discovery went stale) simply has no series rather than a
# zero one. `$MetricItems.Count -gt 0` cannot see that gap - it passes as soon
# as one pod out of however many is reporting.
#
# Pure comparison so it can be exercised offline
# (scripts/tests/test-custom-metrics-pod-coverage.ps1) instead of only ever
# being exercised by a cluster that happens to have a scraping gap.
function Confirm-PodsMetricCoverage {
    param(
        [string[]] $ReadyPodNames = @(),
        [string[]] $MetricPodNames = @(),
        [Parameter(Mandatory)] [string] $MetricName
    )

    $missingPodNames = @($ReadyPodNames | Where-Object { $MetricPodNames -notcontains $_ })

    Confirm-Condition `
        -Condition ($missingPodNames.Count -eq 0) `
        -SuccessMessage "$MetricName resolves for every Ready pod ($($ReadyPodNames.Count) of $($ReadyPodNames.Count))" `
        -FailureMessage "$MetricName is missing for $($missingPodNames.Count) of $($ReadyPodNames.Count) Ready pod(s): $($missingPodNames -join ', '). The adapter is only serving a subset - check that Prometheus service discovery is not stale and that /actuator/prometheus is reachable on every Ready pod"

    # Coverage is not just presence: the HPA averages the values it is served,
    # so a pod carrying two entries is weighted twice and drags the average
    # towards whichever series is duplicated. The adapter emits one entry per
    # pod, so a second entry for the same pod means the underlying Prometheus
    # query matched more than one series for it (a leftover series from a
    # previous pod incarnation with the same name, or a rule whose label set
    # is not unique per pod), and the number the HPA scales on is no longer
    # the metric it claims to be.
    $duplicatedPodNames = @($ReadyPodNames | Where-Object {
        $podName = $_
        @($MetricPodNames | Where-Object { $_ -eq $podName }).Count -gt 1
    })

    $duplicateDetail = @($duplicatedPodNames | ForEach-Object {
        $podName = $_
        "$podName ($(@($MetricPodNames | Where-Object { $_ -eq $podName }).Count) entries)"
    })

    Confirm-Condition `
        -Condition ($duplicatedPodNames.Count -eq 0) `
        -SuccessMessage "$MetricName resolves to exactly one value per Ready pod" `
        -FailureMessage "$MetricName returns more than one entry for $($duplicatedPodNames.Count) of $($ReadyPodNames.Count) Ready pod(s): $($duplicateDetail -join ', '). The HPA averages every entry it is served, so a duplicated pod is weighted twice - check that the adapter rule's series are unique per pod and that no stale series for a previous pod of the same name is still in Prometheus"
}

Export-ModuleMember -Function Confirm-TelemetryProcessorHpa, Confirm-IngestionServiceCustomMetricsHpa, Confirm-PodsMetricCoverage, Get-ManifestValue
