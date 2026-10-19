# Office CRS309 routing migration

The Office CRS309 owns the VLAN 1, 10 and 20 gateways. VLANs 10/20 moved on
2026-10-16; VLAN 1 moved on 2026-10-19. The RB5009's old gateway addresses are
disabled for rollback, and automatic rollback timers are removed.
See [router-baseline.md](router-baseline.md) and
[switch-baseline.md](switch-baseline.md) for the current configuration decisions.

## Addressing and ownership

| Item                | RB5009                 | Office CRS309          |
| ------------------- | ---------------------- | ---------------------- |
| Management endpoint | 10.255.0.1             | 10.1.0.10/32           |
| VLAN 1 gateway      | disabled for rollback  | 10.1.0.1/24            |
| VLAN 10 gateway     | disabled for rollback  | 10.1.10.1/24           |
| VLAN 20 gateway     | disabled for rollback  | 10.1.20.1/24           |
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

Management no longer detours through the RB5009 when communicating with VLANs
10/20. The switch's management /25 routes, three CPU-redirect ACLs and
`l3-recovery` source rule, plus the RB5009 switch-management return exception,
are disabled and retained only for rollback. The switch's control-plane input
filters remain active; no inter-VLAN stateful firewall is configured there.

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

## Recovery

Old RB5009 gateway addresses and VLAN 10/20 interfaces remain disabled.
Automatic rollback timers are removed. Read the current configuration before
using any recovery script; the one-time cutover scripts must not be replayed.
Use wired management or console for recovery.

For VLAN 1, run `vlan1-rollback` on the Office CRS309 first, then on the RB5009
at 10.255.0.1. The switch releases 10.1.0.1, restores its 10.1.0.10/24 address
and old management exceptions, and enables the 10.255.0.5/32 rollback-ready
signal. The router requires that signal before reclaiming the gateway. It
restores `dhcp-vlan1` on bridge and refreshes management neighbors. The router's
10.255.0.5/32 route via the switch is retained for this handshake; the signal
address is disabled during normal operation.

For a complete return to router-on-a-stick, restore VLAN 1 as above before
running the original `l3-rollback` scripts. Run that script on the switch first,
wait for gateway/RA release, then run it on the RB5009. It restores VLAN 10/20
ownership, original DHCP placement/options, ND and mDNS repeating. Never enable
a router gateway while the switch still owns the address. The original switch
rollback disables L3 hardware routing and restores its default via 10.1.0.1.

The router's DNS/API endpoint and active BGP peer source remain 10.255.0.1
through rollback. Keep transit and those peer configurations in place; reverting
them to 10.1.0.1 is not required to restore the old gateway ownership. The
10.255.0.4/32 handoff address and its switch route are retained disabled.

## Retiring the rollback configuration

After about one week of stable operation following the latest gateway handoff,
the request **"remove the l3 rollback scripts"** means complete the cleanup below,
including the retained legacy
configuration and temporary recovery artifacts. This is a future live change;
the checklist itself does not authorize removal now.

1. Read the current RB5009 and Office CRS309 configuration over SSH. Confirm
   that the CRS309 still owns all three gateways, hardware routing is enabled, BGP
   peers and service routes are healthy, DHCP relays work, and public IPv6
   delegation renews. Review any switch/router reboot recovery results; do not
   claim reboot recovery was tested if it was not. Inventory each candidate and
   its references before deleting it; disabled status or an `l3 migration:`
   comment alone does not identify an obsolete object.
2. Remove `l3-cutover`, `l3-rollback`, `vlan1-cutover` and `vlan1-rollback`
   system scripts from both devices, plus any scheduler references. Remove the
   disabled 10.255.0.4/32 handoff address and its disabled switch route, and the
   disabled 10.255.0.5/32 rollback-ready address and its router route. The timers
   should already be absent; verify that no migration-only scheduler remains.
3. On the RB5009, remove the disabled old VLAN 1/10/20 gateway addresses, old
   public/ULA address definitions, per-interface ND entries and static prefix
   deprecation entries, obsolete interface-list memberships, and finally the
   disabled `vlan10-internal` and `vlan20-servers` interfaces. Check all references
   first. Keep the live DHCP server objects, leases, pools and network options:
   the servers now use transit and the CRS309 relays. Review bridge VLAN entries
   separately; retain any tagging required to carry VLANs between physical ports.
   Keep bridge and its 192.168.88.1/24 Netinstall address. Remove the disabled old
   BGP connections sourced from 10.1.0.1 and disabled switch-management return
   firewall exception; keep the active transit-sourced BGP connections.
4. On the CRS309, remove the temporary source routing rule for
   10.1.0.10 -> 10.1.0.252, its host route and the `l3-recovery` table, after
   confirming they still serve only the disconnected cutover workstation.
   Remove any disabled pre-migration default route via 10.1.0.1 retained solely
   for rollback, after checking that the live default uses transit. Remove the
   disabled management /25 detour routes and three disabled CPU-redirect ACLs.
   Keep both live management addresses: gateway 10.1.0.1/24 and alias
   10.1.0.10/32.
5. Review all configuration added for the migration on both devices and in the
   repository, including transit, routes, addresses, ACLs, firewall rules, BGP,
   DHCP and IPv6 delegation. Replace migration-era comments and descriptions on
   every retained object with its ongoing purpose, such as `office transit`,
   `VLAN 10 return via CRS309`, or `management via CRS309`. This applies to all
   newly added configuration, not just one object or the literal `l3 migration:`
   prefix. Check retained scripts and automation for comment-based selectors and
   update those references together. Use consistent wording in the device
   configuration and documentation.
6. Verify management access, VLAN 10/20 connectivity, NAS and Kubernetes service
   access, Internet access, BGP, DHCP and IPv6 renewal after cleanup. Confirm no
   invalid references or migration-only scripts, timers or recovery routes remain.
   Remove the local migration staging files and private backups under
   `/private/tmp/home-ops-l3/` and `/private/tmp/home-ops-vlan1/` after verification;
   never commit their contents. Check for leftover staging files under
   `/tmp/home-ops-vlan1/` on the NAS as well.
7. Update this document, [router-baseline.md](router-baseline.md) and
   [switch-baseline.md](switch-baseline.md) to describe the resulting state.
   Remove obsolete rollback/recovery instructions and record any validation gaps.

The permanent routing configuration remains: transit VLAN 4090 and its addresses,
CRS309 gateways/default routes and management alias, RB5009 return routes, DHCP relays,
BGP peers (including the retained RB5009 peers and eBGP multihop), and IPv6
delegation. Keep `sync-office-pd`, its scheduler and DHCPv6 event hook. Retain
these live dependencies and relabel their migration-era comments during cleanup.

## Validation and remaining checks

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
  | Mac to NAS |       738 Mbps |         813 Mbps |
  | NAS to Mac |       863 Mbps |         818 Mbps |

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
native resolution recovered. No DNS server configuration was changed. Private
copies of the original kubeconfig and device exports were saved outside the repo.

## References

- [RouterOS L3 hardware offloading](https://manual.mikrotik.com/docs/bridging-and-switching/l3-hardware-offloading/)
- [RouterOS DHCP relay](https://manual.mikrotik.com/docs/network-management/dhcp/relay/)
- [RouterOS DHCPv6 server](https://manual.mikrotik.com/docs/network-management/dhcp/dhcpv6-server/)
- [RouterOS DHCPv6 client](https://manual.mikrotik.com/docs/network-management/dhcp/dhcpv6-client/)
- [RouterOS mDNS repeater](https://manual.mikrotik.com/docs/network-management/dns/)
