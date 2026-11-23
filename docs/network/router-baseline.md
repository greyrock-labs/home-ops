# Router baseline

`office-gw`, an RB5009UG+S+ on RouterOS 7.25.1, the only gateway since the UniFi removal
(cut over 2026-11-20). Every VLAN except 10 and 20 is routed here; `office-crs309` routes
those two in hardware (see [tools/l3/README.md](tools/l3/README.md)). Its management
endpoint is `office-gw.internal.greyrock.io` (10.1.99.1). See
[switch-baseline.md](switch-baseline.md) for the switch side and
[router-acme.md](router-acme.md) for certificates.

Configs are not stored here. This documents the _decisions_ and the conventions that the
running config cannot explain about itself.

## Interfaces and addressing

The trunk to `office-crs309` is `sfp-sfpplus1`, carrying VLANs 10, 20, 50, 60, 99, 4000,
4001 and 4090 (transit) tagged on a VLAN-filtering `bridge`. `ether2`-`ether8` are untagged access ports on
VLAN 99 for bench and recovery work.

| Interface          | IPv4            | Purpose                                                      |
| ------------------ | --------------- | ------------------------------------------------------------ |
| `ether1`           | DHCP (Spectrum) | WAN                                                          |
| `vlan4090-transit` | 10.255.0.1/30   | Transit to `office-crs309` (10.255.0.2), which owns VLAN 10/20 |
| `vlan30-container` | 10.1.30.1/24    | Router containers                                            |
| `vlan50-iot`       | 10.1.50.1/24    | IoT                                                          |
| `vlan60-cameras`   | 10.1.60.1/24    | Cameras                                                      |
| `vlan99-mgmt`      | 10.1.99.1/24    | Switch and AP management                                     |
| `vlan4000-guest`   | 192.168.23.1/24 | Guest                                                        |
| `vlan4001-work`    | 192.168.24.1/24 | Work                                                         |
| `wg-public-edge`   | 10.254.45.1/24  | WireGuard to skedaddle, see [public-edge.md](public-edge.md) |

VLAN 1 carries no addresses; it is only the native VLAN that RSTP runs on.

A static route sends 10.255.255.10/32, `office-crs309`'s management loopback, via 10.255.0.2.

### Interface lists

`LAN` holds `vlan4090-transit`, `vlan30-container`, `vlan50-iot` and `vlan99-mgmt`.
Traffic from VLANs 10 and 20 arrives on transit, so it keeps its `LAN` policy. `WAN` is `ether1`. `vlan60-cameras` is `RESTRICTED`, `vlan4000-guest` is
`GUEST` and `vlan4001-work` is `WORK`, all deliberately outside `LAN` - the v4 input chain
and both v6 chains end in a drop for anything not from `LAN`.

`LOCALSVC` covers cameras, guest and work so they can still reach the router for DHCP and
DNS despite being outside `LAN`. It does this with `include=RESTRICTED,GUEST,WORK` rather
than direct members - the lists are pulled in dynamically.

**`/interface list member print` shows nothing for a list built from includes.** An empty
member listing is not an empty list; check `/interface list print` for the `INCLUDE`
column before concluding anything is missing.

## IPv6

Spectrum delegates a /56 over DHCPv6-PD (`spectrum-pd`). The client requests both halves:

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
same /56 comes back. Replacing the router hardware is what changes it and renumbers
everything downstream - the 2026-11-20 cutover from the UDM did exactly that.

### Subnets

Public /64s come from `spectrum-pd` (`from-pool=spectrum-pd`); the subnet IDs match the ULA.
IDs `00`-`1f` are a /59 delegated to `office-crs309` by the `sync-office-pd` script
([sync-office-pd.rsc](sync-office-pd.rsc)), so VLAN 10 and 20 live on the switch; keep
other allocations out of that range. Transit is ULA `fdc0:ffee:215:fe::/64`, no RA prefix.

| VLAN | Subnet ID | Public address    | ULA                      |
| ---- | --------- | ----------------- | ------------------------ |
| 10   | `0a`      | `::a:0:0:0:1/64`  | `fdc0:ffee:215:a::1/64`  |
| 20   | `14`      | `::14:0:0:0:1/64` | `fdc0:ffee:215:14::1/64` |
| 4000 | `ff`      | `::ff:0:0:0:1/64` | `fdc0:ffee:215:ff::1/64` |

VLANs 30, 50, 60, 99 and 4001 are IPv4-only. Router advertisements come from the default
`interface=all` ND entry with DNS advertisement off: clients take SLAAC and keep the IPv4
DNS servers DHCP gives them.

### Firewall

**The v4 and v6 filter chains have opposite shapes and this matters.** v4 forward is
default-accept with targeted drops (cameras get no new outbound connections beyond DNS to
ctrld and NTP, guest cannot reach `LAN` or `RESTRICTED`). v6 forward is stock defconf: default-deny,
ending in `drop everything else not coming from LAN`.

