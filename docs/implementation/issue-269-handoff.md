# Issue #269 implementation handoff

Owner: `@ME-Massine`.
Issue: [#269](https://github.com/ME-Massine/pulsestream/issues/269).
Branch: `feature/269-deterministic-anomaly-detection`, based on `1c59114`
(`fix(contracts): preserve decimal precision and fixture immutability`).
Changes remain uncommitted. No push, PR creation, merge or publication occurred.

## Outcome

Ingestion and replay now key raw telemetry by a collision-safe encoding of tenant
and device identity. The standard keyed partitioner and one in-flight producer
request preserve partition order through retries. Existing event IDs and JSON
value contracts remain intact. Shared key vectors prevent drift between services.

Sudden-deviation detection uses bounded PostgreSQL state rather than a replica
map. Flyway V3 adds partition checkpoints, tenant/device/metric/unit readings and
a recent decision journal. A partition lock and transaction update them together.
Redelivery recovers the original decision without comparing the record against
its own advanced baseline. Inactive keys expire as partition stream time advances.
Capacity, stale-offset, wrong-key, database and configuration failures stop raw
consumption without acknowledging or dead-lettering the failed record.

Thresholds, required temperature unit, relative-change ratio, retention and row
bounds are configuration-driven. Equivalent Celsius/Fahrenheit spellings normalize
without converting numeric values. Incompatible temperature units are CRITICAL
and cannot poison the baseline; other metrics isolate differing units.

Real Kafka/PostgreSQL integration tests compare one replica with multiple replicas
through scale-out, scale-in, restart and group rebalance across three partitions.
Crash recovery tests cover both a database outage and termination after detection
commits but before Kafka offset commit. The autoscaling load generator now follows
the key contract and alternates values per device; an executable offline shell
regression checks its real output.

The [operating contract](../architecture/anomaly-detection.md) and
[ADR 0008](../decisions/0008-durable-anomaly-state.md) define ordering, stream-time
expiration, recovery bounds, unit rules, scaling limits and the coordinated rollout.
HPA documentation no longer assumes replica-local anomaly history. Topic partition
counts, HPA manifests, required CI contexts, image pins and coverage floors remain
unchanged. Forward/failure migration test fixtures move from V3 to V4 to leave V3
available for the new production migration.

## Ownership and contracts

Owner: @ME-Massine. C-xx IDs: none assigned in #269.
Related IDs: #254 (Phase 7), #265 (migrations), #267 (anomaly projections),
#268 (event values), #270 (delivery consistency), #271 (reclassification),
#272 (consumer-lag metrics), #277 (load/durability validation).

Shared files: `PROJECT_STATE.md`, `contracts/README.md`,
`contracts/ordering-keys.json`, architecture anomaly/autoscaling/custom-metrics/
database-migrations/replay/topics documents, ADR index and ADR 0008,
`infrastructure/kubernetes/telemetry-processor/README.md`,
`scripts/validate-autoscaling-behavior.ps1`, `scripts/validate-container-images.ps1`
and `scripts/tests/test-autoscaling-load-helpers.ps1`. Ingestion publishing/config
and processor publishing/consumer/state/migration/rule paths and tests also change.
Query production code and service POMs are unchanged.

Joint review required before merge: ingestion/API and external producer owners,
processor/replay and event consumers, PostgreSQL/migration owners, and
platform/autoscaling/operations owners. Joint review remains pending. Review the
paused/drained cutover, stream-time expiration, state capacity and journal window
together; structural JSON compatibility cannot establish ordering compatibility.

## Validation

| Check | Result |
| --- | --- |
| Java 25 ingestion Maven `verify` | Passed: 29 tests; no failures/errors/skips |
| Java 25 processor Maven `verify` | Passed: 185 tests; no failures/errors/skips; required PostgreSQL and Kafka scaling/crash tests included |
| Java 25 query Maven `verify` | Passed: 49 tests; no failures/errors/skips; query tests apply actual V3 migration |
| JaCoCo lines / branches | Ingestion 90.48% / 50.00%; processor 94.86% / 81.65%; query 98.82% / 97.50%; existing floors pass |
| Windows PowerShell 5.1 offline suite | Passed: 56 parsed sources, 18 regression files, no failures/skips |
| PowerShell 7.5.4 offline suite | Passed: 56 parsed sources, 18 regression files, no failures/skips |
| Event contract policy | Passed: nine regression tests and compatibility against `HEAD` (`1c59114`) |
| Docker Compose configuration | Passed |
| Container image build/start validation | Passed: all three images built; startup, liveness/readiness, management health and non-root checks passed; processor recorded Flyway V1–V3 |
| `git diff --check` | Passed |
| Live target-cluster rollout / cluster-only scripts | Not run; remains pending |

Java checks use the local Java 25 JDK matching the POMs and ADR 0006. Reports are
under each service's `target/surefire-reports` and `target/site/jacoco`. Logs are
under `$env:TEMP/pulsestream-269-*.log`. Docker/PostgreSQL tests run in the normal
Maven lifecycle and are not skipped. Python checks used the temporary Python
3.12.10 runtime outside the repository. The PowerShell regression executes the
Kafka load template with Bash and a local producer stub, without Kafka or a cluster.
Run the processor's first check after updating with `./mvnw clean verify` (Windows:
`.\mvnw.cmd clean verify`): the renamed V4 test fixtures otherwise leave old V3
copies in an existing `target/test-classes` directory until a clean build.

