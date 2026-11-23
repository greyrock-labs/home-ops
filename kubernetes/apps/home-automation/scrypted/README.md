# Scrypted NVR

Scrypted NVR records the cameras on kerfuffle and runs as a **cluster server**. Object
detection and video decoding run on a **Mac mini cluster worker** (CoreML), not on the
kerfuffle GPU. AI event summaries come from Gemini.

## Layout

| Piece                 | Where                                                                            |
| --------------------- | -------------------------------------------------------------------------------- |
| Cluster server        | This HelmRelease, on kerfuffle (recordings, camera ingest, UI)                   |
| Detection worker      | Mac mini, Scrypted desktop app, worker name `mac-mini`                           |
| Recordings            | Two 24 TB drives on kerfuffle (Talos user volumes `nvr-0`, `nvr-1`)              |
| Object detection      | CoreML plugin, runs on the Mac (Apple Neural Engine)                             |
| AI summaries          | Scrypted NVR → AI Summary, Gemini (`gemini-3.1-flash-lite-preview`)              |
| Gemini usage          | `observability/stackdriver-exporter`, Grafana dashboard `gemini-scrypted`        |

## Names and addresses

| Name / address                     | What it is                                                                 |
| ---------------------------------- | -------------------------------------------------------------------------- |
| `scrypted.greyrock.io`             | Internal web UI (`envoy-internal` route). Use this in a browser at home.   |
| `nvr.greyrock.io`                  | The Scrypted Cloud plugin's Cloudflare tunnel (custom domain).             |
| `grey-rock-nvr`                    | Container hostname: the server name on the login screen.                   |
| 10.1.10.2 (`multus-internal`)      | Server's internal-VLAN address and its **cluster address**.                |
| 10.1.60.3 (`multus-video`)         | Server's camera-VLAN address.                                              |
| 10.1.10.16 `mac-mini`              | Mac mini, office-c08zp `1/1/1` (2.5G, VLAN 10 untagged).                   |
| 10.1.20.22 `kvm-mac-mini`          | Mac mini's JetKVM, office-c08pf `2/1/3` (VLAN 20 untagged).                |

**Never put `nvr.greyrock.io` on an internal route.** external-dns-mikrotik would then
answer it on the LAN with `ingress-int`, and the Cloud plugin's tunnel health check
(`https://nvr.greyrock.io/_punch/cloudflared_callback`) reaches the internal gateway
instead of the tunnel. It gets 404, fails 3/3, and the plugin restarts its tunnel every
few minutes. When a name moves, flush the router (`/ip dns cache flush`), restart
`ctrld-b` then `ctrld`, and roll CoreDNS; otherwise the old answer lives for its 1 h TTL.

The signed-in Scrypted app sends its control traffic (login, events, stream setup) through
the tunnel; it shows in the server log as `127.0.0.1`. Live video is WebRTC and goes direct
on the home network (`Connection is local network: true`), so it does not use the cable
upload.

## Cameras

All on VLAN 60 (garage-c08pf, see `docs/network/switch-baseline.md`).

| Camera                   | Model                              | Address    |
| ------------------------ | ---------------------------------- | ---------- |
| Courtyard Porch Doorbell | Reolink Video Doorbell PoE         | 10.1.60.12 |
| Side Yard                | Hikvision DS-2CD2386G2-ISU/SL (4K) | 10.1.60.13 |
| Garage Andy              | Hikvision DS-2CD2087G2H-LIU/SL     | 10.1.60.16 |
| Garage Todd              | Hikvision DS-2CD2087G2H-LIU/SL     | 10.1.60.17 |

Hikvision settings set on the cameras themselves (via ISAPI or the camera UI):

- Motion detection enabled, sensitivity 60, full-frame grid.
- White balance **AWB1** on all three. Side Yard had a long-standing purple cast on
  Natural Light that survived resets; AWB1 fixed it.
- Garage cameras: supplement light mode Smart (IR, white light on events).
- Smart Supplement Light on. It is not `supplementLightMode` in ISAPI and is not in the
  image capabilities; set it in the camera UI.

ISAPI notes: user `admin`, passwords in 1Password (Kubernetes vault, one item per camera,
the same ones `camera-cert-updater-hikvision` uses). Use digest auth against the hostname
(`*.internal.greyrock.io`) the way `push-certs.py` does; `curl --digest` against the IP
returned 401 with valid credentials.

## Cluster mode

### Server (this HelmRelease)

- `SCRYPTED_CLUSTER_MODE=server`, `SCRYPTED_CLUSTER_LABELS=storage`,
  `SCRYPTED_CLUSTER_ADDRESS=10.1.10.2`.
