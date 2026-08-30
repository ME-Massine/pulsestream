# Architecture Diagrams

This directory contains the core architecture diagrams for PulseStream.

Every diagram here describes the platform **as it is built**, and marks planned elements explicitly — dotted edges and labelled boxes, with the tracking issue. [PROJECT_STATE.md](../../PROJECT_STATE.md) is the authoritative source for status.

## Available Diagrams

- [System Architecture](./system-architecture.md) — components, topics and the failure/replay paths
- [Event Flow](./event-flow.md) — the lifecycle of one telemetry event, including dead-lettering and replay
- [Kafka Topology](./kafka-topology.md) — topic producers, consumers and durability settings
- [Kubernetes Deployment](./kubernetes-deployment.md) — the deployed cluster topology and its prerequisites

## Purpose

These diagrams document the platform from multiple perspectives:

- high-level system structure
- telemetry event lifecycle, including failure and replay
- Kafka topic and consumer relationships
- the Kubernetes deployment model
