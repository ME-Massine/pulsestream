# Dependabot PRs #384-#389 handoff

Owner: @ME-Massine. Prepared: 2026-11-16.
Branch: `chore/dependabot-updates-384-389`.
Base: `origin/main` at `9f9f2c6476da557cd707a96d3f9850d5fbb3a7fd`.
Worktree: `C:/Github_Repos/pulsestream-dependabot-384-389`.

Changes are uncommitted. The original worktree remains on
`feature/270-postgres-kafka-consistency`, including its existing untracked files.
No commits, pushes, merges, PR publications, comments or closures were performed.
The failed Grafana PR sanity job was rerun through GitHub Actions and passed.

## Outcome and disposition

All six open Dependabot PRs were inspected, including their complete patches,
head revisions, workflow results and review threads. Three infrastructure
updates are consolidated locally. Three Java 26 builder proposals are declined
under [ADR 0006](../decisions/0006-java-25-runtime-baseline.md).

| PR | Proposal | Prepared disposition |
| --- | --- | --- |
| [#384](https://github.com/ME-Massine/pulsestream/pull/384) | Grafana 13.3.0 to 13.3.1 | Apply in Compose and update operating documentation |
| [#385](https://github.com/ME-Massine/pulsestream/pull/385) | Ingestion Maven builder to Java 26 | Keep Java 25; close proposal after the policy change merges |
| [#386](https://github.com/ME-Massine/pulsestream/pull/386) | Query Maven builder to Java 26 | Keep Java 25; close proposal after the policy change merges |
| [#387](https://github.com/ME-Massine/pulsestream/pull/387) | Prometheus v3.15.1 to v3.16.0 | Apply in Compose and update operating documentation |
| [#388](https://github.com/ME-Massine/pulsestream/pull/388) | Processor Maven builder to Java 26 | Keep Java 25; close proposal after the policy change merges |
| [#389](https://github.com/ME-Massine/pulsestream/pull/389) | Kafka 8.4.0 to 8.4.1 | Apply to both broker and topic initializer |

All service builders retain `maven:3.10.0-eclipse-temurin-25`, aligned with the
wrappers, POMs, Java 25 runtimes and CI. `.github/dependabot.yml` ignores the
`maven` Docker image across the three service directories. This also suppresses
automatic Maven builder fixes on Java 25: the owner must review builder images
and wrapper updates together during dependency maintenance. Docker ignore
version constraints compare the numeric release, so a Java-suffix wildcard is
not a supported way to keep one Java line. Other images, Maven libraries and
GitHub Actions remain monitored. The ADR records this operating tradeoff and
requires revisiting the rule during the next coordinated toolchain upgrade.

## Remote evidence

Release review: [Grafana 13.3.1](https://github.com/grafana/grafana/releases/tag/v13.3.1)
includes security fixes. [Prometheus 3.16.0](https://github.com/prometheus/prometheus/releases/tag/v3.16.0)
changes experimental search limits, TLS external-URL defaults and deprecated
Remote Write 2.0 metrics; the local configuration uses plain HTTP and scrape
jobs without remote write. [Confluent 8.4.1](https://docs.confluent.io/platform/8.4/release-notes/index.html#confluent-platform-release-8-4-1)
documents Kafka Connect admin authorization changes; this stack runs the Kafka
broker and topic initializer without Kafka Connect. Configuration review found
no required flag or query edits for the committed local setup. Persistent-data
checks remain a separate validation requirement below.

All six PRs were open and mergeable when inspected. No inline review threads
were present. CI, CodeQL, dependency review and PR issue alignment now pass for
each inspected head. Green checks do not override the Java baseline decision.

| PR | Inspected head | CI evidence |
| --- | --- | --- |
| #384 | `499858100c3fcc49c20e8f5069355393dd9d174f` | [Passed after rerun](https://github.com/ME-Massine/pulsestream/actions/runs/43618004482) |
| #385 | `bf5cf0403b136d3ff1004241d70049398eed3dda` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/43618014229) |
| #386 | `416e8f23d9a03efd8073ba4fa46ceeaccd55152e` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/43618014808) |
| #387 | `eed77dd14e6f4741bded2e494520621b0de850b5` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/43618016554) |
| #388 | `82a36ddf2dbe88fac3bd44a8cce09a4b14b8fe07` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/43618019865) |
| #389 | `49d7dff36084d718736fc08a0910c45c6efc9f02` | [Passed](https://github.com/ME-Massine/pulsestream/actions/runs/43618021201) |

The original #384 failure was limited to `Repository sanity checks`, at
`Download artifact compatibility fixture`: the download action reported
`Artifact not found` immediately after a successful upload. Its service builds,
container probes and other jobs had passed. The rerun passed without a code or
workflow change. These CI results describe the individual remote PRs; the
unpublished consolidated branch still needs its own required checks and review.

## Ownership and shared files

Owner: @ME-Massine. IDs: #384, #385, #386, #387, #388 and #389.
C-xx IDs: none assigned. Architectural contract: ADR 0006.
Create a dedicated maintenance issue with the supplied text for the human PR.

Shared files:

- `.github/dependabot.yml`: builder image update policy across all services.
- `docs/decisions/0006-java-25-runtime-baseline.md`: manual toolchain maintenance
  and the reason for the image ignore rule.
- `infrastructure/docker/docker-compose.yml`: Kafka broker/initializer,
  Prometheus and Grafana image versions.
- `infrastructure/docker/README.md`: matching versions and existing backup,
  verification and restore procedures.
- This handoff: disposition, validation and developer commands.

Joint review before merge: platform/operations owners for Kafka data and
recovery, observability owners for Grafana/Prometheus persistence and queries,
and service/CI/security owners for coordinated builder maintenance. Joint review
is pending. No application source, dependency POMs, database migrations, event
contracts, Kubernetes image pins, coverage floors or required check names change.

## Local validation

| Check | Result |
| --- | --- |
| Compose configuration | Passed |
| Prometheus 3.16.0 `promtool check config` | Passed with the committed scrape configuration |
| Dependabot YAML parsing and Docker rule inspection | Passed |
| PR issue-alignment policy | Passed: six Node tests |
| Event-contract policy and baseline compatibility | Passed: nine Python tests; compatibility against the base SHA above |
| Windows PowerShell 5.1 offline suite | Passed: 56 parsed files, 18 regression files, no failures or skips |
| PowerShell 7.4.6 native offline suite | Passed: 56 parsed files, 18 regression files, no failures or skips |
| Java 25 Maven verify, all three services | Passed: ingestion 29, processor 174 and query 49 tests; no failures, errors or skips; all coverage gates enforced |
| Kafka 8.4.0 to 8.4.1 on the same disposable volume | Passed: all four topics and pre/post-upgrade records retained |
| Grafana 13.3.0 to 13.3.1 on the same disposable volume | Passed: saved dashboard retained; provisioned datasource health and query passed |
| Prometheus v3.15.1 to v3.16.0 on the same disposable volume | Passed: historical self-scrape sample retained; current scrape and reported version verified |
| `git diff --check` | Passed |
| Consolidated GitHub CI, joint review and live rollout | Pending |

Validation logs and the disposable upgrade harness are under
`$env:TEMP/pulsestream-dependabot-384-389-*`. Maven verification uses the Java 25
JDK container with the committed wrappers, the local Maven cache, and the Docker
socket for PostgreSQL integration tests. Surefire and JaCoCo reports are in each
service's `target` directory. PowerShell 7.4.6 and PowerShell 5.1 validation run
natively on Windows; PowerShell 7 uses a portable temporary installation.

Measured line/branch coverage: ingestion 90.48%/50.00%, processor
95.38%/85.37%, and query 98.82%/97.50%. The first PowerShell 7 Linux attempt
encountered environment failures: missing Git and CRLF shell fixtures from the
Windows checkout. Those failures did not require repository changes.

The upgrade harness derives its configuration from Compose, selects Kafka,
its initializer, Grafana and Prometheus, and gives all containers, networks and
volumes the isolated project prefix `pulsestream-dependabot-384-389`. HTTP ports
are allocated dynamically on loopback. It seeds a Kafka record, a saved Grafana
dashboard and a Prometheus self-scrape sample on the previous image versions,
then upgrades with those same disposable volumes. User stack volumes and fixed
ports are not used. The harness removes its project resources after validation.

The Docker host's automatic address pools were exhausted, so the disposable
network used the explicit `10.254.248.0/24` subnet after checking existing Docker
networks for overlap. Slow image pulls required parallel range downloads from
the official registry. Every image blob's size and SHA-256 digest was verified
against its manifest before loading. Tests used Linux amd64 images:

| Image | Tested platform manifest digest |
| --- | --- |
| `confluentinc/cp-kafka:8.4.1` | `sha256:b03f1069add027c142160c0f87ceaaba49227a5717e358377281ae384801a698` |
| `grafana/grafana:13.3.1` | `sha256:1c88285f1dd391a62232c010e6c224846e6a73bdc583b3365be2eba614b7919e` |
| `prom/prometheus:v3.16.0` | `sha256:89c1a644817e9ad70fa2af76c84898e327c1de7063735f962e8313b1e28672c3` |

The disposable stack, its network and volumes, and the temporary image-pull
engine were removed. Large transfer archives were removed. Downloaded image
tags remain cached in Docker. The temporary image-layer files remain at
`$env:TEMP/pulsestream-dependabot-384-389-images`; the developer may remove that
specific directory after reviewing the evidence. Logs, temporary harnesses and
portable PowerShell remain available for inspection.

## Operating effects

Recreate the local Kafka, Prometheus and Grafana containers to adopt the updates;
rerun `kafka-init` with the matching broker image. Pause producers/consumers and
back up stopped Kafka, Grafana and Prometheus volumes before upgrading an
existing environment. Preserve Kafka cluster identity and avoid metadata
feature-level changes during validation. Restore pre-upgrade backups with the
previous images for rollback, following the
[local platform instructions](../../infrastructure/docker/README.md).

No application rebuild or database/event-contract migration is introduced.
Small disposable-volume checks do not establish production capacity, failure
recovery or target-cluster readiness. Builder image and wrapper fixes now need
coordinated manual maintenance by the owner.

## Tracking issue text

Title: `Address Dependabot PRs #384-#389 and preserve the Java 25 baseline`.

<!-- issue-body-start -->
Address all six Dependabot PRs #384-#389.

Owner: @ME-Massine. C-xx IDs: none assigned. Contract: ADR 0006.

Acceptance criteria:

- Apply Kafka 8.4.1 to the broker and initializer, Grafana 13.3.1 and Prometheus
  v3.16.0 to local Compose, with matching operating documentation.
- Decline Java 26 builders in #385, #386 and #388 under ADR 0006 and suppress
  repeated Maven builder proposals. Document manual builder/wrapper maintenance.
- Validate service builds/coverage, policy/script checks and retained Kafka,
  Grafana and Prometheus data across isolated upgrades.
- Obtain joint platform, observability, service/CI/security review and close the
  superseded proposals after the consolidated change merges.

Evidence: `docs/implementation/dependabot-384-389-handoff.md`.
<!-- issue-body-end -->

## Copy-ready PR text

Title: `chore(deps): address Dependabot updates and preserve Java 25 builders`.

<!-- pr-body-start -->
## Summary

Apply the infrastructure updates from #384, #387 and #389, and preserve the Java
25 build/runtime contract for #385, #386 and #388. Suppress automatic `maven`
Docker image proposals and document coordinated manual builder/wrapper updates.

Owner: @ME-Massine. C-xx IDs: none assigned. Contract: ADR 0006.

## Related Issue

Closes #MAINTENANCE_ISSUE_NUMBER

Supersedes dependency proposals #384, #385, #386, #387, #388 and #389.

## Issue Requirements Covered

- Kafka broker and initializer use 8.4.1; Grafana uses 13.3.1 and Prometheus
  uses v3.16.0, with matching upgrade documentation.
- Java 25 and the wrapper-aligned Maven builder remain the service baseline.
- Dependabot policy prevents recurring Maven builder proposals. Builder fixes
  require manual coordinated maintenance, including fixes on Java 25.
- Record retained-data validation, backup/restore and joint owner review.

## Changes

Shared files: `.github/dependabot.yml`, ADR 0006, local Compose and its README,
and `docs/implementation/dependabot-384-389-handoff.md`.

Joint review required from platform/operations, observability and
service/CI/security owners. Review remains pending.

Operating effects: recreate the three updated infrastructure services and rerun
the topic initializer; back up stopped persistent volumes and retain pre-upgrade
backups for restore. Builder images and wrappers need coordinated manual
maintenance. Application source, database/event contracts, Kubernetes image
pins and required CI contexts are unchanged.

## Testing

- Compose configuration, Dependabot YAML parsing and policy inspection passed.
- Six Node PR-policy tests and nine Python contract-policy tests passed;
  event contracts are compatible with the base revision.
- Windows PowerShell 5.1: 56 parsed files and 18 offline regression files passed.
- Native PowerShell 7.4.6: the same 56 sources and 18 regression files passed.
- Java 25 Maven `verify`: ingestion 29, processor 174 and query 49 tests;
  no failures, errors or skips, with all coverage gates enforced.
- Isolated same-volume Kafka, Grafana and Prometheus upgrades retained seeded
  records, a saved dashboard and historical samples. All four Kafka topics,
  Grafana datasource health/query and current Prometheus scraping passed.
- Prometheus 3.16.0 `promtool` accepted the committed scrape configuration.
- All six inspected remote PR heads pass CI, CodeQL, dependency review and PR
  issue alignment; #384 passed after rerunning an artifact-download failure.

Full evidence: `docs/implementation/dependabot-384-389-handoff.md`.
Consolidated GitHub checks, joint review and live rollout remain pending.

## Checklist

- [x] Dependency versions and operating documentation updated
- [x] Policy, contract and Windows offline checks pass
- [x] All three services build, pass tests and enforce coverage on Java 25
- [x] Same-volume infrastructure upgrades retain seeded data and pass smoke checks
- [ ] Consolidated required GitHub checks pass
- [ ] Joint owner review complete
- [ ] Superseded Dependabot PRs closed after merge
<!-- pr-body-end -->

## Developer commands

Review the changes and evidence, then execute these commands. Publication and
closure remain developer actions.

```powershell
Set-Location C:/Github_Repos/pulsestream-dependabot-384-389
git diff --check
git diff --stat
git add .github/dependabot.yml docs/decisions/0006-java-25-runtime-baseline.md infrastructure/docker/docker-compose.yml infrastructure/docker/README.md docs/implementation/dependabot-384-389-handoff.md
git diff --cached
git commit -m "chore(deps): address Dependabot updates and preserve Java 25 builders"
git push -u origin chore/dependabot-updates-384-389

$handoffText = Get-Content docs/implementation/dependabot-384-389-handoff.md -Raw -Encoding UTF8
$issueBody = ($handoffText -split '<!-- issue-body-start -->', 2)[1]
$issueBody = ($issueBody -split '<!-- issue-body-end -->', 2)[0].Trim()
$issueBodyPath = Join-Path $env:TEMP 'pulsestream-dependabot-384-389-issue.md'
[IO.File]::WriteAllText($issueBodyPath, $issueBody, [Text.UTF8Encoding]::new($false))
$trackingIssueUrl = gh issue create --repo ME-Massine/pulsestream --assignee ME-Massine --title "Address Dependabot PRs #384-#389 and preserve the Java 25 baseline" --body-file $issueBodyPath
if ($LASTEXITCODE -ne 0) { throw 'Tracking issue creation failed' }
$trackingIssueNumber = ($trackingIssueUrl.Trim() -split '/')[-1]
if ($trackingIssueNumber -notmatch '^\d+$') { throw 'Expected a numeric tracking issue ID' }

$prBody = ($handoffText -split '<!-- pr-body-start -->', 2)[1]
$prBody = ($prBody -split '<!-- pr-body-end -->', 2)[0].Trim()
$prBody = $prBody.Replace('MAINTENANCE_ISSUE_NUMBER', $trackingIssueNumber)
$prBodyPath = Join-Path $env:TEMP 'pulsestream-dependabot-384-389-pr.md'
[IO.File]::WriteAllText($prBodyPath, $prBody, [Text.UTF8Encoding]::new($false))
gh pr create --repo ME-Massine/pulsestream --base main --head chore/dependabot-updates-384-389 --draft --title "chore(deps): address Dependabot updates and preserve Java 25 builders" --body-file $prBodyPath
if ($LASTEXITCODE -ne 0) { throw 'Draft PR creation failed' }
```

Check each command's success before continuing. Request joint review before
merging, after the consolidated branch passes required checks.

Optional local download-cache cleanup after reviewing the evidence:

```powershell
$imageCachePath = Join-Path $env:TEMP 'pulsestream-dependabot-384-389-images'
Get-Item -LiteralPath $imageCachePath
Remove-Item -LiteralPath $imageCachePath -Recurse
```

Only after the consolidated PR has merged and its changes are present on
`main`, close the superseded PRs. Commands below intentionally omit `--delete-branch`.

```powershell
$acceptedReason = 'Superseded by the consolidated Dependabot maintenance change on main; requested infrastructure versions are applied. See docs/implementation/dependabot-384-389-handoff.md.'
foreach ($prNumber in 384, 387, 389) {
    gh pr close $prNumber --repo ME-Massine/pulsestream --comment $acceptedReason
    if ($LASTEXITCODE -ne 0) { throw "Failed to close PR #$prNumber" }
}
$declinedReason = 'Declined under ADR 0006: builders, tests and runtimes stay on Java 25. The coordinated Maven builder/wrapper maintenance policy is recorded in docs/decisions/0006-java-25-runtime-baseline.md and .github/dependabot.yml.'
foreach ($prNumber in 385, 386, 388) {
    gh pr close $prNumber --repo ME-Massine/pulsestream --comment $declinedReason
    if ($LASTEXITCODE -ne 0) { throw "Failed to close PR #$prNumber" }
}
```
