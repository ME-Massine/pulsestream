# Security Policy

PulseStream is a reference implementation of an event-driven telemetry platform.
It is developed in the open, and this document describes what is supported, how
to report a vulnerability privately, and what happens after a report arrives.

## Supported versions

The project is pre-1.0 and ships from a single line of development. Only the
current default branch and the images built from it receive security fixes;
older commits and previously published image tags are not patched in place.

| Version | Supported | Notes |
| --- | --- | --- |
| `main` (and images tagged `latest` / `sha-<commit>` built from it) | Yes | Fixes land here first and only here. |
| Released `v*` tags | Latest tag only | Older release tags are superseded, not backported. |
| Any other branch or fork | No | Feature branches are work in progress. |

When a fix ships, the remedy is to move to the newest image digest, not to
request a patched build of an older tag. Image tags, digests, and how to verify
them are described in
[docs/architecture/container-image-registry.md](docs/architecture/container-image-registry.md)
and
[docs/architecture/supply-chain-security.md](docs/architecture/supply-chain-security.md).

## Reporting a vulnerability

**Do not open a public issue for a suspected vulnerability.** A public issue
discloses the problem to everyone, including anyone able to act on it, before a
fix exists.

Report privately through GitHub's private vulnerability reporting:

**<https://github.com/ME-Massine/pulsestream/security/advisories/new>**

That form opens a draft security advisory visible only to you and the
maintainers. It carries a private discussion thread, a place to attach a fix,
and the ability to publish an advisory and request a CVE once the fix is
released.

If the form is unavailable to you, open a public issue containing **no
technical detail** — a single line asking for a private channel is enough — and
a maintainer will make one available.

### What to include

The more of this a report carries, the faster it can be confirmed:

- Which component is affected (service name, workflow, manifest, or image tag
  and digest).
- The version, commit SHA, or image digest you observed it on.
- What an attacker can do with it, and what access they need first.
- Reproduction steps, a proof-of-concept request, or a failing test.
- Any suggested remediation you already have in mind.

### What to expect

This is a personal open-source project, not a staffed security team. The
following are intentions rather than contractual guarantees:

| Stage | Target |
| --- | --- |
| Acknowledgement that the report was received | Within 5 working days |
| Initial assessment: confirmed, needs more information, or not a vulnerability | Within 10 working days |
| Fix or documented mitigation for a confirmed critical or high finding | Within 30 days of confirmation |
| Advisory published, credit given if wanted | With the fix |

You will be told which of those outcomes applies and why. If a report is
declined, the reasoning comes with it.

### Scope

In scope: the service code under `services/`, the container images published
from this repository, the GitHub Actions workflows under `.github/workflows/`,
and the deployment manifests under `infrastructure/`.

Out of scope, because the platform does not claim them yet and the gaps are
already known and documented:

- Absence of application authentication and authorization on the service APIs.
- Kafka traffic without TLS or client authentication.
- Findings that require cluster-admin access you already hold.
- Reports produced solely by running an automated scanner, with no analysis of
  whether the finding is reachable in this codebase.
- Denial of service through unbounded request volume against a local deployment.

Anything that lets an attacker read or alter another tenant's telemetry, execute
code in a service container, escalate privilege inside the cluster, or subvert
the build and release pipeline is in scope and worth reporting.

## Automated security controls

These run continuously; a report about one of them not doing its job is a valid
report.

| Control | Where |
| --- | --- |
| Dependency updates for Maven, GitHub Actions, and Docker base images | [`.github/dependabot.yml`](.github/dependabot.yml) |
| Static analysis of the Java services | [`.github/workflows/codeql.yml`](.github/workflows/codeql.yml) |
| Vulnerable-dependency review on every pull request | [`.github/workflows/dependency-review.yml`](.github/workflows/dependency-review.yml) |
| Image vulnerability gate, SBOM, and signature on every published image | [`.github/workflows/publish-images.yml`](.github/workflows/publish-images.yml) |
| Maven distribution checksum verification | `services/*/.mvn/wrapper/maven-wrapper.properties` |
| Configuration checks over all of the above | [`scripts/validate-supply-chain-security.ps1`](scripts/validate-supply-chain-security.ps1) |

How alerts from these are triaged, and who is responsible for what, is described
in
[docs/architecture/supply-chain-security.md](docs/architecture/supply-chain-security.md).
