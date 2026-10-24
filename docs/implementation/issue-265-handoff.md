# Issue #265 handoff

Owner: Massine AMAKHTARI (`@ME-Massine`).
Issue: [#265](https://github.com/ME-Massine/pulsestream/issues/265).
Branch: `feature/265-postgresql-migrations`.

PR #355 resolution baseline: `main` at
`87ad6b51999e233796a912a3fc0c29d692a69a90`, with PR head
`9d0e9184ba26991e5c1b8bb69267d66c6da5ca18`.
The POM resolution retains Java 25 and Spring Boot 4.1.1, adds the Flyway starter
required for automatic startup migrations, and uses Boot-managed Testcontainers 2.
The migration suite and Kafka test exclusion follow the updated package names.

## Outcome and shared contracts

The processor applies ordered Flyway migrations automatically before JPA and
Kafka startup. V1 initializes an empty PostgreSQL database and adopts compatible
legacy tables without deleting rows or resetting sequences. Failed migration or
checksum validation stops startup. The former manual initialization path is
removed; the original SQL remains only as a frozen legacy-upgrade test fixture.

C-xx IDs: none are assigned in #265. The shared database contract remains
`platform.processed_telemetry` and `platform.anomalies`, including `SERIAL` IDs,
unique event IDs, numeric/timestamp types, defaults, and lookup indexes. Shared
files include processor `pom.xml`/`application.yml`, the container validator,
Kubernetes ConfigMap documentation, local-development instructions, architecture
documents, `CONTRIBUTING.md`, and `PROJECT_STATE.md`.

Joint review remains required from processor/persistence, query, and platform
owners before merge. Review legacy adoption and the preserved contract with the
query/anomaly follow-ups #266/#267; review startup privileges, multi-replica
migration, and disposable database cleanup with the platform owner. No joint
review or live-cluster acceptance is claimed.

## Validation on 2026-10-24

| Check | Result |
| --- | --- |
| Java 25 Maven `verify`, ingestion | Passed; 23 tests and coverage gate |
| Java 25 Maven `verify`, processor | Passed; 149 tests and coverage gate |
| Java 25 Maven `verify`, query | Passed; 1 test and coverage gate |
| PostgreSQL 16 migration integration suite | Passed; 20 tests, no skips; six new unique-index cases fail before the fix |
| Processor coverage | 94.00% lines, 76.96% branches; floors unchanged |
| PowerShell 7.5.4 / Windows PowerShell 5.1 offline suites | Passed; 56 sources parsed and 17 regression scripts per edition |
| Compose configuration | Passed |
| Processor Java 25 Docker image build | Passed |
| Container startup, probes, migration history, cleanup | Passed on Windows PowerShell 5.1 and PowerShell 7.5.4 |
| Success and forced startup timeout cleanup | Removed service/database validation containers and their observed anonymous database volumes on both PowerShell editions |
| Live Kubernetes rollout | Pending; Phase 6 validation gate remains open |

The PostgreSQL suite covers fresh startup and repository writes, repeated
startup, populated legacy-table adoption, seven incompatible legacy definitions,
rejection of unique variants of all six lookup indexes, checksum rejection,
concurrent migrators, successful forward migration, and
transactional rollback after a failed forward migration.

## Operating effects

Processor startup now requires reachable PostgreSQL and a role able to create
schemas and modify owned platform objects. Migrations are embedded in the
processor image and run identically locally and in Kubernetes; no migration Job
or manual SQL is required. Flyway history resides in `pulsestream_migrations`.
Back up existing databases before adoption. Future versions must be immutable
and compatible with rolling deployments. Application rollback does not reverse
schema changes. See [database migrations](../architecture/database-migrations.md)
for recovery and rollback rules.

## Developer Git commands

Run from the repository root after reviewing the diff. The explicit file list
excludes the pre-existing Maven-wrapper changes and untracked instruction files.
No commit, push, merge, or publication has been performed.

```powershell
$issueFiles = @(
    'docs/architecture/container-image-validation.md'
    'docs/architecture/database-migrations.md'
    'docs/implementation/issue-265-handoff.md'
    'scripts/validate-container-images.ps1'
    'services/telemetry-processor/src/main/resources/db/migration/V1__create_platform_tables.sql'
    'services/telemetry-processor/src/test/java/com/pulsestream/processor/migration/PostgresMigrationIntegrationTest.java'
)
git add -- $issueFiles
git diff --cached --check
git diff --cached --stat
git commit -m "fix(database): reject unique lookup indexes and clean validation volumes"
git push -u origin feature/265-postgresql-migrations
```

## Copy-ready draft PR

Title: `feat(database): introduce versioned PostgreSQL migrations`

```markdown
## Summary
The telemetry processor automatically applies Flyway migrations
before JPA and Kafka startup. Clean PostgreSQL databases initialize without SQL
commands; compatible legacy tables retain data and sequence positions. Migration
and checksum errors prevent startup.

## Related Issue
Closes #265. PR #355; query/anomaly follow-ups #266/#267.

## Changes
- Initialize empty databases and adopt compatible legacy tables through V1.
- Reject unique variants of all six legacy lookup indexes before startup so
  repeated tenants, devices, and timestamps remain valid.
- Remove the disposable PostgreSQL container and anonymous data volume on
  successful image validation and on failure.
- Document startup, adoption, and recovery procedures.

## Ownership and contracts
Owner: @ME-Massine. C-xx IDs: none assigned in #265.
Preserves both platform table contracts for #266/#267. Shared files: processor
POM/configuration, container validator, local/Kubernetes operating docs,
architecture docs, CONTRIBUTING.md, and PROJECT_STATE.md.
Joint review required: processor/persistence, query, and platform owners.

## Testing
- Java 25 Maven verify passed for all services; coverage gates unchanged.
- PostgreSQL 16 integration suite: 20 passing tests covering initialization,
  restart, populated legacy adoption, incompatible schemas, checksums, concurrent
  migrators, successful forward upgrade, failed-migration rollback, and unique
  definitions of all six lookup indexes. The six new cases fail before the fix.
- PowerShell 7.5.4 and Windows PowerShell 5.1 offline suites passed.
- Compose configuration and processor Java 25 Docker image build passed.
- Processor image startup, main-port probes, management health, migration history,
  and disposable database cleanup passed on both PowerShell versions.
- Success and forced timeout runs removed the disposable database and its
  anonymous volume on both PowerShell versions.

## Checklist
- [x] Code builds successfully.
- [x] Tests pass; coverage gates unchanged.
- [x] Documentation updated.
- [x] Linked issue is referenced.
- [x] Changes stay within the issue scope.
- [ ] Joint review from processor/persistence, query, and platform owners.

## Operating effects
PostgreSQL connectivity and schema DDL privileges are now startup requirements.
The processor owns migrations and stores history in pulsestream_migrations;
manual init.sql is retired. Local and Kubernetes use the same startup process.
Back up existing databases before adoption; schema rollback is not automatic.
Live Kubernetes rollout remains pending, and Phase 6 acceptance is unchanged.
```
