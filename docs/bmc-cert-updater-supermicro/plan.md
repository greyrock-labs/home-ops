# BMC Certificate Updater (SuperMicro) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Flux CronJob in `network` that pushes the existing `*.internal.greyrock.io` Let's Encrypt certificate to the SuperMicro IPMI BMC at `kvm-homeassistant.internal.greyrock.io` (10.1.20.14), on change only.

**Architecture:** A second Flux app parallel to the existing `bmc-cert-updater`. Same `network` ns, same upstream cert, separate vendor script and CNP. Login → fetch CSRF from cert-upload page → compare served leaf → upload cert+key via `/cgi/upload_ssl.cgi` → verify-after-BMC-restart.

**Tech Stack:** Flux Kustomizations, cert-manager (existing ClusterIssuer `letsencrypt-production-classic`, existing Secret `internal-greyrock-io-tls`), External Secrets Operator + 1Password, bjw-s app-template v5.1.0, Cilium, curlimages/curl.

## Global Constraints

- Spec: `docs/bmc-cert-updater-supermicro/design.md`.
- GitOps: push to forgejo triggers Flux webhook; never run `flux reconcile`/`just k8s sync-ks`/`sync-hr`; read-only `kubectl` monitoring OK.
- Remotes: forgejo only.
- **Do not push until Task 6.** Tasks 1-5 commit locally only.
- Image pinning: container images `tag@sha256:...` (`curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777`); OCI chart pinned by tag only (`5.1.0`).
- Cert + ClusterIssuer already exist (`letsencrypt-production-classic`, Certificate `internal-greyrock-io`, Secret `internal-greyrock-io-tls` in `network`). Do not recreate.
- ESLint/format: every yaml change passes `yamllint --config-file .yamllint.yaml`.
- YAML sorting per `.agents/instructions/sorting.instructions.md` for app-template HelmReleases (already baked into the YAML blocks below).
- Commit style: `type(scope): verb`.
- No `metadata.namespace` on app resources.
- 1Password item `BMC Certs` in `Automation` vault now contains `updater-username` (shared `certupdater`) plus `homeassistant-password` for this board.
- Critical lesson from the ASRock Rack rollout: per-app Flux Kustomizations live in their target namespace (`network`), so cross-namespace `dependsOn` entries (cluster apps like `cert-manager`, `external-secrets`) MUST include explicit `namespace:` fields. Same-namespace entries (none here) can omit it.
- Targets: `kvm-homeassistant.internal.greyrock.io` (10.1.20.14). User `certupdater` Administrator.

## File Map

| File | Responsibility |
|---|---|
| `kubernetes/apps/network/bmc-cert-updater-supermicro/ks.yaml` | Flux Kustomization wiring |
| `kubernetes/apps/network/bmc-cert-updater-supermicro/app/ocirepository.yaml` | app-template chart source |
| `kubernetes/apps/network/bmc-cert-updater-supermicro/app/externalsecret.yaml` | BMC credentials from `BMC Certs` |
| `kubernetes/apps/network/bmc-cert-updater-supermicro/app/kustomization.yaml` | Resource list + configMapGenerator |
| `kubernetes/apps/network/bmc-cert-updater-supermicro/app/helmrelease.yaml` | CronJob |
| `kubernetes/apps/network/bmc-cert-updater-supermicro/app/ciliumnetworkpolicy.yaml` | Egress to BMC IP |
| `kubernetes/apps/network/bmc-cert-updater-supermicro/app/config/push-certs-supermicro.sh` | Vendor script |
| `kubernetes/apps/network/kustomization.yaml` | Register the new app |

---

### Task 1: Endpoint reconnaissance (probes firmware 03.95)

**Files:**
- Create: `docs/bmc-cert-updater-supermicro/recon.md` (findings)
- Create (in home dir, then delete): `/var/folders/.../opencode/recon.sh`
- No cluster mutations.

**Interfaces:**
- Consumes: BMC reachable at `kvm-homeassistant.internal.greyrock.io:443`.
- Produces: a `docs/bmc-cert-updater-supermicro/recon.md` listing the **exact** URLs and form-field names that Tasks 4 uses verbatim. If this task finds anything different from the assumptions in design.md (e.g. field named `csrftoken` instead of `_csrf_token`, login URL is `/cgi/login` without `.cgi`), all later tasks use what recon finds.

The SuperMicro MegaRAC firmware 03.95 (12/2021, Redfish 1.0.1) web-UI cert-upload flow varies slightly between firmware versions, so we verify exact field names against this BMC before writing the script.

- [ ] **Step 1: Write `recon.sh`** (do not commit; place under `/var/folders/.../opencode/` and remove after the run):

