# office-gw, step 2: give up the VLAN 10/20 gateways. Run by scheduler at T; the
# switch side runs at T+5s. vlan10-internal and vlan20-servers stay up without
# addresses, so a client still holding the old gateway MAC is forwarded anyway.
:log warning "l3: cutover starting (office-gw)"
/ip address disable [find address="10.1.10.1/24"]
/ip address disable [find address="10.1.20.1/24"]
/ipv6 address disable [find interface=vlan10-internal and !dynamic]
/ipv6 address disable [find interface=vlan20-servers and !dynamic]
/ipv6 nd add advertise-dns=no comment="l3: no longer the vlan 10 router" interface=vlan10-internal ra-lifetime=0s
/ipv6 nd add advertise-dns=no comment="l3: no longer the vlan 20 router" interface=vlan20-servers ra-lifetime=0s
/ip route add comment="l3: vlan 10 via office-crs309" dst-address=10.1.10.0/24 gateway=10.255.0.2 scope=10
/ip route add comment="l3: vlan 20 via office-crs309" dst-address=10.1.20.0/24 gateway=10.255.0.2 scope=10
/ipv6 route add comment="l3: vlan 10 ula via office-crs309" dst-address=fdc0:ffee:215:a::/64 gateway=fdc0:ffee:215:fe::2
/ipv6 route add comment="l3: vlan 20 ula via office-crs309" dst-address=fdc0:ffee:215:14::/64 gateway=fdc0:ffee:215:fe::2
/ip dhcp-server set dhcp-vlan10 interface=vlan4090-transit relay=10.1.10.1
/ip dhcp-server set dhcp-vlan20 interface=vlan4090-transit relay=10.1.20.1
/ip dhcp-server network set [find address="10.1.10.0/24"] next-server=10.255.0.1
/ip dhcp-server network set [find address="10.1.20.0/24"] next-server=10.255.0.1
/ip dns set mdns-repeat-ifaces=""
:log warning "l3: cutover done (office-gw)"
