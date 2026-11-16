# Dependabot PRs #392-#394 handoff

Owner: @ME-Massine. Prepared: 2026-11-16.
Branch: `chore/dependabot-updates-392-394`.
Base: `origin/main` at `dc432fa9ab9c9392a8fc2d8f1c4ca8f0c1512c5b`, including #391.
Worktree: `C:/Github_Repos/pulsestream-dependabot-392-394`.

Preparation state: changes are local and uncommitted. The original worktree
remains on `feature/270-postgres-kafka-consistency` with its existing untracked
files. No commits, pushes, merges, publications, comments or PR closures were
performed for this batch. Publication and closure are developer actions below.

## Outcome

Consolidate all three open Dependabot proposals into a coordinated Maven 3.10.1
upgrade for service wrappers and container builders, retaining Java 25 under
[ADR 0006](../decisions/0006-java-25-runtime-baseline.md).

| PR | Service | Inspected head | Disposition |
| --- | --- | --- | --- |
| [#392](https://github.com/ME-Massine/pulsestream/pull/392) | Ingestion | `42b7f4cdbdd542441d5b5364ed0dcbd06e5a3517` | Apply Maven 3.10.1 and verified ZIP checksum |
| [#393](https://github.com/ME-Massine/pulsestream/pull/393) | Processor | `948d2fb0a44084312d488f354e54e3cc98007bb8` | Apply Maven 3.10.1 and verified ZIP checksum |
| [#394](https://github.com/ME-Massine/pulsestream/pull/394) | Query | `2649c67659960d1d5231a806582326b6ea79dde5` | Apply Maven 3.10.1 and verified ZIP checksum |

Each original PR changes only its wrapper properties. Applying them alone
would leave container builders on Maven 3.10.0. All three Dockerfiles now build
on `eclipse-temurin:25-jdk`, download the same Maven 3.10.1 ZIP as the wrappers
with Docker `ADD --checksum=sha256:...`, extract it with the JDK's `jar` tool,
and expose its launcher through `MAVEN_HOME` and `PATH`.

The expected `maven:3.10.1-eclipse-temurin-25` image was unavailable: both a
registry manifest request and `docker pull` returned not found. The verified
distribution bootstrap keeps the wrapper and builder versions aligned without
adopting a Java 26 image. It requires Docker BuildKit supporting
[`ADD --checksum`](https://docs.docker.com/reference/dockerfile/#add---checksum).
Version, distribution URL and checksum must be updated together in all three
wrapper property files and Dockerfiles during subsequent maintenance.

The ZIP at
`https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.10.1/apache-maven-3.10.1-bin.zip`
was independently downloaded and matched both Dependabot's SHA-256 and Apache's
published SHA-512. The shared SHA-256 is:

```text
9c1ef9174ef250a5009ed0dec97cbe8699acf7479add4e62bf7b0ea791c0adb5
```

[Apache's release notes](https://maven.apache.org/docs/3.10.1/release-notes.html)
describe 3.10.1 as a bugfix release for 3.10.0, including regression fixes and
lighter startup. Existing build/test plugin versions and application dependencies
remain defined by the current POMs.

## Remote evidence

All three PRs were open and mergeable when inspected, with no inline review
threads. Each inspected head passed CI, CodeQL, dependency review and PR issue
alignment. These checks describe the original wrapper-only proposals; the
consolidated change still requires its own GitHub checks and joint review.

| PR | Passing CI |
| --- | --- |
| #392 | [CI run 43898037316](https://github.com/ME-Massine/pulsestream/actions/runs/43898037316) |
| #393 | [CI run 43898065549](https://github.com/ME-Massine/pulsestream/actions/runs/43898065549) |
| #394 | [CI run 43898084636](https://github.com/ME-Massine/pulsestream/actions/runs/43898084636) |

## Ownership, shared files and operating effects

Owner: @ME-Massine. IDs: #392, #393 and #394; prior policy change #391.
C-xx IDs: none assigned. Contract: ADR 0006.

Shared files: each service's `.mvn/wrapper/maven-wrapper.properties` and
`Dockerfile`, `docs/architecture/container-build-standard.md`, ADR 0006,
`CONTRIBUTING.md` and this handoff. The container standard includes the complete
verified Maven bootstrap; contributing guidance records the Unix `unzip` prerequisite.
Joint review remains pending with all three service owners and CI/platform/
security owners for distribution integrity, build support and Java 25 alignment.

Local and CI builds use Maven 3.10.1 after the wrappers download and validate
the ZIP. Container builds use the same ZIP, and fail if its SHA-256 differs.
The Maven bootstrap and dependencies remain in the build stage; runtime images
retain the Java 25 JRE, Spring Boot layered launcher and non-root user. Rebuild
service images to use the updated build tool. No database or event-contract
migration, infrastructure-volume upgrade or Kubernetes image change is involved.

Maven builder-image ignores from #391 remain in place. Future Maven distribution
updates still require coordinated wrapper/bootstrap maintenance. POMs, coverage
floors, workflow permissions and required check names are unchanged.

## Validation

| Check | Result |
| --- | --- |
| Maven ZIP integrity | Passed: independently checked SHA-256 and published SHA-512 |
| Wrapper/bootstrap alignment | Passed: all three URLs, checksums, versions and Java 25 bootstrap blocks match |
| Native Windows wrapper launch | Passed: all three `mvnw.cmd --version` commands report Maven 3.10.1 |
| Container builder tool versions | Passed: extracted builder reports Maven 3.10.1 on Temurin 25.0.5 |
| Java 25 Maven `clean verify`, all services | Passed: ingestion 29, processor 174 and query 49 tests; no failures, errors or skips; all coverage gates enforced |
| Container build, non-root and deployed health probes, all services | Passed: all images built; deployed liveness/readiness and management health passed; processor migration checks passed |
| PR issue-alignment policy | Passed: six Node tests |
| Compose configuration | Passed |
| `git diff --check` | Passed |
| Consolidated GitHub CI and joint review | Pending |

Logs are under `$env:TEMP/pulsestream-dependabot-392-394-*`. Surefire and JaCoCo
reports are under each service's `target` directory in the maintenance worktree.
Application tests run in a Java 25 JDK container through the updated wrappers;
PostgreSQL tests use the Docker socket and disposable databases. The first cold
Linux wrapper attempt encountered a missing `unzip`: the wrapper substituted a
tarball while retaining the ZIP checksum and correctly failed verification.
The local cache was then prepared from the independently verified ZIP. Wrapper
scripts and checksum checks were not weakened or modified.

Native Windows wrapper launch checks use the installed Java 21 only to verify
the wrapper and Maven startup. Application compilation/tests and container
builds use Java 25. Container validation uses `-Network bridge`, an isolated
image-tag prefix and temporary PostgreSQL instances; user stack data is unused.

Measured line/branch coverage: ingestion 90.48%/50.00%, processor
95.38%/85.37%, query 98.82%/97.50%. All three Maven builds and the container
validator exited successfully. Validation containers and disposable validation
databases were removed. Local image tags, Maven caches, reports and logs remain
available for review and repeatable validation.

## Tracking issue text

Title: `Coordinate Maven 3.10.1 wrappers and Java 25 container builders`.

<!-- issue-body-start -->
Address Dependabot PRs #392, #393 and #394 as one Maven toolchain update.

Owner: @ME-Massine. C-xx IDs: none assigned. Contract: ADR 0006. Related: #391.

Acceptance criteria:

- Upgrade all three wrappers to Maven 3.10.1 with the independently verified ZIP
  SHA-256 and align every Docker builder with that same version and checksum.
- Retain Java 25 and verify the Maven bootstrap instead of depending on the
  unavailable `maven:3.10.1-eclipse-temurin-25` tag.
- Pass service tests/coverage, container build/start/probes/non-root checks and
  toolchain alignment checks; document operating effects and joint review.

Evidence: `docs/implementation/dependabot-392-394-handoff.md`.
<!-- issue-body-end -->

## Copy-ready PR text

Title: `chore(deps): align Maven 3.10.1 wrappers and Java 25 builders`.

<!-- pr-body-start -->
## Summary

Upgrade all service wrappers and Docker builders to Maven 3.10.1 while retaining
Java 25. Builders install the same SHA-256-pinned Apache ZIP as the wrappers,
because the matching Maven/Java 25 image tag is unavailable.

Owner: @ME-Massine. C-xx IDs: none assigned. Contract: ADR 0006.

## Related Issue

Closes #MAINTENANCE_ISSUE_NUMBER

Supersedes #392, #393 and #394. Related policy: #391.

## Issue Requirements Covered

- Align Maven version, ZIP URL and SHA-256 across all wrappers and builders.
- Retain Java 25 and enforce distribution integrity during Docker builds.
- Validate tests, coverage, container startup and health; update build guidance.

## Changes

Shared files: three wrapper property files, three Dockerfiles, CONTRIBUTING,
the container build standard, ADR 0006 and
`docs/implementation/dependabot-392-394-handoff.md`.

Joint review by ingestion, processor, query and CI/platform/security owners is
pending. Operating effects: wrappers download Maven 3.10.1; rebuild service
images using BuildKit with `ADD --checksum` support. Maven remains confined to
the builder stage. Database/event contracts, runtime configuration, Kubernetes
image pins, coverage floors and required CI contexts are unchanged.

## Testing

- Independent ZIP SHA-256 and published SHA-512 verification passed.
- All three wrapper/bootstrap URLs, versions and checksums match.
- All native Windows wrappers report Maven 3.10.1.
- The extracted container builder reports Maven 3.10.1 on Temurin 25.0.5.
- All three service images built and passed non-root, deployed liveness/readiness
  and management-health checks; processor migration checks passed.
- Six Node policy tests, Compose configuration and whitespace checks passed.
- Java 25 Maven `clean verify`: ingestion 29, processor 174 and query 49 tests;
  no failures, errors or skips, with all coverage gates enforced.
- Original #392-#394 heads pass CI, CodeQL, dependency review and issue alignment.

Evidence: `docs/implementation/dependabot-392-394-handoff.md`.
Consolidated required GitHub checks and joint owner review remain pending.

## Checklist

- [x] Verified distribution integrity and coordinated version/checksum updates
- [x] Build and operating documentation updated
- [x] All service tests and coverage gates pass on Java 25 and Maven 3.10.1
- [x] All service images build and pass non-root, startup and deployed health probes
- [ ] Consolidated required GitHub checks pass
- [ ] Joint service and CI/platform/security review complete
- [ ] Superseded Dependabot PRs closed after merge
<!-- pr-body-end -->

## Developer commands

Review the worktree and validation, then execute these commands. Check each
command's exit status before continuing. No publication has been performed.

```powershell
Set-Location C:/Github_Repos/pulsestream-dependabot-392-394
git diff --check
git diff --stat
git add services/ingestion-service/.mvn/wrapper/maven-wrapper.properties services/ingestion-service/Dockerfile services/telemetry-processor/.mvn/wrapper/maven-wrapper.properties services/telemetry-processor/Dockerfile services/query-service/.mvn/wrapper/maven-wrapper.properties services/query-service/Dockerfile CONTRIBUTING.md docs/architecture/container-build-standard.md docs/decisions/0006-java-25-runtime-baseline.md docs/implementation/dependabot-392-394-handoff.md
git diff --cached
git commit -m "chore(deps): align Maven 3.10.1 wrappers and Java 25 builders"
git push -u origin chore/dependabot-updates-392-394

$handoffText = Get-Content docs/implementation/dependabot-392-394-handoff.md -Raw -Encoding UTF8
$issueBody = ($handoffText -split '<!-- issue-body-start -->', 2)[1]
$issueBody = ($issueBody -split '<!-- issue-body-end -->', 2)[0].Trim()
$issueBodyPath = Join-Path $env:TEMP 'pulsestream-dependabot-392-394-issue.md'
[IO.File]::WriteAllText($issueBodyPath, $issueBody, [Text.UTF8Encoding]::new($false))
$trackingIssueUrl = gh issue create --repo ME-Massine/pulsestream --assignee ME-Massine --title "Coordinate Maven 3.10.1 wrappers and Java 25 container builders" --body-file $issueBodyPath
if ($LASTEXITCODE -ne 0) { throw 'Tracking issue creation failed' }
$trackingIssueNumber = ($trackingIssueUrl.Trim() -split '/')[-1]
if ($trackingIssueNumber -notmatch '^\d+$') { throw 'Expected a numeric tracking issue ID' }

$prBody = ($handoffText -split '<!-- pr-body-start -->', 2)[1]
$prBody = ($prBody -split '<!-- pr-body-end -->', 2)[0].Trim()
$prBody = $prBody.Replace('MAINTENANCE_ISSUE_NUMBER', $trackingIssueNumber)
$prBodyPath = Join-Path $env:TEMP 'pulsestream-dependabot-392-394-pr.md'
[IO.File]::WriteAllText($prBodyPath, $prBody, [Text.UTF8Encoding]::new($false))
gh pr create --repo ME-Massine/pulsestream --base main --head chore/dependabot-updates-392-394 --draft --title "chore(deps): align Maven 3.10.1 wrappers and Java 25 builders" --body-file $prBodyPath
if ($LASTEXITCODE -ne 0) { throw 'Draft PR creation failed' }
```

Request joint review after required checks pass, before merging. After the
consolidated PR merges and the new toolchain is present on `main`, close the
superseded wrapper-only proposals:

```powershell
$closureReason = 'Superseded by the coordinated Maven 3.10.1 wrapper and Java 25 builder update on main. See docs/implementation/dependabot-392-394-handoff.md.'
foreach ($prNumber in 392, 393, 394) {
    gh pr close $prNumber --repo ME-Massine/pulsestream --comment $closureReason
    if ($LASTEXITCODE -ne 0) { throw "Failed to close PR #$prNumber" }
}
```
