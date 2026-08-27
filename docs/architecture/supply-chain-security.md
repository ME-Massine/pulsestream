# Supply-Chain Security

PulseStream's risk did not stop at the code its authors write. The services pull
in a Spring Boot dependency tree, build inside a Maven distribution downloaded at
build time, run on a base image maintained by someone else, and are published by
workflows that call third-party GitHub Actions holding a token with write access
to the registry. Each of those is a way for code nobody reviewed to end up
running in the cluster.

This document describes the controls that answer those risks, what each one
does and deliberately does not cover, who is responsible for the alerts they
produce, and how to verify a published image.

Related: [Container Image Registry](container-image-registry.md) for naming and
tagging, [Container Build Standard](container-build-standard.md) for how images
are built, and [SECURITY.md](../../SECURITY.md) for reporting a vulnerability.

---

## What is being defended against

| Risk | Control | Where |
| --- | --- | --- |
| A dependency with a known vulnerability stays in the tree because nobody looked | Dependabot alerts and grouped update pull requests | `.github/dependabot.yml` |
| A pull request adds a vulnerable or copyleft-licensed dependency | Dependency review on every pull request | `.github/workflows/dependency-review.yml` |
| Our own code contains an exploitable pattern | CodeQL analysis of all three services | `.github/workflows/codeql.yml` |
| A vulnerable image reaches the registry and then the cluster | Trivy gate that runs before the push | `.github/workflows/publish-images.yml` |
| Nobody can answer "what is actually inside this image" after the fact | SPDX SBOM attached to the image digest | `.github/workflows/publish-images.yml` |
| A published image is replaced or impersonated | Keyless cosign signature over the digest | `.github/workflows/publish-images.yml` |
| A build executes a substituted Maven distribution | `distributionSha256Sum` verified by `mvnw` before unpacking | `services/*/.mvn/wrapper/maven-wrapper.properties` |
| A third-party action is repointed at hostile code | Every action pinned to a commit SHA | all workflows |
| A credential is committed | Secret scanning with push protection | repository settings |
| A critical path is changed without review | CODEOWNERS | `.github/CODEOWNERS` |
| Any of the above quietly regresses | Configuration validator run by CI | `scripts/validate-supply-chain-security.ps1` |

Out of scope, and unchanged by this work: application authentication and
authorization, Kafka TLS and client authentication, runtime policy enforcement
in the cluster, and any form of compliance certification.

---

## Repository settings

Four controls are repository settings rather than files, so they cannot be
enabled by a pull request. They must be turned on once by someone with admin
rights on the repository, under **Settings → Advanced Security** (Dependabot
settings live under **Settings → Code security**):

| Setting | Why |
| --- | --- |
| Dependency graph | Everything else in this section depends on it, and dependency review compares against it. |
| Dependabot alerts | Notifies on vulnerable dependencies already merged, which is what `.github/dependabot.yml` acts on. |
| Dependabot security updates | Opens fix pull requests for alerts without waiting for the weekly schedule. |
| Secret scanning | Detects committed credentials in history and in new pushes. |
| Push protection | Blocks the push that contains a credential, instead of reporting it after it is public. |
| Private vulnerability reporting | Provides the reporting form `SECURITY.md` points at. Without it, that link 404s. |

They can also be set from the command line by an account with admin rights:

```bash
gh api -X PATCH repos/ME-Massine/pulsestream \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'

gh api -X PUT  repos/ME-Massine/pulsestream/vulnerability-alerts
gh api -X PUT  repos/ME-Massine/pulsestream/automated-security-fixes
gh api -X PUT  repos/ME-Massine/pulsestream/private-vulnerability-reporting
```

Verify afterwards:

```bash
gh api repos/ME-Massine/pulsestream --jq '.security_and_analysis'
gh api repos/ME-Massine/pulsestream/vulnerability-alerts --include | head -1   # expect HTTP 204
```

Branch protection on `main` is where the workflows below become *required*
rather than advisory. Require CodeQL, dependency review, and the CI jobs as
status checks, and require review from code owners, or CODEOWNERS is a
notification list rather than a gate.

---

## Action pinning

Every `uses:` in this repository resolves to a 40-character commit SHA with the
human-readable version in a trailing comment:

```yaml
uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
```

`@v4` is a tag, and a tag is a pointer its owner can move. An action that runs
in the publish workflow holds a token with `packages: write` and this run's OIDC
identity, so "the maintainer's account was compromised and v4 was retargeted" is
a full compromise of the release pipeline. A commit SHA is the only reference
form that cannot be repointed.

The cost of pinning is staleness, which is why the `github-actions` Dependabot
configuration exists: Dependabot rewrites the SHA and the version comment
together, so updates arrive as reviewable pull requests instead of silently.

`scripts/validate-supply-chain-security.ps1` fails CI if any action is
referenced by tag, by a truncated SHA, or without its version comment.

---

## Maven wrapper checksum

`mvnw` downloads a Maven distribution and then executes it. Without a checksum
the only thing standing between the build and arbitrary code execution is TLS to
`repo.maven.apache.org`.

All three wrappers therefore pin both the URL and the archive:

```properties
distributionUrl=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.14/apache-maven-3.9.14-bin.zip
distributionSha256Sum=55fadd669532a3205d5db95f490bf13971d8b0843526f407f29db0e61f074ab3
```

`mvnw` and `mvnw.cmd` both verify this before unpacking and abort on a mismatch:

```
Error: Failed to validate Maven distribution SHA-256, your Maven distribution might be compromised.
```

To change the Maven version, download the new archive, confirm its published
`.sha512` matches on both `repo.maven.apache.org` and `archive.apache.org`,
compute the SHA-256 of the same bytes, and update all three services together —
the validator requires them to agree.

```bash
curl -sSLO https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/<version>/apache-maven-<version>-bin.zip
curl -sSL  https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/<version>/apache-maven-<version>-bin.zip.sha512
sha512sum apache-maven-<version>-bin.zip   # must match the published value
sha256sum apache-maven-<version>-bin.zip   # this is distributionSha256Sum
```

---

## Release pipeline

`publish-images.yml` runs on pushes to `main` and on `v*` tags. Per service:

```
build (local tag only)
  -> report fixable CRITICAL and HIGH findings          (never fails)
  -> vulnerability gate: fixable CRITICAL               (fails the job)
  -> push every tag
  -> read the digest back from the registry
  -> generate SPDX SBOM
  -> cosign sign        <image>@<digest>
  -> cosign attest      <image>@<digest>  (SBOM as spdxjson predicate)
```

Two properties of that order are deliberate and are asserted by the validator:

- **The scan precedes the push.** A scan after the push reports on an image the
  cluster can already pull.
- **Everything after the push addresses the digest, not a tag.** `latest` will
  point somewhere else next week. A signature over `latest` says nothing about
  the bytes anyone actually pulled.

### Gate threshold

The gate fails on **fixable CRITICAL** findings. The report step above it prints
fixable CRITICAL *and* HIGH on every run, so the difference between what is
reported and what is enforced stays visible rather than being hidden behind a
green check.

`--ignore-unfixed` is set on both. A finding with no upstream fix cannot be
answered by merging faster; blocking every release on it teaches people to
disable the gate, which costs more than it buys.

### Accepted vulnerabilities

`.trivyignore.yaml` is the register of findings the gate is currently allowed to
pass over. Every entry carries a `statement` explaining the acceptance and an
`expired_at` date after which Trivy ignores the entry and the gate blocks again.

The validator fails CI when an entry has no justification, has no expiry, or has
an expiry already in the past — so a stale acceptance surfaces in a pull request
rather than the next time a release is attempted.

An entry is a decision, not a formality. Adding one needs the same review as any
other change to release behaviour, which is why the file is owned in CODEOWNERS.
Removing one needs nothing: if the update landed, delete the entry.

### Signing identity

Signatures are keyless. cosign exchanges the workflow's OIDC token for a
short-lived Fulcio certificate, and the certificate records which workflow, on
which ref, produced the signature. There is no private key to store, leak, or
rotate, and the identity is a fact about the run rather than a shared secret.

---

## Verifying a published image

Signature, over the digest:

```bash
cosign verify \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  --certificate-identity-regexp "^https://github\.com/ME-Massine/pulsestream/\.github/workflows/publish-images\.yml@refs/(heads/main|tags/v.*)$" \
  ghcr.io/me-massine/pulsestream/<service>@sha256:<digest>
```

