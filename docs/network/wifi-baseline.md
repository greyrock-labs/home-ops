# Wi-Fi baseline

Ruckus Unleashed 200.19, eight APs, replacing UniFi again (rebuilt 2026-11-20). The master
AP floats; `unleashed.internal.greyrock.io` (10.1.99.2) follows whichever AP currently holds
it, and each AP also has its own A record under `internal.greyrock.io`. Wi-Fi clients never see that
record: Unleashed intercepts their lookups of `unleashed.internal.greyrock.io` and answers
with the master AP's own address.

Configs are not stored here. This documents the decisions
and the settings that deviate from defaults.

## APs

All eight are on VLAN 99 with static addresses (mask /24, gateway 10.1.99.1, DNS the
ctrlds 10.1.30.2 and 10.1.30.4). Their switch ports carry VLAN 99 untagged and 10, 4000
and 4001 tagged; see [switch-baseline.md](switch-baseline.md).

| Name                  | IP         | Model  | Switch port          |
| --------------------- | ---------- | ------ | -------------------- |
| `office-ap`           | 10.1.99.13 | R770   | office-c08zp 1/1/7   |
| `upstairs-hallway-ap` | 10.1.99.14 | R770   | office-c08zp 1/1/8   |
| `game-room-ap`        | 10.1.99.23 | R770   | gameroom-c08zp 1/1/5 |
| `garage-ap`           | 10.1.99.33 | R650   | garage-c08zp 1/1/5   |
| `kitchen-ap`          | 10.1.99.34 | R770   | garage-c08zp 1/1/6   |
| `rear-driveway-ap`    | 10.1.99.35 | T750SE | garage-c08zp 1/1/1   |
| `side-yard-ap`        | 10.1.99.36 | T750SE | garage-c08zp 1/1/2   |
| `side-driveway-ap`    | 10.1.99.37 | T750SE | garage-c08zp 1/1/3   |

AFC (6 GHz standard power) uses Minimum Floor 0 and Maximum Floor 1: ground floor is 0.
Setting both to 0 disables AFC.

### AP groups

The groups and radio plan below are from the previous Unleashed build (October 2026).
Re-apply them on the rebuilt controller; they are not yet confirmed there.

| Group                | APs                                     | 2.4 GHz  | WLANs                                      |
| -------------------- | --------------------------------------- | -------- | ------------------------------------------ |
| `indoor`             | upstairs-hallway, garage                | on       | all four                                   |
| `indoor-2g-disabled` | office, game-room, kitchen              | disabled | Grey Rock, Grey Rock Guest, Grey Rock Work |
| `outdoor`            | side-yard, rear-driveway, side-driveway | disabled | Grey Rock, Grey Rock Guest, Grey Rock Work |

System Default has no APs. Each group sets 5 GHz to 40 MHz at -9 dB and 6 GHz to 160 MHz,
with the same 5 GHz channel list (below). Per-AP overrides carry the pinned channels, the
2.4 GHz settings on the two `indoor` APs, the -10 dB 5 GHz power on Upstairs Hallway and Side
Yard, and the -6 dB 5 GHz power on Office.

### Radios

Channels are pinned per AP, and ChannelFly (System Settings > Automatic Wireless
Optimization) is off on every band.

| AP                    | 2.4 GHz (20 MHz) | 5 GHz (40 MHz)   | 6 GHz (160 MHz) |
| --------------------- | ---------------- | ---------------- | --------------- |
| `upstairs-hallway-ap` | 6, -3 dB         | 149, -10 dB      | 5 (1–29)        |
| `garage-ap`           | 1, -6 dB         | 108 (DFS), -9 dB | —               |
| `office-ap`           | —                | 132 (DFS), -6 dB | 133 (129–157)   |
| `game-room-ap`        | —                | 44, -9 dB        | 37 (33–61)      |
| `kitchen-ap`          | —                | 52 (DFS), -9 dB  | 69 (65–93)      |
| `side-yard-ap`        | —                | 36, -10 dB       | —               |
| `rear-driveway-ap`    | —                | 149, -9 dB       | —               |
| `side-driveway-ap`    | —                | 157, -9 dB       | —               |

Every radio has its own channel except Upstairs Hallway and Rear Driveway, which share 5 GHz
149; they are the farthest apart. The 6 GHz blocks are the four 160 MHz blocks the channel
picker marks "Allowed by AFC".

The 5 GHz channel list (group and per-AP) allows only 36, 44, 52, 108, 132, 149 and 157, so
a radar event can only move a radio to one of those:

- 60–64 and 100–104: radar detected on 60 (Upstairs Hallway, 2026-10-24 and 10-25) and on
  99 (Office, 2026-10-22).
- 116–120 and 124–128: overlap the weather-radar band.
- 140–144: unavailable at 40 MHz.

The outdoor APs and the two indoor APs phones lean on most are on non-DFS channels.

Upstairs Hallway's 5 GHz is one step below the rest so a phone between it and Game Room
stops reassociating back and forth between them. Side Yard's 5 GHz is also at -10 dB.
Office's 5 GHz is up at -6 dB so a phone in the main bedroom stays on it instead of
switching between Office, Game Room and Side Yard; Side Yard was not lowered further because
its next step is Min and the yard coverage must not suffer.

Pinning the channel on an AP forces per-AP overrides of Channelization and the channel list
as well, and the channel list resets to every channel; re-disable the excluded ones.

#### Why 2.4 GHz is pinned

Two radios carry 2.4 GHz, each on its own channel at reduced power, and every other AP has
2.4 GHz disabled. On Auto, three radios ended up sharing channel 11 at minimum
power, and the Upstairs Hallway radio reported RF pollution 34 and estimated capacity 1410,
against 3 and 8666 on a clean radio. Clients stayed associated but lost 40–95% of their
traffic, which broke Matter sessions to the Kasa plugs.

