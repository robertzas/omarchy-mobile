<!-- SPDX-License-Identifier: MIT -->
# omamobile-sensors

The Pixel 7 Pro's sensors (accelerometer, light, proximity, compass) belong
to the AoC, the audio and sensor DSP, and reach Linux through its sensor
framework (USF) on `/dev/acd-com.google.usf`. This package turns them into
iio-sensor-proxy's D-Bus API, and rotates Hyprland with the phone.

| File | What |
|---|---|
| `omamobile-sensor-proxy` (system service, enabled at boot after `omamobile-aoc.service`) | `net.hadess.SensorProxy` on the system bus: `HasAccelerometer`, `AccelerometerOrientation`, `AccelerometerTilt`, light (lux), proximity, compass; a sensor samples only while a client holds a claim. Loads the AoC's sensor registry once per AoC boot from `/usr/share/omamobile/sensors/registry` (Google's files from the phone's vendor partition, never shipped) and the factory calibration from `persist` (read-only, with debugfs) |
| `omamobile-autorotate` (user service, turned on from the rotation lock tile) | claims the accelerometer and sets the monitor's and the touchscreen's transform through `hyprctl` (normal 0, left-up 1, bottom-up 2, right-up 3); `~/.local/state/omamobile/rotation-lock` locks it |
| `omamobile-usf` | the USF client, for bring-up: sensor list, registry load, sampling |

It provides and conflicts with `iio-sensor-proxy`, whose daemon would take
the same bus name. `monitor-sensor` (from iio-sensor-proxy's source) works
against it.

Needs the AoC running (`omamobile-aoc.service` in omamobile-device-cheetah).
Bring-up: `device/cheetah/AOC-PLAN.md`, stage C6.
