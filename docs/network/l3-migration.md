# Office CRS309 routing migration

Completed 2026-10-16. The Office CRS309 owns the VLAN 10 and 20 gateways;
RB5009 ownership of those addresses is disabled. The successful handoff completed
at 11:26:58 America/New_York. Both timed rollback jobs were removed after checks.
See [router-baseline.md](router-baseline.md) and
[switch-baseline.md](switch-baseline.md) for the current configuration decisions.

## Addressing and ownership

| Item | RB5009 | Office CRS309 |
| --- | --- | --- |
| Management | 10.1.0.1/24 | 10.1.0.10/24 |
| VLAN 10 gateway | disabled for rollback | 10.1.10.1/24 |
| VLAN 20 gateway | disabled for rollback | 10.1.20.1/24 |
| Transit VLAN 4090 | 10.255.0.1/30 | 10.255.0.2/30 |
| Transit ULA | fdc0:ffee:215:fe::1/64 | fdc0:ffee:215:fe::2/64 |
| ASN | 64513 | 64516 |
| IPv4 default | WAN | 10.255.0.1 |
| IPv6 default | ISP | fdc0:ffee:215:fe::1 |

Transit is tagged on bridge and sfp-sfpplus1 only, on both devices. Other
switches remain L2. Bridge and routed VLAN MTUs on the CRS309 are 9000; its
Ethernet L2MTUs remain 10218. NAS and Kubernetes remain on Office C08ZP ports
1/1/7 and 1/1/8, both negotiated at 10G, sharing the 10G switch uplink.

Client and server gateway IPs did not change. The NAS retains its static
`default via 10.1.20.1`; no host network edit was needed.

```text
VLAN 10 -> CRS309 -> VLAN 20 NAS
VLAN 10 -> CRS309 -> service /32 -> NAS/Kubernetes
VLAN 10/20 -> CRS309 -> transit -> RB5009 -> WAN / router services / other VLANs
guest / WireGuard -> RB5009 -> transit -> CRS309 -> server/service
```

## BGP and deployment

Cilium and NAS FRR retain their 10.1.0.1/AS64513 peers and add the directly
connected 10.1.20.1/AS64516 peer. The retained router path requires eBGP TTL 2
on Cilium and FRR after the extra routing hop. The CRS309 imports only Cilium
service /32s within 10.1.25.0/24 and NAS 10.1.25.21/32, and exports nothing.
NAS re-advertisements of learned Cilium routes are filtered by the switch.

Changes were committed to the existing `forgejo` remote. Normal deployment is
Forgejo push -> GitHub mirror -> Flux webhook. Do not manually reconcile Flux.
NAS doco-cd uses the GitHub mirror; the documented container restart workflow
was used to apply its FRR changes. The running FRR neighbors were verified.

## Hardware forwarding and management exception

IPv4 and IPv6 L3 hardware routing are enabled. Trusted client/server and service
routes use the main routing table and are eligible for hardware forwarding.
BGP negotiation, DHCP relay, mDNS repeating and the switch's own control plane
use CPU. A route H flag alone does not prove measured wire-speed performance.

Management's connected 10.1.0.0/24 otherwise creates asymmetric return paths
around the RB5009. Two more-specific /25s send routed management destinations
through transit. Hardware host forwarding initially bypassed this intent;
software routing tests isolated the issue. Three switch ACLs therefore redirect
IPv4 packets destined for 10.1.0.0/24 on VLANs 10/20/4090 to CPU, where those
routes are honored. Bulk client/server traffic does not match these rules.
The ACL port lists cover the four current trunks; extend them with new trunks.

The recovery workstation was wired to Office C08ZP port 1 at 10.1.0.252. A
source-specific rule for 10.1.0.10 -> 10.1.0.252 uses `l3-recovery`, whose host
route sends only the switch's own management replies directly over bridge.
A global recovery host route must not be used: it also bypasses the router for
server replies. The RB5009 has a narrow accept for switch-originated management
traffic arriving over transit and leaving bridge.

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

