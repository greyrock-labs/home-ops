# BMC Certificate Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a valid Let's Encrypt `*.internal.greyrock.io` certificate on both ASRock Rack X570D4U-2L2T BMC web UIs via a Flux-managed CronJob that pushes the cert only when it changes.

**Architecture:** cert-manager issues an RSA 2048 wildcard from a new classic-profile ClusterIssuer into a Secret; an app-template CronJob in the `network` namespace runs a POSIX-sh/curl script daily that logs into each BMC's web API, compares the served leaf cert, and uploads cert+key only on change. Spec: `docs/bmc-cert-updater/design.md`.

**Tech Stack:** Flux Kustomizations, cert-manager, External Secrets Operator + 1Password Connect, bjw-s app-template v5.1.0 (OCI), Cilium, curlimages/curl.

## Global Constraints

- **Design spec is authoritative:** `docs/bmc-cert-updater/design.md`. Read it before starting.
- **Git is GitOps:** pushing to `forgejo` triggers a Flux webhook. **Never** run `flux reconcile source git` or `just k8s sync-ks` / `sync-hr` on your own — read-only `kubectl` monitoring is fine.
- **Remotes:** `forgejo` is the only remote. Never add a remote.
- **Do not push until Task 6.** Tasks 1-5 commit locally only, so Flux never sees a half-built app.
- **Image pinning:** container images pinned `tag@sha256:...`; the app-template OCI chart pinned by tag only (`5.1.0`).
- **YAML sorting:** the HelmRelease YAML in this plan is already sorted per `.agents/instructions/sorting.instructions.md`. Do not re-sort.
- **No `metadata.namespace`** on app resources — the namespace comes from `ks.yaml` `targetNamespace: network` / the `network` kustomization.
- **Lint gate:** every YAML change must pass `yamllint --config-file .yamllint.yaml <files>` (config: `indentation: consistent`, `truthy` requires quoted `"true"`, line-length disabled).
- **Commit style:** `type(scope): verb`, e.g. `feat(bmc-cert-updater): add ...`.
- **BMC endpoints** (from spec): login `POST /api/session` (form-encoded, JSON response with `CSRFToken`), upload `POST /api/settings/ssl/certificate` (header `X-CSRFTOKEN`, multipart `new_certificate` = fullchain, `new_private_key` = key). Targets: `kvm-codswallop.internal.greyrock.io` (10.1.20.13), `kvm-kerfuffle.internal.greyrock.io` (10.1.20.11).
- **Secrets:** 1Password item `BMC Certs` with fields `updater-username`, `codswallop-password`, `kerfuffle-password` (already created by the user). Secret keys must be valid env var names (underscores), so: `UPDATER_USERNAME`, `CODSWALLOP_PASSWORD`, `KERFUFFLE_PASSWORD`.

## File Map

| File | Responsibility |
|---|---|
| `kubernetes/apps/cert-manager/cert-manager/app/clusterissuer.yaml` | Add `letsencrypt-production-classic` (Task 1) |
| `kubernetes/apps/network/bmc-cert-updater/ks.yaml` | Flux Kustomization wiring (Task 2) |
| `kubernetes/apps/network/bmc-cert-updater/app/ocirepository.yaml` | app-template chart source (Task 2) |
| `kubernetes/apps/network/bmc-cert-updater/app/kustomization.yaml` | Resource list + configMapGenerator (grows in Tasks 2-5) |
| `kubernetes/apps/network/bmc-cert-updater/app/certificate.yaml` | `*.internal.greyrock.io` RSA cert (Task 3) |
| `kubernetes/apps/network/bmc-cert-updater/app/externalsecret.yaml` | BMC credentials from 1Password (Task 3) |
| `kubernetes/apps/network/bmc-cert-updater/app/config/push-certs.sh` | The push script, self-testable (Task 4) |
| `kubernetes/apps/network/bmc-cert-updater/app/helmrelease.yaml` | The CronJob (Task 5) |
| `kubernetes/apps/network/bmc-cert-updater/app/ciliumnetworkpolicy.yaml` | Egress to the two BMC IPs (Task 5) |
| `kubernetes/apps/network/kustomization.yaml` | Register the new app (Task 5) |

---

### Task 1: ClusterIssuer `letsencrypt-production-classic`

**Files:**
- Modify: `kubernetes/apps/cert-manager/cert-manager/app/clusterissuer.yaml` (append a third document)

