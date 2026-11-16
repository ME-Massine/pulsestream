# Query service

The internal ClusterIP service exposes processed telemetry and anomaly queries on port 8083.
See [the API and operating contract](../../../docs/api/processed-telemetry.md)
for tenant identity, filters, response schemas, database grants and health policy.
The [anomaly API](../../../docs/api/anomalies.md) additionally requires Flyway V2
and SELECT on the anomalies table.

1. Provision PostgreSQL at `postgres:5432` in the platform namespace, or adapt
   the ConfigMap URL and NetworkPolicy for the actual destination.
2. Start the telemetry processor and confirm successful schema migrations.
3. Create a dedicated query login with CONNECT, schema USAGE and SELECT on
   `platform.processed_telemetry` and `platform.anomalies` only.
4. Provision `query-service-secret` out of band with
   `PULSESTREAM_POSTGRES_USERNAME` and `PULSESTREAM_POSTGRES_PASSWORD` as shown in
   `secret.example.yaml`. Never apply or commit placeholder or real credentials.
5. Apply the ConfigMap, Deployment, Service and query NetworkPolicy.

`/readyz` requires database connectivity; `/livez` does not. The API requires an
authenticated servlet principal supplied by the Phase 7 integration and returns
401 until one is installed. The deployment does not expose an external route or
trust forwarded tenant headers. Promote new images through the existing release
workflow; image references are unchanged by this implementation.

## Replay classification (#271)

Authoritative event classifications and Flyway V6 now reconcile all replay
transitions. Processed/anomaly writers emit v2 UPSERT/RETRACT values on existing
topics; raw/DLQ contracts and published v1 fixtures remain available. Query readers
require V6 and SELECT on `platform.event_classifications`. See [the classification
contract](../../../docs/architecture/replay-reclassification.md) for revisions, unresolved legacy conflicts, bounded
replay, consumer migration and the coordinated paused/drained cutover.
