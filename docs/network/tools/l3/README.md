# Office L3 cutover

Moves the VLAN 10 and 20 gateways (10.1.10.1, 10.1.20.1) from `office-gw` to
`office-crs309`, so traffic between internal and servers is routed in the CRS309's
switch chip instead of crossing the RB5009. Everything else stays on the RB5009: VLANs
30/50/60/99/4000/4001, WAN, DHCP servers, DNS/ctrld, firewall, public edge.

This is the October design (`git show 2fcc8e9d^:docs/network/office-routing.md`) on
today's network: VLAN 99 replaces VLAN 1 as management and stays on the RB5009, and the
delegated IPv6 block is a /59 at subnet IDs `00`-`1f`, which already holds VLAN 10's
`0a` and VLAN 20's `14`. **No public or ULA prefix changes**, so clients keep their IPv6
addresses.

| Item              | office-gw                          | office-crs309                          |
| ----------------- | ---------------------------------- | -------------------------------------- |
| Transit VLAN 4090 | 10.255.0.1/30, fdc0:ffee:215:fe::1 | 10.255.0.2/30, fdc0:ffee:215:fe::2     |
| VLAN 10/20        | routes via 10.255.0.2              | 10.1.10.1/24, 10.1.20.1/24, RA, relays |
| BGP               | AS 64513, sessions from 10.255.0.1 | AS 64516, sessions from 10.1.20.1      |
| DHCP              | servers on transit, `relay=`       | relays to 10.255.0.1                   |
| mDNS repeat       | -                                  | vlan10-internal, vlan20-servers        |
| IPv6 public       | binds /59 to the switch (script)   | `office-pd` pool, `::a` and `::14`     |

Files: `1-prestage-*` (inert objects), `2-cutover-*` (the switch-over, run by scheduler),
`3-rollback-*` (undo step 2), and [`../../sync-office-pd.rsc`](../../sync-office-pd.rsc)
(permanent PD script on office-gw). Run everything from the Mac, from this directory.

## 0. Check

```sh
GW=admin@10.1.99.1; SW=admin@10.255.0.2   # office-crs309 is managed on transit
ssh $GW '/system ntp client print; /routing bgp session print; /ip route print count-only where bgp'
ssh $SW '/system ntp client print'
```

Both clocks `synchronized`, two BGP sessions established, the service /32s present.

Nothing may use 10.1.10.1 or 10.1.20.1 for DNS: the switch does not answer DNS there.
CoreDNS forwards to the node resolv.conf it got at pod start, so restart it if this shows
kerfuffle:

```sh
ssh $GW '/ip firewall connection print terse proplist=src-address,dst-address where dst-port=53 and (dst-address=10.1.10.1 or dst-address=10.1.20.1)'
kubectl -n kube-system rollout restart deploy/coredns   # only if 10.1.20.10 shows up
```

## 1. Prestage (no traffic change)

```sh
scp 1-prestage-crs309.rsc 2-cutover-crs309.rsc 3-rollback-crs309.rsc $SW:
scp 1-prestage-gw.rsc 2-cutover-gw.rsc 3-rollback-gw.rsc $GW:
for f in 1-prestage-crs309 2-cutover-crs309 3-rollback-crs309; do ssh $SW "/import file-name=$f.rsc dry-run verbose=yes"; done
for f in 1-prestage-gw 2-cutover-gw 3-rollback-gw; do ssh $GW "/import file-name=$f.rsc dry-run verbose=yes"; done
ssh $SW '/import file-name=1-prestage-crs309.rsc verbose=yes'
ssh $GW '/import file-name=1-prestage-gw.rsc verbose=yes'
ssh $GW '/ping 10.255.0.2 count=3; /ping fdc0:ffee:215:fe::2 count=3'
```

### IPv6 delegation

```sh
ssh $SW ':put [/ipv6 dhcp-client get [find comment~"office-gw"] duid]'
```

Put that DUID in a local copy of the script, install it enabled, and hook it up:

```sh
DUID=0x...   # from above
sed -e "s/FILL-DUID/$DUID/" -e 's/applyChanges false/applyChanges true/' ../../sync-office-pd.rsc > /tmp/sync-office-pd.rsc
scp /tmp/sync-office-pd.rsc $GW: && rm /tmp/sync-office-pd.rsc
ssh $GW '/system script add name=sync-office-pd policy=read,write,test source=[/file get sync-office-pd.rsc contents]; /file remove sync-office-pd.rsc'
ssh $GW '/system script run sync-office-pd'
ssh $GW '/system scheduler add name=sync-office-pd interval=1m on-event="/system script run sync-office-pd" policy=read,write,test'
ssh $GW '/ipv6 dhcp-client set [find comment=spectrum] script="/system script run sync-office-pd"'
ssh $GW '/ipv6 dhcp-server binding print detail'
ssh $SW '/ipv6 dhcp-client print detail; /ipv6 pool print'
```

Want: one binding `<spectrum /56 base>::/59`, the client `bound`, pool `office-pd` with that
/59. The RB5009's own /64s are more specific, so nothing moves yet.

### BGP over transit

