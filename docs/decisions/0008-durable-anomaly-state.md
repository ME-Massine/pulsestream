# ADR 0008: Device ordering and durable bounded anomaly state

Status: Accepted for issue [#269](https://github.com/ME-Massine/pulsestream/issues/269).

## Context

Sudden-deviation detection previously kept unbounded readings in a replica-local
map, while ingestion and replay keyed raw records by event ID. A device could
reach different replicas and lose history during rebalances and restarts.
PostgreSQL is already required by the processor and owns its projections.

## Decision

Key raw records by an unambiguous encoding of the trimmed, case-sensitive tenant
and device IDs. Keep the three existing partitions. Use Kafka partition offset
order, including replay appended as a new reading; event timestamps do not reorder
the stream. Pin both producers to Kafka's standard keyed partitioner and one
in-flight request per connection, preserving ordering through send retries.

Store prior values by tenant/device/metric/canonical unit in PostgreSQL. A locked
partition checkpoint serializes each transaction across consumer owners. Commit
the reading, decision journal and offset watermark atomically before returning
the detection result. Retain a bounded recent decision window to reproduce
uncommitted deliveries after restart. Reject old offsets outside that window.

Expire inactive reading keys using a monotonic per-partition Kafka-record timestamp
watermark. Set a hard key limit per partition and stop consumption at capacity
rather than evicting active history. Stream time makes decisions and expiration
independent of processing delays and replica clocks. Completely idle partitions
remain bounded and prune on their next record.

Keep rules stateless and configuration-driven. Reject incompatible temperature
units; keep distinct units in separate baseline keys. Store the configuration with
each checkpoint and reject mixed configurations. Use record acknowledgments and
a stopping error handler for state failures, preserving failed Kafka offsets.

## Consequences

Replicas recover shared state without transferring or rebuilding local maps.
Scale-out, scale-in, restart and real group rebalances are covered with Kafka and
PostgreSQL integration tests. State adds database reads/writes and partition-level
locking; throughput and connection budgets require load validation under #277.

The producer key change needs a paused/drained cutover. Partition count, topic
recreation, state reset and rule changes require coordinated recovery. This does
not make projections, Kafka output and consumer offsets one atomic transaction
(#270), nor reconcile replay reclassification (#271). Kafka Streams/changelog
recovery would add another runtime/state topology and is deferred.

See [the operating contract](../architecture/anomaly-detection.md) for limits,
retention, rollout, failure handling and recovery.
