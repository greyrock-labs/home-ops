# Switch baseline

Reference for the 2026 network rebuild. Covers both switch families: six Ruckus ICX8200
running FastIron 10.0, and three MikroTik CRS309 running RouterOS 7. Records the shared
conventions, and the platform syntax that differs from the published documentation.

Configs themselves are not stored here. This file
documents the *decisions* and the *gotchas*, not per-device running-configs.

## Topology

Daisy chain, RB5009 (`office-gw`, 10.1.99.1) at the head in the Office. Every switch is
L2 only except `office-crs309`, which routes VLANs 10 and 20 in hardware over transit
VLAN 4090; the RB5009 routes the rest (see [router-baseline.md](router-baseline.md) and
[tools/l3/README.md](tools/l3/README.md)).

`office-crs309` keeps its management (`vlan99-mgmt`, 10.1.99.10/24) in a VRF named `mgmt`,
with its own default route via 10.1.99.1; SSH and Winbox listen only there. A switch that
routes must not also sit in the management subnet in its main table: it would deliver
VLAN 10/20 traffic straight into VLAN 99 while the replies return through `office-gw`,
which drops them as invalid. With the VRF, traffic between VLAN 10/20 and VLAN 99 always
crosses the RB5009, in both directions. The switch's own DNS and NTP stay in main and leave
over transit from 10.255.0.2.

```
office-gw sfp-sfpplus1
   |
[Office CRS309 .10] -- C08ZP .11
   |                -- C08PF .12 (stack)
   |                -- NVR Pro (sfp-sfpplus6, VLAN 60)
[GameRoom CRS309 .20] -- C08ZP .21
   |                  -- C08PF .22
[Garage CRS309 .30] -- C08ZP .31
                    -- C08PF .32 (stack)
```

Garage traffic transits Game Room and Office. Rooms are joined by 10G-SR multimode fiber;
in-room uplinks are DACs.

## VLANs

| VLAN | Name     | Subnet          |
| ---- | -------- | --------------- |
| 1    | Default  | none            |
| 10   | Internal | 10.1.10.0/24    |
| 20   | Servers  | 10.1.20.0/24    |
| 50   | IoT      | 10.1.50.0/24    |
| 60   | Cameras  | 10.1.60.0/24    |
| 99   | Mgmt     | 10.1.99.0/24    |
| 4000 | Guest    | 192.168.23.0/24 |
| 4001 | Work     | 192.168.24.0/24 |

VLAN 1 carries no addresses. It stays untagged on the trunks only because RSTP runs on
it. VLAN 2 (`UniFi-Mgmt`) carried the UniFi devices during the migration and was
removed from every switch on 2026-11-20.

`10.1.25.0/24` is the Cilium load-balancer pool. It is **not** a VLAN — those /32s are
BGP-announced to the RB5009.

## Conventions

- **Trunks** carry VLAN 1 untagged and 10/20/50/60/99/4000/4001 tagged.
- **AP ports** carry VLAN 99 untagged (AP management) and 10/4000/4001 tagged. Power the
  port off before swapping an AP and back on afterwards (`no inline power` / `inline power`).
- **Port VLAN lists are written native-first.** `99,10,4000,4001` means untagged 99,
  tagged 10/4000/4001.
- **Hostnames** are `<room>-<model>`: `<room>-c08zp`, `<room>-c08pf` and `<room>-crs309`. Rooms are `office`, `gameroom`, `garage`; the router is `office-gw`. Uplink ports are named `uplink-<room>-crs309`.
- **Management** is static on VLAN 99 (`ve 99` on FastIron, `vlan99-mgmt` on RouterOS),
  gateway 10.1.99.1, DNS the two ctrlds 10.1.30.2 and 10.1.30.4, domain
  `internal.greyrock.io`. Each room gets a block: Office .10-.19, Game Room .20-.29,
  Garage .30-.39; switches take the low numbers and APs follow. On FastIron, `ve 99`
  binds to VLAN 99 by itself (`router-interface ve 99` is rejected), `no ip dns
  server-address` needs the exact current list, and adding an address already in the list
  fails with `duplicated dns server IP address`.
