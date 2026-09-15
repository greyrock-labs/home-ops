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
    # The ASRock Rack BMC writes JSON keys with a space after the colon
    # ("CSRFToken": "value") and may return "ok": 0 while still issuing a
    # usable CSRFToken + session cookie, so we treat presence of CSRFToken
    # as success and only fail when the token is genuinely absent.
    # shellcheck disable=SC2086
    response=$($CURL --cookie-jar "$jar" \
        --data-urlencode "username=$username" \
        --data-urlencode "password=$password" \
        "$base/api/session") || { echo "$name: login request failed"; return 1; }
    token=$(printf '%s' "$response" | sed -n 's/.*"CSRFToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    ok=$(printf '%s' "$response" | sed -n 's/.*"ok"[[:space:]]*:[[:space:]]*\([01]\).*/\1/p' | head -1)
    if [ -z "$token" ]; then
        echo "$name: login failed (no CSRFToken in response)"
        return 1
    fi
    if [ "$ok" = "0" ]; then
        echo "$name: BMC returned ok=0; proceeding with issued CSRFToken"
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
