# renovate-steward — design (phase 1)

## Intent

Cut down the Renovate PR noise across every Forgejo repo. Safe updates merge on their own. Updates that need a migration Todd doesn't have to do himself get that work staged for his review. Updates that need Todd get one clear explanation. Every run leaves a complete, readable record in Hermes: what it looked at, what it decided, why, and what happened. That record is how a bad decision gets traced and fixed.

## Goals

- Watch every Forgejo repo `agent-smith` can see, including repos added later, with no per-repo setup.
- Give every open Renovate PR a tier (1, 2 or 3) and a matching `tier-N` label.
- **Tier 1:** safe to merge without supervision. The steward merges it.
- **Tier 2:** needs a migration Todd doesn't have to do himself. The steward does the migration, pushes it onto the Renovate PR's branch, and comments with what it changed and why. It does not merge (*staged for review*).
- **Tier 3:** needs Todd to check the migration and the outcome. The steward comments with the reason.
- Each run's output in Hermes logs every step: every repo and PR it looked at, every decision and the reasons for it, every action and its result. When it leaves a PR alone, the output says which PR and why.

## Non-goals (phase 1)

- Non-Renovate PRs.
- Checking Flux or the deployment after a merge.
- Notifications outside Hermes.
- Merging tier 2.

## Anti-goals (failures even if it "works")

- Skipping a PR without saying so in the run output.
- An empty or `[SILENT]` run.
- Repeated comments: a PR that has already been evaluated at its current commit is never commented on again.
- Merging anything that fails a hard rule, whatever the model says.

## Approaches considered

- **A. A script drives the run and the model only judges (picked).** A `--no-agent` Hermes cron job runs a Python script. The script owns the loop, the rules, the actions and the logging. For each PR, the model is asked once for a tier. Tier-2 migration work goes to a Hermes kanban task, which is Hermes' supported way to hand agent work off from a script.
  - Every PR gets a recorded outcome, and the output is the script's stdout, shown verbatim.
  - This is cheap, because there's one model call per new PR commit.
- **Rejected for tier 2:** the cron script starting `hermes chat` itself, which isn't a supported pattern.
- **B. An agent cron job with a tool (yesterday's design).** Rejected. The model ran the loop and skipped PRs, replied `[SILENT]`, and produced unreliable logs.
- **C. A Forgejo Actions workflow per repo.** Rejected. The logs would be in Forgejo rather than Hermes, and every new repo would need the workflow added.

## Hermes facts this relies on (checked 2026-11-25)

- `hermes cron create --no-agent --script X`: the script is the job, and its stdout is delivered verbatim as the run output. No model runs, so there's no `[SILENT]` and no monitor gating. Hermes cron output is stored under the profile's `cron/output/`.
- The script timeout is 3600 s by default.
- **Kanban:** `hermes kanban create` takes `--assignee`, `--skill`, `--model`/`--provider`, `--workspace dir:<path>`, `--idempotency-key`, `--max-runtime`, `--max-retries` and `--body-file`.
  - The dispatcher is embedded in the default gateway and ticks every 60 s.
  - Each task records its events, its runs, and a worker log in `/opt/data/kanban/logs/<task>.log`.
  - Workers hand off to the profile's gateway. That handoff was broken until PR #1011 fixed the PVC root ownership, and it was verified working on 2026-11-25.
- Scripts must live in `$HERMES_HOME/scripts/`, and writes are only allowed under `/opt/data`.
- Scheduled runs fire from the gateway. Manual tests use the UI button.
- **Still to confirm in the first build step, before anything else is built on them:**
  - The script's environment has `AGENTGATEWAY_API_KEY` and the `agent-smith` Forgejo token.
  - The token can push to PR branches.
  - The script can read a task's status and summary in machine-readable form (`kanban show`/`list` output, or the kanban DB read-only).
  - A `renovate-steward` worker can run with only file and terminal tools.

## Layout (code on the Hermes PVC only)

```
/opt/data/profiles/renovate-steward/
  config.yaml                 # minimal profile, no MCP servers
  scripts/steward.py          # the job
  steward/                    # library + tests (pytest, fake Forgejo)
  prompts/classify.md         # tiering instructions for the classifier call
  skills/renovate-migrate/SKILL.md   # tier-2 agent instructions
  work/<repo>-<pr>-<sha>/     # tier-2 checkouts (kanban workspace); removed once pushed or abandoned
  docs/ledger.md              # decisions made while building it
```

This design and the implementation plan live in home-ops next to the Hermes README, which has a short section describing the profile.

## Cron job

`20 * * * *`, `--no-agent --script steward.py --deliver local --no-wrap-response`. It is created paused, and Todd resumes it after the first supervised run.

## Run flow

Every printed line starts with a UTC timestamp. Lines about a PR also carry `owner/repo#N@shortsha`.

1. **Header.** Run start, steward version (the hash of its files), and the mode (`live` or `dry-run`).
2. **Discover repos.** Search Forgejo through `/repos/search`, since the token can't list the org. Archived repos and mirrors are skipped. The run logs every repo found, and the count of Renovate PRs in each.
3. **List PRs.** Collect the open PRs whose author is `renovate`, and log each one. PRs by anyone else are ignored completely: never evaluated, labelled, commented on or merged.
4. **Already evaluated?** Look at the steward's own comments on the PR. Each comment ends with a hidden marker:
   ```
   <!-- renovate-steward sha=<head sha evaluated> tier=<n> pushed=<sha or -> -->
   ```
   - If the PR's head is the evaluated `sha`, or the `pushed` commit (the steward's own tier-2 commit), the PR isn't touched, and the run logs: `not touched: evaluated as tier 2 at a1b2c3d on 2026-11-25 (comment #4512); no new commits since`.
   - A new head commit, from Renovate or from Todd, starts a new evaluation, which may add a new comment. Earlier comments are left as they are.
