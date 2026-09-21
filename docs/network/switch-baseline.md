# Switch baseline

Reference for the 2026 network rebuild. Covers both switch families: six Ruckus ICX
running FastIron 10.0, and three MikroTik CRS309 running RouterOS 7. Records the shared
conventions, and the platform syntax that differs from the published documentation.

Configs themselves are not stored here — Unimus is the intended backup. This file
documents the *decisions* and the *gotchas*, not per-device running-configs.

## Topology

True daisy chain, RB5009 (`office-gw`, 10.1.0.1) at the head in the Office:

```
office-gw
   |
[Office CRS309 .10] -- ICX8200 .11
   |                -- ICX7150 .12
[GameRoom CRS309 .20] -- ICX8200 .21
   |                  -- ICX7150 .22
[Garage CRS309 .30] -- ICX8200 .31
                    -- ICX7150 .32
```

Garage traffic transits Game Room and Office. Routing is router-on-a-stick: all nine
switches are pure L2, the RB5009 holds every SVI. Inter-VLAN throughput is therefore
capped by the RB5009's single SFP+ and its CPU.

## VLANs

| VLAN | Name | Subnet |
| --- | --- | --- |
| 1 | Default (mgmt) | 10.1.0.0/24 |
| 10 | Internal | 10.1.10.0/24 |
| 20 | Servers | 10.1.20.0/24 |
| 50 | IoT | 10.1.50.0/24 |
| 60 | Cameras | 10.1.60.0/24 |
| 4000 | Guest | 192.168.23.0/24 |

`10.1.25.0/24` is the Cilium load-balancer pool. It is **not** a VLAN — those /32s are
BGP-announced to 10.1.0.1. The old UniFi controller required a VLAN for it; MikroTik
does not, so the migration drops it.

## Conventions

- **Trunks** carry VLAN 1 untagged and 10/20/50/60/4000 tagged. Untagged mgmt means a
  factory-default switch is reachable over its uplink before it is configured.
- **Port VLAN lists are written native-first.** `1,10,20,4000` means untagged 1, tagged
  10/20/4000.
- **Hostnames** are `<room>-icx8200` / `<room>-icx7150` — no dashes. Rooms are `office`, `gameroom`, `garage`; the router is `office-gw`. Uplink ports are named `uplink-<room>-crs309`.
- **Management** is static on `ve 1` out of 10.1.0.0/24, gateway and DNS 10.1.0.1,
  domain `internal.greyrock.io`.
- **RSTP runs on VLAN 1 only**, matching RouterOS, which runs a single instance per
  bridge rather than one per VLAN. CRS309 spines take priority 4096 / 8192 / 12288
  (Office / Game Room / Garage); every ICX leaf stays at the 32768 default.
- **NTP** points at `time1`-`time4.internal.greyrock.io` with `disable serve`, so switches
  are clients only. Hostnames resolve fine in the `server` command despite the docs only
  showing IP literals.
- **Jumbo frames on every switch.** Talos hosts run `mtu: 9000` on `bond0`
  (`kubernetes/talos/cluster.yaml.j2`). `jumbo` is global on FastIron and needs a reload.
- **IGMP/MLD snooping on every VLAN.** Exactly one active querier per VLAN in the L2
  domain — the Office ICX8200. Every other switch is `passive`.
- **Unregistered multicast floods.** Snooping otherwise prunes IPv6 link-local groups,
  which breaks Matter and HomeKit over `ff02::fb`. IPv4 mDNS (224.0.0.251) is inside
  `224.0.0.0/24` and is never pruned, so only the IPv6 side is actually at risk.
- **MLD snooping is disabled entirely on the ICX7150s.** That platform has no
  `ipv6 multicast flood-unregistered`, so its MLD snooping can only prune, never flood —
  strictly worse than no snooping for Matter. The 8200s keep MLD snooping with flooding
  enabled. The outcome is the same on both, by different means; IGMP (IPv4) snooping stays
  on everywhere.
- **Never remove** `manager registrar` (Unleashed adoption), `logging host 10.1.20.2
  udp-port 6514`, or the `snmp-server community` line.
