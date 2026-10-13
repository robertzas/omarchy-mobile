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
| Pixel 7 Pro | cheetah | gs201 (Tensor G2) | works | works | works (120 Hz) | works (DVFS) | works | works | works | works | works (audio) | works | testing | works | works | WIP | works | works (quieter than stock) | works | WIP | WIP | WIP | WIP | WIP |
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
| USB networking | works | CDC NCM gadget plus an ACM console; reconnects after a replug (`omandroid-usb-rescue`) until the Type-C driver lands | [USB-C-PLAN](../device/cheetah/USB-C-PLAN.md) |
| Wi-Fi | works | BCM4389 on PCIe through brcmfmac, behind a restricted DMA pool | [WIFI-BATTERY-PLAN](../device/cheetah/WIFI-BATTERY-PLAN.md) |
| Bluetooth | works | BCM4389 on the APM UART through hci_bcm; pairing, A2DP audio through PipeWire. Headset calls (HFP) need the chip's SCO routing changed first | [BLUETOOTH-PLAN](../device/cheetah/BLUETOOTH-PLAN.md) |
| Battery | works | MAX77759 fuel gauge with the stock battery model | [WIFI-BATTERY-PLAN](../device/cheetah/WIFI-BATTERY-PLAN.md) |
| Charging | testing | MAX77759 charger works by hand; waits for the temperature guard before it's on by default | [USB-C-PLAN](../device/cheetah/USB-C-PLAN.md) |
| Haptics | works | CS40L26A, through feedbackd | [HAPTICS-TORCH-PLAN](../device/cheetah/HAPTICS-TORCH-PLAN.md) |
| Torch | works | LM3644TT, quick-settings tile | [HAPTICS-TORCH-PLAN](../device/cheetah/HAPTICS-TORCH-PLAN.md) |
| GNSS | WIP | `omandroid-gnss`: Google's GNSS stack in a vendor chroot, started on demand through GeoClue, with a Location quick-settings tile. The chip streams NMEA; version 0.2.0 adds orbit assistance and time injection for a fast first fix (SUPL opt-in), checked indoors (G4b step 1). A fix still needs the outdoor test | [GNSS-PLAN](../device/cheetah/GNSS-PLAN.md) |
| AoC | works | The audio and sensor DSP starts at boot (`omandroid-aoc.service`) through the GSA and Trusty, with 82 services; sensors and the sound card use it | [AOC-PLAN](../device/cheetah/AOC-PLAN.md) |
| Speakers/mics | works (quieter than stock) | Through the AoC sound card and PipeWire (`omandroid-audio`): "Built-in Audio Speaker" (both speakers in stereo, stock channel map) and "Built-in Audio Microphone", the volume keys and quick settings. The amplifiers run Google's speaker protection firmware with the phone's factory calibration, are kept out of runtime hibernate, and a watchdog mutes them on any fault; playback survives pauses. Version 0.3.0 plays at stage `media` (digital 737, analog 10), inside the no-protection limits and about 17 dB below stock; stock's gains wait until the protection is verified at them (C9), and stock's loudness also needs the AoC's Waves processing (researched, not run) | [AOC-PLAN](../device/cheetah/AOC-PLAN.md) C7-C9, [AOC-TUNING-RESEARCH](../device/cheetah/AOC-TUNING-RESEARCH.md), [AUDIO-PLAN](../device/cheetah/AUDIO-PLAN.md) |
| Sensors | works | `omandroid-sensors`: an iio-sensor-proxy D-Bus service from the AoC's USF, started at boot. Accelerometer, light, proximity and compass at every boot (the sensor rails are power-cycled before the AoC starts); auto-rotate, switched from the rotation lock tile | [AOC-PLAN](../device/cheetah/AOC-PLAN.md) C6, [USF-PROTOCOL](../device/cheetah/USF-PROTOCOL.md) |
| Modem | WIP | S5300 on PCIe: the link comes up at stock timing and the modem enumerates on the bus (M2.5, M3.1). Google's modem interface driver (CPIF) is ported and builds as a module (blacklisted), the RAM-only NV chroot for cbd and rfsd is packaged, and a SIT client daemon (`omandroid-modem-sit`) is built and tested against a simulator; no firmware has been sent. Each modem power-off causes one recovered UFS error-handler pass. Registration is about two to three months away, calls later | [MODEM-PLAN](../device/cheetah/MODEM-PLAN.md), [MODEM-CLIENT](../device/cheetah/MODEM-CLIENT.md) |
| NFC | WIP | ST54J over I2C: with our plain-NCI link for st-nci (upstream framed it in NDLC), the chip powers up, polls and cycles power (N2.4b-N2.6). Reading a tag (N3) is next; the driver stays blacklisted until then. `neard` package; quick settings has an NFC tile (rfkill) | [RADIOS-CAMERA-PLAN](../device/cheetah/RADIOS-CAMERA-PLAN.md) |
| Cameras | WIP | The read-only CSIS probe passed (CAM1: the camera power domains are on, CSIS link 0 answers, DMA-BUF heaps present). The S2MPG13 GPIO and SLG51002 camera-PMIC drivers and the ultrawide's power path are built and blacklisted (CAM2-CAM3a). No frame yet | [CAMERA-PLAN](../device/cheetah/CAMERA-PLAN.md) |
| Suspend | WIP | `pm_test` dry runs pass, and s2idle freezes sleep and wake on a key with Wi-Fi unloaded; UFS now defaults to `spm_lvl` 5 (S3a). Not on by default: the RTC wake, more cycles, Wi-Fi's D3 messages and battery numbers first (S3b-S8). Deep sleep (SYS_SLEEP) not started | [SUSPEND-PLAN](../device/cheetah/SUSPEND-PLAN.md) |
| Fingerprint | WIP | Trusty runs at every boot (the AoC starts through it), the fingerprint kernel passed its first boot (F1), and the sensor's rail reads off at 3.3 V (FB2). Google's HAL in a chroot behind a bridge (`omandroid-fingerprint`) and a libfprint driver for fprintd are built and tested offline; the sensor hasn't been powered, and the first secure-storage write waits for an explicit go | [FINGERPRINT-PLAN](../device/cheetah/FINGERPRINT-PLAN.md), [FINGERPRINT-RESEARCH](../device/cheetah/FINGERPRINT-RESEARCH.md) |

## Wanted

Devices we'd like to support, with the closest starting point. Open an issue to say you're working on one, so efforts don't overlap.

| Device | Codename | SoC | Starting point |
| --- | --- | --- | --- |
| Pixel 7 | panther | gs201 | cheetah's SoC support; needs its own board DTS (panel, touch, battery) |
| Pixel 7a | lynx | gs201 | as panther |
| Pixel Fold | felix | gs201 | as panther, with two panels |
| Pixel Tablet | tangorpro | gs201 | as panther; no modem |
| Pixel 6 | oriole | gs101 | upstream mainline `gs101-oriole.dts` |
| Pixel 6 Pro | raven | gs101 | upstream mainline `gs101-raven.dts` |
| Pixel 6a | bluejay | gs101 | upstream `gs101.dtsi`; a new board DTS |
| Pixel 8, 8 Pro, 8a | shiba, husky, akita | zuma (Tensor G3) | not started |
| Pixel 9 family | tokay, caiman, komodo, comet, tegu | zumapro (Tensor G4) | not started |
| Pixel 10 family | | laguna (Tensor G5) | not started |
