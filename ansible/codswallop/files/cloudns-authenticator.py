#!/usr/bin/env python3
"""ClouDNS ACME DNS-01 authenticator for TrueNAS.

TrueNAS has no built-in ClouDNS authenticator, so this plugs into the stock
``shell`` authenticator instead of patching middleware (``/usr`` lives in the
boot environment and is replaced on every update).

Middleware invokes it twice per challenge:

    cloudns-authenticator.py set   <domain> <validation_name> <validation_content>
    cloudns-authenticator.py unset <domain> <validation_name> <validation_content>

Credentials come from a separate file (default /mnt/tank/apps/acme/cloudns.ini,
override with CLOUDNS_INI) so they never appear in argv or in this script:

    auth-id       = 12345
    auth-password = secret

``sub-auth-id`` may be used in place of ``auth-id``. Stdlib only -- the script
runs as an unprivileged user with no guaranteed site-packages.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.cloudns.net/dns"
DEFAULT_INI = "/mnt/tank/apps/acme/cloudns.ini"
TTL = 60  # ClouDNS minimum
TIMEOUT = 30


def die(msg):
    print(f"cloudns-authenticator: {msg}", file=sys.stderr)
    sys.exit(1)


def load_auth():
    """Read credentials into the dict of auth params every API call needs."""
    path = os.environ.get("CLOUDNS_INI", DEFAULT_INI)
    try:
        with open(path) as fh:
            raw = fh.read()
    except OSError as e:
        die(f"cannot read credentials from {path}: {e}")

    values = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith(("#", ";", "[")):
            continue
        key, sep, value = line.partition("=")
        if sep:
            values[key.strip().lower()] = value.strip()

    password = values.get("auth-password")
    if not password:
        die(f"'auth-password' missing from {path}")

    for key in ("auth-id", "sub-auth-id"):
        if values.get(key):
            return {key: values[key], "auth-password": password}

    die(f"one of 'auth-id' or 'sub-auth-id' must be set in {path}")


def call(endpoint, auth, **params):
    """POST to the ClouDNS API. Credentials go in the body, never the URL."""
    body = urllib.parse.urlencode({**auth, **params}).encode()
    request = urllib.request.Request(f"{API}/{endpoint}.json", data=body)
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            payload = json.loads(response.read().decode())
    except urllib.error.HTTPError as e:
        die(f"{endpoint} returned HTTP {e.code}")
    except (urllib.error.URLError, TimeoutError) as e:
        die(f"{endpoint} unreachable: {e}")
    except json.JSONDecodeError:
        die(f"{endpoint} returned a non-JSON response")

    # ClouDNS reports failures as HTTP 200 with a status field, so a bare
    # response.status check would let every error through silently.
    if isinstance(payload, dict) and payload.get("status") == "Failed":
        die(f"{endpoint}: {payload.get('statusDescription', 'unknown error')}")
    return payload


def split_zone(auth, fqdn):
    """Split _acme-challenge.foo.example.com into (host, zone).

    The zone is whichever suffix ClouDNS actually hosts, so delegated subzones
    resolve correctly rather than being assumed to be the last two labels.
    """
    labels = fqdn.rstrip(".").split(".")
    for i in range(len(labels) - 1):
        candidate = ".".join(labels[i:])
        body = urllib.parse.urlencode({**auth, "domain-name": candidate}).encode()
        request = urllib.request.Request(f"{API}/get-zone-info.json", data=body)
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                payload = json.loads(response.read().decode())
        except Exception:
            continue
        if isinstance(payload, dict) and payload.get("name") == candidate:
            return ".".join(labels[:i]), candidate

    die(f"no ClouDNS zone found for {fqdn}")


def find_records(auth, host, zone, content):
    """Return ids of TXT records at host holding exactly content."""
    records = call("records", auth, **{"domain-name": zone, "host": host, "type": "TXT"})
    if not isinstance(records, dict):
        return []
    return [
        rid
        for rid, rec in records.items()
        if rec.get("type") == "TXT"
        and rec.get("host") == host
        and rec.get("record") == content
    ]


def main():
    if len(sys.argv) != 5:
        die(f"usage: {sys.argv[0]} set|unset <domain> <validation_name> <validation_content>")

    action, _domain, validation_name, content = sys.argv[1:5]
    auth = load_auth()
    host, zone = split_zone(auth, validation_name)

    if action == "set":
        # A retried challenge would otherwise stack duplicate TXT records.
        if find_records(auth, host, zone, content):
            return
        call(
            "add-record",
            auth,
            **{
                "domain-name": zone,
                "record-type": "TXT",
                "host": host,
                "record": content,
                "ttl": TTL,
            },
        )
    elif action == "unset":
        # Cleanup runs even when the challenge failed, so an absent record is
        # a success, not an error.
        for record_id in find_records(auth, host, zone, content):
            call("delete-record", auth, **{"domain-name": zone, "record-id": record_id})
    else:
        die(f"unknown action {action!r}, expected 'set' or 'unset'")


if __name__ == "__main__":
    main()
