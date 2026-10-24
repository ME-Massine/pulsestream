## Local Docker Platform

This directory contains the `Docker Compose` setup used to run the `PulseStream` platform locally.

### Services

The local platform includes:

- `Kafka` (single KRaft node, no `ZooKeeper`)
- `PostgreSQL`
- `Redis`
- `Prometheus`
- `Grafana`
- `Jaeger`

### Files

- `docker-compose.yml` — local platform definition
- `.env.example` — example environment configuration
- `prometheus/prometheus.yml` — `Prometheus` configuration
- `grafana/provisioning/datasources/prometheus.yml` — `Grafana` datasource provisioning for `Prometheus`
- `../../services/telemetry-processor/src/main/resources/db/migration/` — versioned Flyway migrations for processed telemetry and anomalies, applied automatically when the processor starts. The manual `postgres/init.sql` path has been retired.
- `kafka/init-topics.sh` — Kafka topic creation script (runs at startup)
- `kafka/check-health.sh` — Kafka broker health-check script
- `../../scripts/validate-prometheus-metrics.ps1` — validates local ingestion-service metrics collection through `Prometheus`
- `../../scripts/validate-grafana-datasource.ps1` — validates the `Grafana` `Prometheus` datasource is healthy and returns query data
- `../../scripts/validate-kafka-dlq-topic.ps1` — validates the `telemetry.events.dlq` topic exists, is partitioned/replicated correctly, and follows the DLQ naming convention
- `../../scripts/validate-dlq-pipeline.ps1` — publishes a poison event and validates it is rerouted to `telemetry.events.dlq` end to end without crashing the processor
- `../../scripts/validate-event-replay.ps1` — seeds a DLQ record, triggers replay through the `dlqreplay` actuator endpoint, and validates the event is reprocessed successfully end to end
- `../../scripts/validate-distributed-tracing.ps1` — generates a request and validates the tracing flow across services through `Jaeger`

### Usage

Application services run on the host. The [query API setup](../../docs/api/processed-telemetry.md)
requires processor migrations first and a dedicated read-only PostgreSQL role.
Export `PULSESTREAM_POSTGRES_URL`, `PULSESTREAM_POSTGRES_USERNAME` and
`PULSESTREAM_POSTGRES_PASSWORD` to the query JVM; Compose's `.env` is not loaded
by host processes. Query readiness requires the database. Query requests require
an authenticated tenant principal from the Phase 7 integration and return 401
without it.

#### 1. Create environment file

Copy the example file:

```bash
cp .env.example .env
```

On `Windows PowerShell`:

```powershell
Copy-Item .env.example .env
```

#### 2. Start the platform

```bash
docker compose up -d
```

#### 3. Start the telemetry processor and initialize PostgreSQL

Application services run on the host. After PostgreSQL is healthy, run
`.\mvnw.cmd spring-boot:run` from `services/telemetry-processor` (`./mvnw` on Unix).
Flyway initializes a clean database or adopts the compatible legacy tables without
deleting rows. Migration failures prevent processor startup. Custom Compose
database settings must be exported as matching `PULSESTREAM_POSTGRES_*` variables
in the host shell. See [database migrations](../../docs/architecture/database-migrations.md)
for the shared local/Kubernetes process, forward changes, failures, and rollback.

#### 4. Stop the platform

```bash
docker compose down
```

#### 5. Stop and remove volumes (deletes persisted data)

```bash
docker compose down -v
```

### Exposed Ports

| Service    | Port |
| :--------- | :--- |
| Kafka      | 9092 |
| PostgreSQL | 5432 |
| Redis      | 6379 |
| Prometheus | 9090 |
| Grafana    | 3000 |
| Jaeger UI  | 16686 |
| Jaeger OTLP gRPC | 4317 |
| Jaeger OTLP HTTP | 4318 |

### PostgreSQL 18 upgrade

The `postgres` service runs `postgres:18`. PostgreSQL 18 images keep `PGDATA` in a
major-version subdirectory (`/var/lib/postgresql/18/docker`), so the Compose file mounts
the new `postgres18_data` volume at `/var/lib/postgresql`. Data files from a different
major version cannot be opened directly, so an existing PostgreSQL 16 environment
(`postgres_data` volume) moves over with a dump and restore. Run these commands from this
directory **before** pulling the PostgreSQL 18 change, while the version 16 container is
still defined:

