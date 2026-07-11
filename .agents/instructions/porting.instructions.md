# Porting commits from bjw-s-labs/home-ops

When bringing an upstream commit into this fork, the goal is fidelity to
upstream, not improvement of it.

## The rule

- **Bring changes over AS-IS.** Reproduce the upstream diff verbatim. The ported
  files should be byte-identical to the upstream version unless a change below is
  genuinely required.

- **Only adapt fork-specific values, and only when needed:**
  - Hostnames and domains (e.g. `*.greyrock.io`).
  - Paths.
  - Secret references — 1Password item/field names, `ExternalSecret` keys, and
    the `existingSecret`/`secretKeyRef` names they resolve to.

- **Do NOT rewrite values to match what you think is correct.** In particular:
  - Do NOT "fix" apparent upstream inconsistencies. If upstream sets a value that
    looks wrong for this fork (e.g. a `namespace:` that differs from where the app
    actually runs here), **leave it as upstream has it.**
  - Do NOT re-order, rename, restyle, or "clean up" beyond the required
    adaptations above.
  - Do NOT diverge on your own judgment. Divergence from upstream is a defect, not
    an enhancement.

## Verifying a port

After porting, diff each touched file against the upstream commit and confirm the
only differences are the intentional fork-specific adaptations:

```sh
git fetch upstream
diff <(git show <upstream-sha>:<path>) <path>
```

If the diff shows anything other than the hostname/path/secret adaptations you
deliberately made, revert it to match upstream.

## Commit messages

Write a message that is similar to upstream's but not identical — adapt it to this
repo's house style (`type(appname): verb`) rather than copying the upstream
subject verbatim.
