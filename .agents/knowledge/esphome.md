# ESPHome device configs

ESPHome YAML lives in the `todd/esphome-config` Forgejo repo
(`git@git.greyrock.io:todd/esphome-config.git`). The working copy is the clone at
`/config/esphome` on Home Assistant, which the ESPHome Device Builder app builds and
flashes from. There is no local clone on the Mac; edit on HA, not in a separate checkout.

- Reach it through the Advanced SSH & Web Terminal app: `ssh hassio@home.internal.greyrock.io`.
  The app's user is `hassio`, not `root`.
- `/config/esphome` is owned by root, so use `sudo` (e.g. `sudo git -C /config/esphome ...`).
  `cd` into it fails without sudo.
- Git on HA authenticates with root's `/root/.ssh/id_ed25519`, registered as a deploy key on
  `todd/esphome-config`.
- Nothing pulls the clone automatically. After pushing from elsewhere (e.g. Renovate
  merges), run `git pull --ff-only` there before flashing.
- `secrets.yaml` exists only on HA and is not tracked.
- The Device Builder manages the clone (`device-builder.managed=true`) and auto-commits
  any change to a top-level device YAML, one "Edit <file>" commit per file, without
  pushing. Shared packages in subdirectories are left unstaged. Check `git log` before
  committing, and squash those auto-commits into a real commit before pushing.
- Git on HA can push: the deploy key has write access.
- OTA uploads are encrypted with each device's API key (`encryption:` on the shared `ota:`
  in `esphome-common/api.yaml`); there are no OTA passwords. Plaintext uploads are refused,
  so losing a device's API key means a USB flash. The garage RATGDOs take OTA from the
  upstream ratgdo package and are not covered by this.
- Validate with `esphome config` (version pinned in `pyproject.toml`) against a copy of
  the tree and placeholder secrets. The SSH app's protection mode blocks Docker, so the
  Device Builder's own CLI is not reachable from SSH.
- Hardware swap ordered 2026-10-16, configs not yet written:
  - BT proxies: XIAO ESP32-C3 → XIAO ESP32-C5 (5 GHz, uses its own dual-band U.FL
    antenna). Needs a new `seeed-xiao-esp32-c5/` base; `bt-proxy-*.yaml` keep their
    names and keys.
  - HVAC: D1 Mini (ESP8266) → XIAO ESP32-C6 with pre-soldered headers, 2.4 GHz. CN105 is
    5 V UART, so each unit gets a BSS138 level shifter, assembled with Dupont plugs only
    (no soldering). Needs a C6 `hvac-cn105` base with new UART pins (check Seeed's C6
    pinout; D6/D7 expected). Consider ESPHome's native `mitsubishi_cn105` vs echavet.
- The weather ePaper display is `office-weather-display.yaml`. Its sensors are
  `platform: homeassistant` entities, so a removed or renamed HA entity shows as `?` on
  the display until its YAML is updated and reflashed.