```bash
docker compose up -d postgres
docker exec pulsestream-postgres pg_dumpall -U pulsestream --clean --if-exists > pulsestream-pg16.sql
docker compose stop postgres
```

Then, with the PostgreSQL 18 Compose file:

```bash
docker compose up -d postgres
docker exec -i pulsestream-postgres psql -U pulsestream -d postgres < pulsestream-pg16.sql
docker exec pulsestream-postgres psql -U pulsestream -d pulsestream -c "SELECT count(*) FROM platform.processed_telemetry;"
```

The restore reports that the current user cannot be dropped and that the `pulsestream`
role already exists; those messages are expected because the container creates the role
on first start. The old `postgres_data` volume is left untouched, so rolling
back only requires checking out the version 16 Compose file. Once the restored data is
verified, remove it with `docker volume rm pulsestream-local_postgres_data` and delete the
dump file. A fresh environment needs no migration: start the stack and apply
`postgres/init.sql` as described above.

### Kafka Broker Configuration

The broker is configured for local development with the following defaults:

| Setting | Value | Description |
| :------ | :---- | :---------- |
| `KAFKA_NODE_ID` | 1 | Single combined broker/controller node for local dev |
| `KAFKA_PROCESS_ROLES` | broker,controller | `KRaft` mode; the node is its own metadata quorum |
| `KAFKA_CLUSTER_ID` | `MkU3OEVBNTcwNTJENDM2Qk` | Cluster id used to format the `KRaft` log directory on first start |
| `KAFKA_NUM_PARTITIONS` | 3 | Broker default partition count |
| `KAFKA_LOG_RETENTION_HOURS` | 168 | 7-day message retention |
| `KAFKA_LOG_RETENTION_BYTES` | 1 GB | Max log size per partition |
| `KAFKA_MESSAGE_MAX_BYTES` | 10 MB | Maximum message size |
| `KAFKA_AUTO_CREATE_TOPICS_ENABLE` | false | Disable implicit topic creation; topics are created by `kafka-init` |
| `KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS` | 0 | Fast consumer group rebalance |

#### Topics

The `kafka-init` service automatically creates these topics on startup:

| Topic | Partitions | Retention | Purpose |
| :---- | :--------- | :-------- | :------ |
| `telemetry.events.raw` | 3 | 24 hours | Incoming raw events |
| `telemetry.events.processed` | 3 | 7 days | Processed/enriched events |
| `telemetry.events.anomalies` | 3 | 7 days | Detected anomaly events |
| `telemetry.events.dlq` | 1 | 7 days | Dead-letter queue for failed events |

Run the embedded health-check script to verify broker readiness:

```bash
docker exec pulsestream-kafka check-health
```

Alternatively, wait for the `Docker` health status to show `healthy`.

#### Kafka KRaft upgrade

The broker runs `confluentinc/cp-kafka` 8.x in `KRaft` mode. Confluent Platform 8 removed
`ZooKeeper` support, so the former `zookeeper` service and its volumes are gone, and the
broker stores its data in the new `kafka_kraft_data` volume. A `ZooKeeper`-mode log
directory cannot be reused by a `KRaft` node.

An existing local environment keeps its old volumes until they are removed. Messages
held in the old broker are not migrated; `kafka-init` recreates the topics on the next
start, and the processed results already live in `PostgreSQL`. To clean up after
upgrading:

```bash
docker compose down --remove-orphans
docker volume rm pulsestream-local_kafka_data pulsestream-local_zookeeper_data pulsestream-local_zookeeper_log
docker compose up -d
```

#### DLQ Topic Validation

The `kafka-init` container creates `telemetry.events.dlq` at startup. Confirm it exists with the expected configuration by running the validation script from the repository root:

```powershell
.\scripts\validate-kafka-dlq-topic.ps1
```

The script runs `kafka-topics --describe` against the running broker and checks that:

- the `telemetry.events.dlq` topic is visible via the Kafka CLI
- it has 1 partition and a replication factor of 1
- its name follows the `<domain>.<entity>.dlq` naming convention from [`docs/architecture/topics.md`](../../docs/architecture/topics.md)

#### DLQ Pipeline Validation

The topic check above confirms the DLQ *exists*; this flow confirms the DLQ is actually *fed* when processing fails. After starting the platform and the `telemetry-processor`, run the validation script from the repository root:

```powershell
.\scripts\validate-dlq-pipeline.ps1
```

The script publishes a poison event to `telemetry.events.raw` — valid JSON that deserializes into the processor's event type but carries a `null` payload, so normalization fails and the consumer reroutes it. Using the `Kafka` CLI against the running broker, it then checks that:

- `telemetry-processor` reports `UP` before the event is published (so it is consuming)
- the failed event appears in `telemetry.events.dlq`, located by its unique `eventId`
- the DLQ record's routing metadata confirms the reroute: `sourceService` is `telemetry-processor` and a non-empty `errorMessage` captures the failure reason
- the processor's logs confirm the reroute: its log file contains the `Routed failed telemetry event to DLQ ... eventId=<id>` line for this event
- `telemetry-processor` is still `UP` afterwards, i.e. the failure did not crash it

> The log assertion reads `telemetry-processor`'s log file directly from disk, so the processor must be started with a log file configured — for example by setting the standard Spring Boot property when you launch it:
>
> ```powershell
> $env:LOGGING_FILE_NAME = "logs/telemetry-processor.log"; .\mvnw.cmd spring-boot:run
> ```
>
> The script defaults to `services/telemetry-processor/logs/telemetry-processor.log`; point `-ProcessorLogFile` at another path if you configured a different location. This keeps logs off any unauthenticated HTTP endpoint — no actuator or service configuration change is required.

Override the defaults with `-KafkaContainer`, `-BootstrapServer`, `-ProcessorManagementBaseUrl`, and `-ProcessorLogFile` if you changed the local container name, management port, or log location.

> The poison event exercises the **processor** DLQ path, which is the path that deposits records into the topic in a running system. The `ingestion-service` DLQ path only fires when the raw-topic publish itself fails (e.g. the broker is down); in that state the DLQ publish would fail too, so it cannot be validated end to end against a healthy broker. Invalid events sent to the ingestion API are rejected with `400` by request validation *before* any publish and never reach the DLQ.

#### Event Replay Validation

The two flows above confirm the DLQ *exists* and is *fed*; this flow confirms an event can be recovered from it. After starting the platform and the `telemetry-processor`, run the validation script from the repository root:

```powershell
.\scripts\validate-event-replay.ps1
```

The script seeds `telemetry.events.dlq` directly with a record wrapping a *valid* `TelemetryEvent` — standing in for an event that failed once (e.g. a since-fixed downstream issue) and is now safe to reprocess — then triggers a selective replay for that event's id through the `dlqreplay` actuator endpoint (see [event-replay-strategy.md](../../docs/architecture/event-replay-strategy.md)). It checks that:

- `telemetry-processor` reports `UP` before the replay is triggered
- the trigger response reports the event's id as selected for replay (the response itself is asserted rather than polling for a transient `running` state — a single-record replay can finish before the first status poll)
- the processor's logs confirm the DLQ record was picked up for replay (`Replaying selected DLQ event ... eventId=<id>`)
- the event is republished onto `telemetry.events.raw` with its original payload intact, and the logs confirm it (`Republished replayed event to raw topic ... eventId=<id>`)
- the republished event is then **processed successfully** downstream (`Processed normal telemetry event ... eventId=<id>`) — this is the actual reprocessing assertion, since the two checks above only cover republishing and happen before the raw-topic consumer has processed the record
- the event does not land back in `telemetry.events.dlq` — a supplementary replay-loop guard only. Because the replay path deliberately does not publish a second DLQ record on failure (the original record stays the single retry source), an unchanged DLQ count does **not** by itself establish that reprocessing succeeded
- the replay listener stops itself again once it drains the backlog, and `telemetry-processor` is still `UP` — i.e. the replay did not crash the system