```sh
#!/bin/bash
# Probes the SuperMicro IPMI BMC at 10.1.20.14 to learn the exact login and
# cert-upload flow. Reads creds from the k8s Secret so it uses the same
# account you'll use from the pod.
set -eu
dir=/var/folders/fv/4vj4m5492hj4vbtj8z41rch00000gn/T/opencode
mkdir -p "$dir"

U_b64=$(kubectl -n network get secret bmc-cert-supermicro-secret -o jsonpath='{.data.UPDATER_USERNAME}')
H_b64=$(kubectl -n network get secret bmc-cert-supermicro-secret -o jsonpath='{.data.HOMEASSISTANT_PASSWORD}')
UN=$(printf '%s' "$U_b64" | base64 -d)
HP=$(printf '%s' "$H_b64" | base64 -d)
U_b64=""; H_b64=""

base=https://kvm-homeassistant.internal.greyrock.io

# Login: write Set-Cookie to jar, do not follow redirects (-i shows them).
rm -f "$dir/recon_jar"
echo "== LOGIN =="
curl -ksS --connect-timeout 10 \
  -c "$dir/recon_jar" \
  -o "$dir/login.body" \
  -w 'http=%{http_code} ct=%{content_type}\n' \
  -d "name=$UN" -d "pwd=$HP" \
  "$base/cgi/login.cgi" || true
echo "body_len=$(wc -c < "$dir/login.body" | tr -d ' ')"
head -c 600 "$dir/login.body"; echo
echo "cookie jar:"; cat "$dir/recon_jar"

# Probe a few candidate cert-upload URLs to find the one that shows the
# upload form with the CSRF field.
for url in \
  "$base/cgi/url_redirect.cgi?url_name=ssl_cert_upload" \
  "$base/cgi/url_redirect.cgi?url_name=certificate_upload" \
  "$base/cgi/upload_ssl.cgi" \
  "$base/cgi/ssl_upload.cgi"; do
  echo "== PROBE $url =="
  curl -ksS --connect-timeout 10 -b "$dir/recon_jar" \
    -o "$dir/probe.body" -w 'http=%{http_code} ct=%{content_type}\n' "$url" || true
  echo "body_len=$(wc -c < "$dir/probe.body" | tr -d ' ')"
  head -c 600 "$dir/probe.body"; echo
  echo "form inputs:"
  grep -oE '<input[^>]*name="[^"]*"' "$dir/probe.body" | sort -u
done

# Probe a sample upload with a tiny self-signed cert to learn the BMC's
# "error" response shape (we throw it away; never overwrites the real cert).
cat >"$dir/csr.pem" <<EOF
-----BEGIN CERTIFICATE REQUEST-----
MIIByTCCATICAQAwgYwxCzAJBgNVBAYTAlVTMRMwEQYDVQQKDApMb2NhbGhvc3Qx
EjAQBgNVBAgTCkNhbGlmb3JuaWExETAPBgNVBAcTCFNhbiBKb3NlMRIwEAYDVQQI
EwlPZmZpY2UxETAPBgNVBAsTCFRlYW1hbmlhMRIwEAYDVQQDEwljZXJ0dXBkYXRl
cjEOMAwGA1UEAxMFMDAwMTBcT0ZGSVRfVEVTVCBNT0NLX09OTFkwgZ8wDQYJKoZI
hvcNAQEBBQADgY0AMIGJAoGBAOZZzVH9/0QG7V9Y2Xz8n7bWJHJVPgsd0Z2D2oLC
F8z5cBqqZWrTcEum8EdLDFXCp4aqVy9qq2zd1KEzeNlZSpFY7EjuksHJj1c6xgqB
Kn5Z49QqgkmZ1U9sbOPcYsVPn9UaZ5SW7tjWUKpEUflzHRkSYv+WAgMBAAGgADAN
BgkqhkiG9w0BAQsFAAOCAQEAiXfkj9d2KE9MAqpu0/8i9ngw+p4/9+G+/Zs+fTw==
-----END CERTIFICATE REQUEST-----
EOF
cat >"$dir/key.pem" <<'EOF'
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDkWc1R/f9EBu1f
WNl8/J+1tiRyVT4LHdGdg9qCwhfM+XAcqqlatNxC6bwR0ssUtcKnhqpXL2qrbN3U
oTN42VlKkVjsiO6SwcmPVzrGCgEqflnj1CqCSZnVT2xs49ixhU+f1RpnpZLe2NZQ
qkRR+XMdGRJi/5YCAwEAAQ==
-----END PRIVATE KEY-----
EOF
# Discover the CSRF token from the probe body first (the form's _csrf_token or similar).
csrf=$(grep -oE 'name="(csrf_token|_csrf_token|csrftoken|TOKEN)"[^>]*value="[^"]*"' "$dir/probe.body" | head -1 | sed 's/.*value="\([^"]*\)".*/\1/')
[ -z "$csrf" ] && csrf=$(grep -oE 'value="[a-f0-9]\{40,\}"' "$dir/probe.body" | head -1 | sed 's/value="//;s/"$//')
echo "extracted csrf=$(printf '%s' "$csrf" | wc -c | tr -d ' ')-chars"

echo "== SAMPLE UPLOAD (expect failure - self-signed CSR is not a cert) =="
curl -ksS --connect-timeout 10 -b "$dir/recon_jar" \
  -F "cert_file=@$dir/csr.pem" -F "key_file=@$dir/key.pem" \
  -F "_csrf_token=$csrf" \
  "$base/cgi/upload_ssl.cgi" \
  -o "$dir/upload.body" -w 'http=%{http_code} ct=%{content_type}\n' || true
echo "body_len=$(wc -c < "$dir/upload.body" | tr -d ' ')"
head -c 600 "$dir/upload.body"; echo

UN=""; HP=""; csrf=""
rm -rf "$dir"
```

