# Dependabot PRs #367–#379 handoff

Owner: @ME-Massine. Prepared: 2026-11-02.
Branch: `chore/dependabot-updates-367-379`.
Base: `origin/main` at `f56d5ffce26ca1bb3fd5df0b61696824b3252f3a`.
Worktree: `C:/Github_Repos/pulsestream-dependabot-367-379`.
Changes are uncommitted. The original worktree remains on
`feature/269-deterministic-anomaly-detection`. No remote PRs were edited,
closed or merged. The commands below are for the developer to execute.

## Outcome

Consolidate all 13 open Dependabot updates into one tested dependency-maintenance
change. Fix the shared PR issue-alignment failure: Dependabot provides release
notes rather than a linked issue and the human template. The workflow now verifies
the bot author, source repository and all changed files before allowing that format.
It checks the complete paginated file list, accepts only modifications to configured
dependency files and makes no comment writes on the bot path. Other PRs retain the
human issue/template rules. Workflow events, permissions and required check names
remain unchanged; CI, dependency review and review requirements still apply.

| Dependency | Previous | Prepared version | Original PRs |
| --- | --- | --- | --- |
| Spring Boot parent, all services | 4.1.1 | 4.1.2 | #367, #368, #373 |
| JaCoCo, all services | 0.8.15 | 0.8.16 | #371, #377, #379 |
| JSON Schema validator, ingestion and processor tests | 3.0.7 | 3.0.8 | #370, #376 |
| OpenTelemetry instrumentation BOM, ingestion and processor | 2.32.0 | 2.33.1 | #375, #378 |
| Grafana, local Compose | 13.2.4 | 13.3.0 | #369 |
| Kafka broker and topic initializer, local Compose | 8.3.2 | 8.4.0 | #372 |
| Redis, local Compose | 7 | 8 | #374 |

## PR evidence

At inspection, all 13 PRs were open and mergeable against the base above.
Each passed CI, CodeQL and dependency review. Each failed only PR issue alignment.
The #367 alignment conversation identifies the six failures: the missing linked
issue and five human template sections. These statuses apply to the individual
heads below, not to the unpublished consolidated change.

