#!/usr/bin/env python3
"""Generate an ICX8200 (FastIron 10.0) CLI config.

usage: gen_icx.py <switch> <out.txt>
Trunks: VLAN 1 untagged (RSTP only), 10/20/50/60/99/4000/4001 tagged.
AP ports: VLAN 99 untagged, 10/4000/4001 tagged. See docs/network/switch-baseline.md.
"""
import sys

name, out = sys.argv[1:3]

AP_TAGGED = [10, 4000, 4001]
S = {
    "garage-c08zp": {
        "ip": "10.1.99.31", "querier": False,
        "names": {"1/1/1": "rd-ap", "1/1/2": "sy-ap", "1/1/3": "sd-ap", "1/1/5": "garage-ap",
                  "1/1/6": "kitchen-ap", "1/2/2": "uplink-garage-crs309"},
        "ap": ["1/1/1", "1/1/2", "1/1/3", "1/1/5", "1/1/6"],
        "access": {},          # port -> untagged vlan
        "tagged_extra": {},    # port -> [vlans]
    },
    "garage-c08pf": {
        "ip": "10.1.99.32", "querier": False, "up": "2/2/2",
        "names": {"2/1/1": "courtyard-doorbell", "2/1/2": "garage-todd-cam", "2/1/5": "side-yard-cam",
                  "2/1/6": "garage-andy-cam", "2/2/2": "uplink-garage-crs309"},
        "ap": [],
        "access": {"2/1/1": 60, "2/1/2": 60, "2/1/5": 60, "2/1/6": 60},
        "tagged_extra": {},
        "poe_off": ["2/1/3", "2/1/4"],  # reserved for cameras; old G6 Turrets still cabled
    },
    "gameroom-c08zp": {
        "ip": "10.1.99.21", "querier": False,
        "names": {"1/1/1": "andys-desktop", "1/1/2": "todds-desktop", "1/1/5": "game-room-ap",
                  "1/2/2": "uplink-gameroom-crs309"},
        "ap": ["1/1/5"],
        "access": {"1/1/1": 10, "1/1/2": 10},
        "tagged_extra": {},
    },
    "gameroom-c08pf": {
        "ip": "10.1.99.22", "querier": False,
        "names": {"1/1/1": "solaredge", "1/2/2": "uplink-gameroom-crs309"},
        "ap": [],
        "access": {"1/1/1": 50},
        "tagged_extra": {},
    },
    "office-c08zp": {
        "ip": "10.1.99.11", "querier": True,
        "names": {"1/1/1": "mac-mini", "1/1/5": "kerfuffle", "1/1/6": "codswallop", "1/1/7": "office-ap",
                  "1/1/8": "uh-ap", "1/2/2": "uplink-office-crs309"},
        "ap": ["1/1/7", "1/1/8"],
        "access": {"1/1/1": 10, "1/1/5": 20, "1/1/6": 20},
        "tagged_extra": {"1/1/5": [10, 60]},
    },
    "office-c08pf": {
        "ip": "10.1.99.12", "querier": False,
        "names": {"1/1/1": "time1", "1/1/2": "time2", "1/1/3": "time3", "1/1/4": "time4",
                  "1/1/5": "homeassistant", "1/1/6": "gallivant", "1/1/7": "kvm-hass", "1/1/8": "kvm-codswallop",
                  "2/1/1": "kvm-kerfuffle", "2/1/2": "kvm-gallivant", "2/1/3": "kvm-mac-mini",
                  "1/2/2": "uplink-office-crs309"},
        "ap": [],
        "access": {"1/1/1": 20, "1/1/2": 20, "1/1/3": 20, "1/1/4": 20, "1/1/5": 10, "1/1/6": 20,
                   "1/1/7": 20, "1/1/8": 20, "2/1/1": 20, "2/1/2": 20, "2/1/3": 20},
        "tagged_extra": {},
    },
}
c = S[name]
up = c.get("up", "1/2/2")
vl = {1: "DEFAULT-VLAN", 10: "Internal", 20: "Servers", 50: "IoT", 60: "Cameras",
      99: "Mgmt", 4000: "Guest", 4001: "Work"}
vlans = [v for v in vl if v != 1]

def members(v):
    tagged = [up]
    untagged = []
    for p in c["ap"]:
        if v == 99:
            untagged.append(p)
        elif v in AP_TAGGED:
            tagged.append(p)
    for p, u in c["access"].items():
        if u == v:
            untagged.append(p)
    for p, ts in c["tagged_extra"].items():
        if v in ts:
            tagged.append(p)
    return tagged, untagged

mode = "active" if c["querier"] else "passive"
L = []
a = L.append
a("configure terminal")
a(f"hostname {name}")
a("clock timezone us Eastern")
a("clock summer-time")
a("jumbo")
a("inline power allocation dynamic all")
a("ip dns domain-list internal.greyrock.io")
a("ip dns server-address 10.1.30.2 10.1.30.4")
a("ip multicast flood-unregistered")
a("ipv6 multicast version 2")
a("ipv6 multicast flood-unregistered")
a("ip route 0.0.0.0/0 10.1.99.1")
a("manager disable")
a("no manager registrar")
a("vlan 1 name DEFAULT-VLAN by port")
a(" spanning-tree 802-1w")
for k in ("multicast", "multicast6"):
    a(f" {k} {mode}")
    a(f" {k} fast-convergence")
a(" multicast version 3")
a("exit")
for v in vlans:
    t, u = members(v)
    a(f"vlan {v} name {vl[v]} by port")
    for p in t:
        a(f" tagged ethe {p}")
    for p in u:
        a(f" untagged ethe {p}")
    for k in ("multicast", "multicast6"):
        a(f" {k} {mode}")
        a(f" {k} fast-convergence")
    a(" multicast version 3")
    a("exit")
a("no global-stp")
for p, n in c["names"].items():
    a(f"interface ethernet {p}")
    a(f" port-name {n}")
    a("exit")
for p in c.get("poe_off", []):
    a(f"interface ethernet {p}")
    a(" no inline power")
    a("exit")
a("interface ve 99")
a(f" ip address {c['ip']} 255.255.255.0")
a("exit")
a("ntp")
a(" disable serve")
for i in range(1, 5):
    a(f" server time{i}.internal.greyrock.io")
a("exit")
a("end")
a("write memory")
open(out, "w").write("\n".join(L) + "\n")
print(f"{out}: {len(L)} lines")
