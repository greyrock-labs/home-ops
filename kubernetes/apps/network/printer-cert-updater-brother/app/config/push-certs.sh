#!/bin/sh
# Pushes the *.internal.greyrock.io certificate to the Brother MFC-L8900CDW
# printer's web admin (brother-printer.internal.greyrock.io, 10.1.10.218).
#
# Flow mirrors justjanne/brother-client (Go): log in once and keep the session
# cookie -> list certificates -> delete our previous copies -> import the
# PKCS#12 that the initContainer builds from the TLS secret.
#
# Two things about this firmware are worth knowing, because neither is
# discoverable from the HTML and both fail silently:
#
#   - Every POST must carry a Referer header. Without one the printer answers
#     "Your request was rejected. Please try again." curl sends no Referer of
#     its own, which is why this needs setting by hand.
#
#   - The bundle must contain the leaf certificate only. A PKCS#12 carrying the
#     CA chain is refused, which is why the initContainer builds one rather than
#     using cert-manager's keystore.
#
# The "Please wait" page the import returns is not a success signal -- it comes
# back even for a request with no file attached at all. The certificate list is
# the only thing worth believing.
#
# Importing does not put a certificate into service, so this also points the
# HTTPS server at the new slot and verifies the result. That form carries every
# protocol toggle on the page, so only inputs that are genuinely checked are
# sent back -- replaying the unchecked ones would quietly switch them on.
#
# Do not assume slot numbering: deleting a certificate does not renumber the
# ones left behind, so the new slot is read back from the list rather than
# guessed, and the HTTPS selection is set explicitly every time.
#
# Offline self-test: push-certs.sh --self-test

set -eu

CERT_FILE="${CERT_FILE:-/certs/tls.crt}"
P12_FILE="${P12_FILE:-/work/cert.p12}"
PRINTER_HOST="${PRINTER_HOST:-brother-printer.internal.greyrock.io}"
# The <select> on the HTTP settings page that picks the server certificate.
# It is B15e8 on the MFC-L8900CDW; justjanne/brother-client hardcodes B12c9,
# which is what the QL series calls the same field.
CERT_SELECT_FIELD="${CERT_SELECT_FIELD:-B15e8}"
BASE="https://${PRINTER_HOST}"
WORK="${WORK:-/tmp}"

# shellcheck disable=SC2086
CURL="curl -k -sS --connect-timeout 10 --max-time 60"
JAR="$WORK/printer-cookies.txt"

# ---------------------------------------------------------------------------
# Certificate helpers
# ---------------------------------------------------------------------------

# Print only the first (leaf) certificate block of a PEM bundle.
first_leaf() {
    if [ "$#" -gt 0 ]; then
        awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} f && /-----END CERTIFICATE-----/{exit}' "$1"
    else
        awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} f && /-----END CERTIFICATE-----/{exit}'
    fi
}

desired_leaf() {
    first_leaf "$CERT_FILE" | tr -d '\r'
}

# PEM of the leaf certificate currently served by $1 (URL).
served_leaf() {
    # shellcheck disable=SC2086
    $CURL -o /dev/null -w '%{certs}' "${1:?no url}" | first_leaf | tr -d '\r'
}


# ---------------------------------------------------------------------------
# HTML form parsing
#
# Brother wraps the CSRFToken value across several CRLF-separated lines. An
# HTML tokenizer normalises CRLF to LF inside an attribute value and otherwise
# passes it through untouched, so the token MUST keep its embedded newlines --
# stripping them changes the token and the printer rejects the post.
# ---------------------------------------------------------------------------

