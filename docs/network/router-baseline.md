# Router baseline

`office-gw`, an RB5009UG+S+ on RouterOS 7.24.4, replacing the previous gateway in the
2026 rebuild. Router-on-a-stick: every SVI lives here and all nine switches are pure L2.
See [switch-baseline.md](switch-baseline.md) for the switch side and
[router-acme.md](router-acme.md) for certificates.

Configs are not stored here. This documents the *decisions* and the conventions that the
running config cannot explain about itself.

## Interfaces and addressing

| Interface | IPv4 | Purpose |
| --- | --- | --- |
| `ether1` | DHCP (Spectrum) | WAN |
| `bridge` | 10.1.0.1/24 | VLAN 1, management |
| `vlan10-internal` | 10.1.10.1/24 | Internal |
| `vlan20-servers` | 10.1.20.1/24 | Servers |
| `vlan30-container` | 10.1.30.1/24 | Router containers |
| `vlan50-iot` | 10.1.50.1/24 | IoT |
| `vlan60-cameras` | 10.1.60.1/24 | Cameras |
| `vlan4000-guest` | 192.168.23.1/24 | Guest |

`192.168.88.1/24` also sits on the bridge for Netinstall. Nothing reaches it unless a
CRS309's `ether1` is patched to a local ICX for recovery, so it stays configured rather
than being rebuilt each time. Procedure is in `switch-baseline.md`.

### Interface lists

`LAN` holds `bridge`, `vlan10`, `vlan20`, `vlan30`, `vlan50`. `WAN` is `ether1`.
`vlan60-cameras` is `RESTRICTED` and `vlan4000-guest` is `GUEST`, both deliberately
outside `LAN` - the input and forward chains end in a drop for anything not from `LAN`.

`LOCALSVC` holds `vlan60-cameras` and `vlan4000-guest`. It exists so those two can still
reach the router for DHCP despite being outside `LAN`. **It was empty for the whole bench
build**, which silently meant cameras and guest could not complete a DHCP handshake at
all. If either VLAN stops getting leases, check this list first.

## IPv6

Spectrum delegates a /56 over DHCPv6-PD. The client requests both halves:

- `request=address,prefix` - `address` takes an IA_NA for the router itself on `ether1`,
  `prefix` takes the IA_PD.
- `prefix-hint=::/56` is required. Without the hint Spectrum hands back a /64.
- `use-peer-dns=no` keeps Spectrum's resolvers out of `/ip dns dynamic-servers`.
- `add-default-route=yes` is what installs `::/0`, because `accept-router-advertisements`
  is `yes-if-forwarding-disabled` and forwarding is on, so RAs on the WAN are ignored.

### Lease behaviour

The first lease comes back with roughly a one-hour lifetime. At T1 the client renews and
Spectrum answers that renewal with 7-day lifetimes, and it stays there. A ~1h lifetime on
a fresh delegation is the initial grant, not instability.

The prefix is keyed to the client DUID, not the interface. RouterOS uses a type 3
DUID-LL derived from `ether1`'s MAC, so it survives reboots and a config reset and the
same /56 comes back. Replacing the router hardware is what would change it and renumber
everything downstream.

### Subnet ID convention

**The subnet ID is the VLAN ID in hex.** A /56 leaves 8 bits of subnet space, so IDs run
`00`-`ff`. Where the VLAN ID does not fit in 8 bits, it clamps to `ff`.

| VLAN | Hex | Subnet ID | Delegated /64 | ULA |
| --- | --- | --- | --- | --- |
| 10 | `0x0a` | `0a` | `…:1d0a::1/64` | `fdc0:ffee:215:a::1/64` |
| 20 | `0x14` | `14` | `…:1d14::1/64` | `fdc0:ffee:215:14::1/64` |
| 4000 | `0xfa0` | `ff` (clamped) | `…:1dff::1/64` | `fdc0:ffee:215:ff::1/64` |

Guest is the only clamped one - `0xfa0` is 12 bits. Its ULA uses `ff` as well rather than
`fa0`, so the two halves match, even though the ULA's 16-bit field would hold `fa0`.

Nothing else has IPv6: VLANs 1, 30, 50 and 60 are v4-only by choice.

### Pinning a /64 out of the pool

`from-pool` normally hands out the next sequential /64. To pin a specific subnet, the
`address` value is OR'd against the pool's base prefix, so the subnet ID goes in the
fourth hextet:

```
/ipv6 address add address=::a:0:0:0:1 from-pool=spectrum-pd interface=vlan10-internal advertise=yes
```

`::a:0:0:0:1` puts `000a` in the fourth hextet, yielding `…:1d0a::1/64`. Verified on
7.24.4 - the result is not sequential allocation. ULAs are ordinary static addresses with
no pool.

### Not delegating downstream

`pool-name=spectrum-pd` holds the delegation; the three addresses above draw from it and
nothing else does. There is no DHCPv6 server and no PD to downstream routers.

## DNS

