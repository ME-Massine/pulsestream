# Repository security operations

## GitHub repository settings

Repository administrators enable these features under **Settings → Code security and analysis**:

- Dependency graph and Dependabot alerts.
- Dependabot security updates.
- Secret scanning and push protection.
- Private vulnerability reporting.

These are repository settings and cannot be enabled by committed workflow files. Confirm each setting after changing repository visibility or plan permissions.

Protect `main` and require the successful CI, CodeQL, and dependency-review checks before merging. Require pull requests, dismiss stale approvals after new commits, and prevent force pushes and deletion. The repository owner should review who can bypass these rules.

## Triage responsibilities

- Repository maintainers review Dependabot security alerts and update pull requests weekly, and sooner for actively exploited or critical issues.
- The maintainer on call for the repository triages private vulnerability reports, coordinates a fix, and publishes an advisory after users can update.
- Service owners review CodeQL findings and container scan failures before merging or promoting a release.
- Repository administrators review CODEOWNERS and branch protection whenever maintainers change.

Dependabot checks Maven dependencies in each service, Dockerfiles, the Docker Compose stack, and GitHub Actions weekly. Action references use major release tags and Dependabot opens weekly version updates; maintainers review those workflow changes before merging.

## Image artifacts and releases

The image publish workflow fails when Trivy finds a high or critical vulnerability. It generates an SPDX SBOM from each image digest, attaches that SBOM to the same digest, and signs the digest with the workflow's short-lived GitHub Actions identity. Release promotion verifies the signature before applying release tags.

To verify a published image, install `cosign` and run:

```sh
cosign verify \
  --certificate-identity-regexp '^https://github.com/ME-Massine/pulsestream/.github/workflows/publish-images.yml@refs/heads/main$' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/me-massine/pulsestream/ingestion-service@sha256:<digest>
```

Use the matching service image and digest. Retrieve the image SBOM with `cosign download sbom IMAGE@sha256:<digest>`.