- [ ] **Step 2: Run it** (Mac-side; no cluster mutations). Run `bash /var/folders/.../opencode/recon.sh; rm -f /var/folders/.../opencode/recon.sh`. Capture the full output in this task's report. The output reveals the actual login URL/response, the cert-upload URL that returns the upload form, the names of all `<input>` fields in that form (especially the CSRF token field), and what the BMC responds to a no-op upload with.

- [ ] **Step 3: Write `docs/bmc-cert-updater-supermicro/recon.md`** as a tight summary of the findings, populated from the captured output. Required sections:

```markdown
# SuperMicro BMC endpoint reconnaissance — 2026-09-15

Firmware: SuperMicro IPMI 03.95 (12/23/2021)
Hostname: kvm-homeassistant.internal.greyrock.io (10.1.20.14)

## Login
- **URL:** <https://kvm-homeassistant.internal.greyrock.io/cgi/login.cgi | …>
- **Method:** POST
- **Body fields:** <name | pwd> (form-encoded)
- **Success response:** <status code, any body, Set-Cookie cookie name>

## Cert upload page (csrf source)
- **URL:** <the one that returned the upload form HTML>
- **Form input fields (name → source-of-value):** <list with csrf field note>

## Upload endpoint
- **URL:** <…>
- **Method:** POST multipart
- **Form fields:** <cert_file | key_file | _csrf_token | …>
- **Response on failure (e.g. dummy CSR):** <body / status>
- **Response on success:** <if any — e.g. "200 OK" with empty body or specific text>

## Decisions
- Login script path: <form-encoded POST to <login URL> with these field names>.
- CSRF extraction: <command used to pull the token from the cert-upload page HTML>.
- Upload field names: <verbatim from the probe output>.

## Discrepancies from design assumptions
- <any deviations from the assumed urls / field names; if none, write "None.">
```

- [ ] **Step 4: Commit**

```bash
git add docs/bmc-cert-updater-supermicro/recon.md
git commit -m "feat(bmc-cert-updater-supermicro): record live BMC endpoint findings"
```

---

### Task 2: App scaffold (`ks.yaml`, `ocirepository.yaml`, initial `kustomization.yaml`)

**Files:**
- Create: `kubernetes/apps/network/bmc-cert-updater-supermicro/ks.yaml`
- Create: `kubernetes/apps/network/bmc-cert-updater-supermicro/app/ocirepository.yaml`
- Create: `kubernetes/apps/network/bmc-cert-updater-supermicro/app/kustomization.yaml`

**Interfaces:**
- Consumes: Kustomization `cert-manager` (in `cert-manager` ns), `external-secrets` (in `external-secrets` ns) must already exist (do not create them). All app Kustomizations live in `flux-system` but get applied *into* `network` via `targetNamespace`.
- Produces: Flux Kustomization `bmc-cert-updater-supermicro` in ns `network`, dependsOn both controllers with explicit `namespace:`; OCIRepository `bmc-cert-updater-supermicro` pointing at app-template 5.1.0.

- [ ] **Step 1: Create `ks.yaml`** (cross-namespace `dependsOn` qualified because per-app Kustomizations live in their target namespace, lesson from `b27e7dcffe`):

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: bmc-cert-updater-supermicro
spec:
  dependsOn:
    - name: cert-manager
      namespace: cert-manager
    - name: external-secrets
      namespace: external-secrets
  interval: 1h
  path: "./kubernetes/apps/network/bmc-cert-updater-supermicro/app"
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: network
```

- [ ] **Step 2: Create `app/ocirepository.yaml`**:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: bmc-cert-updater-supermicro
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 5.1.0
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

- [ ] **Step 3: Create the initial `kustomization.yaml`**:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./ocirepository.yaml
```