- Unleashed and the CLI co-manage these switches; the majority of config is done by CLI.

## Verifying a switch

`show interfaces ethernet <uplink>` is the single best check — it proves the trunk and
jumbo in one shot:

```
Tagged member of 5 L2 VLANs, untagged in VLAN 1, port state is FORWARDING
MTU 10200 bytes, encapsulation ethernet
```

`jumbo` needs a reload, and `show running-config` reads identically before and after it —
so the config line alone says nothing about whether jumbo is live. `MTU 10200` is the proof.
To confirm the reload happened at all, `show version` shows
`started=warm start   reloaded=by "reload"`.

The rest, once per switch. Note that `show span` and `show 802-1w` are separate commands
for separate protocols - 802.1D and RSTP. Wanting "not configured" from one and a live
instance from the other is the same statement twice: RSTP replaced 802.1D on VLAN 1.


| Command | Want to see |
| --- | --- |
| `show running-config \| include global-stp` | nothing |
| `show span` | "not configured" on every VLAN - this command reports 802.1D only |
| `show 802-1w` | the RSTP counterpart: VLAN 1 only, bridge ID starting `8000`, uplink ROOT/FORWARDING |
| `show ip multicast` | all VLANs `cfg V3`, `vlan cfg passive` (active on the Office 8200), Flooding Enabled |
| `show ipv6 multicast` | 8200s: `dft V2`, Flooding Enabled. 7150s: no VLANs listed at all |
| `show ntp status` | synchronized, server mode disabled, client mode enabled |

## Unleashed APs

Static addresses, assigned in the same room blocks as the switches: each room gets a /24
slice of 10.1.0.0/24 where the switches take the low numbers and the APs run up from `.3`.

| AP | Address | Room block |
| --- | --- | --- |
| `office-ap` | 10.1.0.13 | Office (.10-.19) |
| `upstairs-hallway-ap` | 10.1.0.14 | Office |
| `gameroom-ap` | 10.1.0.23 | Game Room (.20-.29) |
| `livingroom-ap` | 10.1.0.24 | Game Room |
| `garage-ap` | 10.1.0.33 | Garage (.30-.39) |
| `rear-driveway-ap` | 10.1.0.34 | Garage |
| `side-yard-ap` | 10.1.0.35 | Garage |
| `side-driveway-ap` | 10.1.0.36 | Garage |
| `kitchen-ap` | 10.1.0.37 | Garage |

The block is the address range, not the physical room - `kitchen-ap` and the driveway and
side-yard APs all home to the Garage stack.

10.1.20.2 (`unleashed.internal.greyrock.io`) is the Unleashed management interface, not a
device. The controller role runs on whichever AP currently holds master, and the
management address floats to it, so it stays reachable without knowing which AP that is.
AP-to-switch-port mapping lives in Unleashed and is not duplicated here.

## Unleashed config drift

These switches carry `manager registrar` and are co-managed. Unleashed re-asserts parts of
its own template, so some CLI settings revert across a reboot. Observed on both the Office
ICX8200 and the Garage ICX7150 after reload, having been verified absent beforehand:

| Setting | Reverts to | Impact |
| --- | --- | --- |
| `global-stp` | re-added | **None.** Verified inert: `show span` still reports "not configured" on every VLAN and RSTP keeps VLAN 1. Cosmetic only. |
| `cli timeout 240` | `cli timeout 0` | Cosmetic - no idle timeout. |
| `snmp-server community` | an extra community appended | Seen on the Garage ICX7150 only. Leave both in place. |

Decision: do not fight the template. `global-stp` does nothing here, so re-clear it if you
care about a tidy config and otherwise ignore it. What matters is that none of the
functional config - VLANs, trunks, RSTP, multicast, jumbo, static addressing, NTP - drifted.

## FastIron 10.0 gotchas

Each of these cost a round trip on the first switch. The published docs describe the
08.0.x/09.0.x behaviour and are wrong for 10.0.

