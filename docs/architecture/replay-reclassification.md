# Replay reclassification (#271)

The processor owns one current classification per globally unique event ID in
`platform.event_classifications`. Tenant ownership is immutable. NORMAL and
ANOMALY results have positive, increasing revisions; unresolved historical
conflicts have revision zero. This is current state, not an audit history.

## Processing and idempotency

The raw receipt, detector decision/state, classification, projection changes and
publication intents commit in one transaction. Raw partition state locks precede
the event classification lock. Different device partitions therefore cannot
concurrently replace the same event. Last serialized replay wins; timestamps and
offsets from different partitions do not define a global order.

Exact source-coordinate redelivery remains a no-op. Distinct ordinary duplicates
still evaluate detector state but keep the first authoritative result and publish
nothing. Explicit replay at a new raw offset reevaluates detection. It replaces a
changed normal or anomaly result, deletes the opposite projection, and increments
the revision. Repeating an identical result leaves revision, projections, row IDs,
ingestion/detection times and publications unchanged. A return to an earlier
classification increments revision rather than reusing its previous revision.

Equality uses JSONB semantic content: normalized output payload, event timestamp
as epoch seconds at microsecond precision, classification, and anomaly
severity/reasons. The anomaly type and threshold are fixed by the projection write
and are neither compared nor rewritten by an unchanged replay. An unchanged replay
still recreates a selected projection row that is missing, without a new revision
or publication.
Decimal scale and object property order do not change equality. Generated
processing/detection times, replay headers and wire versions are excluded.
Reason array order is significant. Numeric and timestamp precision lost in old
PostgreSQL rows cannot be recovered by migration; a higher-precision replay may
establish a corrected revision. Missing event timestamps reuse the resolved
classification's stored semantic event time, including when its projection is
missing. Unresolved events reuse an existing projection timestamp, or the first
processing time when no projection exists.
Same-classification updates retain projection IDs; cross-classification changes
allocate a new destination ID. Authoritative projection updates set `ingestedAt`
to the registry's first event processing time, including when an unresolved
legacy conflict selects an anomaly row ingested later than its normal row.

## Downstream v2 contract

Processed and anomaly topics retain their names and event-ID keys. New output
uses version 2.0. Each value contains `operation` (UPSERT or RETRACT),
`classificationRevision` and the resulting active `classification` (NORMAL or
ANOMALY), plus eventId, tenantId, timestamp, eventType and source. Event type
identifies the topic projection, including retractions. UPSERT contains the
selected payload and, on the anomaly topic, severity, reasons and detectedAt.
RETRACT omits those fields and removes the obsolete topic projection.

Normal-to-normal and anomaly-to-anomaly changes publish one UPSERT. Boundary
changes publish RETRACT on the old topic followed by UPSERT on the selected topic,
both with the new revision. Resolving a historical conflict similarly retracts
the opposite topic and upserts the selected one. Initial classification publishes
one UPSERT. No Kafka null tombstones are introduced.

Consumers must first deploy support for v1 and v2. Treat historical v1 as revision
zero. Track a watermark by tenant, event ID and topic; persist the watermark after
RETRACT. Ignore duplicate or older revisions. UPSERT replaces the topic projection;
RETRACT removes it. A consumer of both topics reconciles the highest classification
revision; its equal-revision pair is complementary, so a retraction must never
remove the selected classification. A retraction received first can identify the
new classification before its payload arrives. Topic-only consumers can see gaps
in revisions. Cross-topic visibility is eventual, not atomic.

Outbox rows are unique by receipt and sequence. Sequence 0 is the retraction and
sequence 1 the replacement on boundary changes. Dispatch preserves source offset
and sequence order within a partition. A message also waits while an earlier
undelivered row for the same event key exists on another source partition, so one
event's revisions leave the processor in commit order.
All retry payloads are immutable. A broker acceptance followed by a failed marker
can duplicate a message; revision watermarks make recovery converge. PostgreSQL
queries may lead Kafka while durable intents await delivery.

## Migration and query visibility

V6 adopts single-projection events at revision 1 without historical publication
backfill. Same-tenant IDs present in both tables remain physically preserved and
UNRESOLVED. Both APIs join authoritative state and hide unresolved rows. The first
record that reaches an unresolved event, ordinary or replay, classifies it at
revision 1 and deletes the other projection; a replay chooses the result
deliberately. Once classified, ordinary duplicates are ignored.
Cross-tenant ownership collisions fail migration without deleting rows.

Both APIs add `classificationRevision`. Existing tenant boundaries, filters and
pagination apply. Each HTTP request has its own database snapshot: separate
requests around a transition may show different revisions. The query role needs
SELECT on `platform.event_classifications` as well as both projections.

The replay marker is a header on the raw topic and is trusted as written. Restrict
write access to `telemetry.events.raw` with broker ACLs to the ingestion service
and the replay publisher, because any other writer could replace an existing
classification.

## Rollout and recovery

1. Deploy v1/v2-capable downstream readers. Pause ingestion, external raw writers
   and replay. Drain the old outbox and stop processors and query instances.
2. Back up the database. Start the new processor to apply V6 before traffic
   resumes. Allow maintenance time, locks, disk and WAL capacity for the registry
   backfill and replacement pending index. Mixed-version writers are unsupported.
3. Grant the existing query login SELECT on `platform.event_classifications`;
   start updated query instances and verify both APIs before resuming traffic.
4. Inspect unresolved events and explicitly select those available in retained
   DLQ data. Replay remains bounded by trigger-time partition snapshots and event
   selection. Raw historical replay tooling is outside this increment; conflicts
   without an available replay source remain hidden until such a source is supplied.
5. Monitor existing delivery pending/failed counts, oldest age and database disk
   capacity. Restart failed listeners after correcting the underlying failure.
   Do not delete receipts or reset offsets to conceal failures. Prefer a forward
   fix; old applications cannot safely resume after classification cutover.

```sql
SELECT classification, count(*) FROM platform.event_classifications GROUP BY classification;
SELECT event_id, tenant_id FROM platform.event_classifications
WHERE classification = 'UNRESOLVED' ORDER BY event_id;
SELECT p.event_id, p.tenant_id AS processed_tenant, a.tenant_id AS anomaly_tenant
FROM platform.processed_telemetry p JOIN platform.anomalies a USING (event_id)
WHERE p.tenant_id <> a.tenant_id;
GRANT SELECT ON platform.event_classifications TO pulsestream_query;
```

Transaction/enqueue failures roll back the entire transition and leave the source
unacknowledged. Kafka/send-marker failures retry committed intents. Missing-payload
DLQ routing remains the separate durable transaction from #270 and never retracts
a previously valid classification. No automatic bulk replay, pruning, historical
publication repair, detection algorithm change or audit-retention policy is added.
Live target-cluster rollout and capacity validation remain pending.
