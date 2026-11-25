# renovate-steward Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An hourly Hermes `--no-agent` cron job that tiers every open Renovate PR across Forgejo, merges tier 1, stages tier-2 migrations through Hermes kanban, comments on tier 3, and logs every step and reason to the run output.

**Architecture:**
- **Script:** a stdlib-only Python package runs on the Hermes PVC. It owns the loop, the hard rules, every Forgejo action, and all logging (stdout, which is the cron run output).
- **Model:** one Agent Gateway chat-completions call per PR commit returns the tier as JSON.
- **Tier 2:** queued as a kanban task for the `renovate-steward` profile. The worker only edits files. A later run commits, pushes and comments.

**Tech Stack:**
- Python 3 stdlib (`urllib`, `json`, `subprocess`); pytest for tests only.
- The Forgejo API (v1) and `git`, through the shared forge toolkit (`/opt/data/shared/lib/forge_common.py`, `forge-git`, `git-credential-forge`).
- `hermes kanban` CLI.
- Agent Gateway's OpenAI-compatible endpoint, `http://agentgateway.ai.svc.cluster.local:8080/v1`.

**Spec:** `renovate-steward-design.md`, approved 2026-11-25. It lives next to this plan in `kubernetes/apps/ai/hermes/`; the decision ledger is on the PVC at `/opt/data/profiles/renovate-steward/docs/ledger.md`.

## Global Constraints

- **Location:**
  - The code lives only on the Hermes PVC under `/opt/data/profiles/renovate-steward/`.
  - The repo holds this plan, the design, and a short section in the Hermes README (Task 8).
  - Development happens in `$SCRATCH/renovate-steward/`, with the same layout, and is installed into the PVC with `tar | kubectl exec`.
- **Dependencies:** runtime is stdlib only. The script runs with `/opt/hermes/.venv/bin/python3`.
- **Secrets:**
  - The Forgejo token is read only through `forge_common.token("git.greyrock.io")`.
  - The Agent Gateway key is read only from `/mnt/secrets/agentgateway/key`.
  - Never print or store either one.
- **Forge:** host `git.greyrock.io`; the Renovate author login is `renovate`; the bot identity is `agent-smith`.
- **Models:**
  - The classifier uses `mistral/small-4`.
  - The migration worker uses `chatgpt/gpt-6-luna` through the `agentgateway` provider.
- **Labels:** `tier-1`, `tier-2`, `tier-3`.
- **Marker:** `<!-- renovate-steward sha=<40-hex> tier=<1|2|3> pushed=<40-hex or -> -->`, placed on the last line of every steward comment.
- **Kanban task:**
  - Idempotency key `<owner>/<repo>#<n>@<sha>`, `--max-runtime 900`, `--max-retries 1`.
  - Workspace `dir:/opt/data/profiles/renovate-steward/work/<owner>-<repo>-<n>-<sha12>`.
  - **At most one task** in `ready` or `running` at any time.
- **Core components (tier floor 3):** a package name, file path or repo matching `talos`, `talosctl`, `siderolabs`, `kubernetes`, `kubectl`, `kubelet`, `flux`, `fluxcd`, `cilium`, `cloudnative-pg`, `cnpg`, `postgres`; also any PR in repo `greyrock-labs/renovate-config`.
- **Floor 2:** update type `major`, or a failed combined CI status.
- **Logging:**
  - Every stdout line is `<UTC ISO8601> <scope> <message>`, where scope is `run`, `repo owner/repo`, or `owner/repo#n@sha7`.
  - The run's final line is always the summary, and output is never empty.
- **Modes:** `--dry-run` (writes nothing anywhere; actions are logged as `would …`) and live (the default).
- **Cron job:** `20 * * * *`, `--no-agent --script steward.py --deliver local --no-wrap-response`, created `--paused`.

## Review Focus

1. **A PR's head moves during a run** (Renovate rebases between evaluation and merge). The steward must not merge or push. It logs `head moved, re-evaluate next run`. Tested in Task 5 (merge) and Task 6 (push).
2. **A repo with no Renovate PRs, or archived, or a mirror.** It is listed in the log with its count, or the reason it was skipped, and nothing crashes. Tested in Task 5.
3. **Forgejo or the model returns an error or bad JSON for one PR.** That PR gets an `error:` or `tier 3 (classifier failed)` line, and the remaining PRs still run. Tested in Tasks 4 and 5.
4. **A PR that the steward already commented on but whose label was removed by hand.** It is still `not touched`, because the marker decides, and the log says so. Tested in Task 2.
5. **The kanban task finishes but the checkout has no diff,** or the task is blocked or archived. The first gives `tier-2 no change needed`; the second gives tier 3 with the task's failure text. Tested in Task 6.

