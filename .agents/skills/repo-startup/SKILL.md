---
name: repo-startup
description: Use ONLY at the very start of every conversation in this repo, before any other response, action, or skill selection. Runs `find .agents -type f`, reads every `SKILL.md` and `*.instructions.md`, and surfaces applicable repo rules. Triggers on new conversation, session start, when no prior repo context is loaded, or any repo-local instructions file may have been added or changed since AGENTS.md was last updated.
---

# Repo startup

Run this before responding to anything in a new session. The point is to make
every repo-local rule visible up front so they cannot be silently skipped.

## Steps

1. Run `find .agents -type f` from the repo root.
2. For every `*.instructions.md` under `.agents/instructions/`, read it. Note
   any rule that constrains the work you are about to do (commit message
   style, porting rules, GitOps reconcile rules, secret/remote handling,
   etc.).
3. For every `SKILL.md` under `.agents/skills/`, note the skill name and the
   trigger description. Skills whose description matches the current task
   MUST be loaded via the skill tool before responding.
4. Verify the contents of `AGENTS.md`. If it does not `@`-reference every
   `*.instructions.md` found in step 1, flag the gap and ask before editing.
5. State, in one or two short lines, which repo rules apply to the task at
   hand. Then proceed with the user's request while honouring them.

## Why this exists

Without this step, repo rules are easy to miss: they live on disk but are not
in the model context unless they are explicitly read. This skill forces the
read. `AGENTS.md` is the primary surface for keeping rules in context; this
skill is the safety net for any file added without an `AGENTS.md` update.