- [ ] **Step 4: Lint and render**

Run: `yamllint --config-file .yamllint.yaml kubernetes/apps/network/bmc-cert-updater-supermicro/ks.yaml kubernetes/apps/network/bmc-cert-updater-supermicro/app/ocirepository.yaml kubernetes/apps/network/bmc-cert-updater-supermicro/app/kustomization.yaml && echo LINT_OK`
Expected: LINT_OK

Run: `kustomize build kubernetes/apps/network/bmc-cert-updater-supermicro/app`
Expected: renders exactly one OCIRepository manifest, no errors

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/network/bmc-cert-updater-supermicro/
git commit -m "feat(bmc-cert-updater-supermicro): add Flux scaffold"
```

---

### Task 3: ExternalSecret

**Files:**
- Create: `kubernetes/apps/network/bmc-cert-updater-supermicro/app/externalsecret.yaml`
- Modify: `kubernetes/apps/network/bmc-cert-updater-supermicro/app/kustomization.yaml`

**Interfaces:**
- Consumes: 1Password item `BMC Certs` in the `Automation` vault via ClusterSecretStore `onepassword-connect` (already installed).
- Produces: Secret `bmc-cert-supermicro-secret` with keys `UPDATER_USERNAME` and `HOMEASSISTANT_PASSWORD` (valid env-var names, so `envFrom: secretRef: bmc-cert-supermicro-secret` in Task 5 will populate the script's environment).

- [ ] **Step 1: Create `externalsecret.yaml`**:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: bmc-cert-supermicro
spec:
  refreshInterval: 12h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: bmc-cert-supermicro-secret
    creationPolicy: Owner
  data:
    - secretKey: UPDATER_USERNAME
      remoteRef:
        key: BMC Certs
        property: updater-username
    - secretKey: HOMEASSISTANT_PASSWORD
      remoteRef:
        key: BMC Certs
        property: homeassistant-password
```

- [ ] **Step 2: Update `kustomization.yaml`** to:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./externalsecret.yaml
  - ./ocirepository.yaml
```

- [ ] **Step 3: Lint and render**

Run: `yamllint --config-file .yamllint.yaml kubernetes/apps/network/bmc-cert-updater-supermicro/app/externalsecret.yaml kubernetes/apps/network/bmc-cert-updater-supermicro/app/kustomization.yaml && echo LINT_OK`
Expected: LINT_OK

Run: `kustomize build kubernetes/apps/network/bmc-cert-updater-supermicro/app`
Expected: renders ExternalSecret + OCIRepository, no errors

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/network/bmc-cert-updater-supermicro/app/
git commit -m "feat(bmc-cert-updater-supermicro): add external secret"
```

---

### Task 4: Push script (`config/push-certs-supermicro.sh`)

**Files:**
- Create: `kubernetes/apps/network/bmc-cert-updater-supermicro/app/config/push-certs-supermicro.sh`
- Modify: `kubernetes/apps/network/bmc-cert-updater-supermicro/app/kustomization.yaml` (add `configMapGenerator`)

**Interfaces:**
- Consumes: `/certs/tls.crt` (fullchain) and `/certs/tls.key` mounted at `/certs`; env vars `UPDATER_USERNAME` and `HOMEASSISTANT_PASSWORD` (Task 3); the exact URLs/form-field names captured in Task 1's `recon.md`.
- Produces: ConfigMap `bmc-cert-updater-supermicro` with key `push-certs-supermicro.sh` (hash-free thanks to `disableNameSuffixHash: true`).

The script below uses the field names **as captured in Task 1's recon.md**. If recon finds different names, substitute them everywhere — every place the [bracketed token] appears below is recon-driven. The variables holding the discovered names make that substitution easy.

- [ ] **Step 1: Create `config/push-certs-supermicro.sh`** with exactly this content (replace the bracket tokens before committing):

