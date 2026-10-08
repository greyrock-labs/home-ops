#!/bin/sh
# Pushes the *.internal.greyrock.io certificate to the Ruckus Unleashed
# controller (login -> CSRF token -> upload cert+key -> replace-cert -> reboot).
# Upload happens only when the controller's served leaf certificate differs from
# the desired one. Offline self-test: push-certs.sh --self-test
#
# Applying a certificate reboots the controller, which drops every wireless
# client for a few minutes. That is why nothing is uploaded unless the served
# certificate actually differs -- in practice once per renewal, not once a day.
#
# Three things about this firmware are worth knowing, because none of them is
# obvious from the request/response shapes:
#
#   - Each upload is validated against whatever is ALREADY staged on the
#     controller, not against the file being sent. Uploading the certificate
#     before the matching key therefore answers "E_CertNotMatchPKey" on a first
#     run even though both files are good. Only the second upload's message
#     says anything about the pair, so only that one is worth believing.
#
#   - Login success is a 302 to dashboard.jsp. A 200 means the credentials were
#     rejected -- the body looks perfectly normal either way.
#
#   - The CSRF token arrives in an "HTTP_X_CSRF_TOKEN" response header (that is
#     the literal header name, and its value is padded with spaces), while it
#     has to be sent back as "X-CSRF-Token".

set -eu

CERT_FILE="${CERT_FILE:-/certs/tls.crt}"
KEY_FILE="${KEY_FILE:-/certs/tls.key}"
RUCKUS_HOST="${RUCKUS_HOST:-unleashed.internal.greyrock.io}"

# shellcheck disable=SC2086
CURL="curl -k -sS --connect-timeout 10 --max-time 120"

WORK=""
# Must not end on a false test: this runs as an EXIT trap, where the status of
# its last command becomes the script's exit status.
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT INT TERM

# Print only the first (leaf) certificate block of a PEM bundle.
first_leaf() {
    if [ "$#" -gt 0 ]; then
        awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} f && /-----END CERTIFICATE-----/{exit}' "$1"
    else
        awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} f && /-----END CERTIFICATE-----/{exit}'
    fi
}

# PEM of the leaf certificate currently served by $1 (URL).
#
# The curl call is deliberately NOT part of a pipeline. A pipeline takes its
# status from the last command, so "curl | first_leaf | tr" reports success even
# when curl never connected, and the caller would compare an empty string
# against the desired certificate, conclude it differs and reboot the whole
# wireless network over a transient blip.
served_leaf() {
    # shellcheck disable=SC2086
    certs=$($CURL -o /dev/null -w '%{certs}' "${1:?no url}") || return 1
    [ -n "$certs" ] || return 1
    printf '%s\n' "$certs" | first_leaf | tr -d '\r'
}

desired_leaf() {
    first_leaf "$CERT_FILE" | tr -d '\r'
}

# Value of response header $1 from the header dump $2, stripped of the padding
# the controller adds.
header_value() {
    grep -i "^${1:?no header}:" "${2:?no file}" | cut -d: -f2- | tr -d '\r\n\t ' || true
}

# The JSON "msg" field from an _upload.jsp response.
upload_msg() {
    sed -n 's/.*"msg"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${1:?no file}" | head -1
}

# A _cmdstat.jsp response carries failures as a non-empty msg="" attribute.
cmdstat_error() {
    sed -n 's/.*[^-]msg="\([^"]*\)".*/\1/p' "${1:?no file}" | head -1
}

