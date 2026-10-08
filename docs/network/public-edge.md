# Public edge

Public traffic for `*.greyrock.io` enters at `skedaddle`, the RackNerd VPS, and reaches
`envoy-external` (10.1.25.41) over a dedicated WireGuard tunnel to `office-gw`. Nothing at
home is exposed to the internet except the tunnel's UDP port.

```
client ─► skedaddle caddy-l4 :443 / :80 / :22
            │  PROXY v2, raw TCP
            ▼
          public-edge (10.254.45.2) ══ WireGuard ══► office-gw wg-public-edge :51822
                                                      │  forward, no NAT
                                                      ▼
                                   envoy-external 10.1.25.41 :8443 / :8080 / :8022
```

`ingress-ext.greyrock.io` and the `skedaddle-*` names point at the VPS through the
`public-edge` DNSEndpoint in `kubernetes/apps/network/external-dns/cloudns/`.

## skedaddle

`ansible/skedaddle/playbook.yaml`, tag `public-edge`:

- `/etc/wireguard/public-edge.conf`: address `10.254.45.2/32`, MTU 1420, `Table = off`,
  one peer (`office-gw`) with `AllowedIPs = 10.1.25.41/32`. The endpoint is the router's
  MikroTik cloud DDNS name, `hmm0bddpjam.sn.mynetname.net:51822`, because the WAN address
  comes from DHCP.
- `public-edge-route.service` adds the only route through the tunnel,
  `10.1.25.41/32 dev public-edge src 10.254.45.2`. With `Table = off`, wg-quick installs
  no routes itself, so the VPS reaches nothing else at home.
- `public_edge_start=false` stops and disables both units.

Keys come from 1Password, `automation/Skedaddle - Wireguard - MikroTik Public Edge`:
`private_key` and `public_key` are skedaddle's, and `server_public_key` is the router's.

Caddy (`docker/skedaddle/03-caddy-l4/`) answers the names in `VPS_LOCAL_HOSTS` itself.
It forwards every other TLS connection on 443 to `10.1.25.41:8443`, every other HTTP
request on 80 to `:8080`, and all of 22 to `:8022`. Every hop carries PROXY v2, so Envoy and
Forgejo see the real client address. Host SSH is on 22222.

doco-cd polls the GitHub mirror hourly. Restarting the `doco-cd` container applies a push
immediately.

## office-gw

- `wg-public-edge`: listen port 51822, MTU 1420, address `10.254.45.1/24`, a single peer
  `skedaddle` with `allowed-address=10.254.45.2/32`.
- Input: `wireguard public edge` accepts UDP 51822 from `WAN`, above
  `drop all not coming from LAN`. The interface is in no interface list, so everything
  else from it to the router hits that drop.
- Forward: `public edge: skedaddle to envoy-external` accepts new TCP to `10.1.25.41`
  ports 8022, 8080 and 8443. `public edge: drop everything else` drops the rest from the
  tunnel.
- No srcnat. Envoy's policy matches on `10.254.45.2`, so the source must arrive unchanged.

**The drop rule must sit below `accept established,related, untracked`.** The accept
rule only matches `connection-state=new`, and v4 forward is otherwise default-accept (see
[router-baseline.md](router-baseline.md)). If the drop sits above the established accept,
the handshake completes and every packet after it is dropped, and connections to the
edge hang with no response.

## Cluster

`kubernetes/apps/network/envoy-gateway/gateway/` has `external/`, `internal/` and `shared/`.

`envoy-external` has two sets of listeners:

| Listener | Port | PROXY protocol | Used by |
| --- | --- | --- | --- |
| `http` / `https` / `ssh` | 80 / 443 / 22 | not accepted | direct connections to 10.1.25.41 |
| `http-proxy` / `https-proxy` / `ssh-proxy` | 8080 / 8443 / 8022 | required | skedaddle |

Each proxy listener has its own ClientTrafficPolicy with `proxyProtocol.optional: false`.
The http-proxy and https-proxy policies strip any incoming `x-forwarded-for`, so the client
address comes only from the PROXY header. `https-redirect` covers `http-proxy` too and
redirects to port 443.

`envoy-external-ingress` (CiliumNetworkPolicy) allows the direct listener, health and
metrics ports from anywhere, and the three proxy ports only from `10.254.45.2/32`. That is
what keeps other hosts from sending forged PROXY headers.

Forgejo runs `SSH_SERVER_USE_PROXY_PROTOCOL: true`. Its TCPRoute attaches to both `ssh`
and `ssh-proxy`, and the `forgejo-ssh-proxy` BackendTrafficPolicy sends PROXY v2 to the pod.
`forgejo-ingress` allows port 2222 only from `envoy-external` pods, and port 3000 from
anywhere.

## Checking it

From skedaddle:

```
sudo wg show public-edge; ip route get 10.1.25.41
```

The latest handshake should be under two minutes old, and the route should leave via
`public-edge` with `src 10.254.45.2`.

From outside, forcing the VPS address:

```
curl -sS -o /dev/null -w '%{http_code}\n' --resolve git.greyrock.io:443:104.168.59.58 https://git.greyrock.io/; ssh -T git@104.168.59.58
```

If connections open and then hang, watch Hubble on the node running `envoy-external`:

```
kubectl -n kube-system exec <cilium pod on that node> -c cilium-agent -- hubble observe --ip 10.254.45.2 --last 25 -o compact
```

A repeating SYN-ACK with no ACK from `10.254.45.2` means `office-gw` is dropping the
tunnel's return path. Check the forward rule order.
