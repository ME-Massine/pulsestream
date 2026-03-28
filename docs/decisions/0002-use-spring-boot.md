# ADR 0002: Use Spring Boot for platform services

## Status
Accepted

## Context

PulseStream requires several backend services, including:

- ingestion service
- telemetry processor
- query service

The team needs a framework that supports:

- rapid service development
- production-grade HTTP APIs
- Kafka integration
- strong configuration support
- observability instrumentation
- testability
- maintainable service structure

The framework should also align with the team's existing skills and allow the project to move quickly without sacrificing engineering quality.

## Decision

PulseStream will use **Spring Boot** as the primary framework for backend services.

Spring Boot will be used for:

- REST API development
- Kafka producers and consumers
- configuration management
- observability integration
- dependency injection and modular service design

Java 17 will be used as the runtime baseline.

## Consequences

### Positive

- Strong productivity for backend service development
- Mature ecosystem
- Excellent support for Kafka integration
- Good fit for structured microservice design
- Strong support for testing and observability
- Aligns with team skills and existing experience

### Negative

- Heavier runtime footprint than some lighter frameworks
- Requires disciplined configuration management
- Can encourage overly complex abstractions if used carelessly

## Alternatives Considered

### Node.js / Express

Rejected because:

- weaker fit with the team’s main backend strength for this project
- less consistent for the service architecture style chosen
- weaker long-term fit for strongly structured distributed-service code in this repo

### Go

Rejected for MVP because:

- excellent for cloud systems, but not the best match for current team delivery speed
- would increase ramp-up time
- would slow initial implementation compared to Spring Boot

### Plain Spring Framework without Spring Boot

Rejected because:

- adds unnecessary setup complexity
- reduces development speed
- provides little benefit for this project compared to Spring Boot

## Notes

Spring Boot is a strategic implementation choice for service delivery speed and maintainability. It does not prevent future polyglot extensions if later phases justify them.