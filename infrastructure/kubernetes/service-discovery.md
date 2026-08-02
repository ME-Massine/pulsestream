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
| `telemetry-processor` | `telemetry-processor` | 8082 | liveness/readiness probes (no HTTP callers today) |

`Service` manifests live next to each Deployment (`<service>/service.yaml`). The
selector matches the Deployment's `app.kubernetes.io/name` pod label, so the two
must stay in sync.

`telemetry-processor` exposes only its main application port 8082 through the
ClusterIP. The full actuator surface — including Prometheus metrics and the
state-changing DLQ replay endpoint — stays on the management port `9083`, bound
to loopback (`127.0.0.1`) and never selected by the Service (see
`services/telemetry-processor/src/main/resources/application.yml`). Only the
`/livez` and `/readyz` probe paths are mirrored onto 8082, so scraping metrics
through the Service DNS name is not possible.

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

Run these from the operator shell (`kubectl`), against the namespace the
workloads run in. A temporary debug Pod gives an unambiguous in-cluster vantage
point for DNS and HTTP checks; the EndpointSlice and readiness checks are read
straight from the API server.

```bash
# 1. DNS resolves for each Service, from an explicit in-cluster debug Pod.
#    --rm cleans the Pod up on exit; run one nslookup per Service name.
kubectl run disco-check --rm -it --restart=Never --image=curlimages/curl -- \
  sh -c 'for s in ingestion-service query-service telemetry-processor; do nslookup "$s"; done'

# 2. Each Service has ready backing endpoints. EndpointSlice replaces the
#    deprecated Endpoints resource; empty/NotReady = selector or probe problem.
kubectl get endpointslices -l kubernetes.io/service-name=ingestion-service
kubectl get endpointslices -l kubernetes.io/service-name=query-service
kubectl get endpointslices -l kubernetes.io/service-name=telemetry-processor

# 3. Readiness is reachable through each ClusterIP by DNS name.
kubectl run disco-check --rm -it --restart=Never --image=curlimages/curl -- sh -c '
  curl -sf http://ingestion-service:8081/readyz &&
  curl -sf http://query-service:8083/readyz &&
  curl -sf http://telemetry-processor:8082/readyz'

# 4. The effective runtime endpoints, read from a running Pod's environment
#    (envFrom values are captured at Pod start, so ConfigMaps alone are not proof).
kubectl exec deploy/ingestion-service   -- printenv PULSESTREAM_KAFKA_BOOTSTRAP_SERVERS
kubectl exec deploy/telemetry-processor -- printenv PULSESTREAM_KAFKA_BOOTSTRAP_SERVERS PULSESTREAM_POSTGRES_URL
```
