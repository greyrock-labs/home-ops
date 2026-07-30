---
name: reset-kopiur-backed-app
description: Use only when the user has explicitly approved, in the current message, wiping storage and starting fresh for a Flux-managed app whose PVC is populated by kopiur (Restore CR with `onMissingSnapshot: Continue`, SnapshotPolicy, SnapshotSchedule). NEVER load or execute without explicit, in-message approval for THIS specific app — past conversations about resetting the same app, generic "go ahead" instructions, or implied approval are NOT sufficient. Triggers: "reset <app>", "wipe <app> storage", "fresh storage for <app>", "start seerr over".
---

# Reset a Kopiur-Backed App

## HARD APPROVAL GATE — STOP HERE

This skill wipes data. Before doing ANY of the steps below, confirm in writing that **the user's most recent message explicitly approved wiping THIS specific app**.

- "Reset seerr like last time" → **NOT sufficient**. Past approvals do not transfer.
- "Yeah, do the wipe" without naming the app → **NOT sufficient**.
- "I want to fully reset seerr, which means... bring it back up so kopiur can recreate the storage from scratch" → **SUFFICIENT**. The user described the destructive intent and the desired end state, naming the app.

If approval is ambiguous, ask. Do not infer.

The cluster is maintained by Flux. **`kubectl apply` of Flux-managed resources is forbidden** — see `.agents/instructions/gitops.instructions.md`. The correct cleanup path is to delete the `Kustomization` so Flux garbage-collects its managed resources, then trigger a git reconcile so Flux recreates them.

## When to Use

- The app is managed by Flux (`Kustomization` under `kubernetes/apps/.../ks.yaml`)
- The app's PVC is populated by a kopiur `Restore` CR (i.e. the kustomization uses `components/kopiur/backup`)
- The user has explicitly asked for a fresh start (storage wiped, app re-initialized, kopiur starts a new backup history)

## When NOT to Use

- App uses StatefulSet-managed volumes without kopiur (use a different reset procedure)
- User wants to keep some data (use a backup-restore flow, not this)
- App is managed by Helm directly (no Flux Kustomization) — different cleanup path
- "I deleted the data by mistake" — that's a restore-from-backup task, not a reset

## Critical Pre-Flight (Read All Before Acting)

### 1. Confirm kopiur-backup topology

```sh
kubectl -n <ns> get kustomization <app>
kubectl -n <ns> get pvc <app> -o jsonpath='{.spec.dataSourceRef}{"\n"}'
# expect: apiGroup: kopiur.home-operations.com, kind: Restore, name: <app>
kubectl -n <ns> get restore.kopiur.home-operations.com <app> -o jsonpath='{.spec.policy.onMissingSnapshot}{"\n"}'
# expect: Continue — required for empty PVC on recreation
kubectl -n <ns> get snapshotpolicy <app> -o jsonpath='{.spec.repository.name}{"\n"}'
# remember the repository — ClusterRepository annotation goes on THIS
```

If the PVC's `dataSourceRef` is not a `Restore`, abort. This skill does not apply.

### 2. Count existing snapshots (expect a non-zero number)

```sh
kubectl -n <ns> get snapshots.kopiur.home-operations.com \
  -o jsonpath='{range .items[?(@.spec.policyRef.name=="<app>")]}{.metadata.name}{"\n"}{end}' | wc -l
```

If zero, the reset is much simpler (no mass-deletion breaker). Skip step 5 below.

### 3. Note the policy's repository (likely `nas`) — needed for step 5

### 4. Confirm kopiur-operator is healthy

```sh
kubectl -n system get pods -l app.kubernetes.io/name=kopiur,app.kubernetes.io/component=controller
```

## Procedure

### Step 1 — Scale the workload to 0

```sh
kubectl -n <ns> scale deployment <app> --replicas=0
kubectl -n <ns> wait deployment <app> --for=jsonpath='{.spec.replicas}'=0 --timeout=60s
kubectl -n <ns> wait pod -l app.kubernetes.io/name=<app> --for=delete --timeout=120s
```

