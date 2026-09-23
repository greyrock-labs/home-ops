#!/bin/sh
# Makes the containers on office-gw run the images listed in /config/containers.
# For each container whose remote-image differs from the listed one it runs
# stop -> set remote-image -> repull -> start, over the RouterOS REST API.
# A container that already matches is left alone, so a run with nothing
# merged changes nothing.
#
# Containers are handled in file order, one at a time. A container listed with
# a DNS address must answer a query there before the run moves on, and any
# failure ends the run. Before a resolver is stopped, every other listed
# resolver must be answering. That is what keeps one of ctrld / ctrld-b serving.
#
# Things about RouterOS 7.24 worth knowing:
#
#   - `repull` after `set remote-image=` pulls the new tag. Verified on acme:
#     the image-id matched the registry's arm64 config digest for the new tag.
#
#   - `repull` stops a running container itself, so there is no pulling ahead
#     while it keeps serving. Downtime per container is the pull plus start;
#     the second ctrld covers it.
#
#   - A running container reports `"running":"true"`. Nothing else is treated
#     as running.
#
#   - `start` is retried until the container reports running, so an image
#     that is still extracting when the tag flips does not fail the run.
#
# Every step is checked explicitly: sync_one runs on the left of `||`, where
# `set -e` does not apply. The router's reported remote-image and tag, and a
# DNS answer where one is listed, are the only proof of success.

set -eu

CONTAINERS_FILE="${CONTAINERS_FILE:-/config/containers}"
ROUTER_HOST="${ROUTER_HOST:-office-gw.internal.greyrock.io}"
API="https://${ROUTER_HOST}/rest"
DNS_CHECK_NAME="${DNS_CHECK_NAME:-google.com}"

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

is_stopped() {
    ! is_running "$1"
}

# The tag is the registry-qualified image, e.g.
# registry-1.docker.io/neilpang/acme.sh:3.1.6.
has_tag() {
    case "$(state "$1" | field 'tag')" in
        */"$2") return 0 ;;
        *) return 1 ;;
    esac
}

answers_dns() {
    nslookup "$DNS_CHECK_NAME" "$1" > /dev/null 2>&1
}

# wait_for <tries> <seconds between> <command...>
wait_for() {
    tries=$1
    pause=$2
    shift 2
    i=0
    until "$@"; do
        i=$((i + 1))
        [ "$i" -lt "$tries" ] || return 1
        sleep "$pause"
    done
}

start_and_check() {
    ros_cmd start "$1" 2>/dev/null || true
    is_running "$2"
}

sync_one() {
    name=$1
    dns=$2
    want=$3

    current=$(state "$name") || { echo "ERROR: $name: cannot read state" >&2; return 1; }
    id=$(printf '%s' "$current" | field '\.id')
    [ -n "$id" ] || { echo "ERROR: $name: no such container on the router" >&2; return 1; }
    have=$(printf '%s' "$current" | field 'remote-image')

    if [ "$have" = "$want" ]; then
        echo "$name: already $want"
        return 0
    fi
    echo "$name: $have -> $want"

    # Never stop a resolver unless every other listed resolver is answering.
    if [ "$dns" != "-" ]; then
        for other in $DNS_ALL; do
            [ "$other" = "$dns" ] && continue
            answers_dns "$other" \
                || { echo "ERROR: $name: not updating while $other is not answering DNS" >&2; return 1; }
        done
    fi

    was_running=false
    printf '%s' "$current" | grep -q '"running":"true"' && was_running=true

    if $was_running; then
        ros_cmd stop "$id" || { echo "ERROR: $name: stop failed" >&2; return 1; }
        wait_for 60 1 is_stopped "$name" \
            || { echo "ERROR: $name: did not stop" >&2; return 1; }
        echo "$name: stopped"
    fi

    rest PATCH "/container/$id" --data "{\"remote-image\":\"$want\"}" > /dev/null \
        || { echo "ERROR: $name: set remote-image failed" >&2; return 1; }
    ros_cmd repull "$id" || { echo "ERROR: $name: repull failed" >&2; return 1; }
    echo "$name: repulling"

    wait_for 150 2 has_tag "$name" "$want" \
        || { echo "ERROR: $name: image tag is not $want after 5 minutes" >&2; return 1; }
    echo "$name: pulled"

    if $was_running; then
        wait_for 150 2 start_and_check "$id" "$name" \
            || { echo "ERROR: $name: did not start within 5 minutes" >&2; return 1; }
        echo "$name: running"
    fi

    if [ "$dns" != "-" ]; then
        wait_for 60 1 answers_dns "$dns" \
            || { echo "ERROR: $name: not answering DNS on $dns" >&2; return 1; }
        echo "$name: answering DNS on $dns"
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

    DNS_ALL=$(awk '$1 !~ /^#/ && NF == 3 && $2 != "-" { print $2 }' "$CONTAINERS_FILE")

    # A failure ends the run rather than moving on: with ctrld down, touching
    # ctrld-b would take DNS out entirely.
    while read -r name dns spec; do
        case "$name" in ''|'#'*) continue ;; esac
        image=${spec%=*}
        tag=${spec##*=}
        sync_one "$name" "$dns" "${image}:${tag}" || exit 1
    done < "$CONTAINERS_FILE"
}

main "$@"
