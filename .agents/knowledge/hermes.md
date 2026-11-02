# Hermes

## Testing a chat from the pod

`hermes chat` run through `kubectl exec` refuses to reach the gateway
(`unsafe_control_path`): `/opt/data` is the PVC root, owned by uid 0, and the pod runs as
uid 10000 without the privileges to change it. Test through the gateway's API server on
`127.0.0.1:8642` (`/v1/chat/completions`, bearer `API_SERVER_KEY` from the pod env)
instead; that is the path the Webapp uses.

## Forgejo access

`Forgejo - Hermes` in 1Password holds an access token for the `agent-smith` Forgejo user
in `password` (scopes `write:repository,write:issue,read:user`; without `read:user` the
API rejects `/api/v1/user`) and the account's login password in `login_password`. Forgejo
deletes tokens only with basic auth, so that password is needed to rotate one. The token
can push only to repos where `agent-smith` is a collaborator.
