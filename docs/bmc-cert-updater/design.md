# BMC Certificate Updater — Design

- **Date:** 2026-09-15
- **Status:** Approved design, pending implementation plan
- **Scope:** Flux-managed automation that keeps a valid Let's Encrypt certificate on the
  BMC web UIs of both ASRock Rack X570D4U-2L2T boards

## Goal

Both X570D4U-2L2T boards (AST2500 BMC, AMI LTS 12.3-era firmware) currently serve
self-signed certificates on their BMC web UIs. This automation issues a
`*.internal.greyrock.io` certificate via cert-manager and pushes it to both BMCs on a
schedule, uploading only when the certificate changes.

## Targets

| Board (host) | BMC URL | BMC IP |
|---|---|---|
| codswallop (TrueNAS NAS) | `https://kvm-codswallop.internal.greyrock.io` | 10.1.20.13 |
| kerfuffle (Talos controlplane host) | `https://kvm-kerfuffle.internal.greyrock.io` | 10.1.20.11 |

The hostnames already resolve (Unifi DNS) to the BMC IPs and are covered by the
`*.internal.greyrock.io` wildcard SAN. No DNS records are created by this work.

## Non-goals

- No new DNS records, monitoring probes, or alerting (failed Jobs are visible via kubectl)
- No changes to the existing `letsencrypt-production` (shortlived/ECDSA) issuer or the
  `greyrock-io` wildcard cert
