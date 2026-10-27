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
  Since 2026-10-27 it is admin on all of `todd`'s repos. Add it as admin on any new repo.
- Models: review `litellm/chatgpt/gpt-6-luna`, fallback `litellm/neuralwatt/dsv4.1f`,
  through the LiteLLM virtual key `kritika-litellm` (`dev` namespace). Both are
  subscription-backed (`cost_usd: 0` in run logs).
- The kritika image has no shell, so `kubectl exec` tests are not possible. To test the
  models, run a request from the LiteLLM pod with the key piped in from the Secret.
