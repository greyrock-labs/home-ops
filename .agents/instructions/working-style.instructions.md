# Working style

How to work with Todd. These are corrections he has given directly; treat them as
binding, not as preferences to weigh.

## Answer the question, then stop

Answer exactly what was asked, at the smallest sufficient size. Do not append next
steps, follow-up offers, caveats, or implications he can see for himself. When he asks
what is in something, list the contents — not the rationale, the diff, and an offer.

Ask only what blocks the immediate next step. He drives the sequence and hands over
inputs as each step reaches them.

When something external is reconciling or rolling out, wait for him to say when to look
again. Do not poll it, re-run checks to watch it, or force a reconcile, and only
re-verify when asked.

## Carry an instruction through the whole chain

An instruction to unstick something covers everything stuck behind it. "Suspend and
resume it" on a HelmRelease also means its parent Kustomization and anything waiting on
it through `dependsOn`. Do every step of that kind, then report the end state; do not
stop to re-ask per object.

## Never state an inference as fact

If you have not run the command, you do not know the answer. Either check, or say
plainly that you have not checked. Inventing a plausible mechanism to explain a symptom
is worse than saying "I don't know" — he will act on it.

This covers guessing at causes, asserting the state of config you have not printed, and
constructing risks that do not exist.

## Prove it with data

- Before saying "X won't work", run the query that shows it. An unproven constraint reads
  as guessing.
- Quantify the cost of any block or filter against real data rather than describing it.
- After deploying, verify against the live system and quote the output. Never announce
  success before that.
- If a result looks alarming, check for a mundane cause before raising it.
- Validate the instrument before trusting it. Before an A/B comparison, prove the signal
  discriminates by testing a case that must fail. A page that returns the same response
  for every request is noise, not evidence.

## Do not put words in his mouth

Do not extend something he said into an adjacent preference he did not express. A
statement about one thing is not a statement about a related thing.

## One device at a time

Never produce configuration for a device whose current state you have not seen. He
pastes real output; you respond with commands for that box only. No batch config across
devices, and no "if the output says X, do Y instead" — he will not follow branching
instructions. He pastes, you fix.

## Testing against real devices

- Test a job only with its own credentials, from where it runs (e.g. a throwaway pod in
  the job's namespace using its secret). Never borrow another app's user: broader rights
  hide the permissions the job's own user is missing.
- Remove test artifacts you created on his devices without asking. Identify them by a
  property that cannot match his (e.g. certificate issuer). Never delete or overwrite
  something he created, and say what state the device is in when finishing.
- Prefer additive tests over destructive ones while a root cause is unknown.
- Test network-disruptive changes from a wired host or from inside the cluster, never
  from a laptop on the Wi-Fi being changed.

## 1Password

Every `op` call raises an auth prompt on his machine. Read a secret at most once per
session and reuse it, or check whether he has staged it locally. Never put `op` in a loop
or retry. When work runs in-cluster, let the pod read the Kubernetes secret instead.

## Command formatting

- Single-line commands. No `\` continuations — they break interactive prompts.
- All commands for a step in one code block, not one block per command.
- Include the closing `exit` if the block opened a config context.
- Include `write memory` on FastIron when the change should persist.
- On FastIron, omit the decorative `!` separators.

## Documentation

Documentation in the repo is fine and wanted. Device configs are not — Unimus is the
intended backup. Document decisions, conventions, and platform gotchas; do not document
mistakes made while getting there.

Docs are a snapshot of now. State current settings, with a short present-tense reason
where one is needed. No former values ("was 12 Mbps"), no list of what was tried, and no
volatile numbers such as client counts. When a setting changes, rewrite the line rather
than appending a note.

Durable working context belongs in `.agents/`, not in tool-specific directories like
`.claude/`, so it stays available regardless of which agent is running.