- `SCRYPTED_CLUSTER_SECRET` from 1Password `scrypted` → `cluster-secret` (Kubernetes vault)
  via `externalsecret.yaml`.
- Workers connect to port **10556**. Scrypted requires server and workers on the same
  network with no NAT or firewall between them, which is why the Mac is on VLAN 10 with
  the server's internal address. 10.1.10.2 has a router reservation (`Scrypted (Internal)`)
  for the pod's fixed MAC.
- No GPU claim. See [Why not the GPU](#why-not-the-gpu).

### Mac mini worker

1. Install the Scrypted desktop app (required for Scrypted NVR on a Mac) and sign in with
   the Scrypted account. On first run choose **Server Mode** and **Skip** the NVR storage
   directory. Server Mode plus the `.env` below is what makes it join as a worker; Viewer
   Mode only shows cameras.
2. Write `~/.scrypted/volume/.env` (the secret comes straight from 1Password):

   ```sh
   mkdir -p ~/.scrypted/volume
   printf 'SCRYPTED_CLUSTER_MODE=client\nSCRYPTED_CLUSTER_SERVER=10.1.10.2\nSCRYPTED_CLUSTER_SECRET=%s\nSCRYPTED_CLUSTER_LABELS=compute,transcode,@scrypted/coreml\nSCRYPTED_CLUSTER_WORKER_NAME=mac-mini\n' "$(op read op://Kubernetes/scrypted/cluster-secret)" > ~/.scrypted/volume/.env
   ```

3. Restart the app. The server logs `Cluster client authenticated. ::ffff:10.1.10.16`
   with labels `compute, transcode, @scrypted/coreml, arm64, darwin`, and **Plugins →
   Cluster Processes → Workers** lists `mac-mini`.
4. Install **CoreML Object Detection** (`@scrypted/coreml`) from Plugins on the server; it
   is forked to the Mac automatically. Do not install OpenVINO: with no worker labelled
   `@scrypted/openvino` it fails to start and every camera's analysis times out.
5. So the worker survives reboots: FileVault off, **Users & Groups → Automatically log in
   as**, and the Scrypted app in **Login Items**. The app only runs in a logged-in session.

`op` on macOS 27 needs **Privacy & Security → Files & Folders → Terminal → "Data shared by
1Password"** turned on, or it reports "No accounts configured" even with the app
integration enabled.

While the Mac is offline, detection is off (cameras log `no worker found for cluster labels
{"require":["compute"]}`); recording continues on kerfuffle.

## Why not the GPU

Until 2026-11-23 detection ran on kerfuffle's Intel Arc A380 with OpenVINO. Twice that day
the detector hung the GPU (`i915 ... GPU HANG: ecode 12:10:f1de2ffd, in python3`), each
time within two seconds of Side Yard starting analysis of its 3840×2160 stream. After a
hang the process's GPU context is reset and every camera's detection fails with
`[GPU] clFinish, error code: -5` until Scrypted restarts. Plex and Jellyfin were idle.

Enabling Resizable BAR (BIOS: Above 4G Decoding on, Re-Size BAR Support Auto, CSM
disabled; BAR now 8 GiB instead of 256 MiB) did not stop it, so detection moved to the Mac.
The BIOS settings stay; the BMC's web BIOS page and Redfish did not save them, they had to
be set in the console (KVM) BIOS.

## Gemini

- Scrypted NVR → Settings → **AI Summary**: AI Provider Cloud, Cloud LLM Provider Gemini,
  model `gemini-3.1-flash-lite-preview`. The API key is stored only in that setting.
- It summarizes events after they end (about two minutes later, several images per event)
  and writes notification titles; it does not describe each detection. Instant "Person
  Detected" notifications do not involve Gemini.
- Google Cloud project `scrypted` (`gen-lang-client-0278640389`). A $5/month budget on the
  billing account emails at 50/90/100%.
- Usage: Grafana → Gemini → **Gemini API (Scrypted)**. Google reports request counts only,
  no tokens; cost comes from the budget email. See `observability/stackdriver-exporter`
  for the metric caveats (`exported_service` label; aggregated deltas need
  `max_over_time(x[w]) - x offset w`, not `increase()`).

## Checks

```sh
# Worker joined, and which labels it has
kubectl -n home-automation logs deploy/scrypted --since=10m | grep -A10 'Cluster client authenticated'

# Detection results and errors
kubectl -n home-automation logs deploy/scrypted --since=30m | grep -E 'Detected \(moving\)|ended with error|no worker found'

# Cloud plugin tunnel health (every 2 minutes)
kubectl -n home-automation logs deploy/scrypted --since=10m | grep -A2 'Performing health check'
```