| Doing this | Actual 10.0 behaviour |
| --- | --- |
| `no ip dhcp-client enable` | Rejected. Use `ip dhcp-client disable`. |
| Removing the per-VE binding first | Refused while the client is on globally. Disable globally, *then* `no ip dhcp-client ve default`, *then* set the static address. |
| `dual-mode` / `dual-mode 1` | Deprecated since 08.0.80. Unnecessary — a port tagged into other VLANs keeps its untagged VLAN 1 membership. Verify with `Tag=Yes, Pvid=1`. |
| `no ip multicast disable-flooding` | Deprecated. Use `ip multicast flood-unregistered` and `ipv6 multicast flood-unregistered`. The IPv6 form of `disable-flooding` does not exist at all. |
| A global command after a `vlan`/`interface` stanza | Silently ignored or misfiled into the sub-context. `no global-stp` landed nowhere; `no ip dhcp-client enable` was written into an interface. **Always `exit` to global config first.** |
| `no global-stp` before VLAN 1 is on 802.1w | Silently does not stick. Removal only takes once `spanning-tree 802-1w` is active on VLAN 1, so sequence it *after* the VLAN 1 stanza. Confirm with `show running-config | include global-stp` printing nothing. |
| `ipv6 mld version 2` | Accepted without error but **silently unreliable** — it applied on two units and left a third on MLDv1. Use the canonical `ipv6 multicast version 2` instead, and verify with `show ipv6 multicast`: want `Version=2`, `dft V2` and `(SG)` caches, not `V1` / `(*G)`. |
| `ipv6 multicast flood-unregistered` on an ICX7150 | `Invalid input` / `Soft pkg not supported`. The keyword does not exist on that platform — confirmed against `ipv6 multicast ?`, which offers only active/passive/version/timers. Works fine on the ICX8200. |
| `global-rstp` | Does not exist. 802.1w is per-VLAN: `spanning-tree 802-1w`. Remove `global-stp`, and `no spanning-tree` on the VLAN before enabling 802.1w. |
| `spanning-tree 802-1w priority 32768` | Accepted but absent from running-config, because it equals the default. Confirm via the bridge ID in `show 802-1w` — a leading `8000` is 32768. |
| `enable` at a `#` prompt | Rejected; already privileged. Needed only after a reload, which drops you to `>`. |
| `?` in a pasted block | Swallowed. Help queries must be typed by hand. |

## Office ICX8200 as-built

ICX8200-C08ZP, FastIron `10.0.10g_cd6T253`, 8x 2.5G PoE (`1/1/1`-`1/1/8`) plus 2x SFP+
(`1/2/1`, `1/2/2`). `show stack` reports stacking disabled, so the default `stack-port`
lines on both SFP+ ports are inert and `1/2/2` works as an ordinary data port.

Uplink `1/2/2` to the Office CRS309. This switch is the **active** IGMP/MLD querier for
all six VLANs; PoE allocation is dynamic; 240W budget.

| Port | Name | Untagged | Tagged |
| --- | --- | --- | --- |
| 1/1/5 | office-ap | 1 | 10, 20, 4000 |
| 1/1/6 | uh-ap | 1 | 10, 20, 4000 |
| 1/1/7 | codswallop | 20 | - |
| 1/1/8 | kerfuffle | 20 | 10, 60 |

`codswallop` and `kerfuffle` are Talos control-plane hosts. Their `bond0` is
`active-backup` over a single link, **not** LACP, so they take plain access ports with
no LAG. Both take their VLAN 20 address by DHCP and resolve against 10.1.20.1.

## Game Room ICX8200 as-built

Identical hardware and firmware to the Office box. `show version` additionally reports
`Current License: 2X25G` and module `ICX8200-2X25G`, so the SFP+ ports are 25G-capable —
relevant if the Office-Game Room hop, which also carries Garage traffic, ever saturates.

Uplink `1/2/2` to the Game Room CRS309. IGMP/MLD **passive** on all six VLANs.

