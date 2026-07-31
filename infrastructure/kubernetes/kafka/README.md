# Kafka on Kubernetes

In-cluster Kafka broker cluster for the `PulseStream` platform.

## Deployment approach

Kafka is deployed with the **Strimzi operator**, running the brokers in **KRaft mode** (no `Zookeeper`). This follows [ADR 0005](../../../docs/decisions/0005-kafka-on-kubernetes-with-strimzi.md), which selected Strimzi and explicitly rejected a hand-written `StatefulSet` and the `bitnami/kafka` `Helm` chart.

What that means concretely for this directory:

- **The manifests describe the cluster, not the workload.** `Kafka` and `KafkaNodePool` are custom resources. The operator reconciles them into the pods, per-broker configuration, listener certificates, and `Services`. Nothing here owns broker ordering, quorum voter lists, advertised listeners, or rolling-restart safety — those were the reasons ADR 0005 rejected raw manifests.
- **KRaft** — brokers form their own metadata quorum, so no `Zookeeper` is deployed. Each node runs both the `broker` and `controller` roles, which makes a three-node pool a complete cluster on its own.
- **Day-2 changes go through the operator.** Editing broker config or the node count is an edit to these files followed by `kubectl apply`; the operator performs the safe rolling restart.

## Prerequisite: the Strimzi cluster operator

This is a real ordering constraint, not a nicety: the `Kafka` and `KafkaNodePool` kinds do not exist until the operator's CRDs are installed, and `kubectl apply -f infrastructure/kubernetes/kafka/` fails with `no matches for kind "Kafka"` without them.

Install the operator **once per cluster**, into the namespace PulseStream is deployed to (`default` below, matching the rest of `infrastructure/kubernetes/`):

```bash
curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/download/1.1.0/strimzi-cluster-operator-1.1.0.yaml \
  | sed 's/namespace: .*/namespace: default/' \
  | kubectl apply -n default -f -
```

The version is pinned deliberately. Strimzi also publishes an unpinned bundle that substitutes the namespace for you — convenient, but it tracks the latest release, so the operator version can change under an existing cluster:

```bash
kubectl create -f 'https://strimzi.io/install/latest?namespace=default' -n default
```

The installed operator is namespace-scoped: it watches only the namespace it was installed into. Deploying PulseStream into a different namespace means installing an operator for that namespace too.

Wait for it before applying anything else:

```bash
kubectl wait --for=condition=Available deployment/strimzi-cluster-operator -n default --timeout=300s
```

Version pairing matters on upgrade: the operator version determines which Kafka versions are supported, so bump the operator first and `spec.kafka.version` in `kafka-cluster.yaml` after — never the reverse.

## Files

| File | Purpose |
| :--- | :------ |
| `kafka-cluster.yaml` | The `Kafka` resource — cluster-wide broker config, the internal listener, and the pinned Kafka version |
| `kafka-node-pool.yaml` | The `KafkaNodePool` resource — how many nodes, which roles, storage, and resources |
| `topics.yaml` | The four platform topics as `KafkaTopic` resources, reconciled by the Topic Operator |
| `../../../scripts/validate-kafka-kubernetes.ps1` | Validates the operator-managed cluster: reconciliation, health, and internal connectivity |

## Broker count

Three brokers, set as `spec.replicas` in `kafka-node-pool.yaml`. That is the smallest count that supports a replication factor of 3 with `min.insync.replicas=2`, so the cluster keeps accepting writes while exactly one broker is down (rolling restart, node drain, single failure). It is also the smallest odd number giving the KRaft controller quorum a real majority.

Changing the count is a single-value edit. The operator derives the node identities and the quorum voter list from it — unlike the raw-manifest approach, there is no second copy of the count to keep in sync.

## Storage

Broker data is **persistent**. The node pool declares a single `persistent-claim` JBOD volume (`spec.storage` in `kafka-node-pool.yaml`), so the operator provisions one `PersistentVolumeClaim` per broker and mounts it at the broker's log dir. A pod that is restarted or rescheduled re-attaches its own PVC and comes back with its data intact, instead of starting empty and refilling from its replicas — the behaviour the previous `ephemeral` volume had.

