# ingestion-service HPA runtime verification (#150)

`scripts/validate-ingestion-hpa.ps1` checks the HPA's *shape* — target, thresholds, replica range, behavior windows — and is deliberately load-independent. This document records the complementary evidence: the HPA applied to a real cluster, read a real CPU metric, scaled `ingestion-service` up under load, and returned to `minReplicas` once the load stopped.

## Run context

| Item | Value |
| --- | --- |
| Manifest commit | `4366d367` (`hpa.yaml` unmodified) |
| Cluster | kind, node `desktop-control-plane`, Kubernetes `v1.36.1`, single node |
| Namespace | `default` |
| Metrics | `metrics-server` `v0.9.0` (`--kubelet-insecure-tls`, required for kind's self-signed kubelet certificates) |
| Load | 3 in-cluster `curlimages/curl` pods, 16 concurrent loops each, `POST /api/v1/events` against the `ingestion-service` ClusterIP |

`metrics-server` must be healthy before any of this means anything. Without it the HPA reports `cpu: <unknown>/70%` and never scales:

```bash
kubectl top nodes
# NAME                    CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
# desktop-control-plane   327m         2%       5702Mi          73%
```

## 1. HPA applies and reports a known CPU target

```bash
kubectl apply -f infrastructure/kubernetes/ingestion-service/hpa.yaml
# horizontalpodautoscaler.autoscaling/ingestion-service created

kubectl get hpa ingestion-service
# NAME                REFERENCE                      TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
# ingestion-service   Deployment/ingestion-service   cpu: 1%/70%   2         6         2          100s
```

`cpu: 1%/70%` — a real current value against the documented 70% target, not `<unknown>`. At rest the two pods sit far below it:

```bash
kubectl top pods --selector=app.kubernetes.io/name=ingestion-service
# NAME                                 CPU(cores)   MEMORY(bytes)
# ingestion-service-7d4dc75498-c9cmn   4m           267Mi
# ingestion-service-7d4dc75498-kv74t   4m           321Mi
```

4m against a 250m request is the ~1% the HPA reports.

## 2. Replicas scale above 2 under load

With the load pods running, per-pod CPU saturates the 1-core limit and utilization passes the 70% target by a wide margin:

```bash
kubectl top pods --selector=app.kubernetes.io/name=ingestion-service
# NAME                                 CPU(cores)   MEMORY(bytes)
# ingestion-service-7d4dc75498-c9cmn   980m         386Mi
# ingestion-service-7d4dc75498-kv74t   1000m        373Mi
```

Sampled every 20s (`kubectl get hpa ingestion-service`, times UTC):

```text
17:17:30Z | cpu:  11%/70%   2  6  2 | pods=2    <- load starts
17:17:51Z | cpu: 396%/70%   2  6  4 | pods=4
17:18:11Z | cpu: 367%/70%   2  6  4 | pods=4
17:18:32Z | cpu: 373%/70%   2  6  4 | pods=4
17:18:52Z | cpu: 293%/70%   2  6  6 | pods=6    <- maxReplicas ceiling
17:19:34Z | cpu: 263%/70%   2  6  6 | pods=6
17:20:15Z | cpu: 248%/70%   2  6  6 | pods=6
```

The autoscaler's own account of the same two steps:

```bash
kubectl describe hpa ingestion-service
# Conditions:
#   AbleToScale     True    ReadyForNewScale  recommended size matches current size
#   ScalingActive   True    ValidMetricFound  the HPA was able to successfully calculate a replica count from cpu resource utilization (percentage of request)
#   ScalingLimited  True    TooManyReplicas   the desired replica count is more than the maximum replica count
# Events:
#   Normal  SuccessfulRescale  86s  horizontal-pod-autoscaler  New size: 4; reason: cpu resource utilization (percentage of request) above target
#   Normal  SuccessfulRescale  25s  horizontal-pod-autoscaler  New size: 6; reason: cpu resource utilization (percentage of request) above target
```

Two things to read out of this. The first step is 2 -> 4, not 2 -> 3: the `scaleUp` policy allows 2 pods or 100% per 60s, whichever is larger, and the zero-second stabilization window lets it act on the first sustained sample rather than waiting one out. The second is that `ScalingLimited/TooManyReplicas` is the ceiling working as designed — at ~300% utilization the raw recommendation exceeds 6, and `maxReplicas` holds it there so ingestion cannot out-produce the 3-partition topic (see [`docs/architecture/autoscaling-strategy.md`](../../../docs/architecture/autoscaling-strategy.md)).

Serving replicas under load:

```bash
kubectl get pods -l app.kubernetes.io/name=ingestion-service
# NAME                                 READY   STATUS    RESTARTS   AGE
# ingestion-service-7d4dc75498-c9cmn   1/1     Running   17         4d17h
# ingestion-service-7d4dc75498-kv74t   1/1     Running   17         4d17h
# ingestion-service-7d4dc75498-xvghk   1/1     Running   0          2m51s
# ingestion-service-7d4dc75498-zkcfn   1/1     Running   0          2m51s
```

### Single-node capacity caveat

On this one-node cluster the last two of the six replicas stayed `Pending` with `0/1 nodes are available: 1 Insufficient memory` — the node was at 93% of allocatable memory before the test, and each replica requests 512Mi. This is a property of the test cluster, not of the HPA: the autoscaler had already made its decision (`currentReplicas: 6`) and the scheduler could not place all of it. Freeing 1Gi let two more replicas start, giving the four `Running` pods above. Anything past that needs a larger node or a second one.

## 3. Replicas return to 2 after the load stops

Load removed at `17:20:46Z`. Utilization falls below target within the next metrics window, and the 300s `scaleDown` stabilization window then holds the replica count flat before any pod is removed:

```text
17:21:38Z | cpu: 247%/70%   2  6  6 | pods=6
17:21:58Z | cpu:  18%/70%   2  6  6 | pods=6    <- below target
17:22:19Z | cpu:   1%/70%   2  6  6 | pods=6
...                                             (~5 min flat: stabilization window)
17:26:46Z | cpu:   2%/70%   2  6  6 | pods=6
17:27:06Z | cpu:   2%/70%   2  6  5 | pods=5    <- first scale-down
17:28:08Z | cpu:   2%/70%   2  6  4 | pods=4
17:29:09Z | cpu:   1%/70%   2  6  3 | pods=3
17:30:10Z | cpu:   0%/70%   2  6  2 | pods=2    <- back at minReplicas
```

Roughly five minutes pass between the metric dropping below target (`17:21:58Z`) and the first pod being removed (`17:27:06Z`) — the configured `stabilizationWindowSeconds: 300`. The four steps that follow are one pod per ~60s, matching the `Pods: 1 / periodSeconds: 60` policy, and the descent stops at 2 rather than continuing.

Final state:

```bash
kubectl get hpa ingestion-service
# NAME                REFERENCE                      TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
# ingestion-service   Deployment/ingestion-service   cpu: 0%/70%   2         6         2          15m

kubectl describe hpa ingestion-service
# Conditions:
#   AbleToScale     True    ScaleDownStabilized  recent recommendations were higher than current one, applying the highest recent recommendation
#   ScalingActive   True    ValidMetricFound     the HPA was able to successfully calculate a replica count from cpu resource utilization (percentage of request)
#   ScalingLimited  True    TooFewReplicas       the desired replica count is less than the minimum replica count
# Events:
#   Normal  SuccessfulRescale  3m33s  horizontal-pod-autoscaler  New size: 5; reason: All metrics below target
#   Normal  SuccessfulRescale  2m30s  horizontal-pod-autoscaler  New size: 4; reason: All metrics below target
#   Normal  SuccessfulRescale  88s    horizontal-pod-autoscaler  New size: 3; reason: All metrics below target
#   Normal  SuccessfulRescale  27s    horizontal-pod-autoscaler  New size: 2; reason: All metrics below target
```

`ScalingLimited/TooFewReplicas` at idle is the `minReplicas: 2` floor: CPU alone would justify one replica, and the floor keeps the second one for rolling updates and node drains.

## Reproducing

1. Install `metrics-server`; on kind or Docker Desktop add `--kubelet-insecure-tls` to its container args, then confirm `kubectl top nodes` returns values.
2. `kubectl apply -f infrastructure/kubernetes/ingestion-service/` and confirm the HPA shows a percentage rather than `<unknown>`.
3. Drive `POST /api/v1/events` from inside the cluster with enough concurrency to push per-pod CPU past 175m (70% of the 250m request); a handful of `curl` loop pods is enough.
4. Watch with `kubectl get hpa ingestion-service --watch`.
5. Stop the load and keep watching for at least 300s + 4 minutes to observe the full return to `minReplicas`.

Structural assertions stay the responsibility of `scripts/validate-ingestion-hpa.ps1`; run it in the same cluster to confirm the applied object still matches the documented configuration.