main() {
    WORK=$(mktemp -d)
    jar="$WORK/cookies"
    username="${UPDATER_USERNAME:?UPDATER_USERNAME not set}"
    password="${RUCKUS_PASSWORD:?RUCKUS_PASSWORD not set}"
    base_url="https://$RUCKUS_HOST"

    desired=$(desired_leaf)
    current=$(served_leaf "$base_url") || { echo "could not fetch served certificate"; return 1; }
    [ -n "$current" ] || { echo "served certificate came back empty"; return 1; }
    if [ "$current" = "$desired" ]; then
        echo "controller already serves the current certificate, nothing to do"
        return 0
    fi
    echo "served certificate differs from the secret, updating"

    # Discover the login page. Unleashed answers / with a redirect to it, and
    # uses that redirect to report two states it cannot serve a login from.
    # shellcheck disable=SC2086
    $CURL -o /dev/null -D "$WORK/root.hdr" --cookie-jar "$jar" "$base_url" ||
        { echo "could not reach $RUCKUS_HOST"; return 1; }
    login_url=$(header_value Location "$WORK/root.hdr")
    case "$login_url" in
        "") echo "no login redirect from $RUCKUS_HOST"; return 1 ;;
        *//"$RUCKUS_HOST"/*) : ;;
        *) echo "redirected off-host to $login_url; set a Preferred Master or Management Interface"; return 1 ;;
    esac
    case "${login_url##*/}" in
        index.html) echo "controller is rebuilding, try again later"; return 1 ;;
        wizard.jsp) echo "controller setup wizard is not complete"; return 1 ;;
    esac
    admin_url="${login_url%/*}"

    # Login. A 302 to the dashboard is success; a 200 means bad credentials.
    # shellcheck disable=SC2086
    $CURL -o /dev/null -D "$WORK/login.hdr" --cookie "$jar" --cookie-jar "$jar" \
        --data-urlencode "username=$username" \
        --data-urlencode "password=$password" \
        --data "ok=Log+In" \
        "$login_url" || { echo "login request failed"; return 1; }
    code=$(awk 'NR==1{print $2}' "$WORK/login.hdr")
    token=$(header_value HTTP_X_CSRF_TOKEN "$WORK/login.hdr")
    if [ "$code" = "200" ]; then
        echo "login failed: credentials rejected"
        return 1
    fi
    if [ -z "$token" ]; then
        echo "login failed: no CSRF token in response (HTTP $code)"
        return 1
    fi

    # Upload the pair. Only the second message describes the pair (see header).
    upload uploadcert "$CERT_FILE" || return 1
    upload uploadprivatekey "$KEY_FILE" || return 1
    msg=$(upload_msg "$WORK/upload.json")
    case "$msg" in
        I_*) echo "controller accepted the certificate and key: $msg" ;;
        *) echo "controller rejected the certificate/key pair: ${msg:-no message}"; return 1 ;;
    esac

    # Install it. The common name is the FQDN the controller answers on; for a
    # wildcard certificate the web UI composes exactly this value.
    echo "installing certificate for $RUCKUS_HOST"
    cmdstat "<ajax-request action=\"docmd\" comp=\"system\" updater=\"rid.0.5\" xcmd=\"replace-cert\" checkAbility=\"6\" timeout=\"-1\"><xcmd cmd=\"replace-cert\" cn=\"$RUCKUS_HOST\"/></ajax-request>" ||
        return 1

    # The controller only serves the new certificate after a restart.
    echo "rebooting the controller to apply it"
    cmdstat '<ajax-request action="docmd" comp="worker" updater="rid.0.5" xcmd="cert-reboot" checkAbility="6"><xcmd cmd="cert-reboot" action="undefined"/></ajax-request>' ||
        return 1

    verify "$base_url" "$desired"
}

# upload <action> <file>; response lands in $WORK/upload.json
upload() {
    action="${1:?no action}"
    file="${2:?no file}"
    [ -f "$file" ] || { echo "missing $file"; return 1; }
    # shellcheck disable=SC2086
    $CURL --cookie "$jar" -H "X-CSRF-Token: $token" \
        -F "u=@$file;filename=$action;type=application/octet-stream" \
        -F "action=$action" \
        -F "callback=uploader_$action" \
        "$admin_url/_upload.jsp?request_type=xhr" -o "$WORK/upload.json" ||
        { echo "$action upload failed"; return 1; }
}

# cmdstat <xml>; fails when the controller reports a message back.
cmdstat() {
    # shellcheck disable=SC2086
    $CURL --cookie "$jar" -H "X-CSRF-Token: $token" \
        --data "${1:?no request}" "$admin_url/_cmdstat.jsp" -o "$WORK/cmdstat.xml" ||
        { echo "command failed to send"; return 1; }
    err=$(cmdstat_error "$WORK/cmdstat.xml")
    [ -z "$err" ] || { echo "controller refused the command: $err"; return 1; }
}

