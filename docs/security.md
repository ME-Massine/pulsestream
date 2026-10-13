# Repository security operations

## GitHub repository settings

Repository administrators enable these features under **Settings → Code security and analysis**:

- Dependency graph and Dependabot alerts.
- Dependabot security updates.
- Secret scanning and push protection.
- Private vulnerability reporting.

These are repository settings and cannot be enabled by committed workflow files. Confirm each setting after changing repository visibility or plan permissions.

Protect `main` and require the successful CI, CodeQL, and dependency-review checks before merging. Require pull requests, dismiss stale approvals after new commits, and prevent force pushes and deletion. The repository owner should review who can bypass these rules.

The intended policy is checked in at [`.github/rulesets/main-branch-protection.json`](../.github/rulesets/main-branch-protection.json). It requires `Dependency review`, `Analyze ingestion-service`, `Analyze telemetry-processor`, and `Analyze query-service` alongside the CI checks. An administrator must [apply the policy to the live ruleset](../.github/rulesets/README.md#applying-it); committing the JSON does not update GitHub settings. Dependency review runs on pull requests, while the three CodeQL contexts also gate release promotion for the selected source commit.

## Triage responsibilities

- Repository maintainers review Dependabot security alerts and update pull requests weekly, and sooner for actively exploited or critical issues.
- The maintainer on call for the repository triages private vulnerability reports, coordinates a fix, and publishes an advisory after users can update.
- Service owners review CodeQL findings and container scan failures before merging or promoting a release.
- Repository administrators review CODEOWNERS and branch protection whenever maintainers change.

Dependabot checks Maven dependencies in each service, Dockerfiles, the Docker Compose stack, and GitHub Actions weekly. Action references use major release tags and Dependabot opens weekly version updates; maintainers review those workflow changes before merging.

## Image artifacts and releases

The image publish workflow builds new images locally and scans a saved image archive with Trivy before pushing the commit tag. A high or critical vulnerability with an available fix blocks publication. It generates an SPDX JSON SBOM from the same archive, attaches it to the pushed digest using Cosign's `spdx` type, and signs only newly built digests with the workflow's short-lived GitHub Actions identity and a signed `source-commit` annotation. `latest` moves only after scanning, SBOM attachment, and signing succeed.

For an existing commit tag, the workflow pins its digest and verifies the exact publishing workflow identity, OIDC issuer, and signed source commit before pulling it. It also checks the OCI source/revision labels and rescans the image. Reused content never receives a new signature. Unsigned images and legacy signatures without the commit annotation fail closed; their labels are insufficient proof. Do not bypass verification or re-sign an existing digest to repair a failed rerun. Use a new reviewed source commit to build and publish fresh images under the updated workflow.

Release promotion verifies the same identity and signed source commit for each runtime-validated digest before applying release tags.

To verify a published image, install `cosign` and run:

```sh
cosign verify \
  --certificate-identity 'https://github.com/ME-Massine/pulsestream/.github/workflows/publish-images.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  -a 'source-commit=<full-40-character-commit>' \
  ghcr.io/me-massine/pulsestream/ingestion-service@sha256:<digest>
```

Use the matching service image, digest, and full source commit from the validated digest record. Retrieve the image SBOM with `cosign download sbom IMAGE@sha256:<digest>`.