# form_fields <html-file> <form-id> <mode> [boundary] [skip-list]
#   mode=query      -> urlencoded body (a=b&c=d)
#   mode=multipart  -> multipart parts for every non-file field
#   mode=filefield  -> name of the <input type="file"> in the form
#   mode=action     -> the form's action attribute
# skip-list is a comma separated set of field names to leave out, for fields the
# caller supplies itself.
form_fields() {
    awk -v want="$2" -v mode="$3" -v boundary="${4:-}" -v skiplist="${5:-}" '
    BEGIN {
        for (i = 32; i < 127; i++) ord[sprintf("%c", i)] = i
        ord["\n"] = 10
        ord["\t"] = 9
        ABSENT = sprintf("%c", 1)
        CRLF = sprintf("%c%c", 13, 10)
        out = ""
        sep = ""
        if (skiplist != "") {
            n = split(skiplist, parts, ",")
            for (i = 1; i <= n; i++) skip[parts[i]] = 1
        }
    }
    { buf = buf $0 "\n" }

    function urlencode(s,   res, i, c, n) {
        res = ""
        n = length(s)
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (c ~ /[A-Za-z0-9._~-]/) res = res c
            else if (c in ord) res = res sprintf("%%%02X", ord[c])
            else res = res "%3F"
        }
        return res
    }

    function attr(tag, name,   m) {
        if (match(tag, "[ \t\n]" name "=\"[^\"]*\"")) {
            m = substr(tag, RSTART, RLENGTH)
            sub("^[ \t\n]" name "=\"", "", m)
            sub("\"$", "", m)
            return m
        }
        return ABSENT
    }

    function hasattr(tag, name) {
        return match(tag, "[ \t\n]" name "([ \t\n=>]|$)") > 0
    }

    function emit(name, value) {
        if (name in skip) return
        if (mode == "query") {
            out = out sep urlencode(name) "=" urlencode(value)
            sep = "&"
        } else if (mode == "multipart") {
            printf "--%s%sContent-Disposition: form-data; name=\"%s\"%s%s%s%s",
                boundary, CRLF, name, CRLF, CRLF, value, CRLF
        }
    }

    END {
        gsub(/\r/, "", buf)

        # Locate the requested <form ...> ... </form> block.
        pos = 1
        block = ""
        while (match(substr(buf, pos), /<form[^>]*>/)) {
            tag = substr(substr(buf, pos), RSTART, RLENGTH)
            start = pos + RSTART + RLENGTH - 2
            rel = index(substr(buf, start), "</form>")
            if (rel == 0) break
            if (attr(tag, "id") == want) {
                block = substr(buf, start + 1, rel - 2)
                break
            }
            pos = start + rel
        }
        if (block == "") exit 3
        if (mode == "action") {
            act = attr(tag, "action")
            if (act != ABSENT) print act
            exit 0
        }

        # <input> elements
        p = 1
        while (match(substr(block, p), /<input[^>]*>/)) {
            tag = substr(substr(block, p), RSTART, RLENGTH)
            p = p + RSTART + RLENGTH - 1

            name = attr(tag, "name")
            if (name == ABSENT || name == "") continue
            type = attr(tag, "type")
            if (type == ABSENT) type = "text"

            if (type == "file") {
                if (mode == "filefield") print name
                continue
            }
            # Buttons carry no submitted value here, and an unchecked box is
            # simply absent from a real browser post.
            if (type == "button" || type == "reset" || type == "submit") continue
            if ((type == "checkbox" || type == "radio") && !hasattr(tag, "checked")) continue
            if (hasattr(tag, "disabled")) continue

            value = attr(tag, "value")
            if (value == ABSENT) value = (type == "checkbox") ? "on" : ""
            emit(name, value)
        }

        # <select> elements: submit the selected option, else the first one.
        p = 1
        while (match(substr(block, p), /<select[^>]*>/)) {
            tag = substr(substr(block, p), RSTART, RLENGTH)
            sstart = p + RSTART + RLENGTH - 2
            srel = index(substr(block, sstart), "</select>")
            if (srel == 0) break
            sbody = substr(block, sstart + 1, srel - 2)
            p = sstart + srel

            name = attr(tag, "name")
            if (name == ABSENT || name == "") continue

            value = ABSENT
            first = ABSENT
            q = 1
            while (match(substr(sbody, q), /<option[^>]*>/)) {
                otag = substr(substr(sbody, q), RSTART, RLENGTH)
                q = q + RSTART + RLENGTH - 1
                ovalue = attr(otag, "value")
                if (ovalue == ABSENT) ovalue = ""
                if (first == ABSENT) first = ovalue
                if (hasattr(otag, "selected")) { value = ovalue; break }
            }
            if (value == ABSENT) value = (first == ABSENT) ? "" : first
            emit(name, value)
        }

        if (mode == "query") printf "%s", out
    }
    ' "$1"
}

