## Local Docker Platform

This directory contains the `Docker Compose` setup used to run the `PulseStream` platform locally.

### Services

The local platform includes:

- `Zookeeper`
- `Kafka`
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
- `postgres/init.sql` — `PostgreSQL` schema script for processed telemetry and anomalies. The current Compose file does not mount this file into `/docker-entrypoint-initdb.d`, so apply it manually or add a mount before relying on automatic schema creation.
- `kafka/init-topics.sh` — Kafka topic creation script (runs at startup)
- `kafka/check-health.sh` — Kafka broker health-check script
- `../../scripts/validate-prometheus-metrics.ps1` — validates local ingestion-service metrics collection through `Prometheus`
- `../../scripts/validate-grafana-datasource.ps1` — validates the `Grafana` `Prometheus` datasource is healthy and returns query data
- `../../scripts/validate-kafka-dlq-topic.ps1` — validates the `telemetry.events.dlq` topic exists, is partitioned/replicated correctly, and follows the DLQ naming convention
- `../../scripts/validate-dlq-pipeline.ps1` — publishes a poison event and validates it is rerouted to `telemetry.events.dlq` end to end without crashing the processor
- `../../scripts/validate-distributed-tracing.ps1` — generates a request and validates the tracing flow across services through `Jaeger`

### Usage

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

#### 3. Stop the platform

```bash
docker compose down
```

#### 4. Stop and remove volumes

```bash
docker compose down -v
```

### Exposed Ports

| Service    | Port |
| :--------- | :--- |
| Zookeeper  | 2181 |
| Kafka      | 9092 |
| PostgreSQL | 5432 |
| Redis      | 6379 |
| Prometheus | 9090 |
| Grafana    | 3000 |
| Jaeger UI  | 16686 |
| Jaeger OTLP gRPC | 4317 |
| Jaeger OTLP HTTP | 4318 |

### Kafka Broker Configuration

The broker is configured for local development with the following defaults:

| Setting | Value | Description |
| :------ | :---- | :---------- |
| `KAFKA_BROKER_ID` | 1 | Single broker for local dev |
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
- the processor's logs confirm the reroute: the `logfile` actuator endpoint contains the `Routed failed telemetry event to DLQ ... eventId=<id>` line for this event
- `telemetry-processor` is still `UP` afterwards, i.e. the failure did not crash it

> The log assertion reads `telemetry-processor`'s logs over the `logfile` actuator endpoint, so the service must be configured to write a log file (the default `logging.file.name` in `application.yml` does this). Override the path with `PULSESTREAM_LOG_FILE` if needed.

Override the defaults with `-KafkaContainer`, `-BootstrapServer`, and `-ProcessorBaseUrl` if you changed the local container name or ports.

> The poison event exercises the **processor** DLQ path, which is the path that deposits records into the topic in a running system. The `ingestion-service` DLQ path only fires when the raw-topic publish itself fails (e.g. the broker is down); in that state the DLQ publish would fail too, so it cannot be validated end to end against a healthy broker. Invalid events sent to the ingestion API are rejected with `400` by request validation *before* any publish and never reach the DLQ.

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
