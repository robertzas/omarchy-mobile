<!-- SPDX-License-Identifier: MIT -->
# Supported devices

The status of each phone, as verified on real hardware. To add a device or update a cell, follow [CONTRIBUTING.md](../CONTRIBUTING.md) §6.4: only claim what you've run on your own phone, and link the notes entry that shows it.

**Legend:**

- **works**: verified on the phone, on by default;
- **testing**: works by hand, not yet on by default;
- **WIP**: bring-up in progress, some gates passed;
- **boots**: the block's firmware runs, but nothing user-facing uses it yet;
- **no**: not started, or blocked;
- **-**: the hardware doesn't exist on this device.

## Matrix

| Device | Codename | SoC | Boot | Storage | Display | GPU | Touch | Buttons | USB net | Wi-Fi | Bluetooth | Battery | Charging | Haptics | Torch | GNSS | AoC | Speakers/mics | Sensors | Modem | Cameras | Suspend | Fingerprint |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Pixel 7 Pro | cheetah | gs201 (Tensor G2) | works | works | works (120 Hz) | works (DVFS) | works | works | works | works | works (audio) | works | testing | works | works | WIP | boots | no | WIP | no | no | no | WIP |
| *Template* | *codename* | *SoC* | | | | | | | | | | | | | | | | | | | | | |

## cheetah (Pixel 7 Pro) in detail

| Subsystem | Status | Notes | Plan |
| --- | --- | --- | --- |
| Boot | works | Mainline on slot B, stock Android kept on slot A; the boot-success marker sets the slot's flags in `devinfo` | [BRINGUP-M1](../device/cheetah/BRINGUP-M1.md) |
| Storage | works | UFS, behind the read-only partition guard; the Arch root on `userdata` | [NOTES](../device/cheetah/NOTES.md) |
| Display | works | Our flip-only KMS driver (gs-decon) on DECON0 → DSIM0 → S6E3HC4, 120 Hz by default, brightness, DPMS | [DISPLAY-PLAN](../device/cheetah/DISPLAY-PLAN.md) |
| GPU | works | Mali-G710 on Panthor, with Mesa patched for G710; frequency scaling through ACPM | [GPU-PLAN](../device/cheetah/GPU-PLAN.md), [ACPM-PLAN](../device/cheetah/ACPM-PLAN.md) |
| Touch | works | Synaptics S3908 over SPI, our TouchComm driver | [NOTES](../device/cheetah/NOTES.md) |
| Buttons | works | Power and volume through `gpio-keys` | [NOTES](../device/cheetah/NOTES.md) |
| USB networking | works | CDC NCM gadget plus an ACM console; reconnects after a replug (`omandroid-usb-rescue`) until the Type-C driver lands | [USB-C-PLAN](../device/cheetah/USB-C-PLAN.md) |
| Wi-Fi | works | BCM4389 on PCIe through brcmfmac, behind a restricted DMA pool | [WIFI-BATTERY-PLAN](../device/cheetah/WIFI-BATTERY-PLAN.md) |
| Bluetooth | works | BCM4389 on the APM UART through hci_bcm; pairing, A2DP audio through PipeWire | [BLUETOOTH-PLAN](../device/cheetah/BLUETOOTH-PLAN.md) |
| Battery | works | MAX77759 fuel gauge with the stock battery model | [WIFI-BATTERY-PLAN](../device/cheetah/WIFI-BATTERY-PLAN.md) |
| Charging | testing | MAX77759 charger works by hand; waits for the temperature guard before it's on by default | [USB-C-PLAN](../device/cheetah/USB-C-PLAN.md) |
| Haptics | works | CS40L26A, through feedbackd | [HAPTICS-TORCH-PLAN](../device/cheetah/HAPTICS-TORCH-PLAN.md) |
| Torch | works | LM3644TT, quick-settings tile | [HAPTICS-TORCH-PLAN](../device/cheetah/HAPTICS-TORCH-PLAN.md) |
| GNSS | WIP | Google's GNSS stack in a vendor chroot; the chip streams NMEA, no outdoor fix verified yet | [GNSS-PLAN](../device/cheetah/GNSS-PLAN.md) |
| AoC | boots | The audio and sensor DSP starts through the GSA and Trusty (82 services); no kernel clients yet | [AOC-PLAN](../device/cheetah/AOC-PLAN.md) |
| Speakers/mics | no | CS35L41 amplifiers and the AoC audio path not brought up | [AUDIO-PLAN](../device/cheetah/AUDIO-PLAN.md) |
| Sensors | WIP | Accelerometer, light, proximity and compass through the AoC's USF; `omandroid-sensors` written | [USF-PROTOCOL](../device/cheetah/USF-PROTOCOL.md) |
| Modem | no | S5300 on PCIe; link bring-up built, not run | [MODEM-PLAN](../device/cheetah/MODEM-PLAN.md) |
| Cameras | no | Surveyed only | [RADIOS-CAMERA-PLAN](../device/cheetah/RADIOS-CAMERA-PLAN.md) |
| Suspend | no | s2idle research and read-only checks done | [SUSPEND-PLAN](../device/cheetah/SUSPEND-PLAN.md) |
| Fingerprint | WIP | Trusty runs from Linux; Google's HAL in a chroot, sensor and RPMB stages pending | [FINGERPRINT-RESEARCH](../device/cheetah/FINGERPRINT-RESEARCH.md) |

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
