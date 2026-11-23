#!/usr/bin/env python3
"""Generate a CRS309 build import (L2 spine; office also routes VLAN 10/20).

usage: gen_crs309.py <room> <out.rsc>
Rooms: office, gameroom, garage. Management on VLAN 99.
"""
import sys

room, out = sys.argv[1:3]
cfg = {
    "office":   {"ip": "10.1.99.10", "prio": "0x1000", "mac_from": "ether1",
                 "ports": {"sfp-sfpplus1": "uplink-office-gw", "sfp-sfpplus2": "downlink-gameroom-crs309",
                           "sfp-sfpplus3": "office-c08zp", "sfp-sfpplus4": "office-c08pf"},
                 "access": {}},
    "gameroom": {"ip": "10.1.99.20", "prio": "0x2000",
                 "ports": {"sfp-sfpplus1": "uplink-office-crs309", "sfp-sfpplus2": "downlink-garage-crs309",
                           "sfp-sfpplus3": "gameroom-c08zp", "sfp-sfpplus4": "gameroom-c08pf"},
                 "access": {}},
    "garage":   {"ip": "10.1.99.30", "prio": "0x3000",
                 "ports": {"sfp-sfpplus1": "uplink-gameroom-crs309", "sfp-sfpplus2": "garage-c08zp",
                           "sfp-sfpplus3": "garage-c08pf"},
                 "access": {}},
}[room]

allp = ["ether1"] + [f"sfp-sfpplus{i}" for i in range(1, 9)]
trunks = list(cfg["ports"])
L = []
a = L.append
a(f"# {room}-crs309 build, generated 2026-11-19 (RouterOS 7.25.1, no-defaults netinstall).")
a("# VLAN 1 native on trunks (RSTP only); management on VLAN 99.")
a("/interface bridge")
a(f"add admin-mac=[/interface ethernet get ether1 mac-address] auto-mac=no igmp-snooping=yes igmp-version=3 mld-version=2 name=bridge priority={cfg['prio']} vlan-filtering=no")
a("/interface ethernet")
for p in allp:
    a(f"set [ find default-name={p} ] l2mtu=10218")
a("/interface vlan")
a("add interface=bridge name=vlan99-mgmt vlan-id=99")
a("/interface bridge port")
for p in allp:
    if p == "ether1":
        continue  # joins last: it carries the bootstrap session
    if p in cfg["ports"]:
        a(f"add bridge=bridge comment={cfg['ports'][p]} interface={p}")
    elif p in cfg["access"]:
        vid, name = cfg["access"][p]
        a(f"add bridge=bridge comment={name} interface={p} pvid={vid}")
    else:
        a(f"add bridge=bridge interface={p}")
a("/interface bridge vlan")
t = ",".join(trunks)
a(f"add bridge=bridge tagged={t} vlan-ids=10,20,50,60,4000,4001")
a(f"add bridge=bridge tagged=bridge,{t} untagged=ether1 vlan-ids=99")
a("/ip address")
if room != "office":  # office-crs309 is managed on transit, see below
    a(f"add address={cfg['ip']}/24 interface=vlan99-mgmt")