| Port | Name | Untagged | Tagged |
| --- | --- | --- | --- |
| 1/1/1 | andys-desktop | 10 | - |
| 1/1/5 | todds-desktop | 10 | - |
| 1/1/7 | game-room-ap | 1 | 10, 20, 4000 |
| 1/1/8 | lr-ap | 1 | 10, 20, 4000 |

`1/1/6` is unused.

## Garage ICX8200 as-built

Same model and firmware as the other two, but the only one with the full L3 package:
`ICX8200_L3_SOFT_PACKAGE`, license `2X25GR`, against `ICX8200_BASE_L3_SOFT_PACKAGE` /
`2X25G` elsewhere. If L3 ever moves down from the RB5009, this is the licensed unit.

Uplink `1/2/2` to the Garage CRS309. IGMP/MLD **passive** on all six VLANs. Heaviest PoE
load of the three: five APs against a 240W budget, dynamic allocation.

| Port | Name | Untagged | Tagged |
| --- | --- | --- | --- |
| 1/1/1 | garage-ap | 1 | 10, 20, 4000 |
| 1/1/2 | rd-ap | 1 | 10, 20, 4000 |
| 1/1/3 | sy-ap | 1 | 10, 20, 4000 |
| 1/1/4 | sd-ap | 1 | 10, 20, 4000 |
| 1/1/5 | kitchen-ap | 1 | 10, 20, 4000 |

## Garage ICX7150 as-built

ICX7150-C12-POE, FastIron `10.0.10g_cd6T213`, `ICX7150_L3_SOFT_PACKAGE`, license `2X10GR`.
Three modules, so the port map differs from the 8200s:

- `1/1/1`-`1/1/12` - 12x 1G PoE
- `1/2/1`-`1/2/2` - 2x 1G copper (`ICX7150-2X1GC`)
- `1/3/1`-`1/3/2` - 2x 10G SFP+ (`ICX7150-2X10GF`)

Uplink `1/3/2` to the Garage CRS309. Stacking confirmed inactive, so the default
`stack-port` claim on `1/3/1`-`1/3/2` is inert. IGMP passive; **MLD snooping removed**
(see Conventions).

| Port | Name | Untagged | Tagged |
| --- | --- | --- | --- |
| 1/1/1 | courtyard-doorbell | 60 | - |
| 1/1/2 | garage-todd | 60 | - |
| 1/1/3 | rear-driveway | 60 | - |
| 1/1/4 | rear-side-yard | 60 | - |
| 1/1/6 | garage-andy | 60 | - |

`1/1/5` and `1/1/7`-`1/1/12` are unused.

## Game Room ICX7150 as-built

Same hardware, firmware and module layout as the Garage ICX7150. Uplink `1/3/2` to the
Game Room CRS309. IGMP passive; MLD snooping not configured.

| Port | Name | Untagged | Tagged |
| --- | --- | --- | --- |
| 1/1/1 | solaredge | 50 | - |
| 1/1/2 | zigbee | 10 | - |

`1/1/3`-`1/1/12` are unused.

## Office ICX7150 as-built

Same hardware, firmware and module layout as the other two 7150s. Uplink `1/3/2` to the
Office CRS309. IGMP passive; MLD snooping not configured.

| Port | Name | Untagged |
| --- | --- | --- |
| 1/1/1 | time1 | 20 |
| 1/1/2 | time2 | 20 |
| 1/1/3 | time3 | 20 |
| 1/1/4 | time4 | 20 |
| 1/1/5 | ai-port | 60 |
| 1/1/7 | kvm-hass | 20 |
| 1/1/8 | homeassistant | 10 |
| 1/1/9 | kvm-nas | 20 |
| 1/1/11 | ai-key | 60 |
| 1/1/12 | chime | 60 |
| 1/2/1 | kvm-k8s | 20 |
| 1/3/1 | nvr | 60 |

`1/1/6`, `1/1/10` and `1/2/2` are unused. The front-panel "port 13" is `1/2/1`, the first
copper uplink on module 2 - the PoE module only goes to `1/1/12`.