---

### Task 1: Platform checks, profile, install path

There's no code in this task. Each check gets a pass/fail line in the task notes. If any check fails, stop and report to Todd.

**Files (PVC):**
- Create: the `/opt/data/profiles/renovate-steward/` profile, via `hermes profile create renovate-steward --no-alias --no-skills --description "Tiers Renovate PRs across Forgejo; merges tier 1, stages tier 2, explains tier 3."`.
- Modify: the profile's `config.yaml`: `model.default: chatgpt/gpt-6-luna`, `provider: agentgateway`, no `mcp_servers`, toolsets limited to file and terminal (match the key names in `homelab-operator/config.yaml`).
- Create: `docs/design.md` and `docs/plan.md`, copied from scratch.

**Steps:**
- [ ] **Step 1: Create the profile and edit its config.** Then:
  - Run `hermes -p renovate-steward config show` (or `cat` the config). Expected: model luna, no MCP servers.
  - Verify that `sha256sum` of the other profiles' `config.yaml` files is unchanged before and after.
- [ ] **Step 2: Model JSON check.** As the `hermes` user, POST to `/v1/chat/completions`:
  - Model `mistral/small-4`, with the key from `/mnt/secrets/agentgateway/key`.
  - `response_format: {"type":"json_object"}`, and the prompt `Return {"ok": true}`.
  - Expected: HTTP 200, and the content parses as JSON.
  - If `response_format` is rejected, record that. The classifier then relies on the prompt plus a parse retry (Task 4 handles both).
- [ ] **Step 3: Forgejo token and write access.** Run `python3 -I -c 'import sys; sys.path.insert(0,"/opt/data/shared/lib"); from forge_common import token; token("git.greyrock.io")'`. Expected: exit 0, and nothing printed. Then, with `forge-auth git.greyrock.io -- curl …`:
  - GET `/api/v1/repos/search?limit=50`. Expected: all greyrock-labs repos.
  - GET `/api/v1/repos/greyrock-labs/home-ops/collaborators/agent-smith/permission`. Expected: `write`.
- [ ] **Step 4: Push access to a Renovate branch.** Check out the head branch of home-ops #1004 with `forge-git repo ensure`. In that checkout, run `git push --dry-run origin HEAD:<branch>`. Expected: no auth error.
- [ ] **Step 5: Kanban round trip as the steward profile.**
  1. Create the task: `hermes kanban create "probe: steward worker" --assignee renovate-steward --model mistral/small-4 --provider agentgateway --workspace dir:/opt/data/profiles/renovate-steward/work/probe --max-runtime 300 --max-retries 1 --idempotency-key steward-probe-1 --body "Create the file probe.txt containing OK in your workspace, then complete this task with --summary '{\"changed\": [\"probe.txt\"]}'."`. Create the `work/probe` directory first.
  2. Poll `hermes kanban show <id> --json` in short foreground steps, up to 5 minutes.
  3. Expected: the status is `done`, `work/probe/probe.txt` exists, and the summary is visible in the JSON.
  4. Record the exact JSON field names for status, summary and the last failure. Task 6 uses them.
  5. Archive the task and delete `work/probe`.
- [ ] **Step 6: Copy the design and plan** to `docs/`, and record the check results at the bottom of `docs/plan.md`.

---

### Task 2: Log, Forgejo client, markers

**Files:**
- Create: `steward/__init__.py`, `steward/log.py`, `steward/forgejo.py`, `steward/markers.py`
- Test: `tests/test_log.py`, `tests/test_markers.py`, `tests/test_forgejo.py`, `tests/fakes.py`

