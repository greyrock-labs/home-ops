# Working style

How to work with Todd. These are corrections he has given directly; treat them as
binding, not as preferences to weigh.

## Answer the question, then stop

Answer exactly what was asked, at the smallest sufficient size. Do not append next
steps, follow-up offers, caveats, or implications he can see for himself. When he asks
what is in something, list the contents — not the rationale, the diff, and an offer.

Ask only what blocks the immediate next step. He drives the sequence and hands over
inputs as each step reaches them.

## Never state an inference as fact

If you have not run the command, you do not know the answer. Either check, or say
plainly that you have not checked. Inventing a plausible mechanism to explain a symptom
is worse than saying "I don't know" — he will act on it.

This covers guessing at causes, asserting the state of config you have not printed, and
constructing risks that do not exist.

## Do not put words in his mouth

Do not extend something he said into an adjacent preference he did not express. A
statement about one thing is not a statement about a related thing.

## One device at a time

Never produce configuration for a device whose current state you have not seen. He
pastes real output; you respond with commands for that box only. No batch config across
devices, and no "if the output says X, do Y instead" — he will not follow branching
instructions. He pastes, you fix.

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

Durable working context belongs in `.agents/`, not in tool-specific directories like
`.claude/`, so it stays available regardless of which agent is running.