- **RSTP runs on VLAN 1 only**, matching RouterOS, which runs a single instance per
  bridge rather than one per VLAN. CRS309 spines take priority 4096 / 8192 / 12288
  (Office / Game Room / Garage); every ICX leaf stays at the 32768 default.
- **Time zone** is `America/New_York` with US daylight-saving rules. On FastIron that is
  `clock timezone us Eastern` plus a bare `clock summer-time`, which takes the default US
  rules. On the CRS309s it is set explicitly rather than by `time-zone-autodetect`, so a
  switch clock never depends on an external lookup service.
- **NTP** points at `time1`-`time4.internal.greyrock.io` with `disable serve`, so switches
  are clients only. Hostnames resolve fine in the `server` command despite the docs only
  showing IP literals.
- **Jumbo frames on every switch.** Talos hosts run `mtu: 9000` on `bond0`
  (`kubernetes/talos/cluster.yaml.j2`). `jumbo` is global on FastIron and needs a reload.
- **IGMP/MLD snooping on every VLAN.** Exactly one active querier per VLAN in the L2
  domain — office-c08zp. Every other switch is `passive`.
- **Unregistered multicast floods.** Snooping otherwise prunes IPv6 link-local groups,
  which breaks Matter and HomeKit over `ff02::fb`. IPv4 mDNS (224.0.0.251) is inside
  `224.0.0.0/24` and is never pruned, so only the IPv6 side is actually at risk.
- **Never remove** `logging host 10.1.99.2 udp-port 6514` or the `snmp-server community`
  line; Unleashed adds both.
