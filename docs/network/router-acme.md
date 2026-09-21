# Router certificates (acme.sh on the RB5009)

`office-gw` gets a real Let's Encrypt certificate from a RouterOS container running
acme.sh, validated over DNS-01 against ClouDNS and installed by acme.sh's `routeros`
deploy hook. Renewal is unattended.

Adapted from https://gist.github.com/ergosteur/34a60e4c3c22a1ee399ee15e19026326, which
targets Cloudflare and an older RouterOS container model. The differences are large
enough that the gist should not be followed literally — see *Differences from the
source guide* below.

## Why

`external-dns` talks to the router's REST API, which is served by `www-ssl`. Without a
real certificate that connection needs `MIKROTIK_SKIP_TLS_VERIFY`. A trusted cert on
`www-ssl` removes the exception rather than documenting it.

## Certificate scope

Issued for `greyrock.io` and `*.internal.greyrock.io`, EC P-256.

- **Wildcard, deliberately.** Every non-wildcard name on a public certificate lands in
  the Certificate Transparency logs. `*.internal.greyrock.io` keeps internal hostnames
  out of them.
- **`greyrock.io` is the first `-d`, not `internal.greyrock.io`.** The apex is already in
  CT from the cluster's gateway certificate, so it leaks nothing new; adding
  `internal.greyrock.io` would have put a label there that is not public today.
- **The first `-d` must not be the wildcard.** acme.sh's `routeros` deploy hook
  interpolates the first domain raw into SCP filenames, `/certificate remove [find
  name=...]` expressions, and a `/system script` name. A leading `*` in those breaks.
  A non-wildcard first name with the wildcard as a SAN covers the same names safely.
- The router therefore holds a certificate for `greyrock.io` in parallel with the
  cluster's. Two independent certs for one name is fine with Let's Encrypt.

## Credentials

ClouDNS, the same provider the cluster's `cert-manager-webhook-cloudns` uses. 1Password
item `ClouDNS`, properties `cert-manager-auth-id` and `cert-manager-auth-password`. The
webhook runs `authIdType: auth-id`, so acme.sh wants `CLOUDNS_AUTH_ID` — not the
`CLOUDNS_SUB_AUTH_ID` variant.

## As-built

| | |
| --- | --- |
| Container | `acme`, image `neilpang/acme.sh:latest` |
| Root dir | `usb1/acme-root` |
| Mount list | `acme` — `usb1/acme` to `/acme.sh` |
| Env list | `acme` |
| veth | `veth-acme`, 10.1.30.3/24, gateway 10.1.30.1, bridge port `pvid=30` |
| Container DNS | 10.1.30.2 (ctrld) |
| RouterOS user | `acme`, group `acme`, key-only |
| Bound service | `www-ssl` (443). `www` (80) stays disabled. |

VLAN 30 is the container VLAN and is a member of the `LAN` interface list, so input
rule 7 (`drop all not coming from LAN`) does not block the container's SSH to
10.1.30.1. No firewall rule was needed.

One mount, not the gist's two. `/acme.sh` is both `$HOME` and `$LE_CONFIG_HOME` in that
image, so state and SSH keys live under it together and the deploy hook is pointed at
the key explicitly via `ROUTER_OS_SSH_CMD` / `ROUTER_OS_SCP_CMD`.

The `acme` user group is `ssh,ftp,read,write,policy,test`. The hook's own documentation
says ssh/ftp/read/write, but it also adds, runs, and removes a `/system script`, which
needs `policy` and `test`. This is tighter than the gist's `group=full`.

## Differences from the source guide

- `/container mounts add` takes `list=`, not `name=`. `/container add` takes
  `mountlists=`, not `mounts=`.
- `/container envs add` takes `key=`, not `name=`.
- The image's entrypoint is `/entry.sh`. The gist says `/entrypoint.sh`.
- USB paths are `usb1/...`, not `usb1-part1/...`.
- `/container config` was already set for ctrld (`layer-dir=usb1/pull tmpdir=usb1/pull`)
  and is shared. Do not re-run step 0.
- `--dns dns_cloudns` with `CLOUDNS_AUTH_ID` / `CLOUDNS_AUTH_PASSWORD`, not `dns_cf`.
- **No `/system scheduler` entry.** `cmd=daemon` makes the image run supercronic against
  a crontab it generates at `/acme.sh/crontab`, firing `acme.sh --cron` four times a
  day. With `start-on-boot=yes` that is the whole renewal mechanism. The gist's step 12
  scheduler is an alternative to daemon mode, not an addition to it.

## Build

Container config, the veth, and the RouterOS user:

```
/file add type=directory name=usb1/acme
/container mounts add list=acme src=usb1/acme dst=/acme.sh
/container envs add list=acme key=CLOUDNS_AUTH_ID value="<from 1Password>"
/container envs add list=acme key=CLOUDNS_AUTH_PASSWORD value="<from 1Password>"
/container envs add list=acme key=ROUTER_OS_USERNAME value="acme"
/container envs add list=acme key=ROUTER_OS_HOST value="10.1.30.1"
/container envs add list=acme key=ROUTER_OS_PORT value="22"
/container envs add list=acme key=ROUTER_OS_SSH_CMD value="ssh -p 22 -i /acme.sh/.ssh/routeros -o UserKnownHostsFile=/acme.sh/.ssh/known_hosts -o StrictHostKeyChecking=accept-new"
/container envs add list=acme key=ROUTER_OS_SCP_CMD value="scp -P 22 -i /acme.sh/.ssh/routeros -o UserKnownHostsFile=/acme.sh/.ssh/known_hosts -o StrictHostKeyChecking=accept-new"
/interface veth add name=veth-acme address=10.1.30.3/24 gateway=10.1.30.1
/interface bridge port add bridge=bridge interface=veth-acme pvid=30
/user group add name=acme policy=ssh,ftp,read,write,policy,test
/user add name=acme password="" group=acme comment="acme.sh cert deploy"
/container add name=acme remote-image=neilpang/acme.sh:latest hostname=acme interface=veth-acme mountlists=acme envlist=acme root-dir=usb1/acme-root dns=10.1.30.2 entrypoint="/entry.sh" cmd="daemon" logging=yes start-on-boot=yes comment="acme.sh cert automation"
/container start [find name="acme"]
```

Key generation, inside `/container shell [find name="acme"]`:

```
mkdir -p /acme.sh/.ssh
chmod 700 /acme.sh/.ssh
ssh-keygen -t ed25519 -f /acme.sh/.ssh/routeros -N ""
cp /acme.sh/.ssh/routeros.pub /acme.sh/routeros.pub
```

The `cp` matters: RouterOS will not reliably list a dot-directory, and the import below
takes a path.

```
/user ssh-keys import user=acme public-key-file=usb1/acme/routeros.pub
```

Issue and deploy, inside the container shell:

```
acme.sh --set-default-ca --server letsencrypt
acme.sh --issue --dns dns_cloudns --dnssleep 120 --keylength ec-256 -d greyrock.io -d "*.internal.greyrock.io"
acme.sh --deploy -d greyrock.io --ecc --deploy-hook routeros
```

`--ecc` is required on every operation after issuance — the certificate lives in
`greyrock.io_ecc`, and without the flag acme.sh looks in the RSA directory and reports
the domain as unknown.

Finally:

```
/ip service enable [find name="www-ssl"]
```

## Verifying

Before issuing, from the container shell — this catches a bad key, no route out, or
stale ClouDNS credentials before burning a Let's Encrypt attempt:

```
ssh -i /acme.sh/.ssh/routeros -o UserKnownHostsFile=/acme.sh/.ssh/known_hosts -o StrictHostKeyChecking=accept-new acme@10.1.30.1 "/system identity print"
curl -sI https://acme-v02.api.letsencrypt.org/directory | head -1
curl -s "https://api.cloudns.net/dns/login.json?auth-id=$CLOUDNS_AUTH_ID&auth-password=$CLOUDNS_AUTH_PASSWORD"
```

The first also seeds `known_hosts`, which `ROUTER_OS_SSH_CMD` points at. Without it the
deploy hook stalls on host-key confirmation.

After deploying:

```
/certificate print where common-name~"greyrock.io"
/ip service print where name="www-ssl"
```

Want `K` (private key present) and `T` (trusted) on `greyrock.io.cer_0`, both SANs, and
the service enabled and bound to it. The full chain imports as four certificates; the
intermediates land as `greyrock.io.cer_1` through `_3` and the hook removes them itself
on the next renewal.

Renewal settings persist in the domain config and are what cron replays:

```
grep -E "Le_DeployHook|Le_DNSSleep|Le_API|Le_Keylength" /acme.sh/greyrock.io_ecc/greyrock.io.conf
cat /acme.sh/crontab
```

## Open items

- **`--dnssleep 120` rather than propagation checking.** acme.sh's DNS check spins
  indefinitely here; the cause was not established. The flag is saved in the domain
  config, so renewals skip the check too.

Renewal has been exercised with `acme.sh --renew -d greyrock.io --ecc --force`: a new
certificate issued, the saved `Le_DeployHook` fired without a TTY, four certificates and
one key imported, and the `www-ssl` binding survived the hook's remove-and-reimport.

acme.sh picks the next renewal from Let's Encrypt's ARI window rather than a fixed 60
days, so the scheduled date comes from the CA and moves between runs.

`external-dns` reaches the router at `https://office-gw.internal.greyrock.io` with no
`MIKROTIK_SKIP_TLS_VERIFY`. Verified from inside the cluster: the name resolves through
CoreDNS and curl returns an HTTP status without `-k`.
