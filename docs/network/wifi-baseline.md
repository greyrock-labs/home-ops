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

### Radios

Channels are not pinned in this build (decision 2026-11-20); Unleashed chooses them. The
previous build (October 2026) pinned every radio, set 5 GHz to 40 MHz and 6 GHz to 160 MHz,
kept 2.4 GHz on only two APs, and restricted 5 GHz to 36, 44, 52, 108, 132, 149 and 157
after radar hits on 60 and 100. The reason, in case it comes back - watch the Kasa plugs and Matter if 2.4 GHz misbehaves:

#### Why the previous build pinned 2.4 GHz

On Auto, three 2.4 GHz radios ended up sharing channel 11 at minimum
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
join; it is 5 GHz only.

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

## CLI

`ssh unleashed.internal.greyrock.io` answers with its own `Please login:` prompt; the
username and password are in the 1Password item "Ruckus Unleashed" (Infrastructure vault). Key
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
