# Hermes model routing

Which model each kind of Hermes work runs on, why, and how to change it. This is
local tuning on top of the upstream-matching deployment; `README.md` covers the
deployment itself.

## Current routing

Set on 2026-11-13 in each profile's `config.yaml` on the PVC
(`/opt/data/profiles/homelab-operator/` and
`/opt/data/profiles/home-assistant-helper/`). The default profile
(`/opt/data/config.yaml`) is unchanged.

| Work | Config key | Model | Billed to |
|---|---|---|---|
| Main conversation | `model.default` (picker overrides per session) | `chatgpt/gpt-6-luna` | ChatGPT plan (5-hour limit) |
| Subagents | `delegation.provider` / `delegation.model` | `chatgpt/gpt-6-luna` | ChatGPT plan |
| Command approval checks | `auxiliary.approval` | `mistral/small-4` | Mistral, per token |
| Post-turn memory/skill review | `auxiliary.background_review` | `mistral/small-4` | Mistral, per token |
| Context compression | `auxiliary.compression` | `mistral/small-4` | Mistral, per token |
| Memory lookup rewriting | `auxiliary.memory_query_rewrite` | `mistral/small-4` | Mistral, per token |
| Session titles | `auxiliary.title_generation` | `mistral/small-4` | Mistral, per token |

Every other `auxiliary.*` task (for example `mcp`, `vision`, `goal_judge`,
`kanban_decomposer`) is still `provider: auto`. In Hermes, `auto` means "use the
main model", so those follow whatever model the session runs on.

All routes go through Agent Gateway using the profile's `agentgateway` provider
entry, so each value is `provider: agentgateway` plus a gateway model name. The
models Hermes may use are the `allowedModels` of the Hermes key in
`kubernetes/apps/ai/agentgateway/app/helmrelease.yaml`.

## Why

Before this change every side task and subagent inherited the main model. With
`chatgpt/gpt-6.1-sol` selected, one request on 2026-11-09 made 83 model calls and
processed about 6.2M input tokens for about 20k output tokens:

- Three parallel subagents got 2–7% cache hits and used about 1.64M uncached
  input tokens, over six times the main conversation's 260k.
- Titles, approval checks, compression and the post-turn review all ran on
  `sol` as well.

A later `sol` port of a ~100-file commit exhausted the 5-hour limit in one
request (about 128k tokens per call). Both ran through LiteLLM, before Agent
Gateway replaced it.

Side tasks are small and frequent, so they move off the ChatGPT plan entirely.
Subagents do real work (reading diffs, reviewing PRs), so they stay on a capable
model, but the lighter one.

## Changing it

Edit the keys above in each profile's `config.yaml`, then restart the gateway to
be sure running sessions pick up the change. These are profile-owned settings:
keep them out of the managed overlay (`app/resources/config.yaml`) so the overlay
keeps matching upstream. `README.md` explains how overlay keys interact with
Dashboard saves.

Likely adjustments:

- **Compression loses track of earlier work:** move `auxiliary.compression` to
  `chatgpt/gpt-6-luna`. Compression summaries need more care than the other side
  tasks.
- **Mistral spend is higher than expected:** move `background_review` back to
  Luna or disable it (`auxiliary.background_review.enabled: false`). It sends a
  snapshot of the conversation after turns.
- **Subagents still cost too much:** lower
  `delegation.max_concurrent_children` (default 10), or remove `delegation` from
  `platform_toolsets.cli` for the profile so it cannot fan out at all.

## Measuring

Hermes records per-session totals in each profile's `state.db`. The `sessions`
table has `model`, `api_call_count`, `input_tokens` (uncached),
`cache_read_tokens`, `output_tokens`, `reasoning_tokens` and
`parent_session_id` (set on subagents). Open it read-only, for example:

```sh
kubectl -n ai exec deploy/hermes -c app -- /opt/hermes/.venv/bin/python -c '
import sqlite3
c = sqlite3.connect("file:/opt/data/profiles/homelab-operator/state.db?mode=ro", uri=True)
for r in c.execute("select title, model, api_call_count, input_tokens, cache_read_tokens, output_tokens, parent_session_id is not null from sessions order by started_at desc limit 10"):
    print(r)'
```

Compare uncached against cached input. A low cache rate on long sessions or
subagents is the main cost signal.

Tool calls that arrive with empty arguments (`Invalid command: expected string,
got NoneType`) were about 8% of calls through LiteLLM, including every parallel
tool-call batch. Whether that persists through Agent Gateway and CLIProxyAPI has
not been measured yet; count `messages.tool_calls` entries with empty
`arguments` to check.

## Open questions

- Hermes reaches ChatGPT models with chat-completions through Agent Gateway and
  CLIProxyAPI. Codex uses the Responses format, which carries earlier reasoning
  between turns. Whether a Responses route works end to end through this chain is
  untested.

## Backups

The pre-change profile configs, the `homelab-operator` memory file, the default
`SOUL.md`, the `forge-repos` skill and the removed default-profile port skill are
in `/opt/data/backups/2026-11-13-model-routing/` on the PVC.
