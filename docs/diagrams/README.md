# Architecture Diagrams

This directory contains the core architecture diagrams for PulseStream.

Every diagram distinguishes implemented paths (solid edges) from paths that do not exist yet (dashed edges), and links the issue tracking each gap. [`PROJECT_STATE.md`](../../PROJECT_STATE.md) is the authoritative record of what is implemented, validated, and planned.

## Available Diagrams

- [System Architecture](./system-architecture.md) — components and the paths between them
- [Event Flow](./event-flow.md) — the lifecycle of a telemetry event, including the dead-letter and replay paths
- [Kafka Topology](./kafka-topology.md) — topics, producers, and consumers
- [Kubernetes Deployment](./kubernetes-deployment.md) — the deployed cluster topology

## Purpose

These diagrams document the platform from multiple perspectives:

- high-level system structure
- telemetry event lifecycle, including failure and recovery
- Kafka topic and consumer relationships
- the Kubernetes deployment model as it is deployed by the committed manifests