`1/3/1` carries the NVR at 10G on VLAN 60 while the cameras sit on the Garage 7150, so
camera-to-NVR traffic is the one flow that traverses the whole chain in normal operation.

## CRS309 / RouterOS notes

RouterOS expresses the same trunk profile differently: a `pvid` on each bridge port plus
`/interface bridge vlan` entries listing tagged members. Points that matter:

- **No static VLAN 1 entry.** Ports keep `pvid=1` and RouterOS builds the VLAN 1 entry
  dynamically, untagging it on the bridge itself and on every active pvid-1 port. That is
  what keeps management reachable, and it matches the untagged-VLAN-1 rule on the ICX side.
- **`current-tagged` / `current-untagged` list only ports with link.** A port that is down
  is absent from them even when correctly configured. Check `tagged=` in
  `/interface bridge vlan print detail` for the configured membership; ports join the
  dynamic VLAN 1 entry on link-up by themselves.
- **`vlan-filtering=yes` goes last.** It is the line that can cut off management.
- **L2MTU defaults to 1584** and must be raised for the 9000-byte Talos frames. Set it on
  *every* port, not just the ones in use - the bridge inherits the lowest member value.
  `10218` is the CRS3xx maximum and lines up with the 10200 the ICX switches report.
- **Bridge priority is hex.** `0x1000` / `0x2000` / `0x3000` for 4096 / 8192 / 12288.
- **Unregistered multicast floods by default** via the per-port `unknown-multicast-flood=yes`,
  so IGMP snooping can stay enabled here without the Matter/HomeKit problem the ICX7150 has.
  RouterOS covers IGMP and MLD in the one feature.
- **Align snooping versions.** The bridge defaults to `igmp-version=2` / `mld-version=1`
  while the Office ICX8200 queries at IGMPv3 / MLDv2. Set `igmp-version=3 mld-version=2`.
- **`multicast-querier=no`** on all three. No MikroTik switch queries.
- **The build block is idempotent except `/ip route add`.** Changing the address and
  enabling `vlan-filtering` both drop the session, so the block often gets pasted twice.
  Everything else fails safely with "already have..." / "already added"; a bare route `add`
  silently succeeds a second time and leaves two default routes. Use
  `/ip route remove [find where dst-address="0.0.0.0/0" && gateway="10.1.0.1"]` immediately
  before the `add`.
- **Netinstall leaves no default config at all** - `/export` comes back empty, with no
  bridge and no bridge ports. The build has to create them rather than modify defconf, and
  `auto-mac=no admin-mac=<previous>` is worth setting so the bridge MAC stays stable across
  a rebuild.

## Garage CRS309 as-built

CRS309-1G-8S+, RouterOS 7.24. Management 10.1.0.30/24 on the bridge interface, RSTP
priority `0x3000` (12288), hardware offload active on all ports.

| Port | Comment |
| --- | --- |
| sfp-sfpplus1 | uplink-gameroom-crs309 |
| sfp-sfpplus2 | garage-icx8200 |
| sfp-sfpplus3 | garage-icx7150 |

`ether1` and `sfp-sfpplus4`-`8` stay in the bridge at pvid 1, so any unused port is an
untagged VLAN 1 access port - a way back in if management is lost.

## Game Room CRS309 as-built

CRS309-1G-8S+, RouterOS 7.24. Management 10.1.0.20/24 on the bridge, RSTP priority
`0x2000` (8192). Mid-chain, so four tagged ports rather than three.

| Port | Comment |
| --- | --- |
| sfp-sfpplus1 | uplink-office-crs309 |
| sfp-sfpplus2 | downlink-garage-crs309 |
| sfp-sfpplus3 | gameroom-icx8200 |
| sfp-sfpplus4 | gameroom-icx7150 |

This unit has **32MB flash (18.7MB free)** and `minimum-version: 7.11.2`; the Garage unit
has **16MB with ~1.2MB free** and `minimum-version: 6.44.6` - a different board revision.
That gap is the likely reason the Garage box crashed during an upgrade and had to be
netinstalled: on a 16MB board there is barely room to stage a package. Check
`total-hdd-space` before upgrading any of them.

