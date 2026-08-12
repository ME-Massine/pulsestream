# Custom metrics for autoscaling

The metrics pipeline that lets a HorizontalPodAutoscaler scale on something other than CPU (#152).

| File | Purpose |
| --- | --- |
| `prometheus-adapter-values.yaml` | Helm values for prometheus-adapter: the rules that translate HPA metric requests into PromQL. |
| `ingestion-service-hpa-custom-metrics.yaml` | The `ingestion-service` HPA scaling on request rate as well as CPU. An **alternative** to [`../ingestion-service/hpa.yaml`](../ingestion-service/hpa.yaml), not an addition. |

The HPA manifest lives here rather than beside the Deployment on purpose: it and `hpa.yaml` describe the same object two ways, so a wholesale `kubectl apply -f infrastructure/kubernetes/ingestion-service/` must not pick up both.

The design — which metric, why prometheus-adapter rather than KEDA, why consumer lag is specified but not applied — is in [`docs/architecture/custom-metrics-autoscaling.md`](../../../docs/architecture/custom-metrics-autoscaling.md). This file is the runbook.

## What this is not

This directory does **not** deploy Prometheus. The repository's Prometheus configuration today is Compose-only (`infrastructure/docker/prometheus/prometheus.yml`) and scrapes a static host target, which is useless to an in-cluster adapter. An in-cluster Prometheus is a prerequisite of this path, tracked with the wider metrics integration work (#154+).

Whatever installs it must satisfy two requirements, or the adapter cannot serve pod metrics:

- It scrapes `/actuator/prometheus` on the service pods (port `8081` for `ingestion-service`).
- The resulting series carry `namespace` and `pod` labels. Standard `kubernetes_sd_config` pod discovery with the usual relabeling produces both; a static target configuration does not, and the adapter has nothing to map the metric onto.

## Install

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace kube-system \
  --values infrastructure/kubernetes/autoscaling/prometheus-adapter-values.yaml
```

Set `prometheus.url` in the values file to the Service of the in-cluster Prometheus before installing. The default (`http://prometheus-server.monitoring.svc`) is the `prometheus-community/prometheus` chart's Service name in a `monitoring` namespace.

> Exactly one component in a cluster serves `custom.metrics.k8s.io`. If another adapter is already registered, this install takes the API over silently. Check first:
> ```bash
> kubectl get apiservices v1beta1.custom.metrics.k8s.io -o jsonpath='{.spec.service.name}{"\n"}'
> ```

## Verify before touching any HPA

```bash
# 1. The APIService is registered and Available.
kubectl get apiservices v1beta1.custom.metrics.k8s.io

# 2. The metric exists in the API.
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/http_requests_per_second" | jq .

# 3. It carries a real value for each pod, not an empty list.
```

An empty `items` list means the rule matched no series. The usual causes, in order of likelihood: Prometheus is not scraping the pods; the series lack `namespace`/`pod` labels; the counter name changed in a Spring Boot or Micrometer upgrade.

```bash
pwsh ./scripts/validate-custom-metrics-autoscaling.ps1
```

checks all of the above against a live cluster, plus that exactly one HPA targets the Deployment and that the applied HPA has the documented shape.

## Switch the HPA over

Both manifests describe the same HPA object, so this replaces the CPU-only spec in place — no delete, and no window in which the Deployment has no autoscaler:

```bash
kubectl apply -f infrastructure/kubernetes/autoscaling/ingestion-service-hpa-custom-metrics.yaml

kubectl get hpa ingestion-service
# NAME                REFERENCE                      TARGETS                      MINPODS   MAXPODS   REPLICAS
# ingestion-service   Deployment/ingestion-service   1%/70%, 3200m/50             2         6         2
```

Both targets must report real values. `<unknown>` for the rate metric means the adapter is not serving it; roll back rather than leaving the HPA in that state, because an unreadable metric sets `ScalingActive=False` and blocks scale-down while still allowing scale-up on CPU.

## Roll back

```bash
kubectl apply -f infrastructure/kubernetes/ingestion-service/hpa.yaml
```

The CPU-only HPA depends on nothing but `metrics-server`, so this restores autoscaling even with Prometheus and the adapter entirely down. Rollback is always available and is the correct first response to any problem with the custom metric.

The same property is a sharp edge in the other direction: re-applying the service directory as a whole reverts a switched-over cluster to CPU-only autoscaling, silently. Anything that applies `infrastructure/kubernetes/ingestion-service/` on a schedule undoes the switch every time it runs.

## Validation without a cluster

```bash
pwsh ./scripts/tests/test-custom-metrics-hpa-structure.ps1
```

Reads `ingestion-service-hpa-custom-metrics.yaml` and asserts the same shape the cluster validator asserts about the applied object — the metric name, the per-replica target, the replica bounds, and that CPU is still present as the fallback signal. No cluster, no `kubectl`, no network.
