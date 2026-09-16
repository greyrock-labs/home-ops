# WiFi Certificate Updater — Ruckus Unleashed — Design

- **Date:** 2026-09-16
- **Status:** Implemented and verified — full push exercised end to end against the live
  controller (2m50s), which now serves `CN=*.internal.greyrock.io` with a complete
  3-certificate chain that validates without `-k`; a second run reports "nothing to do"
  in under a second without rebooting
- **Scope:** Flux-managed CronJob that pushes the `*.internal.greyrock.io` certificate to
  the Ruckus Unleashed controller (`unleashed.internal.greyrock.io`, 10.1.20.2)

## Goal

Replace a manual certificate upload every renewal with an automated push, on a schedule
that keeps the resulting outage out of waking hours.

## Non-goals

- No new Certificate or ClusterIssuer — reuse the shared `internal-greyrock-io-tls`
  secret (owned by the `internal-greyrock-io-cert` Kustomization, #215)
- No separate intermediate import — measurement showed it is unnecessary (see below)
- No ECC support — the shared certificate is RSA 2048

## Reference implementation

`acme.sh`'s `deploy/ruckus.sh` hook (Tony Rielly, 2024). The overall flow is correct, but
two of its details do not hold on this firmware; both are called out below.

## Architecture

`kubernetes/apps/network/wifi-cert-updater-ruckus/`, mirroring the BMC and printer
updaters. No initContainer — the controller takes PEM directly.

```
ks.yaml                     # targetNamespace: network
                            # dependsOn: [cert-manager, external-secrets, internal-greyrock-io-cert]
app/ciliumnetworkpolicy.yaml
app/config/push-certs.sh
app/externalsecret.yaml
app/helmrelease.yaml
app/kustomization.yaml
app/ocirepository.yaml
```

## Components

- `app/externalsecret.yaml` — item `BMC Certs` → Secret `wifi-cert-updater-ruckus-secret`:
  `UPDATER_USERNAME` ← `updater-username` (shared `certupdater` account),
  `RUCKUS_PASSWORD` ← `ruckus-password`
- `app/helmrelease.yaml` — app-template cronjob, `schedule: "0 3 * * *"`,
  `backoffLimit: 0`, `concurrencyPolicy: Forbid`, `ttlSecondsAfterFinished: 86400`,
  `env: RUCKUS_HOST`
- `app/ciliumnetworkpolicy.yaml` — egress `10.1.20.2/32` TCP 443 only; DNS comes from the
  cluster-wide `allow-dns-egress` policy

**Schedule rationale:** applying a certificate reboots the controller and restarts the
whole wireless network. The job uploads only when the served leaf differs — in practice
once per renewal, not once a day — and 03:00 keeps that outage overnight. The cluster
nodes are wired, so the job survives the outage it causes and can verify its own work.

The `certupdater` account must hold the `rw` privilege; the web UI gates the entire
certificate page on `window.privilege == "rw"`.

## Script flow

1. Compare the controller's served leaf against `/certs/tls.crt`; identical → exit
2. `GET /` → `Location` header gives the login URL (`/admin/login.jsp`)
3. Login POST — **302 to `dashboard.jsp` is success, 200 means bad credentials**
4. Read the CSRF token from the `HTTP_X_CSRF_TOKEN` response header
5. Upload fullchain (`uploadcert`) and key (`uploadprivatekey`) to `_upload.jsp`
6. `replace-cert` via `_cmdstat.jsp` with `cn=$RUCKUS_HOST`
7. `cert-reboot` via `_cmdstat.jsp`
8. Poll the served leaf until the controller returns with the new certificate
   (up to 10 minutes; connection failures during the restart are expected)

## Firmware behaviour worth knowing

Controller under test: **Unleashed 200.19.7.112 build 238**, model R770.

| Behaviour | Consequence |
|---|---|
| Each upload is validated against what is **already staged**, not against the file being sent. | The reference's cert-then-key order reports `E_CertNotMatchPKey` on a first run even when both files are good. Only the **second** upload's `msg` describes the pair, so only that one is trusted. A script that failed on the first message would break on every fresh controller. |
| Login success is a 302; the body looks normal either way. | Status must be checked, not content. |
| The CSRF token arrives as `HTTP_X_CSRF_TOKEN` (literal header name, value space-padded) but must be sent back as `X-CSRF-Token`. | Asymmetric naming; easy to mirror wrongly. |
| `replace-cert` installs the intermediates from the uploaded fullchain. | **No separate intermediate import is needed.** Verified by measurement: the controller serves a 3-certificate chain that validates without `-k`. The UI's `uploadintermediate` / `replace-intermediate` path exists but is not required here. |
| `replace-cert` takes effect immediately; only serving waits for the reboot. | Confirmed because an intermediate upload flips from `E_CertNotMatchIC` to `I_LoadICOptions` straight after `replace-cert` — which also proves the account has `rw`. |
| The ECC-support version check in the reference is unreachable here. | The key is RSA 2048, and 200.19 is far past the 200.13 ECC threshold. Dropped rather than ported. |

For a wildcard certificate the web UI composes the common name as
`redirCn + wildcardDN` — for us `unleashed.internal.greyrock.io` — which matches the
reference's `cn="$RUCKUS_HOST"`. The upload reports the detected wildcard back as
`I_LoadCertOptions::I_CertWildcardCert::.internal.greyrock.io`.

## Two bugs the self-test caught

Both would have failed silently, and are covered by fixtures now:

- The `EXIT` trap ended on `[ -n "$WORK" ] && rm -rf "$WORK"`, which is false when
  `WORK` is empty — and that status became the script's exit status. Every **successful**
  run would have exited 1 and reported the job as failed.
- `served_leaf` piped curl into `awk | tr`, so the pipeline took its status from `tr` and
  returned **success with empty output** when curl could not connect. That empty string
  compares unequal to the desired certificate, so a transient blip at 03:00 would have
  been read as "the certificate changed" and rebooted the entire wireless network for
  nothing. The curl call is now kept out of the pipeline, and a fixture asserts that an
  unreachable host fails rather than returning empty.

## Read-only endpoints useful for diagnosis

- `_savezdcert.jsp` — installed certificate (`certificate.bak`, proprietary/encrypted)
- `_savezdCA.jsp` — installed CA/intermediate store (`CA_bak.tar.gz`; an empty tar means
  none installed)
- `_cmdstat.jsp` with `<ajax-request action="getstat" comp="system"><sysinfo/></ajax-request>`
  — model, version, serial

## Failure / recovery

| Failure | Detection | Recovery |
|---|---|---|
| Credentials rejected | Job logs "login failed: credentials rejected" (HTTP 200) | Check `ruckus-password`; confirm `certupdater` still has `rw` |
| Pair rejected | Job logs the controller's `E_*` message | Inspect the secret; the controller keeps serving the old certificate |
| Controller does not return within 10m | Verification poll fails, job exits non-zero | Check the controller physically; the previous certificate is still in place until a successful replace |
| Setup wizard incomplete / controller rebuilding | Login redirect lands on `wizard.jsp` / `index.html` | Job reports it and exits; retry later |

## Verification

- `push-certs.sh --self-test` (offline fixtures, including the unreachable-host
  regression), `shellcheck -s sh`
- Manual run: `kubectl -n network create job <name> --from=cronjob/wifi-cert-updater-ruckus`
- Second run must log "nothing to do" without rebooting
- Served chain must validate without `-k`
