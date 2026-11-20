#!/usr/bin/env python3
"""Generate the office-gw (RB5009) build import from the Sept backup + migration doc changes.

usage: gen_office_gw.py <sept-backup.txt> <reservations.csv> <out-main.rsc> <out-stage4-ipv6.rsc>
No secrets are emitted: WireGuard key is generated on the router, passwords/tokens are added by hand.
"""
import csv
import re
import sys

backup_path, csv_path, out_main, out_v6 = sys.argv[1:5]  # argv[5]: live hostname check file
backup = open(backup_path).read().splitlines()

# --- Sept static-lease DNS names, keyed by MAC (via the Sept lease IP) ---
sept_ip_by_mac = {}
for line in backup:
    m = re.match(r'add address=(\S+) .*mac-address=(\S+) server=', line)
    if line.startswith("add address=") and "server=dhcp-vlan" in line and m:
        sept_ip_by_mac[m.group(2).upper()] = m.group(1)
sept_name_by_ip = {}
for line in backup:
    m = re.match(r'add address=(\S+) comment=static-lease name=(\S+)\.internal\.greyrock\.io type=A', line)
    if m:
        sept_name_by_ip[m.group(1)] = m.group(2)

def slug(s):
    s = s.lower().replace("'s", "s").replace("'", "")
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s

rows = [r for r in csv.DictReader(open(csv_path)) if r["ip"] and r["network"].startswith("dhcp-vlan")]
live = {}
for line in open(sys.argv[5]):
    parts = line.split()
    if parts and parts[0] == "OK":
        live[parts[1]] = parts[2]
leases, names, seen_names = [], [], set()
for r in rows:
    mac = r["mac"].upper()
    name = r["name"].replace('"', "'")
    leases.append(f'add address={r["ip"]} comment="{name}" mac-address={mac} server={r["network"]}')
    for host, why in ((live.get(r["ip"], ""), "hostname"), (slug(r["name"]), "name")):
        if host and host not in seen_names:
            seen_names.add(host)
            names.append(f'add address={r["ip"]} comment="static-lease {why}" name={host}.internal.greyrock.io type=A')

infra = {
    "office-gw": "10.1.99.1", "unleashed": "10.1.99.2",
    "office-crs309": "10.1.99.10", "office-c08zp": "10.1.99.11", "office-c08pf": "10.1.99.12",
    "office-ap": "10.1.99.13", "upstairs-hallway-ap": "10.1.99.14",
    "gameroom-crs309": "10.1.99.20", "gameroom-c08zp": "10.1.99.21", "gameroom-c08pf": "10.1.99.22",
    "game-room-ap": "10.1.99.23",
    "garage-crs309": "10.1.99.30", "garage-c08zp": "10.1.99.31", "garage-c08pf": "10.1.99.32",
    "garage-ap": "10.1.99.33", "kitchen-ap": "10.1.99.34", "rear-driveway-ap": "10.1.99.35",
    "side-yard-ap": "10.1.99.36", "side-driveway-ap": "10.1.99.37",
    "time1": "10.1.20.16", "time2": "10.1.20.17", "time3": "10.1.20.18", "time4": "10.1.20.19",
}
infra_lines = [f'add address={ip} comment=infra name={n}.internal.greyrock.io type=A' for n, ip in infra.items()]
infra_lines.append('add address=10.1.25.50 comment=service name=k8s.internal.greyrock.io type=A')
# drop lease-derived names that collide with infra names
names = [l for l in names if not any(f"name={n}.internal" in l for n in infra)]

ntp = "10.1.20.16,10.1.20.17,10.1.20.18,10.1.20.19"
ctrld = "10.1.30.2,10.1.30.4"
eth = ["ether1", "ether2", "ether3", "ether4", "ether5", "ether6", "ether7", "ether8", "sfp-sfpplus1"]
access = ["ether3", "ether4", "ether5", "ether6", "ether7", "ether8"]  # ether2 joins last (bootstrap)