The identity regexp is the point of the exercise. Verifying without it only
proves *someone* signed the image; pinning issuer and identity proves *this*
workflow, on `main` or a release tag, signed it.

SBOM attestation, and extracting the SBOM itself:

```bash
cosign verify-attestation --type spdxjson \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  --certificate-identity-regexp "^https://github\.com/ME-Massine/pulsestream/\.github/workflows/publish-images\.yml@refs/(heads/main|tags/v.*)$" \
  ghcr.io/me-massine/pulsestream/<service>@sha256:<digest> \
  | jq -r '.payload' | base64 -d | jq '.predicate' > sbom.spdx.json
```

Resolve a tag to the digest to verify first:

```bash
docker buildx imagetools inspect ghcr.io/me-massine/pulsestream/<service>:latest --format '{{.Manifest.Digest}}'
```

The same SBOM is also attached to its workflow run as
`sbom-<service>.spdx.json`, which is the convenient copy. The attestation is the
authoritative one: it is cryptographically bound to the digest, and the run
artifact is not.

---

## Responsibilities

Ownership currently sits with a single maintainer (see `.github/CODEOWNERS`).
The table describes roles rather than people, so it survives that changing.

| Alert source | Where it appears | Owner | Response |
| --- | --- | --- | --- |
| Dependabot alerts | Security → Dependabot | Maintainer | Triage within 5 working days. Critical or high: merge the fix or record an accepted risk within 14 days. |
| Dependabot update pull requests | Pull requests, Mondays | Maintainer | Review within the week. Grouped minor and patch updates merge on green CI; majors are read before merging. |
| CodeQL alerts | Security → Code scanning | Maintainer | Triage within 5 working days. Dismiss with a reason, or fix. Never dismiss silently. |
| Dependency review failures | The pull request itself | Pull request author | Blocks merge. Update the dependency, or justify it in review. |
| Release gate failures | Publish images workflow | Maintainer | Publication stops. Fix the dependency, or add a justified, expiring entry to `.trivyignore.yaml`. |
| Secret scanning alerts | Security → Secret scanning | Maintainer | Immediate. Revoke the credential first; removing it from history does not un-leak it. |
| Reported vulnerabilities | Private advisory | Maintainer | Timelines in [SECURITY.md](../../SECURITY.md). |

### Triage principles

- **Revoke before you tidy.** A leaked credential is compromised the moment it
  is pushed. Rewriting history is cleanup, not remediation.
- **Dismissal needs a reason.** "Not exploitable here" is a reason. Silence is
  not, and the alert simply returns.
- **Fix the version, not the symptom.** Nearly every image finding is answered
  by a base image or dependency bump, which is what the Dependabot feeds are
  for.
- **An expiry date is a commitment.** If an acceptance is about to lapse and the
  fix is not close, that is a decision to re-make, not a date to extend by
  reflex.

---

## Validating the configuration

```powershell
pwsh -File scripts/validate-supply-chain-security.ps1        # run by CI
pwsh -File scripts/tests/test-supply-chain-security.ps1      # proves the validator can fail
```

The validator checks action pinning, Dependabot coverage of every service and
ecosystem, wrapper checksum agreement, gate ordering and blocking behaviour,
accepted-vulnerability hygiene, and CODEOWNERS coverage. It is offline and
read-only, and CI runs it in the `repo-sanity` job so a regression fails the pull
request that causes it.

---

## Known gaps

- **Transitive Maven dependencies are not in the dependency graph.** GitHub
  reads declared dependencies from each `pom.xml`; it does not resolve the tree.
  Dependency review therefore sees direct changes, while the image scan is what
  covers transitive ones — which is part of why the scan gate exists.
- **Kubernetes manifest image digests are not updated by Dependabot.** It does
  not read Kubernetes manifests. Those digests move with the change that bumps
  the workload.
- **Build provenance (SLSA) is not attested.** Images carry a signature and an
  SBOM, but not a statement of how they were built.
- **Signatures are not verified at admission.** Nothing in the cluster currently
  refuses an unsigned image; verification is a manual step today.