# Poll until the controller comes back serving the certificate we pushed. It
# drops off the network entirely while it restarts, so connection failures are
# expected for the first few minutes and are not treated as errors.
verify() {
    base="${1:?no url}"
    want="${2:?no cert}"
    i=1
    while [ "$i" -le 40 ]; do
        sleep 15
        if got=$(served_leaf "$base" 2>/dev/null); then
            if [ "$got" = "$want" ]; then
                echo "controller is back and serving the new certificate"
                return 0
            fi
        fi
        i=$((i + 1))
    done
    echo "controller did not come back serving the new certificate within 10m"
    return 1
}

self_test() {
    tmp=$(mktemp -d)

    # Fixture 1: fullchain with three certs - only the leaf must be extracted.
    cat >"$tmp/fullchain.pem" <<'EOF'
-----BEGIN CERTIFICATE-----
LEAFAAABBBCCC
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
INTERMEDIATEDDD
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
ROOTEEEFFF
-----END CERTIFICATE-----
EOF
    leaf=$(first_leaf "$tmp/fullchain.pem")
    lines=$(printf '%s\n' "$leaf" | wc -l | tr -d ' ')
    [ "$lines" -eq 3 ] || { echo "self-test FAIL: leaf extraction returned $lines lines"; return 1; }
    [ "$(printf '%s\n' "$leaf" | sed -n '2p')" = "LEAFAAABBBCCC" ] || { echo "self-test FAIL: leaf extraction picked wrong block"; return 1; }

    # Fixture 2: the CSRF header, with the padding the controller really sends.
    printf 'HTTP/1.1 302 Moved Temporarily\r\nLocation: https://h/admin/dashboard.jsp\r\nHTTP_X_CSRF_TOKEN:  8OSZJ1Y804\r\n\r\n' >"$tmp/login.hdr"
    t=$(header_value HTTP_X_CSRF_TOKEN "$tmp/login.hdr")
    [ "$t" = "8OSZJ1Y804" ] || { echo "self-test FAIL: CSRF parse returned '$t'"; return 1; }
    l=$(header_value Location "$tmp/login.hdr")
    [ "$l" = "https://h/admin/dashboard.jsp" ] || { echo "self-test FAIL: Location parse returned '$l'"; return 1; }

    # Fixture 3: upload messages - the error and success forms seen in practice.
    printf '{\n "msg": "E_CertNotMatchPKey",\n "cf": "uploadcert",\n "size": 5675\n}' >"$tmp/bad.json"
    [ "$(upload_msg "$tmp/bad.json")" = "E_CertNotMatchPKey" ] || { echo "self-test FAIL: error msg parse"; return 1; }
    printf '{\n "msg": "I_LoadCertOptions::I_CertWildcardCert::.internal.greyrock.io",\n "cf": "uploadprivatekey"\n}' >"$tmp/ok.json"
    case "$(upload_msg "$tmp/ok.json")" in
        I_LoadCertOptions::*) : ;;
        *) echo "self-test FAIL: success msg parse"; return 1 ;;
    esac

    # Fixture 4: cmdstat success carries no message; a failure carries one. The
    # updater="rid.0.5" attribute must not be mistaken for one.
    printf '<ajax-response><response type="object" id="rid.0.5" /></ajax-response>' >"$tmp/ok.xml"
    [ -z "$(cmdstat_error "$tmp/ok.xml")" ] || { echo "self-test FAIL: clean cmdstat read as an error"; return 1; }
    printf '<ajax-response><response type="object" id="rid.0.5"><xmsg type="0" msg="" res="Yes" /></response></ajax-response>' >"$tmp/empty.xml"
    [ -z "$(cmdstat_error "$tmp/empty.xml")" ] || { echo "self-test FAIL: empty msg read as an error"; return 1; }
    printf '<ajax-response><response><xmsg type="1" msg="E_NoPrivilege" /></response></ajax-response>' >"$tmp/err.xml"
    [ "$(cmdstat_error "$tmp/err.xml")" = "E_NoPrivilege" ] || { echo "self-test FAIL: error cmdstat not detected"; return 1; }

    # Fixture 5: an unreachable host must FAIL, not return empty successfully.
    # Getting this wrong reboots the wireless network on a transient blip.
    if CURL="curl -k -sS --connect-timeout 2 --max-time 3" served_leaf "https://192.0.2.1" >/dev/null 2>&1; then
        echo "self-test FAIL: served_leaf reported success for an unreachable host"
        return 1
    fi

    # Fixture 6: CRLF from curl %{certs} must compare equal after tr -d '\r'.
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

main