L = []
a = L.append
a("# office-gw (RB5009) build, generated 2026-11-19 from the 2026-09-29 backup and the migration doc.")
a("# Run on a no-defaults 7.25.1 router. Not included (done by hand): CF_Token, externaldns/dexd")
a("# user passwords, skedaddle WireGuard peer public key, Spamhaus/DoH lists, IPv6 addresses (stage4 file).")
a("/interface bridge")
a('add admin-mac=D0:EA:11:C7:4F:C3 auto-mac=no comment="lan bridge - vlan filtering" mtu=9000 name=bridge protocol-mode=none vlan-filtering=no')
a("/interface ethernet")
for e in eth:
    a(f"set [ find default-name={e} ] l2mtu=9796")
a("/interface veth")
a('add address=10.1.30.2/24 container-mac-address=1E:EA:AE:F5:E1:EC dhcp=no gateway=10.1.30.1 mac-address=1E:EA:AE:F5:E1:EB name=veth-ctrld')
a('add address=10.1.30.3/24 container-mac-address=6E:E0:74:78:3A:3C dhcp=no gateway=10.1.30.1 mac-address=6E:E0:74:78:3A:3B name=veth-acme')
a('add address=10.1.30.4/24 comment="ctrld-b dns" container-mac-address=5E:EC:FE:05:2A:62 dhcp=no gateway=10.1.30.1 mac-address=5E:EC:FE:05:2A:61 name=veth-ctrld-b')
a("/interface wireguard")
a('add comment="public edge: skedaddle" listen-port=51822 mtu=1420 name=wg-public-edge')
a("/interface vlan")
for vid, name, mtu in [(10, "vlan10-internal", 9000), (20, "vlan20-servers", 9000), (30, "vlan30-container", None),
                       (50, "vlan50-iot", 9000), (60, "vlan60-cameras", 9000), (99, "vlan99-mgmt", None),
                       (4000, "vlan4000-guest", 9000), (4001, "vlan4001-work", 9000)]:
    a(f"add interface=bridge {'mtu=%d ' % mtu if mtu else ''}name={name} vlan-id={vid}")
a("/interface list")
a('add comment="internet facing" name=WAN')
a('add comment="full router access" name=LAN')
a('add comment="dhcp and dns only, no internet" name=RESTRICTED')
a('add comment="dhcp and dns only, internet only" name=GUEST')
a('add comment="internet only" name=WORK')
a('add comment="dhcp and dns only" include=RESTRICTED,GUEST,WORK name=LOCALSVC')
a("/ip pool")
pools = {"vlan10": "10.1.10.6-10.1.10.254", "vlan20": "10.1.20.6-10.1.20.254", "vlan50": "10.1.50.6-10.1.50.254",
         "vlan60": "10.1.60.6-10.1.60.254", "vlan99": "10.1.99.100-10.1.99.254",
         "vlan4000": "192.168.23.2-192.168.23.254", "vlan4001": "192.168.24.2-192.168.24.254"}
for k, v in pools.items():
    a(f"add name=pool-{k} ranges={v}")
a("/ip dhcp-server")
for k, iface, cmt, lt in [("vlan10", "vlan10-internal", "internal", "8h"), ("vlan20", "vlan20-servers", "servers", "8h"),
                          ("vlan50", "vlan50-iot", "iot", "8h"), ("vlan60", "vlan60-cameras", "cameras", "8h"),
                          ("vlan99", "vlan99-mgmt", "mgmt", "8h"), ("vlan4000", "vlan4000-guest", "guest", "4h"),
                          ("vlan4001", "vlan4001-work", "work", "8h")]:
    a(f"add address-pool=pool-{k} comment={cmt} interface={iface} lease-time={lt} name=dhcp-{k}")
a("/routing bgp instance")
a("add as=64513 name=greyrock")
a("/routing id")
a('add comment="bgp router-id" id=10.1.99.1 name=router-id select-from-vrf=main')
a("/user group")
a("add name=acme policy=ssh,ftp,read,write,policy,test,!local,!telnet,!reboot,!winbox,!password,!web,!sniff,!sensitive,!api,!romon,!rest-api")
for g in ("externaldns", "dexd"):
    a(f"add name={g} policy=read,write,web,api,rest-api,!local,!telnet,!ssh,!ftp,!reboot,!policy,!test,!winbox,!password,!sniff,!sensitive,!romon")