# Decode the numeric HTML entities Brother uses for certificate names.
decode_entities() {
    awk '
    BEGIN { for (i = 32; i < 127; i++) chr[i] = sprintf("%c", i) }
    {
        line = $0
        res = ""
        while (match(line, /&#[0-9]+;/)) {
            res = res substr(line, 1, RSTART - 1)
            code = substr(line, RSTART + 2, RLENGTH - 3) + 0
            res = res ((code in chr) ? chr[code] : "?")
            line = substr(line, RSTART + RLENGTH)
        }
        print res line
    }'
}

# ---------------------------------------------------------------------------
# Printer API
# ---------------------------------------------------------------------------

login() {
    rm -f "$JAR"
    password="${BROTHER_PASSWORD:?BROTHER_PASSWORD not set}"

    # shellcheck disable=SC2086
    $CURL --cookie-jar "$JAR" \
        --referer "$BASE/general/status.html" \
        --data-urlencode "B15bd=$password" \
        --data-urlencode "loginurl=/general/status.html" \
        -o /dev/null \
        "$BASE/general/status.html" || {
        echo "login request failed" >&2
        return 1
    }

    if ! grep -q 'AuthCookie' "$JAR" 2>/dev/null; then
        echo "login failed (wrong password?)" >&2
        return 1
    fi
}

# form_url <html-file> <form-id> <page-path>
# Resolve the form's action the way a browser would, falling back to the page
# itself when the form carries no action.
form_url() {
    action=$(form_fields "$1" "$2" action || true)
    page_dir=$(printf '%s' "$3" | sed 's|[^/]*$||')
    case "$action" in
        "") printf '%s/%s' "$BASE" "$3" ;;
        http://*|https://*) printf '%s' "$action" ;;
        /*) printf '%s%s' "$BASE" "$action" ;;
        *) printf '%s/%s%s' "$BASE" "$page_dir" "$action" ;;
    esac
}

# fetch <path> <outfile>
fetch() {
    # shellcheck disable=SC2086
    $CURL --cookie "$JAR" --cookie-jar "$JAR" -o "$2" "$BASE/$1"
}

# Print "idx<TAB>name" for every certificate in the list page ($1).
list_certs() {
    awk '
    { buf = buf $0 "\n" }
    END {
        gsub(/\r/, "", buf)
        n = split(buf, rows, "<tr")
        for (i = 2; i <= n; i++) {
            row = rows[i]
            idx = ""
            name = ""
            if (match(row, /delete\.html\?idx=[0-9]+/)) {
                idx = substr(row, RSTART, RLENGTH)
                sub(/.*idx=/, "", idx)
            }
            if (match(row, /<div class="certificateName">[^<]*/)) {
                name = substr(row, RSTART, RLENGTH)
                sub(/<div class="certificateName">/, "", name)
            }
            gsub(/<!--[^>]*-->/, "", name)
            gsub(/^[ \t\n]+|[ \t\n]+$/, "", name)
            if (idx != "") print idx "\t" name
        }
    }' "$1" | decode_entities
}

delete_cert() {
    idx="${1:?no idx}"
    page="$WORK/delete-$idx.html"
    fetch "net/security/certificate/delete.html?idx=$idx" "$page" || {
        echo "could not load delete page for idx=$idx" >&2
        return 1
    }
    body="$WORK/delete-$idx.body"
    form_fields "$page" cert_delete query >"$body" || {
        echo "could not parse cert_delete form for idx=$idx" >&2
        return 1
    }
    url=$(form_url "$page" cert_delete "net/security/certificate/delete.html?idx=$idx")
    # shellcheck disable=SC2086
    $CURL --cookie "$JAR" --cookie-jar "$JAR" \
        --referer "$BASE/net/security/certificate/delete.html?idx=$idx" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-binary "@$body" -o /dev/null \
        "$url" || {
        echo "delete post failed for idx=$idx" >&2
        return 1
    }
    rm -f "$page" "$body"
}

