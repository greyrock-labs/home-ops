# Wi-Fi baseline

Ruckus Unleashed, five APs. The master AP floats;
`unleashed.internal.greyrock.io` (10.1.20.2) follows whichever AP currently holds it, and
each AP also has its own A record under `internal.greyrock.io`. Wi-Fi clients never see that
record: Unleashed intercepts their lookups of `unleashed.internal.greyrock.io` and answers
with the master AP's own address.

Configs are not stored here. This documents the decisions
and the settings that deviate from defaults.

## APs

`show ap all` lists five APs:

| Name | IP | Model |
| --- | --- | --- |
| `office-ap` | 10.1.0.13 | R770 |
| `upstairs-hallway-ap` | 10.1.0.14 | R770 |
| `game-room-ap` | 10.1.0.23 | R770 |
| `kitchen-ap` | 10.1.0.34 | R770 |
| `garage-ap` | 10.1.0.33 | R650 |

All five are in the System Default AP group; per-AP overrides carry the 2.4 GHz settings.

### Radios

| AP | 2.4 GHz | 5 GHz | 6 GHz |
| --- | --- | --- | --- |
| `kitchen-ap` | ch 1, Full | Auto, 80 MHz, -9 dB | Auto, 160 MHz |
| `upstairs-hallway-ap` | ch 6, Full | Auto, 80 MHz, -9 dB | Auto, 160 MHz |
| `garage-ap` | ch 11, Full | Auto, 80 MHz, -9 dB | — |
| `office-ap` | off | Auto, 80 MHz, -9 dB | Auto, 160 MHz |
| `game-room-ap` | off | Auto, 80 MHz, -9 dB | Auto, 160 MHz |

ChannelFly manages 5 and 6 GHz with Channel Change Frequency 66 and the full-optimization
period at 02:00–03:00. It is off for 2.4 GHz.

#### Why 2.4 GHz is pinned

2.4 GHz has three usable channels, so three radios get one each and the other two APs carry
no 2.4 GHz WLAN. On Auto, three radios ended up sharing channel 11 at minimum power, and the
Upstairs Hallway radio reported RF pollution 34 and estimated capacity 1410, against 3 and
8666 on a clean radio. Clients stayed associated but lost 40–95% of their traffic, which broke
Matter sessions to the Kasa plugs (see
[`.agents/knowledge/matter-thread.md`](../../.agents/knowledge/matter-thread.md)).

ChannelFly would not have moved it. Outside the optimization period it only changes a
radio's channel when fewer clients are associated than the Channel Change Frequency allows
(CCF 10 per client: 60 allows changes below 6 clients), and every IoT radio has more than
that. Ruckus also recommends ChannelFly off for 2.4 GHz when clients lack 802.11h
channel-switch support, as most IoT devices do.

After an AP reboot, its 2.4 GHz WLAN takes about five minutes to come back, and clients that
moved to another AP in the meantime stay there.

## WLANs

| SSID | Encryption | VLAN | Bands |
| --- | --- | --- | --- |
| Grey Rock | WPA3 (SAE) | 10 | 5 / 6 GHz |
| Grey Rock IoT | WPA2 (PSK) | 10 | 2.4 GHz only |
| Grey Rock Guest | OWE, managed guest pass | 4000 | 5 / 6 GHz |

Only Grey Rock IoT uses 2.4 GHz.

### Grey Rock IoT settings

| Setting | Value | Why |
| --- | --- | --- |
| OFDM-Only | Enabled | keeps 802.11b rates (1–11 Mbps) off the air |
| BSS Min Rate | Default (floor is 6 Mbps) | |
| Inactivity Timeout | 60 min | see below |
| DTIM | 2 | |
| Directed MC/BC | Disabled | |
| Background Scanning | Enabled | ChannelFly needs it for 5 / 6 GHz |
| Radio Resource Management | Enabled | |
| Wi-Fi 6/7 | Enabled | |
| Application Visibility | Enabled, `No_Policy` | |
| QoS Mirroring | Enabled via Protocol | |

The CLI's `show wlan` prints `Directed Multicast= Enabled` for this WLAN while the UI's
Directed MC/BC toggle is off; they are separate settings.

#### Why the Inactivity Timeout is 60 minutes

At the default 5 minutes, APs repeatedly drop IoT clients with
`[INACT] vap-N(wlan1): [<mac>]station kicked out due to excessive retries`, and each one
is offline for a few seconds while it reconnects. At 60 minutes they are not kicked.

The only cost is that a departed client lingers in the client list longer. The maximum
the field accepts is 4200 minutes.

## CLI

`ssh unleashed.internal.greyrock.io` answers with its own `Please login:` prompt; the
username and password are in the 1Password item "Ruckus Unleashed". Key auth does not work.
`enable` needs no further password. Read-only commands worth knowing:

| Command | Shows |
| --- | --- |
| `show ap all` | every AP's radios: channel, channelization, Tx power, WLAN service |
| `show ap-group name "System Default"` | group radio defaults |
| `show wlan name "Grey Rock IoT"` | WLAN settings, including some the UI does not show |
| `show current-active-clients all` | every client: AP MAC, channel, signal, connect time, IP, hostname |
| `show performance ap-radio2-4 mac <ap mac>` | per-radio RF pollution, estimated capacity, client count |

Output pages with `--More--`; script it with `expect` and send a space on each prompt.

## Wi-Fi Calling profiles

The AP snoops DNS for each profile's hostnames to prioritise carrier ePDG traffic. Each
profile lists only hostnames that resolve:

| Profile | Hostnames |
| --- | --- |
| AT&T | `epdg.epc.att.net`, `epdg.epc.mnc410.mcc310.pub.3gppnetwork.org`, `epdg.epc.mnc280.mcc310.pub.3gppnetwork.org`, `sentitlement2.mobile.att.net`, `vvm.mobile.att.net` |
| Verizon | `wo.vzwwo.com`, `233.sub-141-207-229.myvzw.com` |
| T-Mobile | `ss.epdg.epc.geo.mnc260.mcc310.pub.3gppnetwork.org`, `epdg.epc.mnc260.mcc310.pub.3gppnetwork.org`, `crl.t-mobile.com` |
| US Cellular | `epdg.epc.mnc580.mcc311.pub.3gppnetwork.org` |
| Others | `epdg.epc.mnc006.mcc454…`, `epdg.epc.mnc001.mcc505…`, `epdg.epc.mnc002.mcc505…`, `epdg.epc.mnc720.mcc302…` (all `.pub.3gppnetwork.org`) |

There is no Sprint profile; its network is gone and its names do not resolve. The IP
column is left blank: the ePDG names rotate between addresses, so a fixed IP is stale
part of the time.

The master AP logs `stamgr ... sta is not found by dst mac <router MAC> ... FQDN-IP
wificalling, fail!` at severity error when one of these lookups is answered to the
router rather than to a wireless client.

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
- **Client MACs in AP syslog are lower case** (`3c:6a:d2:97:70:5c`), while the router's DHCP
  lines use upper case. A quoted phrase search is case-sensitive, so match MACs with a
  case-insensitive regex: `_msg:~"(?i)3c:6a:d2:97:70:5c"`. `assoc req from` lines mark each
  (re)association, which is how to tell a client that dropped off Wi-Fi from one that stayed
  associated but lost traffic.
