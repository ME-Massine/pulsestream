# Observability Stack Validation

Repeatable check that the platform's **metrics** and **traces** pipelines work
end to end in Kubernetes: that one request the platform actually served comes
out the far end of both, visible in Prometheus, through Grafana, and in Jaeger.

This is the acceptance gate for the observability stack (#159). It is not a
substitute for the per-component validators — it is the check none of them can
make.

Out of scope: alerting policy design and performance benchmarking.

---

## Why a separate check

The stack is four components, each deployed and validated by its own issue:

| Component | Deployed by | Its own validator |
| --- | --- | --- |
| Prometheus | #154 — `infrastructure/kubernetes/monitoring/` | `scripts/validate-prometheus-kubernetes.ps1` |
| Grafana | #155 — `infrastructure/kubernetes/monitoring/grafana/` | `scripts/validate-grafana-deployment.ps1` |
| Grafana provisioning | #156 — datasource and dashboard ConfigMaps | `scripts/validate-grafana-kubernetes.ps1` |
| OpenTelemetry collector | #157 — `infrastructure/kubernetes/observability/` | `infrastructure/kubernetes/observability/README.md` |
| Jaeger | #158 — `infrastructure/kubernetes/observability/` | `scripts/validate-distributed-tracing.ps1` |

Every one of those can pass while the stack as a whole is blind, because each
checks one component against its own manifest. A dashboard can be loaded and
query a label the in-cluster Prometheus does not produce. A collector can accept
spans and forward them to a backend nobody queries. Prometheus can hold a target
per replica and never be reached by the tool an operator opens.

What ties them together is a single stimulus: generate one telemetry event, then
require **that** event to be observable on both sides. A counter that was
already non-zero, or a trace left over from earlier traffic, proves neither
pipeline works.

---

## What is validated

`scripts/validate-observability-stack.ps1`, in order:

| # | Step | Fails when |
| --- | --- | --- |
| 1 | Every component of the stack is fully rolled out | A component is missing, crash-looping, scaled to zero, or half-way through a rolling update. Every replica the spec asks for must be **updated, Ready and available**, with the controller having observed the current generation — `readyReplicas >= 1` passes on one new pod of three and on a fleet still running the previous template. The Ready pod **names** are taken from each Deployment's own selector here, and everything downstream matches against them. |
| 2 | The services expose metrics and traces | `/actuator/prometheus` is read from **every ready pod** through the API server's pod proxy, not through Prometheus, so a broken endpoint is not confused with a broken scrape config. Tracing services must have registered with Jaeger. |
| 3 | Prometheus is scraping them | Any target is not `up`, or the job's targets, its `up` series and an application metric (`process_uptime_seconds`) do not match the Ready pods of that workload **one-to-one by pod name**. Counting is not enough: two targets for one pod and none for its replica is the same count as one each, and that is the shape a stale discovery entry takes after a rollout — the dashboard keeps drawing a line and the unscraped replica is invisible. A series carrying no `pod` label is reported as unattributable rather than silently dropped. |
| 4 | The metrics pipeline observes a request this run generated | One event is posted, and `sum(http_server_requests_seconds_count{…,status="202"})` must **increase** from a baseline read before the request. |
| 5 | The trace pipeline observes the same request | The ingestion trace is found by `pulsestream.event.id`, and the processor's consumer trace by `messaging.kafka.message.key`, which ingestion sets to the event id. The consumer span's destination topic is checked too, since a DLQ or replay record carries the same key. |
| 6 | Grafana serves that data | The datasource health check, the dashboards being loaded, and the same query run **through Grafana's datasource proxy** — the path a browser uses. The answer must be **at least the value Prometheus reported after the stimulus**: the counter is non-zero for as long as the pod lives, so a Grafana wired to a different Prometheus, or answering from before the request, returns data and would satisfy any "returned something" check. |
| 7 | No major telemetry pipeline errors remain | Any error-level line in the collector, Jaeger, Prometheus or Grafana logs from the last 10 minutes, or any Prometheus target carrying a `lastError`. Each log selector is first required to resolve to exactly the Ready pods of the Deployment it names, and a `kubectl logs` that **fails** (RBAC, wrong namespace, a rotated container log) fails the step — `kubectl logs -l` exits 0 on a selector matching nothing, so the quietest result here would otherwise be the least trustworthy one. |

### telemetry-processor is not scraped

Its actuator surface — including the state-changing `dlqreplay` endpoint — is
served on a management port bound to loopback, so `/actuator/prometheus` is not
reachable from the pod network and it has no Prometheus job (see
`infrastructure/kubernetes/monitoring/README.md`). Step 2 therefore asserts
metrics only for `ingestion-service` and `query-service`. The processor is
covered on the tracing side instead, and step 5's correlated consumer span is
what actually proves it is instrumented and consuming.

### How each component is reached

Prometheus and Jaeger are unauthenticated, and are read through the **API
server's Service proxy**: a synchronous request, nothing exposed outside the
cluster, and no background process to leak if an assertion fails.

Grafana needs credentials and the ingestion API needs a `POST`, neither of which
the proxy carries. Those two get a `kubectl port-forward` that the script opens
and closes itself, in a `finally` block — a leaked port-forward holds the local
port and the next run cannot bind it. Pass `-GrafanaBaseUrl` / `-IngestionBaseUrl`
to reuse tunnels that are already up.

The tunnel is also stopped when its own readiness poll fails (the port is
already bound, the Service has no endpoints, `kubectl` exits at once). On that
path the caller never receives a handle, so the `finally` block has nothing to
stop — and the `kubectl` process would outlive the run still holding the port,
failing the next run with an error that names the port rather than the reason.

### The failure paths are tested without a cluster

Every check above is one whose **failure** is the interesting case, and none of
them can be demonstrated on a healthy cluster on demand: a Deployment half-way
through a rollout, a job covering one replica twice and its sibling not at all,
a denied `kubectl logs`, a port-forward that never answers, a Grafana serving a
value from before the stimulus. Getting any of them wrong reports a working
stack, which is worse than no validator.

They live in `scripts/lib/PulseStreamObservability.psm1` as functions, and
`scripts/tests/test-observability-stack-checks.ps1` drives each through its
failure cases with no cluster and no Grafana:

```powershell
pwsh ./scripts/tests/test-observability-stack-checks.ps1
```

---

## Prerequisites

- A reachable cluster with the platform services deployed (`ingestion-service`,
  `telemetry-processor`, `query-service`), plus Kafka and Postgres.
- All four observability components deployed — see the table above. Step 1
  names the issue that deploys anything it cannot find.
- Grafana credentials. The script defaults to `admin`/`admin`; pass
  `-GrafanaUser` / `-GrafanaPassword` for anything else.

### The stack has to be the one in this repository

Step 6 asserts that Grafana has the dashboards loaded, which requires the #156
provisioning ConfigMaps to be **mounted** into the Grafana pod. Applying them is
not enough, and the Grafana Deployment in #155 currently mounts only its data and
`tmp` volumes — so on a stack deployed purely from the manifests in this
repository, step 6 fails until that Deployment gains the three mounts documented
in
[`infrastructure/kubernetes/monitoring/grafana/README.md`](../../infrastructure/kubernetes/monitoring/grafana/README.md).

A run that passes only after mounting them by hand validates that cluster, not
the manifests. The evidence this issue is accepted on has to come from a stack
brought up entirely from the repository.

---

## Run

```powershell
pwsh ./scripts/validate-observability-stack.ps1
```

Against workloads in another namespace, or a slower cluster:

```powershell
pwsh ./scripts/validate-observability-stack.ps1 `
    -WorkloadNamespace default `
    -MonitoringNamespace monitoring `
    -ObservabilityNamespace observability `
    -TimeoutSeconds 180
```

The script exits non-zero on the first failed assertion and prints the event id
it generated, so the same event can be looked up by hand afterwards.

### How long it takes

Dominated by two waits, neither of which is the request itself:

- **Step 4** waits for the next Prometheus scrape of the pod that served the
  request. Nothing moves before that, however healthy the pipeline is.
- **Step 5** waits for the collector's `batch` processor (5s timeout) and, for
  the consumer trace, the processor's Kafka poll and any partition backlog.

`-TimeoutSeconds` bounds each wait separately, not the run as a whole.

---

## Reading a failure

| Symptom | Where the break is |
| --- | --- |
| Step 2 passes, step 3 fails | The service exposes metrics but Prometheus is not collecting them: scrape config, pod discovery, or a NetworkPolicy in front of the port. |
| Step 3 passes, step 4 fails | Prometheus is scraping, but the request never reached the pod it scrapes, or the scrape interval has not elapsed. The `202` from the POST rules out the service rejecting it. |
| Step 4 passes, step 5 fails | The metrics path works and the trace path does not. Read the collector's `debug` exporter output next — it logs one line per exported batch and is the only signal that survives Jaeger being down (`infrastructure/kubernetes/observability/README.md`). |
| Steps 4 and 5 pass, step 6 fails | Both pipelines work and Grafana cannot see them: the datasource, or provisioning ConfigMaps that were applied but never **mounted**. |
| Everything passes, step 7 fails | The pipeline works and something in it is still logging errors — a flapping target, a rejected export batch, a failing dashboard query. |
| Step 1 fails with "not fully rolled out" | The component is up but the fleet is not the one the manifests declare: a rollout in flight, a failed new revision, or a Deployment scaled below its spec. Nothing after it would describe every replica. |
| Step 3 fails on coverage, not on `up` | Prometheus is scraping *something*, but not one target or series per Ready pod: discovery missed a replica, a stale target survives from a previous revision, or a relabel rule dropped the `pod` label the series are attributed by. |
| Step 7 fails before reading any log | The log selector does not resolve to that component's Ready pods, or `kubectl logs` could not read them at all. The sweep refuses to report a clean result it did not observe. |

---

## Related

- [`infrastructure/kubernetes/monitoring/README.md`](../../infrastructure/kubernetes/monitoring/README.md) — what Prometheus scrapes and why.
- [`infrastructure/kubernetes/monitoring/grafana/README.md`](../../infrastructure/kubernetes/monitoring/grafana/README.md) — datasource and dashboard provisioning.
- [`infrastructure/kubernetes/observability/README.md`](../../infrastructure/kubernetes/observability/README.md) — the collector pipeline and the Jaeger backend.
- [`docs/architecture/custom-metrics-autoscaling.md`](custom-metrics-autoscaling.md) — the other consumer of the same Prometheus.