import_p12() {
    page="${1:?no import page}"
    file_field=$(form_fields "$page" cert_import filefield)
    [ -n "$file_field" ] || { echo "no file input in cert_import form" >&2; return 1; }

    boundary="----brotherclient$(date +%s)$$"
    body="$WORK/import.body"

    {
        form_fields "$page" cert_import multipart "$boundary" \
            "B14bc,hidden_cert_import_password"
        # import.js copies the visible password field into the hidden one.
        printf -- '--%s\r\nContent-Disposition: form-data; name="B14bc"\r\n\r\n%s\r\n' \
            "$boundary" "${BROTHER_P12_PASSWORD:-}"
        printf -- '--%s\r\nContent-Disposition: form-data; name="hidden_cert_import_password"\r\n\r\n%s\r\n' \
            "$boundary" "${BROTHER_P12_PASSWORD:-}"
        printf -- '--%s\r\nContent-Disposition: form-data; name="%s"; filename="certificate.p12"\r\nContent-Type: application/x-pkcs12\r\n\r\n' \
            "$boundary" "$file_field"
        cat "$P12_FILE"
        printf -- '\r\n--%s--\r\n' "$boundary"
    } >"$body"

    result="$WORK/import.result"
    url=$(form_url "$page" cert_import "net/security/certificate/import.html")
    # shellcheck disable=SC2086
    $CURL --cookie "$JAR" --cookie-jar "$JAR" \
        --referer "$BASE/net/security/certificate/import.html" \
        -H "Content-Type: multipart/form-data; boundary=$boundary" \
        --data-binary "@$body" -o "$result" \
        "$url" || {
        echo "import post failed" >&2
        rm -f "$body"
        return 1
    }
    rm -f "$body"

    if grep -qi 'postError\|errorMessage' "$result" 2>/dev/null; then
        echo "printer rejected the certificate bundle" >&2
        rm -f "$result"
        return 1
    fi
    rm -f "$result"
}