### Step 2 — Stop the snapshot schedule

```sh
kubectl -n <ns> delete snapshotschedules.kopiur.home-operations.com <app> --wait=true
```

If you do NOT delete this, the schedule will fire (every hour for `H * * * *`) while the PVC is being deleted and create a "snapshot of nothing." Deleting it now avoids that. Flux recreates it later.

### Step 3 — Delete the Restore CR

```sh
kubectl -n <ns> delete restores.kopiur.home-operations.com <app> --wait=true
```

This breaks the populator link. Without it, a new PVC created from git would have no source to bind against.

### Step 4 — Delete all Snapshot CRs (the mass-deletion breaker WILL trip)

```sh
kubectl -n <ns> get snapshots.kopiur.home-operations.com \
  -o jsonpath='{range .items[?(@.spec.policyRef.name=="<app>")]}{.metadata.name}{"\n"}{end}' \
  | xargs -r kubectl -n <ns> delete snapshots.kopiur.home-operations.com
```

**Expect this to hang on `Deleting` with finalizers.** Kopiur has a mass-deletion breaker: when ≥10 pending destructive deletions are queued for a single `ClusterRepository`, it holds all of them by default. The status condition on the snapshot will read exactly:

> "this snapshot's deletion is HELD by the mass-deletion breaker: N pending external destructive deletions for ClusterRepository `<repo>` are at/above its threshold of 10. No kopia data has been deleted and this Snapshot keeps its finalizer."

**This is the gotcha that makes the wipe fail.** Without approving the wave, the snapshots never delete, the kopia NAS data never goes away, and the recreated Restore will populate the new PVC from the adopted snapshots.

### Step 5 — Approve the mass-deletion wave

```sh
kubectl annotate clusterrepository/<repo> \
  kopiur.home-operations.com/allow-mass-deletion="$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
  --overwrite
```

Watch the controller logs to confirm the batch Job runs:

```sh
kubectl -n system logs -l app.kubernetes.io/name=kopiur,app.kubernetes.io/component=controller --tail=100 \
  | grep -E 'snapshot deleted by batch Job'
```

Wait until the count of snapshots drops to 0. Re-list:

```sh
kubectl -n <ns> get snapshots.kopiur.home-operations.com \
  -o jsonpath='{range .items[?(@.spec.policyRef.name=="<app>")]}{.metadata.name}{"\n"}{end}' | wc -l
# expect: 0
```

Also verify `kubectl -n <ns> get snapshotpolicy <app> -o jsonpath='{.status.retention.activeSnapshotCount}'` is `0`.

**Clean up the annotation afterwards** (it releases only the current wave, but tidy up):

```sh
kubectl annotate clusterrepository/<repo> kopiur.home-operations.com/allow-mass-deletion-
```

### Step 6 — Delete the Flux Kustomization (lets Flux clean up)

```sh
kubectl -n <ns> delete kustomization <app> --wait=true
```

Wait briefly, then confirm Flux garbage-collected everything:

```sh
kubectl -n <ns> get all,pvc,restores.kopiur,snapshotpolicy,snapshotschedule,helmrelease \
  -l kustomize.toolkit.fluxcd.io/name=<app>
# expect: No resources found
```

### Step 7 — Trigger Flux to recreate everything from git

```sh
flux reconcile source git flux-system
flux reconcile kustomization cluster-apps --with-source
```

The seerr-specific path is one level down — `cluster-apps` reconciles the `media/` parent which reconciles the `<app>` kustomization. Adjust `cluster-apps` if your app lives under a different parent path.

### Step 8 — Verify recreation

