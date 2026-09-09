# Releases

One directory per promoted version, written by
[`release-promotion.yml`](../../../.github/workflows/release-promotion.yml) and
never edited by hand:

```
releases/<version>/
  images.lock.json   the source commit and one image digest per service
  release-notes.md   the issue-scoped changes in that release
```

The lock is what makes a deployed image traceable. A digest names bytes, not a
commit; the lock is the record that maps one to the other, and it is what the
**Release manifest consistency** check compares the Deployment manifests
against.

A version is a fixed set of digests. Promoting the same version twice is
refused — publish a new version rather than rewriting one, so a release that was
reviewed keeps meaning what it meant.

This directory is empty until the first promotion. Until then the manifests are
pinned to a `sha-<short>` build tag and the pre-release rules apply.

See [docs/architecture/release-and-promotion.md](../../../docs/architecture/release-and-promotion.md).