- Existing DHCP server objects and leases stay on the RB5009. VLAN 10/20 servers
  listen on transit and identify their relays by the unchanged gateway IPs.
  Switch relays target 10.255.0.1. Gateway, DNS and search-domain options stay intact.
- mDNS repeating moved from the router to the CRS309, between VLANs 10 and 20.
- TFTP files remain on the RB5009, with the same source-subnet restrictions.
  DHCP `next-server` for VLANs 10/20 is now 10.255.0.1.

## Recovery

The old router interfaces and gateway addresses are retained disabled. Device
scripts `l3-rollback` remain available; automatic rollback timers are removed.
Use direct VLAN 1 management or console for recovery. Run the switch rollback
first, wait for it to finish withdrawing RAs and releasing gateway addresses,
then run the RB5009 rollback to restore ownership. Never restore the router's
addresses while the switch still owns them.

The switch script disables its gateways/relays/repeating and L3 hardware routing,
restores its management default via 10.1.0.1, and disables the management /25s.
The router script restores its old interfaces, addresses, DHCP placement/options,
ND defaults and mDNS repeating. Refresh client gateway neighbor entries if needed.
Additive server BGP peers can remain down until removed through the repository.
The staged transit and delegation need not be removed to restore old routing.

Future handoffs must use an explicit ready signal, not just staggered timers:
the switch must verify that the router has released its gateways. Temporary
10.255.0.4/32 was used as that signal for this cutover, then removed along with
its switch route and all cutover/rollback scheduler entries. Do not replay the
one-time cutover scripts against the current state.

## Validation and remaining checks

Verified during preparation and cutover:

- `flate test all`: 244 passed, two skipped for unavailable kanidm-provision SSH
  credentials. Rendered diffs contained only the additive peer and multihop field.
  Cilium Kustomize build, NAS Compose validation and whitespace checks passed.
- Device-local scripts parsed; handoff/recovery access used wired VLAN 1.
- Isolated documentation-prefix delegation: fixed /60 acquisition, renumbering,
  loss/expiry and recovery. Production renewal remained healthy across cycles.
- Both original router peers and both new switch peers established. All seven
  service /32s installed with the correct direct server next hops; NAS-learned
  copies of Cilium routes filtered.
- NAS SSH reachable with hardware routing enabled after the management exception;
  NAS IPv4/IPv6 Internet pings succeeded. Kubernetes API worked using its IP with
  hostname TLS verification. Internal echo returned HTTP 200 through 10.1.25.42;
  public Forgejo returned HTTP 200 through the VPS/WireGuard path.
- Both DNS servers returned the API address. 58 VLAN 10 leases had recent DHCP
  activity after relay cutover. The user confirmed phone Internet on VLAN 10.

Not measured: client-to-NAS transfer speed, application-level ingress behavior
from VLAN 10, actual netboot, mDNS device discovery, and guest/camera negative
runtime tests. Firewall rules and affected paths were inspected, but those tests
must not be reported as passed. No production ISP release or router reboot was
performed to simulate lease loss.

The Mac showed a separate native resolver failure while direct DNS and Go's
resolver worked. Cache flush and mDNSResponder HUP did not fix it. The temporary,
git-ignored kubeconfig uses the API IP with the original TLS server name. Restore
the hostname after native resolution is verified; investigate separately from
routing. A private copy of the original kubeconfig and device exports was saved
outside the repository.

## References

- [RouterOS L3 hardware offloading](https://manual.mikrotik.com/docs/bridging-and-switching/l3-hardware-offloading/)
- [RouterOS DHCP relay](https://manual.mikrotik.com/docs/network-management/dhcp/relay/)
- [RouterOS DHCPv6 server](https://manual.mikrotik.com/docs/network-management/dhcp/dhcpv6-server/)
- [RouterOS DHCPv6 client](https://manual.mikrotik.com/docs/network-management/dhcp/dhcpv6-client/)
- [RouterOS mDNS repeater](https://manual.mikrotik.com/docs/network-management/dns/)
