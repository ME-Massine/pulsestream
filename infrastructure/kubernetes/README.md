# PulseStream — Kubernetes Deployment

Kubernetes manifests for running the full PulseStream platform in a cluster,
managed with [kustomize](https://kustomize.io) (built into `kubectl`). This
is the Kubernetes counterpart to the local
[docker-compose stack](../docker/docker-compose.yml) — the two are kept in
sync (same images, same env var contracts, same Kafka topics, same Postgres
schema, same Grafana dashboards).

## Prerequisites

- A Kubernetes cluster (`kind`, `minikube`, or any managed cluster) and
  `kubectl` configured against it.
- The [metrics-server](https://github.com/kubernetes-sigs/metrics-server)
  add-on installed, for the HorizontalPodAutoscalers to work. Most local
  clusters (`minikube addons enable metrics-server`, `kind` + a metrics-server
  manifest) need this enabled explicitly.
- An ingress controller (e.g. `ingress-nginx`) if you want to use the
  `Ingress` resource. Not required — see "Accessing the ingestion API" below.
- Docker, to build the two service images.

## Building the service images

```bash
docker build -t pulsestream/ingestion-service:latest services/ingestion-service
docker build -t pulsestream/telemetry-processor:latest services/telemetry-processor
```

Load them into your cluster's local image store (skip this if you're using a
remote registry — see "Using a real registry" below):

```bash
# kind
kind load docker-image pulsestream/ingestion-service:latest
kind load docker-image pulsestream/telemetry-processor:latest

# minikube
minikube image load pulsestream/ingestion-service:latest
minikube image load pulsestream/telemetry-processor:latest
```

## Deploying

```bash
kubectl apply -k infrastructure/kubernetes
```

This creates the `pulsestream` namespace and every resource in it. Startup
order is handled by each service's readiness probes; Kubernetes will retry
scheduling and connections rather than fail outright, but the pipeline isn't
usable until Postgres, Zookeeper, and Kafka report ready.

Kafka topics aren't auto-created (`KAFKA_AUTO_CREATE_TOPICS_ENABLE=false`, to
match the docker-compose setup). The `kafka-topics-init` Job creates them and
exits; check it if the pipeline seems stuck:

```bash
kubectl -n pulsestream logs job/kafka-topics-init
```

Watch rollout status:

```bash
kubectl -n pulsestream get pods -w
```

## Accessing the ingestion API

Two options are provided:

- **NodePort** (no ingress controller required): the `ingestion-service`
  Deployment is also exposed on `ingestion-service-nodeport`, port `30081` on
  every node. For `kind`/`minikube` this is the quickest path:
  ```bash
  curl http://$(minikube ip):30081/actuator/health
  ```
- **Ingress**: `networking/ingestion-ingress.yaml` routes host
  `pulsestream.local` to the service on port 8081, if `ingress-nginx` (or
  another controller honoring `ingressClassName: nginx`) is installed.

## Horizontal Pod Autoscaling

`ingestion-service` and `telemetry-processor` each ship a
`HorizontalPodAutoscaler` (CPU + memory utilization, via `metrics-server`).

Kafka-consumer-lag-based scaling for `telemetry-processor` needs an external
metrics source — vanilla HPA can't read consumer group lag. If you have
[KEDA](https://keda.sh) installed, apply
`telemetry-processor/keda-scaledobject.optional.yaml` instead of (not
alongside) `telemetry-processor/hpa.yaml`; it scales on lag against the
`telemetry.events.raw` topic.

## What's deployed

| Component | Kind | Notes |
| --- | --- | --- |
| `ingestion-service` | Deployment + HPA | 2 replicas by default |
| `telemetry-processor` | Deployment + HPA | 2 replicas by default |
| `postgres` | StatefulSet | 1 replica, PVC-backed, seeded via `postgres/init-configmap.yaml` |
| `redis` | Deployment | 1 replica, PVC-backed |
| `zookeeper` | StatefulSet | 1 replica, PVC-backed |
| `kafka` | StatefulSet | 1 broker, PVC-backed. See the comment in `kafka/kafka-statefulset.yaml` before scaling replicas |
| `kafka-topics-init` | Job | Creates the 4 telemetry topics, then exits |
| `prometheus` | Deployment | Scrapes annotated pods via Kubernetes service discovery |
| `grafana` | Deployment | Dashboards from `observability/grafana/dashboards/` provisioned via ConfigMap |
| `jaeger` | Deployment | All-in-one, OTLP receiver enabled — same as local compose |

All service-to-service communication (Kafka bootstrap, Postgres, Redis,
OTLP endpoints) uses in-cluster DNS (`<service>.pulsestream.svc.cluster.local`,
or just `<service>` from within the namespace) — no service needs to leave
the cluster to reach another.

## Using a real registry

The Deployments default to `pulsestream/<service>:latest` with
`imagePullPolicy: IfNotPresent`, which works for locally-loaded images. To
pull from a registry instead, either edit the `image:` fields directly or add
an `images:` transformer to `kustomization.yaml`, e.g.:

```yaml
images:
  - name: pulsestream/ingestion-service
    newName: ghcr.io/<org>/pulsestream-ingestion-service
    newTag: "1.0.0"
```

## Configuration and secrets

`secrets/postgres-secret.yaml` and `secrets/grafana-secret.yaml` ship with
the same development defaults as `infrastructure/docker/.env.example`. They
are **not safe for a shared or production cluster** — replace them with real
secret values, or manage them with a sealed-secrets / external-secrets
controller, before deploying anywhere but a local/disposable cluster.

## Tearing down

```bash
kubectl delete -k infrastructure/kubernetes
```

This deletes the namespace and everything in it, including PersistentVolumeClaims.