```sh
#!/bin/sh
# Pushes the *.internal.greyrock.io certificate to the SuperMicro IPMI BMC
# at kvm-homeassistant.internal.greyrock.io via the BMC web API:
# login (X11 firmware: base64 username/password + check=00) -> fetch cert
# page -> parse CSRF (SmcCsrfInsert("CSRF_TOKEN", "...")) -> upload cert+key
# with Origin/Referer/CSRF_TOKEN headers -> verify-after-BMC-restart.
# Offline self-test: push-certs-supermicro.sh --self-test

set -eu

CERT_FILE="${CERT_FILE:-/certs/tls.crt}"
KEY_FILE="${KEY_FILE:-/certs/tls.key}"
TARGET="homeassistant|kvm-homeassistant.internal.greyrock.io"

# URLs captured by Task 1 (recon.md). Edit only if recon finds different values.
LOGIN_URL="${LOGIN_URL:-https://${TARGET#*|}/cgi/login.cgi}"
CERT_PAGE_URL="${CERT_PAGE_URL:-https://${TARGET#*|}/cgi/url_redirect.cgi?url_name=config_ssl}"
UPLOAD_URL="${UPLOAD_URL:-https://${TARGET#*|}/cgi/upload_ssl.cgi}"

CURL="curl -k -sS --connect-timeout 10 --max-time 60"

# Print only the first (leaf) certificate block of a PEM bundle on disk or stdin.
first_leaf() {
    if [ "$#" -gt 0 ]; then
        awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} f && /-----END CERTIFICATE-----/{exit}' "$1"
    else
        awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} f && /-----END CERTIFICATE-----/{exit}'
    fi
}

# PEM of the leaf certificate currently served by $1 (URL).
served_leaf() {
    # shellcheck disable=SC2086
    $CURL -o /dev/null -w '%{certs}' "${1:?no url}" | first_leaf | tr -d '\r'
}

desired_leaf() {
    first_leaf "$CERT_FILE" | tr -d '\r'
}

# X11 firmware: login body fields are base64-encoded. `base64 | tr -d '\n'`
# produces a single base64 string (macOS base64 lacks -w).
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# Extract the CSRF token from the cert-upload page. The X11 firmware embeds
# it via a JavaScript call SmcCsrfInsert("CSRF_TOKEN", "<token>"); we capture
# the token value out of that line.
extract_csrf() {
    page="$1"
    jar="$2"
    body=$(mktemp)
    # shellcheck disable=SC2086
    $CURL -b "$jar" -o "$body" "$page" 2>/dev/null || { echo ""; rm -f "$body"; return; }
    awk '
        match($0, /SmcCsrfInsert[[:space:]]*\([[:space:]]*"CSRF_TOKEN"[[:space:]]*,[[:space:]]*"[^"]*"/) {
            m = substr($0, RSTART, RLENGTH)
            sub(/.*"CSRF_TOKEN"[[:space:]]*,[[:space:]]*"/, "", m)
            sub(/".*/, "", m)
            print m
            exit
        }
    ' "$body"
    rm -f "$body"
}

push_one() {
    name="${1:?no bmc name}"
    host="${2:?no bmc host}"
    base="https://$host"
    jar=$(mktemp /tmp/cookies.XXXXXX)
    username="${UPDATER_USERNAME:?UPDATER_USERNAME not set}"
    password="${HOMEASSISTANT_PASSWORD:?HOMEASSISTANT_PASSWORD not set}"

    # Login (X11 firmware: name/pwd base64-encoded, plus check=00).
    rm -f "$jar"
    # shellcheck disable=SC2086
    $CURL -c "$jar" --fail \
        --data-urlencode "name=$(b64 "$username")" \
        --data-urlencode "pwd=$(b64 "$password")" \
        --data-urlencode "check=00" \
        "$LOGIN_URL" >/dev/null || { echo "$name: login request failed"; rm -f "$jar"; return 1; }

    # Auth detection: the X11 firmware always issues at least the SID
    # cookie via Set-Cookie on successful login.
    if ! grep -q . "$jar" 2>/dev/null; then
        echo "$name: login failed (no session cookie issued)"
        rm -f "$jar"; return 1
    fi

    # Pull CSRF from the cert page.
    csrf=$(extract_csrf "$CERT_PAGE_URL" "$jar")
    if [ -z "$csrf" ]; then
        echo "$name: csrf token absent on cert page"
        rm -f "$jar"; return 1
    fi

    # Compare served leaf vs desired leaf.
    desired=$(desired_leaf)
    current=$(served_leaf "$base") || { echo "$name: could not fetch served certificate"; rm -f "$jar"; return 1; }
    if [ "$current" = "$desired" ]; then
        echo "$name: certificate unchanged, skipping"
        rm -f "$jar"; return 0
    fi

    # Upload: send CSRF as both an HTTP header and a multipart form field
    # (the X11 firmware accepts either, the community script sends both
    # for safety). Origin and Referer must match.
    # shellcheck disable=SC2086
    $CURL -b "$jar" --fail \
        -H "Origin: $base" \
        -H "Referer: $CERT_PAGE_URL" \
        -H "CSRF_TOKEN: $csrf" \
        -F "cert_file=@$CERT_FILE" \
        -F "key_file=@$KEY_FILE" \
        -F "CSRF_TOKEN=$csrf" \
        "$UPLOAD_URL" >/dev/null || {
        echo "$name: certificate upload failed"
        rm -f "$jar"; return 1
    }
    rm -f "$jar"

    # Verify after BMC web server restart.
    verified=""
    i=1
    while [ "$i" -le 6 ]; do
        sleep 5
        if current=$(served_leaf "$base"); then
            [ "$current" = "$desired" ] && verified=1 && break
        fi
        i=$((i + 1))
    done
    if [ -z "$verified" ]; then
        echo "$name: uploaded but served certificate does not match"
        return 1
    fi
    echo "$name: certificate updated and verified"
}

self_test() {
    tmp=$(mktemp -d)

    # Fixture 1: leaf extraction from a fullchain.
    cat >"$tmp/fullchain.pem" <<'EOF'
-----BEGIN CERTIFICATE-----
LEAFAAABBBCCC
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
CHAINDDD EEEFFF
-----END CERTIFICATE-----
EOF
    leaf=$(first_leaf "$tmp/fullchain.pem")
    lines=$(printf '%s\n' "$leaf" | wc -l | tr -d ' ')
    [ "$lines" -eq 3 ] || { echo "self-test FAIL: leaf extraction returned $lines lines"; rm -rf "$tmp"; return 1; }
    [ "$(printf '%s\n' "$leaf" | sed -n '2p')" = "LEAFAAABBBCCC" ] || { echo "self-test FAIL: leaf extraction picked wrong block"; rm -rf "$tmp"; return 1; }
    [ "$(printf '%s\n' "$leaf" | sed -n '3p')" = "-----END CERTIFICATE-----" ] || { echo "self-test FAIL: leaf block not terminated"; rm -rf "$tmp"; return 1; }

    # Fixture 2: CSRF extraction against the X11 SmcCsrfInsert script block.
    cat >"$tmp/page.html" <<'EOF'
<html><head><script>
SmcCsrfInsert("CSRF_TOKEN", "abc12345TOKEN");
</script></head><body>
<form action="/cgi/upload_ssl.cgi" method="POST" enctype="multipart/form-data">
  <input type="file" name="cert_file"/>
  <input type="file" name="key_file"/>
</form></body></html>
EOF
    csrf=$(awk '
        match($0, /SmcCsrfInsert[[:space:]]*\([[:space:]]*"CSRF_TOKEN"[[:space:]]*,[[:space:]]*"[^"]*"/) {
            m = substr($0, RSTART, RLENGTH)
            sub(/.*"CSRF_TOKEN"[[:space:]]*,[[:space:]]*"/, "", m)
            sub(/".*/, "", m)
            print m
            exit
        }
    ' "$tmp/page.html")
    [ "$csrf" = "abc12345TOKEN" ] || { echo "self-test FAIL: csrf extract returned '$csrf'"; rm -rf "$tmp"; return 1; }

    # Fixture 3: CRLF normalization.
    a=$(printf -- '-----BEGIN CERTIFICATE-----\r\nX\r\n-----END CERTIFICATE-----\r\n' | tr -d '\r')
    b=$(printf -- '-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----\n')
    [ "$a" = "$b" ] || { echo "self-test FAIL: CRLF normalization"; rm -rf "$tmp"; return 1; }

    rm -rf "$tmp"
    echo "self-test: all fixtures passed"
}

case "${1:-}" in
    --self-test)
        self_test
        exit 0
        ;;
esac

[ -f "$CERT_FILE" ] || { echo "missing $CERT_FILE"; exit 1; }
[ -f "$KEY_FILE" ] || { echo "missing $KEY_FILE"; exit 1; }

rc=0
for entry in $TARGET; do
    name=${entry%%|*}
    host=${entry#*|}
    if (push_one "$name" "$host"); then
        :
    else
        rc=1
    fi
done
exit "$rc"
```

