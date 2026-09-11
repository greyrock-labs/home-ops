---
name: merge-renovate-prs
description: Use when asked to merge or process open PRs in home-ops — Renovate PRs, pending updates, "push the PRs", "merge what's safe", triaging open pull requests on git.greyrock.io, or re-evaluating PRs after a failed merge
---

# Merge Renovate PRs

Evaluates open PRs on `todd/home-ops` (git.greyrock.io), auto-merges the safe Renovate ones **serially with per-merge verification**, and reports the flagged ones with reasons.

**Standing authorization:** the user has pre-approved auto-merging any PR that passes every Safe check in Step 2 — no confirmation needed for those. This overrides the tea skill's confirm-before-merge rule for Safe PRs only. Flagged PRs (Step 2) still require explicit user instruction.

Prereq: confirm `git remote get-url origin` points at `git.greyrock.io` and the active tea login matches. Use `tea` with `--repo todd/home-ops`. Honour `gitops.instructions.md` (never `flux reconcile`) and `pr-review.instructions.md`.

## Step 1: Gather evidence for every open PR

For each open PR (`tea pulls list --state open`), fetch:

- **Comments** — `tea api repos/todd/home-ops/issues/<n>/comments`. Two reviewers post there:
  - **konflate** (user `lab-assistant`): rendered diff, blast radius, cautions, image table
  - **AI PR Review** (user `todd`, `<!-- ai-pr-reviewer -->` header): verdict in the `review_result` field; the comment's `head_sha` must match the PR's current head — a stale review counts as no review
- **CI** — `tea pulls view <n> --fields ci`; every check must be ✓
- **Mergeable** — from the pulls API; must be `true`

## Step 2: Classify

**Safe** (auto-merge) requires ALL of:

| Check | Requirement |
|---|---|
| Author | `renovate[bot]` |
| Update type | patch, minor, or digest-only |
| AI PR Review | `review_result: clean` on the **current** head SHA |
| Konflate | "Routine", or only cautions that pre-date the PR (e.g. a long-standing privileged DaemonSet) |
| CI | all green |
| Mergeable | `true` |

**Always flag, never auto-merge:**

- **Major bumps** — `!` in the title, or a major version change (e.g. 1.x → 2.0.0). Even when the AI approves: an APPROVE issued without upstream release notes is an approval made blind, and release-automation mistakes are a known failure class (accidental major tags happen; maintainers typically announce the correction in release notes or community chat). Always tell the user to check upstream release notes / maintainer chat before deciding on a major.
- Any non-Renovate author
- Missing or stale AI review, red CI, konflate cautions that are new in this PR, `mergeable: false`

## Step 3: Merge serially — one at a time, verified

Sort Safe PRs oldest-first (lowest PR index — Forgejo numbers PRs monotonically, so index order = creation order). If the set includes a **forgejo chart bump, merge it LAST**: restarting git.greyrock.io blocks every subsequent tea operation for minutes.

For EACH PR, one at a time:

1. Settle-wait ~60s since the last write to the repo
2. `tea pulls merge <n> --repo todd/home-ops --style squash`
3. Wait ~60–90s
4. **Verify the merge actually landed on main:**

   ```bash
   git fetch forgejo main
   git log forgejo/main --oneline -5   # the (#<n>) commit must appear
   ```

   The API returning `merged: true` is **NOT proof**. Squash merges fired in rapid succession have been recorded as merged while `main` never advanced (observed in this repo). Only the git log counts.
5. Commit not on main → **STOP merging further PRs.** Do not blind-retry. Report the lost merge — Renovate will regenerate it as a new PR within minutes. Investigate (likely the race above) before continuing.

**Never rapid-fire merges. Never loop merge commands without a wait AND a main-verification between each.**

## Step 4: Light cluster verification (read-only)

After merges land, watch rollouts with read-only commands only:

```bash
kubectl get helmrelease -A | grep -E "<affected apps>"
kubectl get pods -A | grep -E "<affected apps>"
```

**Self-hosted caveat:** the Forgejo chart lives in this repo. Merging a forgejo bump restarts git.greyrock.io itself — expect 502s, SSH failures, and tea token-refresh failures for a few minutes. Watch `kubectl get pods -n dev`, wait for 1/1 Running, then continue. Forgejo's init container also waits on kanidm OAuth — a `DependencyNotReady` blip during simultaneous rollouts is normal.

## Step 5: Report

- **Merged:** PR number, change, verified commit SHA
- **Lost merges:** recorded-but-not-on-main; ask how to proceed
- **Flagged:** PR number, title, why flagged, and what evidence is missing

## Failure handling

| Symptom | Meaning | Action |
|---|---|---|
| `failed to merge PR, is it still open?` | Forgejo busy or restarting | Wait, watch the cluster, retry once |
| API 502 / tea token refresh fails | Forgejo rolling (own chart updated) | `kubectl get pods -n dev`, wait for 1/1, re-auth if needed, then complete the interrupted PR's Step 3 merge + main-verification |
| Renovate opened a duplicate of a just-merged PR | That merge was lost (Step 3 race) | Do not auto-merge; surface it and reference the prior PR number |
| Rollout stuck >10m | Genuine failure | Surface pods/events to the user |

## Red flags — STOP and reassess

- About to merge two PRs back-to-back with no wait and no main-verification between them
- About to merge a PR with `!` in the title or a major version change
- About to trust `merged: true` without checking `git log forgejo/main`
- About to say "the user must have reverted it" — verify against git first; the far more likely cause is the Step 3 race
- About to merge on "CI was green earlier" — evidence must be from the PR's current head
- Thinking "waiting is slow, I'll batch them" — the batching IS the failure mode