**Interfaces:**
- Produces:
  - `Log(out=sys.stdout, now=callable)`, with methods:
    - `.run(msg)`, `.repo(full_name, msg)`, `.pr(pr: PR, msg)`
    - `.block(pr, title, text)`: multi-line text, with each line prefixed by `  | `
    - `.lines` (a list of everything written)
  - `@dataclass PR(owner, repo, number, title, body, head_sha, head_ref, author, url, labels: list[str])`; property `full = "owner/repo"`; method `scope() -> "owner/repo#n@sha7"`.
  - `class Forgejo(base="https://git.greyrock.io/api/v1", token=None, http=None)`. `http` is an injectable `(method, url, headers, body) -> (status, dict|list)`. Methods:
    - `repos() -> list[dict]` (`/repos/search`, paginated, all pages)
    - `renovate_prs(owner, repo) -> list[PR]` (state open, author login `renovate`)
    - `pr(owner, repo, n) -> PR`
    - `comments(owner, repo, n) -> list[dict]`
    - `combined_status(owner, repo, sha) -> dict` (`/commits/{sha}/status`)
    - `pr_files(owner, repo, n) -> list[dict]`, `pr_diff(owner, repo, n) -> str`
    - `permission(owner, repo) -> str`
    - `ensure_label(owner, repo, name) -> int`, `set_tier_label(owner, repo, n, tier)` (removes the other `tier-*` labels)
    - `comment(owner, repo, n, body) -> dict`
    - `merge(owner, repo, n, head_sha, style) -> None` (sends `head_commit_id`)
    - `repo_info(owner, repo) -> dict`
    - Any non-2xx response raises `ForgejoError(status, url, body_excerpt)`.
  - `markers.build(sha, tier, pushed=None) -> str`
  - `markers.latest(comments: list[dict], bot_login="agent-smith") -> Evaluation | None`, where `@dataclass Evaluation(sha, tier, pushed, comment_id, created_at, url)`. It returns the newest marker-bearing comment by `agent-smith`.

- [ ] **Step 1: Write the failing tests:**
  - `test_log_line_format`: each line matches `^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ (run|repo \S+|\S+#\d+@[0-9a-f]{7}) .+$`.
  - `test_log_block_prefixes_every_line`
  - `test_marker_roundtrip`: `latest([{"user":{"login":"agent-smith"},"body":"x\n"+build(S,2,P),…}])` gives `sha==S, tier==2, pushed==P`.
  - `test_marker_ignores_other_users`
  - `test_marker_newest_wins`
  - `test_marker_survives_label_removal`: the marker alone decides.
  - `test_forgejo_paginates_repos` (fake http with 2 pages)
  - `test_renovate_prs_filters_author`
  - `test_merge_sends_head_commit_id`
  - `test_forgejo_error_raises_with_status`
- [ ] **Step 2: Run** `cd $SCRATCH/renovate-steward && uv run --no-project --with pytest pytest -q tests/test_log.py tests/test_markers.py tests/test_forgejo.py`. Expected: they fail with an import error.
- [ ] **Step 3: Implement the three modules** to the interfaces above. `Forgejo.__init__` gets the token from `forge_common.token("git.greyrock.io")` when none is passed, with the import path `/opt/data/shared/lib`.
- [ ] **Step 4: Run the same command.** Expected: all pass.

---

### Task 3: Evidence and hard rules

**Files:**
- Create: `steward/evidence.py`, `steward/rules.py`
- Test: `tests/test_evidence.py`, `tests/test_rules.py`

**Interfaces:**
- Consumes: `Forgejo`, `PR`.
- Produces:
  - `@dataclass Evidence(pr: PR, update_type: str, packages: list[str], files: list[str], diff: str, diff_truncated: bool, ci_state: str, ci_contexts: list[dict], review_comments: list[str], release_notes: str, automerge: bool)`.
    - `update_type` is one of `major|minor|patch|digest|pin|unknown`.
    - `ci_state` is one of `success|failure|pending|error|none`.
  - `gather(fj: Forgejo, pr: PR, diff_limit=12000) -> Evidence`.
  - `Evidence.to_prompt() -> str`: the plain-text block sent to the model and logged.
  - `@dataclass Floor(tier: int, reasons: list[str])`.
  - `rules.floor(ev: Evidence) -> Floor`.
  - `rules.final_tier(model_tier: int, floor: Floor) -> tuple[int, str|None]`. The second element is the override note when the floor raised the tier.