a("/container config")
a("set layer-dir=/usb1/pull tmpdir=/usb1/pull")
a("/container mounts")
a("add dst=/acme.sh list=acme src=/usb1/acme")
a("add dst=/etc/controld list=ctrld src=/usb1/ctrld")
a("/container envs")
a("add key=ROUTER_OS_HOST list=acme value=10.1.30.1")
a("add key=ROUTER_OS_PORT list=acme value=22")
a('add key=ROUTER_OS_SCP_CMD list=acme value="scp -P 22 -i /acme.sh/.ssh/routeros -o UserKnownHostsFile=/acme.sh/.ssh/known_hosts -o StrictHostKeyChecking=accept-new"')
a('add key=ROUTER_OS_SSH_CMD list=acme value="ssh -p 22 -i /acme.sh/.ssh/routeros -o UserKnownHostsFile=/acme.sh/.ssh/known_hosts -o StrictHostKeyChecking=accept-new"')
a("add key=ROUTER_OS_USERNAME list=acme value=acme")
a("# by hand: /container envs add key=CF_Token list=acme value=<Cloudflare token>")
a("/interface bridge port")
for e in access:
    a(f"add bridge=bridge comment=mgmt interface={e} pvid=99")
a("add bridge=bridge comment=trunk-office-crs309 interface=sfp-sfpplus1")
for v in ("veth-ctrld", "veth-acme", "veth-ctrld-b"):
    a(f"add bridge=bridge interface={v} pvid=30")
a("/interface bridge vlan")
a("add bridge=bridge tagged=bridge,sfp-sfpplus1 vlan-ids=10,20,50,60,4000,4001")
a(f"add bridge=bridge tagged=bridge,sfp-sfpplus1 untagged={','.join(['ether2'] + access)} vlan-ids=99")
a("add bridge=bridge tagged=bridge vlan-ids=30")
a("/interface list member")
a("add interface=ether1 list=WAN")
for i in ("vlan10-internal", "vlan20-servers", "vlan30-container", "vlan50-iot", "vlan99-mgmt"):
    a(f"add interface={i} list=LAN")
a("add interface=vlan60-cameras list=RESTRICTED")
a("add interface=vlan4000-guest list=GUEST")
a("add interface=vlan4001-work list=WORK")
a("/ip neighbor discovery-settings")
a("set discover-interface-list=LAN")
a("/ip address")
for addr, iface in [("10.1.10.1/24", "vlan10-internal"), ("10.1.20.1/24", "vlan20-servers"), ("10.1.30.1/24", "vlan30-container"),
                    ("10.1.50.1/24", "vlan50-iot"), ("10.1.60.1/24", "vlan60-cameras"), ("10.1.99.1/24", "vlan99-mgmt"),
                    ("192.168.23.1/24", "vlan4000-guest"), ("192.168.24.1/24", "vlan4001-work")]:
    a(f"add address={addr} interface={iface}")
