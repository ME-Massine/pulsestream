# Architecture Diagrams

This directory contains the core architecture diagrams for PulseStream.

Every diagram distinguishes implemented from planned components, using the status words defined in [`PROJECT_STATE.md`](../../PROJECT_STATE.md#how-to-read-status-in-this-repository). Solid edges are implemented; dashed edges are planned.

## Available Diagrams

- [System Architecture](./system-architecture.md) — components and their interactions
- [Event Flow](./event-flow.md) — the telemetry event lifecycle, including the failure and replay path
- [Kafka Topology](./kafka-topology.md) — topics, producers, consumers, and consumer groups
- [Kubernetes Deployment](./kubernetes-deployment.md) — the committed cluster deployment and what is still missing from it

## Purpose

These diagrams document the platform from multiple perspectives:

- high-level system structure
- telemetry event lifecycle, including dead-letter routing and replay
- Kafka topic and consumer relationships
- the Kubernetes deployment model

`system-architecture.png` is a rendered export of the system architecture diagram. The Mermaid source in `system-architecture.md` is the version kept current.
