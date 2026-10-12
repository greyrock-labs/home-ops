# Repo workflow

## Commits

Todd's own work is committed straight to `main` as linear commits and pushed to
`forgejo`; there are no feature branches. History stays linear: Renovate PRs are
rebased onto `main`, not merged with a merge commit. A push to `main` is the deploy (see
`gitops.instructions.md`), so a branch would not roll out.

- One focused commit per concern, subject styled `type(appname): verb`.
- Do not add upstream port attribution to commit messages: no "Port(s) ...",
  source repository/commit references, or "cherry picked from commit" trailers.
  Describe the change itself.
- Push without asking when the change is low-risk (docs, agent instructions, routine
  fixes). Ask first only when the push is risky: it could take down a service, the
  network, storage, or anything hard to roll back.
- Do not open a PR unless asked.

## Forgejo CLI

The only remote is Forgejo (`git.greyrock.io`), so `gh` does not work. Use `tea`, which
is installed and authenticated. Its flags differ from `gh`:

- `tea issues create --title "..." --description-file <path>` (no `--body`).
- `tea comment <issue-number> "<body text>"`: the body is positional; `--body` and
  `--body-file` are rejected.
- `tea issues ls --state all`
- `tea pulls merge --style rebase <pr-number>` merges a PR the way the web UI does:
  the commits keep `renovate[bot]` as author. `--style merge` makes Todd the author of
  a merge commit; do not use it. Forgejo needs a few seconds after each merge before
  the next PR is mergeable again, so merge one at a time.
- After merging, delete the merged PR branches on `forgejo` and any stale local
  remote-tracking refs.

Write long bodies to a temp file first. Issues are used lightly (mostly Renovate's
dashboard), so a filed issue is a real signal.

## Removing things that use 1Password

When a deletion removes the last reference to a 1Password item (an `ExternalSecret`
`remoteRef.key`, a docker-compose secret, an Ansible lookup), delete that item from
1Password as part of the same task. Grep the repo for the item name first; an item
still referenced elsewhere stays.

## Environment

The Kubernetes nodes are on wired Ethernet. An in-cluster job can safely do something
that restarts the Wi-Fi (e.g. applying a certificate to the wireless controller) and
verify it afterwards by polling until the controller returns.

## Knowledge notes

App-specific findings that are not obvious from the manifests live in
`.agents/knowledge/`. Read the relevant note before working on that app.
