# Office CRS309 routing

The Office CRS309 owns the VLAN 1, 10 and 20 gateways. VLANs 10/20 moved on
2026-10-16; VLAN 1 moved on 2026-10-19. The RB5009's old gateway addresses are
removed. Rollback cleanup completed on 2026-10-26.
See [router-baseline.md](router-baseline.md) and
[switch-baseline.md](switch-baseline.md) for the current configuration decisions.

## Addressing and ownership

| Item                | RB5009                 | Office CRS309          |
| ------------------- | ---------------------- | ---------------------- |
| Management endpoint | 10.255.0.1             | 10.1.0.10/32           |
| VLAN 1 gateway      | via 10.255.0.2         | 10.1.0.1/24            |
| VLAN 10 gateway     | via 10.255.0.2         | 10.1.10.1/24           |
| VLAN 20 gateway     | via 10.255.0.2         | 10.1.20.1/24           |
| Transit VLAN 4090   | 10.255.0.1/30          | 10.255.0.2/30          |
| Transit ULA         | fdc0:ffee:215:fe::1/64 | fdc0:ffee:215:fe::2/64 |
| ASN                 | 64513                  | 64516                  |
| IPv4 default        | WAN                    | 10.255.0.1             |
| IPv6 default        | ISP                    | fdc0:ffee:215:fe::1    |

Transit is tagged on bridge and sfp-sfpplus1 only, on both devices. Other
switches remain L2. Bridge and routed VLAN MTUs on the CRS309 are 9000; its
Ethernet L2MTUs remain 10218. NAS and Kubernetes remain on Office C08ZP ports
1/1/7 and 1/1/8, both negotiated at 10G, sharing the 10G switch uplink.

Client and server gateway IPs did not change. The NAS retains its static
`default via 10.1.20.1`; no host network edit was needed.

```text
VLAN 10 -> CRS309 -> VLAN 20 NAS
VLAN 10 -> CRS309 -> service /32 -> NAS/Kubernetes
VLAN 1 <-> CRS309 <-> VLAN 10/20
VLAN 1/10/20 -> CRS309 -> transit -> RB5009 -> WAN / router services / other VLANs
guest / WireGuard -> RB5009 -> transit -> CRS309 -> server/service
```

## BGP

Cilium and NAS FRR peer with the RB5009 at 10.255.0.1/AS64513 and directly
with the CRS309 at 10.1.20.1/AS64516. The router path requires eBGP TTL 2
on Cilium and FRR across the switch/transit hop. The CRS309 imports only Cilium
service /32s within 10.1.25.0/24 and NAS 10.1.25.21/32, and exports nothing.
NAS re-advertisements of learned Cilium routes are filtered by the switch.

## Hardware forwarding and management

IPv4 and IPv6 L3 hardware routing are enabled. Trusted client/server and service
routes use the main routing table and are eligible for hardware forwarding.
BGP negotiation, DHCP relay, mDNS repeating and the switch's own control plane
use CPU. A route H flag alone does not prove measured wire-speed performance.

VLAN 1 uses `10.1.0.1/24` as its primary subnet address on the bridge.
`10.1.0.10/32` is the switch's management alias; do not expand it to a second
/24 on the same interface. This makes ARP resolution use the gateway address
and allows devices to learn the new gateway MAC during handoff. VLAN 1 remains
untagged on the physical trunks; the bridge keeps its dynamic VLAN 1 membership.

The RB5009 routes 10.1.0.0/24 through 10.255.0.2 and manages itself through
10.255.0.1. `office-gw.internal.greyrock.io` resolves to that transit address;
router API clients retain the hostname and TLS verification. Router syslog also
sources from 10.255.0.1. The protocol router ID remains 10.1.0.1 independently
of gateway ownership.

Management routes directly between VLANs 1, 10 and 20. The temporary management
/25 detours, CPU-redirect ACLs, source recovery table/rule and RB5009 return
exception have been removed. The switch's control-plane input filters remain
active; no inter-VLAN stateful firewall is configured there.

WAN, WireGuard, router-hosted DNS and VLANs 50/60/4000 still involve the RB5009.
Guest/camera policies and existing DNS/NTP/portal exceptions were retained;
transit's LAN membership preserves the existing interface-list policy.

## IPv6 delegation

Reserve hexadecimal subnet IDs `10`-`1f` within the ISP /56 for the switch /60.
Use matching public and ULA IDs: VLAN 10 uses `10`, VLAN 20 `14`, guest `ff`.
Transit uses ULA ID `fe` without public addressing or RA.

