## Workflow
1. Pick an issue from Ready
2. Create a feature branch
3. Open a draft PR early
4. Link the PR to the issue
5. Request review before merging

## Branch Naming
- feature/<name>
- fix/<name>
- chore/<name>
- docs/<name>

## Pull Requests
Every pull request must:
- link to an issue
- describe the change
- include testing notes
- update documentation when needed

## Security

- Never open a public issue for a suspected vulnerability. Report it privately —
  see [SECURITY.md](SECURITY.md).
- Dependabot opens dependency update pull requests weekly. Reviewing and merging
  them is normal maintenance work, not background noise; a skipped week is how a
  dependency tree goes a year stale.
- Pull requests are checked by CodeQL and dependency review. A failure there is
  a finding to answer, not a check to re-run.
- Controls, alert triage, and who owns what:
  [docs/architecture/supply-chain-security.md](docs/architecture/supply-chain-security.md).

## Issue Types

- **Feature**: a meaningful platform capability or service-level increment
- **Task**: a concrete implementation step, usually under a feature
- **Bug**: a defect or incorrect behavior that needs fixing