- [ ] **Step 2: Run the self-test**

Run: `sh kubernetes/apps/network/bmc-cert-updater-supermicro/app/config/push-certs-supermicro.sh --self-test`
Expected: `self-test: all fixtures passed`, exit 0

- [ ] **Step 3: Shellcheck**

Run: `shellcheck kubernetes/apps/network/bmc-cert-updater-supermicro/app/config/push-certs-supermicro.sh`
Expected: no findings (the inline `# shellcheck disable=SC2086` comments cover the expansion warnings)

- [ ] **Step 4: Update `kustomization.yaml`** to enable the configMapGenerator:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./externalsecret.yaml
  - ./ocirepository.yaml
configMapGenerator:
  - name: bmc-cert-updater-supermicro
    files:
      - config/push-certs-supermicro.sh
generatorOptions:
  disableNameSuffixHash: true
  annotations:
    kustomize.toolkit.fluxcd.io/substitute: disabled
```

- [ ] **Step 5: Lint and render**

Run: `yamllint --config-file .yamllint.yaml kubernetes/apps/network/bmc-cert-updater-supermicro/app/kustomization.yaml && echo LINT_OK`
Expected: LINT_OK

Run: `kustomize build kubernetes/apps/network/bmc-cert-updater-supermicro/app | grep -c push-certs-supermicro.sh`
Expected: `2` (ConfigMap data key + mounted file path)

- [ ] **Step 6: Commit**

```bash
git add kubernetes/apps/network/bmc-cert-updater-supermicro/app/
git commit -m "feat(bmc-cert-updater-supermicro): add BMC cert push script"
```

---

### Task 5: HelmRelease, CiliumNetworkPolicy, register app

**Files:**
- Create: `kubernetes/apps/network/bmc-cert-updater-supermicro/app/helmrelease.yaml`
- Create: `kubernetes/apps/network/bmc-cert-updater-supermicro/app/ciliumnetworkpolicy.yaml`
- Modify: `kubernetes/apps/network/bmc-cert-updater-supermicro/app/kustomization.yaml`
- Modify: `kubernetes/apps/network/kustomization.yaml`

**Interfaces:**
- Consumes: OCIRepository `bmc-cert-updater-supermicro` (Task 2); ExternalSecret `bmc-cert-updater-supermicro` → Secret `bmc-cert-supermicro-secret` (Task 3); ConfigMap `bmc-cert-updater-supermicro` (Task 4); existing Secret `internal-greyrock-io-tls` in `network` ns (owned by the other app).
- Produces: CronJob `bmc-cert-updater-supermicro` in `network` ns; app registered in `network` kustomization.

- [ ] **Step 1: Create `helmrelease.yaml`** with exactly this content (already sorted per the repo's sorting instructions — do not reorder):

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: bmc-cert-updater-supermicro
spec:
  chartRef:
    kind: OCIRepository
    name: bmc-cert-updater-supermicro
  interval: 30m
  values:
    controllers:
      bmc-cert-updater-supermicro:
        type: cronjob
        cronjob:
          schedule: "@daily"
          backoffLimit: 0
          concurrencyPolicy: Forbid
          failedJobsHistory: 1
          successfulJobsHistory: 0
        pod:
          labels:
            egress.policy.home.arpa/block-all: "true"
          securityContext:
            runAsGroup: 100
            runAsNonRoot: true
            runAsUser: 100
        containers:
          app:
            image:
              repository: docker.io/curlimages/curl
              tag: 8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777
            command:
              - /bin/sh
              - /script/push-certs-supermicro.sh
            envFrom:
              - secretRef:
                  name: bmc-cert-supermicro-secret
            probes:
              liveness:
                enabled: false
              readiness:
                enabled: false
              startup:
                enabled: false
            resources:
              requests:
                cpu: 10m
                memory: 16Mi
              limits:
                memory: 64Mi
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop:
                  - ALL
              readOnlyRootFilesystem: true
    persistence:
      certs:
        type: secret
        name: internal-greyrock-io-tls
        globalMounts:
          - path: /certs
      script:
        type: configMap
        name: bmc-cert-updater-supermicro
        globalMounts:
          - path: /script/push-certs-supermicro.sh
            subPath: push-certs-supermicro.sh
      tmp:
        type: emptyDir
        globalMounts:
          - path: /tmp
```

