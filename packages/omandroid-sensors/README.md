<!-- SPDX-License-Identifier: MIT -->
# omandroid-sensors

The Pixel 7 Pro's sensors (accelerometer, light, proximity, compass) belong
to the AoC, the audio and sensor DSP, and reach Linux through its sensor
framework (USF) on `/dev/acd-com.google.usf`. This package turns them into
iio-sensor-proxy's D-Bus API, and rotates Hyprland with the phone.

| File | What |
|---|---|
| `omandroid-sensor-proxy` (system service, not enabled) | `net.hadess.SensorProxy` on the system bus: `HasAccelerometer`, `AccelerometerOrientation`, `AccelerometerTilt`, light (lux), proximity, compass; a sensor samples only while a client holds a claim. Loads the AoC's sensor registry once per AoC boot from `/usr/share/omandroid/sensors/registry` (Google's files from the phone's vendor partition, never shipped) and the factory calibration from `persist` (read-only, with debugfs) |
| `omandroid-autorotate` (user service, not enabled) | claims the accelerometer and sets the monitor's and the touchscreen's transform through `hyprctl` (normal 0, left-up 1, bottom-up 2, right-up 3); `~/.local/state/omandroid/rotation-lock` locks it |
| `omandroid-usf` | the USF client, for bring-up: sensor list, registry load, sampling |

It provides and conflicts with `iio-sensor-proxy`, whose daemon would take
the same bus name. `monitor-sensor` (from iio-sensor-proxy's source) works
against it.

Needs the AoC running (`omandroid-aoc.service` in omandroid-device-cheetah).
Bring-up: `device/cheetah/AOC-PLAN.md`, stage C6.
