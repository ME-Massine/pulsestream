# In-cluster Prometheus

Cluster-level metrics collection for the platform services (#154).

| File | Purpose |
| --- | --- |
| `prometheus-values.yaml` | Helm values for the `prometheus-community/prometheus` chart: what runs, and the complete set of scrape targets. |

Prometheus is installed as an add-on from a chart rather than vendored as raw manifests, matching how `metrics-server`, the Strimzi operator and `prometheus-adapter` are handled in this repository. Only the values file is version-controlled; the chart is fetched at install time.

This is the **cluster** path. The Compose stack keeps its own Prometheus (`infrastructure/docker/prometheus/prometheus.yml`, validated by `scripts/validate-prometheus-metrics.ps1`), which is unchanged and still the local-development path. Its static host target produces no `namespace`/`pod` labels, so it is unusable in a cluster — the configuration here uses pod discovery for that reason.

## Install

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace monitoring --create-namespace \
  --values infrastructure/kubernetes/monitoring/prometheus-values.yaml
```

The release name and namespace are **not** free choices. `prometheus` in `monitoring` produces the Service `prometheus-server.monitoring.svc`, which is the URL [`../autoscaling/prometheus-adapter-values.yaml`](../autoscaling/prometheus-adapter-values.yaml) already points at. Renaming either fails silently: the adapter keeps running and every custom metric turns into `<unknown>`. Change both together if you must change one.

## What is scraped

| Job | Target | Why |
| --- | --- | --- |
| `prometheus` | Prometheus' own `/metrics` | Proves the server is collecting even when no platform workload is deployed. |
| `ingestion-service` | `/actuator/prometheus` on every `ingestion-service` pod, port `http` (8081) | Service metrics, and the source of the `http_requests_per_second` custom metric (#152). |
| `query-service` | `/actuator/prometheus` on every `query-service` pod, port `http` (8083) | Service metrics. |

Both service jobs use `kubernetes_sd_configs` with `role: pod` rather than a static or Service target: one target per replica, and each series carries `namespace` and `pod`. Those two labels are what `prometheus-adapter` maps a metric onto a pod with — a Service target would load-balance across replicas and produce one anonymous series that the adapter cannot use.

The chart's own default jobs (API server, kubelet, cAdvisor, annotation-driven pod and endpoint discovery) are disabled key by key in the values file. Nothing in this repository consumes them, and `scrapeConfigs` is a map that Helm merges rather than replaces, so a default left un-disabled would silently stay enabled.

### telemetry-processor is not scraped

Its actuator surface — including the state-changing `dlqreplay` endpoint (#125) — is served on a separate management port bound to loopback by default, so `/actuator/prometheus` is not reachable from the pod network. A scrape job for it would be a permanently failing target. Making it scrapable means exposing that management port and putting a matching NetworkPolicy rule in front of it, which is a service and isolation change rather than a Prometheus change.

### NetworkPolicies and an enforcing CNI

The platform NetworkPolicies (#147) predate this Prometheus and do not know about it:

- `ingestion-service` admits its `http` port from **any** peer, so it is scraped from any namespace.
- `query-service` admits its `http` port from the **same namespace only**. On a cluster whose CNI enforces NetworkPolicy (Calico, Cilium), a Prometheus in `monitoring` is therefore blocked from scraping it and that job's targets report a connection error. On kind/kindnet and Docker Desktop, which do not enforce NetworkPolicy, it is scraped normally.

Two ways out, neither of which this issue makes: install this release into the platform namespace instead (and repoint `prometheus.url` in the adapter values), or add an ingress rule to [`../network-policies/query-service.yaml`](../network-policies/query-service.yaml) admitting the `monitoring` namespace on the `http` port.

## Validate

```bash
pwsh ./scripts/validate-prometheus-kubernetes.ps1
```

Checks, in order, that the server is running with its Service, that the **applied** scrape configuration has the documented shape, that Prometheus answers queries, that every job has healthy targets, and that the service jobs produce real `jvm_info` series carrying `namespace` and `pod`. It reaches Prometheus through the API server's Service proxy, so nothing has to be exposed and no port-forward is left running.

By hand:

```bash
kubectl get pods --namespace monitoring
kubectl port-forward --namespace monitoring svc/prometheus-server 9090:80
```

then `http://localhost:9090` — Status → Targets should list every job as `UP`, and:

```
up{job="ingestion-service"}
jvm_info{job="ingestion-service"}
```

should both return a series per Ready pod, each with `namespace` and `pod` labels.

An empty result with a healthy target usually means the scrape reached something other than `/actuator/prometheus`. A missing target means no pod carries `app.kubernetes.io/name=<service>` — deploy the service first. A target in error against `query-service` on an enforcing CNI is the NetworkPolicy case above.

## Validation without a cluster

```bash
pwsh ./scripts/tests/test-prometheus-scrape-config.ps1
```

Reads `prometheus-values.yaml`, projects it onto the shape the chart renders, and asserts the same thing the cluster validator asserts about the applied ConfigMap — the job set, the metrics path, pod discovery, and the `namespace`/`pod` relabel rules. No cluster, no `kubectl`, no Helm, no network.

## Retention and storage

`persistentVolume` is disabled: on a dev cluster with no default StorageClass the pod would stay `Pending` forever waiting for a volume to bind, which is a worse failure than losing history on a restart. Retention is 24h, and the data lives in the pod. Autoscaling decisions and the validation queries above read minutes of data, so this is sufficient for what consumes the metrics today — enable persistence before treating this instance as a source of historical truth.

## Out of scope

Alertmanager, alert rules, Grafana dashboards and any tracing backend. The chart's Alertmanager, Pushgateway, node-exporter and kube-state-metrics sub-charts are all disabled here.