RouterOS rejects an overlapping child pool on the RB5009. Instead,
`office-crs309-pd` is a static-only DHCPv6 server on transit, delegating one /60
binding to the switch DUID and fixed IAID 4090. The switch creates `office-pd`
with /64 allocation size. It uses offset 0 for VLAN 10 and offset 4 for VLAN 20.
The server installs the public return route; a static ULA /60 route uses transit.

[sync-office-pd.rsc](sync-office-pd.rsc) is the source for system script
`sync-office-pd` on the RB5009. The file defaults to read-only preview; the
installed body has `applyChanges=true`. It runs on ISP DHCPv6 events and every
minute as a watchdog. Binding lifetime is at most five minutes and one minute
less than remaining ISP validity. Unchanged settings are not rewritten.
On loss it disables the server and removes the binding; on renumbering it
replaces the binding. A brief public IPv6 interruption until client renewal is
possible; ULA remains stable. Keep other ISP-pool allocations outside `10`-`1f`.

The router-facing CRS309 trunk must be `multicast-router=permanent`. Initial
acquisition worked without this but later renewal stopped under snooping;
setting the actual router port permanently restored acquisition and renewal.
Do not enable a second global querier to solve this transit-specific issue.

The old RB5009 RAs were withdrawn and VLAN 10's old prefixes deprecated.
Withdrawing `advertise` does not remove dynamic ND prefix entries synchronously;
wait for their disappearance before installing static deprecation entries.
The switch uses explicit per-VLAN ND, DNS advertisement off, pure SLAAC.

## DHCP, discovery and boot

- Existing DHCP server objects and leases stay on the RB5009. VLAN 1/10/20 servers
  listen on transit and identify their relays by the unchanged gateway IPs.
  Switch relays target 10.255.0.1. Gateway, DNS and search-domain options stay intact.
- mDNS repeating moved from the router to the CRS309, between VLANs 10 and 20.
- TFTP files remain on the RB5009, with the same source-subnet restrictions.
  DHCP `next-server` for VLANs 10/20 is now 10.255.0.1.

## Completed rollback cleanup (2026-10-26)

After a week of operation, the one-time cutover and rollback scripts were removed
from both devices, along with the retained configuration they restored:

- RB5009: old VLAN 1/10/20 gateway addresses, VLAN 10/20 public and ULA addresses,
  ND and deprecated-prefix entries, disabled VLAN interfaces and their LAN-list
  memberships, and the unused router-side VLAN 10/20 bridge tagging entries.
  The latter tagged only the router CPU and its single switch uplink; they did
  not carry traffic between physical ports.
- RB5009: disabled BGP connections sourced from 10.1.0.1 and the disabled
  switch-management return firewall exception.
- CRS309: unused default via 10.1.0.1, management /25 detours, three disabled
  CPU-redirect ACLs, and the temporary 10.1.0.252 host route, source rule and
  `l3-recovery` table.
- Both devices: temporary 10.255.0.4/32 and 10.255.0.5/32 handoff addresses and
  their counterpart routes. No migration scheduler remained.

Retained configuration was reviewed and migration-era comments were replaced
with their ongoing purpose. This includes IPv4/IPv6 transit, gateways, return
and default routes, and control-plane firewall rules. The installation comment
in `sync-office-pd` was updated without changing its executable behavior.

The permanent dependencies remain: transit VLAN 4090, CRS309 gateways/defaults
and management alias, hardware routing, RB5009 return routes, DHCP servers and
relays, active BGP peers and filters, and IPv6 delegation. The RB5009 bridge and
192.168.88.1/24 Netinstall address remain. Keep `sync-office-pd`, its scheduler
and DHCPv6 event hook. Names such as `greyrock-l3` and `l3-cilium-in` identify
permanent Layer 3 BGP configuration; they are not recovery artifacts.

Cleanup validation is recorded below. Recovery now requires deliberate
reconfiguration using the current baselines and wired management or console;
the one-time rollback scripts are no longer available.

## Validation and remaining checks

Rollback cleanup validation (2026-10-26):

- Post-change configuration audits found no cutover/rollback scripts, migration
  timers, temporary signal/recovery routes or migration-era comments on either
  device. Old VLAN interface references were absent on the RB5009.
