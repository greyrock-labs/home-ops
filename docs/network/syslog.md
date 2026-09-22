# Syslog

Network gear logs to VictoriaLogs over UDP syslog at `10.1.25.44:514`, a Cilium
LoadBalancer in front of the `syslog-udp` listener on `:5140`
(`kubernetes/apps/observability/victoria-logs/`). Every record carries
`log_source=syslog`.

Currently sending: the Unleashed APs, and the six ICX by way of Unleashed. The RB5009 and
the CRS309s are not configured to send yet - they are not Unleashed-managed and need
their own `/system logging action`.

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
  `_msg:~"garage-icx8200"`. Giving each switch its own `remote_ip` would mean pointing its
  `logging host` directly at `10.1.25.44`, which Unleashed may overwrite.
- NUL records have no ingest-side filter; exclude them with `facility:*`.

## What is useful in it

Most volume is debug-level radio and housekeeping noise: `chanflybg`, `kernel` wlan scans,
`collectd`, inter-AP `matrix`/`mosquitto`, and `APMgr` heartbeats.

The useful part is Wi-Fi client events from `hostapd` and `stamgr` - disassociate,
associate, key install, VLAN assignment and `AUTHORIZED`, each with the client MAC. A
power-cycled client produces no event when it drops (no deauth is sent); the reconnect is
what appears, starting with the AP clearing its stale entry.

All six switches send the same single line roughly once a minute -
`MGMT Agent: switch Registrar Query Failure. Please check DRS/SWR Registrar` - and
nothing else.

## Open items

- **Confirm storage fits 14-day retention once the ingest rate is real.** Syslog shares
  the instance's `retentionPeriod: 14d` and 20Gi `miroir-local` volume with cluster logs.
  Recheck after several days, and again once MikroTik is sending.

  Baseline on 2026-09-22, retention already full back to 2026-09-08:

  | | |
  | --- | --- |
  | Compressed storage | ~506 MB (`vl_data_size_bytes{type="storage"}`) |
  | Free on volume | 20.26 GB of 20.96 GB |
  | Syslog, last hour | 3,875 rows, 345 KB of message text |
  | Everything, last hour | 59,795 rows, 8.1 MB of message text |

  Syslog was about 6% of rows and 4% of message bytes. Recheck with:

  ```
  _time:24h log_source:syslog | stats count() n, sum_len(_msg) bytes
  _time:24h | stats count() n, sum_len(_msg) bytes
  ```

  plus `vl_data_size_bytes` and `vl_free_disk_space_bytes` from `/metrics`.