a('add address=10.254.45.1/24 comment="public edge: skedaddle" interface=wg-public-edge')
a("/ip cloud")
a("set ddns-enabled=yes")
a("/ip dhcp-client")
a("add comment=wan interface=ether1 use-peer-dns=no")
a("/ip dhcp-server lease")
L.extend(leases)
a("/ip dhcp-server network")
a(f"add address=10.1.10.0/24 boot-file-name=netboot.xyz-snponly.efi dns-server={ctrld} domain=internal.greyrock.io gateway=10.1.10.1 next-server=10.1.10.1 ntp-server={ntp}")
# VLAN 20 hands out no domain: a search domain there breaks musl (Alpine) lookups in the cluster.
a(f"add address=10.1.20.0/24 boot-file-name=netboot.xyz-snponly.efi dns-server={ctrld} gateway=10.1.20.1 next-server=10.1.20.1 ntp-server={ntp}")
a(f"add address=10.1.50.0/24 dns-server={ctrld} domain=internal.greyrock.io gateway=10.1.50.1 ntp-server={ntp}")
a(f"add address=10.1.60.0/24 dns-server={ctrld} domain=internal.greyrock.io gateway=10.1.60.1 ntp-server={ntp}")
a(f"add address=10.1.99.0/24 dns-server=10.1.30.2,10.1.30.4 domain=internal.greyrock.io gateway=10.1.99.1 ntp-server={ntp}")
a("add address=192.168.23.0/24 dns-server=192.168.23.1 gateway=192.168.23.1")
a("add address=192.168.24.0/24 dns-server=1.1.1.1,8.8.8.8 gateway=192.168.24.1")
a("/ip dns")
a("set allow-remote-requests=yes mdns-repeat-ifaces=vlan10-internal,vlan20-servers servers=9.9.9.9,149.112.112.112")
a("/ip dns static")
L.extend(infra_lines)
L.extend(names)
a("/ip firewall address-list")
a("add address=10.1.30.2 comment=ctrld list=ctrld")
a("add address=10.1.30.4 comment=ctrld-b list=ctrld")
a("/ip firewall filter")
F = [
    'chain=input comment="accept established,related,untracked" connection-state=established,related,untracked action=accept',
    'chain=input comment="drop invalid" connection-state=invalid log=yes log-prefix=in-invalid action=drop',
    'chain=input comment="accept ICMP" protocol=icmp action=accept',
    'chain=input comment="accept to local loopback (for CAPsMAN)" dst-address=127.0.0.1 in-interface=lo src-address=127.0.0.1 action=accept',
    'chain=input comment="dhcp from restricted+guest+work" dst-port=67 in-interface-list=LOCALSVC protocol=udp action=accept',
    'chain=input comment="dns udp from restricted+guest+work" dst-port=53 in-interface-list=LOCALSVC protocol=udp action=accept',
    'chain=input comment="dns tcp from restricted+guest+work" dst-port=53 in-interface-list=LOCALSVC protocol=tcp action=accept',
    'chain=input comment="wireguard public edge" dst-port=51822 in-interface-list=WAN protocol=udp action=accept',
    'chain=input comment="drop all not coming from LAN" in-interface-list=!LAN action=drop',
    'chain=forward comment="accept in ipsec policy" ipsec-policy=in,ipsec action=accept',
    'chain=forward comment="accept out ipsec policy" ipsec-policy=out,ipsec action=accept',
    'chain=forward comment="dns to ctrld udp" dst-address-list=ctrld dst-port=53 protocol=udp action=accept',
    'chain=forward comment="dns to ctrld tcp" dst-address-list=ctrld dst-port=53 protocol=tcp action=accept',
    'chain=forward comment=ntp dst-address=10.1.20.16/30 dst-port=123 protocol=udp action=accept',
    'chain=forward comment="cameras: nvr to internet" connection-state=new src-address=10.1.60.2 out-interface-list=WAN action=accept',
    'chain=forward comment="cameras: no forwarding out of vlan 60" connection-state=new in-interface-list=RESTRICTED log=yes log-prefix=cam-block action=drop',
    'chain=forward comment="guest: voucher portal" dst-address=10.1.25.42 dst-port=443 in-interface-list=GUEST protocol=tcp action=accept',
    'chain=forward comment="guest: no lan" in-interface-list=GUEST log=yes log-prefix=guest-lan out-interface-list=LAN action=drop',
    'chain=forward comment="guest: no cameras" in-interface-list=GUEST log=yes log-prefix=guest-cam out-interface-list=RESTRICTED action=drop',
    'chain=forward comment="guest: no work" in-interface-list=GUEST out-interface-list=WORK action=drop',
    'chain=forward comment="work: internet only" in-interface-list=WORK out-interface-list=!WAN action=drop',
    'chain=forward comment="lan: no guest" connection-state=new in-interface-list=LAN out-interface-list=GUEST action=drop',
    'chain=forward comment="internal: reject encrypted dns 853" dst-port=853 in-interface=!vlan30-container in-interface-list=LAN src-address=!10.1.20.0/24 out-interface-list=WAN protocol=tcp action=reject reject-with=icmp-network-unreachable',
    'chain=forward comment="internal: reject encrypted dns 853 udp" dst-port=853 in-interface=!vlan30-container in-interface-list=LAN src-address=!10.1.20.0/24 out-interface-list=WAN protocol=udp action=reject reject-with=icmp-network-unreachable',
    'chain=forward comment="public edge: skedaddle to envoy-external" connection-state=new dst-address=10.1.25.41 dst-port=8022,8080,8443 in-interface=wg-public-edge protocol=tcp action=accept',
    'chain=forward comment=fasttrack connection-state=established,related action=fasttrack-connection',
    'chain=forward comment="accept established,related, untracked" connection-state=established,related,untracked action=accept',
    'chain=forward comment="public edge: drop everything else" in-interface=wg-public-edge action=drop',
    'chain=forward comment="drop invalid" connection-state=invalid log=yes log-prefix=fwd-invalid action=drop',
    'chain=forward comment="drop all from WAN not DSTNATed" connection-nat-state=!dstnat in-interface-list=WAN action=drop',
]
for f in F:
    a("add " + f)
