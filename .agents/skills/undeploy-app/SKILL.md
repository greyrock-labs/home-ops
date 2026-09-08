---
name: undeploy-app
description: Use when removing a deployed app from the cluster or a docker host — Flux k8s apps under kubernetes/apps/, docker-compose stacks under docker/, "remove X from the cluster", "tear down Y", "get rid of Z"
---

# Undeploy an App

Removes a Flux-managed k8s app under `kubernetes/apps/<namespace>/<app>/` or a docker-compose stack under `docker/<host>/NN-<app>/`. Mirrors `add-app` / `add-docker-app` in reverse — same directory layouts, so most of the work is "delete files, then edit the parent's registry list." In doubt, mirror a recent removal: `git log --diff-filter=D --name-only --format= | grep -E '^kubernetes/apps/'` shows past removals.

## Step 1: Check for cross-app references

Before deleting anything, find what depends on the app — leaving a stale reference will break another Kustomization's `dependsOn`:

```bash
grep -rE "<app>|targetNamespace: <namespace>" kubernetes/apps/
grep -rE "<app>" docker/
grep -rE "<app>" .forgejo/workflows/ 2>/dev/null   # e.g. konflate evidence providers
```

Common dependencies to look for:

- **Other Kustomizations with `dependsOn`** pointing at this app's Kustomization (these must be updated first or in the same commit)
- **Gateway routes / HTTPRoutes / DNSEndpoints** referencing the app's hostname (will silently stop reconciling after the service is gone, leaving stale DNS records in UniFi)
- **1Password items** referenced by *other* apps — leave the item, only its reference goes
- **ExternalSecrets** in other apps referencing the same 1Password field

If anything turns up, surface it to the user before proceeding.

## Step 2: Delete the app directory

**Flux-managed k8s app:**

```bash
git rm -r kubernetes/apps/<namespace>/<app>/
```

The Flux Kustomization that owns the app has `prune: true` (per `add-app` convention), so Flux garbage-collects the Kubernetes resources (HelmRelease, Service, etc.) on its next reconciliation.

**doco-cd-managed docker app:**

```bash
git rm -r docker/<host>/NN-<app>/
```

doco-cd's auto-discovery has `delete: true` (`docker/<host>/.doco-cd.yaml`), so on its next reconciliation it tears down the docker-compose stack on the docker host.

## Step 3: Edit the parent registry lists

**Flux k8s app:** remove the `./<app>/ks.yaml` line from `kubernetes/apps/<namespace>/kustomization.yaml` `resources`, keeping the rest alphabetically sorted. Do not touch other entries. If the namespace now has zero apps, leave the `kustomization.yaml` and `namespace.yaml` in place — Flux handles empty namespaces.

**Docker app:** if `docker/<host>/NN-<app>/docker-compose.yaml` references any `op://...` values under `external_secrets` in `docker/<host>/.doco-cd.yaml`, remove those entries. For skedaddle apps serving HTTP, remove the hostname from **both** `VPS_LOCAL_HOSTS` in `docker/skedaddle/03-caddy-l4/docker-compose.yaml` AND the matching site block in `docker/skedaddle/03-caddy-l4/config/Caddyfile` (missing one leaves a dead TLS cert or a 502).

## Step 4: Verify

```bash
grep -rE "<app>" kubernetes/ docker/   # should return nothing
yamllint --config-file .yamllint.yaml kubernetes/apps/<namespace>/ docker/<host>/
```

## Step 5: Commit

Format:

```
feat(<app>)!: undeploy
```

Rules:

- **Type**: `feat` — the app is being added/removed as a feature of the cluster.
- **Scope**: the app name (`<app>`), never the category (`observability`, `selfhosted`, ...).
- **Breaking-change marker**: `!` — removal is a breaking change for the cluster.
- **Verb**: `undeploy`, lowercase.
- **Subject**: single line, no body.
- **Docker apps**: append ` from NAS` after the verb (mirror `add-docker-app`'s `feat(<app>): Deploy to NAS`): `feat(<app>)!: undeploy from NAS`.

## Common mistakes

- **Skipping Step 1** — `dependsOn` from another Kustomization points at a Kustomization that no longer exists; the dependent fails to reconcile until updated in the same commit or a follow-up.
- **Leaving the entry in the parent `kustomization.yaml`** — Kustomize will refuse to build (or worse, build an empty app silently).
- **Half-removing a docker host's HTTP hostname registration** — apps serving HTTP typically register the hostname in two places (reverse-proxy config and an env var or hosts file). Removing one leaves the other routing to a dead container.
- **Reaching for `git restore` instead of `git rm`** — leaves the working tree out of sync with the index, fails the next `git status`.
- **Using a category as scope** (`feat(<category>)!: ...`) instead of the app name (`feat(<app>)!: ...`).
- **Adding a multi-line commit body** explaining the removal.
- **Capitalizing the verb** (`Undeploy`) — use lowercase `undeploy`.