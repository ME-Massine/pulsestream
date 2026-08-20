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

The script opens its own `kubectl port-forward` (pass `-GrafanaBaseUrl` to reuse one) and walks the three acceptance criteria in the order they fail: the ConfigMaps are applied, the datasource is provisioned and its health check reaches Prometheus, both dashboards are loaded in the `PulseStream` folder, and every expression committed in `dashboards-configmap.yaml` returns at least one series.

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

## Why these dashboards are not the Compose ones

The same Micrometer series are labelled differently by the two Prometheus deployments, so one dashboard cannot serve both:

| | Discovery | Selector that identifies a workload |
| --- | --- | --- |
| Compose (`infrastructure/docker/prometheus/prometheus.yml`) | one static job per service | `job="ingestion-service"` |
| Kubernetes ([`../configmap.yaml`](../configmap.yaml)) | pod discovery, one job for every pod | `service="ingestion-service"` |

In the cluster, `job` is the constant `kubernetes-pods` for every scraped pod, and the workload name is relabelled into `service`. A panel copied across unchanged does not error — it draws an empty graph. The dashboards here are the Compose dashboards with that selector swapped, plus a `pod` breakdown on the per-pod panels, since a Deployment has replicas where a Compose service has one container.

`scripts/tests/test-grafana-dashboard-provisioning.ps1` holds the two sets to the same structure — same UIDs, titles, panel IDs, query counts — so a panel added to one and forgotten in the other fails without a cluster.

**Only annotated pods appear.** `ingestion-service` and `query-service` are scraped; `telemetry-processor` is not, because its actuator surface is bound to `127.0.0.1` on its management port and is unreachable over the pod network. It is therefore absent from the `service` variable in `Service Health`, and that is a property of the scrape config, not of these dashboards.

## Editing a dashboard

The ConfigMap is the source of truth, and `allowUiUpdates: false` makes Grafana say so rather than accepting a save it cannot write to a read-only volume.

1. Edit the panel in the UI and use `Export > Save to file` (leave **Export for sharing externally** off — it rewrites the datasource into a `${DS_...}` input and breaks the stable `prometheus` UID).
2. Paste the JSON back into `dashboards-configmap.yaml` under its existing key, indented to match.
3. Make the matching change in `observability/grafana/dashboards/` with the Compose selector, or the structural test fails.
4. `kubectl apply -f infrastructure/kubernetes/monitoring/grafana/dashboards-configmap.yaml`.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Datasource prometheus was not found` on every panel | The datasource ConfigMap is not mounted, or Grafana was not restarted after it was applied. |
| Panels render but are empty, no error | The queries match nothing. Check the `service` label exists: `curl -s -u "$GRAFANA_AUTH" http://localhost:3000/api/datasources/uid/prometheus/resources/api/v1/label/service/values`. An empty list means the relabel rule in [`../configmap.yaml`](../configmap.yaml) is missing or no pod carries `prometheus.io/scrape`. |
| Datasource health says `dial tcp: lookup prometheus-server...` | Prometheus (#154) is not deployed, or is not in the `monitoring` namespace the URL names. |
| The `PulseStream` folder is empty | The dashboards ConfigMap is not mounted at the provider's `options.path`, or its keys are not named `*.json`. |
| A UI edit disappears after a minute | Expected. The provider re-reads the ConfigMap and overwrites; export the JSON and commit it instead. |
| Two copies of each dashboard | Both the chart's dashboard sidecar and `dashboard-provider-configmap.yaml` are active. Remove the provider ConfigMap. |
