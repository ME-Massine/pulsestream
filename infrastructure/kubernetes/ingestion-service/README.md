# ingestion-service on Kubernetes

Manifests for the `PulseStream` REST ingest gateway, and the documented way to reach it from outside the cluster.

| File | Purpose |
| --- | --- |
| `deployment.yaml` | The workload: two replicas, probes, resource limits, pinned image tag. |
| `hpa.yaml` | `HorizontalPodAutoscaler` scaling the Deployment between 2 and 6 replicas on CPU utilization. |
| `hpa-runtime-verification.md` | Recorded cluster run of the HPA: scale-up under load and return to `minReplicas`. |
| `configmap.yaml` | Non-sensitive runtime configuration consumed via `envFrom`. |
| `service.yaml` | `ClusterIP` Service `ingestion-service` — the in-cluster DNS name other services call. |
| `service-nodeport.yaml` | `NodePort` Service `ingestion-service-external` — the external entry point. |

Apply the directory as a whole:

```bash
kubectl apply -f infrastructure/kubernetes/ingestion-service/
```

## Exposure method: NodePort

External clients reach the ingest API through the `NodePort` Service `ingestion-service-external`, on **port 30081 of any cluster node**:

```text
http://<node-ip>:30081/api/v1/events
```

The Service forwards `30081` on the node to the Service port `8081`, and from there to the container's named `http` port (`containerPort: 8081` in `deployment.yaml`). Both Services select the same pods, so an external client and an in-cluster caller hit the same two replicas.

The node port is pinned rather than left to Kubernetes to allocate from the `30000-32767` range. An allocated port changes whenever the Service is recreated, which would invalidate this document and the validation script on every re-apply.

### Why NodePort and not Ingress

An `Ingress` resource does nothing on its own — it is configuration for an ingress controller, and no controller is installed by this repository or by a stock `minikube`/`kind`/Docker Desktop cluster. Shipping an `Ingress` here would produce a manifest that applies cleanly and routes nothing, with no error to explain why.

`NodePort` has no such prerequisite: `kubectl apply` is the whole installation. The cost is that the address is a node IP and a high port rather than a hostname, and that host-based routing, TLS termination, and path rewriting are not available. When an ingress controller becomes part of the platform, `service-nodeport.yaml` is the file that gets replaced — the `ClusterIP` Service and the in-cluster name stay as they are.

### Finding the node address

The node IP depends on how the cluster runs:

```bash
# Any cluster: the address kubelet reports for each node.
kubectl get nodes -o wide

# minikube
minikube ip

# Docker Desktop / k3d / a single-node cluster on this machine
# The node port is published on the host, so localhost works.
```

`kind` is the exception: its nodes are containers on a private Docker network, so `30081` is not published on the host unless the cluster was created with a matching `extraPortMappings` entry. Without that, use a port-forward for local access:

```bash
kubectl port-forward service/ingestion-service-external 8081:8081
```

## Verifying external access

Send a request from outside the cluster. The readiness endpoint confirms reachability:

```bash
curl -i http://<node-ip>:30081/readyz
# HTTP/1.1 200 OK
```

Routing to the ingest endpoint is confirmed by posting an event:

```bash
curl -i -X POST http://<node-ip>:30081/api/v1/events \
  -H 'Content-Type: application/json' \
  -d '{
    "eventId": "evt_ext_probe",
    "tenantId": "factory_01",
    "eventType": "telemetry.reading",
    "timestamp": "2026-03-15T12:05:21Z",
    "source": "sensor_gateway",
    "version": "1.0",
    "payload": {
      "deviceId": "sensor_1042",
      "deviceType": "temperature-sensor",
      "metric": "temperature",
      "value": 28.4,
      "unit": "C",
      "location": "zone-a"
    }
  }'
# HTTP/1.1 202 Accepted
```

A `202` means the request reached `TelemetryController` and the event was published to Kafka. A `400` means the request was routed correctly but the body failed validation — also proof that routing works, without producing a record.

The scripted equivalent of both checks is:

```powershell
pwsh ./scripts/validate-ingestion-external-access.ps1
```

## Autoscaling

`hpa.yaml` applies a `HorizontalPodAutoscaler` targeting the `ingestion-service` Deployment: CPU utilization against the pod's `250m` request, a 70% target, and a 2-6 replica range. The full reasoning behind these numbers lives in [`docs/architecture/autoscaling-strategy.md`](../../../docs/architecture/autoscaling-strategy.md).

The HPA reads from the `metrics.k8s.io` API, so `metrics-server` must be installed and healthy in the cluster first, or the HPA reports `unknown` for its current metric and never scales:

```bash
kubectl top pods -l app.kubernetes.io/name=ingestion-service
```

Watch scaling behavior with:

```bash
kubectl get hpa ingestion-service --watch
```

A recorded run of that watch — the HPA reading a real CPU metric, scaling `ingestion-service` from 2 to 6 replicas under load, and returning to 2 after the load stops and the 300s stabilization window passes — is in [`hpa-runtime-verification.md`](hpa-runtime-verification.md).

### Scaling on request rate as well as CPU

[`../autoscaling/ingestion-service-hpa-custom-metrics.yaml`](../autoscaling/ingestion-service-hpa-custom-metrics.yaml) is an **alternative** to `hpa.yaml`: the same HPA object, with the same target, bounds and behavior windows, plus a second metric — request rate per replica, served from `custom.metrics.k8s.io` by prometheus-adapter (#152). Applying it replaces the CPU-only spec in place; applying this directory afterwards puts the CPU-only spec back.

It needs an in-cluster Prometheus and the adapter installed first; applying it without them leaves the HPA reporting `<unknown>` for the rate metric, which blocks scale-down. The install, verification and rollback steps are in [`../autoscaling/README.md`](../autoscaling/README.md), and the reasoning — including why CPU stays on the HPA and where the 50 rps/replica target comes from — is in [`docs/architecture/custom-metrics-autoscaling.md`](../../../docs/architecture/custom-metrics-autoscaling.md).

## Not configured here

Authentication, TLS termination, and rate limiting are out of scope for the exposure work (#145). Port `30081` serves plain HTTP and accepts any client that can route to a node, so it is an entry point for development and evaluation clusters, not for an untrusted network.
