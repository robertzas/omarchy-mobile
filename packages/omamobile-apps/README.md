# omamobile-apps

A meta package: the apps a phone needs that desktop Omarchy doesn't ship.
`omamobile-shell` depends on it, so every Omarchy Mobile install gets them.

| App | Package | Status |
| --- | --- | --- |
| Maps and location | `gnome-maps`, `geoclue` | default: the GPS reaches GeoClue through `omamobile-gnss` |
| NFC tags | `neard` | default: tapping a tag with a web link opens it (`omamobile-nfc-open` in `omamobile-shell`) |
| Camera | `snapshot`, `pipewire-libcamera` | installed: all four cameras through libcamera and PipeWire (CAMERA-PLAN CAM5.4; needs omamobile-device-cheetah 0.1.31) |
| Phone calls | `gnome-calls` | optional until the modem works (MODEM-PLAN M4) and Calls can talk to its RIL |
| Messages | `chatty` | optional, as Calls |

An app moves from `optdepends` to `depends` when the hardware behind it
works on the reference device.
