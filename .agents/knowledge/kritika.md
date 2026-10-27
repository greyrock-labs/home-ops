# Kritika (AI PR review)

- Bot account on Forgejo is `lab-assistant`; it also posts the Konflate rendered-diff
  comments. Ask questions with `@lab-assistant <question>`; other commands are
  `review`, `pause`, `resume` and `dismiss <reason>` (upstream
  [Reviews and commands](https://kritika.home-operations.com/reviews/)).
- `lab-assistant` must be a repository **admin**, not just a writer, on every repo where
  mentions should work. Kritika checks the commenter's permission through
  `GET /repos/{owner}/{repo}/collaborators/{user}/permission`, which Forgejo only
  answers for repo or site admins. With write access, automatic reviews still run but
  mentions are ignored with `permission lookup failed` (403) then
  `follow-up ignored ... reason: permission unknown` in the `deploy/kritika` logs.
  It is admin on all of `todd`'s repos; add it as admin on any new repo.
- The kritika image has no shell, so `kubectl exec` tests are not possible. To test its
  models, send a request from the LiteLLM pod with Kritika's key piped in from its
  Secret.
