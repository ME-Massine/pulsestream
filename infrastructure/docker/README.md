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
- `postgres/init.sql` — `PostgreSQL` initialization (schema and tables)
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
| `KAFKA_NUM_PARTITIONS` | 3 | Default partitions for auto-created topics |
| `KAFKA_LOG_RETENTION_HOURS` | 168 | 7-day message retention |
| `KAFKA_LOG_RETENTION_BYTES` | 1 GB | Max log size per partition |
| `KAFKA_MESSAGE_MAX_BYTES` | 10 MB | Maximum message size |
| `KAFKA_AUTO_CREATE_TOPICS_ENABLE` | true | Allow auto topic creation |
| `KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS` | 0 | Fast consumer group rebalance |

#### Topics

The `kafka-init` service automatically creates these topics on startup:

| Topic | Partitions | Retention | Purpose |
| :---- | :--------- | :-------- | :------ |
| `pulsestream.events.raw` | 3 | 7 days | Incoming raw events |
| `pulsestream.events.processed` | 3 | 7 days | Processed/enriched events |
| `pulsestream.events.failed` | 1 | 30 days | Dead-letter queue |
| `pulsestream.notifications` | 2 | 3 days | Alert notifications |
| `pulsestream.metrics` | 2 | 1 day | Internal metrics |

Run the embedded health-check script to verify broker status and topic availability:

```bash
docker exec pulsestream-kafka check-health
```

Alternatively, wait for the `Docker` health status to show `healthy`.

### Notes

- `Kafka` is exposed on `localhost:9092` for local development.
- Internal `Docker` network communication uses the `kafka:29092` listener.
- Topics are created by the `kafka-init` one-shot container, which exits after completion.
- `Prometheus` is initialized with a minimal configuration and will be extended when application services are added.
- `Grafana` uses the credentials defined in `.env`.
- `PostgreSQL` is initialized with the PulseStream platform schema and initial tables for telemetry and anomalies.
- The `postgres/init.sql` script is executed when the container starts for the first time.
- The platform uses the `platform` schema to store processed events.