- No IPMI/fan-control changes (coolercontrol's BMC access is untouched)

## Why a second ClusterIssuer

The existing `letsencrypt-production` uses LE's `shortlived` profile (6-day certs).
The X570D4U BMC firmware has no documented ECDSA support and a failed/malformed upload
can wedge the BMC web UI until a BMC reset (verified by community reports on this exact
board). A classic-profile RSA 2048 cert (90 days) is maximally compatible with the
firmware and cuts upload churn from ~every 2-3 days to ~monthly.

## Components

### 1. ClusterIssuer `letsencrypt-production-classic`

Appended to `kubernetes/apps/cert-manager/cert-manager/app/clusterissuer.yaml`:

- Byte-copy of `letsencrypt-production` minus the `profile:` line (LE `classic` profile
  is the default → 90-day certs, RSA allowed)
- Same `email: acme@greyrock.io`, same ClouDNS dns01 webhook solver
  (`groupName: acme.ixon.cloud`, `solverName: cloudns`)
- `privateKeySecretRef.name: letsencrypt-production-classic`

DNS-01 validation writes a `_acme-challenge.internal.greyrock.io` TXT record into the
public ClouDNS zone — normal for DNS-01; exposes no host IPs.

### 2. Certificate `internal-greyrock-io`

`kubernetes/apps/network/bmc-cert-updater/app/certificate.yaml`:

- `dnsNames: ["*.internal.greyrock.io"]`
- `issuerRef: ClusterIssuer/letsencrypt-production-classic`
- `privateKey: algorithm RSA, size 2048, rotationPolicy: Always`
- `secretName: internal-greyrock-io-tls` (in the `network` namespace)

### 3. ExternalSecret `bmc-cert-updater`

Follows the house pattern (`refreshInterval: 12h`, ClusterSecretStore
`onepassword-connect`, `creationPolicy: Owner`), targeting Secret
`bmc-cert-updater-secret` from a single 1Password item **`BMC Certs`** (must live in one
of the ClusterSecretStore vaults: Kubernetes / Automation / Services):

| secretKey (env var name) | 1Password item | property (field) |
|---|---|---|
| `UPDATER_USERNAME` | BMC Certs | `updater-username` |
| `CODSWALLOP_PASSWORD` | BMC Certs | `codswallop-password` |
| `KERFUFFLE_PASSWORD` | BMC Certs | `kerfuffle-password` |

Note: the 1Password field names keep their hyphens; the Secret keys use underscores
because `envFrom` requires valid environment-variable names. A single shared
`updater` admin account is used on both BMCs, with a per-BMC password.

### 4. App `bmc-cert-updater` (app-template CronJob)

Directory layout `kubernetes/apps/network/bmc-cert-updater/` mirrors the
recyclarr/towonel-agent convention:

```
ks.yaml                     # targetNamespace: network; dependsOn: [cert-manager, external-secrets]
app/certificate.yaml
app/ciliumnetworkpolicy.yaml
app/config/push-certs.sh    # push script (configMapGenerator -> ConfigMap bmc-cert-updater)
app/externalsecret.yaml
app/helmrelease.yaml
app/kustomization.yaml
app/ocirepository.yaml      # oci://ghcr.io/bjw-s-labs/helm/app-template (tag per current convention)
```

HelmRelease values:

- Controller `type: cronjob`, `schedule: "@daily"`, `backoffLimit: 0`,
  `concurrencyPolicy: Forbid`, `failedJobsHistory: 1`, `successfulJobsHistory: 0`
- Container image `curlimages/curl` pinned `tag@sha256` (repo image-pinning convention;
  Renovate keeps the digest fresh)
- Pod hardening like recyclarr, adjusted for the curl image user (uid/gid 100,
  `runAsNonRoot`, `readOnlyRootFilesystem`, drop ALL capabilities, no privilege
  escalation)
- Pod label `egress.policy.home.arpa/block-all` (same least-privilege pattern as
  plex-image-cleanup)
- Persistence: `certs` (type secret, `internal-greyrock-io-tls`, mounted at `/certs`),
  `script` (type configMap, mounted at `/script`), `tmp` (emptyDir — cookie jar)
- `envFrom: secretRef: bmc-cert-updater-secret`

### 5. CiliumNetworkPolicy

Egress-only, selecting the app pods:

1. `toEndpoints` kube-dns (`kube-system`, `k8s-app: kube-dns`), UDP+TCP 53 — the script
   resolves the two BMC hostnames
2. `toCIDR` `10.1.20.13/32` and `10.1.20.11/32`, TCP 443

## Push script behavior

Runs per BMC (codswallop, then kerfuffle; a failure on the first does not stop the
second — both are attempted, and the job exits non-zero if either failed). Mechanism is
the community-verified ASRock Rack web API for X570D4U-2L2T (AST2500):

1. **Login:** `POST /api/session` with form-encoded
   `username=$UPDATER_USERNAME&password=$<per-BMC password>`. Response JSON contains
   `CSRFToken`; extract with sed (no jq in the curl image). Session cookies kept in an
   emptyDir cookie jar.
2. **Compare (skip-if-unchanged):** fetch the currently served certificate with
   `curl -k -o /dev/null -w '%{certs}'` (curl ≥ 7.88; current curlimages/curl is 8.x).
   Extract the leaf PEM block from both the served output and `/certs/tls.crt` (first
   `BEGIN CERTIFICATE`…`END CERTIFICATE` block) and compare byte-for-byte after
   stripping `\r`. Identical → log "unchanged, skipping" and move on. This is the
   primary mitigation against the upload brick risk: the write endpoint is only touched
   when the certificate actually changed (~monthly).
3. **Upload:** `POST /api/settings/ssl/certificate` with header `X-CSRFTOKEN: $token`,
   multipart `new_certificate=@/certs/tls.crt` (fullchain) and
   `new_private_key=@/certs/tls.key`.
4. **Verify:** re-fetch the served leaf and compare against the desired leaf; mismatch
   (or any HTTP/login failure) → log and mark the run failed.

All interactions use `curl -k` (the BMC serves a self-signed/expired cert until the
first successful push). No openssl/jq dependency — string handling only.

## Prerequisites (user actions, one-time)

- Dedicated `updater` admin account exists on **both** BMC web UIs: same username,
  per-BMC passwords, matching the `BMC Certs` 1Password item exactly
- BMC firmware: both boards on a reasonably current X570D4U-2L2T BMC firmware (any
  version exposing the `/api/` web endpoints; current firmware family is fine)

## Failure modes and runbook

| Failure | Detection | Recovery |
|---|---|---|
| Upload wedges BMC web UI (known X570D4U-2L2T firmware bug) | Web UI unreachable after a push | `ipmitool mc reset cold` — local on codswallop (fan duty reverts until CoolerControl re-applies it; expect a brief fan ramp), over-LAN from codswallop for kerfuffle |
| Login failure (locked account / password drift) | Job fails at login step | Fix the account or the `BMC Certs` item; ExternalSecret refreshes within 12h |
| Cert Secret missing / not yet issued | Pod mount or file check fails | `dependsOn` ordering makes this a first-rollout edge only; next run self-heals |
| BMC unreachable | curl timeout, job fails | Investigate BMC/network manually |

Mitigations baked in: upload only on change, always upload a freshly-issued
fullchain+key pair, verify after upload, and `backoffLimit: 0` so a wedged BMC never
receives automatic rapid retries.

## Verification plan

1. Rollout via Flux (commit triggers webhook reconcile; no manual `flux reconcile`)
2. Manual first-run gate: `kubectl create job -n network bmc-cert-updater-manual
   --from=cronjob/bmc-cert-updater` (a one-off Job creation, not a Flux reconcile)
3. In a browser: both BMC UIs show a valid Let's Encrypt cert, SAN
   `*.internal.greyrock.io`, correct dates, no warnings
4. Trigger a second manual run — both BMCs log "unchanged, skipping" (proves the
   compare logic works)
5. Repo lint/CI passes (`.forgejo` lint workflow, image digest validation)

## Open items for implementation

- Pin the current `curlimages/curl` tag+digest at implementation time
- Confirm the current app-template chart tag to pin (match recyclarr's
  `ocirepository.yaml` convention)
