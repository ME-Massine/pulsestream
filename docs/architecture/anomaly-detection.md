# Deterministic anomaly detection

Issue [#269](https://github.com/ME-Massine/pulsestream/issues/269) replaces
replica-local history with tenant/device partitioning and bounded PostgreSQL
state. [ADR 0008](../decisions/0008-durable-anomaly-state.md) records the decision.
Implementation and local integration validation do not establish live cluster
acceptance or production capacity.

## Ordering and identities

Both ingestion and DLQ replay publish raw records with this String key:

```text
v1:base64url(UTF-8(trim(tenantId))):base64url(UTF-8(trim(deviceId)))
```

Base64url has no padding. IDs remain case-sensitive. Delimiter-containing and
Unicode IDs cannot collide; shared vectors in `contracts/ordering-keys.json`
are tested in both services. Event ID is preserved in the value for identity and
projection deduplication. It does not determine the raw partition. Missing
tenant/device/payload prevents publication by ingestion and replay.

The standard Kafka keyed partitioner routes every tenant/device to one partition.
Both producer factories enforce keyed partitioning and one in-flight request per
connection even if custom producer properties try to override them. External
producers, including simulators, must use the same key and standard partitioner,
with no explicit partition override. A wrong raw key stops processing. The
autoscaling Kafka generator follows this contract.

Within a partition, ascending Kafka offset is the authoritative order. There is
no global order between partitions and no event-time sort. Concurrent ingress
writers have the order assigned by the broker, not a promise of wall-clock or
device-sequence order. Replay appends a new reading at its new raw offset, with
the existing replay headers and event ID. The payload timestamp does not rewind
the baseline. Repeated event IDs at different offsets are separate readings for
detection; event-ID deduplication of projections remains a separate contract.

## Durable state and recovery

Flyway V3 adds three processor-owned tables:

| Table | Contents and bound |
| --- | --- |
| `platform.anomaly_partition_state` | One checkpoint/configuration per raw topic partition |
| `platform.anomaly_reading_state` | Last value per tenant/device/metric/canonical unit; at most the configured key limit per partition |
| `platform.anomaly_decisions` | Input fingerprint, severity and reasons per raw offset; at most the configured recent-decision limit per partition |

Detection locks the partition checkpoint with `SELECT ... FOR UPDATE`, checks
configuration and offset, prunes expired keys, evaluates the rules and commits
the baseline, decision and checkpoint together. Other partitions proceed
independently. A restarted or newly assigned replica uses the same database
state; no local history or rebalance transfer exists.

Retained redelivery returns its original severity and reasons and does not
advance history again. A changed input at a retained offset fails closed. An
offset at or below the checkpoint with no retained decision also fails closed;
manual group rewinds cannot silently recompute old readings against future
history. The journal is a bounded crash/rebalance recovery window, not historical
analytics or indefinite replay storage.

Raw listeners enforce `enable.auto.commit=false`, synchronous `RECORD` commits
and a stopping error handler. Database failures, capacity exhaustion, wrong keys,
missing record timestamps, stale offsets and configuration mismatch propagate as
state failures. They stop the container without dead-lettering or acknowledging
the failed record. Restore the dependency/correct the cause and restart the
processor to resume. Existing normalization/projection/publication failures
continue to follow the documented ordinary DLQ and replay failure paths.

Detection commits before projection persistence and Kafka publication. A crash
in between recovers the detection decision, but does not make those downstream
effects atomic. Delivery consistency remains #270; cross-classification replay
reconciliation remains #271. Neither a second consumer group nor manual offset
resets provide independent historical re-evaluation against these shared tables.
Use an isolated database for independent processing experiments.

## Retention and capacity

For each partition, stream time is the maximum Kafka **record timestamp** seen
so far, independent of the payload timestamp. New readings store that watermark
as their last activity time. On each new offset, delete baselines whose last
activity is at or before `stream time - state retention`. The first reading after
expiration establishes a new baseline and can still breach absolute thresholds.
Late record timestamps cannot move the watermark backward. Replayed records use
their new publication timestamp. Producer clocks must be reasonable; future
timestamps can advance expiration for every key on that partition.

Expiration advances with input, not replica wall clocks. An entirely idle
partition retains its bounded rows until its next input; restarts and quiet
periods alone do not erase history. This is intentional stream-time retention.
There is no unbounded per-replica map or background expiration race. Zero input
does not grow state. PostgreSQL vacuum/storage maintenance remains an operating
responsibility; the bounds describe retained rows, not a fixed disk byte budget.

With three partitions, defaults retain at most 30,000 reading rows, 3,000 decision
rows and three checkpoints. At capacity, updating an existing key is permitted.
A new key stops consumption, with the whole detection transaction rolled back;
active keys are never evicted to obtain a different anomaly answer. Recover by
restoring reviewed capacity/configuration or a coordinated state migration. Do
not skip the failed record or wait for wall-clock expiration: stream time is
stopped too. Retain enough journal entries for the supported redelivery window.

## Rules, units and configuration

Environment variables map to `pulsestream.anomaly.*` in application configuration:

| Environment suffix after `PULSESTREAM_ANOMALY_` | Default | Meaning |
| --- | --- | --- |
| `MIN_TEMPERATURE` | `-40` | Inclusive lower bound in the configured temperature unit |
| `MAX_TEMPERATURE` | `80` | Inclusive upper bound in that unit |
| `TEMPERATURE_UNIT` | `c` | Required canonical temperature unit |
| `SPIKE_RATIO` | `0.5` | Strict relative change threshold for all valid metric/unit streams |
| `STATE_RETENTION` | `24h` | Inactivity measured in partition stream time |
| `MAX_KEYS_PER_PARTITION` | `10000` | Hard active reading-key bound |
| `DECISIONS_PER_PARTITION` | `1000` | Retained offset decisions per partition |

Minimum must be below maximum; the ratio must be nonnegative; retention and row
bounds must be positive. Invalid configuration prevents startup. Every partition
persists the full settings; any mismatch stops consumption rather than mixing
rules between replicas. Change settings through a coordinated state migration,
not a rolling environment-variable edit.

Normalization trims and lowercases metric/unit tokens. `C`, `celsius` and `°C`
mean `c`; `F`, `fahrenheit` and `°F` mean `f`. No numeric unit conversion occurs.
With default rules, Fahrenheit, Kelvin and unknown temperature units produce a
CRITICAL incompatible-unit result and do not update a baseline. Missing units
are also CRITICAL. Other metrics compare only within the same canonical unit;
`pressure/bar` and `pressure/kpa` never share a baseline. Changing temperature
units requires setting the corresponding minimum/maximum together.

Missing tenant/device/metric/value is CRITICAL. Valid readings above/below the
temperature bounds or with `abs(current - previous) > abs(previous) * ratio`
are WARNING. Equality is normal. The first reading and a zero previous value
have no relative spike test. Negative previous values use absolute magnitude.
Both normal and anomalous valid readings become the next baseline. Displayed
percentage changes round to one decimal; threshold comparisons are exact.

## Rollout, reset and scaling

1. Pause all ingestion and replay writers, including external producers. Drain
   the old processor consumer group to zero lag and confirm committed offsets;
   then stop every old processor. Back up PostgreSQL and record group offsets.
2. Deploy ingestion and processor versions together while writers remain paused.
   Flyway applies V3. Do not mix old event-ID-keyed and new device-keyed producers
   or processors. Existing persisted projections remain intact; initial state is
   empty, so each device/metric/unit starts with a documented warm-up reading.
3. Resume writers, verify correct keys, group progress and expected decisions.
   Exercise scale-out, scale-in and restart in the target environment. Wrong-key
   historical backlog must be drained before cutover; do not bypass the guard.

Keep the existing raw topic at three partitions. Partition increases change key
placement and require a separate drained migration and baseline policy. Topic
recreation, restore and consumer-offset recovery must be coordinated with state
and retained Kafka history. Do not recreate a topic under an existing checkpoint.

For an intentional cold reset or rule change, pause writers, drain and stop all
processors, back up state and offsets, and obtain joint review of the warm-up
effects. Clear only the three anomaly state tables in one transaction (decisions
and readings before checkpoints), preserve projection tables and committed Kafka
offsets, deploy identical settings on every replica, then resume. A cold reset
removes spike comparisons for first readings. Recovering a larger history instead
requires an isolated rebuild and reviewed cutover. Rollback to the old key/state
implementation needs the same paused/drained coordination.

At most three raw consumer threads are active in a group. With concurrency one,
three replicas are the useful ceiling and two replicas divide all three
partitions. For concurrency `C`, `ceil(3 / C)` replicas provide enough consumer
slots; additional slots may be idle depending on assignment. Raising concurrency
does not increase partition throughput capacity. The existing CPU HPA stays
within two to three replicas. Lag-based HPA remains deferred pending #272 and
load evidence; database/state pressure is not resolved by adding consumers.

Local Maven integration tests compare 48 readings across three partitions for
one replica and a real consumer group changing from one to two to one replica,
then a fresh restarted instance. Tests also cover tenant/unit isolation, bounded
retention, concurrent redelivery, stale/configuration guards, database outage
without offset loss, and a crash after state commit before Kafka commit. Live
cluster rollout and representative capacity validation remain pending.

References: [PostgreSQL row locks](https://www.postgresql.org/docs/16/explicit-locking.html#LOCKING-ROWS),
[Spring Kafka offset commits](https://docs.spring.io/spring-kafka/reference/kafka/receiving-messages/message-listener-container.html#committing-offsets),
[stopping error handlers](https://docs.spring.io/spring-kafka/reference/kafka/annotation-error-handling.html#container-stopping-error-handlers).