The router runs `allow-remote-requests` with Quad9 upstream, but clients are pointed at
`ctrld` on 10.1.30.2, which forwards `greyrock.io` and `10.in-addr.arpa` back to the
router at 10.1.30.1:53. That split is what makes internal names resolve while everything
else goes out over DoH. `mdns-repeat-ifaces` covers `vlan10-internal` and
`vlan20-servers`.

Static entries fall into four groups, distinguished by comment so automation can be
filtered from hand-made records:

| Comment | Source | Notes |
| --- | --- | --- |
| `dhcp-auto` | DHCP lease script | Added and removed by the script only |
| `switch` | Hand-made | Nine switches, 10.1.0.10-.12/.20-.22/.30-.32 |
| `ap` | Hand-made | Nine Unleashed APs, see `switch-baseline.md` |
| `router` | Hand-made | `office-gw.internal.greyrock.io` → 10.1.0.1 |
| *(none)* | `external-dns` | Owned via TXT registry, `txtPrefix: k8s.main.%{record_type}-` |

`external-dns` only deletes records it holds an ownership TXT for, and the lease script
only removes records commented `dhcp-auto`, so hand-made entries are safe from both.

`office-gw.internal.greyrock.io` exists so `external-dns` can reach the REST API by a
name the router's certificate actually covers. Verified from inside the cluster: the name
resolves through CoreDNS and the certificate validates without `-k`.

## DHCP

Leases are 8h everywhere except guest at 4h. Pools start at `.100` on VLAN 1, `.2` on
guest, and `.6` on everything else.

A lease script writes a DNS record per lease so that requests reaching `ctrld` can be
attributed to a device. It is installed on every server **except guest**. Behaviour:

- Hostname is lowercased and sanitised to `[a-z0-9-]`; anything else becomes `-`.
- A client that sends no hostname gets `host-<last 3 octets of MAC>`.
- A name that already exists pointing at a different address gets the MAC suffix appended.
- Entries are tagged `dhcp-auto` and removed when the lease goes away.

### RouterOS scripting gotchas

- **There is no `:tolower`.** No lowercase function exists at all. Case folding has to be
  a character-map lookup with `:find` against `"ABCDEFGHIJKLMNOPQRSTUVWXYZ"`.
- The function is `:tostr`, not `:tostring`.
- A failing lease script is silent from the DHCP side. `/log print where topics~"script"`
  is the only place it surfaces.

## Containers

Two, both on `vlan30-container` via veth, with layers and tmpdir shared on `usb1/pull`.

| Container | veth | Address | Purpose |
| --- | --- | --- | --- |
| `ctrld` | `veth-ctrld` | 10.1.30.2 | DNS, split-horizon to the router |
| `acme` | `veth-acme` | 10.1.30.3 | Let's Encrypt, see `router-acme.md` |

VLAN 30 is in the `LAN` interface list, so containers reach the router without a
dedicated firewall rule. Bridge membership comes from `pvid=30` on the bridge port alone -
the `/interface bridge vlan` entry for 30 needs no `untagged=` edit.

`/container envs` takes `key=`, and `/container mounts` takes `list=`, with
`mountlists=` on `/container add`. Every published guide uses `name=`/`mounts=`.

## BGP

Local AS 64513, router-id 10.1.0.1 from `/routing id` - the dynamic `main` entry had
selected 192.168.23.1 on its own, which is why the entry is explicit.

| Peer | Address | AS | Source |
| --- | --- | --- | --- |
| kerfuffle | 10.1.20.10 | 64514 | Cilium, `CiliumBGPClusterConfig` |
| codswallop | 10.1.20.12 | 64515 | FRR, `docker/codswallop/00-frr/config/frr.conf` |

The Cilium config selects all linux nodes with one `localASN` and `peerAddress: 10.1.0.1`,
so any k8s node peers the same way. codswallop is hand-configured, and its `neighbor` line
had to be moved from the old router's 10.1.20.1 to 10.1.0.1 during the cutover - FRR drops
an OPEN from an address it has no neighbor statement for, which presents as a session that
never leaves idle with `remote.as=0`.

codswallop advertises `10.1.25.21/32`. That prefix reaches the cluster through the router,
so kerfuffle receives it from office-gw rather than directly.

RouterOS 7 specifics: an `instance` is mandatory and carries the AS - `as=` on a
connection is rejected. The AFI parameter is `afi`, not `address-families`. `router-id`
and `local.router-id` are both invalid on a connection; it comes from `/routing id`.

`10.1.25.0/24` is the Cilium load-balancer range, learned over BGP. It is not a VLAN and
has no SVI.

## Open items

- **`/ip service www-ssl` has no `address=` restriction**, so REST answers on every
  address the router holds. Only the input chain's final drop keeps it off the WAN.
- **IPv6 firewall is defconf.** It drops non-`LAN` on both input and forward, which is
  correct, but it has not been reviewed against the VLANs that now carry global addresses.
