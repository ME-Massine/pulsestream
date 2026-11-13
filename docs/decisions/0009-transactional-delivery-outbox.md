# ADR 0009: Recover delivery through a PostgreSQL outbox

Status: Accepted for issue #270; live rollout pending.

## Context

Projection persistence followed by a Kafka send leaves a crash window in which
PostgreSQL commits but downstream consumers receive nothing. Best-effort DLQ
publication and swallowed replay failures could acknowledge unsuccessful work.
Kafka transactions cannot atomically commit PostgreSQL projections.

## Decision

Commit the source receipt, anomaly state, projection and serialized publication
intent in one PostgreSQL transaction. A separate dispatcher sends committed
outbox messages with broker acknowledgements and records successful delivery.
Input validation failures use a new transaction for a durable DLQ outcome after
processing rolls back. Infrastructure and unexpected failures stop consumption.

Source receipts identify topic/partition/offset and fingerprint the input. They
make repeated delivery of the same source record a no-op. Explicit replay records
at new offsets remain distinct operations. PostgreSQL conflict clauses implement
projection idempotency without parsing localized exception messages.

## Consequences

Kafka outages create a visible database backlog instead of losing source work.
An ambiguous send or failed delivery-marker commit may publish a duplicate.
Consumers must tolerate at-least-once delivery. No end-to-end exactly-once claim
is made. Source offsets may lead downstream publication after durable enqueue.
Receipts and delivered outbox rows require capacity planning; automatic pruning
is deferred until an explicit offset-retention and recovery policy exists.

See [the operating contract](../architecture/delivery-consistency.md) for failure
windows, recovery, metrics and rollout. Replay reclassification remains #271.
