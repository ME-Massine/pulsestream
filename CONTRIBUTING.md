## Workflow
1. Pick an issue from Ready
2. Create a feature branch
3. Open a draft PR early
4. Link the PR to the issue
5. Request review before merging

## Branch Naming
- feature/<name>
- fix/<name>
- chore/<name>
- docs/<name>

## Pull Requests
Every pull request must:
- link to an issue
- describe the change
- include testing notes
- update documentation when needed

## Continuous Integration

`.github/workflows/ci.yml` is the quality gate for pull requests into `main`
or `dev`. Push runs are limited to those long-lived branches so a feature
branch with an open pull request does not run the same workflow twice.

Runs are grouped by pull request with `cancel-in-progress`, so a newer commit
cancels the run it supersedes.

The workflow runs these checks:

- Repository file and directory sanity checks.
- A Java 17 Maven `verify` matrix for `ingestion-service`,
  `telemetry-processor`, and `query-service`, with Maven dependency caching.
- JaCoCo reports and per-service non-regression coverage floors, uploaded as
  artifacts and summarized in the job output.
- All service Dockerfiles built and started through the existing container
  validation script, including non-root and health probes.
- Docker Compose configuration validation.
- Strict Kubernetes schema validation, including Strimzi custom resources.
- PowerShell parsing and regression tests on PowerShell 7 and Windows
  PowerShell 5.1.
- Release-manifest consistency and exact image-digest runtime validation.

### Running the checks locally

```bash
# Compile, test, package, report coverage, and enforce the baseline
cd services/ingestion-service && ./mvnw verify

# Compose configuration
docker compose -f infrastructure/docker/docker-compose.yml config --quiet
```

```powershell
# Parse every script/module, then run each regression test in a child process
pwsh -File scripts/tests/run-all-tests.ps1
powershell -File scripts\tests\run-all-tests.ps1
```

Two PowerShell tests use `kubectl` client-side serialization and therefore need
API discovery. The CI jobs create a disposable Kubernetes API for those tests.
When running locally without a reachable cluster, the runner reports those
tests as skipped by name and fails the gate; the Kubernetes manifests are still
checked by the strict schema job. A skipped test is not counted as a pass.

### Coverage baseline

Each service declares `jacoco.coverage.line.minimum` and
`jacoco.coverage.branch.minimum` in its POM. These are initial non-regression
floors measured from the existing tests, not aspirational targets. A change
that drops below a floor must add coverage or intentionally revise the baseline
with supporting test evidence.

### Required checks on `main`

The intended branch ruleset, required check contexts, and administrator apply
commands are in [.github/rulesets/README.md](.github/rulesets/README.md). The
ruleset also requires all review conversations to be resolved. If a CI job is
renamed, added, or removed, update
`.github/rulesets/main-branch-protection.json` in the same pull request and
re-apply the ruleset: a required check that never reports blocks every merge.

## Issue Types

- **Feature**: a meaningful platform capability or service-level increment
- **Task**: a concrete implementation step, usually under a feature
- **Bug**: a defect or incorrect behavior that needs fixing