Because netinstall leaves no defconf to copy a MAC from, `admin-mac` is derived on the box:

```
/interface bridge set bridge auto-mac=no admin-mac=[/interface ethernet get ether1 mac-address]
```

## Office CRS309 as-built

CRS309-1G-8S+, RouterOS 7.24. Management 10.1.0.10/24 on the bridge, RSTP priority
`0x1000` (4096) - the **root bridge** for the whole fabric, which is where the RB5009
attaches.

| Port | Comment |
| --- | --- |
| sfp-sfpplus1 | uplink-office-gw (RB5009) |
| sfp-sfpplus2 | downlink-gameroom-crs309 |
| sfp-sfpplus3 | office-icx8200 |
| sfp-sfpplus4 | office-icx7150 |

## CRS309 flash revisions

Two board revisions are in play, and it matters for upgrades:

| Unit | Flash | Free | minimum-version |
| --- | --- | --- | --- |
| Office | 16MB | ~3.0MB | 6.44.6 |
| Game Room | 32MB | ~18.7MB | 7.11.2 |
| Garage | 16MB | ~1.2MB | 6.44.6 |

On the 16MB units a ~17MB package cannot be staged at all, so a manual `.npk` upload is
not possible there. CRS309 has no `/partitions` support either, so there is no fallback
image and recovery is netinstall only.

**All three failed an in-place 7.24 -> 7.24.4 upgrade**, including the 32MB unit with
18.7MB free. Free space is therefore *not* the explanation - whatever the cause, it is
common to the platform or that version pair, not the board revision. Do not assume the
roomier board is safe to upgrade in place.

**Use netinstall straight to the target version.** With the build blocks here, netinstall
plus one paste restores a switch in a couple of minutes, which is both faster and more
predictable than chasing an in-place upgrade that has failed three times out of three.
Keep Netinstall and the target `.npk` staged beforehand, and put the switch on stable
power - one of these logged `rebooted without proper shutdown, probably power outage`.

## Open items

- IPv6 is prefix-delegated and deliberately deferred.
- **Time zone is unset on all nine switches.** Everything is on GMT. The RB5009 resolved
  `America/New_York` by itself once it had real internet (`time-zone-autodetect: yes`);
  neither FastIron nor RouterOS on the CRS309s does that.
- **`ip mtu 9198` is set on `garage-icx8200` only.** The other five ICX still have `ve 1`
  at 1500. That only affects traffic the switch itself originates or terminates, not
  transit, which is why jumbo proved out end to end anyway - but it is inconsistent.
- **codswallop's BGP session does not establish.** `docker/codswallop/00-frr/config/frr.conf`
  has `neighbor 10.1.20.1`, which was the old router. The RB5009 peers from 10.1.0.1, so
  FRR drops the OPEN from an address it has no neighbor statement for. Fix belongs in
  frr.conf, not on the router. kerfuffle is unaffected - `CiliumBGPClusterConfig` already
  points every k8s node at 10.1.0.1.

Resolved since the bench build: `ctrld` is running on VLAN 30, the `netinstall` package
and its three listeners are in place, and the kerfuffle BGP session is established with
five prefixes.

## Netinstall from a RouterOS device

Running a Netinstall server on a RouterOS device is the separate `netinstall` package,
which requires **RouterOS 7.24beta1 or later on the server device**. (The 7.4-era
Netinstall change was the Linux/CLI build of the desktop tool - different thing.)
Available for every architecture except SMIPS.

Netinstall **reformats the target's system drive**: all configuration and user files are
erased. The RouterOS license and RouterBOOT settings survive.

### The hard constraint: one Layer 2 broadcast domain

Server and target must share a broadcast domain. Etherboot is raw BOOTP broadcast over
wired Ethernet, so it will not cross:

- a routed hop
- a different VLAN
- a wireless link

Across the house is fine as long as it is all one switched broadcast domain. MikroTik
recommends a dedicated interface and a dumb switch to avoid IP/DHCP/BOOTP conflicts, but a
shared bridge is explicitly supported - their own documented example binds to `bridge1`.