```sh
kubectl -n <ns> wait kustomization <app> --for=condition=Ready=True --timeout=120s
kubectl -n <ns> get pvc <app> -o jsonpath='{.status.phase}{"\n"}'   # expect: Bound
kubectl -n <ns> get restores.kopiur.home-operations.com <app> -o jsonpath='{.status.phase}{"\n"}'
# expect: Completed
kubectl -n <ns> get restores.kopiur.home-operations.com <app> \
  -o jsonpath='{.status.conditions[-1:].message}{"\n"}'
# expect contains: "no snapshot found; provisioned an empty volume"
```

If the Restore reports anything else (especially "restored from snapshot"), the wipe failed and you need to investigate why adopted snapshots returned.

### Step 9 — Wait for the app to come up and verify empty storage

The HelmRelease will reconcile replicas back to the chart's default. Wait for the pod:

```sh
kubectl -n <ns> wait pod -l app.kubernetes.io/name=<app> --for=condition=Ready --timeout=180s
POD=$(kubectl -n <ns> get pod -l app.kubernetes.io/name=<app> -o jsonpath='{.items[0].metadata.name}')
kubectl -n <ns> exec $POD -- ls -la /<mount-path>     # check the PVC mount
kubectl -n <ns> exec $POD -- stat -c '%y' /<mount-path>/settings.json 2>&1 || true
# expect: timestamps within the last few minutes (first-run init)
```

App-specific verification: most apps have a public endpoint that returns an "initialized: false" or empty-data flag on fresh install. Hit it.

## Verification Checklist

- [ ] Kustomization Ready
- [ ] PVC Bound
- [ ] Restore phase `Completed` with message containing "no snapshot found"
- [ ] SnapshotPolicy activeSnapshotCount = 0
- [ ] Deployment ready replicas = 1 (chart default)
- [ ] Pod Ready, first-run init timestamps in PVC mount
- [ ] App's public-API health endpoint reports fresh-install state

## Common Mistakes / Rationalizations

| Excuse | Reality |
|--------|---------|
| "Approval was implicit — they said reset last week" | Past approvals do not transfer. Re-confirm. |
| "Just `kubectl apply` the rendered manifests to recreate faster" | Forbidden. The cluster is Flux-managed. Delete the Kustomization and reconcile — Flux recreates everything within seconds anyway. |
| "The mass-deletion breaker will release on its own" | It will not. Approve the wave via the ClusterRepository annotation. |
| "Skip step 2 — schedule's `concurrencyPolicy: Forbid` will prevent overlap" | Concurrency doesn't help when the next scheduled run creates a fresh snapshot of the empty PVC, which gets retained by the policy and blocks the new Restore. |
| "I'll only delete the Snapshot CRs — that's enough, kopia retains are separate" | Deleting the Snapshot CRs alone does NOT delete the kopia NAS data. Kopiur will re-adopt the underlying snapshots as new Snapshot CRs and the recreated Restore will populate the PVC from them. |
| "Per-snapshot `skip-snapshot-cleanup` annotation is safer" | It removes the finalizer without deleting the kopia data, which leaves adoption candidates that the recreated Restore can still pick up. Use only when you intentionally want to preserve kopia history. |
| "Scale-down is optional — kubelet will reap the pod when PVC dies" | The pod will fail with `VolumeFailure` and crash-loop; visible alerts and wasted reconcile cycles. Scale down first. |
| "Force `flux reconcile` repeatedly to speed up" | One source reconcile + one kustomization reconcile is enough. Repeated calls just queue work. |

## Red Flags — STOP and Reassess

- Approval mentions a different app than the one being modified
- Approval says "do what you did last time" without naming the app
- `kubectl apply` of any resource whose manifest lives in this repo
- Deleting the SnapshotPolicy or PVC *before* deleting the SnapshotSchedule
- Force-reconciling a Kustomization whose interval hasn't elapsed, when a normal reconcile would suffice
- Seerr/media/media — `kubectl delete` of `clusterrepository/nas` (wipes ALL backups for the cluster)

## Related Skills

- `add-app` — scaffolding a new kopiur-backed app from scratch (the inverse direction)
- `.agents/instructions/gitops.instructions.md` — the gitops rule this skill depends on
