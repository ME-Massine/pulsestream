# Issue #266 implementation handoff

Owner: Massine AMAKHTARI (`@ME-Massine`).
Issue: [#266](https://github.com/ME-Massine/pulsestream/issues/266).
Branch: `feature/266-processed-telemetry-query`, based on `origin/main` at
`ea024e1` (merged migration PR #355). No commit, push, merge or publication has
been performed for this implementation.

## Outcome

`GET /api/v1/telemetry` reads processed telemetry for the authenticated tenant.
It supports exact device matching, inclusive `from` and exclusive `to` timestamp
filters, zero-based pages 0–10000, and sizes 1–100 (default 50). SQL always
includes tenant scope and orders by `timestamp DESC, id DESC`. The response is
`{content, page, size, hasNext}`; it fetches one lookahead row without a count query.
Unknown/repeated parameters and tenant overrides return controlled 400 responses.
Database failures return 503. Responses use `Cache-Control: no-store`.

The tenant source is an authenticated servlet principal whose name is the
authorized tenant ID. Authentication integration must supply this principal;
raw headers cannot establish it. Until that integration is installed, ordinary
HTTP calls fail closed with 401. This implementation does not add an
authentication provider. Authentication integration and live target-cluster
validation remain pending and must not be reported as completed.

The [API and operating contract](../api/processed-telemetry.md) contains example
requests/responses, error schemas, grants, local setup, Kubernetes prerequisites
and health policy. The OpenAPI 3.1 description is served at `/openapi.yaml`.

## Ownership and contracts

Owner: @ME-Massine. C-xx IDs: none assigned in #266.
Related IDs: #254 (Phase 7), #265 / PR #355 (schema prerequisite), #267
(anomaly follow-up), #273 (external ingestion security boundary).

The processor continues to own schema migrations and projection writes. Query
uses JDBC with a dedicated read-only PostgreSQL role and requires no Kafka,
Flyway history, anomaly or write permissions. Ingestion and processing sources,
schema migrations, image references and coverage floors remain unchanged.

Shared files: CONTRIBUTING.md, PROJECT_STATE.md, README.md, architecture/diagram
and roadmap docs, local operating docs, Kubernetes service-discovery and
network-policy docs/manifests, the container validator and network-policy
validator/regression test. Query-specific source, tests, OpenAPI and deployment
configuration are included in the file list below.

Joint review required before merge: query/API, processor/persistence, platform
deployment and security-boundary owners. Joint review is pending.

## Validation

| Check | Result |
| --- | --- |
| Java 25 Maven `verify`, ingestion | Passed: 23 tests, coverage gate met |
| Java 25 Maven `verify`, processor | Passed: 149 tests, including PostgreSQL migration tests; coverage gates met |
| Java 25 Maven `verify`, query | Passed: 38 tests, including 7 required PostgreSQL integration tests; coverage gates met |
| Query JaCoCo | Approximately 98% lines / 96% branches; configured floors unchanged |
| PowerShell 7.5.4 offline suite | Passed: 56 source files parsed, 18 regression files, no failures/skips |
| Windows PowerShell 5.1 offline suite | Passed: 56 source files parsed, 18 regression files, no failures/skips |
| Query image build/startup | Passed on Java 25; non-root container and deployed main-port probes report UP |
| Container validator, both PowerShell editions | Passed with disposable PostgreSQL; service/database containers and database volumes cleaned up |
| Docker Compose configuration | Passed |
| Query Kubernetes schema validation | Passed: 5 resources, strict Kubernetes 1.30 schemas |
| OpenAPI 3.1 lint | Passed; `security-defined` style rule excluded because the external principal integration has no selected wire authentication scheme |
| `git diff --check` | Passed |
| Live Kubernetes rollout / CNI enforcement | Pending; no reachable Kubernetes API configured |

The PostgreSQL suite executes the processor-owned migration, creates a separate
SELECT-only login, and covers tenant scope, device and independent/combined time
bounds, tied timestamps across pages, maximum page size/lookahead, empty/high
pages, decimal/timestamp mapping, injection strings, write/DDL/anomaly denial,
HTTP response fields, identity overrides, database loss, readiness/liveness and
recovery. Docker unavailability fails the suite rather than substituting H2.

Network-policy regression tests now use the shared offline YAML reader. Negative
cases reject missing query database egress, an additional unrestricted database
rule and a cross-namespace database peer, alongside existing isolation checks.

## Operating effects

- Query startup configuration requires database credentials with no baked-in
  defaults. Provision `query-service-secret` out of band; never apply example
  placeholders. Use a dedicated role with CONNECT, platform USAGE and SELECT
  on `platform.processed_telemetry` only.
- Start processor migrations before routing query traffic. Query has no runtime
  migration runner and does not create schemas or tables.
- Query readiness and aggregate health require database connectivity. Liveness
  remains independent of PostgreSQL. Connectivity checks do not attest to
  migrations, privileges or authentication integration.
- Each replica permits five database connections. Query transactions and socket
  reads have five-second timeouts; connection acquisition/connect timeouts are
  two seconds. Account for replicas when budgeting database connections.
- The committed NetworkPolicy adds same-namespace TCP 5432 egress. External or
  cross-namespace PostgreSQL requires coordinated endpoint/peer/validator changes.
  The service remains ClusterIP and consumes no Kafka topics.
- Offset pages are deterministic over unchanged data; ingestion/replay updates
  can shift offsets across separate requests. No snapshot export is promised.
- Phase 6 live acceptance remains open. A new image rollout uses the existing
  release-promotion workflow after review; committed image references are unchanged.

## Developer Git commands

Run from the repository root after reviewing the diff. The explicit file list
excludes pre-existing Maven-wrapper changes and untracked instruction files.

```powershell
$issueFiles = @(
    'CONTRIBUTING.md'
    'PROJECT_STATE.md'
    'README.md'
    'docs/api/processed-telemetry.md'
    'docs/architecture/autoscaling-strategy.md'
    'docs/architecture/c4-model.md'
    'docs/architecture/container-image-validation.md'
    'docs/architecture/services.md'
    'docs/architecture/system-overview.md'
    'docs/diagrams/event-flow.md'
    'docs/diagrams/kubernetes-deployment.md'
    'docs/diagrams/system-architecture.md'
    'docs/implementation/issue-266-handoff.md'
    'docs/platform-overview.md'
    'docs/roadmap.md'
    'infrastructure/docker/README.md'
    'infrastructure/kubernetes/network-policies/README.md'
    'infrastructure/kubernetes/network-policies/query-service.yaml'
    'infrastructure/kubernetes/query-service/README.md'
    'infrastructure/kubernetes/query-service/configmap.yaml'
    'infrastructure/kubernetes/query-service/deployment.yaml'
    'infrastructure/kubernetes/query-service/secret.example.yaml'
    'infrastructure/kubernetes/service-discovery.md'
    'scripts/tests/test-network-policy-structure.ps1'
    'scripts/validate-container-images.ps1'
    'scripts/validate-network-policies.ps1'
    'services/query-service/pom.xml'
    'services/query-service/src/main/java/com/pulsestream/query/controller/ProcessedTelemetryController.java'
    'services/query-service/src/main/java/com/pulsestream/query/dto/ProcessedTelemetryResponse.java'
    'services/query-service/src/main/java/com/pulsestream/query/dto/TelemetryPage.java'
    'services/query-service/src/main/java/com/pulsestream/query/exception/InvalidQueryException.java'
    'services/query-service/src/main/java/com/pulsestream/query/exception/QueryExceptionHandler.java'
    'services/query-service/src/main/java/com/pulsestream/query/exception/TenantIdentityException.java'
    'services/query-service/src/main/java/com/pulsestream/query/mapper/ProcessedTelemetryMapper.java'
    'services/query-service/src/main/java/com/pulsestream/query/repository/ProcessedTelemetryRepository.java'
    'services/query-service/src/main/java/com/pulsestream/query/service/ProcessedTelemetryService.java'
    'services/query-service/src/main/java/com/pulsestream/query/service/TelemetryQuery.java'
    'services/query-service/src/main/resources/application.yml'
    'services/query-service/src/main/resources/static/openapi.yaml'
    'services/query-service/src/test/java/com/pulsestream/query/QueryServiceApplicationTests.java'
    'services/query-service/src/test/java/com/pulsestream/query/controller/ProcessedTelemetryControllerTest.java'
    'services/query-service/src/test/java/com/pulsestream/query/repository/PostgresQueryIntegrationTest.java'
    'services/query-service/src/test/java/com/pulsestream/query/service/ProcessedTelemetryServiceTest.java'
    'services/query-service/src/test/java/com/pulsestream/query/service/TelemetryQueryTest.java'
)
git add -- $issueFiles
git diff --cached --check
git diff --cached --stat
git commit -m "feat(query): implement tenant-scoped processed telemetry API"
git push -u origin feature/266-processed-telemetry-query
```

## Copy-ready draft PR

Title: `feat(query): implement tenant-scoped processed telemetry API`

```markdown
## Summary
Clients with an authenticated tenant principal can read processed telemetry
through GET /api/v1/telemetry. Device/time filters, bounded pages and deterministic
timestamp/ID ordering replace the query-service scaffold. Tenant overrides and
invalid parameters return controlled errors; database loss removes readiness
without failing liveness.

## Related Issue
Closes #266. Schema prerequisite: #265 / PR #355. Phase: #254.
Anomaly follow-up: #267. External ingestion security work: #273.

## Issue Requirements Covered
- Read-only PostgreSQL repository, mapping, DTO, service, controller and exception layers.
- Tenant-scoped queries with exact device and half-open timestamp filtering.
- Bounded pagination, stable timestamp tie ordering and controlled 400/401/503 errors.
- OpenAPI schemas, examples, local/Kubernetes credentials and health policy.
- Required PostgreSQL repository/API tests and focused unit/web tests.

## Changes
- Require an authenticated servlet principal whose name is the authorized tenant ID.
- Reject query tenant overrides and ignore untrusted identity headers; use no-store responses.
- Add a separate query Secret and database-aware readiness; permit same-namespace PostgreSQL egress.
- Prepare disposable query databases during image validation and run policy regressions offline.
- Reconcile architecture, diagrams, project state and operating documentation.

## Ownership and contracts
Owner: @ME-Massine. C-xx IDs: none assigned in #266.
Shared files: contribution/project-state/architecture docs; local/Kubernetes
operating docs and network policy; container and policy validators/regressions.
Processor-owned migrations, ingestion/processing behavior, image references and
coverage floors remain unchanged. Joint review required: query/API,
processor/persistence, platform and security-boundary owners.

## Testing
- Java 25 Maven verify passed for all services: 23 ingestion, 149 processor,
  38 query tests; coverage gates unchanged. Query coverage is approximately
  98% lines / 96% branches.
- Seven PostgreSQL integration tests cover isolation, filters, ordering,
  pagination, mappings, grants, API responses, database loss and recovery.
- PowerShell 7.5.4 and Windows PowerShell 5.1 offline suites passed:
  56 parsed sources, 18 regression files, no failures/skips on either edition.
- Query Docker image build, non-root startup, database-dependent readiness and
  liveness/management probes passed; validator passed on both PowerShell editions.
- Compose configuration and strict schemas for all five query Kubernetes resources passed.
- OpenAPI lint passed with security-defined excluded: the external principal
  integration does not yet select a wire authentication scheme.
- Live Kubernetes rollout/CNI enforcement remains pending; no cluster API is configured.

## Operating effects
Provision query-service-secret with a dedicated SELECT-only login and run
processor migrations first. Database connectivity gates readiness and aggregate
health, with five pooled connections per replica. Raw HTTP calls return 401
until the Phase 7 authentication integration supplies the authorized tenant
principal. This PR adds no authentication provider or external route. Offset
pages do not provide a shared snapshot during ingestion/replay. Promote the new
image through the existing release workflow after review.

## Checklist
- [x] Code builds successfully.
- [x] Tests pass; coverage gates unchanged.
- [x] Documentation updated.
- [x] Linked issue is referenced.
- [x] Changes stay within the issue scope.
- [ ] Joint review from query, persistence, platform and security owners.
- [ ] Live target-cluster rollout and authentication integration validation.
```