### Server setup

Enable the `netinstall` package for the *server's* architecture and reboot. On 7.24 the
extra packages are already on the device - `/system package print` lists them flagged
`A - AVAILABLE`, so there is no zip to download and upload.

It then appears under Tools -> Netinstall (`/tool/netinstall`) and creates `NetinstallCache/`,
which on flash-only boards lives in RAM - attach storage and set `cache-directory` if
space is tight.

Pre-fetching images needs internet on the server, and `arch` is the **target's** CPU
architecture, not the server's:

```
/tool/netinstall/cache/add arch=arm version=7.24
```

Omitting `version` installs the latest in the Check for Updates channel.

### Listener parameters

| Parameter | Meaning / default |
| --- | --- |
| `interface` | Interface the server listens on |
| `allow-etherboot` | yes/no, default yes |
| `allow-flashfig` | yes/no, default yes |
| `mac-address` | Restrict to one target MAC |
| `ip-range` | BOOTP range handed to the target |
| `version` | RouterOS version to install |
| `auto-reboot` | none/reboot/shutdown, default reboot |
| `extra-packages` | Beyond the system package, which installs automatically |
| `keep-old-configuration` | yes/no, default yes |
| `apply-default-configuration` | yes/no, default no |
| `install-once` | yes/no, default yes |
| `mode-file` | First-boot script, auto-removed after it runs |
| `script-file` | Default configuration script |
| `remove-branding` | yes/no, default no |
| `wait` | yes/no, default no |
| `etherboot-image` | Select a cached package |
| `etherboot-image-arch` | CPU architecture |

Also `/tool/netinstall/cache/` (arch mandatory, packages, version) and
`/tool/netinstall/devices/` (device state; clear the list, or install with
auto-reboot / extra-packages / numbers / version).

### Getting a target into Etherboot

- **Serial console**: hold Ctrl+E during boot.
- **Regular booter**: power on, press and hold Reset ~1-2s after power-up.
- **Backup booter**: power off, hold Reset, power on, wait for the LED to blink, go solid,
  go off, then release.
- **Remotely, if it still boots RouterOS**:

```
/system/routerboard/settings set boot-device=try-ethernet-once-then-nand
/system/reboot
```

### boot-device options

| Option | Behaviour |
| --- | --- |
| `nand-if-fail-then-ethernet` | Factory default. Boots NAND; if RouterOS will not boot, goes to Etherboot automatically |
| `nand-only` | NAND only, no fallback |
| `try-ethernet-once-then-nand` | Tries Etherboot next boot, falls back to NAND if nothing answers |
| `ethernet` | Stays in Etherboot |
| `flash-boot` | Flashfig mode; reverts to NAND after a config change or user login |
| `flash-boot-once-then-nand` | Flashfig for one boot, then reverts to `nand-if-fail-then-ethernet` |

`boot-protocol` is `bootp` (default) or `dhcp`.

### Running the listener on a shared / production interface

Supported, but tighten it:

- **Pin the MAC** plus `install-once=yes`. Only a device actually in Etherboot can be
  caught - but that includes anything someone reset-holds while the listener is live.
- **`allow-flashfig=no`**, or a factory-fresh or freshly-reset board on that LAN can get
  reconfigured unexpectedly.
- **`ip-range` in dead space**, clear of the existing DHCP pool.
- **DHCP race**: the LAN DHCP server and the listener both see the target's request. MAC
  pinning usually settles it; disabling LAN DHCP for the minute the flash takes is the
  blunt fix.
- **VLAN-filtered bridge**: bind to the VLAN interface the target's port is untagged in,
  not the bridge itself.
- **RSTP**: `edge-port=yes` on the target's port. Forwarding delay eats the Etherboot
  window and fails silently - it looks like the target is never seen at all.

## CRS309 remote netinstall recovery

Goal: reflash a bricked CRS309 from `office-gw` over VLAN 1 without unracking.