a("/ip dns")
a("set servers=10.1.30.2,10.1.30.4")
a("/ip route")
a('remove [find where dst-address="0.0.0.0/0"]')
a(f"add dst-address=0.0.0.0/0 gateway={'10.255.0.1' if room == 'office' else '10.1.99.1'}")
if room == "office":
    # L3 for VLAN 10/20 over transit VLAN 4090 (docs/network/tools/l3/README.md). The
    # IPv6 /59 needs sync-office-pd on office-gw with this switch's DUID.
    # Managed on a loopback, never on VLAN 99: an address there makes the switch route
    # VLAN 10/20 straight into VLAN 99 while replies return through office-gw, which drops
    # them. A VRF does not help, the L3 offload ignores it. See switch-baseline.md.
    a("/ip address")
    a('add address=10.255.255.10/32 comment="management loopback" interface=lo')
    a("/interface bridge")
    a("set bridge mtu=9000")
    a("/interface bridge port")
    a("set [find interface=sfp-sfpplus1] multicast-router=permanent")
    a("/interface bridge vlan")
    a("add bridge=bridge comment=transit tagged=bridge,sfp-sfpplus1 vlan-ids=4090")
    a("/interface vlan")
    a('add comment="transit to office-gw" interface=bridge mtu=9000 name=vlan4090-transit vlan-id=4090')
    a("add interface=bridge mtu=9000 name=vlan10-internal vlan-id=10")
    a("add interface=bridge mtu=9000 name=vlan20-servers vlan-id=20")
    a("/ip address")
    a('add address=10.255.0.2/30 comment="transit to office-gw" interface=vlan4090-transit')
    a('add address=10.1.10.1/24 comment="vlan 10 gateway" interface=vlan10-internal')
    a('add address=10.1.20.1/24 comment="vlan 20 gateway" interface=vlan20-servers')
    a("/ipv6 dhcp-client")
    a('add add-default-route=no comment="vlan 10/20 /59 from office-gw" custom-iapd-id=4090 interface=vlan4090-transit pool-name=office-pd pool-prefix-length=64 prefix-hint=::/59 request=prefix use-peer-dns=no')
    a("/ipv6 address")
    a('add address=fdc0:ffee:215:fe::2/64 advertise=no comment="transit to office-gw" interface=vlan4090-transit')
    a("add address=fdc0:ffee:215:a::1/64 interface=vlan10-internal")
    a("add address=fdc0:ffee:215:14::1/64 interface=vlan20-servers")
    a("add address=::a:0:0:0:1/64 from-pool=office-pd interface=vlan10-internal")
    a("add address=::14:0:0:0:1/64 from-pool=office-pd interface=vlan20-servers")
    a("/ipv6 route")
    a('add comment="default via office-gw" dst-address=::/0 gateway=fdc0:ffee:215:fe::1')
    a("/ipv6 nd")
    a("set [find default=yes] disabled=yes")
    a("add advertise-dns=no interface=vlan10-internal ra-interval=30s-1m")
    a("add advertise-dns=no interface=vlan20-servers ra-interval=30s-1m")
    a("/ip dhcp-relay")
    a("add dhcp-server=10.255.0.1 interface=vlan10-internal local-address=10.1.10.1 name=relay-vlan10")
    a("add dhcp-server=10.255.0.1 interface=vlan20-servers local-address=10.1.20.1 name=relay-vlan20")
    a("/ip dns")
    a("set mdns-repeat-ifaces=vlan10-internal,vlan20-servers")
    a("/routing id")
    a('add comment="bgp router-id" id=10.255.255.10 name=router-id select-from-vrf=main')
    a("/routing bgp instance")
    a("add as=64516 name=greyrock-l3")
    a("/routing filter rule")
    a('add chain=l3-cilium-in rule="if (dst in 10.1.25.0/24 && dst-len == 32) { accept }"')
    a('add chain=l3-nas-in rule="if (dst == 10.1.25.21/32) { accept }"')
    a('add chain=l3-out rule="if (dst in 0.0.0.0/0) { reject }"')
    a("/routing bgp connection")
    a('add afi=ip comment="cilium lb pool" input.filter=l3-cilium-in instance=greyrock-l3 local.address=10.1.20.1 .role=ebgp name=l3-cilium-kerfuffle output.filter-chain=l3-out remote.address=10.1.20.10 .as=64514')
    a('add afi=ip comment="nas service ip" input.filter=l3-nas-in instance=greyrock-l3 local.address=10.1.20.1 .role=ebgp name=l3-frr-codswallop output.filter-chain=l3-out remote.address=10.1.20.12 .as=64515')
    a("/interface ethernet switch")
    a("set switch1 l3-hw-offloading=yes")
    a("/interface ethernet switch l3hw-settings")
    a("set ipv6-hw=yes")
a("/system clock")
a("set time-zone-autodetect=no time-zone-name=America/New_York")
a("/system identity")
a(f"set name={room}-crs309")
a("/system ntp client")
a("set enabled=yes")
a("/system ntp client servers")
for i in range(1, 5):
    a(f"add address=time{i}.internal.greyrock.io")
a("/ip service")
for s in ("ftp", "telnet", "www", "api", "api-ssl"):
    a(f"set {s} disabled=yes")
a("/ip ssh")
a("set strong-crypto=yes")
a("# --- last: ether1 into the bridge on VLAN 99, drop the bootstrap address, VLAN filtering on.")
a("/interface bridge port")
a("add bridge=bridge comment=bench-or-recovery interface=ether1 pvid=99")
a("/ip address")
a("remove [find comment=bootstrap]")
a(f"add address={cfg['ip'].replace('10.1.99.', '192.168.88.')}/24 comment=bench interface=vlan99-mgmt")
a("/interface bridge")
a("set bridge vlan-filtering=yes")
open(out, "w").write("\n".join(L) + "\n")
print(f"{out}: {len(L)} lines")
