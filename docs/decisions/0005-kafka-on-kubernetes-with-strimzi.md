# ADR 0005: Use the Strimzi operator to deploy Kafka on Kubernetes

## Status
Accepted

## Context

Phase 6 of the roadmap deploys PulseStream to Kubernetes. Service manifests for
`ingestion-service`, `telemetry-processor`, and `query-service` already exist under
`infrastructure/kubernetes/`. The two services that talk to Kafka —
`ingestion-service` and `telemetry-processor` — expect an in-cluster broker at
`kafka:9092` (see `PULSESTREAM_KAFKA_BOOTSTRAP_SERVERS` in their ConfigMaps;
`query-service` is a read API and consumes no broker config). Nothing currently
provides that broker.

Kafka is stateful, needs stable network identities and persistent volumes, and
needs safe rolling restarts on every config change. Writing raw StatefulSet
manifests for it by hand is not realistic for this project, so the cluster must
come from an existing packaging. Two options are in common use:

- **Bitnami Helm chart** (`bitnami/kafka`) — Kafka packaged as a Helm chart.
- **Strimzi operator** — a CNCF-incubating Kubernetes operator that manages
  Kafka through custom resources (`Kafka`, `KafkaTopic`, `KafkaUser`,
  `KafkaNodePool`).

The decision has been blocking implementation of the Kafka deployment issues.

The local Docker Compose stack (ADR 0004) runs a single ZooKeeper-backed
Confluent broker. That stack is unaffected by this decision; it is not the
target deployment model and is not migrated here.

## Decision

PulseStream will deploy Kafka on Kubernetes using the **Strimzi operator**.

Concretely:

- The Strimzi cluster operator is installed once per cluster, namespace-scoped
  to the PulseStream namespace.
- The broker cluster is declared as a `Kafka` custom resource in
  `infrastructure/kubernetes/kafka/`, alongside the existing service manifests.
- Topics are declared as `KafkaTopic` resources rather than created by an
  imperative script, replacing the role `scripts/create-topics.*` and
  `infrastructure/docker/kafka/init-topics.sh` play locally.
- The Kafka bootstrap Service produced by Strimzi is what the existing
  ConfigMaps point at. The generated name is
  `<cluster-name>-kafka-bootstrap:9092`, so either the cluster resource is named
  so the Service resolves to `kafka`, or the ConfigMap values are updated to the
  generated name. This is settled during implementation, not here.

## Rationale

- **Declarative, matches the repo.** Everything in `infrastructure/kubernetes/`
  is plain YAML applied with `kubectl`. Strimzi keeps Kafka and its topics in the
  same model, reviewable in the same diff. A Helm chart adds a second tooling
  model (values files, releases, templating) for one component.
- **Day-2 operations are the actual problem.** Rolling broker restarts in the
  correct order, partition-aware reconfiguration, certificate rotation, and
  cluster rebalancing are handled by the operator. The Helm chart installs Kafka;
  it does not operate it. Config changes on a chart-managed cluster are a
  `helm upgrade` and a hope.
- **Topics as resources.** `KafkaTopic` gives the four topics in ADR 0001 a
  reconciled, version-controlled definition instead of a shell script that must
  be run at the right moment against a ready broker.
- **Supply-chain risk on the Bitnami side.** In 2025 Bitnami moved its public
  image catalog: hardened/versioned images moved behind Bitnami Secure Images,
  and the free `docker.io/bitnami` tags were narrowed, with older tags relocated
  to `bitnamilegacy`. Pinning a Bitnami chart to a specific Kafka version is
  therefore less dependable than it was. Strimzi publishes its operator and
  Kafka images on Quay under its own project control.
- **Upstream alignment.** Strimzi is CNCF-incubating and tracks Kafka releases
  closely, including KRaft-mode clusters, which removes ZooKeeper from the
  Kubernetes deployment entirely.

## Consequences

### Positive

- Kafka lifecycle (restarts, scaling, config changes) is handled by the operator.
- Topics are declarative and reviewable, in the same place as the manifests.
- No Helm dependency introduced into the deployment path.
- No ZooKeeper in the Kubernetes deployment (KRaft).
- Same operator model works on kind/minikube and on a managed cluster.

### Negative

- A cluster-level prerequisite: CRDs and the operator must be installed before
  any PulseStream manifest applies. `kubectl apply -f infrastructure/kubernetes/`
  alone is no longer sufficient, and the ordering must be documented.
- Higher baseline resource usage than a bare single broker: the operator pod is
  an extra always-on workload, which matters on a laptop cluster.
- The team must learn Strimzi's CRD surface, which is broader than a chart's
  values file.
- Debugging moves one level up: a broken broker can be a broker problem or an
  operator reconciliation problem.
- Operator upgrades are their own maintenance task with their own ordering
  constraints against Kafka versions.

## Alternatives Considered

### Bitnami Helm chart (`bitnami/kafka`)

The fastest path to a running broker: one `helm install`, a values file, done.
Well documented and widely used.

Rejected because:

- it installs Kafka but does not operate it; day-2 changes are manual
- topic creation stays imperative, outside the manifest set
- it introduces Helm as a second deployment tool for a single component
- the 2025 Bitnami catalog change weakens the guarantee that pinned image tags
  remain publicly available

### Hand-written StatefulSet

Rejected because it means owning broker ordering, storage, listener
configuration, and rolling-restart safety by hand, with no upstream to inherit
fixes from. Highest effort and highest risk of the three.

### Managed Kafka (MSK, Confluent Cloud, Aiven)

Rejected for this project because it removes the Kubernetes deployment exercise
that Phase 6 exists to cover, requires a cloud account and ongoing cost, and
makes local cluster testing impossible. Remains a reasonable option if the
platform is ever operated for real.

### Keep the Compose broker and point Kubernetes services at it

Rejected: it defeats the purpose of the phase and leaves a single non-replicated
broker outside the orchestrator as a permanent single point of failure.

## Implementation Path

The chosen approach translates into the following work, tracked as separate
issues. None of it is performed by this ADR.

1. Install the Strimzi cluster operator into the PulseStream namespace, and
   document the ordering prerequisite in the Kubernetes deployment guide.
2. Add `infrastructure/kubernetes/kafka/kafka-cluster.yaml` — a `Kafka` resource
   in KRaft mode, with replica count, storage, and resource limits sized for the
   target environment.
3. Add `KafkaTopic` resources for the four topics defined in ADR 0001:
   `telemetry.events.raw`, `telemetry.events.processed`,
   `telemetry.events.anomalies`, `telemetry.events.dlq`.
4. Reconcile the bootstrap Service name with
   `PULSESTREAM_KAFKA_BOOTSTRAP_SERVERS` in the two ConfigMaps that define it
   (`ingestion-service`, `telemetry-processor`).
5. Broker metrics export and dashboards are handled separately under the
   observability work; they are out of scope for the deployment decision.

## Notes

This decision covers Kubernetes only. The local Docker Compose stack (ADR 0004)
keeps its current single Confluent broker; nothing in this ADR changes it.

The choice is reversible at moderate cost. `Kafka` and `KafkaTopic` resources are
Strimzi-specific, but the broker itself, the topic names, and the client
configuration are not — a move to a chart or to managed Kafka would rewrite the
infrastructure manifests, not the services.
