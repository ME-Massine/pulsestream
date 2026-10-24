# PostgreSQL schema migrations

The telemetry processor owns the `platform` schema through Flyway SQL migrations
packaged in `services/telemetry-processor/src/main/resources/db/migration`.
This implements #265. Query endpoints (#266) and application anomaly persistence
(#267) remain separate work.

Flyway keeps PostgreSQL DDL as ordered SQL files, integrates with the existing
Spring Boot startup lifecycle, and validates applied migration checksums. The
Spring Boot dependency management supplies both its core and PostgreSQL modules.

## Ownership and startup

Flyway runs automatically at processor startup, before JPA initialization and
Kafka listener startup. Both local development and Kubernetes use the same
application configuration and migrations. A database connection, DDL privileges,
and successful migration validation are now startup prerequisites. A migration
error fails startup; disabling database health checks does not bypass migration.

`V1__create_platform_tables.sql` preserves the original `SERIAL` identifiers,
column types, lengths, numeric precision, timestamp defaults, primary and unique
constraints, and six lookup indexes for `platform.processed_telemetry` and
`platform.anomalies`. Hibernate remains `ddl-auto: none` and never changes tables.
The anomaly table is provisioned, but application anomaly persistence is not
implemented by this change.

Flyway creates its own `pulsestream_migrations` schema and records successful
versions and checksums in `pulsestream_migrations.flyway_schema_history`.
Only the telemetry processor runs migrations. The database role configured by
`PULSESTREAM_POSTGRES_USERNAME` must have `CONNECT` and `CREATE` on the database
and own the legacy platform objects, or have equivalent DDL privileges. Use the
existing datasource URL, username, and password settings; credentials stay in
local environment configuration or Kubernetes Secrets.

## Local development

From `infrastructure/docker`, copy `.env.example` to `.env` if needed, then run:

```powershell
docker compose up -d --wait postgres kafka
```

From `services/telemetry-processor`, start the processor:

```powershell
.\mvnw.cmd spring-boot:run
```

Use `./mvnw spring-boot:run` on Unix. Compose starts dependencies; application
services run on the host. Starting the processor applies all pending migrations
without manual SQL. If Compose database names, credentials, or the published
port differ from defaults, export matching `PULSESTREAM_POSTGRES_URL`,
`PULSESTREAM_POSTGRES_USERNAME`, and `PULSESTREAM_POSTGRES_PASSWORD` before
starting it. Compose's `.env` is not automatically exported into the host shell.

After startup, inspect migration history without changing the database:

```powershell
docker compose exec postgres psql -U pulsestream -d pulsestream -c "TABLE pulsestream_migrations.flyway_schema_history;"
```

Adjust the role/database arguments for customized environments. Restarting the
processor validates checksums and skips already-applied versions. `docker compose
down` preserves data; `down -v` deletes it and is not a migration or recovery step.

## Existing databases

The former `infrastructure/docker/postgres/init.sql` manual entrypoint has been
removed. Its frozen copy under test resources is a legacy-upgrade fixture only.
Do not mount an initialization script or apply SQL separately before startup.

Before introducing migrations to a database with data, take and verify a backup,
confirm the datasource points at the intended database, and use its existing
schema owner. V1 uses `IF NOT EXISTS` to retain existing tables and rows, fills in
missing initial objects, and validates the legacy columns, constraints, defaults,
and index definitions before recording success. It does not reset sequences or
delete persisted telemetry or anomalies. An incompatible legacy definition fails
startup and rolls back V1 rather than rewriting data. Investigate the reported
object and prepare a reviewed, data-preserving reconciliation before retrying.

The dedicated history schema must be new or already managed by this application.
Automatic baselining is disabled: adoption executes and records V1 instead of
marking it as already applied. Do not enable `baseline-on-migrate`, use Flyway
`clean`, or drop existing schemas to work around a failure.

## Kubernetes

Supply a reachable PostgreSQL database before deploying the processor; these
manifests do not deploy PostgreSQL. Configure the URL in
`infrastructure/kubernetes/telemetry-processor/configmap.yaml` and provision real
credentials through `telemetry-processor-secret`, following that directory's
README. Network policies and database access rules must permit the connection.

Deploy the promoted processor image containing the migrations using the existing
release workflow. Each replica runs Flyway during startup. PostgreSQL migration
locking serializes competing migrators; subsequent replicas validate and skip
completed versions. No separate Job, init container, SQL ConfigMap, or manual
initialization is required. Inspect rollout and logs:

```bash
kubectl rollout status deployment/telemetry-processor --timeout=180s
kubectl logs deployment/telemetry-processor --tail=100
```

Migration failure exits the application and blocks readiness; inspect the failed
pod's logs (including `kubectl logs <pod> --previous` after a restart). Long
migrations may require adjusting rollout/probe timing. The deployment image pins
are updated by promotion, not by editing a digest alongside a schema change.

## Forward changes, failures, and rollback

Add immutable, ordered files such as `V2__add_metric_index.sql`; never edit an
applied migration. Flyway validates existing checksums before running pending
versions. Review schema changes with processor and query owners. For rolling
deployments, use additive changes compatible with both running application
versions; backfill separately, then remove obsolete objects only in a later
release after all readers and writers have moved.

PostgreSQL executes the current migration transactionally. On SQL failure, its
DDL/data changes roll back and the processor does not start. Earlier successful
migrations remain applied. Correct a migration that has never succeeded anywhere
and retry; once a version has succeeded in any environment, publish a new forward
migration instead. Checksum mismatches require restoring the original packaged
migration or investigating an unexpected database history change. Do not use
`repair` automatically or change checksums to conceal a mismatch. Future
nontransactional operations require a separate reviewed recovery procedure.

There are no automatic down migrations. An application rollback does not undo
database changes: roll back the image only when its code and migration validation
support the current schema. Flyway can reject a release whose migration set omits
already-applied versions. Prefer a forward fix; otherwise use a tested backup
restore with an explicit downtime and data-loss decision. Never remove history
rows or delete a volume as a rollback mechanism.

## Verification

With Docker running, run `./mvnw verify` (or `.\mvnw.cmd verify`) in every service.
The processor's `PostgresMigrationIntegrationTest` uses disposable PostgreSQL 16
Testcontainers databases and runs in the normal Maven/CI test lifecycle. Missing
Docker fails these tests instead of silently skipping them. It covers fresh
startup with real repository writes, repeated startup, adoption of populated
legacy tables, concurrent migrators, successful forward migration, rejection of
incompatible definitions/checksums, and transactional failure of a forward migration.
Existing H2 repository and HTTP tests remain
isolated from production migration SQL.

Container image validation also provisions and removes a disposable PostgreSQL
16 container and verifies that the exact processor image records successful V1.
It does not use a developer's persisted database.

References: [Spring Boot 3.3 database initialization](https://docs.spring.io/spring-boot/3.3/how-to/data-initialization.html),
[Flyway baseline behavior](https://documentation.red-gate.com/flyway/reference/configuration/flyway-namespace/flyway-baseline-on-migrate-setting).
