#!/bin/sh
# Pushes the *.internal.greyrock.io certificate to the SuperMicro IPMI BMC
# at kvm-homeassistant.internal.greyrock.io via the BMC web API:
# login (raw name/pwd) -> mandatory lang cookies -> cert page -> extract CSRF
# (SmcCsrfInsert("CSRF_TOKEN", "...")) -> upload cert+key -> trigger
# main_bmcreset (BMC web server doesn't auto-restart on cert load) ->
# verify-after-restart.
# Offline self-test: push-certs-supermicro.sh --self-test

set -eu

CERT_FILE="${CERT_FILE:-/certs/tls.crt}"
KEY_FILE="${KEY_FILE:-/certs/tls.key}"
TARGET="homeassistant|kvm-homeassistant.internal.greyrock.io"

# URLs captured by Task 1 (recon.md). Edit only if recon finds different values.
LOGIN_URL="${LOGIN_URL:-https://${TARGET#*|}/cgi/login.cgi}"
CERT_PAGE_URL="${CERT_PAGE_URL:-https://${TARGET#*|}/cgi/url_redirect.cgi?url_name=config_ssl}"
UPLOAD_URL="${UPLOAD_URL:-https://${TARGET#*|}/cgi/upload_ssl.cgi}"
RESET_URL="${RESET_URL:-https://${TARGET#*|}/cgi/BMCReset.cgi}"

CURL="curl -k -sS --connect-timeout 15 --max-time 60"

# Print only the first (leaf) certificate block of a PEM bundle on disk or stdin.
first_leaf() {
    if [ "$#" -gt 0 ]; then
        awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} f && /-----END CERTIFICATE-----/{exit}' "$1"
    else
        awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} f && /-----END CERTIFICATE-----/{exit}'
    fi
}

