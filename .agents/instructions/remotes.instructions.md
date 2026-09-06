# Git remotes in this repo

## The rule

- `forgejo` is the only remote. There is no second remote pointing at this
  repository or at any related / parent project.
- **Never add a remote pointing at a source / parent project**, unless the user
  explicitly authorizes it for the specific task at hand.
- Forbidden locations for any second remote: `.git/config`, a local clone, any
  worktree, the user's shell config, environment. There is no place where a
  remote pointing outside this fork belongs.
- When porting: stage the source commit into a throwaway ref (e.g. fetch into
  a temp ref via a one-shot URL, or apply a `git format-patch` / `git am` from
  a fetched tarball), do the cherry-pick, then leave no trace. Never create a
  named remote for it.

## Why

Pushing to the wrong remote (or pulling from one that mirrors to it) has
happened before and the user considers it a serious incident. The only source
of truth for this repo's main branch is `forgejo`.

## If a port is needed and no second remote exists

1. Ask first. Do not add a remote on your own initiative.
2. If approved, use a temporary fetch into a throwaway ref, do the work, then
  make sure no remote config remains (`git remote -v` must show only
  `forgejo`).
