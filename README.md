# Omandroid

Native Omarchy on Google Pixel phones: Arch Linux ARM, Hyprland and Omarchy's own packages running directly on the phone with a mainline kernel, with Android apps in Waydroid as a later goal. First device: Pixel 7 Pro (cheetah, gs201).

**Status (2026-10-12):** a pocket computer, not yet a phone. Display at 120 Hz, GPU, touch, Wi-Fi, Bluetooth audio, battery, haptics, torch, sensors with auto-rotate and the speakers (quieter than stock for now) work. Calls, SMS, mobile data, cameras, fingerprint unlock and sleep on screen-off are in progress. What works on each phone: [docs/DEVICES.md](docs/DEVICES.md). What's missing and the plan to get there: [docs/ROADMAP.md](docs/ROADMAP.md).

Plan: https://claude.ai/code/artifact/060038bc-beff-497e-9643-4f322318b2be

## Layout

| Path | What it is |
| --- | --- |
| `bin/omandroid` | Build and flash tooling: `capture`, `kernel`, `modules`, `initramfs`, `images`, `flash`, `push`, `kexec`, `fastboot` |
| `tools/` | Staged bring-up and capture tools, on-phone probes, firmware extraction from the user's factory image, package and repository helpers |
| `packages/` | pacman packages: `omandroid-shell` (the phone profile for Omarchy's shell), `omandroid-apps` (the mobile apps desktop Omarchy lacks: Maps, NFC), `omandroid-device-cheetah` (Pixel 7 Pro support), `omandroid-sensors` (sensors and auto-rotate through the AoC), `omandroid-gnss` (location on demand), `omandroid-audio` (PipeWire and speaker protection), `omandroid-speaker-tuning` (stock's speaker tuning, off by default), `omandroid-fingerprint` with a patched `libfprint`, `omandroid-modem` (the modem's vendor chroot profile), `omandroid-modem-sit` (the SIT client daemon, not yet run on the phone), `neard`, `omandroid-keyring` (the `[omandroid]` repository's signing key), patched `mesa` and `hyprland`. `tools/phone-install-package` builds one on the phone and installs it |
| `patches/omarchy/` | Changes to Omarchy for touch devices, to send upstream (`bridge-*` ones are stopgaps for the phone's older Omarchy) |
| `bin/lineage-ref` | Builds LineageOS for the phone. Used as a rooted reference Android (M0) and, later, for Waydroid images |
| `kernel/configs/` | Our kernel config fragment, merged on top of arm64 `defconfig` |
| `device/cheetah/` | Pixel 7 Pro bring-up notes, one plan per subsystem, overlays and the initramfs |
| `omandroid.conf` | Shared settings (source dir, jobs, container image). Override in `omandroid.local.conf` |
| `docker/` | Ubuntu 24.04 build environment |
| `docs/DEVICES.md` | Supported-devices matrix |
| `docs/ROADMAP.md` | Where things stand and the plan to a working phone |

Large trees live outside the repo, under `~/android/`:

| Path | Contents |
| --- | --- |
| `~/android/omandroid` | LineageOS 24.0 source. Includes Google's GPL Pixel 7 kernel at `out-kernel/google/gs-6.1` |
| `~/android/mainline/linux` | Our kernel repo: branch `omandroid` on mainline v7.3-rc6 (remote `upstream` is Linus's tree), one commit per subsystem so patches can go upstream. Published to [derekross/linux-omandroid](https://github.com/derekross/linux-omandroid) by `tools/publish-kernel` (a squashed upstream base, our commits unchanged on top) |
| `~/android/mainline/pmos-tensor` | postmarketOS Tensor kernel, for reference |
| `~/android/reference` | Captures from the phone. Contains serial numbers and partition backups: never commit |
| `~/android/factory` | Verified stock factory images, used to restore the phone |

## Ground rules

- We only ever flash the boot images and userdata. Never `bootloader`, `radio`, `devinfo`, `persist` or calibration partitions.
- **Licensing:** this repository is MIT ([LICENSE](LICENSE)) except where a file's SPDX header says otherwise. Kernel patches (and the board dtbo source) are GPL-2.0. The port of Google's Apache-2.0 boot-control code keeps that licence and Google's notice (`packages/omandroid-device-cheetah/src/omandroid-bootctl.c`). Every file we write carries an SPDX header.
- Google's proprietary firmware and binaries are never committed: our scripts extract them from the user's own factory image.
- No code from unlicensed sources. Google's GPL kernel, upstream Linux, postmarketOS and Mesa are fine.

## Contributing

Bringing up another Pixel, fixing a driver or improving the phone shell: start with [CONTRIBUTING.md](CONTRIBUTING.md). It covers the safety model (stock Android stays on slot A, the read-only storage guard, backups, dead-man switches), the build and flash loop, a step-by-step guide to bringing up a new device, and how to submit kernel and package changes. AI coding agents should also read [AGENTS.md](AGENTS.md). The status of each device is in [docs/DEVICES.md](docs/DEVICES.md), and what's next in [docs/ROADMAP.md](docs/ROADMAP.md).
