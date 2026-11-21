# office-crs309: undo step 2. Scheduled at T+15m by the arm step; runs at T+15m
# unless the l3-rollback scheduler entry is removed first. office-gw rolls back at the
# same time. Leaves the inert step 1 objects in place.
:log warning "l3: rollback starting (office-crs309)"
/interface ethernet switch l3hw-settings set ipv6-hw=no
/interface ethernet switch set switch1 l3-hw-offloading=no
/ip dns set mdns-repeat-ifaces=""
/routing bgp connection disable l3-cilium-kerfuffle,l3-frr-codswallop
/ip dhcp-relay disable relay-vlan10,relay-vlan20
/ip route set [find dst-address="0.0.0.0/0" gateway="10.255.0.1"] gateway=10.1.99.1
/ipv6 nd remove [find interface=vlan10-internal]
/ipv6 nd remove [find interface=vlan20-servers]
/ipv6 nd set [find default=yes] disabled=no
/ipv6 address remove [find interface=vlan10-internal and !link-local]
/ipv6 address remove [find interface=vlan20-servers and !link-local]
/ip address remove [find interface=vlan10-internal]
/ip address remove [find interface=vlan20-servers]
:log warning "l3: rollback done (office-crs309)"
