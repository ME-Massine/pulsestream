# ADR 0007: Version JSON Kafka contracts with JSON Schema

Status: Accepted for issue [#268](https://github.com/ME-Massine/pulsestream/issues/268).

## Context

PulseStream transports JSON Kafka values and has independent Java records in
ingestion and processor. Markdown examples cannot prevent structural drift.
Both services publish the same DLQ wrapper; replay must continue to read historical
envelopes. A production schema registry and a serialization migration are outside
this increment.

## Decision

Use self-contained JSON Schema Draft 2020-12 files under `contracts/schemas`, one
per topic and major, and language-neutral JSON fixtures shared by service tests.
Keep JSON transport and the existing topic names. Use the existing `MAJOR.MINOR`
version field; absent historical DLQ versions mean v1.0. Add `version` to new DLQ
output without changing its existing wrapper shape.

Validate actual publisher serialization and consumer fixtures in Maven using
NetworkNT's Jackson 3 validator with format assertions enabled. Keep this dependency
in test scope. Compare committed schema history against the PR base in the existing
CI repository sanity check. The comparator permits optional additions and annotation
changes within a major; other structural changes require a new major and retention
of previous schemas. It intentionally favors a conservative policy over attempting
general JSON Schema language-inclusion proofs.

Consumers ignore unknown fields at both envelope and payload levels. They use
local Java models; no service imports another service's internal package. Raw
HTTP types/versions are constrained by Bean Validation. Kafka historical failure
and replay handling remains in place.

## Consequences

Schema changes, fixtures and tests become reviewable contracts enforced in CI.
The DLQ remains JSON even if a configured mapper fails. Processed/anomaly outputs
declare their producer's version rather than inheriting an input minor version.
The invalid-event portion of a DLQ wrapper remains opaque by design.

The gate cannot infer semantic compatibility, external consumer support or safe
retirement dates. Producer/consumer/replay owners must jointly review evolution
and major migrations. Current schemas and fixtures remain available for historical
recovery. Runtime schema registration/validation and Avro/Protobuf remain separate
decisions. See [the contract policy](../../contracts/README.md) for operating details.