- **Size** — `20Gi` per broker. `log.retention.bytes` caps each partition replica at 1Gi, and with replication factor 3 across 3 brokers every broker holds a replica of every partition; the four platform topics (ADR 0001) are 10 partitions, ~10Gi of topic data, and the rest is headroom for segment rollover, the KRaft metadata log, and Kafka's internal topics.
- **StorageClass** — unset, so the cluster's **default** `StorageClass` is used. This keeps the manifest portable across Docker Desktop, kind, minikube, and managed clusters. Set `storageClassName` on the volume if a specific class is required.
- **PVC lifecycle** — `deleteClaim: false`: deleting the node pool or the `Kafka` resource leaves the PVCs in place, so `kubectl delete` is not a data-loss event. The PVCs must then be removed by hand (`kubectl delete pvc -l strimzi.io/cluster=pulsestream`) to reclaim the storage.

The persistence claim is verifiable: the validation script asserts each broker has a Bound PVC, and a broker pod can be restarted to confirm it re-attaches the same volume rather than starting empty. See **Validate** below.

## Internal connectivity

The operator creates the `Services`; this repository does not declare them.

- **`pulsestream-kafka-bootstrap:9092`** — the bootstrap address clients connect to. The name is generated as `<kafka-cluster-name>-kafka-bootstrap` from the `Kafka` resource named `pulsestream`.
- **`pulsestream-kafka-brokers`** — headless, giving each broker its own DNS name for the per-broker addressing clients are redirected to after bootstrapping, and for the KRaft quorum.

Because Strimzi always suffixes the generated name, no cluster name produces a plain `kafka` Service. ADR 0005 left this open ("either the cluster resource is named so the Service resolves to `kafka`, or the ConfigMap values are updated"); the second option is the one that exists, so `PULSESTREAM_KAFKA_BOOTSTRAP_SERVERS` was updated from `kafka:9092` to `pulsestream-kafka-bootstrap:9092` in the two service `ConfigMaps` that define it:

- `infrastructure/kubernetes/ingestion-service/configmap.yaml`
- `infrastructure/kubernetes/telemetry-processor/configmap.yaml`

(`query-service` is a read API and consumes no broker config.) Renaming the `Kafka` resource renames the Service and breaks both, which is why the coupling is called out in all three files. The validation script asserts the deployed Service name and the `ConfigMap` values still agree.

The listener is internal and plaintext, on the pod network only. No external listener is defined, and TLS and authentication are not configured — exposure and security hardening are outside this issue.

## Topics

The four platform topics (ADR 0001) are declared in `topics.yaml` as `KafkaTopic` resources and reconciled onto the cluster by the **Topic Operator** (`spec.entityOperator.topicOperator` in `kafka-cluster.yaml`). They are not created by a script against a ready broker; the operator drives the cluster to the declared state, so re-applying is idempotent and topic creation is reproducible.

Names, partitions, and retention match [docs/architecture/topics.md](../../../docs/architecture/topics.md) and the local Compose provisioning (`infrastructure/docker/kafka/init-topics.sh`).

| Topic | Partitions | Replicas | Retention |
| :--- | :--- | :--- | :--- |
| `telemetry.events.raw` | 3 | 3 | 24h |
| `telemetry.events.processed` | 3 | 3 | 7d |
| `telemetry.events.anomalies` | 3 | 3 | 7d |
| `telemetry.events.dlq` | 1 | 3 | 7d |

Replication is **3**, not the Compose value of 1. This cluster's default `min.insync.replicas` is 2 (`kafka-cluster.yaml`), so a single-replica topic would reject `acks=all` writes with `NotEnoughReplicas`; RF 3 across the three brokers is also what the node-pool storage is sized for. The 10 partitions here are the same 10 the storage sizing assumes.

Applied with the cluster (`kubectl apply -f infrastructure/kubernetes/kafka/`). The Topic Operator provisions them once it is `Ready`:

```bash
kubectl get kafkatopics -l strimzi.io/cluster=pulsestream
```

Each should report `Ready`; the topic names carry dots, which are valid in both Kafka topic names and Kubernetes resource names.

## Deploy

Order matters; the operator must be running first (see the prerequisite above).

```bash
kubectl apply -f infrastructure/kubernetes/kafka/
```

