# Router baseline

`office-gw`, an RB5009UG+S+ on RouterOS 7.24.4, replacing the previous gateway in the
2026 rebuild. The Office CRS309 routes VLANs 1, 10 and 20 in hardware; office-gw
keeps WAN/NAT, WireGuard, router containers and VLANs 50/60/4000/4001. Its management
endpoint is `office-gw.internal.greyrock.io` (10.255.0.1).
See [switch-baseline.md](switch-baseline.md) for the switch side and
[router-acme.md](router-acme.md) for certificates.

The office routing design and validation history are documented in
[office-routing.md](office-routing.md).

Configs are not stored here. This documents the _decisions_ and the conventions that the
running config cannot explain about itself.

## Interfaces and addressing

| Interface          | IPv4            | Purpose                                                      |
| ------------------ | --------------- | ------------------------------------------------------------ |
| `ether1`           | DHCP (Spectrum) | WAN                                                          |
| `bridge`           | 192.168.88.1/24 | Netinstall recovery on untagged VLAN 1                       |
| `vlan4090-transit` | 10.255.0.1/30   | Office CRS309 at 10.255.0.2                                  |
| `vlan30-container` | 10.1.30.1/24    | Router containers                                            |
| `vlan50-iot`       | 10.1.50.1/24    | IoT                                                          |
| `vlan60-cameras`   | 10.1.60.1/24    | Cameras                                                      |
| `vlan4000-guest`   | 192.168.23.1/24 | Guest                                                        |
| `vlan4001-work`    | 192.168.24.1/24 | Work                                                         |
| `wg-public-edge`   | 10.254.45.1/24  | WireGuard to skedaddle, see [public-edge.md](public-edge.md) |

`192.168.88.1/24` remains on the bridge for Netinstall. Nothing reaches it unless a
CRS309's `ether1` is patched to a local ICX for recovery, so it stays configured rather
than being rebuilt each time. Procedure is in `switch-baseline.md`.

VLANs 1, 10 and 20 retain gateways `10.1.0.1`, `10.1.10.1` and `10.1.20.1`,
owned by the Office CRS309. Static return routes point all three /24s at
`10.255.0.2`. The old gateway addresses and VLAN 10/20 interfaces were removed
after validation. The bridge remains for L2 switching and
Netinstall; it no longer owns an active 10.1.0.0/24 address.

### Interface lists

`LAN` holds `bridge`, `vlan4090-transit`, `vlan30-container`, and `vlan50-iot`.
`WAN` is `ether1`. `vlan60-cameras` is
`RESTRICTED`, `vlan4000-guest` is `GUEST` and `vlan4001-work` is `WORK`, all deliberately
outside `LAN` - the v4 input chain and both v6 chains end in a drop for anything not from
`LAN`.

`LOCALSVC` covers `vlan60-cameras`, `vlan4000-guest` and `vlan4001-work` so they can still
reach the router for DHCP and DNS despite being outside `LAN`. It does this with
`include=RESTRICTED,GUEST,WORK` rather than direct members - the lists are pulled in
dynamically.

**`/interface list member print` shows nothing for a list built from includes.** An empty
member listing is not an empty list; check `/interface list print` for the `INCLUDE`
column before concluding anything is missing.

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

### Subnet IDs and downstream delegation

Public and ULA subnet IDs match. The Office CRS309 receives IDs `10`-`1f` as a
single /60 within the ISP /56. IDs are hexadecimal: VLAN 10 deliberately uses
`10`, replacing its old `0a`; VLAN 20 retains `14` and guest retains `ff`.

| VLAN | Subnet ID | Public /64 example | ULA                      | Gateway owner |
| ---- | --------- | ------------------ | ------------------------ | ------------- |
| 10   | `10`      | `…:1d10::1/64`     | `fdc0:ffee:215:10::1/64` | Office CRS309 |
| 20   | `14`      | `…:1d14::1/64`     | `fdc0:ffee:215:14::1/64` | Office CRS309 |
| 4000 | `ff`      | `…:1dff::1/64`     | `fdc0:ffee:215:ff::1/64` | RB5009        |

The public examples assume an illustrative parent ending `1d00::/56`; the
actual ISP prefix is dynamic. VLANs 1/30/50/60 remain IPv4-only.

`office-crs309-pd` is a DHCPv6 server on transit with `prefix-pool=static-only`.
Its static /60 binding is restricted to the inspected CRS309 DUID and IAID 4090.
The server installs a route to that /60 through the switch's link-local address.
The switch creates `office-pd`, allocating /64s, from this delegation.

The [sync-office-pd.rsc](sync-office-pd.rsc) system-script body derives the /60
from `spectrum-pd`, updates the static binding on renumbering and withdraws it
on loss. It runs on ISP DHCPv6 events and every minute as a watchdog. Binding
lifetimes are capped at five minutes and one minute less than remaining ISP
validity. No write occurs when settings are unchanged. A short IPv6 interruption
is possible during renumbering until the switch renews; ULA remains stable.

