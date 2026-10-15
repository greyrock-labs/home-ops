# Matter and Thread troubleshooting

## Layout

- **Controller:** the Matter Server app in Home Assistant (`core_matter_server`,
  matter-server 1.4.0 / matter.js 0.17.9, beta flag off). Home Assistant's fabric is
  `BD7CFFB333B4F194` (fabric 2, label "Grey Rock", vendor 0x134B). Node IDs show in its log
  as `@1:<hex>`.
- **Wi-Fi Matter:** the Kasa Smart Wi-Fi Plugs (firmware 1.3.0) on Grey Rock IoT, 2.4 GHz
  only. See [`docs/network/wifi-baseline.md`](../../docs/network/wifi-baseline.md).
- **Thread Matter:** IKEA KAJPLATS bulbs, Aqara FP300 presence sensors and the rest, through
  the HomePods and Apple TVs as border routers. Network `MyHome1909637572`, channel 25, PAN
  `0x84b7`, extended PAN `20a7369dc2e342c7`.
- Devices added through the Home Assistant iOS app are also on an **Apple Keychain** fabric
  (vendor 4996). That second fabric is a side effect of commissioning, not another controller.

## A Wi-Fi plug keeps going unavailable

1. **Ping it from the router** next to a plug on a different AP, so the control proves the
   test works:

   ```sh
   command ssh admin@10.1.0.1 ':foreach i in={10.1.10.168;10.1.10.59} do={:put $i; /ping $i count=20 interval=0.2}'
   ```

   Loss on plugs of one AP and not the others means that AP's 2.4 GHz radio is losing
   traffic. Check its channel and RF pollution with the Unleashed CLI
   (`show current-active-clients all`, `show performance ap-radio2-4 mac <ap mac>`).
2. **Check whether it dropped off Wi-Fi or only lost traffic:** search AP syslog for the MAC
   (lower case, regex) and its `assoc req from` lines. A plug can stay associated for days
   while losing most of its packets.
3. **Read the Matter Server log for the node** (`ha_get_logs source=supervisor
   slug=core_matter_server search=@1:<hex>`):

   | Log line | Meaning |
   | --- | --- |
   | `Connecting ... attempt #: N` with nothing after it | the handshake timed out |
   | `Peer error ... (Failure (1) / InvalidParam (2)) ... (Sigma3-Success)` | the plug answered but rejected the last handshake step |
   | `New session with @1:<hex>` / `is online` | connected |

   On a lossy link the same plug cycles through all three; the Sigma3 rejection comes from
   handshake messages arriving lost, late or out of order. Fix the radio first.
4. **If it pings cleanly but Matter still fails,** query its mDNS responder directly:

   ```sh
   dig @<plug ip> -p 5353 _matter._tcp.local PTR +short
   ```

   A working plug lists its fabrics. No answer means the plug's Matter stack is stuck: remove
   the device in Home Assistant, factory reset the plug, and add it again.

## Re-adding a device

- Home Assistant reuses the old device entry (same `device_id`, area, name) but the node ID
  increments and the main entity can come back with a different ID, e.g.
  `switch.master_bedroom_plug_master_bedroom_fan` instead of `switch.plug_master_bedroom_fan`.
  Rename it back before anything that references it runs.
- New nodes appear in mDNS as `BD7CFFB333B4F194-<16-hex node id>._matter._tcp`; watch with
  `dns-sd -B _matter._tcp local.`.

## Restarting the Matter Server

A restart forces a fresh handshake with every device. Thread devices return within about two minutes;
Wi-Fi plugs on a marginal radio can take 20 minutes or more, and a sleepy Thread device whose
address went stale stays offline until it wakes. Restart only when needed.

## Thread

- **iOS app: "Failed to save thread network credential ... does not match any of the active
  thread networks around"** before the QR scan. Home Assistant hands the phone its preferred
  dataset together with a preferred border router, and the phone rejects it when that border
  router no longer exists. Compare `preferred_extended_address` from the `thread/list_datasets`
  WebSocket command with the live `xa` values in the border routers' `_meshcop._udp` TXT
  records:

  ```sh
  dig -p 5353 @224.0.0.251 "Kitchen HomePod._meshcop._udp.local" TXT +short
  ```

  (`xa`, `xp` and `id` are binary; decode the `\ddd` escapes to hex.) Fix: **Settings → Devices
  & services → Thread**, pick a current border router as preferred. "Send credentials to Home
  Assistant" from the phone does not change it when the dataset is unchanged.
- **Rebooting the border routers can change the Thread network's routable prefix.** Sleepy
  battery devices (the FP300s) keep the old address and stay unavailable after the next
  Matter Server reconnect until woken (button press or battery reseat). Compare the device's
  address in `node_diagnostics` with the advertised route: `netstat -rn -f inet6 | grep ^fd`
  on a Mac on VLAN 10 shows the current one via a border router.
- `thread/get_dataset_tlv` returns the full dataset including the network key. Never print
  it.