The consequence is that anything outside the `LAN` list gets v4 connectivity for free and
no v6 connectivity at all. Guest needed three explicit v6 rules above that final drop to
mirror its v4 policy - drop to `LAN`, drop to `RESTRICTED`, accept to `WAN`, in that
order. Cameras and work need no equivalent: they have no v6 address and no RA, so the
final drop covers them.

The one exception to guest's `LAN` drop is `guest: voucher portal`, an accept above it for
TCP 443 to envoy-internal (10.1.25.42), kept for the voucher manager. It has no
connection-state match, because the drop below it has none either and would otherwise
catch the rest of the connection.

Work (VLAN 4001) is internet-only: `work: internet only` drops anything from `WORK` not
bound for `WAN`, and `guest: no work` keeps guest out of it. It exists so a work laptop
can join Wi-Fi before anyone signs in.

Newly added rules can show the `I` (invalid) flag briefly while interface lists resolve.
It clears on its own.

## DNS

The router runs `allow-remote-requests` with Quad9 upstream, but clients are pointed at
`ctrld` on 10.1.30.2 and `ctrld-b` on 10.1.30.4, which forward `greyrock.io` and
`10.in-addr.arpa` back to the router. That split is what makes internal names resolve
while everything else goes out to Control D. ctrld's `Minimal` network covers VLANs 20, 30
and 99; `Internal`, `IoT`, `Cameras` and `Guest` have their own Control D profiles.

`office-crs309` repeats mDNS between VLANs 10 and 20. It does not answer DNS: a host that
asks its VLAN 10/20 gateway for DNS gets no answer, so everything must use ctrld.

**Every DNS query from `LAN`, cameras and guest goes through ctrld, whatever server the
client asked for, except from the servers VLAN.** `dstnat` rules `dns: force lan to ctrld`,
`dns: force guest to ctrld` and `dns: force cameras to ctrld` (UDP and TCP 53) send it to 10.1.30.2, excluding ctrld's own
addresses (the `ctrld` address list) so its forwards to the router still work, and excluding
`vlan30-container` itself, where a redirect would reply off-path. DNS-over-TLS (853) is
rejected from the same networks (guest has its own `guest: reject encrypted dns 853` pair).
**VLAN 20 (servers, the cluster) is never captured**
(`src-address=!10.1.20.0/24` on both): servers resolve wherever they are configured to.
Work is not redirected. DNS-over-HTTPS cannot be caught this way.

Every static entry is either hand-made and commented, or created by automation that tracks
it with a TXT ownership record:

| Comment         | Source               | Notes                                                                   |
| --------------- | -------------------- | ----------------------------------------------------------------------- |
| `static-lease`  | Hand-made            | One per reservation, named from the reservations CSV                    |
| `infra`         | Hand-made            | Router, switches, APs, `unleashed` (10.1.99.2) and time1-4              |
| `service`       | Hand-made            | `k8s.internal.greyrock.io` → 10.1.25.50, the Kubernetes API             |
| _(none)_        | `external-dns`       | Owned via TXT registry, `txtPrefix: k8s.main.%{record_type}-`           |
| `dexd-mikrotik` | `dexd` on codswallop | Owned via `a-<name>` TXT records (`heritage=dexd-mikrotik`); 10.1.25.21 |

To find an unlabelled hand-made entry, filter on `!comment` - `comment=""` does not match an
unset comment.

`external-dns` and dexd only delete records they hold an ownership TXT for, so hand-made
entries are safe from them.

`office-gw.internal.greyrock.io` exists so `external-dns` and dexd can reach the REST API by
a name the router's certificate covers.

### Service exposure

`www-ssl` is restricted to 10.1.10.0/24, 10.1.20.0/24, 10.1.30.0/24 and 10.1.99.0/24 -
internal, servers, containers and management. IoT, cameras, guest and the WAN are
excluded. `www`, `api` and `api-ssl` are disabled. Winbox is a separate service on 8291.

The cluster arrives as a node address, not a pod address: Cilium runs `masquerade: true`
with `routingMode: native` and `ipv4NativeRoutingCIDR: 10.244.0.0/16`, so pod traffic to
the router leaves that CIDR and is masqueraded to the node's server-VLAN address.

The CLI keyword is `available-from`; `address=` still works but warns that it is
deprecated.

### API users

| User          | Group         | Used by                                   | 1Password                 |
| ------------- | ------------- | ----------------------------------------- | ------------------------- |
| `externaldns` | `externaldns` | external-dns MikroTik webhook             | `MikroTik - External DNS` |
| `dexd`        | `dexd`        | dexd-mikrotik on codswallop               | `MikroTik - dexd`         |
| `acme`        | `acme`        | acme.sh deploy hook, see `router-acme.md` | -                         |

The API groups are `read,write,web,api,rest-api` with no `ssh`, `winbox` or `local`.
`rest-api` alone is not enough: without `web` and `api` every REST call returns 500
`not allowed (9)`.

## DHCP

