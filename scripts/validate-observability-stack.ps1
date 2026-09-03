# End-to-end validation of the observability stack in Kubernetes (#159).
#
# The stack is four components deployed by four separate issues, each with its
# own validator that proves that component is correctly configured:
#
#   #154  Prometheus         scripts/validate-prometheus-kubernetes.ps1
#   #155  Grafana            scripts/validate-grafana-deployment.ps1
#   #156  Grafana wiring     scripts/validate-grafana-kubernetes.ps1
#   #157  OTel collector     infrastructure/kubernetes/observability/README.md
#   #158  Jaeger             scripts/validate-distributed-tracing.ps1
#
# Every one of those can pass while the stack as a whole is blind, because they
# each check one component against its own manifest. What none of them checks is
# the thing this issue exists for: that a request the platform actually served
# comes out the other end of BOTH pipelines. So this script does not re-assert
# what they assert - it generates one telemetry event and then requires that
# same event to be visible as a metric in Prometheus, as a metric through
# Grafana's datasource, and as traces in Jaeger.
#
# One stimulus, correlated on both sides, is the difference between "each
# component is configured" and "the pipeline works". A counter that was already
# non-zero, or a trace left over from earlier traffic, proves neither.
#
# HOW EACH COMPONENT IS REACHED. Prometheus and Jaeger are unauthenticated and
# are read through the API server's Service proxy: a synchronous request, with
# nothing exposed outside the cluster and no background process to leak. Grafana
# needs credentials and the ingestion API needs a POST, neither of which the
# proxy carries, so those two get a port-forward that this script opens and
# closes itself. Pass -GrafanaBaseUrl / -IngestionBaseUrl to reuse tunnels that
# are already up.
#
# Usage:
#   ./scripts/validate-observability-stack.ps1
#   ./scripts/validate-observability-stack.ps1 -WorkloadNamespace default -TimeoutSeconds 180

[CmdletBinding()]
param(
    # Where ingestion-service, telemetry-processor and query-service run.
    [string] $WorkloadNamespace = "default",
    # Prometheus and Grafana (#154, #155).
    [string] $MonitoringNamespace = "monitoring",
    # Collector and Jaeger (#157, #158).
    [string] $ObservabilityNamespace = "observability",

    # The chart names the server workload and Service <release>-server, and the
    # release name is not a free choice - see infrastructure/kubernetes/monitoring/README.md.
    [string] $PrometheusRelease = "prometheus",
    [string] $GrafanaService = "grafana",
    [string] $JaegerService = "jaeger",
    [string] $CollectorDeployment = "otel-collector",

    [string] $IngestionService = "ingestion-service",
    [int] $IngestionPort = 8081,
    [string] $ProcessorService = "telemetry-processor",
    [string] $QueryService = "query-service",
    [int] $QueryPort = 8083,

    # The topic ingestion publishes to and the processor consumes from. The
    # consumer span is checked against it so a DLQ or replay record, which
    # carries the same message key, cannot satisfy the correlation.
    [string] $RawTopic = "telemetry.events.raw",

    [string] $DatasourceUid = "prometheus",
    [string] $GrafanaUser = "admin",
    [string] $GrafanaPassword = "admin",

    # When empty, this script opens (and closes) its own port-forward.
    [string] $GrafanaBaseUrl = "",
    [string] $IngestionBaseUrl = "",
    [int] $GrafanaLocalPort = 13000,
    [int] $IngestionLocalPort = 18081,

    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamValidation.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamKubernetes.psm1") -Force
# The checks whose failure paths cannot be produced against a live cluster:
# rollout completeness, per-pod coverage, the log sweep's own failure, the
# port-forward cleanup and the post-stimulus comparison. Driven without a
# cluster by scripts/tests/test-observability-stack-checks.ps1.
Import-Module (Join-Path $PSScriptRoot "lib\PulseStreamObservability.psm1") -Force

$prometheusServer = "$PrometheusRelease-server"
$prometheusProxy = "/api/v1/namespaces/$MonitoringNamespace/services/$($prometheusServer):80/proxy"
$jaegerProxy = "/api/v1/namespaces/$ObservabilityNamespace/services/$($JaegerService):16686/proxy"

$grafanaAuthHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("${GrafanaUser}:${GrafanaPassword}"))
}

# --- Reaching the components -------------------------------------------------

function Invoke-ProxyJson {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ErrorContext
    )

    $raw = Invoke-KubectlChecked -KubectlArgs @("get", "--raw", $Path) -ErrorContext $ErrorContext
    return $raw | ConvertFrom-Json
}

function Invoke-ProxyText {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ErrorContext
    )

    return Invoke-KubectlChecked -KubectlArgs @("get", "--raw", $Path) -ErrorContext $ErrorContext
}

# Throws rather than asserting, because the polling below calls this on every
# attempt: a Confirm-Condition here would print an [ok] line per attempt and
# bury the assertion the caller actually cares about.
function Invoke-PrometheusQuery {
    param([Parameter(Mandatory)] [string] $Query)

    $result = Invoke-ProxyJson `
        -Path "$prometheusProxy/api/v1/query?query=$([uri]::EscapeDataString($Query))" `
        -ErrorContext "Could not reach Prometheus through the API server proxy at $prometheusProxy. Service '$prometheusServer' must exist in namespace '$MonitoringNamespace' (#154)"

    if ($result.status -ne "success") {
        throw "Prometheus rejected the query '$Query': $($result.error)"
    }

    return @($result.data.result)
}

