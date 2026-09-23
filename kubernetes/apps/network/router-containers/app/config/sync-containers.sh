#!/bin/sh
# Makes the containers on office-gw run the images listed in /config/containers.
# For each container whose remote-image differs from the listed one it runs
# stop -> set remote-image -> repull -> start, over the RouterOS REST API.
# A container that already matches is left alone, so a run with nothing
# merged changes nothing.
#
# Things about RouterOS 7.24 worth knowing:
#
#   - `repull` after `set remote-image=` pulls the new tag. Verified on acme:
#     the image-id matched the registry's arm64 config digest for the new tag.
#
#   - A running container reports `"running":"true"`. Nothing else is treated
#     as running.
#
#   - `start` is retried until the container reports running, so an image
#     that is still extracting when the tag flips does not fail the run.
#
# Every step is checked explicitly: sync_one runs on the left of `||`, where
# `set -e` does not apply. The router's reported remote-image and tag are the
# only proof of success.

set -eu

CONTAINERS_FILE="${CONTAINERS_FILE:-/config/containers}"
ROUTER_HOST="${ROUTER_HOST:-office-gw.internal.greyrock.io}"
API="https://${ROUTER_HOST}/rest"

WORK=""
cleanup() {
    [ -n "$WORK" ] && rm -rf "$WORK"
    return 0
}
trap cleanup EXIT INT TERM

# Credentials go through a curl config file so they never appear in argv.
rest() {
    method=$1
    path=$2
    shift 2
    curl -sS --fail-with-body --connect-timeout 10 --max-time 120 \
        -K "$WORK/auth" -X "$method" -H 'Content-Type: application/json' \
        "$@" "${API}${path}"
}

# Print one string field from a single-object JSON response.
field() {
    sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"
}

state() {
    rest GET "/container?name=$1&.proplist=.id,remote-image,running,tag"
}

ros_cmd() {
    rest POST "/container/$1" --data "{\"numbers\":\"$2\"}" > /dev/null
}

is_running() {
    state "$1" | grep -q '"running":"true"'
}

# The tag is the registry-qualified image, e.g.
# registry-1.docker.io/neilpang/acme.sh:3.1.6.
has_tag() {
    case "$(state "$1" | field 'tag')" in
        */"$2") return 0 ;;
        *) return 1 ;;
    esac
}

sync_one() {
    name=$1
    want=$2

    current=$(state "$name") || { echo "ERROR: $name: cannot read state" >&2; return 1; }
    id=$(printf '%s' "$current" | field '\.id')
    [ -n "$id" ] || { echo "ERROR: $name: no such container on the router" >&2; return 1; }
    have=$(printf '%s' "$current" | field 'remote-image')

    if [ "$have" = "$want" ]; then
        echo "$name: already $want"
        return 0
    fi
    echo "$name: $have -> $want"

    was_running=false
    printf '%s' "$current" | grep -q '"running":"true"' && was_running=true

    if $was_running; then
        ros_cmd stop "$id" || { echo "ERROR: $name: stop failed" >&2; return 1; }
        i=0
        while is_running "$name"; do
            i=$((i + 1))
            [ "$i" -lt 12 ] || { echo "ERROR: $name: did not stop" >&2; return 1; }
            sleep 5
        done
        echo "$name: stopped"
    fi

    rest PATCH "/container/$id" --data "{\"remote-image\":\"$want\"}" > /dev/null \
        || { echo "ERROR: $name: set remote-image failed" >&2; return 1; }
    ros_cmd repull "$id" || { echo "ERROR: $name: repull failed" >&2; return 1; }
    echo "$name: repulling"

    i=0
    until has_tag "$name" "$want"; do
        i=$((i + 1))
        [ "$i" -lt 30 ] || { echo "ERROR: $name: image tag is not $want after 5 minutes" >&2; return 1; }
        sleep 10
    done
    echo "$name: pulled"

    if $was_running; then
        i=0
        until is_running "$name"; do
            i=$((i + 1))
            [ "$i" -lt 30 ] || { echo "ERROR: $name: did not start within 5 minutes" >&2; return 1; }
            ros_cmd start "$id" 2>/dev/null || true
            sleep 10
        done
        echo "$name: running"
    fi

    [ "$(state "$name" | field 'remote-image')" = "$want" ] \
        || { echo "ERROR: $name: remote-image did not change" >&2; return 1; }
    echo "$name: now $want"
}

main() {
    : "${MIKROTIK_USERNAME:?MIKROTIK_USERNAME not set}"
    : "${MIKROTIK_PASSWORD:?MIKROTIK_PASSWORD not set}"

    WORK=$(mktemp -d)
    printf 'user = "%s:%s"\n' "$MIKROTIK_USERNAME" "$MIKROTIK_PASSWORD" > "$WORK/auth"

    failed=0
    while read -r name spec; do
        case "$name" in ''|'#'*) continue ;; esac
        image=${spec%=*}
        tag=${spec##*=}
        sync_one "$name" "${image}:${tag}" || failed=1
    done < "$CONTAINERS_FILE"

    exit "$failed"
}

main "$@"
