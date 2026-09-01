# Release and Container Image Promotion

Service images are published for every commit on `main`, and the Kubernetes
manifests that name them are edited separately. Nothing tied the two together,
so a manifest set could deploy `ingestion-service` built at one commit next to
`telemetry-processor` built at another, or name an image published before the
probes and ConfigMap keys that same manifest declares.

This document defines the workflow that closes that: what states an artifact
moves through, how a version is applied to an image that already exists, how
release manifests reference it, and how to upgrade and roll back.

The images promoted here are the ones published by
[Container Image Registry](container-image-registry.md), built to the
[Container Build Standard](container-build-standard.md), and proven runnable by
[Container Image Validation](container-image-validation.md).

Out of scope: publishing the first final PulseStream release, deploying to a
production cluster automatically, multi-environment GitOps reconciliation, and
supporting a second container registry.

---

## The unit that moves is a digest

A tag is a pointer and can be repointed. A digest names the bytes.

Everything below follows from one rule: **an image is built once, for one source
commit, and after that only its tags change.** Promotion never rebuilds — it
copies an existing registry manifest to a new tag with
`docker buildx imagetools create`, so the bytes an operator eventually runs are
the bytes CI tested.

This matters because the platform services are Java builds, which are not
byte-reproducible. Building the same commit twice produces two different
digests. If a release rebuilt, the version tag would name contents no check ever
ran against, and the approval the release represents would be for something
else.

---

## Artifact states

| State                | Tag                        | What it means                                                           | Who applies it                       |
| -------------------- | -------------------------- | ----------------------------------------------------------------------- | ------------------------------------ |
| **development**      | `sha-<short>`              | Built from one `main` commit. Immutable, but not yet known to be good.   | `publish-images.yml`, on push to main |
| **release candidate**| `v<x>.<y>.<z>-rc.<n>`      | A development digest whose required checks all passed. Same digest.      | `release-promotion.yml`              |
| **released**         | `v<x>.<y>.<z>`             | A candidate accepted as the release. Same digest again.                  | `release-promotion.yml`              |

`latest` is not a state. It is a moving convenience pointer for local pulls,
moved onto the digest that was just published; no manifest may reference it.

A state is a property of a digest, not of a build. The same digest carries
`sha-a0ab2f8`, then `v0.7.0-rc.1`, then `v0.7.0`. Promotion adds a tag; it never
produces a new one to add the tag to.

---

## Version tag conventions

```
v<major>.<minor>.<patch>          released
v<major>.<minor>.<patch>-rc.<n>   release candidate for that version
```

Both are validated by `Test-SemanticVersionTag`
([scripts/lib/PulseStreamRelease.psm1](../../scripts/lib/PulseStreamRelease.psm1)),
and anything else is rejected rather than guessed at — the promotion workflow
reads the channel back off the tag to decide whether it is writing a candidate
or a release, so a tag that does not say which is not usable.

Rejected, with examples of why: `1.2.0` (no `v`), `v1.2` (no patch), `v1.2.0-rc`
(no candidate number), `v1.2.0-beta.1` (only `-rc.<n>` is a candidate),
`v01.2.0` (leading zero), `latest`.

---

## One commit, one digest per service

`publish-images.yml` builds each service once per `main` commit and tags it
`sha-<short>`.

If that tag already exists — a re-run of the workflow, or a workflow re-triggered
on the same commit — the existing image is **reused, not rebuilt**. Overwriting
it would repoint a tag a release may already have promoted, and give one commit
two digests for the same service.

Each build records its digest in three places, so it can be found later without
guessing:

- the run's job summary,
- an `image-digest-<service>` artifact per service,
- an `image-digests` artifact holding the merged index for the commit.

The image also carries the commit in its own OCI labels:

```
org.opencontainers.image.source     https://github.com/<owner>/pulsestream
org.opencontainers.image.revision   <full 40-character commit>
org.opencontainers.image.version    sha-<short>
org.opencontainers.image.created    <build time>
```

---

## Promotion

Promotion runs from the Actions tab:
[`release-promotion.yml`](../../.github/workflows/release-promotion.yml),
`workflow_dispatch`, with a version, the full source commit, and a `dry_run`
switch that defaults to on.

It is split into two jobs so that a failed promotion cannot update the release
manifest as a matter of structure rather than step order:

```
gate                                   promote  (needs: gate)
  ├─ the version tag is valid            ├─ resolve sha-<short> -> digest per service
  ├─ the commit is 40 hex, exists,       ├─ imagetools create: copy that digest to the version tag
  │  and is an ancestor of main          ├─ re-inspect the new tag; the digest must be unchanged
  └─ every required check passed         ├─ write the release lock and notes
     for that commit                     ├─ repin every Deployment to the digest
                                         └─ open a pull request
```

`promote` does not exist as a runnable job unless `gate` succeeded, so no tag is
applied and no manifest is written for a commit that did not pass.

### What the gate requires

The required checks are listed in the workflow's `REQUIRED_CHECKS`. A check
blocks promotion when it failed, when it is still running, when it was skipped,
and — the case that matters most — **when it produced no result at all**.

A workflow that was never triggered for a commit leaves no failure behind.
Reading "no failures" off such a commit is how an untested image gets a release
tag, so a required check with no record blocks exactly like a red one. A check
that reported twice (a re-run) is judged on its worst result: a green re-run does
not retire a failing run of the same check.

### Why it opens a pull request

`main` is protected and accepts reviewed changes only. Promotion therefore
proposes the new image references on a `release/<version>` branch and a human
approves them. That is the controlled process for changing a deployment image
reference — there is no other supported way for one to change.

The pull request runs the same **Release manifest consistency** check as any
other, which re-verifies the manifests against the lock that was just written.

---

## The release manifest set

A release is recorded under `infrastructure/kubernetes/releases/<version>/`:

| File                | Contents                                                          |
| ------------------- | ----------------------------------------------------------------- |
| `images.lock.json`  | The version, its state, the source commit, and one digest per service |
| `release-notes.md`  | The issue-scoped changes between the previous release and this one |

```json
{
  "version": "v0.7.0-rc.1",
  "state": "candidate",
  "commit": "a0ab2f8f8f56edcc77ed4d1fc9128fd1fd458649",
  "createdUtc": "2026-09-01T18:00:00Z",
  "promotedFrom": "sha-a0ab2f8",
  "promotionRun": "https://github.com/<owner>/pulsestream/actions/runs/<id>",
  "images": {
    "ingestion-service": {
      "repository": "ghcr.io/<owner>/pulsestream/ingestion-service",
      "digest": "sha256:<64 hex>",
      "tag": "v0.7.0-rc.1",
      "sourceTag": "sha-a0ab2f8",
      "reference": "ghcr.io/<owner>/pulsestream/ingestion-service:v0.7.0-rc.1@sha256:<64 hex>"
    }
  }
}
```

The Deployment manifests are repinned to the `reference` form:

```yaml
image: ghcr.io/<owner>/pulsestream/ingestion-service:v0.7.0-rc.1@sha256:<64 hex>
```

Both halves are there on purpose. Kubernetes resolves the digest and ignores the
tag, so the digest is what actually runs; the tag is for the person reading the
manifest, who otherwise has 64 hex characters and no idea which release they are
looking at. The consistency check requires them to agree.

The rewrite edits only the `image:` line. The manifests carry the reasoning for
their own settings in comments, and a parse-and-reserialize round trip would drop
all of it.

---

## Release notes

Notes are generated from the commits between the previous release's recorded
commit and this one — the previous release's *commit*, not a git tag, so the
range stays correct before the first `v*` tag exists and if a tag is ever moved.

Commits are grouped by their conventional-commit type and every `#<issue>` they
reference is linked. Every change in this repository lands through a pull request
that closes an issue
([pr-issue-alignment.yml](../../.github/workflows/pr-issue-alignment.yml)), so a
commit with no issue reference is reported rather than quietly omitted — it means
either a direct push or notes that do not describe the whole release. Pass
`-RequireIssueReferences` to make that a hard failure.

---

## Finding the source commit for a deployed image

Three routes, in the order they are usually needed.

**From a running pod.** The status carries the digest that was actually pulled,
which is the identity the lock is keyed by:

```bash
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].imageID}'
```

**From the digest to the commit.** Look it up in the release lock:

```bash
grep -rl "<digest>" infrastructure/kubernetes/releases/
```

**From the image alone**, with no repository checkout — the commit is in the
image's own labels:

```bash
docker buildx imagetools inspect \
  ghcr.io/<owner>/pulsestream/query-service@<digest> \
  --format '{{json .Image.Config.Labels}}'
```

---

## Upgrading

1. Pick the `main` commit to release and confirm its checks are green.
2. Run **Release promotion** with `dry_run` on. It resolves the digests, writes
   the lock and the notes, and prints them to the run summary without touching
   the registry. Read the summary.
