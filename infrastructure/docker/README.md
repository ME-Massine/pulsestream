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

### Notes

- `Kafka` is exposed on `localhost:9092` for local development.
- Internal `Docker` network communication uses the `kafka:29092` listener.
- `Prometheus` is initialized with a minimal configuration and will be extended when application services are added.
- `Grafana` uses the credentials defined in `.env`.
- `PostgreSQL` is initialized with the PulseStream platform schema and initial tables for telemetry and anomalies.
- The `postgres/init.sql` script is executed when the container starts for the first time.
- The platform uses the `platform` schema to store processed events.
