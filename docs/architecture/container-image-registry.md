# Container Image Registry

Kubernetes cannot pull a service image unless it lives in a container registry.
This document defines where PulseStream publishes its platform service images,
how they are named and tagged, and how Kubernetes manifests reference them.

The images published here are the ones built from the
[Container Build Standard](container-build-standard.md) and proven runnable by
[Container Image Validation](container-image-validation.md).

Out of scope: image signing, advanced supply-chain security, and deployment
rollout.

---

## Target registry

Platform images are published to the **GitHub Container Registry (GHCR)** at
`ghcr.io`.

GHCR is used because the project already lives on GitHub:

- No extra infrastructure or third-party account is required.
- CI authenticates with the built-in `GITHUB_TOKEN` — no long-lived registry
  credentials are stored in the repository.
- Packages are owned by the same GitHub org/user as the source repository.

---

## Image naming

Each service maps to exactly one image, named under a shared `pulsestream`
namespace so the platform's images group together in the registry:

```
ghcr.io/<owner>/pulsestream/<service>
```

`<owner>` is the repository owner, **lowercased** (GHCR namespaces must be
lowercase). The `<service>` segment matches the service directory under
`services/`.

| Service              | Image                                                |
| -------------------- | ---------------------------------------------------- |
| ingestion-service    | `ghcr.io/<owner>/pulsestream/ingestion-service`      |
| telemetry-processor  | `ghcr.io/<owner>/pulsestream/telemetry-processor`    |
| query-service        | `ghcr.io/<owner>/pulsestream/query-service`          |

This mirrors the local build prefix (`pulsestream/<service>`) used by
[validate-container-images.ps1](../../scripts/validate-container-images.ps1), so
the local and published names differ only by the `ghcr.io/<owner>/` prefix.

---

## Tagging strategy

Every published image carries an **immutable, per-commit** tag. Moving and
release tags are added on top depending on what triggered the publish.

| Tag                 | Applied when                          | Mutable? | Purpose                                              |
| ------------------- | ------------------------------------- | -------- | ---------------------------------------------------- |
| `sha-<short>`       | every publish                         | No       | Exact, reproducible reference to one commit          |
| `latest`            | push to `main`                        | Yes      | Most recent build of the mainline                    |
| `<version>-rc.<n>`  | promotion of a tested `sha-<short>`   | No       | Release candidate (e.g. `v1.2.0-rc.1`)               |
| `<version>`         | promotion of a candidate              | No       | Released version (e.g. `v1.2.0`)                      |

`sha-<short>` uses the first 7 characters of the commit SHA (for example
`sha-c2b315e`).

The two version tags are **applied to an image that already exists** — they are
never built. A promotion copies the registry manifest of a tested `sha-<short>`
digest onto the version tag, so all four rows above can name the same bytes. See
[Release and Container Image Promotion](release-and-promotion.md).

If the per-commit tag already exists when a publish runs, the existing image is
reused rather than rebuilt. A Java build is not byte-reproducible, so
overwriting the tag would give one commit two digests for the same service and
repoint a tag a release may already have promoted.

**Rule of thumb:** pin deployments to an immutable tag (`sha-<short>` or a
`<version>` tag), and to a digest once the image is part of a release. Treat
`latest` as a convenience for local pulls only — it is mutable and must not be
relied on for reproducible deploys.

---

## Publishing

Publishing is automated by
[`.github/workflows/publish-images.yml`](../../.github/workflows/publish-images.yml).
It builds and pushes all three service images on every push to `main`, tagging
`sha-<short>` and moving `latest` onto that same digest.

Pull requests do **not** publish, so forks cannot push images and unmerged work
never reaches the registry. Neither do `v*` tags: a version is applied to an
already-published digest by
[`release-promotion.yml`](../../.github/workflows/release-promotion.yml), and
building on the tag would publish contents no check had run against under a
version that was already approved.

Each run records the digest it published in the job summary and in an
`image-digests` artifact, which is what a promotion later resolves.

### Manual publish (single service)

To publish one image by hand — for example from a maintainer's machine:

```bash
# 1. Authenticate to GHCR with a token that has write:packages scope
echo "$GITHUB_TOKEN" | docker login ghcr.io -u "<your-username>" --password-stdin

# 2. Build and tag (owner must be lowercase)
docker build -t ghcr.io/<owner>/pulsestream/query-service:sha-<short> services/query-service

# 3. Push
docker push ghcr.io/<owner>/pulsestream/query-service:sha-<short>
```

---

## Referencing images from Kubernetes

Kubernetes manifests reference a published image by its full path and an
immutable tag:

```yaml
containers:
  - name: query-service
    image: ghcr.io/<owner>/pulsestream/query-service:sha-c2b315e
```

Once the image is part of a release, the manifest carries the digest as well, so
what Kubernetes resolves cannot be changed by repointing the tag:

```yaml
containers:
  - name: query-service
    image: ghcr.io/<owner>/pulsestream/query-service:v1.2.0@sha256:<64 hex>
```

`scripts/validate-release-manifests.ps1` checks these references on every pull
request — see [Release and Container Image Promotion](release-and-promotion.md).

If the package is private, the pulling cluster needs an image pull secret
holding a token with `read:packages` scope:

```bash
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<username> \
  --docker-password=<token>
```

Reference that secret with `imagePullSecrets` in the pod spec. Making the GHCR
packages public removes the need for a pull secret entirely.