# PEM of the leaf certificate currently served by $1 (URL).
# The curl call is deliberately NOT part of a pipeline. A pipeline takes its
# status from the last command, so "curl | first_leaf | tr" reports success even
# when curl never connected, and an empty result compares unequal to the desired
# certificate -- which reads as "the certificate changed" and triggers a needless
# upload on nothing worse than a transient timeout.
served_leaf() {
    # shellcheck disable=SC2086
    certs=$($CURL -o /dev/null -w '%{certs}' "${1:?no url}") || return 1
    [ -n "$certs" ] || return 1
    printf '%s\n' "$certs" | first_leaf | tr -d '\r'
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
    csrf=$(grep -oE 'SmcCsrfInsert \("CSRF_TOKEN", "([^"]+)"' "$body" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    rm -f "$body"
    printf '%s' "$csrf"
}

# Trigger the BMC's main_bmcreset op (the X11 firmware's reboot endpoint).
# The cert is written to disk by /cgi/upload_ssl.cgi but the running web
# server doesn't reload it until restart; this op triggers the reload.
trigger_reset() {
    jar="$1"
    csrf="$2"
    ts=$(date -u '+%a %d %b %Y %H:%M:%S GMT')
    # shellcheck disable=SC2086
    body=$(mktemp)
    http=$($CURL -b "$jar" -w '%{http_code}' -o "$body" \
        -H "Origin: https://kvm-homeassistant.internal.greyrock.io" \
        -H "Referer: $CERT_PAGE_URL" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "CSRF_TOKEN: $csrf" \
        --data "time_stamp=$ts" --data "_=" \
        "$RESET_URL" 2>/dev/null || echo 000)
    rm -f "$body"
    printf '%s' "$http"
}

# Add the BMC's mandatory lang cookies (langSetFlag=0, language=English) to
# the cookie jar so the cert page returns the full HTML with SmcCsrfInsert
# rather than the lang-loader stub.
add_lang_cookies() {
    jar="$1"
    tmp=$(mktemp -p "$(dirname "$jar")" lang.cookies.XXXXXX)
    printf '127.0.0.1\tFALSE\t/\tFALSE\t0\tlangSetFlag\t0\n127.0.0.1\tFALSE\t/\tFALSE\t0\tlanguage\tEnglish\n' > "$tmp"
    cat "$jar" "$tmp" > "${jar}.full"
    rm -f "$tmp"
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
    # by the firmware on actual probes). The BMC webserver takes ~10-15s
    # to come up after main_bmcreset, so retry a few times with backoff
    # before giving up — covers running this script immediately after a
    # prior upload+reset on the same BMC.
    rm -f "$jar"
    login_ok=
    for attempt in 1 2 3 4 5; do
        # shellcheck disable=SC2086
        if $CURL -c "$jar" --fail \
            --data-urlencode "name=$username" \
            --data-urlencode "pwd=$password" \
            "$LOGIN_URL" >/dev/null 2>&1; then
            login_ok=1; break
        fi
        echo "$name: login attempt $attempt failed, retrying in 8s" >&2
        sleep 8
    done
    if [ -z "$login_ok" ]; then
        echo "$name: login failed after 5 attempts"
        rm -f "$jar"; return 1
    fi

    # Auth detection: the X11 firmware always issues at least the SID
    # cookie via Set-Cookie on successful login.
    if ! grep -q . "$jar" 2>/dev/null; then
        echo "$name: login failed (no session cookie issued)"
        rm -f "$jar"; return 1
    fi

    # Merge mandatory lang cookies. Without these, the cert page returns
    # the lang-loader stub and CSRF extraction returns empty.
    add_lang_cookies "$jar"
    jar_full="${jar}.full"

    # Pull CSRF from the cert page.
    csrf=$(extract_csrf "$CERT_PAGE_URL" "$jar_full")
    if [ -z "$csrf" ]; then
        echo "$name: csrf token absent on cert page"
        rm -f "$jar" "$jar_full"; return 1
    fi

    # Compare served leaf vs desired leaf.
    desired=$(desired_leaf)
    current=$(served_leaf "$base") || { echo "$name: could not fetch served certificate"; rm -f "$jar" "$jar_full"; return 1; }
    if [ "$current" = "$desired" ]; then
        echo "$name: certificate unchanged, skipping"
        rm -f "$jar" "$jar_full"; return 0
    fi

    # Upload: send CSRF as both an HTTP header and a multipart form field
    # (the X11 firmware accepts either, the community script sends both
    # for safety). Origin and Referer must match.
    # shellcheck disable=SC2086
    $CURL -b "$jar_full" --fail \
        -H "Origin: $base" \
        -H "Referer: $CERT_PAGE_URL" \
        -H "CSRF_TOKEN: $csrf" \
        -F "cert_file=@$CERT_FILE" \
        -F "key_file=@$KEY_FILE" \
        -F "CSRF_TOKEN=$csrf" \
        "$UPLOAD_URL" >/dev/null || {
        echo "$name: certificate upload failed"
        rm -f "$jar" "$jar_full"; return 1
    }

    # BMC web server doesn't auto-restart on cert load — trigger main_bmcreset.
    rh=$(trigger_reset "$jar_full" "$csrf")
    rm -f "$jar" "$jar_full"
    if [ "$rh" != "200" ]; then
        echo "$name: BMC reset request returned $rh (cert uploaded; manual reboot required)"
        return 1
    fi

    # Verify after BMC web server restart (BMC was down ~30s).
    verified=""
    i=1
    while [ "$i" -le 12 ]; do
        sleep 5
        code=$(curl -k -sS --connect-timeout 4 -o /dev/null -w '%{http_code}' "$base/" 2>/dev/null || echo down)
        [ "$code" != "200" ] && { i=$((i + 1)); continue; }
        if current=$(served_leaf "$base"); then
            [ "$current" = "$desired" ] && verified=1 && break
        fi
        i=$((i + 1))
    done
    if [ -z "$verified" ]; then
        echo "$name: reset triggered but served certificate still does not match"
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

    # An unreachable host must FAIL, not return empty output successfully.
    if CURL="curl -k -sS --connect-timeout 2 --max-time 3" served_leaf "https://192.0.2.1" >/dev/null 2>&1; then
        echo "self-test FAIL: served_leaf reported success for an unreachable host"
        rm -rf "$tmp"
        return 1
    fi

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
