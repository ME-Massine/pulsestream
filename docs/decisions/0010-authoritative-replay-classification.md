# ADR 0010: Authoritative replay classification and versioned replacement

Status: Accepted for #271; live rollout pending.

## Decision

Maintain one tenant-owned current classification per event ID. Serialize explicit
replay replacements under a PostgreSQL row lock, atomically remove the opposite
projection and enqueue versioned UPSERT/RETRACT messages through the #270 outbox.
Unchanged semantic results produce no revision or publication. Preserve historical
same-tenant conflicts as unresolved and hide them until selective replay resolves
them. Cross-tenant collisions fail migration.

## Consequences

Queries expose the active classification revision. Downstream readers must support
v2, retain revision watermarks after retraction and tolerate duplicates, gaps and
cross-topic reordering. No end-to-end exactly-once or cross-topic atomic visibility
is claimed. A coordinated paused/drained cutover and additional query SELECT grant
are required. A new authoritative Kafka topic and an unbounded classification
history are unnecessary. See [the operating contract](../architecture/replay-reclassification.md).