a("/ip firewall nat")
a("add action=masquerade chain=srcnat comment=masquerade ipsec-policy=out,none out-interface-list=WAN")
# Every DNS query from LAN (except servers, VLAN 20) and cameras goes to ctrld; ctrld's own forwards and vlan30 are exempt.
for proto in ("udp", "tcp"):
    a(f'add chain=dstnat action=dst-nat to-addresses=10.1.30.2 protocol={proto} dst-port=53 in-interface-list=LAN in-interface=!vlan30-container src-address=!10.1.20.0/24 src-address-list=!ctrld dst-address-list=!ctrld comment="dns: force lan to ctrld {proto}"')
for proto in ("udp", "tcp"):
    a(f'add chain=dstnat action=dst-nat to-addresses=10.1.30.2 protocol={proto} dst-port=53 in-interface-list=RESTRICTED dst-address-list=!ctrld comment="dns: force cameras to ctrld {proto}"')
a("/ip service")
a("set ftp disabled=yes")
a("set telnet disabled=yes")
a("set www disabled=yes")
a("set api disabled=yes")
a("set api-ssl disabled=yes")
a("set www-ssl available-from=10.1.10.0/24,10.1.20.0/24,10.1.30.0/24,10.1.99.0/24")
a("/ip ssh")
a("set strong-crypto=yes")
a("/ip tftp")
for f in ("netboot.xyz.efi", "netboot.xyz.kpxe", "netboot.xyz-snponly.efi"):
    a(f"add ip-addresses=10.1.10.0/24,10.1.20.0/24 real-filename=usb1/tftp/{f} req-filename={f}")
a("/ipv6 dhcp-client")
a("add add-default-route=yes comment=spectrum interface=ether1 pool-name=spectrum-pd pool-prefix-length=64 prefix-hint=::/56 request=address,prefix use-peer-dns=no")
a("/ipv6 firewall address-list")
for addr, cmt in [("::/128", "unspecified address"), ("::1/128", "lo"), ("fec0::/10", "site-local"), ("::ffff:0.0.0.0/96", "ipv4-mapped"),
                  ("::/96", "ipv4 compat"), ("100::/64", "discard only "), ("2001:db8::/32", "documentation"),
                  ("2001:10::/28", "ORCHID"), ("3ffe::/16", "6bone")]:
    a(f'add address={addr} comment="{cmt}" list=bad_ipv6')
