# Syslog

Network gear logs to VictoriaLogs over UDP syslog at `10.1.25.44:514`, a Cilium
LoadBalancer in front of the `syslog-udp` listener on `:5140`
(`kubernetes/apps/observability/victoria-logs/`). Every record carries
`log_source=syslog`.

Currently sending: the RB5009 and all three CRS309s directly, the Unleashed APs, and the
six ICX by way of Unleashed.

## MikroTik senders

Applied 2026-09-23 to `office-gw` and all three CRS309s. `src-address` is each device's
own management address - `10.1.0.1`, `.10`, `.20`, `.30`:

```
/system logging action add name=victorialogs target=remote remote=10.1.25.44 remote-port=514 src-address=<own mgmt IP> remote-log-format=syslog syslog-facility=local0
/system logging add topics=dhcp action=victorialogs
/system logging add topics=error action=victorialogs
/system logging add topics=warning action=victorialogs
/system logging add topics=critical action=victorialogs
```

Gotchas:

- **`remote-log-format=syslog` is the one that matters.** WinBox labels it "BSD syslog" in
  the Remote Log Format dropdown; the values are `cef`/`default`/`syslog`. Left at
  `default`, RouterOS sends no PRI and no hostname, and the record lands with null
  facility, severity and app_name.
- `syslog-time-format=bsd-syslog` is a different property (Timestamp Format) and does not
  fix that. `bsd-syslog=yes` is not a valid property in RouterOS 7.
- **Without `src-address` the router identifies itself as `10.1.20.1`**, the servers SVI,
  because routing picks that interface toward the cluster. Pin it to the management
  address.
- The action name is deliberately identical on all four devices, so the configs match;
  `hostname` is what identifies the sender. That action name also becomes `app_name` for
  anything that isn't a firewall rule.

Unlike the Ruckus gear, these parse fully: `hostname` is the device identity, `facility`
is 16 (local0), and severity comes from the topic.

### Firewall logging

`office-gw` only, with `/system logging add topics=firewall action=victorialogs`. Rules
carry `log=yes` and a `log-prefix`, and **the prefix arrives as `app_name`**:

| Chain | Rule | Prefix |
| --- | --- | --- |
| input | drop invalid | `in-invalid` |
| forward | cameras: no forwarding out of vlan 60 | `cam-block` |
| forward | guest: no lan | `guest-lan` |
| forward | guest: no cameras | `guest-cam` |
| forward | drop invalid | `fwd-invalid` |
| input (v6) | drop invalid | `in6-invalid` |
| forward (v6) | drop invalid | `fwd6-invalid` |
| forward (v6) | drop packets with bad src ipv6 | `bad6-src` |
| forward (v6) | drop packets with bad dst ipv6 | `bad6-dst` |
| forward (v6) | rfc4890 drop hop-limit=1 | `rfc4890` |
| forward (v6) | guest: no lan | `guest6-lan` |
| forward (v6) | guest: no cameras | `guest6-cam` |

The WAN-facing drops are deliberately **not** logged - v4 `drop all not coming from LAN`
and `drop all from WAN not DSTNATed`, and both v6 `drop everything else not coming from
LAN` rules. That is internet background noise. The dynamic back-to-home-vpn rule cannot
be edited.

### Telling MikroTik from Ruckus

**`hostname:*` does not do it.** VictoriaLogs falls back to the source IP when a sender
omits the hostname, so the APs match it too, as `hostname="10.1.0.13"` and so on. Filter
on the names, or exclude the addresses:

```
_time:24h log_source:syslog -hostname:~"^[0-9]"          (MikroTik only)
_time:24h log_source:syslog hostname:"office-gw"
_time:24h log_source:syslog hostname:"office-gw" app_name:"cam-block"
```

`facility` does not separate them either - the APs also send local0.

## What the senders actually put on the wire

Captured with `talosctl pcap` on kerfuffle. None of it is clean RFC3164:

- **No sender includes a HOSTNAME field.** Every packet is `<PRI>timestamp tag: msg`.
  Nothing can be parsed into `hostname`.
