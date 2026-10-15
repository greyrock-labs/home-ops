# Lighting

Motion lighting is split between two pieces:

- **Sensor Light blueprint** (`Blackshome/sensor-light.yaml`) turns lights on and off from
  occupancy, with per-room delays and night-light timing.
- **Adaptive Lighting** (HACS, `basnijholt/adaptive-lighting`) owns brightness and colour
  temperature, following the sun all day.

The blueprint sends bare `light.turn_on` calls (transition only, no brightness or colour), and
Adaptive Lighting intercepts them and supplies both.

Snapshots of every automation below are in
[`ha-config/lighting-automations/`](ha-config/lighting-automations/).

## Adaptive Lighting entries

One entry per room, each listing that room's lights. All share these settings:

| Setting | Value | Why |
| --- | --- | --- |
| Colour range | 2000–6500 K | All bulbs are the same IKEA KAJPLATS family |
| Max brightness | 100% | |
| Sleep brightness / colour | 1% / 2200 K | Matches the old night lights; the lamp's warmest is 2202 K |
| `take_over_control_mode` | `pause_changed` | A brightness-only command (e.g. dim-before-off) pauses brightness only; colour keeps adapting |
| `autoreset_control_seconds` | 3600 | A paused light rejoins the curve after an hour |
| `skip_redundant_commands` | off | Re-sending every 90 s corrects any light that missed a command |
| `transition_until_sleep` | off | Colour stops at 2000 K at sunset instead of fading toward sleep |

Minimum brightness per room:

| Min | Rooms |
| --- | --- |
| 80% | Breezeway, Downstairs Hallway, Upstairs Hallway, Porch Hallway, Laundry |
| 60% | Office, Dining Room, Downstairs Bathroom, Kitchen, Living Room |
| 40% | Game Room |

With `brightness_mode: default`, brightness is `max_brightness` for the whole time the sun is up
and only falls after sunset, reaching `min_brightness` at solar midnight. Colour follows a
parabola from sunrise to solar noon to sunset, so it changes fastest near the horizon.

The Garage exterior lights are not on Adaptive Lighting. They run at night on a schedule, where
the curve would hold them at 2000 K; the blueprint sets them to 6500 K.

## Blueprint role

In every room automation:

- `include_dynamic_lighting: disable_dynamic_lighting`
- `include_light_colour_control: disable_colour_control`
- `include_light_control: [use_transition]` (no `use_brightness`)

Night lights stay enabled where a room used them, but without brightness or colour
(`include_night_light_control` has no `use_brightness`, night colour control disabled). They
are kept because they carry the shorter turn-off delay during sleep (`night_time_delay`, 1–5
minutes against the normal 2–15). The leftover `dynamic_lighting_*` inputs are unused.

The Office keeps dim-before-off (50% for 30 s before turning off).

## Sleep mode

Each Adaptive Lighting entry has a sleep switch,
`switch.adaptive_lighting_<room>_sleep_mode`. They mirror the conditions the rooms' night
lights use:

| Rooms | Condition | Driven by |
| --- | --- | --- |
| Office, Game Room | `input_boolean.sleep` on | Sleep - On (Actions) / Sleep - Off (Actions) |
| Dining Room, Downstairs Bathroom, Downstairs Hallway, Kitchen, Laundry, Living Room, Porch Hallway | sleep on **and** 21:00–07:00 | Adaptive Lighting - Sleep Mode (21:00-07:00 rooms) |
| Breezeway, Upstairs Hallway | none (no night lights) | — |

Sleep is usually still on after 07:00 (it is turned off around 09:00), so the window rooms
need the time condition or they would sit at 1% until then.

The sleep automations set the Adaptive Lighting switches before touching
`switch.plug_master_bedroom_fan`. A command to an unreachable Matter plug can block for a
minute and then error, which would otherwise stop the lighting step from running.

## Gotchas

- **Manual-control flag after config changes.** Commands the blueprint sent before a change mark
  lights as manually controlled, and Adaptive Lighting leaves them alone until they turn off
  or the autoreset fires. Clear it with
  `adaptive_lighting.set_manual_control` (`entity_id: switch.adaptive_lighting_<room>`,
  `manual_control: false`).
- **Interval updates are one `light.turn_on` per light every 90 s** while the light is on.
- **Re-adding a plug can change its entity ID.** `switch.plug_master_bedroom_fan` came back as
  `switch.master_bedroom_plug_master_bedroom_fan` and had to be renamed for the sleep
  automations.