- Both BGP sessions on each device retained their week-long uptimes. All seven
  CRS309 service /32s remained active and hardware offloaded; IPv4 and IPv6
  hardware routing remained enabled.
- Management SSH, router-to-switch and router-to-NAS reachability passed.
  NAS-to-VLAN-10 and management pings passed, as did NAS IPv4/IPv6 Internet pings.
  Kubernetes reported its node Ready; internal echo and public Forgejo returned
  HTTP 200. Both ctrld servers resolved the Kubernetes API, and the router API's
  hostname and TLS certificate validated (HTTP 401 without credentials).
- DHCP servers and relays retained their transit configuration and leases.
  VLAN 10 had lease activity after cleanup. No VLAN 1 client was bound, and no
  fresh VLAN 20 renewal or packet-level DHCP test was forced during cleanup.
- The delegated /60 remained bound and renewed after cleanup; the watchdog and
  ISP DHCPv6 hook remained installed. The retained script changed only its
  installation comment.
- Original local migration staging directories were absent or empty, and no
  NAS `/tmp/home-ops-vlan1/` files remained. Temporary private cleanup exports
  and staging files were removed after verification.

No device was rebooted and no production ISP lease was released. The earlier
camera isolation checks remain historical evidence; guest isolation was not
independently exercised during cleanup.

DHCP renewal investigation (2026-10-19):

- A temporary wired VLAN 1 client received an ACK to its unicast renewal in
  about 2 ms. Packet-level clients using the existing Scrypted VLAN 10 and NAS
  VLAN 20 reservations acquired leases through the relays, then received direct
  unicast renewal ACKs in about 1 ms with normal hardware routing enabled.
  Their static interface configurations were not changed; test leases were
  released and the temporary wired client and its dynamic lease were removed.
- The VLAN 10 test received ACKs even while its RB5009 connection showed zero
  reply packets. Transit is in the router's LAN interface list; the input
  firewall does not require these renewals to match the restricted/guest DHCP rule.
- Captures showed matching renewal ACKs for plugs 10.1.10.106 and 10.1.10.59.
  Both stopped retrying and established external TCP connections during the
  investigation. Temporary packet-copy rules also caused CPU forwarding, so
  this does not establish why their earlier retry loops occurred. No permanent
  DHCP or routing change was made; check these clients again at their next T1
  renewal before treating their intermittent problem as resolved.
- Temporary switch capture rules, device capture files and router DHCP debug
  logging were removed; sniffer settings were restored. Hardware routing remains
  enabled. The initial synthetic request from an unbound reservation was rejected
  with `unknown giaddr 0.0.0.0`; testing renewal after actual lease acquisition
  succeeded, so that rejection did not establish a production renewal failure.

VLAN 1 extension (2026-10-19):

- Wired NAS handoff with release-checked rollback; CPU and hardware routing
  checks passed. All 14 other management addresses answered from 10.1.0.1.
- A VLAN 1 switch learned 10.1.0.1 at the Office CRS309 MAC, reached the NAS and
  Internet (three pings each), and resolved the Kubernetes API through ctrld.
- A temporary DHCP client on that wired switch obtained a VLAN 1 lease through
  relay 10.1.0.1 from server 10.255.0.1, with the unchanged gateway/DNS options.
  The client and its test lease were removed afterward.
- Fresh VLAN 10-to-management SSH succeeded with no corresponding RB5009
  connection entry. Hardware routing is enabled and the management /24 has H.
- A camera-interface TCP probe from Scrypted 10.1.60.3 to management
  10.1.0.20:22 matched the RB5009 camera drop rule. Its counter increased by one;
  logs confirmed ingress VLAN 60 and intended egress transit. Guest remains
  verified by inspection rather than a guest-originated runtime test.
- Both devices retained two established BGP peers and all seven service /32s.
  Router API hostname TLS verification passed at 10.255.0.1; external-dns
  successfully updated a record through that endpoint. Internal echo and public
  Forgejo returned HTTP 200; NAS IPv6 Internet pings passed and delegation is bound.
- `flate test all`: 247 passed, two skipped for the unavailable kanidm-provision
  SSH secret. Rendered diff changed only the RB5009 peer address; Cilium
  Kustomize build, NAS Compose validation and whitespace checks passed.
- Automatic rollback timers and temporary device test artifacts were removed.

VLAN 10/20 validation (2026-10-16):

- `flate test all`: 244 passed, two skipped for unavailable kanidm-provision SSH
  credentials. Rendered diffs contained only the additive peer and multihop field.
  Cilium Kustomize build, NAS Compose validation and whitespace checks passed.
