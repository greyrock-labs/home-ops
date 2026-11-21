# office-crs309, step 1: transit, routed VLAN interfaces, BGP and relays, all inert.
# Nothing here changes forwarding: the VLAN 10/20 interfaces have no addresses, the
# relays and BGP connections are disabled.
/interface bridge set bridge mtu=9000
/interface bridge port set [find interface=sfp-sfpplus1] multicast-router=permanent
# Creating vlan10/vlan20 adds a dynamic bridge VLAN entry tagging the bridge itself.
/interface bridge vlan add bridge=bridge comment=transit tagged=bridge,sfp-sfpplus1 vlan-ids=4090
/interface vlan add interface=bridge mtu=9000 name=vlan4090-transit vlan-id=4090 comment="transit to office-gw"
/interface vlan add interface=bridge mtu=9000 name=vlan10-internal vlan-id=10
/interface vlan add interface=bridge mtu=9000 name=vlan20-servers vlan-id=20
/ip address add address=10.255.0.2/30 interface=vlan4090-transit comment="transit to office-gw"
/ipv6 address add address=fdc0:ffee:215:fe::2/64 advertise=no interface=vlan4090-transit comment="transit to office-gw"
/ipv6 route add dst-address=::/0 gateway=fdc0:ffee:215:fe::1 comment="default via office-gw"
/ipv6 dhcp-client add interface=vlan4090-transit request=prefix pool-name=office-pd pool-prefix-length=64 prefix-hint=::/59 add-default-route=no use-peer-dns=no custom-iapd-id=4090 comment="vlan 10/20 /59 from office-gw"

/ip dhcp-relay add name=relay-vlan10 interface=vlan10-internal dhcp-server=10.255.0.1 local-address=10.1.10.1 disabled=yes
/ip dhcp-relay add name=relay-vlan20 interface=vlan20-servers dhcp-server=10.255.0.1 local-address=10.1.20.1 disabled=yes

/routing id add comment="bgp router-id" id=10.255.0.2 name=router-id select-from-vrf=main
/routing bgp instance add as=64516 name=greyrock-l3
# A chain rejects whatever no rule accepts; l3-out needs one rule to exist.
/routing filter rule add chain=l3-cilium-in rule="if (dst in 10.1.25.0/24 && dst-len == 32) { accept }"
/routing filter rule add chain=l3-nas-in rule="if (dst == 10.1.25.21/32) { accept }"
/routing filter rule add chain=l3-out rule="if (dst in 0.0.0.0/0) { reject }"
/routing bgp connection add afi=ip comment="cilium lb pool" disabled=yes input.filter=l3-cilium-in instance=greyrock-l3 local.address=10.1.20.1 .role=ebgp name=l3-cilium-kerfuffle output.filter-chain=l3-out remote.address=10.1.20.10 .as=64514
/routing bgp connection add afi=ip comment="nas service ip" disabled=yes input.filter=l3-nas-in instance=greyrock-l3 local.address=10.1.20.1 .role=ebgp name=l3-frr-codswallop output.filter-chain=l3-out remote.address=10.1.20.12 .as=64515