5. **Wait for checks.** If any commit status or check is still pending, the PR isn't touched this run. The run logs which check is pending. Nothing is posted.
6. **Renovate automerge.** If Renovate will merge the PR itself, the PR isn't touched, and the run logs that reason. *(How automerge is detected is the builder's call, for example from the PR body or the repo's Renovate config.)*
7. **Gather evidence** (all of it in code):
   - The title and body, which include Renovate's release notes.
   - The update type: major, minor, patch, digest or pin.
   - The package name, the files changed, and the diff (truncated with a note).
   - The CI result.
   - Kritika and Konflate review comments, if any.
8. **Hard rules (code).** These are applied before the model is asked, and its answer can only raise the tier floor they set:
   - **Floor 3:** core components. The list is in code: Talos, talosctl, Kubernetes, Flux, Cilium, CloudNativePG/Postgres images, doco-cd (applied via Ansible, always needs human action), and the `renovate-config` repo.
   - **Floor 2:** major updates, updates Renovate marks breaking (`!` in the title, e.g. 0.x minor bumps), and failed CI.
   - **Comment-only:** repos where `agent-smith` lacks write access. No merge and no push happen there, so a tier 1 or tier 2 there is logged and commented as `would merge` or `would migrate, no write access`.
9. **Classify (model).** One OpenAI-compatible call to Agent Gateway, `mistral/small-4`, with JSON output:
   ```
   { "tier": 1|2|3, "summary": "...", "reasons": ["..."],
     "evidence": ["quoted release-note / diff lines relied on"],
     "migration": "what would need to change (tier 2 only)",
     "confidence": "high|medium|low" }
   ```
   - The run output logs both the full request evidence summary and the raw response.
   - An answer that doesn't parse or fails the schema is retried once. If it fails again, the PR becomes tier 3 with the reason `classifier failed`.
   - If the model cannot be reached on either attempt (HTTP 503, timeout), nothing is posted: `not touched: model unavailable …; retry next run`. A migration task that failed on a provider error is discarded and retried the same way.
   - A `low` confidence answer becomes tier 3.
   - The final tier is the higher of the model's tier and the hard-rule floor. When the floor overrides the model, the log says so.
