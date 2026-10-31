# Event contracts

The JSON Schema Draft 2020-12 files in this directory are the authoritative
wire contracts for PulseStream's JSON Kafka values. The schemas are self-contained
and use open objects so consumers can ignore unknown optional fields. No schema
registry, generated Java model library or service-to-service model dependency is
required. [ADR 0007](../docs/decisions/0007-json-event-contracts.md) records the choice.

Raw Kafka keys have a separate tenant/device ordering contract (#269), documented
in [anomaly detection](../docs/architecture/anomaly-detection.md). Both publishers
test `ordering-keys.json` vectors. Value schema versions and historical fixtures
are unchanged; changing partition keys requires a coordinated drain/cutover even
when the JSON value is structurally compatible.

| Kafka topic | Authoritative contract | Producers | Current consumers |
| --- | --- | --- | --- |
| `telemetry.events.raw` | [raw v1](schemas/raw/v1.schema.json) | ingestion, processor replay | processor |
| `telemetry.events.processed` | [processed v1](schemas/processed/v1.schema.json) | processor | external consumers; query uses PostgreSQL |
| `telemetry.events.anomalies` | [anomaly v1](schemas/anomaly/v1.schema.json) | processor | external consumers; query uses PostgreSQL |
| `telemetry.events.dlq` | [dead-letter v1](schemas/dead-letter/v1.schema.json) | ingestion and processor | processor replay |

## Fields and formats

Raw, processed and anomaly events require `eventId`, `tenantId`, `eventType`,
`timestamp`, `source`, `version` and `payload`. Identity/source strings are
nonblank; IDs are opaque strings, not necessarily UUIDs. Timestamps are RFC 3339
`date-time` strings, including offsets and fractional seconds. Format assertions
are enabled in the Java contract validator. Decimal readings are JSON numbers,
never quoted numeric strings. No temperature limits are enforced by the schema;
those remain detection rules.

Raw payloads require all six fields: `deviceId`, `deviceType`, `metric`, `value`,
`unit` and `location`. All strings are nonblank. Processed payloads require
nonblank `deviceId` and `metric` plus numeric `value`; metadata (`deviceType`,
`unit`, `location`) may be absent or null to represent historical readings that
predate HTTP validation. Anomaly payload fields may be absent or null because
missing readings are themselves anomalous. Envelope identity remains required:
failures to persist unidentified events follow the DLQ path.

Processed/anomaly `eventType` is fixed to `telemetry.processed`/`telemetry.anomaly`
and `source` to `telemetry-processor`. Anomalies additionally require `severity`
(`WARNING` or `CRITICAL`), a nonempty array of nonblank `reasons`, and a
`detectedAt` timestamp. `NONE` is an internal detection result, not an anomaly event.

DLQ values use their existing wrapper, not the telemetry envelope: required
`event` (object), `errorMessage` (nonblank), `sourceService` (`ingestion-service`
or `telemetry-processor`) and `failedAt` (`date-time`). New publishers include
`version: "1.0"`. An absent DLQ version means historical v1.0. The nested failed
event is deliberately unconstrained so malformed/unsupported telemetry is still
diagnosable. DLQ validity does not imply that the nested event is valid for raw
publication or replay. Both publishers use an independent JSON mapper if their
configured mapper fails; Java record text is no longer emitted to the DLQ.

## Versions and compatibility

The wire `version` is `MAJOR.MINOR`, retaining the existing `1.0` spelling. A
topic and major select `schemas/<contract>/v<major>.schema.json`. Each major
schema accepts numeric minor versions in that major (`1.0`, `1.1`, etc.). The
schema URI identifies the major's evolving compatible contract; it is not a
schema-registry address. Producers increment the minor when introducing optional
fields. Current processed/anomaly/DLQ producers emit their own `1.0`, independently
of the raw input's minor version. Replay preserves the nested raw version and
event identity. Replay metadata remains in Kafka headers.

Within a major, only optional property additions to open objects and documentation
annotation changes pass the automated gate. Existing properties, required sets,
types, nullability, formats, enums, constants, references, numeric/string/array
constraints and object openness are preserved. Removals and even some logically
safe validation relaxations require a new major under this conservative policy.
Unknown schema keyword changes fail closed. Adding an optional field assumes
its name has not already acquired conflicting semantics in a consumer extension;
owners must review names and meanings together. Semantic/unit/order changes also
require review because a structural validator cannot detect them.

For an incompatible change, add a new `v2.schema.json` with `version` accepting
`2.x`, leaving v1 unchanged. Add fixtures, adapt producers and consumers to the
new major, and document the rollout. Merely editing a v1 file's version pattern
or deleting v1 fails CI, even if v2 exists. A version bump alone does not make
existing consumers support a different payload structure.

## Validation and shared fixtures

[fixtures.json](fixtures.json) maps every shared JSON fixture to its supported
schema. No Java types cross service boundaries. Both event-producing services
copy this directory as Maven test resources and validate the schemas against
the Draft 2020-12 meta-schema, then validate fixtures with format assertions.
Their tests also capture actual raw, processed, anomaly, replay and DLQ publisher
values, including both fallback serialization paths, and validate serialized JSON.
Processor tests deserialize shared consumer fixtures using local model types and
production consumer settings, including foreign producer type headers and unknown
optional fields. Query-service reads projections and has no Kafka contract model.

Run the service checks from each service directory with `./mvnw verify` (Windows:
`.\mvnw.cmd verify`). The schema validator is a test-only dependency. Conformance
is a build gate; it does not add a runtime JSON Schema validator to Kafka listeners.
The HTTP boundary rejects unsupported raw event types and majors with 400 through
Bean Validation. Historical Kafka records retain the existing processing, failure
and replay behavior; this change neither rewrites nor retrospectively rejects them.

The existing CI repository sanity check also runs:

```sh
python3 -m unittest discover -s scripts/ci -p test_event_contracts.py
python3 scripts/ci/check-event-contracts.py --base-ref <base-commit>
```

The gate uses the PR base SHA, or the previous push SHA for main/dev. It compares
all previously published major schemas and fixtures from Git, independent of
current examples, and requires fixtures for every supported major. Missing Git
history or an invalid comparison ref fails the check. Existing fixtures and their
schema registrations are immutable compatibility promises; add new examples.
Initial introduction has no published schema to compare, while structural and
fixture validation still run. Regression cases exercise required/type/format,
enum, nested, reference, unknown-keyword, deletion and explicit-new-major changes.

## Evolution and deprecation process

1. Propose the schema change with topic, fields, meaning, units, version and
   consumer impact. The issue owner coordinates producer/consumer and replay review.
2. Add a fixture for each new behavior; preserve all previously published fixtures.
   Add producer serialization and consumer behavior tests when behavior changes.
3. Run compatibility and both services' Maven checks. Optional-field additions
   require tolerant consumers before producers begin emitting them.
4. For a new major, deploy readers that explicitly support both majors before
   switching writers. Coordinate external consumers; retain topic names and
   retention policies. A production schema registry is outside this increment.
5. Mark an old major deprecated with an owner, replacement, announcement date and
   proposed retirement date. Keep its schema and fixtures. Retirement requires
   evidence that all producers stopped using it, all consumers migrated, Kafka
   retention elapsed and retained DLQ/replay sources no longer need it. Keep the
   archived contract even after runtime support is retired through a reviewed change.

No major is currently deprecated. Live target-cluster rollout remains separate
from the repository's build-time contract validation.
