#!/bin/sh
# Pushes the *.internal.greyrock.io certificate to the SuperMicro IPMI BMC
# at kvm-homeassistant.internal.greyrock.io via the BMC web API:
# login (raw name/pwd form-encoded) -> fetch cert page -> parse CSRF
# (SmcCsrfInsert("CSRF_TOKEN", "...")) -> upload cert+key with
# Origin/Referer/CSRF_TOKEN headers -> verify-after-BMC-restart.
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

    # Login (raw form-encoded name/pwd, no check field — confirmed against
    # this BMC's MegaRAC IPMI 03.95 firmware; base64+check=00 was rejected
    # by the firmware on actual probes).
    rm -f "$jar"
    # shellcheck disable=SC2086
    $CURL -c "$jar" --fail \
        --data-urlencode "name=$username" \
        --data-urlencode "pwd=$password" \
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