| PR | Inspected head | CI | PR issue alignment |
| --- | --- | --- | --- |
| [#367](https://github.com/ME-Massine/pulsestream/pull/367) | `f3230a61082e` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/41221803814) | [Failed](https://github.com/ME-Massine/pulsestream/actions/runs/41221803856) |
| [#368](https://github.com/ME-Massine/pulsestream/pull/368) | `7b442b0bb679` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/41221805584) | [Failed](https://github.com/ME-Massine/pulsestream/actions/runs/41221805572) |
| [#369](https://github.com/ME-Massine/pulsestream/pull/369) | `6944376005da` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/41221811012) | [Failed](https://github.com/ME-Massine/pulsestream/actions/runs/41221810826) |
| [#370](https://github.com/ME-Massine/pulsestream/pull/370) | `e7bb37ef3c56` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/41221812335) | [Failed](https://github.com/ME-Massine/pulsestream/actions/runs/41221812391) |
| [#371](https://github.com/ME-Massine/pulsestream/pull/371) | `47266db1eb84` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/41221816667) | [Failed](https://github.com/ME-Massine/pulsestream/actions/runs/41221816673) |
| [#372](https://github.com/ME-Massine/pulsestream/pull/372) | `2198a7f530cf` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/41221816266) | [Failed](https://github.com/ME-Massine/pulsestream/actions/runs/41221816309) |
| [#373](https://github.com/ME-Massine/pulsestream/pull/373) | `6e6b8a4fd74a` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/41221819713) | [Failed](https://github.com/ME-Massine/pulsestream/actions/runs/41221819697) |
| [#374](https://github.com/ME-Massine/pulsestream/pull/374) | `88168b83d7d1` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/41221821909) | [Failed](https://github.com/ME-Massine/pulsestream/actions/runs/41221821908) |
| [#375](https://github.com/ME-Massine/pulsestream/pull/375) | `fff9a47541c1` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/41221823074) | [Failed](https://github.com/ME-Massine/pulsestream/actions/runs/41221823134) |
| [#376](https://github.com/ME-Massine/pulsestream/pull/376) | `43ff279ffeb3` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/41221827740) | [Failed](https://github.com/ME-Massine/pulsestream/actions/runs/41221827800) |
| [#377](https://github.com/ME-Massine/pulsestream/pull/377) | `d428c11668ec` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/41221829908) | [Failed](https://github.com/ME-Massine/pulsestream/actions/runs/41221829739) |
| [#378](https://github.com/ME-Massine/pulsestream/pull/378) | `99d267660d9c` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/41221837868) | [Failed](https://github.com/ME-Massine/pulsestream/actions/runs/41221837892) |
| [#379](https://github.com/ME-Massine/pulsestream/pull/379) | `90e50d4a7af8` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/41221847370) | [Failed](https://github.com/ME-Massine/pulsestream/actions/runs/41221847301) |

## Ownership and contracts

Owner: @ME-Massine. IDs: PRs #367–#379; related engineering foundations #262
and #263; related implementation #265–#269. C-xx IDs: none assigned for this batch.
Create a dedicated maintenance issue with the supplied text before opening the
consolidated PR; do not close an unrelated implementation issue.

Shared files:

- `.github/workflows/pr-issue-alignment.yml`, `.github/workflows/ci.yml` and
  `scripts/ci/test-pr-issue-alignment.cjs`: CI policy and executable regression tests.
- `CONTRIBUTING.md`: documented Dependabot exception and retained quality gates.
- `infrastructure/docker/docker-compose.yml` and its `README.md`: local images,
  Redis persistence/rollback and Kafka upgrade guidance; corrected stale
  Prometheus/Grafana version documentation.
- All three service `pom.xml` files: aligned supported dependency versions.
- This handoff: validation evidence and developer commands.

Joint review before merge: service owners for Spring Boot/OpenTelemetry and test
compatibility; CI/security owners for the automation policy; platform/observability
owners for Kafka, Redis and Grafana data and recovery behavior. Joint review is
pending. No Java source, contracts, database migrations, Kubernetes image pins,
coverage floors or branch-protection contexts change.

## Validation

| Check | Result |
| --- | --- |
| Java 25 ingestion `clean verify` | Passed: 28 tests, no failures/errors/skips |
| Java 25 processor `clean verify` | Passed: 164 tests, no failures/errors/skips; real PostgreSQL/Kafka integration tests included |
| Java 25 query `clean verify` | Passed: 49 tests, no failures/errors/skips; real PostgreSQL integration tests included |
| JaCoCo lines / branches | Ingestion 90.24% / 57.14%; processor 94.86% / 78.67%; query 98.82% / 97.50%; all floors enforced |
| PR issue-alignment policy | Passed: six Node tests executing the actual workflow script with API stubs |
| Event contract policy | Passed: nine Python tests and compatibility against `origin/main` |
| Windows PowerShell 5.1 offline suite | Passed: 56 parsed sources, 18 regression files, no failures/skips |
| PowerShell 7.4.6 offline suite | Passed: 56 parsed sources, 18 regression files, no failures/skips |
| Compose configuration | Passed |
| Workflow validation with actionlint, ShellCheck disabled | Passed; full lint separately reports existing SC2034 for the unchanged registry-readiness loop |
| Kafka 8.3.2 → 8.4.0 on the same disposable volume | Passed: healthy broker, all four topics retained; pre-upgrade and post-upgrade records consumed |
| Grafana 13.2.4 → 13.3.0 on the same disposable volume | Passed: healthy database, saved dashboard retained and provisioned Prometheus datasource healthy |
| Redis 7 → 8 on the same disposable AOF volume | Passed: original key retained through upgrade, AOF rewrite and restart |
| Service container build/start/probes/non-root validation | Passed: all three images built; liveness, readiness, management health and non-root checks passed; processor applied Flyway V1/V2 |
| `git diff --check` | Passed |
| Consolidated GitHub CI, joint review and live target-cluster rollout | Pending |

Local Java checks use the existing temporary Temurin 25.0.4.1 JDK, matching the
POMs and CI. Logs are under `$env:TEMP/pulsestream-dependabot-367-379-*.log`.
Coverage and Surefire reports are under each service's `target` directory.
The isolated Compose project uses `pulsestream-dependabot-367-379`, strips host
ports/container names and assigns its own named volumes. User stack volumes are
not mounted. The Redis 8 floating tag resolved to 8.10.3 in this run.
The disposable Compose containers, network and test volumes were removed after
validation; the service-image validator also removed its containers and databases.

## Operating effects

Application services must be rebuilt and restarted to adopt Spring Boot and
OpenTelemetry updates. JaCoCo and the JSON Schema validator affect build/test
tooling. No database or JSON event-contract migration is introduced.

The Compose updates affect persistent infrastructure. Back up stopped Kafka,
Redis and Grafana volumes before upgrading an existing environment. Preserve
Kafka cluster identity, test retained messages and delay metadata feature-level
changes through the validation window. Redis keeps the existing AOF command and
mount; preserve the complete multipart AOF backup for rollback. Restore a
pre-upgrade backup with the old image when reverting a migrated volume. The local
smoke test demonstrates a small retained dataset, not production load, failure
recovery or target-cluster readiness. Kubernetes retains its independently
reviewed digest pins.

See [the local upgrade instructions](../../infrastructure/docker/README.md),
[Confluent upgrade guidance](https://docs.confluent.io/platform/current/installation/upgrade.html)
and [Redis standalone upgrade guidance](https://redis.io/docs/latest/operate/oss_and_stack/install/upgrade/standalone/).

## Tracking issue text

Title: `Validate Dependabot dependency updates #367–#379 and fix bot PR alignment`.

<!-- issue-body-start -->
Address Dependabot PRs #367–#379 as one dependency-maintenance batch.

Owner: @ME-Massine. C-xx IDs: none assigned. Related foundations: #262 and #263.

Acceptance criteria:

- Apply all 13 requested version updates consistently across the three services
  and local Compose stack.
- Allow verified Dependabot dependency updates to use generated release notes,
  preserving human PR issue/template requirements and all required quality gates.
- Validate Java tests/coverage, automation policy, script regressions and
  stateful Kafka/Redis/Grafana upgrade behavior.
- Document operating effects, backup/rollback, shared files and joint review
  with service, CI/security and platform/observability owners.

Evidence and developer handoff:
`docs/implementation/dependabot-367-379-handoff.md`.
<!-- issue-body-end -->

## Copy-ready PR text

Title: `chore(deps): validate Dependabot updates and fix bot PR alignment`.

The developer commands replace `MAINTENANCE_ISSUE_NUMBER` with the newly created
issue number before opening the draft PR.

<!-- pr-body-start -->
## Summary

Apply all 13 Dependabot updates from #367–#379 and fix their common PR
issue-alignment failure. Verified Dependabot dependency updates may use their
generated release notes; human PRs still require an issue and the project template.

Owner: @ME-Massine. C-xx IDs: none assigned.

## Related Issue

Closes #MAINTENANCE_ISSUE_NUMBER

Supersedes dependency changes in #367, #368, #369, #370, #371, #372, #373,
#374, #375, #376, #377, #378 and #379. Related foundations: #262 and #263.

## Issue Requirements Covered

- Align Spring Boot 4.1.2 and JaCoCo 0.8.16 in all services, JSON Schema validator
  3.0.8 and OpenTelemetry instrumentation 2.33.1 where used.
- Update local Kafka and its initializer to 8.4.0, Grafana to 13.3.0 and Redis to 8.
- Validate Dependabot author/repository/changed-file scope and preserve CI/review gates.
- Record stateful upgrade behavior, rollback requirements and owner review.

## Changes

Shared files: all three service POMs, local Compose and README, CONTRIBUTING,
PR issue-alignment and CI workflows, the Node policy regression and
`docs/implementation/dependabot-367-379-handoff.md`.

No application source, event schemas, migration SQL, Kubernetes image pins,
coverage floors or required check names change.

## Ownership and contracts

Owner: @ME-Massine. IDs: #367–#379, related #262/#263 and #265–#269.
C-xx IDs: none assigned. Joint review by service, CI/security and
platform/observability owners remains required before merge.

Operating effects: rebuild/restart applications; back up stopped Kafka/Redis/
Grafana volumes before infrastructure upgrades and retain pre-upgrade data for
rollback. The handoff and local platform README describe recovery and validation
limits. No database or event-contract migration is introduced.

## Testing

- Java 25 `clean verify`: ingestion 28, processor 164 and query 49 tests;
  no failures/errors/skips; all coverage floors enforced.
- PR alignment policy: six Node tests. Event contracts: nine Python tests and
  compatibility against the base revision.
- Offline PowerShell suites: 56 parsed sources and 18 regression files on both
  PowerShell 7.4.6 and Windows PowerShell 5.1; no failures/skips.
- Compose configuration and actionlint workflow validation passed.
- All three service images built and passed startup, deployed health probes,
  management health and non-root validation; processor migrations V1/V2 applied.
- Isolated same-volume Kafka and Grafana upgrades retained seeded data;
  Redis retained its original key through upgrade, AOF rewrite and restart.

Full evidence: `docs/implementation/dependabot-367-379-handoff.md`.
Consolidated GitHub CI, joint review and target-cluster rollout remain pending.

## Checklist

- [x] Code builds successfully
- [x] Java tests and coverage checks pass
- [x] Automation and offline script regressions pass
- [x] Upgrade documentation updated
- [x] Linked maintenance issue is referenced
- [x] Changes stay within dependency-maintenance scope
- [ ] Consolidated required GitHub checks pass
- [ ] Joint service, CI/security and platform/observability review complete
<!-- pr-body-end -->

## Developer commands

Review the worktree and evidence, then run these commands. No commit, push,
issue creation or PR publication has been performed.

```powershell
Set-Location C:/Github_Repos/pulsestream-dependabot-367-379
git diff --check
git diff --stat
git add .github/workflows/ci.yml .github/workflows/pr-issue-alignment.yml CONTRIBUTING.md infrastructure/docker/README.md infrastructure/docker/docker-compose.yml services/ingestion-service/pom.xml services/telemetry-processor/pom.xml services/query-service/pom.xml scripts/ci/test-pr-issue-alignment.cjs docs/implementation/dependabot-367-379-handoff.md
git diff --cached
git commit -m "chore(deps): validate Dependabot updates and fix bot PR alignment"
git push -u origin chore/dependabot-updates-367-379

$handoffText = Get-Content docs/implementation/dependabot-367-379-handoff.md -Raw -Encoding UTF8
$issueBody = ($handoffText -split '<!-- issue-body-start -->', 2)[1]
$issueBody = ($issueBody -split '<!-- issue-body-end -->', 2)[0].Trim()
$issueBodyPath = Join-Path $env:TEMP 'pulsestream-dependabot-367-379-issue.md'
[IO.File]::WriteAllText($issueBodyPath, $issueBody, [Text.UTF8Encoding]::new($false))
$trackingIssueUrl = gh issue create --repo ME-Massine/pulsestream --assignee ME-Massine --title "Validate Dependabot dependency updates #367–#379 and fix bot PR alignment" --body-file $issueBodyPath
if ($LASTEXITCODE -ne 0) { throw 'Tracking issue creation failed' }
$trackingIssueNumber = ($trackingIssueUrl.Trim() -split '/')[-1]
if ($trackingIssueNumber -notmatch '^\d+$') { throw 'Expected a numeric tracking issue ID' }

$prBody = ($handoffText -split '<!-- pr-body-start -->', 2)[1]
$prBody = ($prBody -split '<!-- pr-body-end -->', 2)[0].Trim()
$prBody = $prBody.Replace('MAINTENANCE_ISSUE_NUMBER', $trackingIssueNumber)
$prBodyPath = Join-Path $env:TEMP 'pulsestream-dependabot-367-379-pr.md'
[IO.File]::WriteAllText($prBodyPath, $prBody, [Text.UTF8Encoding]::new($false))
gh pr create --repo ME-Massine/pulsestream --base main --head chore/dependabot-updates-367-379 --draft --title "chore(deps): validate Dependabot updates and fix bot PR alignment" --body-file $prBodyPath
```

Check each command's success before continuing. Request joint review after the
draft's required checks pass and before merging. Close superseded Dependabot PRs
only after the consolidated change has merged and its versions are present on
`main`; until then those PRs remain the source proposals.