- [ ] **Step 2: Create `ciliumnetworkpolicy.yaml`**:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/cilium.io/ciliumnetworkpolicy_v2.json
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: bmc-cert-updater-supermicro
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: bmc-cert-updater-supermicro
      app.kubernetes.io/instance: bmc-cert-updater-supermicro
  egress:
    - toCIDR:
        - 10.1.20.14/32
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

- [ ] **Step 3: Final `app/kustomization.yaml`** (all five resources + generator block):

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./ciliumnetworkpolicy.yaml
  - ./externalsecret.yaml
  - ./helmrelease.yaml
  - ./ocirepository.yaml
configMapGenerator:
  - name: bmc-cert-updater-supermicro
    files:
      - config/push-certs-supermicro.sh
generatorOptions:
  disableNameSuffixHash: true
  annotations:
    kustomize.toolkit.fluxcd.io/substitute: disabled
```

- [ ] **Step 4: Register the app in `kubernetes/apps/network/kustomization.yaml`** — final `resources:` list:

```yaml
resources:
  - ./bmc-cert-updater-supermicro/ks.yaml
  - ./bmc-cert-updater/ks.yaml
  - ./echo-server/ks.yaml
  - ./envoy-gateway/ks.yaml
  - ./external-dns/ks.yaml
  - ./multus/ks.yaml
  - ./towonel-agent/ks.yaml
  - ./unifi-voucher-manager/ks.yaml