> Like `validate-dlq-pipeline.ps1`, this script reads `telemetry-processor`'s log file directly from disk (`-ProcessorLogFile`, defaulting to `services/telemetry-processor/logs/telemetry-processor.log`) and talks to the processor's actuator endpoints on the dedicated management port (`-ProcessorManagementBaseUrl`, defaulting to `http://localhost:9083` — see the `dlqreplay` endpoint in the processor's `application.yml`). Override `-KafkaContainer`, `-BootstrapServer`, or the topic names if you changed the local container name, ports, or topics.

### Prometheus Metrics Validation

Use this flow to validate that `Prometheus` can scrape `ingestion-service` metrics end to end.

1. Start the local platform from this directory:

   ```bash
   docker compose up -d
   ```

2. Start `ingestion-service` from the repository root in a separate terminal:

   ```powershell
   cd services\ingestion-service
   .\mvnw.cmd spring-boot:run
   ```

3. Run the validation script from the repository root after the service is listening on port `8081`:

   ```powershell
   .\scripts\validate-prometheus-metrics.ps1
   ```

The script checks that:

- `ingestion-service` reports `UP` from `/actuator/health`
- `/actuator/prometheus` exposes key service metrics
- `Prometheus` has an active `ingestion-service` target
- the target is `up` with no scrape errors
- `up`, `jvm_info`, `process_uptime_seconds`, and `application_ready_time_seconds` are queryable for the `ingestion-service` job

You can also verify the same result in the `Prometheus` UI at `http://localhost:9090/targets`; the `ingestion-service` target should be `UP` and show no scrape error. In the graph view, query `up{job="ingestion-service"}` and confirm it returns `1`.

### Grafana

Grafana is available at `http://localhost:3000` by default, or at the port configured by `GRAFANA_PORT`.

Default local credentials are:

| Setting | Default |
| :------ | :------ |
| Username | `admin` |
| Password | `admin` |

The `Prometheus` datasource is provisioned automatically as the default datasource (`uid: prometheus`) and points to `http://prometheus:9090` on the internal Docker network. Its `timeInterval` matches the `Prometheus` scrape interval (`15s`) so range queries request data at the resolution `Prometheus` stores.

#### Datasource Validation

After starting the platform, confirm the datasource is healthy and can return data by running the validation script from the repository root:

```powershell
.\scripts\validate-grafana-datasource.ps1
```

The script authenticates against the local `Grafana` API and checks that:

- the `Prometheus` datasource is provisioned as the default datasource
- `GET /api/datasources/uid/prometheus/health` reports status `OK`
- an `up` query run through the datasource resources API (`/api/datasources/uid/prometheus/resources/api/v1/query`) returns data

Override the defaults with `-GrafanaBaseUrl`, `-GrafanaUser`, and `-GrafanaPassword` if you changed the local `Grafana` port or credentials. You can also verify manually in the `Grafana` UI under `Connections > Data sources > Prometheus`; the `Save & test` button should report the datasource is working.

#### Dashboards

Dashboard JSON is version-controlled under [`observability/grafana/dashboards`](../../observability/grafana/dashboards) as the single source of truth. The Compose file mounts that directory into the `Grafana` container at `/etc/grafana/dashboards`, and the file provider in `grafana/provisioning/dashboards/dashboards.yml` loads every dashboard into the `PulseStream` folder on startup. See the [dashboards README](../../observability/grafana/dashboards/README.md) for the list of dashboards and instructions on re-importing or exporting changes.

#### Prometheus 3 and Grafana 13 upgrade

The stack runs `prom/prometheus:v3.15.0` and `grafana/grafana:13.2.3` (the version the
Kubernetes Grafana Deployment already uses). Both reuse their existing volumes:

- `Prometheus` 3 reads the TSDB written by 2.x, so metrics collected before the upgrade
  stay queryable. The committed scrape configuration and every dashboard query work
  unchanged.
- `Grafana` migrates `grafana.db` in `grafana_data` on first start, keeping users,
  datasources, and dashboards created in the UI. Provisioned dashboards reload from
  `observability/grafana/dashboards`.

Neither migration can be reversed by switching the image back: `Grafana` does not support
downgrading a migrated database, and `Prometheus` supports downgrading a
version 3 TSDB only to 2.55 or later. Back up both volumes before upgrading an existing
environment:

```bash
docker compose stop prometheus grafana
docker run --rm -v pulsestream-local_grafana_data:/data:ro -v "$PWD":/backup alpine tar czf /backup/grafana-data.tgz -C /data .
docker run --rm -v pulsestream-local_prometheus_data:/data:ro -v "$PWD":/backup alpine tar czf /backup/prometheus-data.tgz -C /data .
```

To roll back, stop both services, restore each archive into an emptied volume (`tar xzf`
with the same mounts), and check out the previous Compose file. In Git Bash on Windows,
prefix the `docker run` commands with `MSYS_NO_PATHCONV=1` so `/backup` is not rewritten
to a Windows path.

### Jaeger

`Jaeger` is the local distributed tracing backend. The all-in-one container runs the collector, storage, and query UI in a single process, with the OTLP receiver enabled via `COLLECTOR_OTLP_ENABLED`.

The `Jaeger` UI is available at `http://localhost:16686` by default, or at the port configured by `JAEGER_UI_PORT`.

Both services export traces over OTLP to `Jaeger`:

| Endpoint | Port | Used by |
| :------- | :--- | :------ |
| OTLP gRPC | 4317 | OpenTelemetry exporters (gRPC) |
| OTLP HTTP | 4318 | OpenTelemetry exporters (HTTP/protobuf) |

`ingestion-service` and `telemetry-processor` are instrumented with the OpenTelemetry Spring Boot starter and default to exporting traces to `http://localhost:4318` (OTLP HTTP). Because the services run on the host rather than in `Docker Compose`, they reach the container through the published host port. Override the target with `PULSESTREAM_OTEL_EXPORTER_OTLP_ENDPOINT`, or set `PULSESTREAM_OTEL_TRACES_EXPORTER=console` to fall back to console export.

To verify traces end to end:

1. Start the local platform (`docker compose up -d`) and confirm the `pulsestream-jaeger` container is running.
2. Start `ingestion-service` (and optionally `telemetry-processor`) from the repository root.
3. Send traffic to the service, then open `http://localhost:16686`, select the `ingestion-service` service, and search for traces.

#### Tracing Validation

After starting the platform and both services, confirm the tracing flow across
components by running the validation script from the repository root:

```powershell
.\scripts\validate-distributed-tracing.ps1
```

The script generates a telemetry request and, using the `Jaeger` query API,
checks that:

- `ingestion-service` reports `UP` and the `Jaeger` query API is reachable
- the generated request produces a visible ingestion trace (located by its
  `pulsestream.event.id` tag) that contains no missing spans — the HTTP server
  span, the `TelemetryController.ingestTelemetry` application span, and the
  `Kafka` producer span
- `telemetry-processor` registers with `Jaeger` and emits its own consumer trace
  after consuming the published event

Because trace context is currently propagated over HTTP only, the
`telemetry-processor` spans form a separate trace rather than joining the
ingestion trace across the `Kafka` boundary; the script validates each service's
spans independently. Override the defaults with `-IngestionBaseUrl` and
`-JaegerBaseUrl` if you changed the local ports. You can also verify manually in
the `Jaeger` UI at `http://localhost:16686` by searching for both the
`ingestion-service` and `telemetry-processor` services.

### Notes

- `Kafka` is exposed on `localhost:9092` for local development.
- Internal `Docker` network communication uses the `kafka:29092` listener.
- Topics are created by the `kafka-init` one-shot container, which exits after completion.
- `Prometheus` scrapes `ingestion-service` (`host.docker.internal:8081/actuator/prometheus`) at a 15s interval, in addition to itself. The service runs on the host, not in `Docker Compose`, so `extra_hosts` maps `host.docker.internal` to the host gateway.
- `Grafana` uses the credentials defined in `.env`, persists data in the `grafana_data` volume, and provisions `Prometheus` as its default datasource.
- `Jaeger` runs as an all-in-one container with the OTLP receiver enabled; traces are stored in memory and reset when the container restarts.
- `Kafka topics` are managed manually or via scripts defined in the project and follow the naming convention `telemetry.events.*`.
