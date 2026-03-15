# ADR 0004: Use Docker Compose for local platform delivery before Kubernetes

## Status
Accepted

## Context

PulseStream is intended to become a cloud-native platform deployed on Kubernetes.
However, the team needs a practical local development environment that supports:

- rapid iteration
- low setup overhead
- local testing of the event pipeline
- reproducible onboarding for all contributors

The project includes multiple components:

- Kafka
- PostgreSQL
- Redis
- observability tools
- backend services

Introducing Kubernetes as the first implementation environment would increase the learning and operational burden before the platform basics are working.

## Decision

PulseStream will use **Docker Compose** as the first local platform environment.

Docker Compose will be used to:

- run the local development stack
- validate service integration
- support early implementation phases
- simplify contributor onboarding

Kubernetes remains the target deployment model and is already planned as a later dedicated project phase.

## Consequences

### Positive

- Faster local setup
- Lower cognitive overhead for the first implementation phases
- Easier debugging during early development
- Better fit for the MVP lifecycle
- Keeps the team focused on service behavior before orchestration complexity

### Negative

- Local runtime differs from target orchestration environment
- Some Kubernetes-specific concerns are deferred
- Compose does not model full cloud-native orchestration behavior

## Alternatives Considered

### Start directly with Kubernetes

Rejected because:

- too much infrastructure complexity for the first implementation phase
- slows delivery of the MVP
- makes local debugging harder
- introduces orchestration concerns before the platform behavior is validated

### Run services manually without Compose

Rejected because:

- inconsistent developer setup
- poor reproducibility
- difficult to coordinate infrastructure dependencies

## Notes

This is a sequencing decision, not a rejection of Kubernetes. Kubernetes remains a core platform target and is addressed explicitly in a later project phase.