# Point the HTTPS server at slot $1. Two steps, as the web UI does it: post the
# settings form with the certificate selected, then commit with http_page_mode=5,
# which restarts the printer's web server.
#
# Only inputs that are actually checked are sent back. That form carries every
# protocol toggle on the page (IPP, Web Services, redirect-to-HTTPS), and
# replaying the unchecked ones would quietly switch them on.
activate_http_cert() {
    idx="${1:?no idx}"
    page="$WORK/http.html"
    fetch "net/net/certificate/http.html" "$page" || {
        echo "could not load the HTTP settings page" >&2
        return 1
    }
    url=$(form_url "$page" http_setting "net/net/certificate/http.html")

    body="$WORK/http.body"
    {
        form_fields "$page" http_setting query "" "$CERT_SELECT_FIELD" || exit 1
        printf '&%s=%s' "$CERT_SELECT_FIELD" "$idx"
    } >"$body" || {
        echo "could not parse the http_setting form" >&2
        return 1
    }

    selected="$WORK/http-selected.html"
    # shellcheck disable=SC2086
    $CURL --cookie "$JAR" --cookie-jar "$JAR" \
        --referer "$BASE/net/net/certificate/http.html" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-binary "@$body" -o "$selected" "$url" || {
        echo "selecting the certificate failed" >&2
        return 1
    }
    if grep -q 'postError' "$selected" 2>/dev/null; then
        echo "the printer rejected the certificate selection" >&2
        return 1
    fi

    # Commit. The printer answers, then restarts its web server.
    commit="$WORK/http-commit.body"
    form_fields "$selected" http_setting query | tr '&' '\n' \
        | grep -E '^(CSRFToken|pageid)=' | tr '\n' '&' >"$commit"
    printf 'http_page_mode=5' >>"$commit"

    # shellcheck disable=SC2086
    $CURL --cookie "$JAR" --cookie-jar "$JAR" \
        --referer "$BASE/net/net/certificate/http.html" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-binary "@$commit" -o /dev/null "$url" || {
        echo "committing the certificate selection failed" >&2
        return 1
    }
    rm -f "$page" "$body" "$selected" "$commit"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

push_one() {
    [ -f "$CERT_FILE" ] || { echo "missing $CERT_FILE" >&2; return 1; }
    [ -f "$P12_FILE" ] || {
        echo "missing $P12_FILE -- is keystores.pkcs12 enabled on the Certificate?" >&2
        return 1
    }

    desired=$(desired_leaf)
    [ -n "$desired" ] || { echo "no certificate in $CERT_FILE" >&2; return 1; }

    if current=$(served_leaf "$BASE") && [ -n "$current" ]; then
        if [ "$current" = "$desired" ]; then
            echo "printer already serves the current certificate, nothing to do"
            return 0
        fi
    else
        echo "warning: could not read the certificate the printer is serving" >&2
    fi

    cn="${PRINTER_CERT_NAME:?PRINTER_CERT_NAME not set}"

    login || return 1

    listpage="$WORK/certificate.html"
    fetch "net/security/certificate/certificate.html" "$listpage" || {
        echo "could not load the certificate list" >&2
        return 1
    }

    # Load and validate the import form BEFORE deleting anything, so a parsing
    # failure cannot leave the printer without our certificate.
    importpage="$WORK/import.html"
    fetch "net/security/certificate/import.html" "$importpage" || {
        echo "could not load the import page" >&2
        return 1
    }
    form_fields "$importpage" cert_import filefield | grep -q . || {
        echo "could not parse the cert_import form" >&2
        return 1
    }

    ours=$(list_certs "$listpage" | awk -F'\t' -v cn="$cn" '$2 == cn { print $1 }')
    if [ -n "$ours" ]; then
        for idx in $ours; do
            echo "removing previous copy of $cn (slot $idx)"
            delete_cert "$idx" || return 1
        done
        # Re-fetch the import page for a fresh CSRF token after the delete.
        fetch "net/security/certificate/import.html" "$importpage" || {
            echo "could not reload the import page" >&2
            return 1
        }
        fetch "net/security/certificate/certificate.html" "$listpage" || {
            echo "could not re-read the certificate list" >&2
            return 1
        }
    fi

    # Record the slots in use right before importing. The new certificate is
    # whichever slot appears afterwards -- matching on the name instead would
    # only prove that some certificate with this CN is listed, which an older
    # copy would satisfy just as well.
    before=$(list_certs "$listpage" | cut -f1 | sort -n | tr '\n' ' ')

    echo "importing $cn"
    import_p12 "$importpage" || return 1

    # Wait for a slot that was not there before the import.
    slot=""
    i=1
    while [ "$i" -le 12 ]; do
        sleep 5
        if fetch "net/security/certificate/certificate.html" "$listpage"; then
            slot=$(list_certs "$listpage" | cut -f1 | awk -v before=" $before " '
                index(before, " " $0 " ") == 0 { print; exit }')
            if [ -n "$slot" ]; then
                echo "imported $cn into slot $slot"
                break
            fi
        fi
        i=$((i + 1))
    done
    if [ -z "$slot" ]; then
        echo "import reported success but no new certificate appeared" >&2
        return 1
    fi

    echo "pointing HTTPS at slot $slot"
    activate_http_cert "$slot" || return 1

    # The web server restarts, so give it a few tries.
    i=1
    while [ "$i" -le 12 ]; do
        sleep 5
        if current=$(served_leaf "$BASE") && [ "$current" = "$desired" ]; then
            echo "printer is serving the new certificate"
            return 0
        fi
        i=$((i + 1))
    done
    echo "certificate activated but the printer is still serving the old one" >&2
    return 1
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

self_test() {
    tmp=$(mktemp -d)
    rc=0

    cat >"$tmp/fullchain.pem" <<'EOF'
-----BEGIN CERTIFICATE-----
LEAFAAABBBCCC
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
CHAINDDD EEEFFF
-----END CERTIFICATE-----
EOF
    leaf=$(first_leaf "$tmp/fullchain.pem")
    [ "$(printf '%s\n' "$leaf" | sed -n '2p')" = "LEAFAAABBBCCC" ] ||
        { echo "FAIL: leaf extraction"; rc=1; }

    # A CRLF-wrapped CSRFToken must keep its newlines, encoded as %0A.
    printf '<form id="cert_import">\r\n<input type="hidden" name="CSRFToken" value="AAAA\r\nBBBB\r\nCCCC"/>\r\n<input type="hidden" name="pageid" value="473"/>\r\n</form>\r\n' >"$tmp/csrf.html"
    got=$(form_fields "$tmp/csrf.html" cert_import query)
    case "$got" in
        *"CSRFToken=AAAA%0ABBBB%0ACCCC"*) ;;
        *) echo "FAIL: CSRFToken newlines not preserved: $got"; rc=1 ;;
    esac
    case "$got" in
        *"pageid=473"*) ;;
        *) echo "FAIL: pageid missing: $got"; rc=1 ;;
    esac

    # Only checked checkboxes are submitted, and disabled inputs never are.
    cat >"$tmp/boxes.html" <<'EOF'