Merge the BGP PR (Cilium and codswallop FRR peer with 10.1.20.1/AS 64516 and
10.255.0.1/AS 64513). The old sessions drop and the transit ones come up; the service
/32s can blip for a few seconds. FRR reads its config only at start:

```sh
ssh codswallop 'docker exec frr vtysh -c "show bgp summary"'   # restart frr if it still shows 10.1.20.1 as 64513
ssh $GW '/routing bgp session print; /ip route print where bgp'
ssh $GW '/routing bgp connection disable cilium-kerfuffle,frr-codswallop'
```

Want: `cilium-kerfuffle-transit` and `frr-codswallop-transit` established, all /32s via
10.1.20.10 / 10.1.20.12. Disabling the 10.1.20.1-sourced connections is required: that
address leaves the RB5009 in step 2.

## 2. Cutover

Pick T two minutes ahead (`date`). office-gw lets go at T, office-crs309 takes over at
T+5s, and **both roll back at T+15m unless the rollback is cancelled**.

```sh
D=$(date +%Y-%m-%d); T=HH:MM   # e.g. T=10:30, R = T+15m
R=HH:MM
ssh $GW "/system scheduler add name=l3-cutover start-date=$D start-time=$T:00 interval=0 on-event=\"/import file-name=2-cutover-gw.rsc\"; /system scheduler add name=l3-rollback start-date=$D start-time=$R:00 interval=0 on-event=\"/import file-name=3-rollback-gw.rsc\""
ssh $SW "/system scheduler add name=l3-cutover start-date=$D start-time=$T:05 interval=0 on-event=\"/import file-name=2-cutover-crs309.rsc\"; /system scheduler add name=l3-rollback start-date=$D start-time=$R:00 interval=0 on-event=\"/import file-name=3-rollback-crs309.rsc\""
```

Watch it happen:

```sh
ssh $GW '/log print where message~"l3:"'; ssh $SW '/log print where message~"l3:"'
```

Both must log `cutover done`. A missing `done` means the import stopped on that line:
`/log print where topics~"script|error"` shows which.

## 3. Verify, then cancel the rollback

```sh
ssh $SW '/interface ethernet switch print; /routing bgp session print; /ip route print where dst-address in 10.1.25.0/24; /ip dhcp-relay print'
ssh $GW '/routing bgp session print; /ip route print where bgp; /ip dhcp-server lease print count-only where server=dhcp-vlan10 and last-seen<2m'
ping -c3 10.1.10.1; traceroute -n -m3 10.1.20.12; traceroute -n -m3 10.1.25.42
dig +short k8s.internal.greyrock.io
curl -sI https://grafana.greyrock.io | head -1; ping6 -c3 google.com
kubectl get nodes; kubectl -n default run dnscheck --rm -it --restart=Never --image=alpine -- nslookup dl-cdn.alpinelinux.org
uv run --no-project --with websockets python ../../../homeassistant/matter-check.py --live
```

Want: `l3-hw-offloading=yes`; the switch's /32s flagged `H` (hardware); one hop to
10.1.20.12 and 10.1.25.42 (10.1.10.1 then the target); VLAN 10 leases renewing through
the relay; DNS, Grafana, IPv6, kubectl, the Alpine lookup and Matter all fine.

```sh
ssh $GW '/system scheduler remove l3-rollback,l3-cutover'
ssh $SW '/system scheduler remove l3-rollback,l3-cutover'
```

To roll back early instead: `ssh $GW '/import file-name=3-rollback-gw.rsc'` and
`ssh $SW '/import file-name=3-rollback-crs309.rsc'`.

## 4. Afterwards

- Merge the docs PR, then take a fresh RB5009 backup and export into 1Password
  (`office-gw (RB5009) backup` / `export`, Infrastructure vault).
- After a quiet week, on office-gw: remove `vlan10-internal`, `vlan20-servers`, their
  disabled addresses, the `l3:` ND entries, the disabled `cilium-kerfuffle` and
  `frr-codswallop` connections, the VLAN 10/20 entries from the bridge VLAN table, and the
  step files on both devices. Keep everything else.

## Notes

- **Stale ARP:** clients that still hold the RB5009's MAC for their gateway keep working;
  its VLAN 10/20 interfaces stay up without addresses and forward anyway, until the
  entries age out. Same for IPv6: the RB5009 advertises `ra-lifetime=0` there, so clients
  drop it as a default router.
- **MAC Winbox / MAC Telnet** to office-crs309 stop working with L3 offload on (98DX8xxx
  drops them). Use its IP.
- **Firewall:** traffic between VLAN 10 and 20, and VLAN 10 to the service /32s, no longer
  crosses the RB5009; nothing filters it there today. Everything to or from VLANs
  30/50/60/99/guest/work still goes through the RB5009's rules, symmetrically.
- **DNS to a gateway address** (e.g. the Tesla Wall Connector, 10.1.10.39, asks 10.1.10.1)
  stops working: the router redirected it to ctrld, the switch does not answer DNS.
- If the switch loses its BGP routes, VLAN 10 to the /32s still works through the RB5009
  (asymmetric, slower).
