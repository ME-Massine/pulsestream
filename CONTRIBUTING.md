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

## Issue Types

- **Feature**: a meaningful platform capability or service-level increment
- **Task**: a concrete implementation step, usually under a feature
- **Bug**: a defect or incorrect behavior that needs fixing

## Continuous Integration

`.github/workflows/ci.yml` is the only quality gate between a branch and `main`.
It runs on every pull request into `main` or `dev`, and on pushes to those two
branches. Feature branches are deliberately not built on push: a branch with an
open pull request would otherwise run the whole workflow twice for one commit.

Runs are grouped per pull request with `cancel-in-progress`, so pushing a new
commit cancels the run it superseded instead of leaving two runs competing for
runners.

### Jobs

| Job | Runner | What fails it |
| --- | --- | --- |
| Repository sanity checks | ubuntu | A required repository file or docs directory is missing |
| Service verify (per service) | ubuntu | `./mvnw verify` fails: compilation, a test, or the coverage baseline |
| Service image (per service) | ubuntu | The Dockerfile fails to build, or the image would run as root. The telemetry-processor image is additionally started and required to reach a running Spring context as a non-root process |
| Docker Compose configuration | ubuntu | `docker compose config` rejects `infrastructure/docker/docker-compose.yml` |
| Kubernetes manifests | ubuntu | `kubeconform -strict` rejects a manifest under `infrastructure/kubernetes`, including the Strimzi custom resources |
| PowerShell checks (per edition) | windows | A script or module under `scripts/` fails to parse, or a regression test in `scripts/tests/` fails |

All three services are built and tested on Java 17, matching `<java.version>` in
the POMs and the `eclipse-temurin:17` images the Dockerfiles use. Maven
dependencies are cached by `actions/setup-java` keyed on the committed POMs; the
local repository is never committed.

### Coverage

Each service runs JaCoCo during `verify` and produces a report under
`target/site/jacoco/`, uploaded as a run artifact and summarised in the run's
job summary.

Coverage cannot silently regress: `jacoco:check` enforces a per-service
baseline, declared in each POM as

```xml
<jacoco.coverage.line.minimum>...</jacoco.coverage.line.minimum>
<jacoco.coverage.branch.minimum>...</jacoco.coverage.branch.minimum>
```

These are floors measured from the code as it stood when JaCoCo was introduced,
not targets. Raise them when coverage improves. Never lower one to make a build
pass - a change that drops coverage below the floor should add the missing
tests.

### Running the checks locally

```bash
# One service: compile, test, coverage report and coverage baseline
cd services/ingestion-service && ./mvnw verify

# Compose file
docker compose -f infrastructure/docker/docker-compose.yml config --quiet

# Service image
docker build -t pulsestream/ingestion-service:local services/ingestion-service
```

```powershell
# Parse every script and module under scripts\, then run every regression test
pwsh -File scripts/tests/run-all-tests.ps1
powershell -File scripts\tests\run-all-tests.ps1
```

Two of the PowerShell tests turn a committed manifest into JSON with `kubectl
create --dry-run=client`, which resolves the kind through API discovery and so
needs a reachable cluster. They run locally against a local cluster and report
as skipped, by name, where none answers - including on CI runners. The manifests
they cover are schema-checked by the Kubernetes manifests job regardless.

### Required checks on `main`

The checks the ruleset requires before a merge, and how to apply that ruleset,
are documented in [.github/rulesets/README.md](.github/rulesets/README.md).
Review conversations must also be resolved before merge. When a job in
`ci.yml` is renamed, added or removed, update
`.github/rulesets/main-branch-protection.json` in the same pull request and
re-apply it: a required check that never reports blocks every merge, and a
renamed job silently stops being required.
