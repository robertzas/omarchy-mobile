<!-- SPDX-License-Identifier: MIT -->
# Supported devices

The status of each phone, as verified on real hardware. What's still missing and the order we plan to tackle it: [ROADMAP.md](ROADMAP.md). To add a device or update a cell, follow [CONTRIBUTING.md](../CONTRIBUTING.md) §6.4: only claim what you've run on your own phone, and link the notes entry that shows it.

**Legend:**

- **works**: verified on the phone, on by default;
- **testing**: works by hand, not yet on by default;
- **partial**: works on by default, with a known gap that the notes name;
- **WIP**: bring-up in progress, some gates passed;
- **built**: driver and DT written and built, not yet run on the phone;
- **boots**: the block's firmware runs, but nothing user-facing uses it yet;
- **no**: not started, or blocked;
- **-**: the hardware doesn't exist on this device.

## Matrix

| Device | Codename | SoC | Boot | Storage | Display | GPU | Touch | Buttons | USB net | Wi-Fi | Bluetooth | Battery | Charging | Haptics | Torch | GNSS | AoC | Speakers/mics | Sensors | Modem | NFC | Cameras | Suspend | Fingerprint |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Pixel 7 Pro | cheetah | gs201 (Tensor G2) | works | works | works (120 Hz) | works (DVFS) | works | works | works | works | works (audio) | works | testing | works | works | works | works | works (quieter than stock) | works | WIP | works | WIP (ultrawide works) | WIP | WIP |
| *Template* | *codename* | *SoC* | | | | | | | | | | | | | | | | | | | | | | |

## cheetah (Pixel 7 Pro) in detail

