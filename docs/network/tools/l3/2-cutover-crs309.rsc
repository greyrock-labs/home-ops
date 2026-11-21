# office-crs309, step 2: take the VLAN 10/20 gateways. Run by scheduler at T+5s.
:log warning "l3: cutover starting (office-crs309)"
/interface bridge vlan set [find comment=trunk] vlan-ids=50,60,4000,4001
/interface bridge vlan add bridge=bridge comment=routed tagged=bridge,sfp-sfpplus1,sfp-sfpplus2,sfp-sfpplus3,sfp-sfpplus4 vlan-ids=10,20
/ip address add address=10.1.10.1/24 comment="vlan 10 gateway" interface=vlan10-internal
/ip address add address=10.1.20.1/24 comment="vlan 20 gateway" interface=vlan20-servers
/ipv6 address add address=fdc0:ffee:215:a::1/64 interface=vlan10-internal
/ipv6 address add address=fdc0:ffee:215:14::1/64 interface=vlan20-servers
/ipv6 address add address=::a:0:0:0:1/64 from-pool=office-pd interface=vlan10-internal
/ipv6 address add address=::14:0:0:0:1/64 from-pool=office-pd interface=vlan20-servers
/ipv6 nd set [find default=yes] disabled=yes
/ipv6 nd add advertise-dns=no interface=vlan10-internal ra-interval=30s-1m
/ipv6 nd add advertise-dns=no interface=vlan20-servers ra-interval=30s-1m
/ip route set [find dst-address="0.0.0.0/0" gateway="10.1.99.1"] gateway=10.255.0.1
/ip dhcp-relay enable relay-vlan10,relay-vlan20
/routing bgp connection enable l3-cilium-kerfuffle,l3-frr-codswallop
/ip dns set mdns-repeat-ifaces=vlan10-internal,vlan20-servers
/interface ethernet switch set switch1 l3-hw-offloading=yes
/interface ethernet switch l3hw-settings set ipv6-hw=yes
:log warning "l3: cutover done (office-crs309)"
