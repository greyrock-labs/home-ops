# Network build generators

Scripts that produce the configs the 2026-11 rebuild was built from. They hold the port maps
and conventions described in [switch-baseline.md](../switch-baseline.md) and
[router-baseline.md](../router-baseline.md); change the data here when a port moves, so a
rebuilt device comes out the same as the running one. None of them emit secrets.

| Script             | Output                                                     | Usage                                                                                               |
| ------------------ | ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `gen_icx.py`       | FastIron 10.0 CLI config for one ICX8200                   | `gen_icx.py <office\|gameroom\|garage>-<c08zp\|c08pf> <out.txt>`                                    |
| `gen_crs309.py`    | RouterOS import for one CRS309 (L2 spine)                  | `gen_crs309.py <office\|gameroom\|garage> <out.rsc>`                                                |
| `gen_office_gw.py` | RouterOS import for the RB5009, plus its IPv6 address file | `gen_office_gw.py <sept-backup.txt> <reservations.csv> <out-main.rsc> <out-ipv6.rsc> <hostnames.txt>` |

## Building a device

- **ICX:** console bootstrap first (static `ve 99` address, `todd.pub` from TFTP; see
  switch-baseline.md), then paste the generated config over SSH. `jumbo` needs a reload, then
  `ip mtu 9198` on `ve 99`.
- **CRS309:** netinstall 7.25.1 from the RB5009 (switch-baseline.md, "CRS309 netinstall from the
  RB5009"), then `/import` the generated file, dry run first
  (`/import file-name=<file> dry-run verbose=yes`). The import adds a `bench` 192.168.88.x
  address for the build; remove it once the switch is in its rack.
- **RB5009:** the generator reads the 2026-09-29 RB5009 backup export and the reservations CSV,
  both kept outside the repo (`~/Downloads`) because the backup holds secrets. Added by hand
  after the import: the Cloudflare token for acme, the `externaldns`/`dexd` user passwords
  (1Password `MikroTik - External DNS`, `MikroTik - dexd`), the skedaddle WireGuard peer's
  public key (`Skedaddle - Wireguard - MikroTik Public Edge`), and the IPv6 file once the WAN
  delegation is up.

Generated output goes outside the repo; it is reproducible from these scripts.
