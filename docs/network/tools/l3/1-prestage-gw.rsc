# office-gw, step 1: transit, BGP over transit and the PD server, all inert until
# office-crs309 holds the gateways. The VLAN 10/20 gateways stay here.
/interface bridge vlan add bridge=bridge comment=transit tagged=bridge,sfp-sfpplus1 vlan-ids=4090
/interface vlan add interface=bridge mtu=9000 name=vlan4090-transit vlan-id=4090 comment="transit to office-crs309"
/interface list member add interface=vlan4090-transit list=LAN
/ip address add address=10.255.0.1/30 interface=vlan4090-transit comment="transit to office-crs309"
/ipv6 address add address=fdc0:ffee:215:fe::1/64 advertise=no interface=vlan4090-transit comment="transit to office-crs309"

# Second pair of sessions, sourced from transit. Cilium and FRR only answer once the
# BGP PR is merged; until then these sit in Active.
/routing bgp connection add afi=ip comment="cilium lb pool (transit)" instance=greyrock local.address=10.255.0.1 .role=ebgp multihop=yes name=cilium-kerfuffle-transit remote.address=10.1.20.10 .as=64514
/routing bgp connection add afi=ip comment="nas service ip (transit)" instance=greyrock local.address=10.255.0.1 .role=ebgp multihop=yes name=frr-codswallop-transit remote.address=10.1.20.12 .as=64515

# Static-only: the binding comes from the sync-office-pd script.
/ipv6 dhcp-server add disabled=yes interface=vlan4090-transit name=office-crs309-pd prefix-pool=static-only
