# Restoring from the Cloudflare R2 offsite copy

Use this when TrueNAS (`codswallop`) and its S3 data are gone, with or without the
cluster. If only the cluster is lost and TrueNAS S3 is intact, skip to
[Bootstrap the cluster](#3-bootstrap-the-cluster).

## What is where

Everything that matters is backed up to TrueNAS S3 (`https://s3.greyrock.io`,
Traefik on `codswallop` → `10.1.20.12:9000`) and mirrored nightly to R2:

| TrueNAS bucket | R2 bucket                 | Contents                                                      | Mirrored by                                             |
| -------------- | ------------------------- | ------------------------------------------------------------- | ------------------------------------------------------- |
| `kopiur`       | `home-ops-kopiur-backups` | Kopia repository with every app PVC (`ClusterRepository/nas`) | `RepositoryReplication/r2`, 05:00 America/New_York      |
| `cnpg`         | `home-ops-cnpg-backups`   | CloudNativePG base backups + WAL, one prefix per cluster      | `CronJob/offsite-sync` (rclone), 04:00 America/New_York |
| `kanidm`       | `home-ops-kanidm-backups` | Encrypted Kanidm backups (`sso/`)                             | `CronJob/offsite-sync` (rclone), 04:00 America/New_York |

Both mirrors live in `system`: `kubernetes/apps/system/kopiur/repository/` and
`kubernetes/apps/system/offsite-sync/`. The R2 copy can lag TrueNAS by up to a
day.

Not backed up anywhere: `kritika-postgres` (deliberately), and the regenerable
cache volumes (`plex-cache`, `jellyfin-metadata`, `radarr-cache`,
`sabnzbd-cache`), which rebuild themselves.

### Secrets you need (1Password, `Kubernetes` vault)

| Item                      | Fields                                           | Used for                        |
| ------------------------- | ------------------------------------------------ | ------------------------------- |
| `Cloudflare R2 - Backups` | `access_key_id`, `secret_access_key`, `endpoint` | Reading the R2 buckets          |
| `Kopiur`                  | `repository_password`                            | Decrypting the Kopia repository |
| `Kanidm`                  | `backup_encryption_key`                          | Decrypting Kanidm backups       |
| `TrueNAS S3 - Kopiur`     | `username`, `password`                           | S3 keys for the `kopiur` bucket |
| `TrueNAS S3 - CNPG`       | `username`, `password`                           | S3 keys for the `cnpg` bucket   |
| `TrueNAS S3 - kanidm`     | `username`, `password`                           | S3 keys for the `kanidm` bucket |

The R2 token is scoped to the three `home-ops-*` buckets with Object Read &
Write. R2 storage is Standard class, so restores have no retrieval fee and no
egress charge.

## ⚠️ Read before starting: don't let the mirrors run against an empty TrueNAS

`offsite-sync` runs `rclone sync` **from** TrueNAS **to** R2. If the cluster is
running while the TrueNAS buckets are empty, the 04:00 run deletes R2 objects
to match, up to its `--max-delete 2000` cap per bucket. That is most of the CNPG
backups. The Kopia replication fails safely instead, since it can't open an empty
source repository, but don't rely on it.

So: **put the data back into TrueNAS before the cluster comes up**. If the
cluster is already running, suspend both mirrors first:

```sh
flux -n system suspend kustomization offsite-sync
flux -n system suspend kustomization kopiur-repository
kubectl -n system patch cronjob offsite-sync --type merge -p '{"spec":{"suspend":true}}'
kubectl -n system patch repositoryreplication r2 --type merge -p '{"spec":{"suspend":true}}'
```

Resume them (`flux resume ...`, which also reverts the two patches) only after
step 2 is verified.

## 1. Rebuild TrueNAS S3

1. Bring the S3 service back on `codswallop` so `https://s3.greyrock.io` answers
   (Traefik route: `docker/codswallop/02-traefik/docker-compose.yaml`).
2. Create the buckets `kopiur`, `cnpg` and `kanidm`.
3. Create one access key per bucket and store them in the three
   `TrueNAS S3 - *` items (`username` = access key, `password` = secret key),
   replacing the old values if they changed.

## 2. Copy R2 back into TrueNAS

Run from the Mac in bash or zsh, not fish (rclone via mise; secrets come from `op-sa`, nothing is printed):

```sh
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$(op-sa read 'op://Kubernetes/Cloudflare R2 - Backups/access_key_id')"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$(op-sa read 'op://Kubernetes/Cloudflare R2 - Backups/secret_access_key')"
export RCLONE_CONFIG_R2_ENDPOINT="$(op-sa read 'op://Kubernetes/Cloudflare R2 - Backups/endpoint')"

for pair in "Kopiur:kopiur:home-ops-kopiur-backups" "CNPG:cnpg:home-ops-cnpg-backups" "kanidm:kanidm:home-ops-kanidm-backups"; do
  item="TrueNAS S3 - $(echo "$pair" | cut -d: -f1)"; bucket=$(echo "$pair" | cut -d: -f2); r2=$(echo "$pair" | cut -d: -f3)
  RCLONE_CONFIG_T_TYPE=s3 RCLONE_CONFIG_T_PROVIDER=Other RCLONE_CONFIG_T_ENDPOINT=https://s3.greyrock.io RCLONE_CONFIG_T_FORCE_PATH_STYLE=true \
  RCLONE_CONFIG_T_ACCESS_KEY_ID="$(op-sa read "op://Kubernetes/$item/username")" \
  RCLONE_CONFIG_T_SECRET_ACCESS_KEY="$(op-sa read "op://Kubernetes/$item/password")" \
    mise x rclone@1.76.0 -- rclone copy "r2:$r2" "t:$bucket" --fast-list --transfers 8 --progress
done
```

`copy` never deletes, so re-running it after an interruption is safe. Expect
about 18 GB in total (Kopiur is most of it).

Verify that each pair matches with `rclone size r2:<r2-bucket> --fast-list` and
`rclone size t:<bucket> --fast-list`, using the same environment.

## 3. Bootstrap the cluster

```sh
just k8s-bootstrap cluster
```

Flux then brings the apps up, and the data restores itself as each one is
created:

- **App volumes (Kopiur):** every app using `components/kopiur/backup` creates
  its PVC with `dataSourceRef: Restore/<app>`, which populates it from the
  newest snapshot of `SnapshotPolicy/<app>`. `onMissingSnapshot: Continue`
  means **an app whose snapshot can't be found starts with an empty volume**.
  That's another reason step 2 has to finish first.
- **Postgres (CNPG):** every cluster from `components/cnpg/pg18` has a permanent
  `bootstrap.recovery` stanza. A newly created cluster restores the latest base
  backup and replays WAL from its `<app>-postgres-pg18` prefix in `cnpg`, then
  carries on archiving to the same prefix. Don't use `initdb` or
  `just k8s seed-cnpg` here: those are for clusters that have no backups yet.

Watch for apps that came up empty:

```sh
kubectl get restores.kopiur.home-operations.com -A
kubectl get clusters.postgresql.cnpg.io -A
```

## 4. Restore Kanidm

Kanidm restores with an explicit `KanidmRestore`. Once `Kanidm/sso` is running
again:

1. Let kaniop rediscover the backups. `KanidmBackupSchedule/sso` scans the
   `kanidm` bucket and recreates `KanidmBackup` objects, labelled
   `kaniop.rs/discovered: "true"`:

   ```sh
   kubectl -n security get kanidmbackups --sort-by=.spec.backupId
   kubectl -n security get kanidmbackupschedule sso -o jsonpath='{.status.discovery.conditions[0].message}{"\n"}'
   ```

   Backups are stored under the **old** Kanidm UID
   (`sso/v1/tenants/security/clusters/<old-uid>/backups/<id>/`). Discovery for a
   rebuilt instance with a new UID hasn't been tested. If nothing shows up,
   create a `KanidmBackup` by hand with the `backupId` and `manifestKey`
   (`sso/v1/.../backups/<id>/manifest.json`) of the newest backup, taken from
   the bucket listing.

2. Restore the newest backup into the running instance:

   ```yaml
   apiVersion: kaniop.rs/v1beta1
   kind: KanidmRestore
   metadata:
     name: sso-restore
     namespace: security
   spec:
     restoreImage: kanidm/server:1.12.1 # same version as Kanidm/sso spec.image
     source:
       backupRef:
         name: <newest KanidmBackup name>
     targetRef:
       name: sso
       uid: <kubectl -n security get kanidm sso -o jsonpath='{.metadata.uid}'>
     safetyBackup:
       skip: true # nothing worth keeping in a freshly bootstrapped instance
   ```

## 5. Resume the mirrors and verify

1. Resume anything suspended above.
2. Trigger a replication run instead of waiting for 05:00, and check it:

   ```sh
   kubectl -n system annotate repositoryreplication r2 kopiur.home-operations.com/run-requested="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
   kubectl -n system get repositoryreplication r2 -o jsonpath='{.status.manualRun}{"\n"}'
   ```

3. Optionally, prove the R2 Kopia copy opens independently of the cluster:

   ```sh
   D=$(mktemp -d); export KOPIA_CONFIG_PATH=$D/r2.config KOPIA_CACHE_DIRECTORY=$D/cache KOPIA_LOG_DIR=$D/logs
   export KOPIA_PASSWORD="$(op-sa read 'op://Kubernetes/Kopiur/repository_password')"
   mise x kopia@latest -- kopia repository connect s3 --readonly --bucket home-ops-kopiur-backups --region auto \
     --endpoint "$(op-sa read 'op://Kubernetes/Cloudflare R2 - Backups/endpoint' | sed 's#https://##')" \
     --access-key "$(op-sa read 'op://Kubernetes/Cloudflare R2 - Backups/access_key_id')" \
     --secret-access-key "$(op-sa read 'op://Kubernetes/Cloudflare R2 - Backups/secret_access_key')"
   mise x kopia@latest -- kopia snapshot list --all
   rm -rf "$D"
   ```

## If TrueNAS can't be rebuilt for a while

You can run the cluster directly against R2, but it touches several manifests
and new backups then land only in R2:

- `kubernetes/apps/system/kopiur/repository/clusterrepository.yaml`: set the
  backend to the R2 endpoint, bucket `home-ops-kopiur-backups`, `region: auto`,
  and `secretRef: kopiur-r2-secret`.
- `kubernetes/components/cnpg/base/`: set `CNPG_ENDPOINT` and `CNPG_BUCKET`
  (per app in `ks.yaml` or as component defaults), and point the objectstore
  ExternalSecret at `Cloudflare R2 - Backups` (`access_key_id` /
  `secret_access_key` instead of `username` / `password`).
- `kubernetes/apps/security/kanidm-operator/instance/backup-repository.yaml`:
  set the endpoint, bucket and credentials to R2.
- Suspend `offsite-sync` and `RepositoryReplication/r2`, because source and
  destination would be the same.

Once TrueNAS is back, copy R2 into it (step 2) and revert those changes.
