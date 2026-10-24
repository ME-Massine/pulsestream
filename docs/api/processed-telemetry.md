# Processed telemetry query API (#266)

`GET /api/v1/telemetry` reads normal processed events from
`platform.processed_telemetry`. The query service owns no schema migrations and
never writes projections. Start the telemetry processor first so its Flyway
migrations initialize or adopt the database. Anomaly queries remain tracked by
#267. The machine-readable contract is served at `/openapi.yaml` from the query
service's port 8083.

## Tenant boundary

The Phase 7 authentication integration must establish an authenticated servlet
`Principal` whose `getName()` is the authorized tenant ID (1–100 characters,
nonblank). This is an integration contract, not a username-to-tenant lookup.
An authentication provider with user identities must authorize and map the tenant
before supplying that principal to the query controller.

The service does not implement authentication or accept identity from
`X-Tenant-Id`, `Authorization`, or other raw HTTP headers. A gateway alone cannot
set a servlet principal by forwarding a header: an authenticated in-process
security adapter or container integration must create it. Until that integration
is installed, ordinary HTTP calls return **401**, including local requests.
The PostgreSQL integration suite exercises successful calls with authenticated
test principals. Do not expose this ClusterIP API externally before the Phase 7
boundary is implemented and validated. Authentication implementation remains
outside #266; #273 tracks the external ingestion boundary.

Tenant identifiers are never query filters. `tenantId`, `tenant_id`, arbitrary
sorts, other unknown parameters, and repeated parameters return 400. Every SQL
query includes the principal tenant predicate, including device/time queries and
empty results. A tenant with no matching records receives an empty page.
Query responses and controlled errors carry `Cache-Control: no-store` so shared
HTTP caches cannot reuse a tenant's response for another identity.

## Requests and responses

The following request is made through an authentication integration that has
established `Principal.getName() == "site_nador_01"`:

```http
GET /api/v1/telemetry?deviceId=temp_sensor_17&from=2026-10-01T00:00:00Z&to=2026-11-01T00:00:00Z&page=0&size=50
Accept: application/json
```

```json
{
  "content": [{
    "id": 42,
    "eventId": "evt-42",
    "tenantId": "site_nador_01",
    "eventType": "telemetry.processed",
    "timestamp": "2026-10-24T12:00:00Z",
    "source": "processor",
    "deviceId": "temp_sensor_17",
    "deviceType": "temperature_sensor",
    "metric": "temperature",
    "value": 21.1234,
    "unit": "C",
    "location": "room",
    "ingestedAt": "2026-10-24T12:00:01Z"
  }],
  "page": 0,
  "size": 50,
  "hasNext": false
}
```

| Parameter | Contract |
| --- | --- |
| `deviceId` | Optional exact match; 1–100 characters and nonblank. |
| `from` | Optional inclusive event timestamp, ISO-8601 with offset, years 0001–9999. |
| `to` | Optional exclusive timestamp; later than `from` when both are supplied. |
| `page` | Zero-based integer, default 0, range 0–10000. |
| `size` | Integer, default 50, range 1–100. |

Bounds can be supplied independently. All supplied filters are combined with
AND. URL-encode `+` in non-UTC offsets as `%2B`. Ordering is fixed at
`timestamp DESC, id DESC`, including when timestamps are equal. PostgreSQL stores
timestamps at microsecond precision. The maximum offset is 1,000,000 rows;
queries fetch at most `size + 1` rows to determine `hasNext` and never count the
entire result set. There are no total-count or total-page fields.

Pagination is deterministic over unchanged data. Each request sees its own
database snapshot: concurrent ingestion, replay, or projection updates can shift
offsets between requests. This API does not promise a stable multi-page export.

Controlled errors use `application/problem+json`:

```json
{
  "type": "about:blank",
  "title": "Bad Request",
  "status": 400,
  "detail": "from must be earlier than to.",
  "instance": "/api/v1/telemetry"
}
```

400 covers invalid filters, bounds, duplicate or unknown parameters. Missing or
invalid authenticated tenant identity returns 401. Database connection,
transaction and SQL failures return 503 with the generic detail
`Processed telemetry is temporarily unavailable.` SQL and credentials are not
included in responses.

## Database and local configuration

Use Java 25, matching the service POM and ADR 0006. Start the local infrastructure
and processor as described in [the Docker README](../../infrastructure/docker/README.md).
Create a dedicated login with a password managed outside version control, then
grant only the read privileges below (execute as the database owner):

```sql
GRANT CONNECT ON DATABASE pulsestream TO pulsestream_query;
GRANT USAGE ON SCHEMA platform TO pulsestream_query;
GRANT SELECT ON platform.processed_telemetry TO pulsestream_query;
```

The role must not own schemas/tables, inherit write-capable roles, or have
superuser privileges. No anomaly, sequence, DDL, Flyway history or write grants
are needed. Both the pool and service transactions request read-only connections;
database grants enforce the boundary independently.

Set `PULSESTREAM_POSTGRES_URL` (default
`jdbc:postgresql://localhost:5432/pulsestream`),
`PULSESTREAM_POSTGRES_USERNAME` and `PULSESTREAM_POSTGRES_PASSWORD` in the host
process environment, then run `.\mvnw.cmd spring-boot:run` from
`services/query-service`. Credentials have no application defaults. Compose's
`.env` configures infrastructure; it is not automatically loaded by host JVMs.

```powershell
$env:PULSESTREAM_POSTGRES_URL = 'jdbc:postgresql://localhost:5432/pulsestream'
# Supply the dedicated username/password through the local secret mechanism.
.\mvnw.cmd spring-boot:run
```

Without an installed security adapter, this smoke request intentionally returns
401; the OpenAPI document and probes remain available without a tenant identity:

```bash
curl -i http://localhost:8083/api/v1/telemetry
curl -f http://localhost:8083/openapi.yaml
curl -f http://localhost:8083/readyz
```

## Health and deployment policy

`/readyz` and `/actuator/health/readiness` include `readinessState` and `db`.
The aggregate `/actuator/health` also includes database connectivity. Required
PostgreSQL loss returns 503 and removes the pod from service; `/livez` remains
200 while the process is alive, avoiding restart loops during a database outage.
Readiness checks connectivity, not migration version, table privileges, or tenant
authentication integration. Operators must apply processor migrations and the
documented grants before routing query traffic. Query failures remain controlled
503 responses if a schema or permission prerequisite is missing.

The pool has at most five connections per replica, a two-second acquisition and
connect timeout, a one-second validation timeout, and a five-second socket
timeout. Query transactions have a five-second timeout. Monitor replica count
against PostgreSQL's connection budget.

In Kubernetes, apply `query-service/configmap.yaml` and provision
`query-service-secret` out of band using the keys shown in
`query-service/secret.example.yaml`. Do not apply the example placeholders.
Deploy after processor migration startup. PostgreSQL remains separately
provisioned at `postgres:5432`; adapt the URL and network-policy peers together
for another namespace or external database. The committed policy permits TCP
5432 to same-namespace pods, matching the processor's provisioning assumption;
tighten to PostgreSQL pod labels when known. Kafka egress stays denied.

## Validation

Run `.\mvnw.cmd verify` from `services/query-service`. Unit and MVC tests validate
parameters and identity handling. The required PostgreSQL 16 Testcontainers suite
applies the processor's actual V1 migration and tests row mapping, read-only
grants, tenant isolation, bound filters, tie ordering, pagination, HTTP schemas,
SQL injection strings, database loss, readiness, liveness and recovery. Docker
unavailability fails the build. No H2 substitute is used for repository behavior.