# The scalar value of a single-series query, or 0 when nothing matches yet. A
# counter that does not exist and a counter sitting at zero are the same
# starting point for the delta below, and both are legitimate on a cluster that
# has served no traffic since the pods started.
function Get-PrometheusScalar {
    param([Parameter(Mandatory)] [string] $Query)

    $series = @(Invoke-PrometheusQuery -Query $Query)
    if ($series.Count -eq 0) { return [double] 0 }
    return [double] $series[0].value[1]
}

function Invoke-JaegerTraceSearch {
    param(
        [Parameter(Mandatory)] [string] $ServiceName,
        [Parameter(Mandatory)] [long] $StartMicros,
        [hashtable] $Tags = @{},
        [int] $Limit = 20
    )

    $query = "service=$([uri]::EscapeDataString($ServiceName))" +
             "&start=$StartMicros" +
             "&end=$([long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) * 1000)" +
             "&limit=$Limit"

    if ($Tags.Count -gt 0) {
        $query += "&tags=$([uri]::EscapeDataString(($Tags | ConvertTo-Json -Compress)))"
    }

    $result = Invoke-ProxyJson `
        -Path "$jaegerProxy/api/traces?$query" `
        -ErrorContext "Could not reach Jaeger through the API server proxy at $jaegerProxy. Service '$JaegerService' must exist in namespace '$ObservabilityNamespace' (#158)"

    return @($result.data)
}

# Spans of one kind carrying a specific tag value. Jaeger's `tags` query filters
# TRACES - a trace comes back when any one of its spans matches - so a trace
# returned by a tag search is not on its own evidence that the span we care
# about is the one that carried the tag. Both conditions are re-checked here on
# the same span.
function Get-SpansWithTag {
    param(
        [Parameter(Mandatory)] $Trace,
        [Parameter(Mandatory)] [string] $Kind,
        [Parameter(Mandatory)] [string] $TagKey,
        [Parameter(Mandatory)] [string] $TagValue
    )

    return @($Trace.spans | Where-Object {
        $span = $_
        (@($span.tags | Where-Object { $_.key -eq "span.kind" -and $_.value -eq $Kind }).Count -gt 0) -and
        (@($span.tags | Where-Object { $_.key -eq $TagKey -and "$($_.value)" -eq $TagValue }).Count -gt 0)
    })
}

# Pods matching a label selector whose Ready condition is True.
#
# Deliberately local rather than shared: #154 adds an equivalent
# Get-ReadyPodNames to PulseStreamKubernetes.psm1, and adding a second copy of
# the same function to that module here would collide with it on merge. Once
# #154 lands, this can be deleted and the module helper used instead.
function Get-ReadyPodName {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $Selector
    )

    $podsJson = Invoke-KubectlChecked `
        -KubectlArgs @("get", "pods", "--namespace", $Namespace, "-l", $Selector, "-o", "json") `
        -ErrorContext "Could not list pods matching '$Selector' in namespace '$Namespace'"

    return @(($podsJson | ConvertFrom-Json).items | Where-Object {
        $readyCondition = @($_.status.conditions | Where-Object { $_.type -eq 'Ready' }) | Select-Object -First 1
        $null -ne $readyCondition -and $readyCondition.status -eq 'True'
    } | ForEach-Object { $_.metadata.name })
}

function Get-Deployment {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $Deployment,
        [Parameter(Mandatory)] [string] $DeployedBy
    )

    $json = Invoke-KubectlChecked `
        -KubectlArgs @("get", "deployment", $Deployment, "-n", $Namespace, "-o", "json") `
        -ErrorContext "Deployment '$Deployment' was not found in namespace '$Namespace'. It is deployed by $DeployedBy"

    return $json | ConvertFrom-Json
}

# The Deployment's own selector, as a kubectl `-l` argument. Used instead of a
# guessed `app.kubernetes.io/name=` so the pods this script reasons about are
# exactly the pods that Deployment owns, whatever it labels them.
function Get-DeploymentSelector {
    param([Parameter(Mandatory)] $Deployment)

    $matchLabels = $Deployment.spec.selector.matchLabels

    if ($null -eq $matchLabels) {
        throw "Deployment '$($Deployment.metadata.name)' has no spec.selector.matchLabels; this script cannot identify its pods."
    }

    return [string]::Join(",", @($matchLabels.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }))
}