10. **Act** (only in `live` mode; `dry-run` logs the same lines prefixed `would`):
    - **Processing indicator:** when the steward starts evaluating a PR (after the not-touched checks), it adds a 👀 (`eyes`) reaction as `agent-smith`, and removes it once the PR's comment is posted. A PR with a pending migration keeps 👀 until its result is posted. Reaction failures are logged and never stop the run.
    - **Tier 1:**
      1. Re-read the PR. The head must be unchanged and CI green.
      2. Merge it, using the repo's default merge style.
      3. Apply the `tier-1` label, and post a short comment with the reasons and the marker.
      4. Log the merge commit.
    - **Tier 2, queuing it (this run):**
      1. Clone the PR branch into `work/<repo>-<pr>-<sha>/`.
      2. Create a kanban task:
         - assignee `renovate-steward`, skill `renovate-migrate`, model `chatgpt/gpt-6-luna`
         - `--workspace dir:<that checkout>`
         - `--idempotency-key <repo>#<pr>@<sha>`, so the same commit can never be queued twice
         - `--max-runtime 900 --max-retries 1`
         - a body file holding the classifier's output and the evidence
      3. The worker only edits files in the checkout. It completes the task with a JSON summary of what it changed and why. Its skill forbids pushing and merging.
      4. In the same run, the PR gets the `tier-2` label. After its other PRs, the run waits for the migration it queued (checking every 20 s, up to 960 s) and finishes it in the same run (below), posting **one** comment: the reasons, quoted evidence, any hard-rule override, and what the migration did.
      5. A separate decision comment is posted first only when the migration can't finish in this run: the PR is waiting for the one migration slot, or the task is still running at the wait limit. The marker then records `migration=queued|deferred`; a waiting PR is queued on a later run without a new evaluation or comment, and the later result comment carries only the result, linking back to the decision.
    - **Tier 2, finishing it (in the run that queued it, or the first later run that finds the task finished; open tasks are checked before markers):**
      - **Still running:** the log says `migration in progress (task t_xxx, running since …)`, and the PR isn't touched.
      - **Done:**
        1. Check that the PR head is still the evaluated `sha`. If Renovate pushed in the meantime, discard the work, log it, and evaluate the new commit in the same run.
        2. Check that the PR branch on Forgejo hasn't moved.
        3. Commit the checkout's diff as `agent-smith`, and push it to the PR branch.
        4. Apply the `tier-2` label.
        5. Post the comment (combined, or result-only if a decision comment exists for this commit) with the worker's summary, the diffstat, the kanban task id and the marker with `pushed=<sha>`.
      - **Done with no changes:** the PR still gets `tier-2` and a comment saying no change was needed. It stays staged for review and is never merged.
      - **Blocked, failed or timed out:** the PR becomes tier 3, labelled and commented, with the failure taken from the task as the reason.
      - In every case, the log prints the task id and the path of its worker log (`/opt/data/kanban/logs/<task>.log`). The worker's full session is in the profile's `state.db`.
    - **Tier 3:** apply the `tier-3` label, and post a comment headed "needs human intervention" with the reasons and the marker.
    - **Review requests:** PRs that need Todd get a review request for `todd` from `agent-smith`: tier 3, failed migrations, tier-2 PRs once the migration result is posted, and tier-1 PRs that could not be merged. Merged PRs and pending migrations never request one, so Forgejo email can be limited to review requests. Failures are logged and never stop the run.
    - **Labels:** if a `tier-N` label is missing in a repo, it is created. When a new evaluation gives a different tier, the old tier label is removed.
11. **Limits.** One tier-2 migration at a time, across all repos, so two migrations never overlap. Further tier-2 PRs wait, and the log says `deferred: migration already in progress (task t_xxx for <repo>#<pr>)`. Waiting PRs are queued oldest first.
12. **Summary.** One line per PR (`merged`, `tier 2 queued`, `tier 2 staged`, `tier 3`, `not touched: <why>` or `error: <what>`), then the totals. A run with no PRs prints `No Renovate PRs open in N repos`.

Any exception while handling one PR is logged with its traceback and recorded as `error` in the summary, and the run moves on to the next PR. The run itself never ends silently.

## Testing and rollout

1. **Platform checks first** (the "still to confirm" list above). If one fails, the design is revisited before any building.
2. **Unit tests** with a fake Forgejo cover:
   - Each hard rule.
   - Marker parsing and the not-touched cases.
   - The checks-pending wait.
   - Classifier schema failures.
   - The rule that the higher tier always wins.
   - Comment-only repos.
   - The summary always being non-empty.
3. **My own dry run against the live PRs, before handing anything to Todd.** This is read-only, with no comments, labels or merges. The current open PRs make good test data:
   - **home-ops #985/#986 (Talos):** expected tier 3.
   - **#1010 (blackbox v12, major):** tier 2 or 3.
   - **#1003 (kaniop, breaking):** tier 2 or 3.
   - **#1004, #1005, #1006, #1009:** tier 1 candidates.
   - **#1001 (doco-cd):** a judgment call.
4. **Todd reads the dry-run output.** Once he's happy with it, I create the job in live mode (paused), Todd triggers the first live run from the UI, and he resumes the schedule.

## Calls I made (Todd can override)

- `small-4` for classifying, `gpt-6-luna` for tier-2 migrations.
- If unsure (low confidence, an unparseable answer, or a failed migration), the PR goes to tier 3.
- PRs with CI still running aren't evaluated until it finishes.
- One tier-2 migration at a time (Todd: they could overlap).
- A tier-2 PR normally gets its commit and one comment in the same run; only a migration that can't finish in that run is completed by a later run.
- The core-component list above.
- The tier label names are `tier-1`, `tier-2` and `tier-3`.
- The first live run happens only after Todd has reviewed a dry run.

## Access

`agent-smith` has write access on every repo in scope, including `esphome-config` and `renovate-config` (granted 2026-11-25). The comment-only rule applies only to repos added later without write access.
