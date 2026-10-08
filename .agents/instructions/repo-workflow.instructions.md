# Repo workflow

## Commits

Todd's own work is committed straight to `main` as linear commits and pushed to
`forgejo`; there are no feature branches. Merge commits come only from Renovate PRs. A
push to `main` is the deploy (see `gitops.instructions.md`), so a branch would not roll
out.

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

Write long bodies to a temp file first. Issues are used lightly (mostly Renovate's
dashboard), so a filed issue is a real signal.

## Environment

The Kubernetes nodes are on wired Ethernet. An in-cluster job can safely do something
that restarts the Wi-Fi (e.g. applying a certificate to the wireless controller) and
verify it afterwards by polling until the controller returns.

## Knowledge notes

App-specific findings that are not obvious from the manifests live in
`.agents/knowledge/`. Read the relevant note before working on that app.
