# Kiosk Wi-Fi stalls (open)

The wall display (`guest-wifi-display.internal.greyrock.io`, see
`docs/homeassistant/kiosk/README.md`) has short traffic stalls on Wi-Fi. Status as of
2026-10-14: open.

| | |
| --- | --- |
| MAC | 88:a2:9e:a1:fe:1f |
| IP | 10.1.10.97 |
| SSID | Grey Rock IoT (2.4 GHz) |
| BSSID lock | 00:33:58:6B:0B:E0 (`kitchen-ap`) |

## Symptom

Stalls of a few seconds while the Pi stays associated. In a 60-round probe, the gateway
ping, the HA ping and an HA curl failed together in 4–5 rounds, with no disconnect
events. Still happening on 2026-10-14: one ping reply took 1155 ms, one was lost, and
an SSH session hung.

## Ruled out

- **Roaming.** wpa_supplicant's bgscan kept moving the Pi to `upstairs-hallway-ap`
  (5c:83:6c:7b:0e:d0), where it hit auth timeouts and lost the link for ~10 s every
  30–36 min. The connection is now pinned with `802-11-wireless.bssid
  00:33:58:6B:0B:E0`. Overnight 2026-10-13/14 it had zero disconnects, only GTK rekeys,
  but the stalls continued, so bgscan was not their cause.
- **Power save.** Wi-Fi powersave was already off.

`autoconnect-retries` is 0 on the connection.

## Constraints

The journal is volatile on purpose to spare the SD card. Todd declined a persistent
journal; do not enable one.

## Not yet investigated

- `office-gw` logs `fwd-invalid` TCP RST/FIN from the Pi to 10.1.25.42:443.

## Planned watchdog rework (not deployed)

The `kiosk-watchdog` timer is stopped on the Pi; leave it stopped. The rework:

- Check HA over HTTP only, retried over ~30 s.
- Restart TouchKio after 3+ consecutive failures (a restart also wakes the screen).
- Reconnect only if NetworkManager reports disconnected for 3 checks.
- Bounce the radio at 5 HA-down checks; reboot at 15.

## Screen blanking (deprioritised)

swayidle (`timeout 600`, wlopm) in `~/.config/labwc/autostart` reports idle correctly,
but TouchKio logged no display-off overnight. Unresolved; Todd put it behind the stalls.
