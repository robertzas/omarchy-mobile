# omandroid-apps

A meta package: the apps a phone needs that desktop Omarchy doesn't ship.
`omandroid-shell` depends on it, so every Omandroid install gets them.

| App | Package | Status |
| --- | --- | --- |
| Maps and location | `gnome-maps`, `geoclue` | default: the GPS reaches GeoClue through `omandroid-gnss` |
| NFC tags | `neard` | default: tapping a tag with a web link opens it (`omandroid-nfc-open` in `omandroid-shell`) |
| Camera | `snapshot` | optional until the camera captures (CAMERA-PLAN CAM4) and libcamera supports it |
| Phone calls | `gnome-calls` | optional until the modem works (MODEM-PLAN M4) and Calls can talk to its RIL |
| Messages | `chatty` | optional, as Calls |

An app moves from `optdepends` to `depends` when the hardware behind it
works on the reference device.