## Operating effects

- The raw Kafka key changes. Pause ingestion/replay/external writers, drain old
  records with the old processor, verify group offsets, stop old processors and
  deploy the new producers/processors together before resuming. First readings
  establish new baselines; existing projections remain intact.
- PostgreSQL now stores detection state as well as projections. A state outage,
  exhausted key capacity, incompatible configuration or invalid recovery stops
  raw consumption. Repair the cause and restart the processor; adding replicas
  does not recover state capacity or database availability.
- Default stream-time retention is 24 hours, with 10,000 reading keys and 1,000
  offset decisions per partition. Across three partitions this bounds retained
  rows at 30,000 readings, 3,000 decisions and three checkpoints. Idle partitions
  prune on their next input; wall-clock waiting alone does not expire state.
- All replicas must use identical anomaly settings and the same database. Rule,
  bound, partition-count and topic-lifecycle changes require reviewed migration.
  An intentional cold state reset preserves projections and Kafka offsets but
  removes first-reading spike comparisons. No automatic active-key eviction occurs.
- Default temperature bounds remain -40 to 80 Celsius and the strict spike ratio
  remains 0.5. Missing/incompatible units now produce CRITICAL anomalies. Celsius
  aliases normalize to `c`; values are never silently compared across units.
- Kafka offsets determine reading order. Replaying an event at a new offset is a
  new reading against current history. The journal recovers raw offset redelivery;
  it is not event-ID deduplication or indefinite history. Atomic downstream delivery
  remains #270; replay reclassification remains #271.
- Three raw partitions allow at most three active consumer threads. Default
  concurrency one retains the two-to-three replica CPU HPA range. Lag-based HPA,
  production capacity calibration and live deployment validation remain pending.

## Developer Git commands

Review before staging. The commands exclude untracked `AGENTS.md` and `Claude.md`.

```powershell
git switch feature/269-deterministic-anomaly-detection
git diff --check
git add -- PROJECT_STATE.md contracts/README.md contracts/ordering-keys.json `
    docs/architecture/anomaly-detection.md docs/architecture/autoscaling-strategy.md `
    docs/architecture/custom-metrics-autoscaling.md docs/architecture/database-migrations.md `
    docs/architecture/event-replay-strategy.md docs/architecture/topics.md `
    docs/decisions/README.md docs/decisions/0008-durable-anomaly-state.md `
    docs/implementation/issue-269-handoff.md `
    infrastructure/kubernetes/telemetry-processor/README.md `
    scripts/validate-autoscaling-behavior.ps1 scripts/validate-container-images.ps1 `
    scripts/tests/test-autoscaling-load-helpers.ps1 `
    services/ingestion-service/src services/telemetry-processor/src
git diff --cached --check
git diff --cached --stat
git commit -m "feat(processor): make anomaly detection deterministic under scaling"
git push -u origin feature/269-deterministic-anomaly-detection
```

Copy the PR body below into a temporary Markdown file, then open a draft PR:

```powershell
gh pr create --draft --title "feat(processor): make anomaly detection deterministic under scaling" `
    --body-file "$env:TEMP/pulsestream-269-pr.md"
```

## Copy-ready PR text

