# Service discovery

How PulseStream workloads find each other inside the cluster (#144).

## Convention

Every workload that other components address has a `Service` named exactly after
the workload. Kubernetes DNS then resolves that name to the Service's stable
ClusterIP, which load-balances across the current pods:

- Same namespace: `<service-name>` (e.g. `query-service`)
- Cross-namespace: `<service-name>.<namespace>.svc.cluster.local`

Pods come and go with random IPs; the Service name is the stable address.
Callers use the name, never a pod IP.

## Platform services

| Service               | DNS name              | Port | Discovered by                          |
|-----------------------|-----------------------|------|----------------------------------------|
| `ingestion-service`   | `ingestion-service`   | 8081 | HTTP telemetry producers, health/metrics |
| `query-service`       | `query-service`       | 8083 | HTTP read clients, health/metrics      |
| `telemetry-processor` | `telemetry-processor` | 8082 | health/metrics (no HTTP callers today) |

`Service` manifests live next to each Deployment (`<service>/service.yaml`). The
selector matches the Deployment's `app.kubernetes.io/name` pod label, so the two
must stay in sync.

## Infrastructure dependencies

Inter-service communication is primarily asynchronous (see
`docs/architecture/services.md`), so the discovery that carries production
traffic is against infrastructure, not peer HTTP APIs. Both names are already
wired into the service ConfigMaps:

- **Kafka** — `pulsestream-kafka-bootstrap:9092`, the bootstrap Service the
  Strimzi operator generates from the `Kafka` resource named `pulsestream`
  (`kafka/kafka-cluster.yaml`). Renaming that resource renames this Service.
- **PostgreSQL** — `postgres:5432` (`telemetry-processor/configmap.yaml`). The
  DNS name is fixed here; provisioning the Postgres workload/Service itself is
  tracked separately.

## Verifying resolution

From any pod in the namespace:

```bash
# DNS record for a service
nslookup query-service

# reach a service's health endpoint by name
kubectl run disco-check --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sf http://query-service:8083/readyz

# confirm the Service has endpoints (empty = selector/label mismatch)
kubectl get endpoints query-service
```
