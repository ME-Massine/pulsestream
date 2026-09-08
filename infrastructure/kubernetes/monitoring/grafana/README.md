# Grafana provisioning

What turns the in-cluster Grafana from an empty install into the platform's metrics view (#156): the Prometheus datasource it queries through, and the dashboards it loads at startup.

| File | Mounted at | Purpose |
| --- | --- | --- |
| `datasource-configmap.yaml` | `/etc/grafana/provisioning/datasources` | The Prometheus datasource, `uid: prometheus`, pointing at the #154 Service. |
| `dashboard-provider-configmap.yaml` | `/etc/grafana/provisioning/dashboards` | The file provider that tells Grafana to load dashboards from the directory below. |
| `dashboards-configmap.yaml` | `/etc/grafana/dashboards` | The dashboard JSON itself. |

All three are required. The provider without the dashboards gives an empty `PulseStream` folder; the dashboards without the provider gives nothing at all, and no error in either case.

## Prerequisites

- **Prometheus in the cluster (#154)** — `Service/prometheus-server` in namespace `monitoring`, port 80. The datasource URL is that name spelled out; nothing here deploys it.
- **Grafana in the cluster (#155)** — `Deployment/grafana` and `Service/grafana` in namespace `monitoring`. This directory does not deploy Grafana either: it is the configuration Grafana reads, and it has to be mounted by whatever runs it.

## Apply

```bash
kubectl apply -f infrastructure/kubernetes/monitoring/grafana/
```

Applying the ConfigMaps is not enough on its own — Grafana has to mount them.

### Wiring them into a Grafana Deployment

Grafana reads its provisioning directories once, at startup. The three mounts:

```yaml
    spec:
      containers:
        - name: grafana
          volumeMounts:
            - name: datasource
              mountPath: /etc/grafana/provisioning/datasources
              readOnly: true
            - name: dashboard-provider
              mountPath: /etc/grafana/provisioning/dashboards
              readOnly: true
            - name: dashboards
              # Must match `options.path` in dashboard-provider-configmap.yaml.
              mountPath: /etc/grafana/dashboards
              readOnly: true
      volumes:
        - name: datasource
          configMap:
            name: grafana-datasource
        - name: dashboard-provider
          configMap:
            name: grafana-dashboard-provider
        - name: dashboards
          configMap:
            name: grafana-dashboards
```

### If Grafana is installed from the `grafana` Helm chart instead

The chart runs a sidecar that watches for labelled ConfigMaps cluster-wide, and both labels are already on these manifests:

- `grafana_datasource: "1"` on `grafana-datasource`
- `grafana_dashboard: "1"` on `grafana-dashboards`

Enable `sidecar.datasources.enabled` and `sidecar.dashboards.enabled` in the chart's values, and **do not apply `dashboard-provider-configmap.yaml`**: the sidecar writes its own provider pointing at the directory it syncs into, so a second provider loads the same dashboards twice under the same UIDs.

## Applying a change

| Changed | Takes effect |
| --- | --- |
| `dashboards-configmap.yaml` | On its own, within ~1 minute: the kubelet refreshes the mounted files and the provider re-scans every 30s. |
| `datasource-configmap.yaml` | Only on restart — `kubectl rollout restart deployment/grafana -n monitoring`. Provisioning of datasources runs at startup. |
| `dashboard-provider-configmap.yaml` | Only on restart, for the same reason. |

## Verify

```powershell
./scripts/validate-grafana-kubernetes.ps1
```

The script opens its own `kubectl port-forward` (pass `-GrafanaBaseUrl` to reuse one) and walks the three acceptance criteria in the order they fail: the ConfigMaps are applied and carry what is committed, the datasource is provisioned and its health check reaches Prometheus, both dashboards are loaded in the `PulseStream` folder, and every panel query returns at least one series.

**It validates the dashboards Grafana serves, not the files on disk.** Each dashboard is fetched with `/api/dashboards/uid/<uid>` and compared with the committed JSON panel by panel — titles, query counts, expressions, template variables — and it is the fetched model's own expressions that are executed against Prometheus. Identity does not prove content: a dashboard loaded before a change to `dashboards-configmap.yaml` keeps its UID, its title and its folder, so `/api/search` cannot tell it apart from a current one, and executing the local manifest's expressions against it would report success over panels nobody had checked. A difference is reported as a diff:

```
Dashboard 'pulsestream-service-health' is loaded, but is not the committed dashboard...
  loaded dashboard 'pulsestream-service-health': panel 1 ('JVM Memory Used') query 1 is loaded as
  'sum(jvm_memory_used_bytes{service=~"$service"}) by (job, pod)', committed as
  'sum(jvm_memory_used_bytes{job=~"$job"}) by (job, pod)'
```

The applied ConfigMap is checked the same way, one step earlier, so the report separates the two kinds of stale: a difference there means `kubectl apply` was not re-run; a difference against the loaded model means it was, and Grafana has not picked it up (or the dashboard was overwritten through the UI). `scripts/tests/test-grafana-dashboard-provisioning.ps1` covers the comparison itself against synthetic stale models — no cluster needed.

**The query checks need traffic.** `Request Rate`, `Success vs Failure Count` and `Average Ingestion Latency` are all rates over `/api/v1/events`; with no requests in the window they correctly return nothing, and the script reports them as failures. Send some ingestion traffic first — see [`../../ingestion-service/README.md`](../../ingestion-service/README.md) for the NodePort address.

By hand:

```bash
kubectl port-forward -n monitoring svc/grafana 3000:80

# Read the admin credentials from wherever Grafana takes them (#155) rather
# than typing them into a shell that records its history.
GRAFANA_AUTH="admin:$(kubectl get secret grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)"

# The datasource resolves and Grafana can reach Prometheus through it.
curl -s -u "$GRAFANA_AUTH" http://localhost:3000/api/datasources/uid/prometheus/health

# Both dashboards are loaded.
curl -s -u "$GRAFANA_AUTH" "http://localhost:3000/api/search?type=dash-db"
```

Then open `http://localhost:3000` and look under `Dashboards > PulseStream`.

## The label contract these queries select on

The panels here select on the labels [`../prometheus-values.yaml`](../prometheus-values.yaml) (#154) actually produces:

| | Discovery | Identifies a workload | Also carries |
| --- | --- | --- | --- |
| Compose (`infrastructure/docker/prometheus/prometheus.yml`) | one static target per service | `job="ingestion-service"` | — |
| Kubernetes ([`../prometheus-values.yaml`](../prometheus-values.yaml)) | `role: pod`, one job per workload | `job="ingestion-service"` | `namespace`, `pod`, `node` |

`job` is the workload name in both, because #154 defines one scrape job per service rather than a single pod-discovery job. There is **no `service` label** in the cluster: that scrape config relabels three meta labels and that is not one of them. Selecting on a label Prometheus does not write is not an error — the panel draws an empty graph — so `scripts/tests/test-grafana-dashboard-provisioning.ps1` holds every expression here to the label set it reads out of `../prometheus-values.yaml`, and fails a query that names a job that file does not define.

### So why a separate set at all

Two differences remain, both consequences of pods being plural where a Compose container is singular: the per-pod panels in `Service Health` break their series out by `pod`, and the tags carry `kubernetes`. `ingestion-metrics.json` has no per-pod panel and is the Compose dashboard apart from that tag; it lives in the ConfigMap because Grafana in the cluster loads dashboards from a ConfigMap and cannot read `observability/grafana/dashboards/` off the host.

The same test holds the two sets to the same structure — same UIDs, titles, panel IDs, query counts — so a panel added to one and forgotten in the other fails without a cluster.

**Only the scraped jobs appear.** `ingestion-service` and `query-service` are scraped; `telemetry-processor` is not, because its actuator surface is bound to `127.0.0.1` on its management port and is unreachable over the pod network. It is therefore absent from the `job` variable in `Service Health`, and that is a property of the scrape config, not of these dashboards.

## Editing a dashboard

The ConfigMap is the source of truth, and `allowUiUpdates: false` makes Grafana say so rather than accepting a save it cannot write to a read-only volume.

1. Edit the panel in the UI and use `Export > Save to file` (leave **Export for sharing externally** off — it rewrites the datasource into a `${DS_...}` input and breaks the stable `prometheus` UID).
2. Paste the JSON back into `dashboards-configmap.yaml` under its existing key, indented to match.
3. Make the matching change in `observability/grafana/dashboards/`, dropping any `pod` breakdown (Compose has no `pod` label), or the structural test fails.
4. `kubectl apply -f infrastructure/kubernetes/monitoring/grafana/dashboards-configmap.yaml`.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Datasource prometheus was not found` on every panel | The datasource ConfigMap is not mounted, or Grafana was not restarted after it was applied. |
| Panels render but are empty, no error | The queries match nothing. Check the jobs Prometheus knows: `curl -s -u "$GRAFANA_AUTH" http://localhost:3000/api/datasources/uid/prometheus/resources/api/v1/label/job/values`. A list without `ingestion-service` means the scrape job in [`../prometheus-values.yaml`](../prometheus-values.yaml) has no targets — check `Status > Targets` in Prometheus. |
| A panel is empty but the same query works in the expression browser | The loaded dashboard is not the committed one. `./scripts/validate-grafana-kubernetes.ps1` diffs the served model against the ConfigMap and names the panel. |
| Datasource health says `dial tcp: lookup prometheus-server...` | Prometheus (#154) is not deployed, or is not in the `monitoring` namespace the URL names. |
| The `PulseStream` folder is empty | The dashboards ConfigMap is not mounted at the provider's `options.path`, or its keys are not named `*.json`. |
| A UI edit disappears after a minute | Expected. The provider re-reads the ConfigMap and overwrites; export the JSON and commit it instead. |
| Two copies of each dashboard | Both the chart's dashboard sidecar and `dashboard-provider-configmap.yaml` are active. Remove the provider ConfigMap. |
