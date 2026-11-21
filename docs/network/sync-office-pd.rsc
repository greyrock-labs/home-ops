# Body of /system script sync-office-pd on office-gw. Not a top-level /import file.
# Delegates the /59 at subnet IDs 00-1f of the Spectrum /56 to office-crs309 as a
# static binding (RouterOS rejects an overlapping child pool). Runs on Spectrum DHCPv6
# events and every minute. applyChanges=false only prints what it would do.
:local applyChanges false
:local parentName "spectrum-pd"
:local serverName "office-crs309-pd"
:local transitName "vlan4090-transit"
:local clientDuid "FILL-DUID"
:local clientIaid 4090
:local parent [/ipv6 pool find where name=$parentName]
:local server [/ipv6 dhcp-server find where name=$serverName]
:local usable false
:local target ""
:local lifetime 0s

if ([:len $parent] = 1) do={
    :local prefix [:tostr [/ipv6 pool get $parent prefix]]
    :local slash [:find $prefix "/"]
    :local remaining [/ipv6 pool get $parent valid-lifetime]
    if (([:pick $prefix ($slash + 1) [:len $prefix]] = "56") && ($remaining > 2m) && (![/ipv6 pool get $parent inactive])) do={
        :set target ([:pick $prefix 0 $slash] . "/59")
        :set lifetime ($remaining - 1m)
        if ($lifetime > 5m) do={ :set lifetime 5m }
        :set usable true
    }
}

if (!$applyChanges) do={
    :put ("READ ONLY: usable=" . $usable . " delegated=" . $target . " life-time=" . $lifetime)
} else={
    if ([:len $server] != 1) do={ :error "office PD: expected one DHCPv6 server" }
    if ([/ipv6 dhcp-server get $server interface] != $transitName) do={ :error "office PD: unexpected server interface" }
    if ([/ipv6 dhcp-server get $server prefix-pool] != "static-only") do={ :error "office PD: expected static-only" }
    :local binding [/ipv6 dhcp-server binding find where server=$serverName]
    if ([:len $binding] > 1) do={ :error "office PD: unexpected additional bindings" }
    if ([:len $binding] = 1) do={
        if (([/ipv6 dhcp-server binding get $binding duid] != $clientDuid) || ([/ipv6 dhcp-server binding get $binding iaid] != $clientIaid)) do={
            :error "office PD: unexpected client identity"
        }
    }
    if (!$usable) do={
        /ipv6 dhcp-server disable $server
        if ([:len $binding] = 1) do={ /ipv6 dhcp-server binding remove $binding }
    } else={
        if ([:len $binding] = 1) do={
            if ([:tostr [/ipv6 dhcp-server binding get $binding address]] != $target) do={
                /ipv6 dhcp-server disable $server
                /ipv6 dhcp-server binding remove $binding
                :set binding ""
            }
        }
        if ([:len $binding] = 0) do={
            /ipv6 dhcp-server binding add address=$target server=$serverName duid=$clientDuid iaid=$clientIaid life-time=$lifetime comment="office CRS309 PD"
            :log info "office PD: downstream binding updated"
        } else={
            if ([/ipv6 dhcp-server binding get $binding life-time] != $lifetime) do={
                /ipv6 dhcp-server binding set $binding life-time=$lifetime
            }
        }
        if ([/ipv6 dhcp-server get $server disabled]) do={ /ipv6 dhcp-server enable $server }
    }
}