**Interfaces:**
- Produces: ClusterIssuer `letsencrypt-production-classic`, consumed by the Certificate in Task 3. Its `privateKeySecretRef` is `letsencrypt-production-classic` (cert-manager-managed ACME account key Secret in `cert-manager` ns).

- [ ] **Step 1: Append the new ClusterIssuer document** to the end of `kubernetes/apps/cert-manager/cert-manager/app/clusterissuer.yaml` (it currently contains `letsencrypt-production` and `letsencrypt-staging`; copy `letsencrypt-production`, drop the `profile:` line so LE's default `classic` profile applies, rename, and change the `privateKeySecretRef`):

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/cert-manager.io/clusterissuer_v1.json
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production-classic
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: acme@greyrock.io
    privateKeySecretRef:
      name: letsencrypt-production-classic
    solvers:
      - dns01:
          webhook:
            groupName: acme.ixon.cloud
            solverName: cloudns
```

- [ ] **Step 2: Lint**

Run: `yamllint --config-file .yamllint.yaml kubernetes/apps/cert-manager/cert-manager/app/clusterissuer.yaml`
Expected: no output (clean pass)

- [ ] **Step 3: Verify the manifest renders**

Run: `kustomize build kubernetes/apps/cert-manager/cert-manager/app | grep -c 'name: letsencrypt-production-classic'`
Expected: `2` (once in `privateKeySecretRef`, once as the document's metadata name)

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/cert-manager/cert-manager/app/clusterissuer.yaml
git commit -m "feat(cert-manager): add classic-profile ClusterIssuer"
```

---

### Task 2: App scaffold (`ks.yaml`, `ocirepository.yaml`, initial `kustomization.yaml`)

**Files:**
- Create: `kubernetes/apps/network/bmc-cert-updater/ks.yaml`
- Create: `kubernetes/apps/network/bmc-cert-updater/app/ocirepository.yaml`
- Create: `kubernetes/apps/network/bmc-cert-updater/app/kustomization.yaml`

**Interfaces:**
- Produces: Flux Kustomization `bmc-cert-updater` (targetNamespace `network`, dependsOn `cert-manager` and `external-secrets` — all app Kustomizations live in `flux-system`, so no namespace on dependsOn entries, matching `towonel-agent/ks.yaml`); OCIRepository `bmc-cert-updater`. The app is NOT yet registered in `kubernetes/apps/network/kustomization.yaml` (that happens in Task 5, so Flux never sees a half-built app).

- [ ] **Step 1: Create `kubernetes/apps/network/bmc-cert-updater/ks.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: bmc-cert-updater
spec:
  dependsOn:
    - name: cert-manager
    - name: external-secrets
  interval: 1h
  path: "./kubernetes/apps/network/bmc-cert-updater/app"
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: network
```

- [ ] **Step 2: Create `kubernetes/apps/network/bmc-cert-updater/app/ocirepository.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: bmc-cert-updater
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 5.1.0
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

- [ ] **Step 3: Create the initial `kubernetes/apps/network/bmc-cert-updater/app/kustomization.yaml`**

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./ocirepository.yaml
```

- [ ] **Step 4: Lint and render**

Run: `yamllint --config-file .yamllint.yaml kubernetes/apps/network/bmc-cert-updater/ks.yaml kubernetes/apps/network/bmc-cert-updater/app/ocirepository.yaml kubernetes/apps/network/bmc-cert-updater/app/kustomization.yaml`
Expected: clean pass

Run: `kustomize build kubernetes/apps/network/bmc-cert-updater/app`
Expected: renders one OCIRepository manifest, no errors

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/network/bmc-cert-updater/
git commit -m "feat(bmc-cert-updater): add Flux scaffold"
```

---

### Task 3: Certificate and ExternalSecret

**Files:**
- Create: `kubernetes/apps/network/bmc-cert-updater/app/certificate.yaml`
- Create: `kubernetes/apps/network/bmc-cert-updater/app/externalsecret.yaml`
- Modify: `kubernetes/apps/network/bmc-cert-updater/app/kustomization.yaml`

**Interfaces:**
- Consumes: ClusterIssuer `letsencrypt-production-classic` (Task 1); 1Password item `BMC Certs` via ClusterSecretStore `onepassword-connect`.
- Produces: Secret `internal-greyrock-io-tls` (`network` ns; keys `tls.crt` fullchain + `tls.key`) mounted by the CronJob (Task 5); Secret `bmc-cert-updater-secret` with env keys `UPDATER_USERNAME`, `CODSWALLOP_PASSWORD`, `KERFUFFLE_PASSWORD` (consumed by the script in Task 4 via `envFrom`).

- [ ] **Step 1: Create `kubernetes/apps/network/bmc-cert-updater/app/certificate.yaml`**

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/datreeio/CRDs-catalog/refs/heads/main/cert-manager.io/certificate_v1.json
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: internal-greyrock-io
spec:
  dnsNames:
    - "*.internal.greyrock.io"
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt-production-classic
  privateKey:
    algorithm: RSA
    rotationPolicy: Always
    size: 2048
  secretName: internal-greyrock-io-tls
```

- [ ] **Step 2: Create `kubernetes/apps/network/bmc-cert-updater/app/externalsecret.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: bmc-cert-updater
spec:
  refreshInterval: 12h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: bmc-cert-updater-secret
    creationPolicy: Owner
  data:
    - secretKey: UPDATER_USERNAME
      remoteRef:
        key: BMC Certs
        property: updater-username
    - secretKey: CODSWALLOP_PASSWORD
      remoteRef:
        key: BMC Certs
        property: codswallop-password
    - secretKey: KERFUFFLE_PASSWORD
      remoteRef:
        key: BMC Certs
        property: kerfuffle-password
```

- [ ] **Step 3: Add both to `kustomization.yaml`** — full resulting file:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./certificate.yaml
  - ./externalsecret.yaml
  - ./ocirepository.yaml
```

- [ ] **Step 4: Lint and render**

Run: `yamllint --config-file .yamllint.yaml kubernetes/apps/network/bmc-cert-updater/app/certificate.yaml kubernetes/apps/network/bmc-cert-updater/app/externalsecret.yaml kubernetes/apps/network/bmc-cert-updater/app/kustomization.yaml`
Expected: clean pass

Run: `kustomize build kubernetes/apps/network/bmc-cert-updater/app`
Expected: three manifests (OCIRepository, Certificate, ExternalSecret), no errors

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/network/bmc-cert-updater/app/
git commit -m "feat(bmc-cert-updater): add certificate and external secret"
```

---

### Task 4: The push script (`config/push-certs.sh`)

**Files:**
- Create: `kubernetes/apps/network/bmc-cert-updater/app/config/push-certs.sh`
- Modify: `kubernetes/apps/network/bmc-cert-updater/app/kustomization.yaml` (add configMapGenerator)

**Interfaces:**
- Consumes: files `/certs/tls.crt` (fullchain) and `/certs/tls.key` (mounted in Task 5); env vars `UPDATER_USERNAME`, `CODSWALLOP_PASSWORD`, `KERFUFFLE_PASSWORD` (Task 3 Secret).
- Produces: ConfigMap `bmc-cert-updater` with data key `push-certs.sh` (name is hash-free thanks to `disableNameSuffixHash: true` — that exact name is referenced by the Task 5 HelmRelease). The script exits 0 when both BMCs are in the desired state, non-zero if any BMC failed. `--self-test` runs offline fixtures and exits 0/non-zero without touching the network.

- [ ] **Step 1: Create `kubernetes/apps/network/bmc-cert-updater/app/config/push-certs.sh`** with exactly this content:

```sh
#!/bin/sh
# Pushes the *.internal.greyrock.io certificate to the ASRock Rack X570D4U-2L2T
# BMC web UIs via the BMC web API (login -> CSRF token -> upload cert+key).
# Upload happens only when the BMC's served leaf certificate differs from
# the desired one. Offline self-test: push-certs.sh --self-test

set -eu

CERT_FILE="${CERT_FILE:-/certs/tls.crt}"
KEY_FILE="${KEY_FILE:-/certs/tls.key}"
TARGETS="codswallop|kvm-codswallop.internal.greyrock.io kerfuffle|kvm-kerfuffle.internal.greyrock.io"

# shellcheck disable=SC2086
CURL="curl -k -sS --connect-timeout 10 --max-time 60"

password_for() {
    case "${1:?no bmc name}" in
        codswallop) printf '%s' "${CODSWALLOP_PASSWORD:?CODSWALLOP_PASSWORD not set}" ;;
        kerfuffle) printf '%s' "${KERFUFFLE_PASSWORD:?KERFUFFLE_PASSWORD not set}" ;;
        *) return 1 ;;
    esac
}

# Print only the first (leaf) certificate block of a PEM bundle.
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

push_one() {
    name="${1:?no bmc name}"
    host="${2:?no bmc host}"
    base="https://$host"
    jar=$(mktemp /tmp/cookies.XXXXXX)
    username="${UPDATER_USERNAME:?UPDATER_USERNAME not set}"
    password=$(password_for "$name")

    # Login: form-encoded credentials, JSON response carries the CSRF token.
    # shellcheck disable=SC2086
    response=$($CURL --cookie-jar "$jar" \
        --data-urlencode "username=$username" \
        --data-urlencode "password=$password" \
        "$base/api/session") || { echo "$name: login request failed"; return 1; }
    token=$(printf '%s' "$response" | sed -n 's/.*"CSRFToken":"\([^"]*\)".*/\1/p')
    if [ -z "$token" ]; then
        echo "$name: login failed (no CSRFToken in response)"
        return 1
    fi

    desired=$(desired_leaf)
    current=$(served_leaf "$base") || { echo "$name: could not fetch served certificate"; return 1; }

    if [ "$current" = "$desired" ]; then
        echo "$name: certificate unchanged, skipping"
        rm -f "$jar"
        return 0
    fi

    # Upload fullchain + key. Only reached when the cert actually changed.
    # shellcheck disable=SC2086
    $CURL --fail --cookie "$jar" \
        -H "X-CSRFTOKEN: $token" \
        -F "new_certificate=@$CERT_FILE" \
        -F "new_private_key=@$KEY_FILE" \
        "$base/api/settings/ssl/certificate" >/dev/null || {
        echo "$name: certificate upload failed"
        rm -f "$jar"
        return 1
    }
    rm -f "$jar"

    # The BMC restarts its web server to apply the new cert; verify with retries.
    verified=""
    i=1
    while [ "$i" -le 6 ]; do
        sleep 5
        if current=$(served_leaf "$base"); then
            if [ "$current" = "$desired" ]; then
                verified=1
                break
            fi
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

    # Fixture 1: fullchain with two certs - only the leaf must be extracted.
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
    [ "$lines" -eq 3 ] || { echo "self-test FAIL: leaf extraction returned $lines lines"; return 1; }
    [ "$(printf '%s\n' "$leaf" | sed -n '2p')" = "LEAFAAABBBCCC" ] || { echo "self-test FAIL: leaf extraction picked wrong block"; return 1; }
    [ "$(printf '%s\n' "$leaf" | sed -n '3p')" = "-----END CERTIFICATE-----" ] || { echo "self-test FAIL: leaf block not terminated"; return 1; }

    # Fixture 2: CSRF token parse.
    parsed=$(printf '{"ok":true,"CSRFToken":"a1b2c3","privilege":4}' |
        sed -n 's/.*"CSRFToken":"\([^"]*\)".*/\1/p')
    [ "$parsed" = "a1b2c3" ] || { echo "self-test FAIL: CSRFToken parse returned '$parsed'"; return 1; }

    # Fixture 3: CRLF from curl %{certs} must compare equal after tr -d '\r'.
    a=$(printf -- '-----BEGIN CERTIFICATE-----\r\nX\r\n-----END CERTIFICATE-----\r\n' | tr -d '\r')
    b=$(printf -- '-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----\n')
    [ "$a" = "$b" ] || { echo "self-test FAIL: CRLF normalization"; return 1; }

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
for entry in $TARGETS; do
    name=${entry%%|*}
    host=${entry#*|}
    # Subshell keeps set -e contained: one failing BMC does not stop the other.
    if (push_one "$name" "$host"); then
        :
    else
        rc=1
    fi
done
exit "$rc"
```

- [ ] **Step 2: Run the self-test** (offline; exercises fixtures 1-3)

Run: `sh kubernetes/apps/network/bmc-cert-updater/app/config/push-certs.sh --self-test`
Expected: `self-test: all fixtures passed`, exit code 0

- [ ] **Step 3: Shellcheck**

Run: `shellcheck kubernetes/apps/network/bmc-cert-updater/app/config/push-certs.sh`
Expected: no findings (SC2086 uses are suppressed inline)

- [ ] **Step 4: Add the configMapGenerator to `kustomization.yaml`** — full resulting file:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./certificate.yaml
  - ./externalsecret.yaml
  - ./ocirepository.yaml
configMapGenerator:
  - name: bmc-cert-updater
    files:
      - config/push-certs.sh
generatorOptions:
  disableNameSuffixHash: true
  annotations:
    kustomize.toolkit.fluxcd.io/substitute: disabled
```

- [ ] **Step 5: Lint and render**

Run: `yamllint --config-file .yamllint.yaml kubernetes/apps/network/bmc-cert-updater/app/kustomization.yaml`
Expected: clean pass

Run: `kustomize build kubernetes/apps/network/bmc-cert-updater/app | grep -c 'push-certs.sh'`
Expected: `2` (once as ConfigMap data key, once as the mounted file name)

- [ ] **Step 6: Commit**

```bash
git add kubernetes/apps/network/bmc-cert-updater/app/
git commit -m "feat(bmc-cert-updater): add BMC cert push script"
```

---

### Task 5: CronJob HelmRelease, CiliumNetworkPolicy, app registration

**Files:**
- Create: `kubernetes/apps/network/bmc-cert-updater/app/helmrelease.yaml`
- Create: `kubernetes/apps/network/bmc-cert-updater/app/ciliumnetworkpolicy.yaml`
- Modify: `kubernetes/apps/network/bmc-cert-updater/app/kustomization.yaml`
- Modify: `kubernetes/apps/network/kustomization.yaml`

**Interfaces:**
- Consumes: OCIRepository `bmc-cert-updater` (Task 2); Secret `internal-greyrock-io-tls` (Task 3); Secret `bmc-cert-updater-secret` (Task 3); ConfigMap `bmc-cert-updater` (Task 4).
- Produces: CronJob `bmc-cert-updater` in `network` (controller key equals release name, so the resource is named exactly `bmc-cert-updater` — verified against the recyclarr precedent). The CronJob schedule is `@daily`; `backoffLimit: 0` means a wedged BMC never gets automatic rapid retries.

- [ ] **Step 1: Create `kubernetes/apps/network/bmc-cert-updater/app/helmrelease.yaml`** with exactly this content (already sorted per the repo's sorting instructions — do not re-order):

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: bmc-cert-updater
spec:
  chartRef:
    kind: OCIRepository
    name: bmc-cert-updater
  interval: 30m
  values:
    controllers:
      bmc-cert-updater:
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
              - /script/push-certs.sh
            envFrom:
              - secretRef:
                  name: bmc-cert-updater-secret
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
        name: bmc-cert-updater
        globalMounts:
          - path: /script/push-certs.sh
            subPath: push-certs.sh
      tmp:
        type: emptyDir
        globalMounts:
          - path: /tmp
```

- [ ] **Step 2: Create `kubernetes/apps/network/bmc-cert-updater/app/ciliumnetworkpolicy.yaml`**

DNS egress to kube-dns is already allowed cluster-wide by the `allow-dns-egress` CiliumClusterwideNetworkPolicy, so this policy only grants the BMC IPs:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/cilium.io/ciliumnetworkpolicy_v2.json
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: bmc-cert-updater
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: bmc-cert-updater
      app.kubernetes.io/instance: bmc-cert-updater
  egress:
    - toCIDR:
        - 10.1.20.13/32
        - 10.1.20.11/32
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

- [ ] **Step 3: Final `kustomization.yaml`** — full resulting file:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./certificate.yaml
  - ./ciliumnetworkpolicy.yaml
  - ./externalsecret.yaml
  - ./helmrelease.yaml
  - ./ocirepository.yaml
configMapGenerator:
  - name: bmc-cert-updater
    files:
      - config/push-certs.sh
generatorOptions:
  disableNameSuffixHash: true
  annotations:
    kustomize.toolkit.fluxcd.io/substitute: disabled
```

- [ ] **Step 4: Register the app in `kubernetes/apps/network/kustomization.yaml`** — add `- ./bmc-cert-updater/ks.yaml` to `resources:` (alphabetically first). Full resulting `resources` list:

```yaml
resources:
  - ./bmc-cert-updater/ks.yaml
  - ./echo-server/ks.yaml
  - ./envoy-gateway/ks.yaml
  - ./external-dns/ks.yaml
  - ./multus/ks.yaml
  - ./towonel-agent/ks.yaml
  - ./unifi-voucher-manager/ks.yaml
```

(`namespace: network`, `components:`, and the header comment lines of that file are unchanged.)

- [ ] **Step 5: Lint and render**

Run: `yamllint --config-file .yamllint.yaml kubernetes/apps/network/bmc-cert-updater/app/helmrelease.yaml kubernetes/apps/network/bmc-cert-updater/app/ciliumnetworkpolicy.yaml kubernetes/apps/network/bmc-cert-updater/app/kustomization.yaml kubernetes/apps/network/kustomization.yaml`
Expected: clean pass

Run: `kustomize build kubernetes/apps/network > /dev/null && echo "network ns renders OK"`
Expected: `network ns renders OK`

- [ ] **Step 6: Commit**

```bash
git add kubernetes/apps/network/
git commit -m "feat(bmc-cert-updater): add cert updater CronJob"
```

---

### Task 6: Roll out and verify

**Files:** none (verification only)

**Interfaces:**
- Consumes: the pushed commits from Tasks 1-5; kubectl context `home-ops` (verified working); the `updater` admin account on both BMCs (user-provisioned; same username on both, per-BMC passwords matching the `BMC Certs` 1Password item).

**Known risk (from spec):** a bad upload can wedge the BMC web UI until `ipmitool mc reset cold` (codswallop: local, fans ramp briefly until CoolerControl re-applies duty; kerfuffle: over-LAN from codswallop). If a manual job wedges a BMC, STOP and use the runbook — do not re-run the job.

- [ ] **Step 1: Push**

Run: `git push forgejo`
Expected: push succeeds; Flux reconciles via webhook. **Do not** run `flux reconcile`/`just k8s sync-ks` — wait for the webhook.

- [ ] **Step 2: Wait for rollout and cert issuance (read-only monitoring)**

```bash
kubectl -n flux-system get kustomization bmc-cert-updater    # expect Ready: True
kubectl get clusterissuer letsencrypt-production-classic    # expect READY: True
kubectl -n network get certificate internal-greyrock-io      # expect READY: True (DNS-01 via ClouDNS, may take a couple of minutes)
kubectl -n network get secret internal-greyrock-io-tls      # expect it exists
kubectl -n network get externalsecret bmc-cert-updater       # expect SECRETSYNCED: True
kubectl -n network get cronjob bmc-cert-updater              # expect SCHEDULE: @daily
```

Note: certificate readiness may lag the rest by a few minutes (ACME DNS-01). Poll with `kubectl -n network get certificate internal-greyrock-io -w` until `READY: True`.

- [ ] **Step 3: Manual first run (the gate from the spec)**

```bash
kubectl -n network create job --from=cronjob/bmc-cert-updater bmc-cert-updater-manual-1
kubectl -n network wait --for=condition=complete --timeout=300s job/bmc-cert-updater-manual-1 \
  || kubectl -n network logs job/bmc-cert-updater-manual-1
```

Expected logs: `codswallop: certificate updated and verified` and `kerfuffle: certificate updated and verified`.
If the job fails: read the logs (`kubectl -n network logs job/bmc-cert-updater-manual-1`), fix, and only re-run after understanding the failure. If a BMC web UI becomes unreachable, stop and use the runbook above.

- [ ] **Step 4: Browser verification (user)**

Open `https://kvm-codswallop.internal.greyrock.io` and `https://kvm-kerfuffle.internal.greyrock.io` — both must show a valid Let's Encrypt cert with SAN `*.internal.greyrock.io` and no browser warning.

- [ ] **Step 5: Verify the skip-if-unchanged path**

```bash
kubectl -n network create job --from=cronjob/bmc-cert-updater bmc-cert-updater-manual-2
kubectl -n network wait --for=condition=complete --timeout=300s job/bmc-cert-updater-manual-2
kubectl -n network logs job/bmc-cert-updater-manual-2
```

Expected logs: `codswallop: certificate unchanged, skipping` and `kerfuffle: certificate unchanged, skipping`.

- [ ] **Step 6: Clean up manual jobs**

```bash
kubectl -n network delete job bmc-cert-updater-manual-1 bmc-cert-updater-manual-2
```

- [ ] **Step 7: Mark verification in the design doc** — update the `Status:` line of `docs/bmc-cert-updater/design.md` from "Approved design, pending implementation plan" to "Implemented and verified in cluster", commit as `docs(bmc-cert-updater): mark design verified`, and push with the next batch (or immediately, it is docs-only and Flux ignores it).