- [ ] **Step 1: Write the failing tests:**
  - **Update type:**
    - `test_update_type_major_from_title_bang`: `feat(helm)!: Update chart … to v12` gives major.
    - `test_update_type_from_versions`: `(11.24.0 ➔ 11.26.2)` gives minor, `(8.3.114 ➔ 8.3.115)` gives patch, `(8c2a1a9 ➔ b856c51)` gives digest.
  - **Automerge:** `test_automerge_detected_from_body` (`**Automerge**: Enabled`).
  - **Diff:** `test_diff_truncated_flag`.
  - **Review comments:** `test_review_comments_collected`, covering comments by kritika/konflate logins found in the comments. Use the logins that appear on home-ops #1003. Look them up in Task 3 Step 0 with `forge-auth git.greyrock.io -- curl …/issues/1003/comments` and record them here.
  - **Floors:**
    - `test_floor_core_talos`: package `siderolabs/talos` gives floor 3.
    - `test_floor_core_by_path`: a file under `kubernetes/talos/` gives floor 3.
    - `test_floor_renovate_config_repo` gives 3.
    - `test_floor_major_is_2`
    - `test_floor_ci_failure_is_2`
    - `test_floor_patch_is_1`
  - **Final tier:**
    - `test_final_tier_floor_wins`: `(1, Floor(3,…))` gives `(3, "floor raised 1→3: …")`.
    - `test_final_tier_model_higher_kept`: `(3, Floor(1,[]))` gives `(3, None)`.
- [ ] **Step 2: Run them.** Expected: they fail.
- [ ] **Step 3: Implement.** Release notes are the PR body section after `### Release Notes`, or the whole body if that heading is absent. Packages come from the body's Renovate table (`| Package |` rows) and the title.
- [ ] **Step 4: Run them.** Expected: they pass.

---

### Task 4: Classifier

**Files:**
- Create: `steward/classify.py`, `prompts/classify.md`
- Test: `tests/test_classify.py`

**Interfaces:**
- Consumes: `Evidence`.
- Produces:
  - `@dataclass Verdict(tier: int, summary: str, reasons: list[str], evidence: list[str], migration: str, confidence: str, raw: str)`.
  - `classify(ev: Evidence, log: Log, post=None, model="mistral/small-4") -> Verdict`.
    - `post` is an injectable `(payload: dict) -> str` (the content string).
    - It logs the full raw response with `log.block(pr, "model response", raw)`.
    - It retries once on a parse or schema failure.
    - A second failure returns `Verdict(tier=3, summary="classifier failed", reasons=[<error>], …)`.
    - `confidence == "low"` forces `tier=3`, and the reasons get `low confidence → tier 3` appended.
  - The tier definitions in `prompts/classify.md` are Todd's wording:
    - **Tier 1:** safe to merge without supervision.
    - **Tier 2:** needs migration work Todd doesn't have to do himself.
    - **Tier 3:** needs Todd to check the migration work and the final outcome.
    - The prompt also requires quoted evidence lines and the JSON schema from the spec, and says: "if unsure, choose the higher tier".

- [ ] **Step 1: Write the failing tests:**
  - `test_valid_json_verdict`
  - `test_retry_then_success` (the first response is garbage, the second valid; assert 2 posts)
  - `test_two_failures_tier3`
  - `test_low_confidence_forces_tier3`
  - `test_schema_rejects_tier_4`
  - `test_raw_response_logged`: the log lines contain the raw text.
  - `test_http_error_is_classifier_failure`
- [ ] **Step 2: Run them.** Expected: they fail.
- [ ] **Step 3: Implement.** The default `post` reads the key file and POSTs to `…/v1/chat/completions` with `temperature: 0`. It includes `response_format: {"type":"json_object"}` only if Task 1 Step 2 showed it is accepted, and it times out after 120 s.
- [ ] **Step 4: Run them.** Expected: they pass.

---

### Task 5: The run: tier 1, tier 3, not-touched, summary

**Files:**
- Create: `steward/run.py`, `scripts/steward.py`
- Test: `tests/test_run.py`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `main(argv=None) -> int`, which parses `--dry-run`.
  - `run(fj, log, classify_fn, migrator, dry_run: bool) -> list[Outcome]`, where `@dataclass Outcome(scope: str, result: str)`. `result` is one of `merged`, `tier 2 queued`, `tier 2 staged`, `tier 3`, `not touched: …` and `error: …`.
  - `scripts/steward.py` inserts the profile dir into `sys.path` and calls `sys.exit(main())`.

