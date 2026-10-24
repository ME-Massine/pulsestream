# Issue #267 implementation handoff

Owner: `@ME-Massine`.
Issue: [#267](https://github.com/ME-Massine/pulsestream/issues/267).
Branch: `feature/267-anomaly-persistence-query`, based on `origin/main` at
`c01f9b4` (merged processed-query PR #356).
No commit, push, merge or publication has been performed for this implementation.

## Outcome

Detected anomalies are committed to `platform.anomalies` before Kafka publication.
Atomic PostgreSQL event-ID conflict handling keeps the first ordinary delivery
and replaces same-tenant explicit replays without changing row ID or original
ingestion time. Cross-tenant identifier collisions fail. Missing device, metric
and value fields can be stored with detection reasons; missing tenant/event
identity follows the existing failure path.

`GET /api/v1/anomalies` reads only the authenticated tenant's projection, with
device/severity/metric/time filters, bounded pages and deterministic timestamp/ID
ordering. The same principal integration boundary as #266 applies: authentication
integration remains pending, and ordinary HTTP requests without a principal
return 401. No authentication provider is added.

The [API and operating contract](../api/anomalies.md) documents example requests
and responses, legacy fields, errors, grants, persistence metrics and recovery.
`/openapi.yaml` describes both query endpoints.

## Ownership and contracts

Owner: @ME-Massine. C-xx IDs: none assigned in #267.
Related IDs: #254 (Phase 7), #265 / PR #355 (migration foundation), #266 / PR #356
(query prerequisite), #270 (PostgreSQL/Kafka delivery consistency), #271
(cross-classification replay consistency), #273 (external security boundary).

The processor owns Flyway migrations and all projection writes. Query-service
uses JDBC and a dedicated read-only database role. Normal telemetry processing,
detection thresholds, image references and coverage floors retain their existing
contracts. Reclassification across normal/anomaly projections remains #271;
both tables can still expose contradictory classifications after such a replay.

Shared files: CONTRIBUTING.md, PROJECT_STATE.md, README.md, architecture/diagram
and roadmap documentation, `docs/api/processed-telemetry.md`,
`scripts/validate-container-images.ps1`, and the query Kubernetes README and
Secret example. Service-specific source/tests, the new V2 migration, API guide
and OpenAPI description complete the implementation. Test-only forward/failure
migrations move from V2 to V3 to keep production V2 unique.

Joint review required before merge: processor/persistence, query/API, platform
deployment and security-boundary owners. Joint review is pending.

## Validation

| Check | Result |
| --- | --- |
| Java 25 Maven `verify`, ingestion | Passed: 23 tests; coverage gates met |
| Java 25 Maven `verify`, processor | Passed: 159 tests, including 21 PostgreSQL migration cases and 4 PostgreSQL anomaly projection cases; no failures/skips |
| Java 25 Maven `verify`, query | Passed: 49 tests, including 11 PostgreSQL repository/API cases; no failures/skips |
| Processor JaCoCo | 94.20% lines / 78.41% branches; floors unchanged |
| Query JaCoCo | 98.82% lines / 97.50% branches; floors unchanged |
| PowerShell 7.5.4 offline suite | Passed: 56 sources parsed, 18 regression files, no failures/skips |
| Windows PowerShell 5.1 offline suite | Passed: 56 sources parsed, 18 regression files, no failures/skips |
| Processor/query images and container validator | Passed on both PowerShell editions using the Docker bridge; non-root startup, main-port probes, management health, V1/V2 history and disposable database initialization verified |
| Docker Compose configuration | Passed |
| OpenAPI 3.1 lint | Passed; `security-defined` excluded because the principal integration has no selected wire authentication scheme |
| `git diff --check` | Passed |
| Live target-cluster rollout / authentication integration | Not run; remains pending |

The final processor/query Maven runs used read-only source snapshots with
isolated Docker build outputs. JUnit and JaCoCo reports are retained under
`$env:TEMP/pulsestream-267-validation`. The Java 25 Maven image matches the
service POMs and ADR 0006. PostgreSQL tests execute actual processor migrations;
Docker absence fails rather than substituting H2.

The tests cover V1 upgrades and legacy preservation, atomic concurrent inserts
and replay replacements, stable IDs/ingestion time, tenant collision rejection,
missing readings, persistence-before-publication, persistence outcome counters,
ordinary DLQ/replay failure routing, all query filters and injection strings,
pagination/ties/lookahead, decimal/reason mapping, read-only grants, API identity,
database loss and recovery. Recovery assertions allow a bounded interval for
the pool to reconnect after login restoration. Disposable database containers
and their volumes, plus the isolated Maven containers, were removed after use.

## Operating effects

- Deploy processor Flyway V2 before routing traffic to the new query endpoint.
  V1 is unchanged; legacy rows, IDs, sequences, thresholds and labels survive.
  Back up before upgrade and account for transactional update/index locks on
  large histories. Binary rollback requires Flyway/schema compatibility review.
- Extend the dedicated query role with SELECT on `platform.anomalies`. Existing
  processed-table SELECT, database CONNECT and schema USAGE remain required.
  No write, DDL, sequence or Flyway history privileges are needed.
- Persistence failures prevent anomaly publication. Ordinary failures use the
  existing DLQ route; failed replays keep their original DLQ record as the retry
  source. A database commit followed by Kafka failure can leave a visible row
  before publication recovery. Separate database/Kafka writes remain #270.
- Processor metrics expose successful writes, ignored duplicates and failures
  through `pulsestream_anomaly_persistence_total{outcome=...}` without identifiers
  in metric labels. Success includes committed inserts and replay updates.
- Query pool budgets, database-dependent readiness, independent liveness,
  timeouts and network policy retain the #266 contract. Readiness proves
  connectivity, not migration version, grants or authentication integration.
- Query responses use no-store caching policy. Offset pages share no snapshot
  during concurrent ingestion/replay. There is no new Kafka consumer or topic.
- Phase 6 live deployment acceptance remains open. Image promotion and joint
  review remain developer actions; no committed deployment image references change.

## Developer Git commands

Review the diff before staging. Existing edits in all three `mvnw.cmd` files
and untracked AGENTS.md / Claude.md predate this issue and are excluded below.

```powershell
git switch feature/267-anomaly-persistence-query
git diff --check
git diff --stat
git add -- CONTRIBUTING.md PROJECT_STATE.md README.md docs `
    infrastructure/kubernetes/query-service/README.md `
    infrastructure/kubernetes/query-service/secret.example.yaml `
    scripts/validate-container-images.ps1 `
    services/query-service/src services/telemetry-processor/src
git diff --cached --stat
git commit -m "feat(anomalies): persist and query detected anomalies"
git push -u origin feature/267-anomaly-persistence-query
# Copy the PR text below into a temporary Markdown file before running:
gh pr create --draft --base main `
    --title "feat(anomalies): persist and query detected anomalies" `
    --body-file "$env:TEMP/pulsestream-267-pr.md"
```

## Copy-ready PR text

```markdown
## Summary
Detected anomalies now produce durable PostgreSQL projections before Kafka
publication. GET /api/v1/anomalies returns the authenticated tenant's history
with device/severity/metric/time filters and bounded timestamp/ID ordering.
Ordinary duplicates keep the first projection; explicit replays atomically
replace the same tenant's result while preserving row ID and first ingestion time.

## Related Issue
Closes #267. Phase: #254. Prerequisites: #265 / PR #355 and #266 / PR #356.
Delivery consistency remains #270; cross-classification reconciliation remains
#271; security-boundary integration remains pending alongside #273.

## Issue Requirements Covered
- Durable anomaly projection, atomic duplicate/replay behavior and recovery metrics.
- Versioned V2 migration preserving legacy records and supporting missing readings.
- Tenant-isolated repository, mapping, DTO, service and REST query layers.
- Device, severity, metric and half-open event-time filters; bounded deterministic pages.
- Unit, service, recovery, PostgreSQL concurrency, migration and repository/API tests.
- OpenAPI, examples, architecture, grants and operating documentation.

## Ownership and contracts
Owner: @ME-Massine. C-xx IDs: none assigned in #267.
Shared files: contribution/project-state/README, architecture/diagram/roadmap/API
docs, container validator, query deployment README and Secret example.
Joint review required: processor/persistence, query/API, platform and security
owners. Review is pending. Normal telemetry behavior and thresholds retain their
contracts; authentication integration and cross-classification replay remain pending.

## Testing
- Java 25 Maven verify passed: ingestion 23, processor 159, query 49 tests;
  coverage gates unchanged. Processor coverage: 94.20% lines / 78.41% branches;
  query: 98.82% lines / 97.50% branches.
- Required PostgreSQL 16 migration, anomaly insert/duplicate/replay/concurrency,
  query/filter/isolation/grant/API and database recovery tests passed.
- PowerShell 7.5.4 and Windows PowerShell 5.1 offline suites passed: 56 parsed
  sources, 18 regression files, no failures/skips on either edition.
- Both editions passed processor/query image validation with disposable
  PostgreSQL: non-root startup, health probes and V1/V2 migrations verified.
- Compose configuration, OpenAPI 3.1 lint and git diff --check passed.
  OpenAPI security-defined is excluded until a wire authentication scheme is selected.
- Live target-cluster rollout and tenant authentication integration remain pending.

## Operating effects
Run processor V2 before routing anomaly query traffic; add SELECT on
platform.anomalies to the dedicated query role. Plan migration locks and backup,
and review schema compatibility before binary rollback. Missing authenticated
tenant principals return 401. Persistence failures follow the existing DLQ/replay
path; database and Kafka writes remain separate. Persistence outcome counters
are exported without identifier labels. Query readiness, connection limits and
network policy retain the existing contract. No live rollout is claimed.

## Checklist
- [x] Code builds and tests pass; coverage gates unchanged.
- [x] Documentation and issue links updated.
- [x] Changes stay within the issue scope.
- [ ] Joint review from persistence, query, platform and security owners.
- [ ] Live target-cluster rollout and authentication integration validation.
```