<form id="http_setting">
<input type="checkbox" name="on1" value="1" checked="checked" />
<input type="checkbox" name="off1" value="1" />
<input type="checkbox" name="dis1" value="1" disabled />
<input type="submit" value="Submit" />
</form>
EOF
    got=$(form_fields "$tmp/boxes.html" http_setting query)
    [ "$got" = "on1=1" ] || { echo "FAIL: checkbox handling: '$got'"; rc=1; }

    # Forms are matched by id, not by position.
    cat >"$tmp/scope.html" <<'EOF'
<form action="/general/status.html"><input type="hidden" name="B15be" value="x"/></form>
<form id="cert_import"><input type="hidden" name="pageid" value="473"/></form>
EOF
    got=$(form_fields "$tmp/scope.html" cert_import query)
    [ "$got" = "pageid=473" ] || { echo "FAIL: form scoping: '$got'"; rc=1; }

    # <select> submits the selected option.
    cat >"$tmp/sel.html" <<'EOF'
<form id="http_setting"><select name="B15e8"><option value="0">Preset</option><option value="1" selected="selected">Ours</option></select></form>
EOF
    got=$(form_fields "$tmp/sel.html" http_setting query)
    [ "$got" = "B15e8=1" ] || { echo "FAIL: select handling: '$got'"; rc=1; }

    # File inputs are reported separately, not as ordinary fields.
    cat >"$tmp/file.html" <<'EOF'
<form id="cert_import"><input type="file" name="B14bb" value=""/><input type="hidden" name="pageid" value="473"/></form>
EOF
    [ "$(form_fields "$tmp/file.html" cert_import filefield)" = "B14bb" ] ||
        { echo "FAIL: file field detection"; rc=1; }
    [ "$(form_fields "$tmp/file.html" cert_import query)" = "pageid=473" ] ||
        { echo "FAIL: file field leaked into query"; rc=1; }

    # Certificate list parsing, including Brother numeric entities.
    cat >"$tmp/list.html" <<'EOF'
<table summary="Certificate List">
<tr class="odd"><td><div class="certificateName">&#42;&#46;internal.greyrock.io</div></td>
<td><a href="delete.html?idx=2">Delete</a></td></tr>
<tr class="even"><td><div class="certificateName">other</div></td>
<td><a href="delete.html?idx=1">Delete</a></td></tr>
</table>
EOF
    got=$(list_certs "$tmp/list.html" | tr '\t' '=' | tr '\n' ' ')
    case "$got" in
        "2=*.internal.greyrock.io 1=other "*) ;;
        *) echo "FAIL: certificate list parsing: '$got'"; rc=1 ;;
    esac

    # Form actions resolve the way a browser resolves them.
    cat >"$tmp/act.html" <<'EOF'