- **The RUCKUS One registrar is off** (`manager disable`; 10.0's name for `sz disable`).
  Unleashed manages the switches over SSH and does not use it. Left on, every switch polls
  `sw-registrar.ruckuswireless.com` every few seconds and gets a 404.
- **Stack ports**: a factory unit has both SFP+ ports as stack ports. To keep `1/2/2` as
  the uplink, remove it under `stack unit 1` with `no stack-port ethernet 1/2/2`;
  `stack-port ethernet 1/2/1` alone does not replace the pair, and `stack enable` refuses
  while a tagged port is still a stack port.
- Unleashed and the CLI co-manage these switches; the majority of config is done by CLI.
- **SSH public key** on every ICX: `todd.pub` from the laptop's TFTP root
  (`/private/tftpboot`), loaded at the `#` prompt with
  `copy tftp flash <laptop ip> todd.pub ssh-pub-key-file` and checked with
  `show ip client-pub-key`. `ip ssh pub-key-file tftp` is gone on 10.0; only its
  `remove` form is left.


## Verifying a switch

`show interfaces ethernet <uplink>` is the single best check — it proves the trunk and
jumbo in one shot:

```
Tagged member of 7 L2 VLANs, untagged in VLAN 1, port state is FORWARDING
MTU 10200 bytes, encapsulation ethernet
```

`jumbo` needs a reload, and `show running-config` reads identically before and after it —
so the config line alone says nothing about whether jumbo is live. `MTU 10200` is the proof.
To confirm the reload happened at all, `show version` shows
`started=warm start   reloaded=by "reload"`.

The rest, once per switch. Note that `show span` and `show 802-1w` are separate commands
for separate protocols - 802.1D and RSTP. Wanting "not configured" from one and a live
instance from the other is the same statement twice: RSTP replaced 802.1D on VLAN 1.


| Command                                     | Want to see                                                                          |
| ------------------------------------------- | ------------------------------------------------------------------------------------ |
| `show running-config \| include global-stp` | nothing                                                                              |
| `show span`                                 | "not configured" on every VLAN - this command reports 802.1D only                    |
| `show 802-1w`                               | the RSTP counterpart: VLAN 1 only, bridge ID starting `8000`, uplink ROOT/FORWARDING |
| `show ip multicast`                         | all VLANs `cfg V3`, `vlan cfg passive` (active on office-c08zp), Flooding Enabled |
| `show ipv6 multicast`                       | `dft V2`, Flooding Enabled                                                           |
| `show ntp status`                           | synchronized, server mode disabled, client mode enabled                              |

On the ICX8200, a port whose link is up shows a yellow LED once its error counters are
non-zero; one CRC error is enough. `clear statistics ethernet <port>` turns it green again.


## Unleashed APs

The APs live on VLAN 99 in the same room blocks as the switches; see
[wifi-baseline.md](wifi-baseline.md) for addresses and settings. 10.1.99.2
(`unleashed.internal.greyrock.io`) is the Unleashed management address, not a device: it
floats to whichever AP currently holds master.

## Unleashed config drift

These switches are co-managed. Unleashed re-asserts parts of
its own template, so some CLI settings revert across a reboot. Observed after reload in the
earlier build, having been verified absent beforehand:

| Setting                 | Reverts to                  | Impact                                                                                                                   |
| ----------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `global-stp`            | re-added                    | **None.** Verified inert: `show span` still reports "not configured" on every VLAN and RSTP keeps VLAN 1. Cosmetic only. |
| `cli timeout 240`       | `cli timeout 0`             | Cosmetic - no idle timeout.                                                                                              |
| `snmp-server community` | an extra community appended | Seen once in the earlier build. Leave both in place.                                                                     |

Decision: do not fight the template. `global-stp` does nothing here, so re-clear it if you
care about a tidy config and otherwise ignore it. What matters is that none of the
functional config - VLANs, trunks, RSTP, multicast, jumbo, static addressing, NTP - drifted.

## FastIron 10.0 gotchas

Each of these cost a round trip on the first switch. The published docs describe the
08.0.x/09.0.x behaviour and are wrong for 10.0.

| Doing this                                         | Actual 10.0 behaviour                                                                                                                                                                                                                                                 |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `no ip dhcp-client enable`                         | Rejected. Use `ip dhcp-client disable`.                                                                                                                                                                                                                               |
| Removing the per-VE binding first                  | Refused while the client is on globally. Disable globally, *then* `no ip dhcp-client ve default`, *then* set the static address.                                                                                                                                      |
| `dual-mode` / `dual-mode 1`                        | Deprecated since 08.0.80. Unnecessary — a port tagged into other VLANs keeps its untagged VLAN 1 membership. Verify with `Tag=Yes, Pvid=1`.                                                                                                                           |
| `no ip multicast disable-flooding`                 | Deprecated. Use `ip multicast flood-unregistered` and `ipv6 multicast flood-unregistered`. The IPv6 form of `disable-flooding` does not exist at all.                                                                                                                 |
| A global command after a `vlan`/`interface` stanza | Silently ignored or misfiled into the sub-context. `no global-stp` landed nowhere; `no ip dhcp-client enable` was written into an interface. **Always `exit` to global config first.**                                                                                |
| `no global-stp` before VLAN 1 is on 802.1w         | Silently does not stick. Removal only takes once `spanning-tree 802-1w` is active on VLAN 1, so sequence it *after* the VLAN 1 stanza. Confirm with `show running-config | include global-stp` printing nothing.                                                      |
| `ipv6 mld version 2`                               | Accepted without error but **silently unreliable** — it applied on two units and left a third on MLDv1. Use the canonical `ipv6 multicast version 2` instead, and verify with `show ipv6 multicast`: want `Version=2`, `dft V2` and `(SG)` caches, not `V1` / `(*G)`. |
| `global-rstp`                                      | Does not exist. 802.1w is per-VLAN: `spanning-tree 802-1w`. Remove `global-stp`, and `no spanning-tree` on the VLAN before enabling 802.1w.                                                                                                                           |
| `spanning-tree 802-1w priority 32768`              | Accepted but absent from running-config, because it equals the default. Confirm via the bridge ID in `show 802-1w` — a leading `8000` is 32768.                                                                                                                       |
| `ip mtu 9198` on `ve 99` before the `jumbo` reload | Rejected: the range is 1280-1500 until jumbo is live. Set it after the reload. `ip mtu` also sets the IPv6 MTU.                                                                                                                                                       |
| `enable` at a `#` prompt                           | Rejected; already privileged. Needed only after a reload, which drops you to `>`.                                                                                                                                                                                     |
| `?` in a pasted block                              | Swallowed. Help queries must be typed by hand.                                                                                                                                                                                                                        |


## ICX as-built (2026-11-20)

All six are ICX8200 on FastIron `10.0.10g_cd6T253`, uplinked on `1/2/2` (`2/2/2` on the
Garage stack) to their room's CRS309. office-c08zp is the **active** IGMP/MLD querier for
every VLAN; the other five are passive with flooding. PoE allocation is dynamic. The C08ZP
ports `1/1/1`-`1/1/4` are 2.5G and `1/1/5`-`1/1/8` 10G, all 802.3bt; the C08PF ports are
1G PoE+ (30 W), so anything needing more (the AI Key, Class 5) goes on a C08ZP.

### Office C08ZP (.11)

| Port  | Name       | Untagged | Tagged         |
| ----- | ---------- | -------- | -------------- |
| 1/1/1 | ai-key     | 60       | -              |
| 1/1/5 | kerfuffle  | 20       | 10, 60         |
| 1/1/6 | codswallop | 20       | -              |
| 1/1/7 | office-ap  | 99       | 10, 4000, 4001 |
| 1/1/8 | uh-ap      | 99       | 10, 4000, 4001 |

`kerfuffle` is the Talos node. Its `bond0` is `active-backup` over a single link,
**not** LACP, so it takes a plain port with no LAG, with VLANs 10 and 60 tagged for
Multus. `codswallop` is the TrueNAS host, on a plain VLAN 20 port (`enp36s0f0`, no bond).

### Office C08PF (.12, stack)

A two-unit stack; unit 1 (priority 128, holding the uplink) is active. The stack link is
`1/2/1`-`2/2/1`; those are the only stack ports, so `1/2/2` and `2/2/2` stay data ports.
Stack ports reject all interface config, including `port-name`.

| Port  | Name           | Untagged |
| ----- | -------------- | -------- |
| 1/1/1 | time1          | 20       |
| 1/1/2 | time2          | 20       |
| 1/1/3 | time3          | 20       |
| 1/1/4 | time4          | 20       |
| 1/1/5 | homeassistant  | 10       |
| 1/1/6 | gallivant      | 20       |
| 1/1/7 | kvm-hass       | 20       |
| 1/1/8 | kvm-codswallop | 20       |
| 2/1/1 | kvm-kerfuffle  | 20       |
| 2/1/2 | kvm-gallivant  | 20       |
| 2/1/4 | up-chime       | 60       |

### Game Room C08ZP (.21)

| Port  | Name          | Untagged | Tagged         |
| ----- | ------------- | -------- | -------------- |
| 1/1/1 | andys-desktop | 10       | -              |
| 1/1/2 | todds-desktop | 10       | -              |
| 1/1/5 | game-room-ap  | 99       | 10, 4000, 4001 |

### Game Room C08PF (.22)

| Port  | Name      | Untagged |
| ----- | --------- | -------- |
| 1/1/1 | solaredge | 50       |

### Garage C08ZP (.31)

| Port  | Name       | Untagged | Tagged         |
| ----- | ---------- | -------- | -------------- |
| 1/1/1 | rd-ap      | 99       | 10, 4000, 4001 |
| 1/1/2 | sy-ap      | 99       | 10, 4000, 4001 |
| 1/1/3 | sd-ap      | 99       | 10, 4000, 4001 |
| 1/1/5 | garage-ap  | 99       | 10, 4000, 4001 |
| 1/1/6 | kitchen-ap | 99       | 10, 4000, 4001 |

### Garage C08PF (.32, stack)

A two-unit stack. The uplink is `2/2/2` on unit 2, and the cameras are on unit 2 as well.

| Port  | Name            | Untagged |
| ----- | --------------- | -------- |
| 2/1/1 | g4-doorbell-pro | 60       |
| 2/1/2 | garage-todd-cam | 60       |
| 2/1/3 | g6-turret-1     | 60       |
| 2/1/4 | g6-turret-2     | 60       |
| 2/1/5 | side-yard-cam   | 60       |
| 2/1/6 | g5-pro-enhancer | 60       |

### Joining a second C08PF unit

Set `priority 128` and `stack enable` on the unit that holds the uplink **before** the
second unit joins, or the newcomer can win the election and the stack comes up on a blank
config. On the new unit: `stack unit 1`, `no stack-port ethernet 1/2/2`,
`stack suggested-id 2`, `stack enable`. It reboots into the stack, and `write memory` on
the active unit makes its config static. 10.0 has no `stack secure-setup`.

### Upgrading a factory C08PF

Factory units ship on `10.0.00`. On that release the switch's own `scp` binary is broken
(`wrong ELF class`), and the RouterOS TFTP server on `office-gw` never answered the
switch's request, so the image comes from the macOS TFTP server on a laptop
(`/private/tftpboot`). Set the block size first - a factory unit asks for 8192-byte blocks,
which fragment and stall the transfer at 0%:

```
configure terminal
ip tftp blocksize 1400
exit
copy tftp flash <laptop ip> ICX8200/Images/RDR10010g_cd6ufi.bin primary
show flash
boot system flash primary
```

`boot system flash primary` at the `#` prompt reboots immediately. Afterwards the switch
updates its PoE firmware; wait for that to finish before any further reload.
`ip mtu 9198` is rejected until the reload that activates `jumbo`.


## CRS309 / RouterOS notes

RouterOS expresses the same trunk profile differently: a `pvid` on each bridge port plus
`/interface bridge vlan` entries listing tagged members. Points that matter:

- **No static VLAN 1 entry.** Ports keep `pvid=1` and RouterOS builds the VLAN 1 entry
  dynamically, untagging it on every active pvid-1 port, which matches the untagged-VLAN-1
  rule on the ICX side. Management is `vlan99-mgmt` on the bridge, tagged on every trunk.
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
  so IGMP snooping can stay enabled here without the Matter/HomeKit problem the ICX7150s had.
  RouterOS covers IGMP and MLD in the one feature.
- **Align snooping versions.** The bridge defaults to `igmp-version=2` / `mld-version=1`
  while office-c08zp queries at IGMPv3 / MLDv2. Set `igmp-version=3 mld-version=2`.
- **`multicast-querier=no`** on all three. No MikroTik switch queries.
- **The build block is idempotent except `/ip route add`.** Changing the address and
  enabling `vlan-filtering` both drop the session, so the block often gets pasted twice.
  Everything else fails safely with "already have..." / "already added"; a bare route `add`
  silently succeeds a second time and leaves two default routes. Use
  `/ip route remove [find where dst-address="0.0.0.0/0" && gateway="10.1.99.1"]` immediately
  before the `add`.
- **Netinstall leaves no default config at all** - `/export` comes back empty, with no
  bridge and no bridge ports. The build has to create them rather than modify defconf.
- **The bridge MAC is the unit's own `ether1` MAC**, pinned with `auto-mac=no` so it stays
  stable across a rebuild. The three units are interchangeable between rooms, so it is
  derived on the box rather than carried over from a backup. `admin-mac` must be given on
  the `add` line itself, or the bridge add fails:
  `/interface bridge add name=bridge auto-mac=no admin-mac=[/interface ethernet get ether1 mac-address] ...`


## CRS309 as-built (2026-11-20)

All three are CRS309-1G-8S+ on RouterOS 7.25.1, netinstalled from the RB5009, with
management on `vlan99-mgmt` and hardware offload on every port. `ether1` is pvid 99
(`bench-or-recovery`), so it is a management access port. Unused SFP+ ports stay in the
bridge at pvid 1.

### Office CRS309 (.10), RSTP priority `0x1000` - the root bridge

| Port         | Comment                  |
| ------------ | ------------------------ |
| sfp-sfpplus1 | uplink-office-gw         |
| sfp-sfpplus2 | downlink-gameroom-crs309 |
| sfp-sfpplus3 | office-c08zp             |
| sfp-sfpplus4 | office-c08pf             |
| sfp-sfpplus6 | nvr-pro (pvid 60)        |

### Game Room CRS309 (.20), RSTP priority `0x2000`

| Port         | Comment                |
| ------------ | ---------------------- |
| sfp-sfpplus1 | uplink-office-crs309   |
| sfp-sfpplus2 | downlink-garage-crs309 |
| sfp-sfpplus3 | gameroom-c08zp         |
| sfp-sfpplus4 | gameroom-c08pf         |

This unit is the 32MB board revision; the Office and Garage units are 16MB boards. See
[CRS309 flash revisions](#crs309-flash-revisions) before upgrading any of them.

### Garage CRS309 (.30), RSTP priority `0x3000`

| Port         | Comment                |
| ------------ | ---------------------- |
| sfp-sfpplus1 | uplink-gameroom-crs309 |
| sfp-sfpplus2 | garage-c08zp           |
| sfp-sfpplus3 | garage-c08pf           |

## CRS309 flash revisions

Two board revisions are in play, and it matters for upgrades:

| Unit      | Flash | Free    | minimum-version |
| --------- | ----- | ------- | --------------- |
| Office    | 16MB  | ~3.0MB  | 6.44.6          |
| Game Room | 32MB  | ~18.7MB | 7.11.2          |
| Garage    | 16MB  | ~3.0MB  | 6.44.6          |

On the 16MB units a ~17MB package cannot be staged at all, so a manual `.npk` upload is
not possible there. CRS309 has no `/partitions` support either, so there is no fallback
image and recovery is netinstall only.

**All three failed an in-place 7.24 -> 7.24.4 upgrade**, including the 32MB unit with
18.7MB free. Free space is therefore *not* the explanation - whatever the cause, it is
common to the platform or that version pair, not the board revision. Do not assume the
roomier board is safe to upgrade in place.

**Use netinstall straight to the target version.** That is how all three reached 7.25.1. With the build blocks here, netinstall
plus one paste restores a switch in a couple of minutes, which is both faster and more
predictable than chasing an in-place upgrade that has failed three times out of three.
Keep Netinstall and the target `.npk` staged beforehand, and put the switch on stable
power - one of these logged `rebooted without proper shutdown, probably power outage`.


## Garage stack

garage-c08pf is a two-unit stack (see its as-built section). The two units run under the
one name and address.


The SFP+ ports are also the stacking ports, but a two-unit stack only consumes one per
unit. Confirmed in the FastIron 10.0.20 Stacking Configuration Guide, Table 16 and the
ICX 8200 Configuration Notes:

- The valid-stack-port set for C08PF / C08ZP / C08PFV is `(x/2/1, x/2/2, 1)`. The third
  number is the maximum ports in a stacking trunk; `1` means a single stack-port only.
- "Unused stacking ports can be used as data ports. For example, you can elect to use only
  one valid-stack-port as a stacking port and the other valid-stack-port as a data port."
- "To maintain stacking functionality, ensure that only one valid stacking port is used for
  stacking while the other can be utilized as a data port."

So each stack unit uses one SFP+ for the stack link and keeps the other as a 10G data port.
No stack-trunk is supported on these models, with one exception - a two-unit
linear-topology trunk, `stack-trunk x/2/1 to x/2/2`. That doubles stack bandwidth to 20G
and consumes both ports, leaving no 10G uplink. **Do not use it here**; the Garage sits at
the end of the daisy chain and needs its uplink.

**Module 2 must be clean before stacking is enabled.** From the same notes: "Stacking
cannot be enabled on an ICX 8200 device containing configuration for Module 2, including
port speed. The configuration must be removed before stacking is enabled." The existing
C08ZP carries inert default `stack-port` lines on both SFP+ (see *Office C08ZP
as-built*), so expect the same on a new unit and clear Module 2 first.

C08PF supports 10-Gbps stacking only, which is moot here - the ports are 10G.

Note when searching: `garage` in `docker/codswallop/04-garage/` and the kanidm
`oauth2-garage-ui` refer to the Garage S3 software, not the room.


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
/tool/netinstall/cache/add arch=arm version=7.25.1 packages=routeros
```

Omitting `version` installs the latest in the Check for Updates channel.

### Listener parameters

| Parameter                     | Meaning / default                                       |
| ----------------------------- | ------------------------------------------------------- |
| `interface`                   | Interface the server listens on                         |
| `allow-etherboot`             | yes/no, default yes                                     |
| `allow-flashfig`              | yes/no, default yes                                     |
| `mac-address`                 | Restrict to one target MAC                              |
| `ip-range`                    | BOOTP range handed to the target                        |
| `version`                     | RouterOS version to install                             |
| `auto-reboot`                 | none/reboot/shutdown, default reboot                    |
| `extra-packages`              | Beyond the system package, which installs automatically |
| `keep-old-configuration`      | yes/no, default yes                                     |
| `apply-default-configuration` | yes/no, default no                                      |
| `install-once`                | yes/no, default yes                                     |
| `mode-file`                   | First-boot script, auto-removed after it runs           |
| `script-file`                 | Default configuration script                            |
| `remove-branding`             | yes/no, default no                                      |
| `wait`                        | yes/no, default no                                      |
| `etherboot-image`             | Select a cached package                                 |
| `etherboot-image-arch`        | CPU architecture                                        |

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

| Option                        | Behaviour                                                                               |
| ----------------------------- | --------------------------------------------------------------------------------------- |
| `nand-if-fail-then-ethernet`  | Factory default. Boots NAND; if RouterOS will not boot, goes to Etherboot automatically |
| `nand-only`                   | NAND only, no fallback                                                                  |
| `try-ethernet-once-then-nand` | Tries Etherboot next boot, falls back to NAND if nothing answers                        |
| `ethernet`                    | Stays in Etherboot                                                                      |
| `flash-boot`                  | Flashfig mode; reverts to NAND after a config change or user login                      |
| `flash-boot-once-then-nand`   | Flashfig for one boot, then reverts to `nand-if-fail-then-ethernet`                     |

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


## CRS309 netinstall from the RB5009

Goal: reflash a CRS309 from `office-gw` over VLAN 99 without unracking. This is how the
three were built on 2026-11-19.

**The `netinstall` package on the RB5009 is disabled** (since the 2026-11-20 cleanup).
Enable it first: `/system package enable netinstall`, then reboot the router.

CRS309-1G-8S+ is 32-bit ARM (98DX8208, 800MHz dual core), so `arch=arm`. It has one copper
`ether1` plus 8x SFP+. The `etherboot-port` selector that lets you choose a boot interface
exists only on CRS520/804/812 - on the 309, Etherboot uses **copper `ether1` only**.

### Adjustments for this build

- **Bind the listener to `vlan99-mgmt`.** The CRS309's `ether1` is a pvid 99 access port,
  and the RB5009's `ether2`-`ether8` are pvid 99 too, so cable `ether1` to an RB5009 copper
  port (or any VLAN 99 access port).
- **`ip-range` is 192.168.88.x**, not production space. The router needs a temporary
  `192.168.88.1/24` on `vlan99-mgmt` (comment `netinstall`); remove it afterwards.
- **Cache the image with `packages=routeros`**, or the cache never populates:
  `/tool netinstall cache add arch=arm version=7.25.1 packages=routeros`.
- **`keep-old-configuration=no`** for a clean build, then import the room's `.rsc`.
- **Device-mode blocks `boot-device` from software** on these units, so Etherboot is by the
  reset button: unplug power, hold reset, plug in, release when the USR LED goes steady
  then off. Watch `/tool netinstall devices print`.

```
/tool/netinstall/add interface=vlan99-mgmt \
    mac-address=<CRS309 ether1 MAC> \
    ip-range=192.168.88.10-192.168.88.20 \
    version=7.25.1 \
    keep-old-configuration=no \
    allow-flashfig=no install-once=yes auto-reboot=reboot
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
