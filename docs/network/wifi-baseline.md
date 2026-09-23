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

### AP groups

| Group | APs | 2.4 GHz | WLANs |
| --- | --- | --- | --- |
| `indoor` | kitchen, upstairs-hallway, garage | on | all |
| `indoor-2g-disabled` | office, game-room | off | Grey Rock, Grey Rock Guest |
| `outdoor` | side-yard, rear-driveway, side-driveway | no WLANs | Grey Rock, Grey Rock Guest |

System Default has no APs.

The three 2.4 GHz radios are pinned to non-overlapping channels at 20 MHz, TX power Full:

| AP | Channel |
| --- | --- |
| `kitchen-ap` | 1 |
| `upstairs-hallway-ap` | 6 |
| `garage-ap` | 11 |

Pinning the channel on an AP forces per-AP overrides of Channelization and the channel
list as well; Unleashed does not allow overriding the channel alone.

## WLANs

| SSID | Encryption | VLAN | Bands |
| --- | --- | --- | --- |
| Grey Rock | WPA3 (SAE) | 10 | 5 / 6 GHz |
| Grey Rock IoT | WPA2 (PSK) | 10 | 2.4 GHz only |
| Grey Rock Guest | OWE, managed guest pass | 4000 | 5 / 6 GHz |

Only Grey Rock IoT uses 2.4 GHz.
Guest pass credentials come from the `Ruckus Unleashed Controller` 1Password item, which
also holds the exporter's read-only login (see
`kubernetes/apps/network/unleashed-voucher-manager`).

### Grey Rock IoT settings that differ from defaults

| Setting | Value | Why |
| --- | --- | --- |
| OFDM-Only | Enabled | keeps 802.11b rates (1–11 Mbps) off the air |
| BSS Min Rate | Disabled (floor is 6 Mbps) | |
| Inactivity Timeout | 60 min | see below |
| DTIM | 1 | wake-friendly for sleepy IoT clients |
| Directed MC/BC | Disabled | |

#### Why the Inactivity Timeout is 60 minutes

At the default 5 minutes, APs repeatedly drop IoT clients with
`[INACT] vap-N(wlan1): [<mac>]station kicked out due to excessive retries`, and each one
is offline for a few seconds while it reconnects. At 60 minutes they are not kicked.

The only cost is that a departed client lingers in the client list longer. The maximum
the field accepts is 4200 minutes.

WLAN settings can also be read and set from the CLI, which exposes fields the web UI does
not have:

```
ssh unleashed.internal.greyrock.io
en
config
wlan "Grey Rock IoT"
show
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
