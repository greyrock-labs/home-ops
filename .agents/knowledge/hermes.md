# Hermes

## The gateway only autostarts if it was running before

On boot, `/etc/cont-init.d/02-reconcile-profiles` registers each profile's gateway as an
s6 service but starts only those whose last recorded state on the PVC is `running`. On
a fresh PVC there is no recorded state, so the gateway stays down, the cron ticker never
writes `/opt/data/cron/ticker_heartbeat`, and the `app` container fails its startup probe.

Start it once; the state is saved and later boots start it on their own:

```sh
kubectl -n ai exec deploy/hermes -c app -- sh -c 'cd /opt/data && /opt/hermes/.venv/bin/hermes gateway start'
```

## Forgejo access

`Forgejo - Hermes` in 1Password holds an access token for the `agent-smith` Forgejo user
in `password` (scopes `write:repository,write:issue,read:user`; without `read:user` the
API rejects `/api/v1/user`) and the account's login password in `login_password`. Forgejo
deletes tokens only with basic auth, so that password is needed to rotate one. The token
can push only to repos where `agent-smith` is a collaborator.
