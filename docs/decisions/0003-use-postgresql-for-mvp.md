# ADR 0003: Use PostgreSQL as the primary persistence layer for the MVP

## Status
Accepted

## Context

PulseStream must persist:

- processed telemetry records
- anomaly events
- device status summaries

The MVP requires a storage solution that is:

- reliable
- simple to operate locally
- easy to query
- compatible with Spring Boot
- sufficient for structured telemetry and anomaly data
- appropriate for dashboards and API queries

A time-series database may become attractive later, but the initial version should optimize for delivery speed, simplicity, and engineering clarity.

## Decision

PulseStream will use **PostgreSQL** as the primary persistence layer for the MVP.

PostgreSQL will store:

- telemetry readings
- anomaly events
- device status summaries
- queryable aggregates where appropriate

Redis may be introduced as a secondary caching layer, but PostgreSQL remains the primary source of truth for stored application data.

## Consequences

### Positive

- Mature and reliable database
- Easy local development setup
- Strong support in Spring Boot
- Flexible relational modeling
- Excellent for dashboards, APIs, and structured queries
- Reduces infrastructure complexity in early phases

### Negative

- Not optimized specifically for high-volume time-series workloads
- May require tuning as telemetry volume increases
- Advanced telemetry analytics may later need specialized storage

## Alternatives Considered

### TimescaleDB

Rejected for MVP because:

- adds conceptual and operational complexity
- not necessary for the first implementation
- PostgreSQL alone is sufficient initially

### ClickHouse

Rejected for MVP because:

- better suited to analytical workloads at larger scale
- more infrastructure complexity than needed early on
- premature for initial delivery

### MongoDB

Rejected because:

- the project benefits from structured queryability
- anomaly and telemetry relationships are easier to manage in relational form
- PostgreSQL is a better fit for the expected query patterns

## Notes

This decision is intentionally MVP-scoped. Future platform versions may introduce time-series or analytical storage once telemetry volume and query complexity justify it.