Do not create an overlapping child pool on the RB5009: RouterOS rejects it.
The parent allocator does not reserve the static /60, so all other local /64
allocations must stay outside IDs `10`-`1f`. Guest is explicitly pinned to `ff`.

Transit uses `fdc0:ffee:215:fe::1/64` on the router and `::2` on the switch,
without RA or a public prefix. A static route for `fdc0:ffee:215:10::/60` points
to the switch. The switch's IPv6 default points to the router's transit ULA.

### Pinning /64s on the switch

Within the delegated /60, VLAN 10 uses offset 0 and VLAN 20 uses offset 4:

```routeros
/ipv6 address add address=::1/64 from-pool=office-pd interface=vlan10-internal advertise=yes
/ipv6 address add address=::4:0:0:0:1/64 from-pool=office-pd interface=vlan20-servers advertise=yes
```

These are existing configuration, not commands to add again. ULA gateways are
ordinary static addresses from the table above. The old RB5009 VLAN 10/20
address definitions and interfaces have been removed.

### Firewall

**The v4 and v6 filter chains have opposite shapes and this matters.** v4 forward is
default-accept with targeted drops (cameras get no new outbound connections, guest cannot
reach `LAN` or `RESTRICTED`). v6 forward is stock defconf: default-deny, ending in
`drop everything else not coming from LAN`.

The consequence is that anything outside the `LAN` list gets v4 connectivity for free and
no v6 connectivity at all. Guest needed three explicit v6 rules above that final drop to
mirror its v4 policy - drop to `LAN`, drop to `RESTRICTED`, accept to `WAN`, in that
order. Cameras need no equivalent: VLAN 60 has no v6 address and no RA, so the final drop
covers it.

The one exception to guest's `LAN` drop is `guest: voucher portal`, an accept above it for
TCP 443 to envoy-internal (10.1.25.42), so the captive portal's redirect to
`voucher.greyrock.io` loads. It has no connection-state match, because the drop below it
has none either and would otherwise catch the rest of the connection.

Work (VLAN 4001) is internet-only: `work: internet only` drops anything from `WORK` not
bound for `WAN`, and `guest: no work` keeps guest out of it. Both sit after the guest
rules. VLAN 4001 has no v6 address and no RA, so the final v6 drop covers it, as for
cameras. It exists so a work laptop can join Wi-Fi before anyone signs in, which the
guest voucher portal does not allow.

Newly added v6 rules can show the `I` (invalid) flag briefly while interface lists
resolve. It clears on its own.

### Router advertisements

The RB5009 advertises only guest. Its old per-interface VLAN 10/20 ND entries
have zero router lifetime and their VLAN interfaces are disabled. They were used
to withdraw the old default router during migration. The default `interface=all`
entry remains for guest with DNS advertisement off.

The Office CRS309 advertises public and ULA /64s on VLANs 10/20, using explicit
per-interface ND entries (10–30 second intervals, three-minute router lifetime).
Its default `interface=all` entry is disabled. Prefix defaults are five minutes
valid and 4m30s preferred; public lifetimes are also constrained by delegation.
DNS advertisement, managed and other flags are off: clients retain SLAAC and the
IPv4 DNS servers supplied by DHCP.

## DNS

The router runs `allow-remote-requests` with Quad9 upstream, but clients are pointed at
`ctrld` on 10.1.30.2 and `ctrld-b` on 10.1.30.4, which forward `greyrock.io` and `10.in-addr.arpa` back to the
router at 10.1.30.1:53. That split is what makes internal names resolve while everything
else goes out to Control D over DoH3 (QUIC, UDP 443). The Office CRS309 now repeats
mDNS between `vlan10-internal` and `vlan20-servers`; repeating is disabled on the RB5009.
Client DNS still crosses transit because both ctrld containers live on the RB5009.

Every static entry is either hand-made and commented, or created by automation that tracks
it with a TXT ownership record:

| Comment        | Source               | Notes                                                                                           |
| -------------- | -------------------- | ----------------------------------------------------------------------------------------------- |
| `static-lease` | Hand-made            | One per static DHCP lease, named from the MAC address list in 1Password                         |
| `switch`       | Hand-made            | Nine switches, 10.1.0.10-.12/.20-.22/.30-.32                                                    |
| `ap`           | Hand-made            | Nine Unleashed APs, plus `unleashed` (10.1.0.2), the management address that follows the master |
| `router`       | Hand-made            | `office-gw.internal.greyrock.io` → 10.255.0.1, TTL five minutes                                 |
| `service`      | Hand-made            | `k8s.internal.greyrock.io` → 10.1.25.50, the Kubernetes API                                     |
| `camera`       | Hand-made            | `courtyard-porch-doorbell`                                                                      |
| _(none)_       | `external-dns`       | Owned via TXT registry, `txtPrefix: k8s.main.%{record_type}-`                                   |
| _(none)_       | `dexd` on codswallop | Owned via `a-<name>` TXT records; all point at 10.1.25.21                                       |

