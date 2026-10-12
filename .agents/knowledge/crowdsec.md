# CrowdSec

The setup is described in `docs/network/public-edge.md` (section CrowdSec). This note holds
what is not obvious from the manifests.

## Detection

- Envoy Gateway already writes JSON access logs to stdout by default (no `telemetry.accessLog`
  needed). `yanis-kouidri/envoy-logs` has a JSON branch that matches its field names.
- Its grok branch always fails on these lines, so `child-yanis-kouidri/envoy-logs` shows as
  many unparsed as parsed in `cscli metrics`. That is normal; check the top-level parser line.
- The access log has no request headers. Header-only probes (e.g. CVE-2025-29927's
  `x-middleware-subrequest`) are invisible to the log scenarios; only AppSec catches them.
- `crowdsecurity/appsec-default` loads `crowdsecurity/experimental-*` out-of-band. Without
  `crowdsecurity/appsec-generic-rules` installed, the AppSec pod exits at startup.
- The acquisition glob is `envoy-external-*_network_envoy-*.log` so the shutdown-manager
  container's logs are not read.

## Enforcement

- The bouncer takes the client IP from the rightmost `X-Forwarded-For` entry, which Envoy
  appends from the PROXY v2 address. Leave `trustedProxies` empty; clients cannot spoof it.
- Envoy Gateway applies the most specific SecurityPolicy only. The `crowdsec-lapi` route
  policy therefore replaces the Gateway's ext_authz on that route, and any future route-level
  SecurityPolicy on `envoy-external` would bypass CrowdSec unless it adds its own `extAuth`.
- ext_authz does run on routes with a `RequestRedirect` filter (the port-80 `https-redirect`).
- The `crowdsec-lapi` allowlist matches the PROXY v2 client address, so it is reliable
  through the tunnel. A denied request shows `rbac_access_denied_matched_policy[DENY]`.
- Every new bouncer pod IP registers as an extra `envoy@<ip>` entry on LAPI.
  `cscli bouncers delete envoy` removes all of them, including the live one; a LAPI restart
  re-registers `envoy` from `BOUNCER_KEY_envoy`.

## Console

- `ENROLL_INSTANCE_NAME` only applies to the first enrollment. To rename, run
  `cscli console enroll --overwrite --name <name> "$ENROLL_KEY"` in the LAPI pod, then accept
  it in the Console and restart LAPI.
- Manual decisions (`cscli decisions add`) are forwarded to the Console (`manual` option).
- A test alert whose source is the home WAN shows up in the Console as a "Self-Report"
  incident, because the cluster's egress address is the home WAN.

## Testing

- Do not probe from the home WAN: alerts land against your own address and are reported to
  CrowdSec. The `greyrock/home-wan` whitelist stops bans, not alerts.
- Parser and scenarios, without creating alerts: put Envoy-style JSON lines from a TEST-NET
  source (e.g. `203.0.113.50`) in a CRI-format file in the agent pod and run
  `cscli explain -f <file> -t containerd --labels program:envoy`.
- Ban test: ban `104.168.59.58` and curl a public name from the skedaddle host
  (`ssh skedaddle`), expecting 403, then delete the decision.
- Propagation to skedaddle: add a decision for a TEST-NET address and check
  `sudo ipset test <set> <address>` on skedaddle; it appears within about 10s.
- Fail-open: scale `deploy/crowdsec-bouncer` to 0, a public request still returns 200, scale
  back to 1.
- Clean up test alerts by ID (`cscli alerts delete --id <n>`). `cscli alerts delete --ip`
  can also match the blocklist alerts and delete every community decision; if that happens,
  restart LAPI (it re-pulls the blocklists on startup) and then both bouncers.
- Caddy junk filter: the `ssl_connection_error` counter for listener `0.0.0.0_8443` in
  Envoy's `/stats/prometheus` (port 19001) must not move after
  `printf garbage | nc 104.168.59.58 443`. Garbage sent straight to `10.1.25.41:443` moves the
  `0.0.0.0_10443` counter, which shows the counter works.

## Housekeeping

- Stale `envoy@<ip>` bouncer entries are harmless; leave them. Do not enable
  `db_config.flush.bouncers_autodelete`: a long tunnel outage would delete the `skedaddle`
  bouncer, and env-registered keys only come back on a LAPI restart.
