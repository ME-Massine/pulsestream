# Issue #270 dispatcher lookup fix

Owner: `@ME-Massine`. Issue: [#270](https://github.com/ME-Massine/pulsestream/issues/270).
Branch: `feature/270-postgres-kafka-consistency`. Review finding: P2, delivered
receipt scans during pending-message lookup. C-xx IDs: none assigned.

## Outcome and shared files

Flyway V5 copies source topic, partition and offset from receipts onto outbox rows
and adds a partial index for undelivered rows in source order. Enqueue copies the
coordinates in the processing transaction. Partition discovery and individual
delivery lookups query the outbox directly, avoiding delivered receipt history.
Partition advisory locks, backoff, source-offset ordering, the 100-message poll
limit and at-least-once publication semantics remain in effect.

Shared files: `docs/architecture/database-migrations.md`,
`docs/architecture/delivery-consistency.md` and this handoff. Processor delivery
code, migrations and integration tests change; synthetic forward/failure test
migrations move from V5 to V6. Applied V1-V4 migrations remain unchanged.

Joint review before merge: processor/replay, database/migration and operations
owners. Review remains pending. Related IDs: #265 (migrations), #270 (delivery),
#277 (capacity validation).

## Validation

The PostgreSQL 16 regression loads one million receipts and outbox rows, with
900,000 delivered and 100,000 pending, then refreshes statistics. It checks the
actual production head query with `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`:
the partial source index must be used, receipt access must be absent, one row
must be returned, and total shared hit/read blocks must stay below 100.
Dispatch then delivers exactly the first 100 pending offsets in order.

Additional regressions cover receipt insertion order differing from source-offset
order, missing-receipt enqueue failure, and V4-to-V5 backfill preserving pending
and delivered payloads, retry state and markers across multiple source partitions.
Existing tests exercise concurrent dispatcher ownership, retries, backoff,
independent partitions and recovery after ambiguous broker acknowledgements.

All service checks ran with Java 25.0.5 and required Docker dependencies:

| Check | Result |
| --- | --- |
| Processor `mvnw.cmd clean verify` | Passed: 174 tests, including 17 delivery and 22 migration integration tests |
| Ingestion `mvnw.cmd verify` | Passed: 29 tests |
| Query `mvnw.cmd verify` | Passed: 49 tests, including the actual V5 migration |
| JaCoCo line / branch coverage | Processor 95.38% / 85.37%; ingestion 90.48% / 50.00%; query 98.82% / 97.50%; all floors passed |
| `git diff --check` | Passed |

No tests failed, errored or skipped. Logs are under
`$env:TEMP/pulsestream-outbox-fix-processor.log`,
`$env:TEMP/pulsestream-outbox-fix-ingestion.log` and
`$env:TEMP/pulsestream-outbox-fix-query.log`. Reports remain in each service's
`target/surefire-reports` and `target/site/jacoco` directories.
PowerShell and infrastructure checks were not rerun; those files are unchanged.

## Operating effects

Stop processors before upgrading a V4 database. V5 updates all retained outbox
rows and builds an index in a transaction, holding table locks and consuming disk
and WAL capacity. Allow maintenance time for the retained history. Resume only
after Flyway succeeds; V4 writers cannot fill the new required columns. See the
[delivery operating contract](../architecture/delivery-consistency.md).
Live rollout and target-cluster capacity validation remain pending.

## Developer Git commands

Run from the repository root on `feature/270-postgres-kafka-consistency`.
Local `AGENTS.md` and `Claude.md` are excluded from staging.

```powershell
git diff --check
git add -- docs/architecture/database-migrations.md docs/architecture/delivery-consistency.md docs/implementation/issue-270-dispatcher-fix.md services/telemetry-processor
git diff --cached --stat
git diff --cached --check
git commit -m "fix(processor): index pending outbox delivery by source offset"
git push -u origin feature/270-postgres-kafka-consistency
```

## Copy-ready PR text

Title: `fix(processor): avoid delivered history scans during outbox recovery`

```markdown
## Summary
Find each pending source-partition head through a partial outbox index, preventing
retained delivered receipts from slowing every delivery attempt. Flyway V5
backfills immutable source coordinates without changing payloads or retry state.

## Related Issue
Refs #270

## Issue Requirements Covered
- Pending-message lookup avoids delivered receipt history.
- Partition locking, backoff, source ordering and durable recovery are preserved.

## Changes
- Source coordinates copied into each enqueue and indexed for pending rows only.
- Dispatcher discovery and head selection read the outbox directly.
- Migration, million-receipt query-plan and ordering regressions; rollout guidance.

Owner: @ME-Massine. C-xx IDs: none assigned. Related: #265, #270, #277.
Shared files and validation: docs/implementation/issue-270-dispatcher-fix.md.
Joint review: processor/replay, database/migrations and operations; pending.

## Testing
Java 25 Maven verification passed for processor (174 tests), ingestion (29) and
query (49), including all coverage checks. The million-receipt PostgreSQL 16
regression confirms an indexed head lookup with no receipt access and fewer than
100 shared buffer accesses. Migration and source-order regressions pass.
Live rollout and target-cluster capacity validation remain pending.

## Operating effects
Stop processors for V5 backfill and index creation; allow maintenance time, disk
and WAL capacity for retained outbox history. Mixed V4/V5 writers are unsupported.
Delivery remains at least once, and retained history still requires storage planning.

## Checklist
- [x] Code builds successfully
- [x] Tests pass
- [x] Documentation updated
- [x] Linked issue is referenced
- [x] This PR stays within the issue scope
```
