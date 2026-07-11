# GitOps operating conventions

This repository is GitOps-managed by Flux. A webhook triggers Flux to reconcile
the `GitRepository` source on every commit, so pushed changes roll out on their
own.

## The rule

- **Do not manually reconcile the `GitRepository` source** (e.g.
  `flux reconcile source git flux-system`) unless specifically told to. The
  webhook already does this on commit.

- If a manual reconcile is genuinely needed (e.g. to speed up a rollout while
  troubleshooting), **ask first** — do not run it on your own.

- Monitoring a rollout is fine and expected: observe the `GitRepository`,
  `OCIRepository`, `HelmRelease`, and resulting workloads with read-only
  commands. Do not force reconciles as part of monitoring.
