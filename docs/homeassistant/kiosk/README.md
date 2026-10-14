# Wall Display (guest-wifi-display)

Raspberry Pi 4 with the official DSI touchscreen, running
[TouchKio](https://github.com/leukipp/touchkio) 1.5.0 as a kiosk for Home Assistant.

- Host: `guest-wifi-display.internal.greyrock.io` (SSH as `todd`, passwordless sudo)
- OS: Debian 13 (trixie), labwc/Wayland, NetworkManager
- Network: Wi-Fi connection `Grey Rock IoT`, gateway `10.1.10.1`
- TouchKio: systemd user service `touchkio.service` (user `todd`), config in
  `~/.config/touchkio/Arguments.json`, logs in `~/.config/touchkio/logs/main.log`.
  Loads `https://home.internal.greyrock.io`.

## Reliability fixes

Before these fixes, there were two failure modes, and neither recovered on its own:

1. **Wi-Fi drops and never reconnects.** NetworkManager stops trying after
   4 failed attempts (the default).
2. **Display stuck on an error after an HA outage.** If HA is unreachable when the
   page loads, TouchKio stays on the error page and never retries.

What's configured on the Pi:

- Wi-Fi power save is off: `/etc/NetworkManager/conf.d/wifi-powersave-off.conf`
  (`wifi.powersave = 2`).
- Unlimited reconnect attempts:
  `nmcli connection modify "Grey Rock IoT" connection.autoconnect-retries 0`
  (the default is `-1`, which means NM's global limit of 4).
- Locked to `kitchen-ap` (2026-10-13):
  `nmcli connection modify "Grey Rock IoT" 802-11-wireless.bssid 00:33:58:6B:0B:E0`.
  wpa_supplicant's `bgscan simple` kept trying to roam to `upstairs-hallway-ap`
  (`5c:83:6c:7b:0e:d0`), and each attempt failed with an authentication timeout. The
  failed attempt dropped the existing link for about 10 s, and it happened every
  30-36 min. The Pi's driver can't monitor signal strength, and the two APs look
  nearly identical to it (64 vs 63). There is no failover if `kitchen-ap` goes down.
  Undo with `802-11-wireless.bssid ""`.
- `kiosk-watchdog`, a root systemd timer that runs every 60 s
  (files in this directory):
  - Network: a check fails if NM doesn't report `wlan0` connected or the gateway
    doesn't answer ping. A connected link is never torn down on one bad check.
    If NM is idle (disconnected), the watchdog nudges it with `nmcli connection up`.
    Every 3rd consecutive failure it bounces the Wi-Fi radio, and at 10 it reboots.
  - HA: it checks `https://home.internal.greyrock.io/manifest.json`. After an outage
    of 2+ consecutive checks (HA or network), it restarts `touchkio.service` once HA
    answers, so the page reloads cleanly. Single-check blips are left to HA's
    own frontend reconnect.
  - v1 (2026-10-13) ran `nmcli connection up` on a single failed ping and
    restarted TouchKio after every blip. That bounced a healthy link roughly every
    5 min and caused the "reconnecting" screens. v1 was replaced the same day.
  - Counters live in `/run/kiosk-watchdog` (tmpfs), so they reset on boot.
  - Logs: `journalctl -t kiosk-watchdog`.

The journal is intentionally kept in RAM only, to limit SD card writes. Watchdog logs
from before a reboot are therefore lost. The watchdog itself writes nothing to the card.

## Install / reinstall

```sh
scp kiosk-watchdog kiosk-watchdog.service kiosk-watchdog.timer guest-wifi-display.internal.greyrock.io:/tmp/
ssh guest-wifi-display.internal.greyrock.io '
  sudo install -m 755 /tmp/kiosk-watchdog /usr/local/bin/
  sudo install -m 644 /tmp/kiosk-watchdog.service /tmp/kiosk-watchdog.timer /etc/systemd/system/
  sudo systemctl daemon-reload && sudo systemctl enable --now kiosk-watchdog.timer'
```

## Remove

```sh
sudo systemctl disable --now kiosk-watchdog.timer
sudo rm /usr/local/bin/kiosk-watchdog /etc/systemd/system/kiosk-watchdog.{service,timer}
sudo systemctl daemon-reload
sudo nmcli connection modify "Grey Rock IoT" connection.autoconnect-retries -1
```
