# BMC Certificate Updater — SuperMicro — Design

- **Status:** Implemented and verified on both BMCs (subject `CN=*.internal.greyrock.io`, issuer Let's Encrypt); the daily CronJob keeps them current.
- **Scope:** Flux-managed CronJob that pushes the `*.internal.greyrock.io` Let's Encrypt certificate to the SuperMicro IPMI BMCs:

| Name | Host | Address | Board | BMC firmware |
|---|---|---|---|---|
| `homeassistant` | `kvm-homeassistant.internal.greyrock.io` | 10.1.20.14 | A2SDV-16C-TLN5F | 04.07 |
| `gallivant` | `kvm-gallivant.internal.greyrock.io` | 10.1.20.21 | A2SDi-4C-HLN4F | 04.07 |

## Goal

Replace each BMC's self-signed cert with the cluster's existing `*.internal.greyrock.io` LE cert, on rotation, with no manual touch and no risk of bricking.

## Non-goals

- No new Certificate or ClusterIssuer (reuse what's already in `network` ns).
- No Redfish — the vendor cert upload flow via `/cgi/*` is what the web UI itself uses on this firmware.
- No DNS or CNP changes for other apps.

## Architecture

A Flux app `kubernetes/apps/network/bmc-cert-updater-supermicro/` parallel to `bmc-cert-updater-asrock`. Same `network` namespace, same upstream cert secret, separate script and network policy for fault isolation. The cert Secret `internal-greyrock-io-tls` (owned by the `internal-greyrock-io-cert` Kustomization) is mounted read-only. The 1Password item `Cert Updater` is shared with the other cert updaters; this app slices out the fields it needs.

## Components

- `ks.yaml` — `targetNamespace: network`; `dependsOn` `cert-manager` and `external-secrets` (with explicit `namespace:` for the cross-namespace deps) and `internal-greyrock-io-cert`
- `app/ocirepository.yaml` — `oci://ghcr.io/bjw-s-labs/helm/app-template`
- `app/kustomization.yaml` — resources + `configMapGenerator` over `config/push-certs-supermicro.sh` with `disableNameSuffixHash: true`
- `app/helmrelease.yaml` — app-template:
  - `externalSecrets` from ClusterSecretStore `onepassword-connect`, item `Cert Updater`: `UPDATER_USERNAME` ← `updater-username`, `HOMEASSISTANT_PASSWORD` ← `homeassistant-password`, `GALLIVANT_PASSWORD` ← `gallivant-password`
  - Cilium `networkpolicies` egress to `10.1.20.14/32` and `10.1.20.21/32` TCP 443 only (DNS cluster-wide via `allow-dns-egress`); pod carries `egress.policy.home.arpa/block-all: "true"`
  - cronjob `@daily`, `backoffLimit: 0`, `concurrencyPolicy: Forbid`, image `docker.io/curlimages/curl`, persistence: `internal-greyrock-io-tls` at `/certs`, script, `/tmp`
- `app/config/push-certs-supermicro.sh` — POSIX sh, iterates `TARGETS` (`name|host` pairs), `--self-test` mode

## Script flow (per BMC, firmware 04.07)

1. `POST /cgi/login.cgi` form-encoded `name=$UPDATER_USERNAME&pwd=<name>_PASSWORD` (raw, not base64), retried 5× with backoff → session cookie jar
2. Append the `langSetFlag=0` / `language=English` cookies; without them the cert page returns a language-loader stub
3. `GET /cgi/url_redirect.cgi?url_name=config_ssl` → CSRF token from `SmcCsrfInsert ("CSRF_TOKEN", "...")`
4. `curl %{certs}` against the BMC → leaf; compare to the `/certs/tls.crt` leaf (`tr -d '\r'`). Match → log out, "certificate unchanged, skipping"
5. `POST /cgi/upload_ssl.cgi` multipart `cert_file`, `key_file`, `CSRF_TOKEN` (also sent as a header, with matching `Origin`/`Referer`). This only stages the files
6. `POST /cgi/ipmi.cgi` `SSL_VALIDATE.XML=(0,0)` with the fresh CSRF token from the upload response page. The BMC installs the staged cert only on this call and answers `VALIDATE="1"`; anything else fails the run. Without it, the reset comes back on the old cert
7. `POST /cgi/BMCReset.cgi` — the BMC web server does not reload the cert on its own. Log out before the restart; each login holds a session slot until idle timeout
8. Poll the served leaf (`sleep 5 × 12`); exit 0 only on match

## Failure / recovery

- BMC restart after the reset is expected; the verify loop covers it
- Brick (firmware-level, rare): `ipmitool mc reset cold` from the host OS or over LAN

## Verification

- Run the script from a throwaway pod in `network` using the app's own secret and the mounted cert; expect "certificate updated and verified" per BMC, then `openssl s_client` shows the LE leaf
- A second run logs "certificate unchanged, skipping"
