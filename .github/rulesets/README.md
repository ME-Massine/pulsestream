# Branch rulesets

GitHub stores rulesets in repository settings, not in the repository. The
checked-in JSON records the intended `main` policy next to the workflow whose
check names it requires.

## What it enforces

- The branch cannot be deleted or force-pushed.
- Merging needs a pull request with one approving review, and approvals are
  dismissed when new commits are pushed.
- Every review conversation must be resolved before merge.
- Every CI check listed below must pass, and the branch must be up to date with
  `main` before merge.

## Required checks

The `context` values are GitHub check-run names. Matrix jobs use the job `name`
with the matrix value appended. They must stay synchronized with
`.github/workflows/ci.yml`: a required context that never reports blocks every
merge, while a renamed job silently stops being protected.

| Check | CI job |
| --- | --- |
| `Repository sanity checks` | `repo-sanity` |
| `Service verify (<service>)` | `service-verify` (one per service) |
| `Release manifest consistency` | `release-manifests` |
| `Platform container images` | `platform-container-images` |
| `Published image runtime validation` | `published-image-runtime-validation` |
| `Docker Compose configuration` | `compose-config` |
| `Kubernetes manifests` | `kubernetes-manifests` |
| `PowerShell checks (<edition>)` | `powershell-checks` (one per edition) |

## Applying it

Repository administrator permission is required. Look up the existing ruleset
and replace it with the checked-in policy:

```bash
gh api repos/ME-Massine/pulsestream/rulesets --jq '.[] | {id, name}'

gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  repos/ME-Massine/pulsestream/rulesets/<id> \
  --input .github/rulesets/main-branch-protection.json
```

Confirm the live ruleset after applying it:

```bash
gh api repos/ME-Massine/pulsestream/rulesets/<id> \
  --jq '.rules[] | select(.type == "required_status_checks")
        | .parameters.required_status_checks[].context'

gh api repos/ME-Massine/pulsestream/rulesets/<id> \
  --jq '.rules[] | select(.type == "pull_request")
        | .parameters.required_review_thread_resolution'
```
