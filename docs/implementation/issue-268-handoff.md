# Issue #268 implementation handoff

Owner: `@ME-Massine`.
Issue: [#268](https://github.com/ME-Massine/pulsestream/issues/268).
Branch: `feature/268-versioned-event-contracts`, based on `0fd9a31`
(`feat(anomalies): persist and query detected anomalies`).
No repository commit, push, PR creation, merge or publication was performed.

## Outcome

All four platform Kafka topics have authoritative JSON Schema Draft 2020-12 v1
contracts. Shared language-neutral fixtures cover producer/consumer compatibility,
minor-version optional extensions, historical DLQ envelopes, both DLQ producers,
invalid nested failed events, missing processed metadata and missing anomaly
readings. No service depends on another service's internal Java model package.

Maven tests validate schemas against their meta-schema, all registered fixtures
against their declared contract, and actual raw/processed/anomaly/replay/DLQ
publisher JSON. Both DLQ publishers retain valid JSON through configured-mapper
failures. Consumers ignore optional envelope/payload additions. Ingestion accepts
compatible `1.x` extensions and returns 400 for unsupported majors/event types.

CI's existing Repository sanity checks context compares schemas and immutable
fixtures with the PR base or previous push SHA. Same-major changes preserve all
existing validation rules and fields; optional additions and documentation edits
are allowed. Breaking changes require a new major schema while retaining old
schemas and fixtures. The required check names and branch ruleset are unchanged.

The [contract policy](../../contracts/README.md) defines required/optional fields,
formats, version mapping, evolution, rollout and deprecation. [ADR 0007](../decisions/0007-json-event-contracts.md)
records the format decision. Architecture Markdown links to authoritative schemas.

## Ownership and contracts

Owner: @ME-Massine. C-xx IDs: none assigned in #268.
Related IDs: #254 (Phase 7), #265 (migrations), #266/#267 (projection query APIs),
#270 (PostgreSQL/Kafka delivery), #271 (replay reclassification).

Shared files: `.github/workflows/ci.yml`, CONTRIBUTING.md, PROJECT_STATE.md,
README.md, `docs/architecture/event-schema.md`, `docs/architecture/topics.md`,
`docs/decisions/README.md`, `docs/roadmap.md`, the new `contracts/` tree and
`scripts/ci/check-event-contracts.py` / `test_event_contracts.py`. Both event-producing
service POMs, boundary/wire types, publishing paths and contract tests also change.
Query-service production code and its Kafka responsibilities do not change.

Joint review required before merge: ingestion/API, processor/replay, event-contract
consumers and CI/platform owners. Joint review remains pending. Structural gates
cannot establish semantic/unit compatibility or external consumer readiness.

## Validation

| Check | Result |
| --- | --- |
| Java 25 ingestion Maven `verify` | Passed: 28 tests; no failures/skips; coverage floors unchanged |
| Java 25 processor Maven `verify` | Passed: 164 tests; no failures/skips; PostgreSQL migration/projection tests included |
| Java 25 query Maven `verify` | Passed: 49 tests; no failures/skips; PostgreSQL repository/API tests included |
| Coverage | Ingestion 90.24% lines / 57.14% branches; processor 94.86% / 78.67%; query 98.82% / 97.50% |
| Compatibility-policy regression tests | Passed: 4 tests, including nested/type/format/required/enum/reference/unknown-keyword changes, optional additions, retained/new major and schema/fixture deletion |
| Compatibility gate against `HEAD` (`0fd9a31`) | Passed; initial schema introduction has no prior schemas |
| PowerShell 7.5.4 offline suite | Passed: 56 parsed sources, 18 test files; no failures/skips |
| Windows PowerShell 5.1 offline suite | Passed: 56 parsed sources, 18 test files; no failures/skips |
| Docker Compose configuration | Passed |
| `git diff --check` | Passed |
| Live target-cluster rollout | Not run; remains pending |

Maven used the local Java 25 JDK matching service POMs and ADR 0006. Reports are
under each service's `target/surefire-reports` and `target/site/jacoco`; command
logs are under `$env:TEMP/pulsestream-268-*-verify.log`. Python checks ran in the
cached `node:24-bookworm` image with a read-only repository mount and bytecode
output disabled. The Python comparator has no third-party package dependency.
Contract validation uses NetworkNT 3.0.7 only in Maven test scope.

## Operating effects

- New HTTP ingestion accepts only `telemetry.reading` and numeric `1.x` versions.
  Unsupported types/majors now return 400. Unknown optional fields remain accepted.
- Processed/anomaly outputs declare the emitting producer's `1.0` schema rather
  than inheriting the raw minor version. Replay preserves raw identity/version;
  existing Kafka replay headers remain unchanged.
- New DLQ wrappers include `version: "1.0"`. Historical unversioned JSON wrappers
  remain readable. Independent JSON fallback replaces non-JSON record text.
  Previously written non-JSON fallback records are not rewritten by this change.
- A valid DLQ wrapper can contain invalid telemetry. Validate/correct its nested
  event before replay; DLQ validity alone does not guarantee replay success.
- Schema conformance is enforced during builds. No runtime schema registry or
  Kafka JSON Schema validator is introduced. Historical processing and failure
  routing remain in place; external consumers still require coordinated major
  migrations and semantic review.
- Topic names, partitions, retention, database migrations, image references and
  coverage floors remain unchanged. Authentication and delivery/reclassification
  work remains under its existing issues. Phase 6 live validation remains open.

## Developer Git commands

Review the diff before staging. The three existing `mvnw.cmd` changes and
untracked `AGENTS.md` / `Claude.md` predate this issue and are excluded below.
Confirm the base branch contains prerequisite `0fd9a31` before creating the PR.

```powershell
git switch feature/268-versioned-event-contracts
git diff --check
git diff --stat
git add -- .github/workflows/ci.yml CONTRIBUTING.md PROJECT_STATE.md README.md `
    contracts docs/architecture/event-schema.md docs/architecture/topics.md `
    docs/decisions/0007-json-event-contracts.md docs/decisions/README.md `
    docs/roadmap.md docs/implementation/issue-268-handoff.md `
    scripts/ci/check-event-contracts.py scripts/ci/test_event_contracts.py `
    services/ingestion-service/pom.xml services/ingestion-service/src `
    services/telemetry-processor/pom.xml services/telemetry-processor/src
git diff --cached --stat
git commit -m "feat(contracts): version Kafka event schemas and enforce compatibility"
git push -u origin feature/268-versioned-event-contracts
# Save the PR text below in the specified file before running:
gh pr create --draft --base main `
    --title "feat(contracts): version Kafka event schemas and enforce compatibility" `
    --body-file "$env:TEMP/pulsestream-268-pr.md"
```

## Copy-ready PR text

```markdown
## Summary
Kafka raw, processed, anomaly and dead-letter JSON values now have authoritative
versioned JSON Schema contracts. Shared fixtures and producer/consumer tests
prevent model drift. CI rejects incompatible edits to published major schemas;
new majors retain old contracts and fixtures.

## Related Issue
Closes #268. Phase: #254. Related foundations: #265, #266 and #267.
Delivery/reclassification work remains #270/#271.

## Issue Requirements Covered
- JSON Schema Draft 2020-12 contracts for every current topic, with explicit
  required/optional fields, formats and major/minor version mapping.
- Shared fixtures and actual raw/processed/anomaly/replay/DLQ publisher validation.
- Consumer compatibility checks, optional-field tolerance and foreign type headers.
- One DLQ contract for both producers, including valid JSON serialization fallback
  and historical unversioned wrappers.
- Git-baseline compatibility gate, regression cases, evolution/deprecation policy
  and authoritative schema links from architecture Markdown.
- Independent service model packages; no shared internal model dependency.

## Ownership and contracts
Owner: @ME-Massine. C-xx IDs: none assigned in #268.
Shared files: contracts/, CI workflow, contribution/project-state/README,
architecture/topics/ADR index/roadmap docs and CI compatibility scripts.
Joint review required: ingestion/API, processor/replay, event consumers and
CI/platform owners. Joint review is pending. Review semantic/unit compatibility
and external consumer migration separately from structural validation.

## Testing
- Java 25 Maven verify: ingestion 28, processor 164 and query 49 tests passed;
  no failures/skips; PostgreSQL tests included; coverage floors unchanged.
- JaCoCo line/branch coverage: ingestion 90.24%/57.14%, processor 94.86%/78.67%,
  query 98.82%/97.50%.
- Four compatibility-policy regression tests and the gate against 0fd9a31 passed.
- Offline PowerShell checks passed on 7.5.4 and Windows 5.1: 56 parsed sources,
  18 regression files, no failures/skips on each edition.
- Compose configuration and git diff --check passed.
- Live target-cluster rollout remains pending.

## Operating effects
HTTP ingestion returns 400 for unsupported raw types/majors and accepts optional
1.x extensions. Processed/anomaly output uses the emitting producer's 1.0 version.
New DLQ values add version 1.0 and retain JSON fallback; historical unversioned
JSON wrappers remain supported. Existing non-JSON records are not rewritten.
DLQ envelopes deliberately preserve invalid nested telemetry; correct that event
before replay. Schema checks run during builds, with no runtime registry or Kafka
schema validator. Topic/retention/database/image contracts remain unchanged.

## Checklist
- [x] Builds, tests and coverage gates pass.
- [x] Documentation and issue links updated.
- [x] Changes remain within issue scope.
- [ ] Joint review by ingestion, processor/replay, event consumer and CI owners.
- [ ] Live rollout validation.
```
