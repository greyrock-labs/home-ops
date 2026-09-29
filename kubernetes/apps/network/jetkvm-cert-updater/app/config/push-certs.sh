#!/bin/sh
# Pushes the RSA *.internal.greyrock.io certificate to the JetKVM at
# kvm-rubberneck.internal.greyrock.io. JetKVM keeps custom TLS material at
# /userdata/jetkvm/tls/user-defined.{crt,key}, but only loads it when
# jetkvm_app starts. The firmware's BusyBox image has no service manager, so
# the script restarts only jetkvm_app after atomically replacing both files.

set -eu

CERT_FILE="${CERT_FILE:-/certs/tls.crt}"
HOST="${JETKVM_HOST:-kvm-rubberneck.internal.greyrock.io}"
IDENTITY_FILE="${IDENTITY_FILE:-/credentials/private-key}"
KEY_FILE="${KEY_FILE:-/certs/tls.key}"
SSH="ssh -i /tmp/jetkvm-identity -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/script/known_hosts"
URL="https://${HOST}"

file_hash() {
    sha256sum "$1" | awk '{print $1}'
}

installed_hashes() {
    # Query the persisted pair rather than the currently served leaf. This
    # works with the minimal SSH client image and detects full-chain changes.
    # shellcheck disable=SC2086
    hashes=$($SSH "root@${HOST}" 'sha256sum /userdata/jetkvm/tls/user-defined.crt /userdata/jetkvm/tls/user-defined.key') || return 1
    printf '%s\n' "$hashes" | awk '{print $1}'
}

status_is_healthy() {
    wget -q --spider --timeout=30 "$URL/device/status"
}

cleanup() {
    rm -f /tmp/jetkvm-identity
}
trap cleanup EXIT INT TERM

main() {
    want_cert=$(file_hash "$CERT_FILE")
    [ -n "$want_cert" ] || { echo "ERROR: no certificate in $CERT_FILE" >&2; exit 1; }
    [ -s "$KEY_FILE" ] || { echo "ERROR: no private key in $KEY_FILE" >&2; exit 1; }
    [ -s "$IDENTITY_FILE" ] || { echo "ERROR: no SSH identity in $IDENTITY_FILE" >&2; exit 1; }
    want_key=$(file_hash "$KEY_FILE")

    cp "$IDENTITY_FILE" /tmp/jetkvm-identity
    chmod 600 /tmp/jetkvm-identity

    have=$(installed_hashes) || { echo "ERROR: cannot read installed certificate hashes from $HOST" >&2; exit 1; }
    have_cert=$(printf '%s\n' "$have" | sed -n '1p')
    have_key=$(printf '%s\n' "$have" | sed -n '2p')
    if [ "$have_cert" = "$want_cert" ] && [ "$have_key" = "$want_key" ]; then
        status_is_healthy || { echo "ERROR: $URL/device/status did not validate" >&2; exit 1; }
        echo "Installed certificate is already current and validates; nothing to do."
        exit 0
    fi

    # kroniak/ssh-client deliberately ships ssh but not scp. Stream each file
    # to a temporary path over the same pinned SSH connection instead.
    # shellcheck disable=SC2086
    $SSH "root@${HOST}" 'umask 077; cat > /userdata/jetkvm/tls/user-defined.crt.new' < "$CERT_FILE"
    # shellcheck disable=SC2086
    $SSH "root@${HOST}" 'umask 077; cat > /userdata/jetkvm/tls/user-defined.key.new' < "$KEY_FILE"
    # shellcheck disable=SC2086
    $SSH "root@${HOST}" '
        # RkEnv.sh references optional variables that are unset in a
        # non-interactive SSH shell, so it is incompatible with nounset.
        set -e
        test -s /userdata/jetkvm/tls/user-defined.crt.new
        test -s /userdata/jetkvm/tls/user-defined.key.new
        chmod 644 /userdata/jetkvm/tls/user-defined.crt.new
        chmod 600 /userdata/jetkvm/tls/user-defined.key.new
        mv /userdata/jetkvm/tls/user-defined.crt.new /userdata/jetkvm/tls/user-defined.crt
        mv /userdata/jetkvm/tls/user-defined.key.new /userdata/jetkvm/tls/user-defined.key
        killall jetkvm_app
        . /etc/profile.d/RkEnv.sh
        nohup /userdata/jetkvm/bin/jetkvm_app > /userdata/jetkvm/last.log 2>&1 </dev/null &
    '

    attempt=1
    while [ "$attempt" -le 12 ]; do
        sleep 5
        if have=$(installed_hashes) && \
            [ "$(printf '%s\n' "$have" | sed -n '1p')" = "$want_cert" ] && \
            [ "$(printf '%s\n' "$have" | sed -n '2p')" = "$want_key" ] && \
            status_is_healthy; then
            echo "JetKVM is serving the new certificate and it validates."
            exit 0
        fi
        attempt=$((attempt + 1))
    done

    echo "ERROR: JetKVM did not serve the new certificate after restart" >&2
    exit 1
}

main "$@"
