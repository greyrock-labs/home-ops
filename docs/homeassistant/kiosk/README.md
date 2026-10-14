# Wall Display (dining-room-kiosk)

Surface Pro 4 running Windows 11, showing the Home Assistant dashboard full-screen in
Edge.

- Host: `dining-room-kiosk.internal.greyrock.io` (10.1.10.8, static lease)
- Network: Wi-Fi `Grey Rock`, random hardware addresses off so the lease holds
- Accounts, both local:
  - `todd`: administrator, for maintenance
  - `kiosk`: standard user, the one that auto-signs in. A standard user limits what anyone
    who gets out of the browser can do.
  - The `kiosk` password is in 1Password.
- Loads `https://home.internal.greyrock.io`

## How it starts

- **Auto sign-in:** Sysinternals Autologon, run as `todd` for the `kiosk` account. It
  stores the password as an LSA secret, not in the registry in plain text.
- **Browser:** a shortcut in `kiosk`'s Startup folder (`shell:startup`):

  ```
  "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --app=https://home.internal.greyrock.io --start-fullscreen --no-first-run
  ```

  `--app` uses `kiosk`'s normal Edge profile, so the Home Assistant login ("Keep me logged
  in") survives reboots.

## Gotchas

- **Edge Startup boost must be off** (`edge://settings/system`, along with "Continue
  running background extensions and apps when Microsoft Edge is closed"). With it on, Edge
  is already running when the shortcut fires, the URL is handed to that process, and
  `--start-fullscreen` is ignored.
- **The Windows "Set up a kiosk" wizard (Assigned Access) is not used.** Its Edge kiosk
  modes browse InPrivate and clear data on exit, so the Home Assistant login would not
  persist without HA `trusted_networks`, which is not wanted.