- Device-local scripts parsed; handoff/recovery access used wired VLAN 1.
- Isolated documentation-prefix delegation: fixed /60 acquisition, renumbering,
  loss/expiry and recovery. Production renewal remained healthy across cycles.
- Both original router peers and both new switch peers established. All seven
  service /32s installed with the correct direct server next hops; NAS-learned
  copies of Cilium routes filtered.
- NAS SSH reachable with hardware routing enabled;
  NAS IPv4/IPv6 Internet pings succeeded. Kubernetes API worked using its IP with
  hostname TLS verification. Internal echo returned HTTP 200 through 10.1.25.42;
  public Forgejo returned HTTP 200 through the VPS/WireGuard path.
- Both DNS servers returned the API address. 58 VLAN 10 leases had recent DHCP
  activity after relay cutover. The user confirmed phone Internet on VLAN 10.
- After returning the Mac to VLAN 10 Wi-Fi, native DNS, hostname-based kubectl,
  internal echo HTTP 200 and NAS SSH all passed. Routes to NAS and API used
  en1 through the unchanged 10.1.10.1 gateway.
- The user confirmed normal mDNS entries in the phone's discovery app.
- IPv4 camera isolation was tested from Scrypted's VLAN 60 interface
  (10.1.60.3), sending probes explicitly through 10.1.60.1. NAS SSH
  (10.1.20.12:22), Kubernetes API (10.1.25.50:6443) and VLAN 10 gateway SSH
  (10.1.10.1:22) were reachable from the trusted network. All three VLAN 60
  SYN probes matched the RB5009 camera drop rule, increasing its packet counter
  by three; logs confirmed ingress `vlan60-cameras` and intended egress
  `vlan4090-transit`. A DNS query to 10.1.30.2 from the same camera interface
  succeeded through the permitted exception. No pod routes or firewall rules
  were changed. Guest isolation remains assumed from the inspected rules,
  rather than independently tested.

- IPv4 iperf3 from the Mac on 6 GHz VLAN 10 Wi-Fi (10.1.10.9) to the NAS
  (10.1.20.12), 20 measured seconds per test after two seconds omitted:

| Direction  | One TCP stream | Four TCP streams |
| ---------- | -------------: | ---------------: |
| Mac to NAS | 738 Mbps       | 813 Mbps         |
| NAS to Mac | 863 Mbps       | 818 Mbps         |

  CRS309 sampled CPU averaged 0.4–0.6%, peaking at 2%. All 20 RB5009
  connection-table samples found no matching Mac-to-NAS connection, and its
  trunk RX/TX samples stayed below 1 Mbps. These observations support hardware
  forwarding on the switch with bulk traffic bypassing the router. This tests
  the Wi-Fi client path, not the 10G link ceiling; no before-migration speed
  comparison was measured. The temporary NAS listener exited after testing.

Not measured: actual netboot and guest negative runtime tests. Guest firewall
rules and affected paths were inspected, but a guest runtime test must not be
reported as passed. No production ISP release or router reboot was performed to
simulate lease loss.

The Mac showed a native resolver failure during the Ethernet/Wi-Fi transition,
reproduced in the user's shell while direct DNS and Go's resolver worked. Cache
flush and mDNSResponder HUP did not immediately fix it. After the user left only
the wired interface active, native DNS APIs and hostname-based kubectl passed.
Some later agent checks inside its restricted sandbox misleadingly continued to
report lookup failures; host DNS checks must run outside that sandbox. The exact
original macOS cause was not established; the DNS servers were answering.
The temporary API-IP override was removed from the git-ignored kubeconfig after
native resolution recovered. No DNS server configuration was changed. Temporary private copies and migration staging files were removed during cleanup.

## References

- [RouterOS L3 hardware offloading](https://manual.mikrotik.com/docs/bridging-and-switching/l3-hardware-offloading/)
- [RouterOS DHCP relay](https://manual.mikrotik.com/docs/network-management/dhcp/relay/)
- [RouterOS DHCPv6 server](https://manual.mikrotik.com/docs/network-management/dhcp/dhcpv6-server/)
- [RouterOS DHCPv6 client](https://manual.mikrotik.com/docs/network-management/dhcp/dhcpv6-client/)
- [RouterOS mDNS repeater](https://manual.mikrotik.com/docs/network-management/dns/)