<form id="abs" action="/net/security/certificate/import.html"><input name="a" value="1"/></form>
<form id="rel" action="http.html"><input name="a" value="1"/></form>
<form id="none"><input name="a" value="1"/></form>
EOF
    [ "$(BASE=https://p form_url "$tmp/act.html" abs net/security/certificate/import.html)" \
        = "https://p/net/security/certificate/import.html" ] ||
        { echo "FAIL: absolute form action"; rc=1; }
    [ "$(BASE=https://p form_url "$tmp/act.html" rel net/net/certificate/http.html)" \
        = "https://p/net/net/certificate/http.html" ] ||
        { echo "FAIL: relative form action"; rc=1; }
    [ "$(BASE=https://p form_url "$tmp/act.html" none general/status.html)" \
        = "https://p/general/status.html" ] ||
        { echo "FAIL: absent form action"; rc=1; }

    # The activation commit sends only these three fields.
    cat >"$tmp/commit.html" <<'EOF'
<form id="http_setting"><input type="hidden" name="pageid" value="403"/>
<input type="hidden" name="CSRFToken" value="tok"/>
<input type="checkbox" name="B150a" value="1" checked="checked"/>
<input type="hidden" name="http_page_mode" value="0"/></form>
EOF
    got=$(form_fields "$tmp/commit.html" http_setting query | tr '&' '\n' \
        | grep -E '^(CSRFToken|pageid)=' | tr '\n' '&')
    got="${got}http_page_mode=5"
    [ "$got" = "pageid=403&CSRFToken=tok&http_page_mode=5" ] ||
        { echo "FAIL: activation commit body: '$got'"; rc=1; }

    # Overriding the certificate select drops the parsed value, not adds to it.
    cat >"$tmp/sel2.html" <<'EOF'
<form id="http_setting"><input type="hidden" name="pageid" value="403"/>
<select name="B15e8"><option value="0">Preset</option><option value="1" selected="selected">old</option></select></form>
EOF
    got=$(form_fields "$tmp/sel2.html" http_setting query "" B15e8)
    [ "$got" = "pageid=403" ] || { echo "FAIL: select skip: '$got'"; rc=1; }

    # The new slot is the one absent from the pre-import set, whatever it is
    # called. A stale copy sharing the CN must not satisfy it.
    newslot() { cut -f1 | awk -v before=" $1 " 'index(before, " " $0 " ") == 0 { print; exit }'; }
    got=$(printf '1\tx\n2\tx\n5\tx\n' | newslot "1 2")
    [ "$got" = "5" ] || { echo "FAIL: new slot detection: '$got'"; rc=1; }
    got=$(printf '2\tx\n' | newslot "1 2")
    [ -z "$got" ] || { echo "FAIL: unchanged list must yield no slot: '$got'"; rc=1; }
    got=$(printf '3\tx\n' | newslot "")
    [ "$got" = "3" ] || { echo "FAIL: empty pre-import set: '$got'"; rc=1; }
    # A slot whose number is a substring of another must not false-match.
    got=$(printf '1\tx\n2\tx\n' | newslot "1 12")
    [ "$got" = "2" ] || { echo "FAIL: substring slot match: '$got'"; rc=1; }

    # A missing form is an error, not silently empty output.
    form_fields "$tmp/scope.html" nosuchform query >/dev/null 2>&1 &&
        { echo "FAIL: missing form should fail"; rc=1; }

    rm -rf "$tmp"
    [ "$rc" -eq 0 ] && echo "self-test: all fixtures passed"
    return "$rc"
}

case "${1:-}" in
    --self-test)
        self_test
        exit $?
        ;;
esac

push_one
