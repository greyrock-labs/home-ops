# Kiosk Wi-Fi stalls

The wall display (`guest-wifi-display.internal.greyrock.io`, see
`docs/homeassistant/kiosk/README.md`) loses its Wi-Fi data path for seconds to a minute
at a time. As of 2026-10-14 the evidence points at the Pi 4's own Wi-Fi transmit side;
Todd is considering replacing the Pi.

| | |
| --- | --- |
| MAC | 88:a2:9e:a1:fe:1f |
| IP | 10.1.10.97 |
| SSID | Grey Rock IoT (2.4 GHz, `kitchen-ap` channel 1) |
| BSSID lock | 00:33:58:6B:0B:E0 (`kitchen-ap`) |
| Chip | BCM4345/6, firmware 7.45.265, wpa_supplicant 2.10, NetworkManager 1.52 |

## Symptom

Pinged from `office-gw` (wired), the Pi loses 24–45% over 5 minutes in outages of
10–40 s, often about a minute apart, plus a latency bump every ~12 s. The Pi stays
associated throughout: no disconnect, nothing in its journal, and its userspace keeps
running.

## Evidence it is the Pi

- During an outage `kitchen-ap` shows the Pi associated at -48 dBm, and the Pi still
  receives unicast (its HTTPS session with HA at 10.1.10.3 keeps arriving). What fails is
  sending: `tx failed` reached 59% of `tx packets` in 5 minutes.
- The Pi's 802.11 `rx packets` rate rises ~2.6× during outages, but a raw-socket capture
  shows the same IP traffic up and down (mDNS ~40 pps, HA). The extra frames are the AP
  retransmitting because the Pi's ACKs are not reaching it.
- Other `kitchen-ap` channel 1 clients (Bluetooth Proxy - Kitchen, HVAC - Kitchen) and
  the 5 GHz radio stay at 0% loss over the same windows. The Davis weather station on the
  wall above the Pi also drops at times, but it is an Android tablet with weak Wi-Fi and
  is not a reliable control.
- The Pi cannot associate with any AP but `kitchen-ap`. `upstairs-hallway-ap` (Grey Rock
  IoT) and Grey Rock (WPA3, 5 GHz) both end in `ASSOC-REJECT status_code=16` after
  repeated attempts. The firmware logs these rejects against the previous BSSID
  (`00:33:58:6b:0b:e0`), not the one it is trying.

## Ruled out

- **Roaming.** bgscan moved the Pi to `upstairs-hallway-ap` and lost the link; the BSSID
  lock stopped the roams, not the stalls.
- **Power save.** Off (`iw` reports `Power save: off`).
- **Power and heat.** `vcgencmd get_throttled` is `0x0` since boot, ~40 °C, no USB
  devices, display is DSI only.
- **BSS Min Rate.** Grey Rock IoT was at 12 Mbps; lowering it to Disabled did not change
  the outages.
- **Network traffic as a trigger.** See the capture above. AP airtime and multicast
  counters also showed nothing that lines up; Unleashed refreshes them only about once a
  minute, so finer polling adds nothing.
- **802.11r on Grey Rock.** It advertises `SAE FT/SAE` and stays on (Wi-Fi calling). The
  Pi's failure there matches its failure on non-FT Grey Rock IoT, so FT is not shown to be
  the cause.

Not investigated: `office-gw` logs `fwd-invalid` TCP RST/FIN from the Pi to
10.1.25.42:443, possibly sessions that went stale during outages.

`kitchen-ap` logs no per-client events for the Pi in VictoriaLogs; AP syslog does not
help with this.

## Constraints

- The journal is volatile on purpose to spare the SD card. Todd declined a persistent
  journal; do not enable one.
- No Ethernet run to the display and no USB Wi-Fi adapter. The Pi is mounted on the back
  of the official touchscreen on a 3D-printed plastic stand.
- Unleashed's client records (`getstat` `client`) include the WLAN passphrase in
  `wpa-passphrase`. Filter it out before printing.

## Planned watchdog rework (not deployed)

The `kiosk-watchdog` timer is stopped on the Pi; leave it stopped. The rework:

- Check HA over HTTP only, retried over ~30 s.
- Restart TouchKio after 3+ consecutive failures (a restart also wakes the screen).
- Reconnect only if NetworkManager reports disconnected for 3 checks.
- Bounce the radio at 5 HA-down checks; reboot at 15.

## Screen blanking (deprioritised)

swayidle (`timeout 600`, wlopm) in `~/.config/labwc/autostart` reports idle correctly,
but TouchKio logged no display-off overnight. Unresolved; Todd put it behind the stalls.
