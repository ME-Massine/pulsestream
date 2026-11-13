# PostgreSQL and Kafka delivery consistency

Issue #270 replaces projection-then-send processing with a transactional outbox.
Implementation and local validation do not establish live-cluster acceptance.

## Durable outcome and acknowledgement

The raw listener commits a source receipt, anomaly state/decision, the selected
projection and the exact downstream JSON in one PostgreSQL transaction. It returns
only after commit. A receipt uniquely identifies source topic, partition and
offset; a SHA-256 fingerprint includes the event, key, timestamp and headers.
Redelivery of that coordinate does nothing; changed input stops consumption and
requires investigation of topic recreation or incorrect offset restoration.

Both listener factories disable auto-commit, use RECORD acknowledgements and
synchronous commits, and stop on unhandled failures. The bounded DLQ replay
listener still acknowledges selected records only after successful republishing
to raw Kafka; raw processing then uses the outbox. Deserialization failures and
tombstones stop consumption without acknowledging the offending record.

A missing payload is a known invalid input: processing rolls back and a separate
transaction commits its receipt and the existing DLQ wrapper. This applies to
explicit replays too; it does not silently discard the replay. Other validation,
database, state, serialization and unexpected errors stop the source listener.
They are not assumed to be permanent input faults. A failed DLQ transaction also
propagates. The ingestion service's separate DLQ behavior is outside #270.

## Recovery windows

| Failure window | Durable state and recovery |
| --- | --- |
| Before or during processing commit | All processing changes roll back; source remains uncommitted and is retried after restart. |
| Commit succeeds, source offset commit fails | Redelivery finds the receipt; no second state transition, projection or outbox row. |
| Kafka unavailable before send | Pending row remains; dispatcher retries automatically. |
| Send fails or times out | Outcome may be ambiguous; retain and retry the identical payload. |
| Kafka accepts, process/database fails before delivery marker | Pending row is resent; downstream duplication is possible. |
| Delivery marker commits | Dispatcher skips the row on later polls and restarts. |
| Invalid input plus database/Kafka outage | A durable DLQ intent or an uncommitted source remains; no best-effort acknowledgement. |

Ordinary event-ID duplicates keep the first projection. Distinct source records
can each publish a result; source receipts do not deduplicate different offsets.
Explicit same-tenant replays update their selected projection and enqueue another
result. Cross-tenant event-ID collisions fail. Cross-classification cleanup and
consumer supersession remain #271.

## Dispatcher and monitoring

`pulsestream.outbox.enabled` defaults to true. Each instance polls with a fixed
delay of `pulsestream.outbox.poll-interval` milliseconds (default 1000), delivering
at most 100 messages per poll. PostgreSQL transaction advisory locks serialize
dispatch for each source partition across replicas. The oldest pending offset
blocks later offsets from that partition during backoff; independent partitions
can continue. Locks release automatically on connection/process loss.

The dedicated string producer sends stored JSON with `acks=all`, idempotence and
one in-flight request. Batching delay defaults to zero so the default 30-second
delivery timeout satisfies Kafka's request/delivery timeout constraint. Conflicting durability overrides fail startup. Publish
wait and metadata/buffer blocking use the configured positive publish timeout;
the underlying Kafka send may complete after the caller times out. There is no
cross-restart deduplication guarantee from producer idempotence. Broker durability
also depends on replication, ISR and retention settings in the target cluster.

Failures retain a bounded error class, increment attempts and back off from one
second exponentially to 60 seconds. There is no automatic discard or retry limit.
Ordering applies to dispatcher attempts within a source partition, not global
ordering across source partitions or duplicate sends with ambiguous outcomes.

Prometheus exposes:

- `pulsestream_delivery_pending`, `pulsestream_delivery_failed_pending` and
  `pulsestream_delivery_oldest_pending_seconds`: database-backed backlog gauges.
  Database query failure reports NaN instead of an empty backlog.
- `pulsestream_delivery_attempts_total`, `pulsestream_delivery_failures_total`,
  `pulsestream_delivery_retries_total`, `pulsestream_delivery_delivered_total` and
  `pulsestream_delivery_recovered_total`: per-instance attempt/outcome counters.
  Delivered and recovered counters increment after the marker commits.

Inspect pending rows by joining `platform.delivery_outbox.receipt_id` to
`platform.processing_receipts.id`; inspect `attempts`, `next_attempt_at`,
`last_error`, destination and source coordinates. Avoid exposing payloads in logs.
Repair Kafka connectivity/configuration, then let retries resume. For database
or processing failures, restore the dependency, investigate logs and restart the
stopped listener/process. Never advance offsets or delete pending rows to clear
an incident. Monitor PostgreSQL storage and oldest-pending age: acknowledgements
can continue while publication is unavailable, so backlog can grow without bound.

Receipts and delivered rows are retained in this version. No automatic pruning
or historical publication backfill is provided. Downstream consumers must handle
duplicate events and replay results; exactly-once external effects are not promised.

## Rollout

Pause ingestion and replay, drain raw consumption and stop every old processor.
Start the new release so Flyway applies V4 before listener/dispatcher startup;
verify migration success, metrics and delivery, then resume producers. Mixed old
and new processor versions are unsupported for the cutover. Existing projection
rows are preserved. Pre-upgrade missing publications need an audited replay;
the outbox cannot infer whether historical Kafka sends succeeded.

Do not restore only one of receipts, outbox, projections and anomaly state.
Coordinate database and Kafka offset/topic recovery. Topic recreation requires
an explicit migration of receipts and anomaly state. Keep producers paused during
recovery. Rollback to a pre-outbox binary requires draining pending publications
and an explicit recovery plan; additive schema compatibility alone is insufficient.
