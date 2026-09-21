# Printer Certificate Updater — Brother — Design

- **Date:** 2026-09-16
- **Status:** Implemented and verified — the printer serves `CN=*.internal.greyrock.io`
  (issuer Let's Encrypt YR2) on its web admin, assigned to the HTTPS server by the job
  itself; a second run reports "already serves the current certificate, nothing to do"
- **Scope:** Flux-managed CronJob that pushes the `*.internal.greyrock.io` certificate to
  one Brother MFC-L8900CDW (`brother-printer.internal.greyrock.io`, 10.1.10.218)

## Goal

Keep a valid certificate on the printer's web admin without a manual PKCS#12 upload
every renewal — including **assigning** it to the HTTPS server, which is the step that
makes the upload actually take effect.

## Non-goals

- No new Certificate or ClusterIssuer — reuse the shared `internal-greyrock-io-tls`
  secret in `network` (owned by the `internal-greyrock-io-cert` Kustomization, #215)
- No IPP/print-path changes; only the web admin certificate
- No attempt to serve a full chain — the firmware refuses one (see below)

## Architecture

`kubernetes/apps/network/printer-cert-updater-brother/`, mirroring the two BMC updaters.
The flow follows `justjanne/brother-client` (Go), which is a known-good implementation
for this family of firmware.

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

- `app/externalsecret.yaml` — item `Cert Updater` → Secret `printer-cert-updater-brother-secret`:
  `BROTHER_PASSWORD` ← `brother-password`, `BROTHER_P12_PASSWORD` ← `printer-p12-password`
- `app/helmrelease.yaml` — app-template cronjob, `schedule: "0 12 * * *"`,
  `backoffLimit: 0`, `concurrencyPolicy: Forbid`, `ttlSecondsAfterFinished: 86400`
- **initContainer `bundle`** (`alpine/openssl`) — builds `/work/cert.p12` from the
  mounted secret; see "PKCS#12 constraints" below for why this is not cert-manager's
  `keystores.pkcs12`
- `app/ciliumnetworkpolicy.yaml` — egress `10.1.10.218/32` TCP 443 only; DNS comes from
  the cluster-wide `allow-dns-egress` policy

**Schedule rationale:** activating a certificate restarts the printer's web server, so
this runs at midday rather than overnight — the printer is a physical device the user
would rather not have restarting unattended at night.

## Script flow

1. Compare the printer's served leaf against `/certs/tls.crt`; identical → exit
2. Log in (`B15bd` + `loginurl`, with a `Referer`), keep the session cookie
3. List certificates, then load **and parse** the import form *before* deleting
   anything — so a parsing failure cannot leave the printer with no certificate of ours
4. Delete previously-pushed copies of our own CN, then re-fetch the import page for a
   fresh CSRF token
5. Record the set of slot IDs in use — **after** the deletes, immediately before importing
6. Import `/work/cert.p12`
7. Re-read the list; the slot that was **not** in that recorded set is the new one
8. Point the HTTPS server at that slot (`http_setting`, field `B15e8`), then commit with
   `http_page_mode=5` — which restarts the web server
9. Poll the served leaf until it matches

## Firmware behaviour worth knowing

Each of these was established against the device, and each fails **silently** if ignored:

| Behaviour | Consequence |
|---|---|
| Every POST must carry a `Referer`. `Origin` alone is not enough. | Without it the printer answers "Your request was rejected. Please try again." curl sends no `Referer` on its own. |
| The PKCS#12 must contain the **leaf only**. A bundle carrying the CA chain is refused. | cert-manager's `keystores.pkcs12` cannot be used at all — it always embeds the chain. The initContainer strips to the leaf and uses SHA-1/3DES (`-macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES`), which this firmware predates AES/PBKDF2 defaults for. |
| The "Please wait" page returned by an import is **not** a success signal. | It comes back even for a request with no file attached. Only the certificate list is worth believing — this invalidated roughly a dozen A/B tests scored on that page before it was caught. |
| Importing does not put a certificate into service. | The HTTPS server keeps serving the old one until the selection is changed, so the job must also set it. Without this step the certificate would have to be assigned by hand every renewal, defeating the purpose. |
| Deleting a certificate does not renumber the remaining ones, and freed low slots are reused. | The new slot is read back by diffing the ID set before and after, never guessed or assumed to be "highest" or "next". Matching on the certificate *name* instead would only prove that some certificate with this CN is listed — which an older copy satisfies just as well. |
| The certificate-select field is `B15e8` on the MFC-L8900CDW. | `justjanne/brother-client` hardcodes `B12c9`, which is what the QL series calls the same field. |

## Known limitation

The printer serves a **leaf-only chain** (1 certificate, `verify error:num=20 unable to
get local issuer certificate`). This is forced by the firmware's refusal of a
chain-bearing PKCS#12, not a choice. Browsers recover via AIA fetching; stricter clients
may not. Verified 2026-09-16: served chain length 1.

## Failure / recovery

| Failure | Detection | Recovery |
|---|---|---|
| Import rejected (wrong p12 shape) | Job logs the certificate list unchanged | Rebuild the p12 leaf-only; check the initContainer's openssl flags |
| Login rejected | Job fails at login | Check `brother-password` in `Cert Updater` |
| Web server does not come back after activation | Verification poll fails | Power-cycle the printer; the previous certificate is still installed |

## Verification

- `push-certs.sh --self-test` (offline fixtures), `shellcheck -s sh`
- Manual run: `kubectl -n network create job <name> --from=cronjob/printer-cert-updater-brother`
- Second run must log "nothing to do" — proves the compare path
- Served leaf sha256 must equal the secret's leaf sha256