**Per-PR order** (each branch logs its reason line):
1. `markers.latest`: if head ∈ {sha, pushed}, the result is `not touched: evaluated as tier N at sha7 on DATE (comment URL); no new commits since`.
2. `migrator.owns(pr)`: if a migration task exists for this PR, see Task 6.
3. `ci_state == pending` gives `not touched: checks pending (<context names>)`.
4. `ev.automerge` gives `not touched: Renovate automerges this PR`.
5. Log the evidence block, the floor, the verdict (with reasons and quotes), and the override note.
6. **Tier 1:**
   1. `permission != write|admin` means comment only.
   2. Otherwise, re-read the PR (head unchanged? `ci_state == success`?).
   3. Merge with the repo's `default_merge_style`.
   4. Apply the label.
   5. Post the comment (summary, reasons, marker).
7. **Tier 2:** `migrator.queue(pr, ev, verdict)` (Task 6).
8. **Tier 3:** apply the label, then post the comment (summary, reasons, quoted evidence, marker).

Wrap every PR in `try/except Exception`: log the traceback with `log.block` and record `error: <type>: <msg>`. The final summary is one line per outcome, then the totals. If no PRs exist, print `No Renovate PRs open in N repos`.

- [ ] **Step 1: Write the failing tests** against `fakes.FakeForgejo` and fake classify and migrator:
  - **Marker and repo handling:**
    - `test_not_touched_when_marker_matches_head`: no comment or label calls, and a log line containing `not touched: evaluated as tier`.
    - `test_not_touched_when_head_is_pushed_sha`
    - `test_new_commit_reevaluates_and_new_comment`
    - `test_archived_and_mirror_repos_skipped_with_reason`
    - `test_repo_without_prs_logged_with_zero`
  - **Pre-evaluation skips:**
    - `test_pending_ci_not_touched_names_contexts`
    - `test_automerge_not_touched`
  - **Tier 1:**
    - `test_tier1_merges_with_head_commit_id_labels_and_comments`
    - `test_tier1_head_moved_does_not_merge` (Review Focus 1)
    - `test_tier1_no_write_permission_comment_only`
  - **Floors and tier 3:**
    - `test_floor_overrides_logged`
    - `test_tier3_labels_and_comments_with_marker`
  - **Errors, summary, modes:**
    - `test_one_pr_error_does_not_stop_others` (Review Focus 3)
    - `test_summary_always_last_and_nonempty`
    - `test_no_prs_message`
    - `test_dry_run_writes_nothing`: the FakeForgejo write-call list is empty, and the log contains `would merge`.
- [ ] **Step 2: Run them.** Expected: they fail.
- [ ] **Step 3: Implement** `run.py` and `scripts/steward.py`.
- [ ] **Step 4: Run the full suite.** Expected: it passes.

---

### Task 6: Tier 2 through kanban

**Files:**
- Create: `steward/migrate.py`, `skills/renovate-migrate/SKILL.md`
- Test: `tests/test_migrate.py`

**Interfaces:**
- Consumes: `Forgejo`, `Log`, `PR`, `Evidence`, `Verdict`, and the kanban JSON field names recorded in Task 1 Step 5.
- Produces `class Migrator(fj, log, kanban=None, git=None, dry_run=False)`:
  - `kanban` is injectable: `(args: list[str]) -> dict|list` (runs `hermes kanban … --json`).
  - `git` is injectable: `(cwd, args) -> str`.
  - `in_flight() -> Task | None`: the single `ready`/`running` task assigned to `renovate-steward`.
  - `owns(pr) -> Task | None`: finds the task by idempotency key `owner/repo#n@head_sha`, and also the task for the PR's previous sha.
  - `queue(pr, ev, verdict) -> Outcome`:
    - If `in_flight()`, return `not touched: deferred: migration already in progress (task t_x for owner/repo#n)`.
    - Otherwise, `forge-git repo ensure` and check out `head_ref` into the workspace dir (a fresh clone at `pr.head_sha`). Write the body file (verdict JSON, plus `ev.to_prompt()`), then `hermes kanban create …`, using the exact flags in Global Constraints with `--skill renovate-migrate --assignee renovate-steward --model chatgpt/gpt-6-luna --provider agentgateway --body-file`.
  - `finish(pr, task) -> Outcome`:
    - **running/ready:** `not touched: migration in progress (task t_x, running since …)`.
    - **done:**
      1. Re-read the PR; if head ≠ the task sha, log `head moved; migration discarded`, delete the workspace, and return `not touched: re-evaluate next run`.
      2. Check `git ls-remote` of the branch == the task sha.
      3. If `git status --porcelain` is empty, label `tier-2` and post a comment saying no change was needed (marker `pushed=-`).
      4. Otherwise, commit `chore(renovate-steward): migrate for <title>` and push. Verify the remote head with `ls-remote`.
      5. Label `tier-2`, and post the comment (the worker summary, `git diff --stat`, task id, and marker `pushed=<new sha>`).
      6. Delete the workspace.
    - **blocked/failed/archived:** label `tier-3`, and post a comment with the task's failure text and the marker.
    - In every case, log the task id and `/opt/data/kanban/logs/<task>.log`.
  - `run.py` calls `finish` for `owns(pr)` before evaluating. Oldest PRs are queued first (sort PRs by number within the run).