Every DHCP server is directly attached to its VLAN interface, except VLAN 10 and 20: those
listen on `vlan4090-transit` with `relay=10.1.10.1` / `relay=10.1.20.1`, fed by relays on
`office-crs309`. Leases are 8h everywhere
except guest at 4h. Pools start at `.100` on VLAN 99, `.2` on guest and work, and `.6` on
everything else.

Every network except work hands out ctrld for DNS (guest lands in ctrld's `Guest` Control D
profile), and every network except guest and work hands out the four time servers
(10.1.20.16-.19) for NTP. Every network except VLAN 20, guest and work also hands out the
domain `internal.greyrock.io`.

**VLAN 20 hands out no domain.** Talos takes it as a search domain and passes it to every
pod, and `*.internal.greyrock.io` answers NOERROR with no records for names that do not
exist (public resolvers included). glibc moves on to the next candidate, but musl (Alpine)
stops at the first NOERROR, so with `ndots:5` an Alpine container's
`dl-cdn.alpinelinux.org` became `dl-cdn.alpinelinux.org.internal.greyrock.io` and failed
with "no address for host". This broke every image build's `apk add` after the 2026-11-20
cutover until the domain was removed.

Work hands out Cloudflare and Google (1.1.1.1, 8.8.8.8) so a work VPN client does not
depend on anything at home.

Every known device has a **static lease** on the address it already had, first taken from
`~/Downloads/dhcp-reservations-2026-11-19.csv` (UniFi fixed and current addresses) and kept
in step with it since. Reservations for hosts with static addresses (Scrypted, Bambuddy,
Codswallop) only hold the address and name. The lease comment is its name, and it has a `static-lease` DNS entry. ctrld
resolves client names by reverse lookup against the router, so that one name per address
is what shows up there.

There is no DHCP lease script. Anything still dynamic has no DNS name and shows in ctrld
as a bare address, which is the cue to give it a static lease. Deliberately dynamic:
everything on guest and work.

To add a device, find its lease - it is the only dynamic one outside guest and work:
`/ip dhcp-server lease print where dynamic and server!=dhcp-vlan4000 and
server!=dhcp-vlan4001`. Then on the lease: `make-static`, set `comment="<name>"`, then
`/ip dns static add name=<name>.internal.greyrock.io address=<ip> comment=static-lease`.

### Network boot

The router's built-in TFTP server hands out netboot.xyz on VLANs 10 and 20; the menus
and installers load from `boot.netboot.xyz` over HTTPS. The boot files live in
`usb1/tftp`, and each has an `/ip tftp` entry limited to those two subnets. The VLAN 10
and 20 DHCP networks set `next-server` to 10.255.0.1 (the router's transit address) and `boot-file-name` to
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
dedicated firewall rule. Bridge membership comes from `pvid=30` on the bridge port alone.

`/container envs` takes `key=`, and `/container mounts` takes `list=`, with
`mountlists=` on `/container add`. Every published guide uses `name=`/`mounts=`.

### Two ctrlds

`ctrld` and `ctrld-b` share the `ctrld` mount list, so both read the one
`usb1/ctrld/ctrld.toml`. That works because the listener binds `0.0.0.0` and ctrld never
writes to that directory. Clients outside `LAN` reach them through the `dns to ctrld`
forward accepts, which match the `ctrld` address list holding both addresses. After a
config change, restart them one at a time so DNS never goes fully down.

`[service]` sets `cache_enable = true` and `cache_serve_stale = true`. ctrld does not
cache by default, so without it every query goes out to Control D. Each instance keeps its
own cache, and a container restart empties it.

### Image updates

Container images are updated by hand: set `remote-image` to the new tag and RouterOS
stops, repulls and starts the container on its own. Do one ctrld at a time.

## BGP

Local AS 64513 (instance `greyrock`), router ID 10.1.99.1 from `/routing id`. Both
sessions are sourced from transit, 10.255.0.1, with `multihop=yes` (the peers set eBGP
multihop 2). `office-crs309` (AS 64516) peers with the same hosts on 10.1.20.1 and imports
only the service /32s. Next hops resolve through the static VLAN 20 route, which is
`scope=10` for that reason.

| Peer       | Address    | AS    | Source                                          |
| ---------- | ---------- | ----- | ----------------------------------------------- |
| kerfuffle  | 10.1.20.10 | 64514 | Cilium, `CiliumBGPClusterConfig`                |
| codswallop | 10.1.20.12 | 64515 | FRR, `docker/codswallop/00-frr/config/frr.conf` |

The Cilium config selects all linux nodes with one `localASN` and both peers,
so any k8s node peers the same way. codswallop advertises `10.1.25.21/32`; Cilium
advertises the load-balancer /32s.

RouterOS 7 specifics: an `instance` is mandatory and carries the AS - `as=` on a
connection is rejected. The AFI parameter is `afi`, not `address-families`. `router-id`
and `local.router-id` are both invalid on a connection; it comes from `/routing id`.

`10.1.25.0/24` is the Cilium load-balancer range, learned over BGP. It is not a VLAN and
has no SVI.