- **ICX lines are relayed by the Unleashed master AP, not sent by the switches.** The
  master wraps each switch line in its own header, giving a double timestamp:
  `<239>Sep 22 10:55:43  Sep 22 10:55:48 garage-icx7150 MGMT Agent: ...`. The parser then
  reads `Sep` as `app_name` and yields a bogus `facility=29`. The switch name only exists
  in the message text.
- **Clocks disagree.** Some APs stamp UTC, some local time, and RFC3164 carries no zone.
- **Some APs append `\n\x00`**, and the newline split produces a separate NUL-only record
  with no facility. Others append a bare `\x00`. Some put a space after `<PRI>`.

## Listener settings

Because of the above, the listener is configured to rely on the network rather than the
header:

- `useRemoteIP` records the sender in `remote_ip`, and `streamFields: ["remote_ip"]`
  makes each sender its own stream. This is the only reliable identity.
- `useLocalTimestamp` sets `_time` to receive time; the header's value is kept in
  `timestamp`. Without it, a UTC-stamping AP parsed as `America/New_York` lands four hours
  off.
- `externalTrafficPolicy: Local` on the Service keeps the source address from being
  SNATed if the LB IP is ever announced from a node without the pod.

Consequences to keep in mind when querying:

- Relayed ICX lines carry the **master AP's** `remote_ip` - currently `office-ap`, and it
  changes if master fails over. Filter switches by message text, e.g.
  `_msg:~"garage-c08zp"`. Giving each switch its own `remote_ip` would mean pointing its
  `logging host` directly at `10.1.25.44`, which Unleashed may overwrite.
- NUL records have no ingest-side filter; exclude them with `facility:*`.

## What is useful in it

Most volume is debug-level radio and housekeeping noise: `chanflybg`, `kernel` wlan scans,
`collectd`, inter-AP `matrix`/`mosquitto`, and `APMgr` heartbeats.

The useful part is Wi-Fi client events from `hostapd` and `stamgr` - disassociate,
associate, key install, VLAN assignment and `AUTHORIZED`, each with the client MAC. A
power-cycled client produces no event when it drops (no deauth is sent); the reconnect is
what appears, starting with the AP clearing its stale entry.

All six switches used to send the same single line roughly once a minute -
`MGMT Agent: switch Registrar Query Failure. Please check DRS/SWR Registrar` - and
nothing else. Relayed through 10.1.0.13, that came to about 36,000 lines a day.

That line came from the SmartZone registrar. It stopped once `no sz registrar` / `sz disable`
went onto every ICX. The last one arrived at 2026-09-23 15:38Z, and none had arrived three
hours later.

## Storage

Syslog shares the instance's `retentionPeriod: 14d` and 20Gi `miroir-local` volume with
cluster logs. Measured 2026-09-23, after ~8 hours with every sender live:

| | 13:56Z | 20:00Z |
| --- | --- | --- |
| On disk (storage + indexdb) | 460 MB | 471 MB + 3 MB |
| Free on volume | 20.3 GB | 20.3 GB of ~21 GB |
| Syslog, 24h | 514k records / 48.9 MB raw | 523k records / 49.1 MB raw |

Syslog settles at roughly 21-24k records an hour; it peaked at 33.8k in the 14:00Z hour and
dropped once the SmartZone registrar line stopped. At ~50 MB raw a day and the ~4:1
compression seen so far, 14 days of syslog is about 175 MB on disk - under 1% of the
volume. It fits with ample room; no retention change needed.

The largest sender is the Unleashed master (10.1.0.13), about 67k records in 8 hours
including the relayed ICX lines. The other APs send 14-20k each, `office-gw` about 14.5k.

To recheck:

```
_time:24h log_source:syslog | stats count() n, sum_len(_msg) bytes
_time:24h | stats count() n, sum_len(_msg) bytes
```

plus `vl_data_size_bytes` and `vl_free_disk_space_bytes` from `/metrics`.
