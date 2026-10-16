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
- The weather ePaper display is `office-weather-display.yaml`. Its sensors are
  `platform: homeassistant` entities, so a removed or renamed HA entity shows as `?` on
  the display until its YAML is updated and reflashed.
