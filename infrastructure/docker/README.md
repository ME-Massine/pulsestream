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

### Files

- `docker-compose.yml` — local platform definition
- `.env.example` — example environment configuration
- `prometheus/prometheus.yml` — `Prometheus` configuration
- `postgres/init.sql` — `PostgreSQL` schema script for processed telemetry and anomalies. The current Compose file does not mount this file into `/docker-entrypoint-initdb.d`, so apply it manually or add a mount before relying on automatic schema creation.
- `kafka/init-topics.sh` — Kafka topic creation script (runs at startup)
- `kafka/check-health.sh` — Kafka broker health-check script

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

### Notes

- `Kafka` is exposed on `localhost:9092` for local development.
- Internal `Docker` network communication uses the `kafka:29092` listener.
- Topics are created by the `kafka-init` one-shot container, which exits after completion.
- `Prometheus` scrapes `ingestion-service` (`host.docker.internal:8081/actuator/prometheus`) at a 15s interval, in addition to itself. The service runs on the host, not in `Docker Compose`, so `extra_hosts` maps `host.docker.internal` to the host gateway.
- `Grafana` uses the credentials defined in `.env`.
- `Kafka topics` are managed manually or via scripts defined in the project and follow the naming convention `telemetry.events.*`.