```markdown
## Summary
Raw telemetry ingestion and replay use tenant/device ordering keys. Stateful
anomaly detection uses bounded PostgreSQL reading state and retained offset
decisions, producing the same decisions through scaling, restart and rebalance.
Thresholds and units are explicit and configurable; incompatible units cannot
update a baseline. State failures stop consumption without committing the record.

## Related Issue
Closes #269. Phase: #254. Foundations: #265, #267 and #268.
Delivery/reclassification remain #270/#271; metrics/capacity remain #272/#277.

## Issue Requirements Covered
- Collision-safe tenant/device raw keys shared by ingestion and replay; standard
  keyed partitioning and retry order; unchanged event identity/value schemas.
- PostgreSQL partition locks, checkpoints, reading state and bounded decision
  recovery; deterministic stream-time expiration and hard per-partition bounds.
- Tenant/device/metric/unit isolation, explicit temperature units and configurable
  bounds/ratio; incompatible units produce CRITICAL anomalies without state changes.
- Multi-instance Kafka/PostgreSQL tests for three partitions, scale-out, scale-in,
  restart, rebalance, concurrent redelivery, outage and state/Kafka commit crashes.
- Coordinated key cutover/recovery documentation and corrected HPA scaling limits.
- Autoscaling load keys and per-device alternation verified by executable shell
  regression on both PowerShell editions; container validation checks Flyway V3.

## Ownership and contracts
Owner: @ME-Massine. C-xx IDs: none assigned in #269.
Shared files: PROJECT_STATE.md, contract key vectors/README, architecture and ADR
documents, processor Kubernetes README, container/autoscaling validation scripts
and load-helper regression. Both producing services and processor migration/state
paths change; query production code, topic partitions and HPA manifests do not.
Joint review pending: ingestion/external producers, processor/replay/event
consumers, PostgreSQL/migrations and platform/autoscaling/operations owners.

## Testing
- Java 25 Maven verify: ingestion 29, processor 185 and query 49 tests passed;
  no failures/errors/skips; real PostgreSQL and Kafka tests included.
- JaCoCo lines/branches: ingestion 90.48%/50.00%, processor 94.86%/81.65%,
  query 98.82%/97.50%; existing coverage floors pass.
- Offline PowerShell 7.5.4 and Windows PowerShell 5.1: 56 parsed sources and
  18 regression files passed on each edition, with no failures/skips.
- Nine contract-policy tests, compatibility against 1c59114, Compose configuration
  and git diff --check passed.
- All three container images built and passed startup, liveness/readiness,
  management health and non-root checks; processor recorded Flyway V1–V3.
- Live target-cluster rollout and cluster-only scripts remain pending.

## Operating effects
Requires a paused/drained cutover from event-ID keys; do not mix old/new producers
or processors. Flyway V3 preserves projections and adds shared detection state.
Defaults retain at most 10,000 keys and 1,000 offset decisions per partition, with
24-hour stream-time expiration. Completely idle partitions prune on their next
input. Capacity exhaustion/database/state errors stop consumption; repair and
restart rather than skipping records. Identical settings are required across
replicas, and configuration/topic/partition changes require coordinated recovery.
The three-partition, concurrency-one CPU HPA ceiling remains three replicas.
Replay at a new raw offset re-evaluates against current history; retained offset
redelivery reuses its decision. Atomic output delivery and replay reclassification
remain separate work under #270/#271. Live rollout/capacity validation is pending.

## Checklist
- [x] Builds, tests and existing coverage gates pass.
- [x] Ordering, unit, migration, recovery and autoscaling documentation updated.
- [x] Issue linked and changes remain within scope.
- [ ] Joint review by producer, processor, database and operations owners.
- [ ] Coordinated live rollout and production capacity validation.
```

## PR #366 conflict resolution

Owner: @ME-Massine. PR: [#366](https://github.com/ME-Massine/pulsestream/pull/366).
Issue: #269; phase: #254. C-xx IDs: none assigned.

Prepared a local merge of `main` at `f56d5ff` into PR head `bbb1342` on
`feature/269-deterministic-anomaly-detection`. The merge remains uncommitted and
has not been pushed. The unresolved index is empty; `MERGE_HEAD` retains the
main commit so the developer's next commit completes the merge.

Resolved three shared files by retaining the #269 additions alongside the event
contracts now present on main:

- `contracts/README.md`: preserve the tenant/device key contract and cutover link.
- `docs/decisions/README.md`: preserve the ADR 0008 index entry after ADR 0007.
- Ingestion `contract/EventContractTest.java`: preserve tenant/device key
  assertions for raw publishing and its DLQ fallback, with schema/JSON checks.

The resolved tracked tree matched `bbb1342` exactly before this handoff update.
No application behavior, schema, fixture, dependency or operating procedure changes
result from the resolution. This handoff is the only additional content change.
Joint review by ingestion/event-contract, processor and platform owners remains
pending before merge; the original rollout and capacity prerequisites still apply.

Validation for this resolution:

- Java 25 ingestion Maven `verify`: 29 tests passed, no failures/errors/skips;
  existing JaCoCo coverage gates passed.
- Nine event-contract policy regression tests passed; compatibility against
  `origin/main` (`f56d5ff`) passed.
- No unmerged index entries or conflict markers remain in the three files.
- Working-tree and staged whitespace checks passed.
- Processor/query, PowerShell and container checks were not repeated: their
  content is unchanged from the tested PR head. Earlier full validation is recorded
  above. Resolution logs are under `$env:TEMP/pulsestream-pr366-*.log`.

Complete the prepared merge and update the existing PR with these developer
commands. No force push is needed; untracked `AGENTS.md` and `Claude.md` stay excluded.

```powershell
git status
git diff --cached --check
git diff --cached --stat
git commit -m "chore(merge): resolve main conflicts for PR #366"
git push origin feature/269-deterministic-anomaly-detection
```

Copy-ready PR update:

```markdown
Resolved conflicts with main at f56d5ff while preserving #269's tenant/device
key assertions, ordering-contract documentation and ADR 0008 index entry.
Owner: @ME-Massine. IDs: PR #366, issue #269, phase #254; C-xx: none assigned.
Shared files: contracts/README.md, docs/decisions/README.md, ingestion
contract/EventContractTest.java and the issue-269 handoff. No runtime behavior
or operating effects change from the existing PR head.

Validation: ingestion Maven verify passed all 29 tests and coverage gates;
nine contract-policy regressions and compatibility against main passed.
No unresolved conflicts or whitespace errors remain. Joint review by ingestion,
event-contract, processor and platform owners remains pending before merge.
```