The operator then creates the pods. `kubectl apply` returns as soon as the custom resources are accepted, so wait on the cluster itself rather than on the command:

```bash
kubectl wait kafka/pulsestream --for=condition=Ready --timeout=600s
kubectl get pods -l strimzi.io/cluster=pulsestream
```

A cold start typically takes two to three minutes, most of which is pulling the Kafka image.

`kubectl apply -f infrastructure/kubernetes/kafka/` applies `topics.yaml` alongside the cluster, so the Topic Operator provisions the four platform topics once it is running. `auto.create.topics.enable` is `false`, so topics are created only from those `KafkaTopic` resources, never implicitly by a connecting producer. See **Topics** above.

### Migrating a cluster already deployed from #139

The `kubectl apply` above assumes the cluster does not exist yet. **Strimzi does not allow a volume's storage `type` to change in place**, so applying this manifest over a cluster still running the earlier `ephemeral` volume from [#139](https://github.com/ME-Massine/pulsestream/issues/139) does *not* convert it to persistent storage — the operator keeps the existing type and logs a warning, and the brokers stay ephemeral.

Converting that cluster is a delete/recreate, which is **destructive**: on `ephemeral` volumes the broker data lives inside the pod, so `kubectl delete` erases every topic's contents. Since [#141](https://github.com/ME-Massine/pulsestream/issues/141) the same `kubectl apply` also provisions the four platform topics via the Topic Operator, so a cluster applied since then *does* hold platform topics and may hold data a producer wrote to them. "No platform data" is a precondition to **verify**, not assume:

1. Stop the producers so nothing writes during the migration:

   ```bash
   kubectl scale deployment/ingestion-service deployment/telemetry-processor --replicas=0
   ```

2. Check whether the platform topics already hold data:

   ```bash
   for t in telemetry.events.raw telemetry.events.processed telemetry.events.anomalies telemetry.events.dlq; do
     kubectl exec pulsestream-dual-role-0 -- /opt/kafka/bin/kafka-get-offsets.sh \
       --bootstrap-server localhost:9092 --topic "$t"
   done
   ```

   Every offset `0` (or the topics absent) means there is nothing to preserve — proceed. **If any offset is non-zero, do not delete** — the delete would lose that data. Preserve it first (drain the topics to another sink, or use the in-place JBOD route below), or accept the loss explicitly before continuing.

3. With the precondition verified, delete and recreate:

   ```bash
   kubectl delete -f infrastructure/kubernetes/kafka/   # tears down the ephemeral #139 cluster
   kubectl apply  -f infrastructure/kubernetes/kafka/   # recreates it with persistent-claim storage
   kubectl wait kafka/pulsestream --for=condition=Ready --timeout=600s
   ```

4. Scale the producers back up:

   ```bash
   kubectl scale deployment/ingestion-service deployment/telemetry-processor --replicas=1
   ```

(Strimzi's supported *in-place* route — add a second JBOD volume with a new id, let the operator reassign data onto it, then remove the old volume — is for when data must be kept. It is unnecessary here, and would in any case not apply to the ephemeral→persistent switch, which changes the existing volume's type rather than adding one.)

## Validate

Run the validation script from the repository root against the current `kubectl` context:

```powershell
.\scripts\validate-kafka-kubernetes.ps1
```

It checks that:

- the Strimzi CRDs and cluster operator are installed in the namespace — the prerequisite this deployment depends on
- the `Kafka` resource reports `Ready`, i.e. the operator itself considers the cluster reconciled, at the expected Kafka and metadata versions
- the node pool is configured for the expected node count, in combined `broker,controller` mode
- the node pool uses `persistent-claim` storage at the expected size, and every broker has a **Bound** `PersistentVolumeClaim` — the persistence this issue adds, so a restart re-attaches the same data instead of starting empty
- the broker pods are owned by a `StrimziPodSet` — the cluster is operator-managed rather than driven by a hand-written `StatefulSet`, as ADR 0005 requires
- every broker pod is `Ready`, and each broker's restart count stays **stable** across the run with no pod replaced — the script does not require a lifetime-zero restart count, since `restartCount` persists for the pod's lifetime and a past node reboot would otherwise fail every long-running cluster; a pre-existing count is reported as a warning, and only a restart or reschedule *during* the run fails the check
- the generated bootstrap `Service` is a `ClusterIP` on `9092` **and its name matches `PULSESTREAM_KAFKA_BOOTSTRAP_SERVERS` in the two service `ConfigMaps`** — the reconciliation this PR performs, asserted rather than assumed
- **a separate client pod can reach the cluster through the bootstrap Service** and receives metadata advertising all brokers as *one* cluster — the client runs outside the broker pods on purpose, since a check run inside one would pass even with the Services broken
- each broker advertises its own stable per-broker DNS name rather than the bootstrap address or a raw pod IP
- the KRaft quorum has elected a controller leader and every broker is a voter — asked of the controller directly rather than inferred from creating a probe topic

