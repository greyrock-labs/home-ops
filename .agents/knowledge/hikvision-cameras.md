# Hikvision cameras (Scrypted)

Setup checklist and findings for the Hikvision IP cameras that feed Scrypted. Recorded
2026-10-27 after auditing all three cameras.

## Inventory

| Host | Name (device + OSD) | Model | Lighting | Firmware |
|---|---|---|---|---|
| `garage-camera-todd.internal.greyrock.io` | Garage - Todd | DS-2CD2087G2H-LIU/SL | Hybrid (IR + white) | V5.7.17 build 240606 |
| `garage-camera-andy.internal.greyrock.io` | Garage - Andy | DS-2CD2087G2H-LIU/SL | Hybrid (IR + white) | V5.7.17 build 240606 |
| `side-yard-camera.internal.greyrock.io` | Side Yard | DS-2CD2386G2-ISU/SL | IR only | V5.7.19 build 241207 |

All three are fixed (non-PTZ) cameras. The web UI shows a PTZ panel on Live View anyway;
ignore it. The two garage cameras are separate devices, so "Garage - Andy" and
"Garage - Todd" are both correct names.

## Network and access

- The cameras sit on an isolated network with no internet access and limited reach into
  the internal network. Because of that, firmware is deliberately not upgraded unless a
  release adds functionality we need (decided 2026-10-27). V5.7.23 (260114) lists the
  2087G2H-LIU/SL (eF revision) but adds no features. Whether it fixes the July 2026 CVE
  batch (CVE-2026-57599/57600/61390/61391/61392, some unauthenticated) is unverified;
  Hikvision's advisory page did not load.
- Use the web UI over HTTPS. Plain HTTP leaves the page blank because its scripts fail
  to load. Do not call `/ISAPI/...` with `fetch()` from page JavaScript: the UI signs its
  own requests, so direct calls return 401 or hang.
- Chrome Safe Browsing shows a red "Dangerous site" page on `/doc/index.html` (the login
  page). It is a false positive, not a certificate problem. Click Details, then proceed.
  This is the user's call; agents must not bypass the warning themselves.
- If the UI jumps to Live View but config fields show "Select" with no values, wait a
  few seconds. If they stay empty, the session is not really signed in.
- Navigating directly to a `#/config/...` URL does not work; the UI redirects. Use the
  menus. On some page loads the first click on Configuration lands on VCA instead.

## Required settings (Scrypted)

Source: [Scrypted camera preparation](https://docs.scrypted.app/camera-preparation.html).

### Video (Configuration > Video/Audio > Video)

Check all three streams (Main, Sub, Third):

| Stream | Resolution | FPS | I-frame | Bitrate | Codec |
|---|---|---|---|---|---|
| Main | 3840×2160 | 20 | 80 | 8192 kbps VBR | H.264, H.264+ off |
| Sub | 640×360 | 20 | 80 | 512 kbps VBR | H.264 |
| Third | 1280×720 | 10 | 40 | 1024 kbps VBR | H.264 |

- I-frame interval = 4 × frame rate.
- Video Type must be "Video and Audio Stream" on every stream.
- SVC off.

### Audio (Configuration > Video/Audio > Audio)

- Encoding **G.711ulaw**. Scrypted recommends AAC only for Amcrest/Dahua; every other
  brand, Hikvision included, uses G.711 mu-law at 8000 Hz. AAC is offered but is not
  the right choice.

### OSD (Configuration > Image > OSD Settings)

- Channel Name, Display Date and Display Week on.
- Time Format **12-Hour**, date format MM-DD-YYYY.
- Also set System > System Settings > Basic Information > Device Name to the same name.
  New cameras arrive as "IP CAMERA" / "Camera 01".

### Time (Configuration > System > System Settings > Time Settings)

- Time zone (GMT-05:00) Eastern Time, NTP to `time1.internal.greyrock.io`, port 123,
  interval 1440 min.
- DST enabled: start **Mar, Second, Sun, 02**; end **Nov, First, Sun, 02**; bias 60 min.
  Two cameras had been set to the *third* Sunday of March; check this on every camera.

### Motion (Configuration > Event > Event and Detection > Motion Detection)

- Enable on. Side Yard was found with motion detection off, so Scrypted got no events.
- Sensitivity **20** (Normal Mode). The number box is read-only; drag the slider.
- Linkage: **Notify Surveillance Center** on (Scrypted needs it).
- Zone currently covers the whole frame on all cameras. Tuning zones is still to do.

### VCA

- VCA resource **Monitoring** on; Smart Event and Face Capture off.

### Day/Night and lighting (Configuration > Image > Display Settings > Day/Night Switch)

- Day/Night Switch **Auto**, sensitivity 4, filtering time 5.
- Hybrid-light models: Smart Supplement Light on, Supplement Light Mode **Smart**,
  brightness Auto. Modes offered: Smart, White Supplement Light, IR Supplement Light, Off.
- IR-only models: Smart Supplement Light (Smart IR) **on**, mode IR Supplement Light.
  Side Yard had it off.
- Open question: with motion in Normal Mode and Smart Event off, it is unverified what
  triggers the white light in Smart mode.

### Integration

- There is no separate Integration Protocol / ISAPI toggle on this firmware. ISAPI works
  (Scrypted and the web UI use it).

### Browser live view (Configuration > Network > Network Service > WebSocket(s))

- Turn on **WebSockets** (secure, port 7682). Leave WebSocket (port 7681) on.
- Without it, Live View and every preview pane stay grey with "Opening the live view
  failed": an HTTPS page cannot use the unencrypted WebSocket on 7681. Port 7682 serves
  the same `*.internal.greyrock.io` certificate as HTTPS. Scrypted uses RTSP and does
  not depend on this.

## Repo wiring for a new camera

1. Certificate: add the host and a `password_env` to
   `kubernetes/apps/network/camera-cert-updater-hikvision/app/config/cameras.json`, add
   the matching `externalSecrets` entry in its `helmrelease.yaml` (1Password item
   `Cert Updater`, property = short host name), and store the camera's admin password
   in that 1Password item. The camera serves only the leaf certificate, without the
   intermediate; `push-certs.py` accounts for that.
2. Monitoring: add the host to the `devices` (ICMP) probe and the `https://` URL to the
   `tls-certs` probe in `kubernetes/apps/observability/blackbox-exporter/app/probes.yaml`.
3. Check the settings above in the web UI after Scrypted has adopted the camera.