To find an unlabelled hand-made entry, filter on `!comment` - `comment=""` does not match an
unset comment.

`external-dns` only deletes records it holds an ownership TXT for, so hand-made entries are
safe from it.

`office-gw.internal.greyrock.io` exists so `external-dns` can reach the REST API by a
name the router's certificate actually covers. Verified from inside the cluster: the name
resolves through CoreDNS and the certificate validates without `-k`.

### Service exposure

`www-ssl` is restricted to 10.1.0.0/24, 10.1.10.0/24, 10.1.20.0/24 and 10.1.30.0/24 -
management, internal, servers and containers. IoT, cameras, guest and the WAN are
excluded. Winbox is a separate service on 8291 and is unaffected.

The cluster arrives as a node address, not a pod address: Cilium runs `masquerade: true`
with `routingMode: native` and `ipv4NativeRoutingCIDR: 10.244.0.0/16`, so pod traffic to
10.255.0.1 leaves that CIDR and is masqueraded to the node's server-VLAN address.

The CLI keyword is now `available-from`; `address=` still works but warns that it is
deprecated.

## DHCP

Servers `dhcp-vlan1`, `dhcp-vlan10` and `dhcp-vlan20` listen on
`vlan4090-transit`, with relay addresses `10.1.0.1`, `10.1.10.1` and `10.1.20.1`.
The Office CRS309 relays each VLAN to `10.255.0.1`. Existing server objects,
pools, static leases, domains and client gateway options are preserved. All other
DHCP servers remain directly attached.

Initial discovery and rebinding use broadcasts through the relay. Normal T1
renewal uses unicast to server `10.255.0.1`, routed through the CRS309. Keep the
transit input path and return routes to the client networks available. A DHCP
connection showing zero reply packets is not proof of failed renewal: a VLAN 10
packet-level test received ACKs while that RB5009 counter remained zero. Check
matching request/ACK transaction IDs at the client; relay request/response totals
alone do not measure renewal success either.

Leases are 8h everywhere except guest at 4h. Pools start at `.100` on VLAN 1, `.2` on
guest and work, and `.6` on everything else.

Work hands out Cloudflare (1.1.1.1, 1.0.0.1) for DNS; every other network hands out ctrld.

Every network except VLAN 20, guest and work hands out the domain name `internal.greyrock.io`.
VLAN 20 has none, so DHCP clients there (Talos) get no search domain from it.

VLAN 10 also hands out a search list of `internal.greyrock.io` then `greyrock.io` (option
119, `domain-search-internal`). RouterOS does not encode option 119 itself, so the value is
the raw RFC 1035 label encoding in hex.

Every known device has a **static lease** on the address it already had. The lease comment
is its name as written in the CSV, and it has a `static-lease` DNS entry with the DNS name. ctrld resolves client names by
reverse lookup against the router, so that one name per address is what shows up there.
Names come from the "Network Device MAC Addresses" document in 1Password: lowercased, with
the room first (`gameroom`, `livingroom`, `diningroom`, `master-bedroom`,
`upstairs-bathroom`, `downstairs-bathroom`), and plugs as `<room>-plug-<rest>` with
`christmas` last.

There is no DHCP lease script. Anything still dynamic has no DNS name and shows in ctrld
as a bare address, which is the cue to give it a static lease. Deliberately dynamic:
everything on guest and work.

To add a device, add it to the CSV and find its lease - it is the only dynamic one outside
guest and work: `/ip dhcp-server lease print where dynamic and server!=dhcp-vlan4000 and
server!=dhcp-vlan4001`. Then on the lease: `make-static`, set `comment="<CSV name>"`, then
`/ip dns static add name=<name>.internal.greyrock.io address=<ip> comment=static-lease`.

### Network boot

The router's built-in TFTP server hands out netboot.xyz on VLANs 10 and 20; the menus
and installers load from `boot.netboot.xyz` over HTTPS. The boot files live in
`usb1/tftp`, and each has an `/ip tftp` entry limited to those two subnets. The VLAN 10
and 20 DHCP networks set `next-server=10.255.0.1` and `boot-file-name` to
`netboot.xyz-snponly.efi`, which uses the firmware's network driver rather than iPXE's
own. `netboot.xyz.efi` (iPXE drivers) and `netboot.xyz.kpxe` (BIOS) are served too, if a
machine needs them.

## Containers

Three, all on `vlan30-container` via veth, with layers and tmpdir shared on `usb1/pull`.

