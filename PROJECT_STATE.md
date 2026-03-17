# PulseStream — Project State

This document tracks the current engineering state of the PulseStream platform.

PulseStream is a cloud-native event processing platform designed for ingesting, streaming, processing, and analyzing IoT telemetry events.

---

# Current Phase

Phase 2 — Local Development Platform (in progress)

---

# Completed Work

## Repository Foundation

Completed initial repository setup and engineering workflow.

Includes:

- GitHub project board
- issue templates
- pull request template
- contribution guidelines
- MIT license
- CI baseline workflow

---

## Architecture Design

The core architecture of PulseStream has been defined and documented.

Architecture artifacts include:

- platform overview
- service boundaries
- event schema
- system architecture diagrams
- C4 architecture model

Documentation located in:

* [Architecture Docs](docs/architecture/)
* [Diagrams](docs/diagrams/)
* [Platform Overview](docs/platform-overview.md)
* [Roadmap](docs/roadmap.md)

---

## Architecture Decision Records

Key architectural decisions are documented as ADRs.

Current ADRs include:

- ADR 0001 — Use Apache Kafka as the event streaming backbone
- ADR 0002 — Use Spring Boot for platform services
- ADR 0003 — Use PostgreSQL as the primary persistence layer
- ADR 0004 — Use Docker Compose for local development before Kubernetes

Location:
* [Decisions](docs/decisions/)

---

# Current Work

## Phase 2 — Local Development Platform

The goal of this phase is to create a reproducible local platform environment that allows developers to run the PulseStream infrastructure locally.

This environment will include:

- Kafka broker
- Zookeeper
- PostgreSQL
- Redis
- Prometheus
- Grafana

Deliverable:
* [Docker](infrastructure/docker/docker-compose.yml)

Once complete, the entire infrastructure stack should start using:

```bash
docker compose up -d
```


---

# Upcoming Phases

## Phase 3 — Core Event Pipeline

Implementation of the core streaming pipeline.

Planned components:

- ingestion service
- telemetry API
- Kafka producer integration
- telemetry processor
- persistence of processed events

---

## Phase 4 — Observability

Introduce full monitoring and tracing.

Includes:

- Prometheus metrics
- Grafana dashboards
- distributed tracing
- service health monitoring

---

## Phase 5 — Reliability and Resilience

Improve platform fault tolerance.

Includes:

- dead-letter queues
- event replay capability
- retry mechanisms
- failure isolation

---

## Phase 6 — Kubernetes Deployment

Deploy the platform to a Kubernetes environment.

Includes:

- Kubernetes manifests
- service deployments
- Kafka cluster deployment
- observability stack deployment

---

# Repository Structure

```
docs/
├─ architecture/
├─ diagrams/
├─ decisions/
├─ platform-overview.md
└─ roadmap.md

infrastructure/
└─ docker/
```


---

# Next Immediate Task

Complete Issue #7:

Create the base Docker Compose platform environment.

Branch:
`infra/docker-compose-platform`

Deliverables:
```
infrastructure/docker/docker-compose.yml
infrastructure/docker/.env.example
infrastructure/docker/prometheus/prometheus.yml
```


---

# Long-Term Vision

PulseStream aims to demonstrate modern distributed systems architecture including:

- event-driven microservices
- scalable streaming pipelines
- cloud-native deployment patterns
- production-grade observability
- resilient event processing

The project serves both as a learning platform and as a reference implementation of a modern event streaming system.