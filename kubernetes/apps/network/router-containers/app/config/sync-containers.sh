#!/bin/sh
# Makes the containers on office-gw run the image tags listed in
# /config/containers. Every container whose remote-image is a listed image
# with a different tag has its remote-image set over the RouterOS REST API. A container that already matches is left alone, so a
# run with nothing merged changes nothing.
#
# Containers sharing an image are updated one at a time. A container that
# answers DNS on its veth address before the update must answer again after
# it, and before any container is stopped, every other container on the same
# image that answered DNS must still be answering. That is what keeps one of
# ctrld / ctrld-b serving. Any failure ends the run.
#
# Things about RouterOS 7.24 worth knowing:
#
#   - Changing remote-image is the update. With ignore-remote-image-change=no
#     RouterOS stops the container, repulls and starts it again on its own
#     (seen in the container log, ~1s when the layers are cached). An explicit
#     repull straight after is rejected with 400 while it is busy.
#
#   - The user needs `web` and `api` as well as `rest-api`; without them every
#     /rest/container call returns 500 "not allowed (9)".
#
# Every step is checked explicitly: sync_one runs on the left of `||`, where
# `set -e` does not apply.

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
# Neither curl nor nslookup reads stdin, since both run inside `while read`
# loops.
rest() {
    method=$1
    path=$2
    shift 2
    curl -sS --fail-with-body --connect-timeout 10 --max-time 120 \
        -K "$WORK/auth" -X "$method" -H 'Content-Type: application/json' \
        "$@" "${API}${path}" < /dev/null
}

# Print one string field from a single-object JSON response.
field() {
    sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"
}

state() {
    rest GET "/container?name=$1&.proplist=.id,remote-image,running,tag"
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

answers_dns() {
    nslookup "$DNS_CHECK_NAME" "$1" < /dev/null > /dev/null 2>&1
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

# Address of a container's veth, without the prefix length.
veth_address() {
    rest GET "/interface/veth?name=$1&.proplist=address" | field 'address' | cut -d/ -f1 | cut -d, -f1
}

# Print "<name> <interface> <remote-image>" for every container on the router.
# The REST response has no trailing newline, so the last object is read too.
all_containers() {
    rest GET "/container?.proplist=name,interface,remote-image" \
        | sed 's/},{/}\n{/g' \
        | while IFS= read -r obj || [ -n "$obj" ]; do
            printf '%s %s %s\n' \
                "$(printf '%s' "$obj" | field 'name')" \
                "$(printf '%s' "$obj" | field 'interface')" \
                "$(printf '%s' "$obj" | field 'remote-image')"
        done
}

# sync_one <name> <dns address or -> <desired image:tag> <other DNS addresses>
sync_one() {
    name=$1
    dns=$2
    want=$3
    peers=$4

    current=$(state "$name") || { echo "ERROR: $name: cannot read state" >&2; return 1; }
    id=$(printf '%s' "$current" | field '\.id')
    [ -n "$id" ] || { echo "ERROR: $name: no such container on the router" >&2; return 1; }
    have=$(printf '%s' "$current" | field 'remote-image')

    if [ "$have" = "$want" ]; then
        echo "$name: already $want"
        return 0
    fi
    echo "$name: $have -> $want"

    for peer in $peers; do
        answers_dns "$peer" \
            || { echo "ERROR: $name: not updating while $peer is not answering DNS" >&2; return 1; }
    done

    # Setting remote-image is the whole update: with ignore-remote-image-change
    # off, RouterOS stops the container, repulls, and starts it again itself.
    rest PATCH "/container/$id" --data "{\"remote-image\":\"$want\"}" > /dev/null \
        || { echo "ERROR: $name: set remote-image failed" >&2; return 1; }
    echo "$name: set remote-image"

    wait_for 300 1 has_tag "$name" "$want" \
        || { echo "ERROR: $name: image tag is not $want after 5 minutes" >&2; return 1; }
    if printf '%s' "$current" | grep -q '"running":"true"'; then
        wait_for 120 1 is_running "$name" \
            || { echo "ERROR: $name: not running 2 minutes after the pull" >&2; return 1; }
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

# sync_image <image> <tag>
sync_image() {
    image=$1
    want="$1:$2"

    # Containers on this image, with the address each answers DNS on, if any.
    all_containers > "$WORK/all" || { echo "ERROR: $image: cannot list containers" >&2; return 1; }
    while read -r name iface remote; do
        [ "${remote%:*}" = "$image" ] || continue
        addr=$(veth_address "$iface") || addr=""
        if [ -n "$addr" ] && answers_dns "$addr"; then
            echo "$name $addr"
        else
            echo "$name -"
        fi
    done < "$WORK/all" > "$WORK/group"

    [ -s "$WORK/group" ] || { echo "$image: no containers on the router"; return 0; }

    while read -r name dns; do
        peers=$(awk -v self="$name" '$1 != self && $2 != "-" { print $2 }' "$WORK/group")
        sync_one "$name" "$dns" "$want" "$peers" < /dev/null || return 1
    done < "$WORK/group"
}

main() {
    : "${MIKROTIK_USERNAME:?MIKROTIK_USERNAME not set}"
    : "${MIKROTIK_PASSWORD:?MIKROTIK_PASSWORD not set}"

    WORK=$(mktemp -d)
    printf 'user = "%s:%s"\n' "$MIKROTIK_USERNAME" "$MIKROTIK_PASSWORD" > "$WORK/auth"

    # A failure ends the run rather than moving on: with one ctrld down,
    # touching the other would take DNS out entirely.
    while read -r spec; do
        case "$spec" in ''|'#'*) continue ;; esac
        sync_image "${spec%=*}" "${spec##*=}" || exit 1
    done < "$CONTAINERS_FILE"
}

main "$@"