| Subsystem | Status | Notes | Plan |
| --- | --- | --- | --- |
| Boot | works | Mainline on slot B, stock Android kept on slot A; the boot-success marker sets the slot's flags in `devinfo` | [BRINGUP-M1](../device/cheetah/BRINGUP-M1.md) |
| Storage | works | UFS, behind the read-only partition guard; the Arch root on `userdata` | [NOTES](../device/cheetah/NOTES.md) |
| Display | works | Our flip-only KMS driver (gs-decon) on DECON0 → DSIM0 → S6E3HC4, 120 Hz by default, brightness, DPMS; the panel sleeps when the screen is off | [DISPLAY-PLAN](../device/cheetah/DISPLAY-PLAN.md) |
| GPU | works | Mali-G710 on Panthor, with Mesa patched for G710; frequency scaling through ACPM | [GPU-PLAN](../device/cheetah/GPU-PLAN.md), [ACPM-PLAN](../device/cheetah/ACPM-PLAN.md) |
| Touch | works | Synaptics S3908 over SPI, our TouchComm driver | [NOTES](../device/cheetah/NOTES.md) |
| Buttons | works | Power and volume through `gpio-keys` | [NOTES](../device/cheetah/NOTES.md) |
| USB networking | works | CDC NCM gadget plus an ACM console; reconnects after a replug (`omamobile-usb-rescue`) until the Type-C driver lands | [USB-C-PLAN](../device/cheetah/USB-C-PLAN.md) |
| Wi-Fi | works | BCM4389 on PCIe through brcmfmac, behind a restricted DMA pool | [WIFI-BATTERY-PLAN](../device/cheetah/WIFI-BATTERY-PLAN.md) |
| Bluetooth | works | BCM4389 on the APM UART through hci_bcm; pairing, A2DP audio through PipeWire. Headset calls (HFP) need the chip's SCO routing changed first | [BLUETOOTH-PLAN](../device/cheetah/BLUETOOTH-PLAN.md) |
| Battery | works | MAX77759 fuel gauge with the stock battery model | [WIFI-BATTERY-PLAN](../device/cheetah/WIFI-BATTERY-PLAN.md) |
| Charging | testing | MAX77759 charger works by hand; waits for the temperature guard before it's on by default | [USB-C-PLAN](../device/cheetah/USB-C-PLAN.md) |
| Haptics | works | CS40L26A, through feedbackd | [HAPTICS-TORCH-PLAN](../device/cheetah/HAPTICS-TORCH-PLAN.md) |
| Torch | works | LM3644TT, quick-settings tile | [HAPTICS-TORCH-PLAN](../device/cheetah/HAPTICS-TORCH-PLAN.md) |
| GNSS | works | `omamobile-gnss`: Google's GNSS stack in a vendor chroot, started on demand through GeoClue, with a Location quick-settings tile. The chip streams NMEA; version 0.2.0 adds orbit assistance and time injection for a fast first fix (SUPL opt-in). First outdoor fix (G4b, 2026-10-13): four constellations in view, GPS and Galileo used, HDOP 0.4, fixes within about 4 m. GNOME Maps (in `omamobile-apps`) reads GeoClue; its outdoor check with the GPS is still to do | [GNSS-PLAN](../device/cheetah/GNSS-PLAN.md) |
| AoC | works | The audio and sensor DSP starts at boot (`omamobile-aoc.service`) through the GSA and Trusty, with 82 services; sensors and the sound card use it | [AOC-PLAN](../device/cheetah/AOC-PLAN.md) |
| Speakers/mics | works (quieter than stock) | Through the AoC sound card and PipeWire (`omamobile-audio`): "Built-in Audio Speaker" (both speakers in stereo, stock channel map) and "Built-in Audio Microphone", the volume keys and quick settings. The amplifiers run Google's speaker protection firmware with the phone's factory calibration, are kept out of runtime hibernate, and a watchdog mutes them on any fault; playback survives pauses. Version 0.3.0 plays at stage `media` (digital 737, analog 10), inside the no-protection limits and about 17 dB below stock; stock's gains wait until the protection is verified at them (C9), and stock's loudness also needs the AoC's Waves processing: `omamobile-speaker-tuning` (off by default) sends it, and the AoC answers (T3.2), but no tuning has been applied during playback yet | [AOC-PLAN](../device/cheetah/AOC-PLAN.md) C7-C9, [AOC-TUNING-RESEARCH](../device/cheetah/AOC-TUNING-RESEARCH.md), [AUDIO-PLAN](../device/cheetah/AUDIO-PLAN.md) |
| Sensors | works | `omamobile-sensors`: an iio-sensor-proxy D-Bus service from the AoC's USF, started at boot. Accelerometer, light, proximity and compass at every boot (the sensor rails are power-cycled before the AoC starts); auto-rotate, switched from the rotation lock tile | [AOC-PLAN](../device/cheetah/AOC-PLAN.md) C6, [USF-PROTOCOL](../device/cheetah/USF-PROTOCOL.md) |
| Modem | WIP | S5300 on PCIe: the link comes up at stock timing, the modem enumerates on the bus, and Google's modem interface driver (CPIF, blacklisted at boot) binds with the modem unpowered (M2.5-M3.3-B); the RAM-only NV chroot for cbd and rfsd is packaged, and a SIT client daemon (`omamobile-modem-sit`) is built and tested against a simulator; no firmware has been sent. Each modem power-off causes one recovered UFS error-handler pass, so the modem now stays on once it is up. Registration is about two to three months away, calls later | [MODEM-PLAN](../device/cheetah/MODEM-PLAN.md), [MODEM-CLIENT](../device/cheetah/MODEM-CLIENT.md) |
| NFC | works | ST54J over I2C through st-nci with our plain-NCI link, loaded at boot; neard (patched for empty Type 4 tags) reads and writes tags, and tapping a tag with a web link opens it (`omamobile-nfc-open`). Card emulation and the secure element are not used | [RADIOS-CAMERA-PLAN](../device/cheetah/RADIOS-CAMERA-PLAN.md) |
| Cameras | WIP | The ultrawide (Sony IMX386, CSIS link 2, D-PHY) works end to end: raw frames through our CSIS/WDMA driver into libcamera's software ISP, pictures in `cam` (CAM5), quality "decent webcam" (no Google ISP or tuning). The main (Samsung S5KGN1, C-PHY link 1), front (S5K3J1, D-PHY link 0) and 5x telephoto (S5KGM5, C-PHY link 4, SEM1215SA focus) cameras are built and wait for their phone runbooks (CAM-M, CAM7, CAM-T). Sensor settings and DC-PHY settings are generated from the user's own camera software (`tools/extract-camera-data`), never shipped. All blacklisted by default | [CAMERA-PLAN](../device/cheetah/CAMERA-PLAN.md) |
| Suspend | WIP | `pm_test` dry runs pass, and s2idle freezes sleep and wake with Wi-Fi unloaded: on a key, and 20 of 20 unattended RTC-alarm cycles with the AoC and sensors running (S3b, S4); UFS defaults to `spm_lvl` 5. Wi-Fi now stays up across a freeze (the D3 handshake fixed, S5b-3); not on by default until the S5c soak and battery numbers (S5c-S8). Deep sleep (SYS_SLEEP) not started | [SUSPEND-PLAN](../device/cheetah/SUSPEND-PLAN.md) |
| Fingerprint | WIP | Trusty runs at every boot (the AoC starts through it), the fingerprint kernel passed its first boot (F1), the sensor's rail reads off at 3.3 V (FB2), and Trusty serves the fingerprint side read-only (F2). Google's HAL in a chroot behind a bridge (`omamobile-fingerprint`) and a libfprint driver for fprintd are built and tested offline; the sensor hasn't been powered, and the first secure-storage write waits for an explicit go | [FINGERPRINT-PLAN](../device/cheetah/FINGERPRINT-PLAN.md), [FINGERPRINT-RESEARCH](../device/cheetah/FINGERPRINT-RESEARCH.md) |

## Wanted

Devices we'd like to support, with the closest starting point. Open an issue to say you're working on one, so efforts don't overlap.

| Device | Codename | SoC | Starting point |
| --- | --- | --- | --- |
| Pixel 7 | panther | gs201 | cheetah's SoC support; needs its own board DTS (panel, touch, battery) |
| Pixel 7a | lynx | gs201 | as panther |
| Pixel Fold | felix | gs201 | as panther, with two panels |
| Pixel Tablet | tangorpro | gs201 | as panther; no modem |
| Pixel 6 | oriole | gs101 | **WIP, community port: [#2](https://github.com/derekross/omarchy-mobile/issues/2)**; our preferred second device. Upstream mainline `gs101-oriole.dts` |
| Pixel 6 Pro | raven | gs101 | upstream mainline `gs101-raven.dts`; shares oriole's port ([#2](https://github.com/derekross/omarchy-mobile/issues/2)) |
| Pixel 6a | bluejay | gs101 | upstream `gs101.dtsi`; a new board DTS; shares oriole's port ([#2](https://github.com/derekross/omarchy-mobile/issues/2)) |
| Pixel 8, 8 Pro, 8a | shiba, husky, akita | zuma (Tensor G3) | **8a (akita): hardware and help offered, [#1](https://github.com/derekross/omarchy-mobile/issues/1)**; a new SoC for us, a longer road than gs101 |
| Pixel 9 family | tokay, caiman, komodo, comet, tegu | zumapro (Tensor G4) | not started |
| Pixel 10 family | | laguna (Tensor G5) | not started |
