# Issue #270 implementation handoff

Owner: `@ME-Massine`.
Issue: [#270](https://github.com/ME-Massine/pulsestream/issues/270).
Branch: `feature/270-postgres-kafka-consistency`.
Changes remain uncommitted. No push, PR creation, merge or publication occurred.

## Outcome and contracts

Flyway V4 adds source-coordinate receipts and durable publication intents.
Normal processing commits the receipt, anomaly state, selected projection and
serialized outbox message together. Known invalid missing-payload input rolls
back processing and commits a DLQ intent in a new transaction. Infrastructure,
state, projection, serialization and unexpected failures stop consumption without
acknowledging the failed source, including explicit replays.

Producer factories default batching delay to zero so the configured 30-second
delivery timeout satisfies Kafka's request/delivery timeout constraint. Tests
instantiate the production factories and use the real outbox factory for delivery.

The dispatcher coordinates replicas through PostgreSQL partition locks, sends
stored JSON, marks broker-acknowledged delivery and retries failures with bounded
backoff. A broker acknowledgement followed by a process/database failure can
produce duplicate Kafka messages. Source offsets may advance after durable
enqueue and before Kafka publication. No end-to-end exactly-once guarantee exists.

Source-coordinate redelivery is a no-op. Distinct offsets may each publish a
result, ordinary event-ID duplicates keep the first projection, and explicit
same-tenant replays update it. Processed writes use atomic PostgreSQL conflict
handling without localized message matching. Cross-tenant collisions fail.
Cross-classification reconciliation remains #271.

Public HTTP APIs, topic names, event-ID output keys and JSON value schemas remain
compatible. Internal publisher classes are replaced by the outbox coordinator and
dispatcher. The original state service participates in the coordinator's database
transaction. Projection success metrics count committed outcomes.

## Ownership and shared files

C-xx IDs: none assigned in #270. Related IDs: #254 (Phase 7), #265 (migrations),
#267 (anomaly projections), #268 (event contracts), #269 (durable detector state),
#271 (reclassification), #272 (metrics), #277 (load/durability validation).

Shared files: `CONTRIBUTING.md`, `PROJECT_STATE.md`, `contracts/README.md`,
architecture delivery/anomaly/replay/database/services/system documents,
`docs/platform-overview.md`, `docs/api/anomalies.md`, the ADR index and ADR 0009,
and `infrastructure/kubernetes/telemetry-processor/README.md`. Processor
configuration, consumers, processing/persistence, migrations and tests change.
Query and ingestion production code, coverage floors, CI contexts and image pins
remain unchanged. Synthetic V4 test migrations move to V5.

Joint review required before merge: processor/replay and event-consumer owners,
PostgreSQL/migration owners, and platform/operations owners. Joint review remains
pending. Review acknowledgement boundaries, replay behavior, retention, duplicate
handling and the paused/drained rollout together.

## Validation

| Check | Result |
| --- | --- |
| Java 25 ingestion Maven `verify` | Passed: 29 tests; no failures/errors/skips |
| Java 25 processor Maven `verify` | Passed: 170 tests; no failures/errors/skips, including 14 delivery integration tests |
| Java 25 query Maven `verify` | Passed: 49 tests; no failures/errors/skips; actual V4 migration included |
| JaCoCo lines / branches | Ingestion 90.48% / 50.00%; processor 95.38% / 84.93%; query 98.82% / 97.50%; existing floors pass |
| Event contract policy | Passed: nine regression tests and compatibility against `HEAD` |
| Docker Compose configuration | Passed |
| `git diff --check` | Passed |
| PowerShell offline suites | Not rerun: no PowerShell files changed |
| Live target-cluster rollout / capacity validation | Not run; remains pending |

Checks used Java 25.0.5, matching the POMs and ADR 0006. Ingestion/query checks
ran in a Java 25 container; processor verification ran on Windows with a temporary
Java 25 installation. A clean processor build removed retired publisher classes
before final verification. PostgreSQL/Kafka dependencies were available and no
required tests were skipped. Reports remain under each service's
`target/surefire-reports` and `target/site/jacoco`. Final logs are under
`$env:TEMP/pulsestream-270-processor-complete.log`,
`$env:TEMP/pulsestream-270-ingestion.log` and `$env:TEMP/pulsestream-270-query.log`.

Reproduce from each service directory with `.\mvnw.cmd verify` (or `./mvnw verify`)
and a Java 25 JDK. From the root, run:

```powershell
python -B -m unittest discover -s scripts/ci -p test_event_contracts.py
python -B scripts/ci/check-event-contracts.py --base-ref HEAD
docker compose -f infrastructure/docker/docker-compose.yml config --quiet
git diff --check
```

Failure injection covers processing/enqueue rollback, deferred commit failure,
Kafka failure/timeout/backoff, invalid input with compound failures, serializer
fallback, process termination before send, broker acceptance before failed marker,
concurrent receipt/dispatcher ownership, independent partitions, duplicate/replay
semantics, tenant protection and source-offset recovery after database failure
and a crash between database and Kafka offset commits. Tests require real
PostgreSQL and Kafka; application integration also verifies the configured Spring
transaction manager coordinates JDBC state and projection writes.

## Operating effects

The [delivery operating contract](../architecture/delivery-consistency.md) defines
failure windows, metrics, retry/restart procedures and coordinated deployment.
Pause ingestion/replay, drain and stop old processors, apply V4 through new-release
startup, then resume traffic after delivery checks. Mixed-version processing is
unsupported. No historical publication backfill or automatic receipt/outbox
pruning is supplied. Monitor pending/failed count, oldest age and PostgreSQL disk
capacity. Kafka outages can grow a durable backlog while ingestion continues.
Live rollout, target-cluster acceptance and load/capacity validation remain pending.

## Developer Git commands

Review and execute these commands from the repository root. Local `AGENTS.md`
and `Claude.md` remain outside the staged paths.

```powershell
git diff --check
git diff --stat
git add -- CONTRIBUTING.md PROJECT_STATE.md contracts/README.md docs services/telemetry-processor infrastructure/kubernetes/telemetry-processor/README.md
git diff --cached --stat
git diff --cached --check
git commit -m "feat(processor): recover PostgreSQL and Kafka delivery with an outbox"
git push -u origin feature/270-postgres-kafka-consistency
```

## Copy-ready PR text

Title: `feat(processor): guarantee recoverable PostgreSQL and Kafka delivery`

```markdown
## Summary
Commit source receipts, detector state, projections and serialized publication
intents in one PostgreSQL transaction. Retry processed/anomaly/DLQ delivery from
a partition-serialized outbox after broker or process failures. Source offsets
advance only after a durable outcome; ambiguous sends can still duplicate Kafka
messages.

## Related Issue
Closes #270

## Issue Requirements Covered
- Atomic projection/outbox recovery and explicit record acknowledgements.
- Durable DLQ routing, replay failure propagation and source-coordinate deduplication.
- PostgreSQL conflict handling without localized exception-message matching.
- Failure-injection coverage, backlog/recovery metrics and accurate at-least-once documentation.

## Changes
- Flyway V4 receipts/outbox, transactional delivery coordinator and retry dispatcher.
- Atomic tenant-safe processed projection writes; broker durability settings.
- ADR 0009, delivery operations contract and reconciled architecture documentation.

Owner: @ME-Massine. C-xx IDs: none assigned. Related: #254, #265, #267, #268,
#269, #271, #272, #277. Shared files and detailed evidence:
docs/implementation/issue-270-handoff.md.
Joint review: processor/replay, event consumers, database/migrations and operations;
review pending.

## Testing
See the validation table in docs/implementation/issue-270-handoff.md for commands,
results and coverage. Required PostgreSQL/Kafka failure-injection tests are included.
Live target-cluster rollout and load/capacity validation remain pending.

## Operating effects
Requires a paused/drained processor cutover and V4 migration. Monitor durable
backlog age/count and database capacity. Rows are retained; no automatic historical
backfill or pruning. Replay reclassification remains #271.

## Checklist
- [x] Code builds successfully
- [x] Tests pass
- [x] Documentation updated
- [x] Linked issue is referenced
- [x] This PR stays within the issue scope
```