ChannelFly would not have moved it: outside the optimization period it only changes a
channel when few clients are associated, and Ruckus recommends it off for 2.4 GHz when
clients lack 802.11h channel-switch support, as most IoT devices do.

After an AP reboot, its 2.4 GHz WLAN takes about five minutes to come back, and clients that
moved to another AP in the meantime stay there.

## WLANs

| SSID            | Encryption                     | VLAN | Bands        |
| --------------- | ------------------------------ | ---- | ------------ |
| Grey Rock       | WPA3 (SAE)                     | 10   | 5 / 6 GHz    |
| Grey Rock IoT   | WPA2 (PSK, AES), no transition | 10   | 2.4 GHz only |
| Grey Rock Work  | WPA3 (SAE)                     | 4001 | 5 / 6 GHz    |
| Grey Rock Guest | WPA2 (PSK), managed guest pass | 4000 | 5 GHz only   |

Only Grey Rock IoT uses 2.4 GHz. Guest is WPA2 rather than OWE so every guest device can
join; it is 5 GHz only. Guest is not built yet on the rebuilt controller.

Grey Rock Work exists so a work laptop gets internet before anyone signs in; the router
keeps it internet-only and hands it public DNS (see [router-baseline.md](router-baseline.md)).

### Grey Rock IoT settings

Nothing on it is older than Wi-Fi 3 (802.11g); most of it is Wi-Fi 4.

| Setting                   | Value                     | Why                                              |
| ------------------------- | ------------------------- | ------------------------------------------------ |
| OFDM-Only                 | Enabled                   | keeps 802.11b rates (1–11 Mbps) off the air      |
| BSS Min Rate              | Default (floor is 6 Mbps) |                                                  |
| Fast BSS Transition (11r) | Disabled                  | old clients mishandle it; nothing here roams     |
| Radio Resource Management | Disabled                  | no 802.11k steering for static devices           |
| Load / Band Balancing     | Disabled                  | single band, nothing to balance                  |
| PMF (802.11w)             | Disabled                  | Wi-Fi 4 clients fail to join with it required    |
| Client isolation          | Disabled                  | HA and Matter need to reach the devices directly |
| Wi-Fi 6/7                 | Disabled                  | older chipsets refuse a BSS advertising 802.11be |
| Background Scanning       | Enabled                   |                                                  |
| 802.11d                   | Enabled                   |                                                  |
| Inactivity Timeout        | 60 min                    | see below (previous build; re-apply)             |
| DTIM                      | 2                         | previous build; re-apply                         |
| Directed MC/BC            | Disabled                  | previous build; re-apply                         |

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
username and password are in the 1Password item "Ruckus Unleashed" (Private vault). Key
auth does not work.
`enable` needs no further password. Read-only commands worth knowing:

| Command                                     | Shows                                                              |
| ------------------------------------------- | ------------------------------------------------------------------ |
| `show ap all`                               | every AP's radios: channel, channelization, Tx power, WLAN service |
| `show ap-group name "System Default"`       | group radio defaults                                               |
| `show wlan name "Grey Rock IoT"`            | WLAN settings, including some the UI does not show                 |
| `show current-active-clients all`           | every client: AP MAC, channel, signal, connect time, IP, hostname  |
| `show performance ap-radio2-4 mac <ap mac>` | per-radio RF pollution, estimated capacity, client count           |

Output pages with `--More--`; script it with `expect` and send a space on each prompt.

## Wi-Fi Calling profiles

The AP snoops DNS for each profile's hostnames to prioritise carrier ePDG traffic. Each
profile lists only hostnames that resolve:

| Profile     | Hostnames                                                                                                                                                            |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| AT&T        | `epdg.epc.att.net`, `epdg.epc.mnc410.mcc310.pub.3gppnetwork.org`, `epdg.epc.mnc280.mcc310.pub.3gppnetwork.org`, `sentitlement2.mobile.att.net`, `vvm.mobile.att.net` |
| Verizon     | `wo.vzwwo.com`, `233.sub-141-207-229.myvzw.com`                                                                                                                      |
| T-Mobile    | `ss.epdg.epc.geo.mnc260.mcc310.pub.3gppnetwork.org`, `epdg.epc.mnc260.mcc310.pub.3gppnetwork.org`, `crl.t-mobile.com`                                                |
| US Cellular | `epdg.epc.mnc580.mcc311.pub.3gppnetwork.org`                                                                                                                         |
| Others      | `epdg.epc.mnc006.mcc454…`, `epdg.epc.mnc001.mcc505…`, `epdg.epc.mnc002.mcc505…`, `epdg.epc.mnc720.mcc302…` (all `.pub.3gppnetwork.org`)                              |

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

## Certificate

`wifi-cert-updater-ruckus` (`kubernetes/apps/network/wifi-cert-updater-ruckus/`) pushes the
`*.internal.greyrock.io` certificate nightly at 03:00 and reboots the controller only when
the served certificate changed. It logs in as `certupdater`, an Unleashed user with an
Admin-level role, using the `Cert Updater` 1Password item; repeated failed logins lock the
account (`API_CommonUserAdminLock`). See
[docs/wifi-cert-updater-ruckus/design.md](../wifi-cert-updater-ruckus/design.md).

## Logging

The APs and the six ICX switches log to the controller (`logging host 10.1.99.2`); there is
no central syslog listener in the cluster any more. Client MACs in AP logs are lower case
(`3c:6a:d2:97:70:5c`), while the router's DHCP log uses upper case.
