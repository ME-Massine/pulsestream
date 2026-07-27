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
| `../../../scripts/validate-kafka-kubernetes.ps1` | Validates the operator-managed cluster: reconciliation, health, and internal connectivity |

## Broker count

Three brokers, set as `spec.replicas` in `kafka-node-pool.yaml`. That is the smallest count that supports a replication factor of 3 with `min.insync.replicas=2`, so the cluster keeps accepting writes while exactly one broker is down (rolling restart, node drain, single failure). It is also the smallest odd number giving the KRaft controller quorum a real majority.

Changing the count is a single-value edit. The operator derives the node identities and the quorum voter list from it — unlike the raw-manifest approach, there is no second copy of the count to keep in sync.

## Internal connectivity

The operator creates the `Services`; this repository does not declare them.

- **`pulsestream-kafka-bootstrap:9092`** — the bootstrap address clients connect to. The name is generated as `<kafka-cluster-name>-kafka-bootstrap` from the `Kafka` resource named `pulsestream`.
- **`pulsestream-kafka-brokers`** — headless, giving each broker its own DNS name for the per-broker addressing clients are redirected to after bootstrapping, and for the KRaft quorum.

Because Strimzi always suffixes the generated name, no cluster name produces a plain `kafka` Service. ADR 0005 left this open ("either the cluster resource is named so the Service resolves to `kafka`, or the ConfigMap values are updated"); the second option is the one that exists, so `PULSESTREAM_KAFKA_BOOTSTRAP_SERVERS` was updated from `kafka:9092` to `pulsestream-kafka-bootstrap:9092` in the two service `ConfigMaps` that define it:

- `infrastructure/kubernetes/ingestion-service/configmap.yaml`
- `infrastructure/kubernetes/telemetry-processor/configmap.yaml`

(`query-service` is a read API and consumes no broker config.) Renaming the `Kafka` resource renames the Service and breaks both, which is why the coupling is called out in all three files. The validation script asserts the deployed Service name and the `ConfigMap` values still agree.

The listener is internal and plaintext, on the pod network only. No external listener is defined, and TLS and authentication are not configured — exposure and security hardening are outside this issue.

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

The cluster comes up with no topics. `auto.create.topics.enable` is `false`, so nothing is created implicitly by a connecting producer either — provisioning the platform topics is [#141](https://github.com/ME-Massine/pulsestream/issues/141).

## Validate

Run the validation script from the repository root against the current `kubectl` context:

```powershell
.\scripts\validate-kafka-kubernetes.ps1
```

It checks that:

- the Strimzi CRDs and cluster operator are installed in the namespace — the prerequisite this deployment depends on
- the `Kafka` resource reports `Ready`, i.e. the operator itself considers the cluster reconciled, at the expected Kafka and metadata versions
- the node pool is configured for the expected node count, in combined `broker,controller` mode
- the broker pods are owned by a `StrimziPodSet` — the cluster is operator-managed rather than driven by a hand-written `StatefulSet`, as ADR 0005 requires
- every broker pod is `Ready` and started cleanly, with no container restarts
- the generated bootstrap `Service` is a `ClusterIP` on `9092` **and its name matches `PULSESTREAM_KAFKA_BOOTSTRAP_SERVERS` in the two service `ConfigMaps`** — the reconciliation this PR performs, asserted rather than assumed
- **a separate client pod can reach the cluster through the bootstrap Service** and receives metadata advertising all brokers as *one* cluster — the client runs outside the broker pods on purpose, since a check run inside one would pass even with the Services broken
- each broker advertises its own stable per-broker DNS name rather than the bootstrap address or a raw pod IP
- the KRaft quorum has elected a controller leader and every broker is a voter — asked of the controller rather than by creating a probe topic, since topic provisioning is out of scope

Override `-Namespace`, `-KafkaClusterName`, `-NodePoolName`, `-ExpectedBrokerCount`, or `-ClientImage` if you changed the defaults.

## Not covered here

Each has its own issue:

- **Persistent storage ([#140](https://github.com/ME-Massine/pulsestream/issues/140))** — the node pool uses `ephemeral` JBOD storage, so a rescheduled pod starts empty and refills from its replicas. This is the main reason the current manifests are not production-ready; the fix is a `persistent-claim` volume in `kafka-node-pool.yaml`.
- **Topic provisioning ([#141](https://github.com/ME-Massine/pulsestream/issues/141))** — no `KafkaTopic` resources and no Topic Operator. ADR 0005 puts the platform topics under the operator as `KafkaTopic` resources; that lands with its own issue, on top of this cluster.
- **Topic-level access control** — no `KafkaUser` resources and no `userOperator`, because the listener is plaintext with no authentication. Securing the listener is not covered by any of the issues in this phase.
- **Observability integration ([#154](https://github.com/ME-Massine/pulsestream/issues/154) onwards)** — no `metricsConfig`, exporter, or scrape configuration.
- **Disaster recovery** — no backup, restore, or multi-zone topology.
