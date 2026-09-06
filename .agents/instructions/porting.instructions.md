# Porting commits from bjw-s-labs/home-ops

When bringing an upstream commit into this fork, the goal is fidelity to
upstream, not improvement of it.

## The rule

- **Bring changes over AS-IS.** Reproduce the upstream diff verbatim by default.
  The ported files should be byte-identical to the upstream version unless an
  adaptation below is genuinely required.

- **Adapt only deployment-environment values.** Things that legitimately differ
  because of where, who, or how this fork runs — e.g.:
  - Hostnames and domains (e.g. `*.greyrock.io`).
  - Paths (NFS mounts, claim names, on-disk locations).
  - Secret references — 1Password item/field names, `ExternalSecret` keys, and
    the `existingSecret`/`secretKeyRef` names they resolve to.
  - Region/locale settings (e.g. `timezone: America/New_York`).

- **Do NOT rewrite values to match what you think is correct.** In particular:
  - Do NOT "fix" apparent upstream inconsistencies. If upstream sets a value that
    looks wrong for this fork (e.g. a `namespace:` that differs from where the app
    actually runs here), **leave it as upstream has it.**
  - Do NOT re-order, rename, restyle, or "clean up" beyond the required
    adaptations above.

- **Divergences need approval and land as their own commit.** If during a port
  you find a real bug in the upstream diff, or a value that genuinely needs to
  differ from upstream for this fork, flag it and ask before changing anything.
  Once approved, land it as its own follow-up commit — do not bundle it into the
  port. **Never name the source repo in that follow-up's commit message.**

## Verifying a port

After porting, diff each touched file against the upstream commit and confirm the
only differences are the intentional fork-specific adaptations:

```sh
git fetch upstream
diff <(git show <upstream-sha>:<path>) <path>
```

If the diff shows anything other than the deployment-environment adaptations you
deliberately made, revert it to match upstream.

## Commit messages

Write a message that is similar to upstream's but not identical — adapt it to this
repo's house style (`type(appname): verb`) rather than copying the upstream
subject verbatim.