- `skills/renovate-migrate/SKILL.md`:
  - The worker reads the body.
  - It makes only the minimal migration edits the release notes require, inside its workspace.
  - It never runs `git commit`, `git push` or any `forge-auth` command, and never merges.
  - It completes with `--summary` holding JSON `{"changed": [...], "why": "...", "notes_for_todd": "..."}`.
  - If it can't do the migration safely, it runs `hermes kanban block` with the reason.

- [ ] **Step 1: Write the failing tests:**
  - **Queuing:**
    - `test_queue_creates_task_with_exact_flags`: assert the idempotency key, workspace, model, `--max-runtime 900` and `--max-retries 1`.
    - `test_queue_deferred_when_one_in_flight`
  - **Finishing:**
    - `test_finish_running_not_touched`
    - `test_finish_done_commits_pushes_labels_comments_with_pushed_marker`
    - `test_finish_done_no_diff_no_change_comment` (Review Focus 5)
    - `test_finish_head_moved_discards` (Review Focus 1)
    - `test_finish_blocked_tier3_with_failure_text` (Review Focus 5)
  - **Modes:** `test_dry_run_queue_writes_nothing`
- [ ] **Step 2: Run them.** Expected: they fail.
- [ ] **Step 3: Implement** `migrate.py` and write `SKILL.md`.
- [ ] **Step 4: Run the full suite.** Expected: it passes.

---

### Task 7: Install and my own dry run against live PRs

- [ ] **Step 1: Install.** Copy the code, prompts, skills, scripts and tests into `/opt/data/profiles/renovate-steward/` with `tar | kubectl exec`. In the pod, run `cd … && mise x uv -- uv run -q --no-project --with pytest pytest -q -p no:cacheprovider`. Expected: everything passes.
- [ ] **Step 2: Dry run.** In the pod, as `hermes`, run `/opt/hermes/.venv/bin/python3 /opt/data/profiles/renovate-steward/scripts/steward.py --dry-run`, with a 15-minute timeout. Save the output to the PVC at `logs/dryrun-<ts>.log`.
- [ ] **Step 3: Check the output against these expectations.** Any mismatch is fixed at its cause, with a test first, before going back to Step 2.
  - Every repo is listed.
  - Every open Renovate PR has exactly one summary line.
  - home-ops #985 and #986 are tier 3, with the floor note.
  - #1010 is at least tier 2 (major).
  - Nothing was written: no new comments or labels on Forgejo (check one PR's comments by API), and no kanban task created.
- [ ] **Step 4: Report to Todd:** the dry-run summary lines, the path to the full log, and anything surprising. Then wait for his go-ahead.

---

### Task 8: Go live (after Todd's go-ahead)

- [ ] **Step 1: Create the job.** As `HERMES_HOME=/opt/data/profiles/renovate-steward`, run `hermes cron create "20 * * * *" --name renovate-steward --no-agent --script steward.py --deliver local --no-wrap-response --paused --paused-reason "awaiting first supervised run"`. Expected: `hermes cron list` shows it paused.
- [ ] **Step 2: First live run.** Tell Todd it's ready to trigger from the UI. When he says it's triggered, read the run output under `cron/output/<job id>/` and report every action taken.
- [ ] **Step 3: Resume the schedule** when Todd says so.
- [ ] **Step 4: README.** Add a short "renovate-steward" section to the Hermes README in home-ops: what it does, where it lives on the PVC, how to read a run, and how to pause it. Open the PR with `fjo` and merge it when Todd says so.
