#!/bin/sh
# Pushes the *.internal.greyrock.io certificate to the Reolink doorbell
# (courtyard-porch-doorbell.internal.greyrock.io, 10.1.60.10) through the same
# JSON API its web UI uses: Login -> CertificateClear -> ImportCertificate ->
# Logout. Import happens only when the served leaf certificate differs from
# the desired one.
#
# Things about this firmware worth knowing:
#
#   - Reolink documents no certificate API; the calls are what the web UI
#     sends, which it hides behind client-side AES. They were lifted from
#     https://gist.github.com/velzend/895c18d533b3992f3a0cc128f27c0894
#
#   - Only RSA keys are accepted, not EC.
#
#   - Both CertificateClear and ImportCertificate restart the web server, so
#     each is followed by a wait for it to answer again. That restart also
#     drops the session: the import answers "please login first" (rspCode -6)
#     unless it logs in again after the clear.
#
#   - The file names in the import must stay server.crt / server.key. Names
#     containing the FQDN make the import fail.
#
# Every response is checked for "code": 0; the served certificate is the only
# thing trusted as proof of success, and it must validate without -k.

set -eu

CERT_FILE="${CERT_FILE:-/certs/tls.crt}"
KEY_FILE="${KEY_FILE:-/certs/tls.key}"
REOLINK_HOST="${REOLINK_HOST:-courtyard-porch-doorbell.internal.greyrock.io}"
BASE="https://${REOLINK_HOST}"
API="${BASE}/cgi-bin/api.cgi"

# shellcheck disable=SC2086
CURL="curl -k -sS --connect-timeout 10 --max-time 60"

WORK=""
TOKEN=""
# Must not end on a false test: this runs as an EXIT trap, where the status of
# its last command becomes the script's exit status. Logging out matters
# because the doorbell only holds a handful of sessions.
cleanup() {
    if [ -n "$TOKEN" ]; then
        # shellcheck disable=SC2086
        $CURL -o /dev/null "${API}?cmd=Logout&token=${TOKEN}" || true
    fi
    [ -n "$WORK" ] && rm -rf "$WORK"
    return 0
}
trap cleanup EXIT INT TERM

# Print only the first (leaf) certificate block of a PEM bundle.
first_leaf() {
    awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} f && /-----END CERTIFICATE-----/{exit}'
}

# PEM of the leaf certificate currently served. The curl call is deliberately
# not part of a pipeline, so a failed connection is an error rather than an
# empty string that compares as "different".
served_leaf() {
    # shellcheck disable=SC2086
    certs=$($CURL -o /dev/null -w '%{certs}' "$BASE/") || return 1
    [ -n "$certs" ] || return 1
    printf '%s\n' "$certs" | first_leaf | tr -d '\r'
}

desired_leaf() {
    first_leaf < "$CERT_FILE" | tr -d '\r'
}

# Escape a string for use inside a JSON string literal.
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Succeeds when the API response in file $1 carries "code": 0.
api_ok() {
    tr -d '\r\n' < "${1:?no file}" | grep -Eq '"code"[[:space:]]*:[[:space:]]*0([^0-9]|$)'
}

# POST the JSON in file $2 to command $1; the response lands in $WORK/$1.json.
api_call() {
    url="${API}?cmd=$1"
    [ -n "$TOKEN" ] && url="${url}&token=${TOKEN}"
    # shellcheck disable=SC2086
    $CURL -o "$WORK/$1.json" -H 'Content-Type: application/json' \
        --data-binary "@$2" "$url" || { echo "ERROR: $1 request failed" >&2; return 1; }
    api_ok "$WORK/$1.json" || { echo "ERROR: $1 rejected: $(cat "$WORK/$1.json")" >&2; return 1; }
}

# Wait for the web server to come back after a restart.
wait_for_web() {
    sleep 5
    i=0
    # shellcheck disable=SC2086
    until $CURL -o /dev/null "$BASE/" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -lt 24 ] || { echo "ERROR: web server did not come back" >&2; return 1; }
        sleep 5
    done
}

# Log in and set TOKEN. The request body is built once in main.
login() {
    TOKEN=""
    api_call Login "$WORK/login.req"
    TOKEN=$(tr -d '\r\n' < "$WORK/Login.json" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -n "$TOKEN" ] || { echo "ERROR: no token in Login response" >&2; exit 1; }
    echo "Logged in."
}

main() {
    : "${UPDATER_USERNAME:?UPDATER_USERNAME not set}"
    : "${REOLINK_PASSWORD:?REOLINK_PASSWORD not set}"

    want=$(desired_leaf)
    [ -n "$want" ] || { echo "ERROR: no certificate in $CERT_FILE" >&2; exit 1; }
    have=$(served_leaf) || { echo "ERROR: cannot reach $BASE" >&2; exit 1; }
    if [ "$have" = "$want" ]; then
        echo "Served certificate is already current; nothing to do."
        exit 0
    fi

    WORK=$(mktemp -d)

    printf '[{"cmd":"Login","param":{"User":{"userName":"%s","password":"%s"}}}]' \
        "$(json_escape "$UPDATER_USERNAME")" "$(json_escape "$REOLINK_PASSWORD")" > "$WORK/login.req"
    login

    printf '[{"cmd":"CertificateClear","action":0,"param":{}}]' > "$WORK/clear.req"
    api_call CertificateClear "$WORK/clear.req"
    echo "Cleared existing certificate."
    wait_for_web
    login

    crt_size=$(wc -c < "$CERT_FILE" | tr -d ' ')
    key_size=$(wc -c < "$KEY_FILE" | tr -d ' ')
    crt_b64=$(base64 -w 0 < "$CERT_FILE")
    key_b64=$(base64 -w 0 < "$KEY_FILE")
    printf '[{"cmd":"ImportCertificate","action":0,"param":{"importCertificate":{"crt":{"size":%s,"name":"server.crt","content":"%s"},"key":{"size":%s,"name":"server.key","content":"%s"}}}}]' \
        "$crt_size" "$crt_b64" "$key_size" "$key_b64" > "$WORK/import.req"
    api_call ImportCertificate "$WORK/import.req"
    echo "Imported certificate."
    wait_for_web

    have=$(served_leaf) || { echo "ERROR: cannot reach $BASE after import" >&2; exit 1; }
    [ "$have" = "$want" ] || { echo "ERROR: doorbell is not serving the new certificate" >&2; exit 1; }
    curl -sS --connect-timeout 10 --max-time 30 -o /dev/null "$BASE/" \
        || { echo "ERROR: served certificate does not validate" >&2; exit 1; }
    echo "Doorbell is serving the new certificate and it validates."
}

main "$@"
