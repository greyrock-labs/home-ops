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

Channels are pinned per AP, and ChannelFly is off on every band.

| AP | 2.4 GHz (20 MHz, TX Full) | 5 GHz (40 MHz, TX -3 dB) | 6 GHz (160 MHz) |
| --- | --- | --- | --- |
| `side-yard-ap` | — | 36 | — |
| `game-room-ap` | — | 44 | 37 (33–61) |
| `kitchen-ap` | 1 | 52 (DFS) | 69 (65–93) |
| `office-ap` | — | 60 (DFS) | 133 (129–157) |
| `upstairs-hallway-ap` | 6 | 100 (DFS) | 5 (1–29) |
| `garage-ap` | 11 | 108 (DFS) | — |
| `rear-driveway-ap` | — | 149 | — |
| `side-driveway-ap` | — | 157 | — |

Every radio has its own channel. The outdoor APs are on non-DFS 5 GHz channels so a
radar event cannot move them while someone outside depends on them. 40 MHz channels 118
and 126 overlap the weather-radar band and 142 needs channel 144, so they are unused.

The four 6 GHz blocks in use are the only 160 MHz blocks AFC allows at standard power
here; the channel picker in Unleashed marks each channel "Allowed by AFC".

The planned living-room AP takes 5 GHz 134 (DFS). Its 6 GHz channel will share one of the
AFC blocks above; which one is decided when it is installed.

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
sharing one model name. Clients are renamed to descriptive names kept in the 1Password
document "Network Device MAC Addresses" (Private vault), outside this repo. A rename
sticks after the client disconnects, and the controller holds up to 520 of them.

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