It works because the factory default `boot-device=nand-if-fail-then-ethernet` means a
switch that cannot boot RouterOS drops into Etherboot **by itself**. A failed upgrade is
exactly that condition, so nothing needs pre-arming on the switch - only a listener armed
on the router beforehand.

CRS309-1G-8S+ is 32-bit ARM (98DX8208, 800MHz dual core), so `arch=arm`. It has one copper
`ether1` plus 8x SFP+. The `etherboot-port` selector that lets you choose a boot interface
exists only on CRS520/804/812 - on the 309, assume Etherboot uses **copper `ether1` only**.

### Adjustments for this build

- **Bind the listener to `bridge`, not `vlan1`.** VLAN 1 is untagged on the bridge itself
  here; there is no separate VLAN 1 interface, unlike 10/20/50/60/4000. This is the
  "bind to the VLAN interface the target is untagged in" rule, and here that is `bridge`.
- **`ip-range` is 192.168.88.x**, not production space - Netinstall wants that subnet. The
  router therefore needs a secondary address there on the listening interface, since the
  server has to reach the target at whatever it hands out. It coexists with 10.1.0.1/24 on
  the same bridge:

  ```
  /ip address add address=192.168.88.1/24 interface=bridge comment="netinstall"
  ```
- **Patch each CRS309's `ether1` to its local ICX.** All three currently uplink over SFP+
  only, and Etherboot will not use those. `ether1` is already a bridge port at pvid 1, so
  any untagged VLAN 1 port on the room's ICX works.
- **`admin-edge-port` on that ICX port.** RSTP runs on VLAN 1 on the ICX side and
  forwarding delay closes the Etherboot window. The router bridge is `protocol-mode=none`
  and contributes no delay.
- **Pin the `ether1` MAC**, not the bridge/management MAC.
- **`keep-old-configuration=yes`** matters more than usual - a switch back on defaults is
  unreachable on VLAN 1 management, which puts you right back at the rack. A `script-file`
  with a minimal known-good management config (bridge, VLAN 1, address) is insurance for
  the case where the config restore is what failed.

```
/tool/netinstall/add interface=bridge \
    mac-address=<CRS309 ether1 MAC> \
    ip-range=192.168.88.10-192.168.88.20 \
    version=7.24 \
    keep-old-configuration=yes \
    allow-flashfig=no install-once=yes auto-reboot=reboot
```

### Workflow for bricking-on-upgrade

1. Arm the listener for the switch about to be upgraded. Idle listeners cost nothing.
2. Upgrade.
3. If it bricks, it falls into Etherboot, gets caught, reflashes, reboots.
4. Confirm it is back, then re-arm - `install-once` has disarmed the entry.

```
/tool/netinstall/devices/print
/tool/netinstall/devices/install numbers=0 version=7.24
```

### Reset button (CRS309-1G-8S+IN)

- Config reset: hold until the USER LED flashes.
- Bootloader recovery: press before power-on, release after ~3s.
- Netinstall/Etherboot: hold while powering on until the USR LED goes steady, then off.

### Where this does not save you

- **Half-brick** - boots RouterOS but comes up misconfigured or unreachable. It never
  enters Etherboot, so nothing catches it.
- **RouterBOOT-level corruption** - no Etherboot at all. Reset button or backup booter
  only, which means unracking.
- **Don't host the listener on a device being upgraded in the same window.**
- **The reformat** - config and user files gone, license and RouterBOOT settings kept.

Serial console or a switched PDU on these switches would cover nearly everything short of
dead hardware, and is worth adding eventually.

Sources:
[Netinstall package](https://manual.mikrotik.com/docs/getting-started/installation-and-upgrade/netinstall/netinstall-package/) ·
[Netinstall](https://manual.mikrotik.com/docs/getting-started/installation-and-upgrade/netinstall/) ·
[RouterBOARD](https://help.mikrotik.com/docs/spaces/ROS/pages/40992878/RouterBOARD) ·
[CRS309-1G-8S+IN](https://help.mikrotik.com/docs/spaces/UM/pages/17956906/CRS309-1G-8S+IN)