```

(`namespace: network`, `components:`, and the file header are unchanged.)

- [ ] **Step 5: Lint and render**

Run: `yamllint --config-file .yamllint.yaml kubernetes/apps/network/bmc-cert-updater-supermicro/app/helmrelease.yaml kubernetes/apps/network/bmc-cert-updater-supermicro/app/ciliumnetworkpolicy.yaml kubernetes/apps/network/bmc-cert-updater-supermicro/app/kustomization.yaml kubernetes/apps/network/kustomization.yaml && echo LINT_OK`
Expected: LINT_OK

Run: `kustomize build kubernetes/apps/network > /dev/null && echo RENDER_OK`
Expected: `RENDER_OK`

- [ ] **Step 6: Commit**

```bash
git add kubernetes/apps/
git commit -m "feat(bmc-cert-updater-supermicro): add cert updater CronJob"
```

---

### Task 6: Roll out and verify

**Files:** none (verification only)

**Interfaces:**
- Consumes: the pushed commits from Tasks 1-5; kubectl context `home-ops`; the `certupdater` user on `kvm-homeassistant.internal.greyrock.io` with the password from `bmc-cert-supermicro-secret`.

**Known risks (from spec):** A bad cert upload can wedge the BMC web UI; recovery is `ipmitool mc reset cold` over LAN from any host.

- [ ] **Step 1: Push**

Run: `git push forgejo`
Expected: succeeds; Flux reconciles via webhook. **Do not** run `flux reconcile` or `sync-ks`/`sync-hr` — wait for the webhook.

- [ ] **Step 2: Wait for rollout and verify references (read-only)**

```bash
kubectl -n flux-system get kustomization bmc-cert-updater-supermicro    # Ready True
kubectl -n network get externalsecret bmc-cert-supdater-supermicro     # SecretSynced True
kubectl -n network get secret bmc-cert-supermicro-secret               # exists, three keys present
kubectl -n network get cronjob bmc-cert-updater-supermicro              # SCHEDULE @daily
kubectl -n network get configmap bmc-cert-updater-supermicro            # key push-certs-supermicro.sh
```

- [ ] **Step 3: Mac-side end-to-end probe** (mirrors the prior project's flow)

Write `/var/folders/.../opencode/e2e.sh` that pulls `bmc-cert-supermicro-secret` from the cluster (base64 decode in vars, never echoed), pulls `internal-greyrock-io-tls` into local files (then securely deletes them), and runs the exact sequence the pod will:

1. form-encoded `POST /cgi/login.cgi` → cookie jar
2. `GET <cert page URL>` with cookie → extract CSRF (use the same script's `extract_csrf` logic with the inline awk)
3. fetch served leaf (`curl -k -o /dev/null -w '%{certs}'`), extract leaf, SHA-256 first 12 hex chars; fetch desired leaf, same hash
4. if different, `POST /cgi/upload_ssl.cgi` multipart `cert_file` / `key_file` / csrf-field → report HTTP code and body length
5. retry `served_leaf` with `sleep 4` × 8 attempts

Print sanitized output only: HTTP codes, leaf sha256 prefixes (no values). Run `bash /var/folders/.../opencode/e2e.sh; status=$?; shred -u /var/folders/.../opencode/e2e.sh /var/folders/.../opencode/*.pem /var/folders/.../opencode/*.key 2>/dev/null; exit $status`.

- [ ] **Step 4: Manual first CronJob run + browser verification**

```bash
kubectl -n network create job --from=cronjob/bmc-cert-updater-supermicro bmc-cert-supdater-supermicro-manual-1
kubectl -n network wait --for=condition=complete --timeout=300s job/bmc-cert-updater-supermicro-manual-1 \
  || kubectl -n network logs job/bmc-cert-updater-supermicro-manual-1
```

Expected logs: `homeassistant: certificate updated and verified`. Confirm in browser at `https://kvm-homeassistant.internal.greyrock.io`: LE cert, SAN `*.internal.greyrock.io`, no browser warning.

- [ ] **Step 5: Verify the skip-if-unchanged path**

```bash
kubectl -n network create job --from=cronjob/bmc-cert-updater-supermicro bmc-cert-supdater-supermicro-manual-2
kubectl -n network wait --for=condition=complete --timeout=300s job/bmc-cert-updater-supermicro-manual-2
kubectl -n network logs job/bmc-cert-updater-supermicro-manual-2
```

Expected logs: `homeassistant: certificate unchanged, skipping`.

- [ ] **Step 6: Clean up**

```bash
kubectl -n network delete job bmc-cert-updater-supermicro-manual-1 bmc-cert-updater-supermicro-manual-2
```

- [ ] **Step 7: Update the design status and commit it**

In `docs/bmc-cert-updater-supermicro/design.md`, change the `Status:` line to "Implemented and verified in cluster — LE certificate live on the SuperMicro BMC, daily CronJob will skip until cert rotates". Commit as `docs(bmc-cert-updater-supermicro): mark design verified`, push with the same single push as the work if any remains.
