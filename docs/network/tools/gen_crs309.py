#!/usr/bin/env python3
"""Generate a CRS309 build import (L2 spine) for the migration.

usage: gen_crs309.py <room> <out.rsc>
Rooms: office, gameroom, garage. Management on VLAN 99.
"""
import sys

room, out = sys.argv[1:3]
cfg = {
    "office":   {"ip": "10.1.99.10", "prio": "0x1000", "mac_from": "ether1",
                 "ports": {"sfp-sfpplus1": "uplink-office-gw", "sfp-sfpplus2": "downlink-gameroom-crs309",
                           "sfp-sfpplus3": "office-c08zp", "sfp-sfpplus4": "office-c08pf"},
                 "access": {"sfp-sfpplus6": (60, "nvr-pro")}},
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
a(f"add address={cfg['ip']}/24 interface=vlan99-mgmt")
a("/ip dns")
a("set servers=10.1.30.2,10.1.30.4")
a("/ip route")
a('remove [find where dst-address="0.0.0.0/0"]')
a("add dst-address=0.0.0.0/0 gateway=10.1.99.1")
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
