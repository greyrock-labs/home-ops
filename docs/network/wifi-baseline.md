# Wi-Fi baseline

Ruckus Unleashed, eight APs, replacing UniFi in the 2026 rebuild. The master AP floats;
`unleashed.internal.greyrock.io` (10.1.20.2) follows whichever AP currently holds it, and
each AP also has its own A record under `internal.greyrock.io`.

Configs are not stored here — Unimus backs the devices up. This documents the decisions
and the settings that deviate from defaults.

## APs

| Name | IP | Model |
| --- | --- | --- |
| `office-ap` | 10.1.0.13 | R770 |
| `upstairs-hallway-ap` | 10.1.0.14 | R770 |
| `game-room-ap` | 10.1.0.23 | R770 |
| `kitchen-ap` | 10.1.0.37 | R770 |
| `garage-ap` | 10.1.0.33 | R650 |
| `side-yard-ap` | 10.1.0.35 | T750SE |
| `rear-driveway-ap` | 10.1.0.34 | T750SE |
| `side-driveway-ap` | 10.1.0.36 | T750SE |

All radios run 20 MHz on 2.4 GHz, auto channel, and 2.4 GHz TX power `Min` from the
System Default AP group. Channel assignment is left on Auto and does move.

## WLANs

| SSID | Encryption | VLAN | Bands |
| --- | --- | --- | --- |
| Grey Rock | WPA3 (SAE) | 10 | 5 / 6 GHz |
| Grey Rock IoT | WPA2 (PSK) | 10 | 2.4 GHz only |
| Grey Rock Guest | OWE, managed guest pass | 4000 | all |

Grey Rock is deliberately **off 2.4 GHz**, so the 2.4 GHz band carries only the ~59 IoT
clients. Guest pass credentials come from the `Ruckus Unleashed Controller` 1Password
item, which also holds the exporter's read-only login (see
`kubernetes/apps/network/unleashed-voucher-manager`).

### Grey Rock IoT settings that differ from defaults

| Setting | Value | Why |
| --- | --- | --- |
| OFDM-Only | Enabled | keeps 802.11b rates (1–11 Mbps) off the air |
| BSS Min Rate | Disabled (floor is 6 Mbps) | was 12 Mbps; lowered while chasing client disconnects |
| Inactivity Timeout | 30 min | was 5 min; keeps the client list stable, not a fix |
| Proxy ARP | Enabled | AP answers ARP for its clients instead of flooding the air |
| DTIM | 1 | wake-friendly for sleepy IoT clients |
| Directed MC/BC | Disabled | |

Proxy ARP is CLI-only — it has no checkbox in the web UI:

```
ssh unleashed.internal.greyrock.io
en
config
wlan "Grey Rock IoT"
proxy-arp
end
```

`show` inside `config-wlan` prints the whole WLAN config, including the passphrase in
plain text, so keep that output out of shared logs.

## Client names

Unleashed shows whatever a device calls itself, which for IoT gear means many clients
sharing one model name. Clients are renamed to descriptive names kept in a local
inventory, outside this repo. A rename sticks after the client disconnects, and the
controller holds up to 520 of them.

Renaming in bulk through the UI is slow; the same call the Save button makes can be
replayed against `/admin/_cmdstat.jsp` from a logged-in session:

```xml
<ajax-request action='docmd' xcmd='rename' updater='stamgr.<ts>.<rand>' comp='stamgr'>
  <xcmd cmd='rename' tag='client' client='<mac>' rename='<name>'/>
</ajax-request>
```

Names must be XML-escaped (`&apos;` for apostrophes). Verify afterwards with a `getstat`
request for `<client LEVEL='1' client-type='3'/>`, which returns each client's `hostname`.

## Monitoring

- **Syslog** from the APs lands in VictoriaLogs — see [syslog.md](syslog.md) for the
  pipeline and the parsing caveats. The Wi-Fi client events worth querying are
  `handle_assoc():VAP <bssid> station <mac>` (every association, logged by the master AP)
  and `STA <mac> IEEE 802.11: ... disassociated` (logged by the serving AP).
- **Metrics** come from `kubernetes/apps/observability/unleashed-exporter`, which polls
  the Unleashed AJAX API. `ruckus_vap_status` maps each BSSID to its AP, SSID and band,
  which is what turns a syslog BSSID into a name.
- **Dashboards** live in the Grafana "Ruckus Unleashed" folder: the exporter's own
  dashboard for current state and RF health, and *Ruckus Unleashed Client Events* for the
  syslog association history.
