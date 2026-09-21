# BMC Certificate Updater — SuperMicro — Design

- **Date:** 2026-09-15
- **Status:** Implemented and verified — LE cert active on kvm-homeassistant.internal.greyrock.io (subject CN=*.internal.greyrock.io, issuer Let's Encrypt), daily CronJob will keep it that way
- **Scope:** Flux-managed CronJob that pushes the `*.internal.greyrock.io` Let's Encrypt certificate to one SuperMicro IPMI BMC (`kvm-homeassistant.internal.greyrock.io`, 10.1.20.14).

## Goal

Replace the BMC's self-signed cert with the cluster's existing `*.internal.greyrock.io` LE cert, on rotation, with no manual touch and no risk of bricking.

## Non-goals

- No new Certificate or ClusterIssuer (reuse what's already in `network` ns).
- No Redfish attempt — the older MegaRAC firmware 03.95 vendor cert upload flow via `/cgi/*` is reliable across generations; Redfish `CertificateService.ReplaceCertificate` is inconsistent at this vintage.
- No DNS or CNP changes for other apps.

## Architecture

A second Flux app `kubernetes/apps/network/bmc-cert-updater-supermicro/` parallel to `bmc-cert-updater-asrock`. Same `network` namespace, same upstream cert secret, separate runbook and CNP for fault isolation. The cert Secret `internal-greyrock-io-tls` (in `network` ns, owned by the `internal-greyrock-io-cert` Kustomization since #215) is mounted read-only. The 1Password item `Cert Updater` is the same; this app's ExternalSecret slices out the fields it needs.

## Components

- `ks.yaml` — `targetNamespace: network`; `dependsOn: [{name: cert-manager, namespace: cert-manager}, {name: external-secrets, namespace: external-secrets}]` (explicit `namespace:` for cross-namespace deps, lesson from `b27e7dcffe`)
- `app/ocirepository.yaml` — `oci://ghcr.io/bjw-s-labs/helm/app-template` tag `5.1.0`
- `app/externalsecret.yaml` — ClusterSecretStore `onepassword-connect`, item `Cert Updater`, target `bmc-cert-supermicro-secret`: `UPDATER_USERNAME` ← `updater-username`, `HOMEASSISTANT_PASSWORD` ← `homeassistant-password`
- `app/kustomization.yaml` — resources + `configMapGenerator` over `config/push-certs-supermicro.sh` with `disableNameSuffixHash: true`
- `app/helmrelease.yaml` — app-template cronjob `@daily`, `backoffLimit: 0`, `concurrencyPolicy: Forbid`, `failedJobsHistory: 1`, `successfulJobsHistory: 1`, `ttlSecondsAfterFinished: 86400`, image `curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777`, `envFrom: bmc-cert-supermicro-secret`, persistence: `internal-greyrock-io-tls` at `/certs` + script + `/tmp`
- `app/ciliumnetworkpolicy.yaml` — egress to `10.1.20.14/32` TCP 443 only (DNS cluster-wide via `allow-dns-egress` CCNP)
- `app/config/push-certs-supermicro.sh` — POSIX sh, `--self-test` mode

## Script flow (MegaRAC IPMI 03.95)

1. `POST /cgi/login.cgi` form-encoded `name=$UPDATER_USERNAME&pwd=$HOMEASSISTANT_PASSWORD` → save `Set-Cookie` to jar
2. `GET /cgi/url_redirect.cgi?url_name=ssl_cert_upload` (or whichever the firmware exposes — verified in Task 1) with cookie → parse `_csrf_token` from hidden form field
3. `curl %{certs}` against `https://kvm-homeassistant.internal.greyrock.io` → extract leaf; compare to `/certs/tls.crt` leaf (with `tr -d '\r'`)
4. Skip upload if leaves match; else `POST /cgi/upload_ssl.cgi` multipart `cert_file=@/certs/tls.crt`, `key_file=@/certs/tls.key`, `_csrf_token=$csrf` with the session cookie
5. Retry served-leaf comparison with `sleep 5 × 6` (the BMC web server restarts after upload); exit 0 only on match

## Failure / recovery

- Web server restart after cert load is expected — verify-only retry loop
- Brick (firmware-level, rare): `ipmitool mc reset cold` over LAN from any host

## Verification (plan Task 6)

- Mac-side end-to-end run with creds from `bmc-cert-supermicro-secret`, mirroring the pod logic
- Manual first CronJob run + browser check at `https://kvm-homeassistant.internal.greyrock.io`
- Second run logs "certificate unchanged, skipping"

## Open items

- Exact `url_name=...` parameter for the cert-upload page and the actual form-field name the firmware uses for the CSRF will be confirmed against this specific BMC in plan Task 1.
