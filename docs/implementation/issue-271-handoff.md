# Issue #271 implementation handoff

Owner: `@ME-Massine`. Issue: [#271](https://github.com/ME-Massine/pulsestream/issues/271).
Branch: `feature/271-replay-reclassification`. C-xx IDs: none assigned.
Related: #254, #265, #266, #267, #268, #269, #270, #272 and #277.

## Outcome and interfaces

Flyway V6 adds authoritative current classification state, preserving existing
single projections and retaining contradictory same-tenant rows as unresolved.
Cross-tenant ownership conflicts fail migration and report up to ten event IDs.
Explicit replay atomically replaces the selected projection, deletes its obsolete
opposite and records v2 Kafka UPSERT/RETRACT intents. JSONB current-result equality
provides numeric-scale-independent idempotency without storing a historical audit
log or relying on generated timestamps. Unchanged results produce no revision or
publication. Ordinary duplicates retain the authoritative result across boundaries.

Processed/anomaly v2 schemas and a dedicated publication record add operation,
classification and classificationRevision. All published v1 schemas/fixtures and
raw/DLQ contracts remain intact. The outbox permits multiple sequenced messages
per receipt and preserves source-offset/sequence ordering with its pending index.
Both query APIs join authoritative state, hide unresolved results and add
classificationRevision. Query SELECT grants must include the classification table.

Shared files: CONTRIBUTING, README, PROJECT_STATE, contracts/README and fixtures
index, replay/schema/delivery/database/anomaly/service architecture documentation,
query API documentation and OpenAPI, ADR index, processor/query Kubernetes
READMEs and container validation. Processor classification/delivery, migrations,
models, query repositories/DTOs/mappers and integration tests change. Applied
V1-V5 migrations, coverage floors, topic names, image pins and CI contexts remain.

Joint review before merge: processor/replay, downstream event consumers,
PostgreSQL/migrations, query and platform/operations owners. Review remains pending.

## Validation

Final validation results are recorded below. Java checks require
Java 25, matching the POMs and ADR 0006. Required integration tests use real
PostgreSQL 16 and embedded Kafka; Docker unavailability is not a skip condition.

| Check | Result |
| --- | --- |
| Ingestion Maven verify | Passed: 29 tests, no failures/errors/skips |
| Query Maven clean verify | Passed: 50 tests, no failures/errors/skips |
| Processor Maven clean verify | Passed: 183 tests, no failures/errors/skips; 24 delivery and 24 migration tests |
| JaCoCo line / branch | Processor 95.02% / 85.71%; ingestion 90.48% / 50.00%; query 98.82% / 97.50%; existing floors pass |
| Contract policy | Passed: nine regression tests; compatibility against implementation base HEAD |
| Windows PowerShell 5.1 Offline | Passed: 56 parsed files; 18 test files; no failures/skips |
| PowerShell 7.4.6 Offline | Passed: 56 parsed files; 18 test files; no failures/skips |
| Docker Compose config | Passed |
| Container builds/startup/migrations | Passed: all three final-source images; health probes; processor V1-V6 history |
| git diff --check | Passed |
| Live cluster deployment/capacity | Not run; pending |

An earlier full processor run timed out in the existing DLQ boundary test during
concurrent validation. The final full clean run passed all 183 tests in 3:02.


Failure coverage includes all four classification transitions, identical results,
raw-input reevaluation after baseline changes, ordinary duplicate classification
conflicts, concurrent replay across partitions, unresolved legacy recovery,
cross-tenant migration rejection and complete rollback after the second enqueue
fails. Existing #270 tests retain commit/source-offset/send-marker/backoff recovery
coverage. Transition tests additionally exercise failure between sends, and
consumer convergence under reordered and repeated equal-revision operations.
Query tests cover unresolved exclusion, revision fields, tenant isolation and
read-only grants. Migration tests preserve both historical projections, outbox
payloads, retry/delivery markers and repeated startup.

Reproduce with `.\mvnw.cmd clean verify` in each service using a Java 25 JDK,
then run from the repository root:

```powershell
python -B -m unittest discover -s scripts/ci -p test_event_contracts.py
python -B scripts/ci/check-event-contracts.py --base-ref HEAD
powershell -NoProfile -File scripts/tests/run-all-tests.ps1 -Scope Offline
pwsh -NoProfile -File scripts/tests/run-all-tests.ps1 -Scope Offline
powershell -NoProfile -File scripts/validate-container-images.ps1 -Network bridge
docker compose -f infrastructure/docker/docker-compose.yml config --quiet
git diff --check
```

Logs reside under `$env:TEMP/pulsestream-271-*.log`. Maven reports remain in each
service's target/surefire-reports and target/site/jacoco directories.

## Operating effects

Deploy v1/v2 readers first, pause ingestion/replay, drain the old outbox, stop old
processors/query instances, apply V6, grant query SELECT, start updated services
and verify before resuming. Mixed-version writers are unsupported. Allow migration
locks, WAL and disk for backfill/index creation. Monitor delivery pending/failed
counts, oldest age and database capacity. Unresolved legacy IDs stay hidden until
the next record for the event is processed (replay or ordinary); there is no automatic historical replay or publication
backfill. Messages remain at least once and visibility across topics is eventual.
Prefer forward fixes over returning to old writers after cutover.

The [operating contract](../architecture/replay-reclassification.md) contains
consumer watermark rules, unresolved/cross-tenant diagnostic SQL, grants,
retention limits and recovery details. Phase 6 live acceptance remains separate.

## Developer Git commands

Review these commands before execution. No commit, push, merge or publication has
been performed. Local AGENTS.md and Claude.md remain outside staged paths.

```powershell
git diff --check
git diff --stat
git add -- CONTRIBUTING.md README.md PROJECT_STATE.md contracts docs infrastructure/kubernetes/query-service/README.md infrastructure/kubernetes/telemetry-processor/README.md scripts/validate-container-images.ps1 services/query-service services/telemetry-processor
git diff --cached --check
git diff --cached --stat
git commit -m "feat(processor): reconcile replay classifications and projections"
git push -u origin feature/271-replay-reclassification
```

## Copy-ready PR text

Title: `feat(processor): reconcile replay classifications and projections`

```markdown
## Summary
Replay now atomically replaces an event's authoritative classification, removes
its obsolete projection and records v2 replacement/retraction publications.
Unchanged results produce no new revision; query APIs expose only active results
and include classificationRevision. Historical conflicts remain hidden until replay.

## Related Issue
Closes #271

## Issue Requirements Covered
- All normal/anomaly transitions and repeated-result idempotency.
- Tenant-owned authoritative state and noncontradictory query projections.
- Versioned downstream upsert/retraction contracts and recoverable ordered delivery.
- PostgreSQL/Kafka integration coverage and coordinated rollout documentation.

## Changes
- Flyway V6 classification registry and sequenced multi-message outbox intents.
- Semantic result equality, tenant-safe transactional replacement and v2 contracts.
- Query revision fields, authoritative filtering, grants and full-schema container validation.
- ADR 0010, operating contract and implementation handoff.

Owner: @ME-Massine. C-xx IDs: none assigned. Related: #254, #265, #266, #267,
#268, #269, #270, #272 and #277. Shared files and validation evidence:
docs/implementation/issue-271-handoff.md.
Joint review pending: processor/replay, consumers, migrations, query and operations.

## Testing
See the validation table in docs/implementation/issue-271-handoff.md for commands,
results and coverage. Required PostgreSQL/Kafka transition and recovery tests run
in the normal lifecycle. Live deployment and capacity validation remain pending.

## Operating effects
Requires v2-capable consumers followed by a paused/drained V6 processor/query
cutover and SELECT on platform.event_classifications. Unresolved legacy events
stay hidden until selective replay. At-least-once delivery, eventual cross-topic
visibility, retained outbox history and forward-fix recovery remain applicable.

## Checklist
- [x] Code builds successfully
- [x] Tests pass
- [x] Documentation updated
- [x] Linked issue referenced
- [x] Changes stay within issue scope
```

## PR #398 timestamp recovery follow-up

Owner: `@ME-Massine`. Issue: #271. PR: #398.
Branch: `fix/271-replay-followups`. C-xx IDs: none assigned.

Authoritative anomaly upserts now apply the registry's `first_processed_at` to
existing rows. Resolving a migrated conflict whose normal row was ingested in
2025 and anomaly row in 2026 therefore keeps 2025 as `ingestedAt` through anomaly
updates and a later NORMAL transition. Standalone anomaly replay writes retain
their existing first-ingestion behavior.

Timestamp-less replays of resolved events reuse `result.eventTime` before
projection/first-processing fallbacks. Epoch seconds are read as decimal text
and converted without floating-point rounding, preserving microseconds before
and after the Unix epoch. Recreating a missing projection leaves the registry
result, revision, change time and outbox unchanged.

Shared files: processor anomaly repository/persistence service, classification
coordinator, delivery integration tests and the replay operating contract.
No C-xx interfaces, migration files, event schemas or topic names change.
Joint review remains pending with processor/replay, PostgreSQL, query and
platform/operations owners. Required GitHub CI remains pending.

Validation on 2026-11-23 with Java 25 and `.\mvnw.cmd -o clean verify` in each
service: processor 199 tests, ingestion 29 tests and query 50 tests passed with
no failures, errors or skips (278 total). All JaCoCo gates passed: processor
95.35% line / 86.22% branch; ingestion 90.48% / 50.00%; query 98.82% / 97.50%.
Docker Compose configuration and `git diff --check` passed.
All five new regression cases failed against the pre-fix production code,
reproducing the wrong ingestion year and revision increment. The corrected
targeted run passed all five plus the existing standalone replay ingestion test.
PostgreSQL regression coverage includes the V6 conflict backfill, anomaly row-ID
retention, both projection types, positive/negative fractional epoch timestamps,
and unchanged replay before and after projection loss.
Logs: `$env:TEMP/pulsestream-271-timestamp-*.log`. GitHub CI and live rollout
remain pending.

Operating effects: processor forward fix; no new migration or configuration.
Existing conflicting rows receive the registry ingestion time on authoritative
updates. Recovery remains explicit replay; no bulk repair is introduced.
The existing paused/drained V6 rollout contract still applies.

The local merge from `origin/main` resolves PR #398's overlapping replay changes
while retaining lost-projection recovery and duplicate metrics. The merge is
uncommitted. Review the diff, then run from the repository root:

```powershell
git diff --check
git add -u -- docs/architecture/replay-reclassification.md docs/implementation/issue-271-handoff.md services/telemetry-processor/src
git diff --cached --check
git diff --cached --stat
git commit -m "fix(processor): preserve authoritative replay timestamps"
git push origin HEAD:fix/271-replay-followups
```

Copy-ready PR update:

```markdown
Preserve the registry's first processing time when resolving legacy conflicts
as ANOMALY. Restore missing projections on timestamp-less unchanged replay using
the stored semantic event time, without a new revision or UPSERT.

Owner: @ME-Massine. Refs #271; follow-up PR #398. C-xx IDs: none assigned.
Shared files: processor persistence/classification, delivery integration tests,
replay operating contract and issue-271 handoff.
Joint review pending: processor/replay, PostgreSQL, query and operations owners.
Validation: Java 25 clean Maven verify passed for all three services (278 tests,
no failures/errors/skips); coverage gates, Compose config and diff checks passed.
All five new PostgreSQL regressions fail against the pre-fix code and pass with
the fix. Required GitHub CI remains pending.
Operating effects: processor forward fix, no schema/configuration change;
existing V6 cutover requirements remain applicable.
```
