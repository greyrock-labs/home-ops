# Network build generators

Scripts that produce the configs the 2026-11 rebuild was built from. They hold the port maps
and conventions described in [switch-baseline.md](../switch-baseline.md) and
[router-baseline.md](../router-baseline.md); change the data here when a port moves, so a
rebuilt device comes out the same as the running one. None of them emit secrets.

| Script             | Output                                                     | Usage                                                                                               |
| ------------------ | ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `gen_icx.py`       | FastIron 10.0 CLI config for one ICX8200                   | `gen_icx.py <office\|gameroom\|garage>-<c08zp\|c08pf> <out.txt>`                                    |
| `gen_crs309.py`    | RouterOS import for one CRS309 (office also routes 10/20)  | `gen_crs309.py <office\|gameroom\|garage> <out.rsc>`                                                |
| `gen_office_gw.py` | First RB5009 build (record only, see below)                | `gen_office_gw.py <sept-backup.txt> <reservations.csv> <out-main.rsc> <out-ipv6.rsc> <hostnames.txt>` |

## Building a device

- **ICX:** console bootstrap first (static `ve 99` address, `todd.pub` from TFTP; see
  switch-baseline.md), then paste the generated config over SSH. `jumbo` needs a reload, then
  `ip mtu 9198` on `ve 99`.
- **CRS309:** netinstall 7.25.1 from the RB5009 (switch-baseline.md, "CRS309 netinstall from the
  RB5009"), then `/import` the generated file, dry run first
  (`/import file-name=<file> dry-run verbose=yes`). The import adds a `bench` 192.168.88.x
  address for the build; remove it once the switch is in its rack.
- **RB5009:** restore from the router's own config, not the generator. 1Password
  (Infrastructure vault) holds `office-gw (RB5009) backup 2026-11-21` (binary, unencrypted,
  includes secrets: `/system backup load`) and `office-gw (RB5009) export 2026-11-21`
  (`/export`, no secrets: import on a no-defaults 7.25.1 router, then add the Cloudflare token,
  the `externaldns`/`dexd` passwords and the acme setup by hand). Take a fresh pair after any
  significant change. `gen_office_gw.py` is the record of how the router was first built from
  the 2026-09-29 backup; its inputs (that backup and the reservations CSV) were kept outside
  the repo and are not needed for a restore.

Generated output goes outside the repo; it is reproducible from these scripts.

## Unleashed client names

`unleashed_rename.py` sets Unleashed's client names from the reservations CSV (name and MAC
per row), with an optional UniFi export as a fallback for clients without a reservation. It
logs in once and stops on a failed login, so it cannot lock the account. Without `--apply` it
only lists the changes.

```
UL_USER=$(kubectl -n network get secret wifi-cert-updater-ruckus -o jsonpath='{.data.UPDATER_USERNAME}' | base64 -d) \
UL_PASS=$(kubectl -n network get secret wifi-cert-updater-ruckus -o jsonpath='{.data.RUCKUS_PASSWORD}' | base64 -d) \
python3 unleashed_rename.py ~/Downloads/dhcp-reservations-2026-11-19.csv [--fallback <unifi-clients.csv>] [--apply]
```

