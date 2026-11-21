# office-gw: undo step 2. Scheduled at T+15m by the arm step, the same time as the switch.
:log warning "l3: rollback starting (office-gw)"
/ip dhcp-server set dhcp-vlan10 interface=vlan10-internal
/ip dhcp-server unset dhcp-vlan10 relay
/ip dhcp-server set dhcp-vlan20 interface=vlan20-servers
/ip dhcp-server unset dhcp-vlan20 relay
/ip dhcp-server network set [find address="10.1.10.0/24"] next-server=10.1.10.1
/ip dhcp-server network set [find address="10.1.20.0/24"] next-server=10.1.20.1
/ip route remove [find comment~"^l3: "]
/ipv6 route remove [find comment~"^l3: "]
/ipv6 nd remove [find comment~"^l3: "]
/ip address enable [find address="10.1.10.1/24"]
/ip address enable [find address="10.1.20.1/24"]
/ipv6 address enable [find interface=vlan10-internal]
/ipv6 address enable [find interface=vlan20-servers]
/ip dns set mdns-repeat-ifaces=vlan10-internal,vlan20-servers
:log warning "l3: rollback done (office-gw)"
