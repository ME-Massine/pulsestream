# Anomaly query API

Issue #267 adds `GET /api/v1/anomalies` and durable anomaly projections in
`platform.anomalies`. The processor owns all writes and Flyway migrations;
query-service uses a dedicated SELECT-only database role. Normal telemetry
continues to use [its existing API](processed-telemetry.md).

## Identity and filters

The authenticated servlet `Principal.getName()` supplies the authorized tenant
ID, using the same integration boundary as #266. No authentication provider is
included. Without that integration, HTTP requests fail closed with 401. Tenant
headers cannot establish or override identity; tenant query parameters return
400. Every SQL query includes a bound tenant predicate.

| Parameter | Contract |
| --- | --- |
| `deviceId` | Exact, case-sensitive device ID, 1–100 characters; not blank |
| `severity` | Exact, case-sensitive severity, 1–20 characters; not blank. Current detector emits `WARNING` or `CRITICAL`; historical labels such as `high` remain supported |
| `metric` | Exact, case-sensitive metric, 1–100 characters; not blank |
| `from` | Inclusive event-time lower bound, ISO-8601 with offset, years 0001–9999 |
| `to` | Exclusive event-time upper bound; later than `from` if both supplied |
| `page` | Zero-based integer 0–10000; default 0 |
| `size` | Integer 1–100; default 50 |

Filters combine with AND. Unknown or repeated parameters return 400. Ordering
is fixed at `timestamp DESC, id DESC`. One lookahead row determines `hasNext`;
there is no total-count query. Empty, unknown-tenant or out-of-range result pages
return 200 with empty content. Offset pages are deterministic over unchanged
data; arrivals and replay updates can move rows between requests.

Example request after the tenant authentication integration is installed:

```http
GET /api/v1/anomalies?deviceId=sensor-1042&severity=WARNING&metric=temperature&from=2026-01-01T00:00:00Z&to=2026-01-02T00:00:00Z&page=0&size=50
```

```json
{
  "content": [{
    "id": 42,
    "eventId": "evt-001",
    "tenantId": "factory-01",
    "timestamp": "2026-01-01T12:00:00Z",
    "deviceId": "sensor-1042",
    "deviceType": "temperature-sensor",
    "metric": "temperature",
    "value": 95.0000,
    "unit": "C",
    "location": "zone-a",
    "threshold": null,
    "anomalyType": "rule_violation",
    "severity": "WARNING",
    "reasons": ["temperature is above maximum threshold"],
    "detectedAt": "2026-01-01T12:00:01Z",
    "ingestedAt": "2026-01-01T12:00:02Z"
  }],
  "page": 0,
  "size": 50,
  "hasNext": false
}
```

`value` can be null for missing-reading anomalies; device/metric and optional
payload metadata can also be null. Decimals use PostgreSQL `NUMERIC(18,4)`.
`threshold` and `anomalyType` preserve legacy records. New results use
`rule_violation` and null threshold: the detector supplies explanations rather
than a structured numeric threshold, and one event can violate several rules.
Legacy records have empty reasons, null additional payload metadata and an
initial `detectedAt` equal to their original `ingestedAt`.

All responses and controlled errors carry `Cache-Control: no-store`. Errors use
`application/problem+json`: 400 for invalid parameters, 401 for missing/blank or
overlong tenant identity, 503 for database/transaction failures. The 503 detail
is `Anomalies are temporarily unavailable.` No SQL or credentials are exposed.
OpenAPI 3.1 is served at `/openapi.yaml` and documents both query endpoints.

## Persistence and recovery

The processor commits the projection before publishing to
`telemetry.events.anomalies`. PostgreSQL `ON CONFLICT (event_id)` makes inserts
and replay replacements atomic under concurrent deliveries. Ordinary duplicate
deliveries keep the first projection unchanged. Explicit replay replaces the
event time, payload, severity, reasons and detection time of the same tenant's
projection. Row ID and first ingestion time stay stable. A collision with another
tenant fails and never transfers a projection to that tenant. Event IDs remain
globally unique, matching the existing schema contract.

Persistence failures prevent anomaly publication and propagate to the existing
raw consumer recovery path. Ordinary failures route the original event to the
DLQ; DLQ publication failure propagates to Kafka retry handling. Failed replays
do not create a new DLQ entry: the original record remains the operator retry
source. After a successful database commit, a Kafka publication failure can
leave a durable row while publication is retried through the DLQ. Database and
Kafka writes are separate; duplicate Kafka messages remain possible (#270).

Tenant and event identity are mandatory for durable persistence. A detector
result with missing tenant/event identity follows the failure path; no anonymous
or invented tenant projection is stored. Missing device, metric or value fields
are preserved with the detector's reasons. Detection rules and thresholds are
unchanged. Reclassification across the normal/anomaly boundary remains #271;
this issue does not delete or supersede a projection in the other table.

Prometheus exports
`pulsestream_anomaly_persistence_total{outcome="success|duplicate|failure"}`
on the existing processor management surface. `success` counts committed
inserts/replay updates, `duplicate` counts ignored ordinary duplicates, and
`failure` counts rejected or failed persistence attempts, including transaction
commit failures. Labels contain no tenant, event or device identifiers.

## Deployment and verification

Apply processor Flyway V2 before deploying the new processor/query images. V1
is unchanged; V2 preserves IDs, rows and legacy threshold/type data, adds JSONB
reasons/detection time and payload metadata, relaxes missing-reading fields and
adds `(tenant_id, timestamp DESC, id DESC)` indexing. Back up before upgrading;
V2 updates legacy rows and creates an index transactionally, so schedule for
table locks and migration time on large histories. Do not roll back schema with
automatic destructive SQL. A binary rollback to a V1-era processor needs Flyway
compatibility review because its migration set no longer includes V2.

Extend the existing dedicated query role after migration:

```sql
GRANT SELECT ON platform.anomalies TO pulsestream_query;
```

The role also retains SELECT on `platform.processed_telemetry`, CONNECT on the
database and USAGE on `platform`; it needs no write, sequence, DDL or Flyway
history access. Credentials and authentication integration follow the
[query operating guide](processed-telemetry.md#database-and-local-configuration).
Existing database health/readiness, connection budgets, timeouts and network
policy apply. Health probes check connectivity, not table privileges or schema
version; verify the new grant and migration before routing traffic.

Required PostgreSQL 16 tests execute the actual migrations and cover V1 upgrade,
legacy preservation, inserts, duplicate deliveries, replay updates, concurrency,
tenant collisions, missing fields, all filters, pagination and the SELECT-only
role/API boundary. Docker unavailability fails these tests. Run Maven `verify`
for all three services; no live target-cluster acceptance is implied.
