# Branch rulesets

GitHub stores rulesets in repository settings, not in the repository. A ruleset
that only exists in settings has no history, no review, and no way to tell which
change to CI it was meant to accompany.

`main-branch-protection.json` is the intended state of the `Production-Guardianship`
ruleset on the default branch, kept next to the workflow whose checks it
requires. Change it in the same pull request that changes those checks, then
apply it.

## What it enforces

- The branch cannot be deleted or force-pushed.
- Merging needs a pull request with one approving review, and approvals are
  dismissed when new commits are pushed.
- Every review conversation must be resolved before merge
  (`required_review_thread_resolution`).
- Every meaningful CI check must pass, and the branch must be up to date with
  the base branch before merge (`strict_required_status_checks_policy`).

## Required checks

The `context` values are GitHub check-run names, which for a matrix job are the
job `name` with the matrix value appended. They must match
`.github/workflows/ci.yml` exactly: a context that never reports blocks every
merge, and a renamed job silently stops being required.

| Check | Job in `ci.yml` |
| --- | --- |
| `Repository sanity checks` | `repo-sanity` |
| `Service verify (<service>)` | `service-verify` (one per service) |
| `Service image (<service>)` | `service-image` (one per service) |
| `Docker Compose configuration` | `compose-config` |
| `Kubernetes manifests` | `kubernetes-manifests` |
| `PowerShell checks (<edition>)` | `powershell-checks` (one per edition) |

## Applying it

Repository admin permission is required. Look up the ruleset id, then replace
the ruleset with this file:

```bash
gh api repos/ME-Massine/pulsestream/rulesets --jq '.[] | {id, name}'

gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  repos/ME-Massine/pulsestream/rulesets/<id> \
  --input .github/rulesets/main-branch-protection.json
```

To create it from scratch on a repository that has no such ruleset, POST to
`repos/ME-Massine/pulsestream/rulesets` with the same body.

Confirm afterwards that the ruleset reports the checks it should:

```bash
gh api repos/ME-Massine/pulsestream/rulesets/<id> \
  --jq '.rules[] | select(.type == "required_status_checks")
        | .parameters.required_status_checks[].context'
```
