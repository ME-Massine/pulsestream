# Container Image Validation

Repeatable local check that every platform service **image builds** and the
resulting **container starts and reports healthy** before any Kubernetes work
begins. This is the gate that proves the images from the
[Container Build Standard](container-build-standard.md) actually run.

Out of scope: registry publishing and Kubernetes deployment.

---

## What is validated

| Service              | Image tag                      | Health endpoint (in container) |
| -------------------- | ------------------------------ | ------------------------------ |
| ingestion-service    | `pulsestream/ingestion-service:local`   | `:8081/actuator/health` |
| telemetry-processor  | `pulsestream/telemetry-processor:local` | `:9083/actuator/health` (management port) |
| query-service        | `pulsestream/query-service:local`       | `:8083/actuator/health` |

For each service the validation:

1. Builds the image locally with `docker build`.
2. Runs the container on the selected Docker network. Processor and query validation
   provision a disposable PostgreSQL 16 container on that network, including
   when `-Network bridge` is used in CI.
   Query validation prepares its database with the canonical processor migration
   before startup; the query image itself contains no migration runner.
3. Polls `/actuator/health` until it reports `UP` (readiness confirmation).
4. Verifies successful migration V1 for the processor and tears down the service
   and disposable database containers, including the database's anonymous data
   volume, on success or failure.

`telemetry-processor` serves its actuator surface on a separate, loopback-bound
management port (`9083`) — see its `application.yml`. Validation sets
`PULSESTREAM_MANAGEMENT_ADDRESS=0.0.0.0` so the published health port is
reachable from the host. This override is for local validation only.

---

## Prerequisites

- Docker running.
- The local infrastructure stack up when using the default platform network:

  ```powershell
  docker compose -f infrastructure/docker/docker-compose.yml up -d
  ```

  Confirm the network name the stack created (the script defaults to
  `pulsestream-local_pulsestream-net`):

  ```powershell
  docker network ls
  ```

---

## Run the validation

From the repository root:

```powershell
# Build and validate all three service images
./scripts/validate-container-images.ps1

# Validate a single service
./scripts/validate-container-images.ps1 -Services telemetry-processor

# Re-validate already-built images without rebuilding
./scripts/validate-container-images.ps1 -SkipBuild
```

A run passes only when every targeted image builds, its container stays running,
and its health endpoint reports `UP`. On success:

```
[ok] All targeted service images built, started, and reported healthy.
```

If a container exits before becoming healthy, the script prints its recent logs
and fails, so the startup error is visible.

---

## Manual equivalent (single service)

For a standalone query image run, initialize PostgreSQL through the processor
first and export `PULSESTREAM_POSTGRES_URL`, `PULSESTREAM_POSTGRES_USERNAME` and
`PULSESTREAM_POSTGRES_PASSWORD` with a read-only query login. The URL must be
reachable from the container (use `host.docker.internal` for host PostgreSQL).
The scripted validator provisions its own disposable database instead.

```powershell
# 1. Build
docker build -t pulsestream/query-service:local services/query-service

# 2. Run on the platform network, publishing the health port
#    (host port 19084 matches what validate-container-images.ps1 uses)
docker run -d --name pulsestream-validate-query-service `
  --network pulsestream-local_pulsestream-net `
  -e PULSESTREAM_POSTGRES_URL -e PULSESTREAM_POSTGRES_USERNAME `
  -e PULSESTREAM_POSTGRES_PASSWORD `
  -p 19084:8083 pulsestream/query-service:local

# 3. Verify health
curl http://localhost:19084/actuator/health   # expect {"status":"UP"}

# 4. Tear down
docker rm -f pulsestream-validate-query-service
```