Override `-Namespace`, `-KafkaClusterName`, `-NodePoolName`, `-ExpectedBrokerCount`, `-ExpectedStorageSize`, or `-ClientImage` if you changed the defaults.

### Persistence across a restart (data-level)

The checks above prove the storage is provisioned and Bound. The acceptance criterion is stronger — **data written before a restart is still readable afterwards** — so it is verified by an actual write/restart/read cycle. Pass `-IncludePersistenceTest` to run it as part of the validation script:

```powershell
.\scripts\validate-kafka-kubernetes.ps1 -IncludePersistenceTest
```

The test is deliberately built so replication cannot mask the result:

1. Create a throwaway topic with **replication factor 1**, so its single partition lives on exactly one broker's disk and there is no replica to refill from. This is what distinguishes disk persistence from the replication-driven recovery that would pass even on `ephemeral` storage. The topic also sets `min.insync.replicas=1`, overriding the cluster default of 2 — otherwise an `acks=all` write (the Kafka 4.3 default) to a single-replica topic is rejected with `NotEnoughReplicas`.
2. Produce a unique marker record and note which broker leads the partition.
3. **Delete that leader broker's pod** and wait for the operator to reschedule it onto its existing PVC and report it `Ready` again.
4. Consume the topic from the beginning through the bootstrap Service and assert the marker record is still there.
5. Delete the throwaway topic.

The topic is a test probe created and removed by the script, not one of the platform topics (those are provisioned by the Topic Operator from `topics.yaml`; `auto.create.topics.enable` stays `false`).

To run the same cycle by hand — note the second command deletes the pod and waits on **that specific pod**, not on the already-`Ready` `Kafka` resource, which would return immediately:

```bash
BROKER=0   # any existing broker id; the topic is pinned to it below
# Create the probe topic with its single replica ON $BROKER, via an explicit
# replica assignment ("partition 0 -> [broker $BROKER]"), so the broker restarted
# below is guaranteed to be the one holding the data. min.insync.replicas=1
# overrides the cluster default of 2 so the acks=all write is accepted.
kubectl exec pulsestream-dual-role-$BROKER -- bash -c \
  "/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --topic persistence-check --replica-assignment $BROKER --config min.insync.replicas=1 && \
   echo 'marker-42' | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic persistence-check"
# restart the broker that holds the data and wait for the same pod to come back
kubectl delete pod pulsestream-dual-role-$BROKER
kubectl wait pod/pulsestream-dual-role-$BROKER --for=condition=Ready --timeout=300s
# the marker must still be readable after the restart
kubectl exec pulsestream-dual-role-$BROKER -- bash -c \
  "/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic persistence-check --from-beginning --timeout-ms 15000"
kubectl exec pulsestream-dual-role-$BROKER -- bash -c \
  "/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --delete --topic persistence-check"
```

With the previous `ephemeral` volume the deleted pod came back with an empty log dir, so an RF=1 topic's data was lost. With `persistent-claim` storage the pod re-attaches the same PVC and the marker survives.

## Not covered here

Each has its own issue:

- **Topic-level access control** — no `KafkaUser` resources and no `userOperator`, because the listener is plaintext with no authentication. Securing the listener is not covered by any of the issues in this phase.
- **Observability integration ([#154](https://github.com/ME-Massine/pulsestream/issues/154) onwards)** — no `metricsConfig`, exporter, or scrape configuration.
- **Disaster recovery** — no backup, restore, or multi-zone topology.