3. Re-run with `dry_run` off. The version tag is applied to the tested digests
   and a `release/<version>` pull request is opened.
4. Review and merge that pull request. The manifests on `main` now reference the
   released digests.
5. Apply the manifest set:

   ```bash
   kubectl apply -f infrastructure/kubernetes/ingestion-service/
   kubectl apply -f infrastructure/kubernetes/telemetry-processor/
   kubectl apply -f infrastructure/kubernetes/query-service/
   kubectl rollout status deployment/ingestion-service
   kubectl rollout status deployment/telemetry-processor
   kubectl rollout status deployment/query-service
   ```

6. For a final release, tag the merge commit so the released manifests are
   reachable by version:

   ```bash
   git tag -a v0.7.0 -m "PulseStream v0.7.0" <merge commit>
   git push origin v0.7.0
   ```

   Tagging is deliberately manual and deliberately last: it marks a release
   whose manifests are already on `main`. Pushing a `v*` tag does **not** build
   or publish anything — `publish-images.yml` does not run on tags, because a
   build there would produce different contents under a version that was already
   approved.

A release candidate stops at step 4. That is what lets a candidate be prepared
and reviewed without publishing a final release.

---

## Rolling back

A rollback restores both halves of what was deployed: the image and the manifest
set that configured it. Restoring only the image leaves the previous release's
probes, resources and ConfigMap references pointed at it.

**Immediate, one service** — undoes the last rollout for that Deployment:

```bash
kubectl rollout undo deployment/query-service
kubectl rollout status deployment/query-service
```

**The full previous release**, from the repository:

```bash
# 1. The manifests as they were at the previous release
git checkout v0.6.0 -- infrastructure/kubernetes/

# 2. Confirm they are the previous release's digests, not a mix
pwsh -File scripts/validate-release-manifests.ps1 -ReleaseVersion v0.6.0

# 3. Apply them
kubectl apply -f infrastructure/kubernetes/ingestion-service/
kubectl apply -f infrastructure/kubernetes/telemetry-processor/
kubectl apply -f infrastructure/kubernetes/query-service/
```

Then restore the working tree (`git checkout HEAD -- infrastructure/kubernetes/`)
and open a pull request reverting the promotion, so `main` describes what is
actually running.

Both digests remain in the registry — a rollback needs nothing rebuilt, which is
the whole reason releases are pinned by digest.

---

## What CI enforces

The **Release manifest consistency** job in
[`ci.yml`](../../.github/workflows/ci.yml) runs
[`validate-release-manifests.ps1`](../../scripts/validate-release-manifests.ps1)
on every pull request. It needs no cluster and no registry: it compares committed
files with each other.

Before any release exists it requires that:

- no platform image is on `latest`, or on no tag at all,
- every platform image is on a `sha-<short>` build tag,
- **every service is on the same one** — a manifest set that names two commits is
  not deploying one tested build,
- every known service is referenced by some Deployment,
- no platform image is pinned only by digest, because a digest alone names no
  commit and without a lock nothing maps it back to source.

Once a release lock exists it requires that every platform Deployment is pinned
to that release's digest, from that release's repository, under that release's
tag. A manifest left on the previous release's digest is reported as stale.

Third-party images (Grafana, Jaeger, the OpenTelemetry collector) are pinned by
their own manifests and are not this workflow's to promote.

---

## Running the pieces by hand

Both scripts are the same ones the workflows call, so a hand-run behaves
identically to a promotion run. They are pure file operations — neither talks to
a registry.

```powershell
# What CI checks, against the working tree
./scripts/validate-release-manifests.ps1

# Against a specific release
./scripts/validate-release-manifests.ps1 -ReleaseVersion v0.7.0

# Write a release manifest set from digests resolved elsewhere
./scripts/promote-release-manifests.ps1 `
    -Version v0.7.0-rc.1 `
    -Commit a0ab2f8f8f56edcc77ed4d1fc9128fd1fd458649 `
    -ImageDigest "ingestion-service=sha256:...", "telemetry-processor=sha256:...", "query-service=sha256:..."

# The rules themselves, with no cluster and no registry
./scripts/tests/test-release-promotion.ps1
```

`promote-release-manifests.ps1` re-runs the consistency check on what it wrote
before it exits, so a promotion that would leave the manifests and the lock
disagreeing fails there rather than on the pull request.
