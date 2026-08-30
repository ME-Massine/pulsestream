## Grafana Dashboards

Version-controlled `Grafana` dashboard definitions for the `PulseStream` platform.
These JSON files are the single source of truth for the platform's dashboards and
are committed to the repository so dashboard changes are reviewed and reproducible.

### Files

| Dashboard | UID | Description |
| :-------- | :-- | :---------- |
| `service-health.json` | `pulsestream-service-health` | JVM, uptime, and health signals across services |
| `ingestion-metrics.json` | `pulsestream-ingestion-metrics` | Request rate, success/failure, and latency for `ingestion-service` |

Each dashboard references the provisioned `Prometheus` datasource by its stable
`uid` (`prometheus`), so the JSON is portable across environments without
hard-coded datasource identifiers.

### How dashboards are loaded

The local `Docker Compose` platform provisions these dashboards automatically.
`infrastructure/docker/docker-compose.yml` mounts this directory into the
`Grafana` container at `/etc/grafana/dashboards`, and the file provider in
`infrastructure/docker/grafana/provisioning/dashboards/dashboards.yml` loads every
JSON file from that path into the `PulseStream` folder.

Start the platform and the dashboards appear under
`Dashboards > PulseStream` at `http://localhost:3000`:

```bash
cd infrastructure/docker
docker compose up -d
```

### In Kubernetes

These files are the `Docker Compose` set. The cluster loads its own copies from
`infrastructure/kubernetes/monitoring/grafana/dashboards-configmap.yaml`, because
`Grafana` in the cluster reads its dashboards from a `ConfigMap` and cannot mount
this directory off the host.

The selector is the same in both. Compose scrapes one static target per service
and the cluster (`infrastructure/kubernetes/monitoring/prometheus-values.yaml`)
defines one `role: pod` scrape job per service, so a workload is `job="ingestion-service"`
either way. What the cluster adds is `namespace`, `pod` and `node` on every series,
and the cluster copy of `service-health.json` uses `pod` to break the per-pod panels
out by replica — a `Compose` service has one container, so those panels stay summed
here.

Everything else is shared. Both sets keep the same UIDs, titles and panel IDs, and
`scripts/tests/test-grafana-dashboard-provisioning.ps1` fails if they drift, so a
panel added here needs the same panel added there.

### Re-importing a dashboard manually

Any dashboard here can be re-imported into a running `Grafana` without the
provisioning mount:

1. Open `Grafana` and go to `Dashboards > New > Import`.
2. Upload the JSON file (or paste its contents).
3. When prompted, select the `Prometheus` datasource (`uid: prometheus`).
4. Click `Import`.

### Exporting changes back to version control

After editing a dashboard in the `Grafana` UI, export the updated definition and
commit it here so the file stays the source of truth:

1. Open the dashboard and go to `Share > Export > Save to file`.
   Leave `Export for sharing externally` **disabled** — that option rewrites the
   datasource into a `${DS_...}` input variable, which breaks the stable
   `prometheus` UID these provisioned files rely on.
2. Replace the matching JSON file in this directory with the exported file.
3. Confirm the datasource still references `"uid": "prometheus"` (not a
   `${DS_...}` variable), then commit the change.