# A port-forward this script owns. Returned so the finally block can stop it
# even when an assertion in between throws - a leaked port-forward holds the
# local port and the next run fails to bind it.
#
# The readiness poll can fail too (the port is already bound, the Service has no
# endpoints, kubectl exits at once), and on that path the caller never gets a
# handle to put in its `finally`. Start-ManagedPortForward stops the process
# before re-throwing, so the failing run does not leave the port held either.
function Start-OwnedPortForward {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $Service,
        [Parameter(Mandatory)] [int] $LocalPort,
        [Parameter(Mandatory)] [int] $RemotePort,
        [Parameter(Mandatory)] [string] $ReadyPath
    )

    $log = Join-Path ([System.IO.Path]::GetTempPath()) "pulsestream-stack-$Service-port-forward.log"

    # GetNewClosure() on each block: they are invoked from inside
    # PulseStreamObservability.psm1, and a plain scriptblock would resolve
    # $Service, $log and the ports against the module's scope, where they do not
    # exist. The closure captures this function's values instead.
    $launcher = {
        Start-Process `
            -FilePath "kubectl" `
            -ArgumentList @("port-forward", "-n", $Namespace, "svc/$Service", "${LocalPort}:${RemotePort}") `
            -PassThru -NoNewWindow `
            -RedirectStandardOutput $log `
            -RedirectStandardError "$log.err"
    }.GetNewClosure()

    # kubectl reports the forward as established before the listener always
    # accepts, so the tunnel is polled rather than slept on.
    $readyProbe = {
        param([string] $BaseUrl)

        Invoke-WithRetry `
            -TimeoutSeconds 30 `
            -FailureMessage "svc/$Service did not answer on $BaseUrl$ReadyPath within 30 seconds." `
            -Operation {
                $status = Invoke-HttpStatus "$BaseUrl$ReadyPath"
                Confirm-Condition `
                    -Condition ($status -ge 200 -and $status -lt 500) `
                    -SuccessMessage "port-forward to svc/$Service is listening on $BaseUrl" `
                    -FailureMessage "port-forward to svc/$Service is not answering on $BaseUrl yet"
            }
    }.GetNewClosure()

    $stopper = {
        param($Process)

        if ($null -ne $Process -and -not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            Write-Host "[ok] the failed port-forward (pid $($Process.Id)) was stopped, so it does not hold port $LocalPort"
        }
    }.GetNewClosure()

    return Start-ManagedPortForward `
        -BaseUrl "http://localhost:$LocalPort" `
        -Description "port-forward to svc/$Service in namespace '$Namespace' (local port $LocalPort)" `
        -Log $log `
        -Launcher $launcher `
        -ReadyProbe $readyProbe `
        -Stopper $stopper
}

function Stop-OwnedPortForward {
    param($PortForward)

    if ($null -eq $PortForward -or $null -eq $PortForward.Process) { return }
    if ($PortForward.Process.HasExited) { return }

    Stop-Process -Id $PortForward.Process.Id -Force -ErrorAction SilentlyContinue
    Write-Host "[ok] port-forward (pid $($PortForward.Process.Id)) stopped"
}

# Error-level lines in a component's own log. Each of these four writes its
# level differently, which is why the pattern is per-component rather than a
# single grep for "error": Grafana's structured logs carry `level=error`, the
# collector prefixes the level as a bare field, and Prometheus uses logfmt.
# A substring search for "error" instead matches metric names, URLs and the
# word appearing inside an informational message, so it reports failures that
# are not there.
function Get-ComponentErrorLines {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $Selector,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Component,
        [string] $Since = "10m"
    )

    $logs = Invoke-Kubectl -KubectlArgs @(
        "logs", "-n", $Namespace, "-l", $Selector, "--since", $Since, "--tail", "2000", "--prefix"
    )

    # Select-ComponentErrorLine throws when kubectl failed. An empty result is
    # only ever "this component logged nothing matching the pattern"; a denied
    # RBAC rule, a wrong namespace or a container whose log has rotated away is
    # a step that could not run, and it must not read as a clean sweep.
    return @(Select-ComponentErrorLine -LogResult $logs -Pattern $Pattern -Component $Component)
}

Write-Host "Validating the observability stack end to end..."
Write-Host "  workloads:     namespace '$WorkloadNamespace'"
Write-Host "  monitoring:    namespace '$MonitoringNamespace' (Prometheus '$prometheusServer', Grafana '$GrafanaService')"
Write-Host "  observability: namespace '$ObservabilityNamespace' (collector '$CollectorDeployment', Jaeger '$JaegerService')"

$grafanaPortForward = $null
$ingestionPortForward = $null

try {

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "1. Every component of the stack is deployed and Ready."

# Checked before anything else because all of the failures below look identical
# from the outside: a missing Deployment, a crash-looping one and a correctly
# running one that is simply not wired produce the same empty query result.
$components = @(
    @{ Namespace = $MonitoringNamespace;    Deployment = $prometheusServer;      DeployedBy = "#154 (helm upgrade --install prometheus, see infrastructure/kubernetes/monitoring/README.md)" },
    @{ Namespace = $MonitoringNamespace;    Deployment = $GrafanaService;        DeployedBy = "#155 (infrastructure/kubernetes/monitoring/grafana/)" },
    @{ Namespace = $ObservabilityNamespace; Deployment = $CollectorDeployment;   DeployedBy = "#157 (infrastructure/kubernetes/observability/)" },
    @{ Namespace = $ObservabilityNamespace; Deployment = $JaegerService;         DeployedBy = "#158 (infrastructure/kubernetes/observability/)" },
    @{ Namespace = $WorkloadNamespace;      Deployment = $IngestionService;      DeployedBy = "infrastructure/kubernetes/ingestion-service/" },
    @{ Namespace = $WorkloadNamespace;      Deployment = $ProcessorService;      DeployedBy = "infrastructure/kubernetes/telemetry-processor/" },
    @{ Namespace = $WorkloadNamespace;      Deployment = $QueryService;          DeployedBy = "infrastructure/kubernetes/query-service/" }
)

# The Ready pods of each component, keyed '<namespace>/<deployment>', taken from
# the Deployment's own selector. Step 3 requires one Prometheus target and one
# sample per name in here, and step 7 sweeps the logs of exactly these pods.
$readyPodsByDeployment = @{}

# The selector each of those pod lists came from, under the same key. Step 7
# reuses it for `kubectl logs -l` rather than guessing a label of its own, so
# the sweep reads the pods this step verified and nothing else.
$selectorByDeployment = @{}

foreach ($component in $components) {
    # `readyReplicas >= 1` would pass here on a Deployment that is half-way
    # through a rolling update, or one scaled to zero and reporting nothing at
    # all. Every replica the spec asks for has to be updated, Ready and
    # available before the assertions below describe the fleet the manifests
    # declare rather than whichever pod happens to be up.
    #
    # The Deployment read, its selector and the pod list all sit inside one
    # retry. The replica count and the pod names are two reads of a moving
    # target: with the telemetry-processor HPA (#151/#152) among these
    # components, a scale event in between leaves them disagreeing, and that is
    # a stale pair of reads rather than a broken stack - the next attempt sees
    # the scaled Deployment and its own pods.
    $resolved = Invoke-WithRetry `
        -TimeoutSeconds $TimeoutSeconds `
        -FailureMessage "Deployment '$($component.Deployment)' in namespace '$($component.Namespace)' did not finish rolling out within $TimeoutSeconds seconds." `
        -Operation {
            $object = Get-Deployment -Namespace $component.Namespace -Deployment $component.Deployment -DeployedBy $component.DeployedBy
            $rollout = Get-DeploymentRolloutState -Deployment $object

            Confirm-Condition `
                -Condition $rollout.IsComplete `
                -SuccessMessage "$($component.Deployment) is fully rolled out in '$($component.Namespace)': $($rollout.Ready)/$($rollout.Desired) Ready, updated and available" `
                -FailureMessage "$($component.Deployment) in '$($component.Namespace)' is not fully rolled out: $($rollout.Reason)"

            $componentSelector = Get-DeploymentSelector -Deployment $object
            $componentPods = @(Get-ReadyPodName -Namespace $component.Namespace -Selector $componentSelector)

            # The Deployment reports counts; this is the list of names those
            # counts stand for, and the two can disagree while a terminating
            # pod is still Ready. Everything downstream matches against the
            # names.
            Confirm-Condition `
                -Condition ($componentPods.Count -eq $rollout.Desired) `
                -SuccessMessage "$($component.Deployment) has $($componentPods.Count) Ready pod(s): $($componentPods -join ', ')" `
                -FailureMessage "$($component.Deployment) wants $($rollout.Desired) replica(s) but selector '$componentSelector' matches $($componentPods.Count) Ready pod(s)"

            @{ Selector = $componentSelector; Pods = $componentPods }
        }

    $componentKey = "$($component.Namespace)/$($component.Deployment)"
    $readyPodsByDeployment[$componentKey] = $resolved.Pods
    $selectorByDeployment[$componentKey] = $resolved.Selector
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "2. The services expose metrics and traces."

# Read straight off each pod through the API server's pod proxy, not through
# Prometheus. If the endpoint is broken, going through Prometheus reports the
# same empty result as a broken scrape configuration would, and the two have
# nothing to do with each other.
$scrapedServices = @(
    @{ Name = $IngestionService; Port = $IngestionPort },
    @{ Name = $QueryService;     Port = $QueryPort }
)

$expectedMetricFamilies = @("jvm_info", "process_uptime_seconds", "application_ready_time_seconds")
$readyPodsByService = @{}

foreach ($service in $scrapedServices) {
    # Taken from step 1 rather than re-listed: those are the pods of a
    # Deployment that was proved fully rolled out, so a replica that is Ready
    # but belongs to the previous revision cannot slip in here.
    $pods = @($readyPodsByDeployment["$WorkloadNamespace/$($service.Name)"])
    $readyPodsByService[$service.Name] = $pods

    Confirm-Condition `
        -Condition ($pods.Count -gt 0) `
        -SuccessMessage "$($service.Name) has $($pods.Count) ready pod(s)" `
        -FailureMessage "$($service.Name) has no ready pods, so nothing can be scraped from it"

    # Every pod, not the first one. A rollout that half-succeeded leaves one
    # replica serving metrics and one not, and Prometheus averages over that
    # without complaining.
    foreach ($pod in $pods) {
        $metrics = Invoke-ProxyText `
            -Path "/api/v1/namespaces/$WorkloadNamespace/pods/$($pod):$($service.Port)/proxy/actuator/prometheus" `
            -ErrorContext "Could not read /actuator/prometheus from pod '$pod'. The management endpoint must be exposed on port $($service.Port)"

        $missing = @($expectedMetricFamilies | Where-Object { $metrics -notmatch "(?m)^$_" })

        Confirm-Condition `
            -Condition ($missing.Count -eq 0) `
            -SuccessMessage "$pod exposes $($expectedMetricFamilies -join ', ')" `
            -FailureMessage "$pod is missing metric families: $($missing -join ', ')"
    }
}

# telemetry-processor is deliberately absent from the list above: its actuator
# surface is on a management port bound to loopback, so it is not scraped at all
# (infrastructure/kubernetes/monitoring/README.md). It still exports traces,
# which is what the next assertion covers, and its consumer trace in step 5 is
# the thing that actually proves it is instrumented.
$tracingServices = @($IngestionService, $ProcessorService)

Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Not every tracing service had registered with Jaeger within $TimeoutSeconds seconds." `
    -Operation {
        $registered = @((Invoke-ProxyJson `
            -Path "$jaegerProxy/api/services" `
            -ErrorContext "Could not reach the Jaeger query API through the API server proxy at $jaegerProxy").data)

        foreach ($service in $tracingServices) {
            Confirm-Condition `
                -Condition ($registered -contains $service) `
                -SuccessMessage "$service is registered as a Jaeger service" `
                -FailureMessage "$service has not registered with Jaeger; it has exported no spans"
        }
    }

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "3. Prometheus is scraping them."

Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Prometheus targets were not all healthy within $TimeoutSeconds seconds." `
    -Operation {
        $targets = @((Invoke-ProxyJson `
            -Path "$prometheusProxy/api/v1/targets?state=active" `
            -ErrorContext "Could not read the Prometheus target list through the API server proxy").data.activeTargets)

        Confirm-Condition `
            -Condition ($targets.Count -gt 0) `
            -SuccessMessage "Prometheus has $($targets.Count) active target(s)" `
            -FailureMessage "Prometheus has no active targets at all"

        foreach ($target in $targets) {
            Confirm-Condition `
                -Condition ($target.health -eq "up") `
                -SuccessMessage "target $($target.scrapeUrl) (job $($target.labels.job)) is up" `
                -FailureMessage "target $($target.scrapeUrl) (job $($target.labels.job)) is '$($target.health)': $($target.lastError)"
        }

        # One target per ready pod, matched BY NAME. Counting is not enough:
        # two targets for one pod and none for its replica is the same count as
        # one each, which is the shape a stale discovery entry takes after a
        # rollout - the dashboards keep drawing a line and the unscraped replica
        # is invisible.
        foreach ($service in $scrapedServices) {
            $expectedPods = @($readyPodsByService[$service.Name])
            $found = @($targets | Where-Object { $_.labels.job -eq $service.Name })
            $targetPods = @(Get-PrometheusTargetLabel -Targets $found -Label "pod")

            $problems = @(Compare-PodCoverage `
                -Expected $expectedPods -Observed $targetPods `
                -Subject "job '$($service.Name)'")

            Confirm-Condition `
                -Condition ($problems.Count -eq 0) `
                -SuccessMessage "job '$($service.Name)' has exactly one target per Ready pod ($($targetPods -join ', '))" `
                -FailureMessage "job '$($service.Name)' does not cover its Ready pods one-to-one: $($problems -join '; ')"
        }
    }

# `up` and one application metric, matched to the same pods. A target that
# discovery lists is not necessarily a target Prometheus stores a series for:
# a scrape that fails on every attempt still yields up=0, and a relabel rule
# that drops the `pod` label leaves the series unattributable to a replica even
# though the fleet looks complete in the target list.
foreach ($service in $scrapedServices) {
    $expectedPods = @($readyPodsByService[$service.Name])

    $perPodQueries = @(
        @{ Query = "up{job=""$($service.Name)""}";                     Kind = "up";                 Predicate = { param($value) $value -eq "1" };            Requirement = "1" },
        @{ Query = "process_uptime_seconds{job=""$($service.Name)""}"; Kind = "an application metric"; Predicate = { param($value) [double] $value -gt 0 }; Requirement = "greater than 0" }
    )

    foreach ($perPod in $perPodQueries) {
        $series = @(Invoke-PrometheusQuery -Query $perPod.Query)
        $seriesPods = @(Get-PrometheusSeriesLabel -Series $series -Label "pod")

        $problems = @(Compare-PodCoverage `
            -Expected $expectedPods -Observed $seriesPods `
            -Subject "$($perPod.Query)")

        Confirm-Condition `
            -Condition ($problems.Count -eq 0) `
            -SuccessMessage "$($perPod.Query) has exactly one series per Ready pod" `
            -FailureMessage "$($perPod.Query) does not cover the Ready pods of '$($service.Name)' one-to-one: $($problems -join '; ')"

        $samples = @(Get-PrometheusSampleValue -Series $series -Label "pod")
        $wrong = @($samples | Where-Object { -not (& $perPod.Predicate $_.Value) })

        Confirm-Condition `
            -Condition ($wrong.Count -eq 0) `
            -SuccessMessage "$($perPod.Query) is $($perPod.Requirement) on every Ready pod" `
            -FailureMessage "$($perPod.Query) is not $($perPod.Requirement) on: $(@($wrong | ForEach-Object { "$($_.Pod)=$($_.Value)" }) -join ', ')"
    }
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "4. The metrics pipeline observes a request this run generated."

# Sum across replicas: the request lands on whichever pod the Service picks, and
# asserting on a single instance would fail whenever it picks the other one.
$acceptedEventsQuery = "sum(http_server_requests_seconds_count{job=""$IngestionService"",uri=""/api/v1/events"",status=""202""})"
$acceptedBefore = Get-PrometheusScalar -Query $acceptedEventsQuery
Write-Host "[ok] baseline: $acceptedEventsQuery = $acceptedBefore"

if ([string]::IsNullOrWhiteSpace($IngestionBaseUrl)) {
    $ingestionPortForward = Start-OwnedPortForward `
        -Namespace $WorkloadNamespace -Service $IngestionService `
        -LocalPort $IngestionLocalPort -RemotePort $IngestionPort -ReadyPath "/actuator/health"
    $IngestionBaseUrl = $ingestionPortForward.BaseUrl
} else {
    Write-Host "[ok] using the ingestion endpoint already provided: $IngestionBaseUrl"
}

# Captured before the request so every span it produces falls inside the Jaeger
# search window in step 5, and so a trace from earlier traffic cannot.
$searchStartMicros = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 60000) * 1000

$eventId = [Guid]::NewGuid().ToString()
$requestBody = @{
    eventId   = $eventId
    tenantId  = "observability-stack-validation"
    eventType = "telemetry.reading"
    timestamp = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    source    = "validate-observability-stack"
    version   = "1.0"
    payload   = @{
        deviceId   = "stack-validation-device"
        deviceType = "temperature-sensor"
        metric     = "temperature"
        value      = 21.5
        unit       = "celsius"
        location   = "validation-lab"
    }
} | ConvertTo-Json -Depth 5

try {
    Invoke-RestMethod -Method Post -Uri "$IngestionBaseUrl/api/v1/events" `
        -ContentType "application/json" -Body $requestBody -TimeoutSec 15 | Out-Null
} catch {
    throw "Failed to POST the telemetry event to $IngestionBaseUrl. Every field of TelemetryIngestionRequestDto is required and a rejected body never reaches the instrumented path. $($_.Exception.Message)"
}
Write-Host "[ok] generated one telemetry event (eventId: $eventId)"

# The scrape interval, not the request, sets how long this takes: the counter
# only moves in Prometheus once the pod that served the request is scraped
# again.
# Kept: step 6 requires Grafana to answer with at least this value, which is
# what makes its answer this run's rather than any historical one.
$acceptedAfter = Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Prometheus did not observe the generated request within $TimeoutSeconds seconds. The service counted it locally (the POST returned 202), so the break is between the pod and Prometheus." `
    -Operation {
        $observed = Get-PrometheusScalar -Query $acceptedEventsQuery
        Confirm-Condition `
            -Condition ($observed -gt $acceptedBefore) `
            -SuccessMessage "Prometheus counted the request: $acceptedEventsQuery went $acceptedBefore -> $observed" `
            -FailureMessage "Prometheus still reports $acceptedEventsQuery = $observed, unchanged from the baseline"

        $observed
    }

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "5. The trace pipeline observes the same request."

# The ingestion controller records the event id on its span, so the trace this
# run produced can be found by tag rather than by "the most recent one".
$requiredOperation = "TelemetryController.ingestTelemetry"

$ingestionTrace = Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "No ingestion-service trace reached Jaeger for eventId $eventId within $TimeoutSeconds seconds. The span crosses the service, the collector and the backend, so check the collector log next (see infrastructure/kubernetes/observability/README.md)." `
    -Operation {
        $traces = Invoke-JaegerTraceSearch `
            -ServiceName $IngestionService `
            -StartMicros $searchStartMicros `
            -Tags @{ "pulsestream.event.id" = $eventId }

        if ($traces.Count -eq 0) {
            throw "No ingestion trace for eventId $eventId yet"
        }

        $trace = $traces[0]

        # Waited for inside the retry rather than asserted after it: the spans of
        # one trace reach Jaeger in separate exported batches (the collector's
        # `batch` processor flushes on size or on its 5s timeout), so the first
        # result returned is routinely the entry span alone.
        if (@($trace.spans | ForEach-Object { $_.operationName }) -notcontains $requiredOperation) {
            throw "Ingestion trace for eventId $eventId is still partial; missing the $requiredOperation span"
        }

        $trace
    }

Confirm-Condition `
    -Condition ($ingestionTrace.spans.Count -gt 0) `
    -SuccessMessage "ingestion trace $($ingestionTrace.traceID) is in Jaeger for eventId $eventId" `
    -FailureMessage "ingestion trace for eventId $eventId has no spans"

# The processor does not set `pulsestream.event.id` - that attribute belongs to
# the ingestion controller. Ingestion publishes each event under a Kafka message
# key equal to its event id (KafkaProducerService.resolveMessageKey) and the
# spring-kafka instrumentation records that key on the consumer span, so that is
# the handle across the Kafka hop. Accepting any recent consumer trace instead
# would pass on traffic this run never generated.
$processorTrace = Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "No telemetry-processor consumer trace reached Jaeger for eventId $eventId within $TimeoutSeconds seconds. The processor consumes from Kafka, so this lags ingestion by the consumer poll and any partition backlog." `
    -Operation {
        $traces = Invoke-JaegerTraceSearch `
            -ServiceName $ProcessorService `
            -StartMicros $searchStartMicros `
            -Tags @{ "messaging.kafka.message.key" = $eventId }

        $correlated = @($traces | Where-Object {
            (Get-SpansWithTag -Trace $_ -Kind "consumer" `
                -TagKey "messaging.kafka.message.key" -TagValue $eventId).Count -gt 0
        })

        if ($correlated.Count -eq 0) {
            throw "No telemetry-processor consumer span keyed to eventId $eventId yet"
        }

        $correlated[0]
    }

$consumerSpan = (Get-SpansWithTag -Trace $processorTrace -Kind "consumer" `
    -TagKey "messaging.kafka.message.key" -TagValue $eventId)[0]

$destination = $consumerSpan.tags |
    Where-Object { $_.key -eq "messaging.destination.name" } |
    Select-Object -First 1 -ExpandProperty value

# A DLQ or replay record carries the same message key, so the key alone does not
# establish that the event travelled the normal ingest path.
Confirm-Condition `
    -Condition ($destination -eq $RawTopic) `
    -SuccessMessage "telemetry-processor consumed eventId $eventId from $RawTopic (trace $($processorTrace.traceID))" `
    -FailureMessage "the consumer span for eventId $eventId names destination '$destination', not '$RawTopic'"

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "6. Grafana serves that data."

if ([string]::IsNullOrWhiteSpace($GrafanaBaseUrl)) {
    $grafanaPortForward = Start-OwnedPortForward `
        -Namespace $MonitoringNamespace -Service $GrafanaService `
        -LocalPort $GrafanaLocalPort -RemotePort 80 -ReadyPath "/api/health"
    $GrafanaBaseUrl = $grafanaPortForward.BaseUrl
} else {
    Write-Host "[ok] using the Grafana endpoint already provided: $GrafanaBaseUrl"
}

$health = Invoke-JsonGet "$GrafanaBaseUrl/api/health"
Confirm-Condition `
    -Condition ($health.database -eq "ok") `
    -SuccessMessage "Grafana is healthy (version $($health.version))" `
    -FailureMessage "Grafana reports database status '$($health.database)'"

Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "The Grafana datasource '$DatasourceUid' did not report healthy within $TimeoutSeconds seconds." `
    -Operation {
        $datasourceHealth = Invoke-JsonGet "$GrafanaBaseUrl/api/datasources/uid/$DatasourceUid/health" -Headers $grafanaAuthHeader
        Confirm-Condition `
            -Condition ($datasourceHealth.status -eq "OK") `
            -SuccessMessage "Grafana reaches Prometheus through datasource '$DatasourceUid': $($datasourceHealth.message)" `
            -FailureMessage "datasource '$DatasourceUid' is '$($datasourceHealth.status)': $($datasourceHealth.message)"
    }

# Piped through ForEach-Object rather than wrapped in @(): the JSON array comes
# back from the helper as a single object, so @() alone would count one
# "dashboard" no matter how many were loaded - including zero of them wrapped in
# an empty array, which is exactly the case this assertion exists to catch.
$dashboards = @(Invoke-JsonGet "$GrafanaBaseUrl/api/search?type=dash-db" -Headers $grafanaAuthHeader |
    ForEach-Object { $_ })
Confirm-Condition `
    -Condition ($dashboards.Count -gt 0) `
    -SuccessMessage "Grafana has $($dashboards.Count) dashboard(s) loaded: $(@($dashboards | ForEach-Object { $_.title }) -join ', ')" `
    -FailureMessage "Grafana has no dashboards loaded. The provisioning ConfigMaps have to be MOUNTED, not just applied (#156)"

# The datasource resources API proxies the query through Grafana, so a result
# here covers the path a browser actually uses. This is deliberately one query
# rather than every panel: per-panel expression coverage belongs to
# scripts/validate-grafana-kubernetes.ps1 (#156). What is being proved here is
# that the request this run generated is visible at the far end of the metrics
# pipeline, from the tool an operator opens.
#
# "Grafana returned something" would not be that proof. The counter is non-zero
# for as long as the pod lives, so a Grafana wired to a different Prometheus, or
# answering from before the stimulus, comes back non-empty and passes. The value
# has to be at least the $acceptedAfter that Prometheus reported once it had
# counted this run's request.
Invoke-WithRetry `
    -TimeoutSeconds $TimeoutSeconds `
    -FailureMessage "Grafana did not serve this run's value for $acceptedEventsQuery within $TimeoutSeconds seconds." `
    -Operation {
        $grafanaQuery = Invoke-JsonGet `
            ("$GrafanaBaseUrl/api/datasources/uid/$DatasourceUid/resources/api/v1/query" +
             "?query=$([uri]::EscapeDataString($acceptedEventsQuery))") `
            -Headers $grafanaAuthHeader

        $verdict = Test-PostStimulusMetric `
            -Response $grafanaQuery -Minimum $acceptedAfter -Query $acceptedEventsQuery

        Confirm-Condition `
            -Condition $verdict.Ok `
            -SuccessMessage "Grafana serves this run's value through its datasource ($acceptedEventsQuery = $($verdict.Value), at least the $acceptedAfter Prometheus reported after the stimulus)" `
            -FailureMessage "Grafana is not serving this run's data for $($acceptedEventsQuery): $($verdict.Reason)"
    }

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "7. No major telemetry pipeline errors remain."

# Run last, and over a window that covers everything above, so it sees the
# errors the traffic this script generated would have produced.
#
# No selector is written out here. A hand-written `app.kubernetes.io/...` label
# is not the Deployment's own selector, and for a Helm sub-chart it is not even
# close: `app.kubernetes.io/instance=$PrometheusRelease` matches node-exporter,
# kube-state-metrics, alertmanager and pushgateway as well as the server. Each
# sweep reuses the selector step 1 read off the Deployment, so it covers that
# Deployment's pods and nothing else.
$errorSources = @(
    @{
        Component = "otel-collector"
        Namespace = $ObservabilityNamespace
        Deployment = $CollectorDeployment
        # The collector logs its level as a bare tab-separated field.
        Pattern   = '(?m)\s(error|fatal|dpanic|panic)\s'
    },
    @{
        Component = "jaeger"
        Namespace = $ObservabilityNamespace
        Deployment = $JaegerService
        Pattern   = '(?m)"level"\s*:\s*"(error|fatal|dpanic|panic)"'
    },
    @{
        Component = "prometheus"
        Namespace = $MonitoringNamespace
        Deployment = $prometheusServer
        Pattern   = '(?m)level=(error|fatal)'
    },
    @{
        Component = "grafana"
        Namespace = $MonitoringNamespace
        Deployment = $GrafanaService
        Pattern   = '(?m)level=(error|eror|crit)'
    }
)

foreach ($source in $errorSources) {
    $sourceKey = "$($source.Namespace)/$($source.Deployment)"
    $sourceSelector = $selectorByDeployment[$sourceKey]

    # Step 1 covers every Deployment swept here, so a missing entry means this
    # list and $components have drifted apart, not that the cluster is unwell.
    Confirm-Condition `
        -Condition (-not [string]::IsNullOrWhiteSpace($sourceSelector)) `
        -SuccessMessage "the $($source.Component) log sweep uses its Deployment's own selector '$sourceSelector'" `
        -FailureMessage "no selector was recorded for '$sourceKey' in step 1, so the $($source.Component) log sweep has no pods to read"

    # The selector is still re-resolved before the sweep runs, because a
    # selector that matches nothing produces the same empty output as a
    # component that logged no errors. `kubectl logs -l` exits 0 on a selector
    # matching no pods, so the quietest possible result here is also the least
    # trustworthy one: this requires the selector to still resolve to exactly
    # the Ready pods step 1 found, which a pod replaced part-way through the
    # run would not.
    $expectedPods = @($readyPodsByDeployment[$sourceKey])
    $selectedPods = @(Get-ReadyPodName -Namespace $source.Namespace -Selector $sourceSelector)

    $coverage = @(Compare-PodCoverage `
        -Expected $expectedPods -Observed $selectedPods `
        -Subject "the $($source.Component) log selector '$sourceSelector'")

    Confirm-Condition `
        -Condition ($coverage.Count -eq 0) `
        -SuccessMessage "the $($source.Component) log selector matches its $($selectedPods.Count) Ready pod(s)" `
        -FailureMessage "the $($source.Component) log sweep would not have read the component it names: $($coverage -join '; ')"

    # Throws when kubectl could not read the logs - RBAC, a wrong namespace, a
    # rotated container log. A sweep that returns "no errors" because it read
    # nothing is the failure mode this step exists to avoid.
    $errorLines = @(Get-ComponentErrorLines `
        -Namespace $source.Namespace -Selector $sourceSelector `
        -Pattern $source.Pattern -Component $source.Component)

    if ($errorLines.Count -gt 0) {
        foreach ($line in @($errorLines | Select-Object -First 5)) {
            Write-Host "    $line"
        }
    }

    Confirm-Condition `
        -Condition ($errorLines.Count -eq 0) `
        -SuccessMessage "$($source.Component) logged no errors in the last 10 minutes" `
        -FailureMessage "$($source.Component) logged $($errorLines.Count) error line(s) in the last 10 minutes (first ones printed above)"
}

# A target that is `up` can still be failing every other scrape, which shows up
# as a lastError while health flaps back to up in between.
$targetsWithErrors = @((Invoke-ProxyJson `
    -Path "$prometheusProxy/api/v1/targets?state=active" `
    -ErrorContext "Could not read the Prometheus target list through the API server proxy").data.activeTargets |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_.lastError) })

Confirm-Condition `
    -Condition ($targetsWithErrors.Count -eq 0) `
    -SuccessMessage "no Prometheus target reports a scrape error" `
    -FailureMessage "$($targetsWithErrors.Count) Prometheus target(s) report a scrape error: $(@($targetsWithErrors | ForEach-Object { "$($_.scrapeUrl): $($_.lastError)" }) -join '; ')"

Write-Host ""
Write-Host "[ok] Observability stack validation completed. Event $eventId was visible as a metric in Prometheus, through Grafana, and as traces in Jaeger."

} finally {
    Stop-OwnedPortForward -PortForward $ingestionPortForward
    Stop-OwnedPortForward -PortForward $grafanaPortForward
}