| Container | veth           | Address   | Purpose                             |
| --------- | -------------- | --------- | ----------------------------------- |
| `ctrld`   | `veth-ctrld`   | 10.1.30.2 | DNS, split-horizon to the router    |
| `ctrld-b` | `veth-ctrld-b` | 10.1.30.4 | Second DNS, same config             |
| `acme`    | `veth-acme`    | 10.1.30.3 | Let's Encrypt, see `router-acme.md` |

VLAN 30 is in the `LAN` interface list, so containers reach the router without a
dedicated firewall rule. Bridge membership comes from `pvid=30` on the bridge port alone -
the `/interface bridge vlan` entry for 30 needs no `untagged=` edit.

`/container envs` takes `key=`, and `/container mounts` takes `list=`, with
`mountlists=` on `/container add`. Every published guide uses `name=`/`mounts=`.

### Two ctrlds

`ctrld` and `ctrld-b` share the `ctrld` mount list, so both read the one
`usb1/ctrld/ctrld.toml`. That works because the listener binds `0.0.0.0` and ctrld never
writes to that directory. Clients outside `LAN` reach them through the `dns to ctrld`
forward accepts, which match the `ctrld` address list holding both addresses.

`[service]` sets `cache_enable = true` and `cache_serve_stale = true`. ctrld does not
cache by default, so without it every query goes out to Control D. Each instance keeps its
own cache, and a container restart empties it.

It also sets `log_level = "warn"`, `metrics_listener = "0.0.0.0:9603"` and
`metrics_query_stats = true`. Container output goes to the router log under the
`container` topic, which a logging rule forwards to VictoriaLogs. The metrics carry
per-client query counts by hostname, and Prometheus scrapes both instances through the
`ctrld` ScrapeConfig.

### Image updates

The image each container runs is pinned in
`kubernetes/apps/network/router-containers/app/config/containers`. Renovate opens a PR
when a new tag is released. After it is merged, the `router-containers` CronJob (every 15 minutes) finds every
container whose `remote-image` is that image with a different tag, and sets
`remote-image` over the REST API. That is the whole update: with
`ignore-remote-image-change=no`, RouterOS stops the container, repulls and starts it on
its own - about 1 second when the layers are cached. An explicit `repull` straight after
is rejected with 400 while the container is busy. A container that already matches is left alone.

- The job logs in as the `router-containers` user: group `read,write,web,api,rest-api`, only
  from 10.1.20.0/24. Its credentials are the `containers-username`/`containers-password`
  fields of the `MikroTik Router` 1Password item. `rest-api` alone is not enough:
  without `web` and `api` every `/rest/container` call returns 500
  `not allowed (9)`.
- Containers on the same image are done one at a time. A container that answered DNS on
  its veth address before the change must answer again after it, and before any is
  changed, every other container on that image that answers DNS must still be answering.
  Any failure ends the run. That is what keeps one of the two ctrlds serving.
- The terraform-routeros provider was ruled out: its `routeros_container` still uses
  `envlist`/`mounts` and cannot set `name`, which RouterOS 7.21+ changed. The fix,
  upstream PR #910, was unmerged at the time.

## BGP

Local AS 64513, explicit router-id 10.1.0.1 from `/routing id`. The router ID is
a protocol identifier; the reachable RB5009 peer address is 10.255.0.1.

| Peer       | Address    | AS    | Source                                          |
| ---------- | ---------- | ----- | ----------------------------------------------- |
| kerfuffle  | 10.1.20.10 | 64514 | Cilium, `CiliumBGPClusterConfig`                |
| codswallop | 10.1.20.12 | 64515 | FRR, `docker/codswallop/00-frr/config/frr.conf` |

The Cilium config selects all linux nodes with one `localASN` and
`peerAddress: 10.255.0.1`, so any k8s node peers the same way. NAS FRR uses the
same router endpoint. The router connections `cilium-transit` and
`codswallop-transit` explicitly source from 10.255.0.1. The obsolete connections
sourced from 10.1.0.1 have been removed.

codswallop advertises `10.1.25.21/32`. Both servers also peer directly with the
Office CRS309 (10.1.20.1, AS 64516), which learns the service /32s without a
router detour. Cilium and FRR use eBGP multihop TTL 2 toward office-gw because
that retained session now crosses the CRS309/transit hop. Router peer sessions
remain established for guest, WireGuard and other router-originating paths.

RouterOS 7 specifics: an `instance` is mandatory and carries the AS - `as=` on a
connection is rejected. The AFI parameter is `afi`, not `address-families`. `router-id`
and `local.router-id` are both invalid on a connection; it comes from `/routing id`.

`10.1.25.0/24` is the Cilium load-balancer range, learned over BGP. It is not a VLAN and
has no SVI.