a("/ipv6 firewall filter")
F6 = [
    'chain=input comment="accept established,related,untracked" connection-state=established,related,untracked action=accept',
    'chain=input comment="drop invalid" connection-state=invalid log=yes log-prefix=in6-invalid action=drop',
    'chain=input comment="accept ICMPv6" protocol=icmpv6 action=accept',
    'chain=input comment="accept UDP traceroute" dst-port=33434-33534 protocol=udp action=accept',
    'chain=input comment="accept DHCPv6-Client prefix delegation." dst-port=546 protocol=udp src-address=fe80::/10 action=accept',
    'chain=input comment="drop everything else not coming from LAN" in-interface-list=!LAN action=drop',
    'chain=forward comment=fasttrack6 connection-state=established,related action=fasttrack-connection',
    'chain=forward comment="accept established,related,untracked" connection-state=established,related,untracked action=accept',
    'chain=forward comment="drop invalid" connection-state=invalid log=yes log-prefix=fwd6-invalid action=drop',
    'chain=forward comment="drop packets with bad src ipv6" log=yes log-prefix=bad6-src src-address-list=bad_ipv6 action=drop',
    'chain=forward comment="drop packets with bad dst ipv6" dst-address-list=bad_ipv6 log=yes log-prefix=bad6-dst action=drop',
    'chain=forward comment="rfc4890 drop hop-limit=1" hop-limit=equal:1 log=yes log-prefix=rfc4890 protocol=icmpv6 action=drop',
    'chain=forward comment="accept ICMPv6" protocol=icmpv6 action=accept',
    'chain=forward comment="guest: no lan" in-interface-list=GUEST log=yes log-prefix=guest6-lan out-interface-list=LAN action=drop',
    'chain=forward comment="guest: no cameras" in-interface-list=GUEST log=yes log-prefix=guest6-cam out-interface-list=RESTRICTED action=drop',
    'chain=forward comment="lan: no guest" in-interface-list=LAN out-interface-list=GUEST action=drop',
    'chain=forward comment="guest: internet only" in-interface-list=GUEST out-interface-list=WAN action=accept',
    'chain=forward comment="drop everything else not coming from LAN" in-interface-list=!LAN action=drop',
]
for f in F6:
    a("add " + f)
a("/routing bgp connection")
a('add afi=ip comment="cilium lb pool" instance=greyrock local.address=10.1.20.1 .role=ebgp name=cilium-kerfuffle remote.address=10.1.20.10 .as=64514')
a('add afi=ip comment="nas service ip" instance=greyrock local.address=10.1.20.1 .role=ebgp name=frr-codswallop remote.address=10.1.20.12 .as=64515')
a("/system clock")
a("set time-zone-autodetect=no time-zone-name=America/New_York")
a("/system identity")
a("set name=office-gw")
a("/system ntp client")
a("set enabled=yes")
a("/system ntp client servers")
for i in range(1, 5):
    a(f"add address=time{i}.internal.greyrock.io")
a("/tool mac-server")
a("set allowed-interface-list=LAN")
a("/tool mac-server mac-winbox")
a("set allowed-interface-list=LAN")
a("/tool netinstall")
for mac in ("18:FD:74:B2:D0:6F", "04:F4:1C:58:22:D5", "18:FD:74:B2:D0:1E"):
    a(f"add allow-flashfig=no install-once=yes interface=vlan99-mgmt ip-range=192.168.88.10-192.168.88.20 mac-address={mac} version=7.25.1")
a("# --- last: move the iMac's port into the bridge, drop the bootstrap address, turn on VLAN filtering.")
a("# The SSH session over 192.168.88.1 drops here and comes back on vlan99-mgmt.")
a("/interface bridge port")
a("add bridge=bridge comment=mgmt interface=ether2 pvid=99")
a("/ip address")
a("remove [find comment=bootstrap]")
a("add address=192.168.88.1/24 comment=netinstall interface=vlan99-mgmt")
a("/interface bridge")
a("set bridge vlan-filtering=yes")
open(out_main, "w").write("\n".join(L) + "\n")

V = ["# office-gw IPv6 addresses: import at Stage 4, after spectrum-pd exists on the real WAN.",
     "/ipv6 address",
     "add address=::a:0:0:0:1 from-pool=spectrum-pd interface=vlan10-internal",
     "add address=fdc0:ffee:215:a::1 interface=vlan10-internal",
     "add address=::14:0:0:0:1 from-pool=spectrum-pd interface=vlan20-servers",
     "add address=fdc0:ffee:215:14::1 interface=vlan20-servers",
     "add address=::ff:0:0:0:1 from-pool=spectrum-pd interface=vlan4000-guest",
     "add address=fdc0:ffee:215:ff::1 interface=vlan4000-guest"]
open(out_v6, "w").write("\n".join(V) + "\n")
print(f"main: {len(L)} lines, {len(leases)} leases, {len(names)} lease names, {len(infra_lines)} infra names")
