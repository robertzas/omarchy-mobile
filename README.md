# Omandroid

Native Omarchy on Google Pixel phones: Arch Linux ARM, Hyprland and Omarchy's own packages running directly on the phone with a mainline kernel, and Android apps in Waydroid. First device: Pixel 7 Pro (cheetah, gs201). What works on each phone: [docs/DEVICES.md](docs/DEVICES.md).

Plan: https://claude.ai/code/artifact/060038bc-beff-497e-9643-4f322318b2be

## Layout

| Path | What it is |
| --- | --- |
| `bin/omandroid` | Native Omarchy tooling: `capture`, `kernel`, `kernel-shell` |
| `packages/` | pacman packages: `omandroid-shell` (the phone profile for Omarchy's shell), `omandroid-device-cheetah` (Pixel 7 Pro support), patched `mesa`. `tools/phone-install-package` builds one on the phone and installs it |
| `patches/omarchy/` | Changes to Omarchy for touch devices, to send upstream (`bridge-*` ones are stopgaps for the phone's older Omarchy) |
| `bin/lineage-ref` | Builds LineageOS for the phone. Used as a rooted reference Android (M0) and, later, for Waydroid images |
| `kernel/configs/` | Our kernel config fragment, merged on top of arm64 `defconfig` |
| `device/cheetah/` | Pixel 7 Pro bring-up notes and device trees |
| `omandroid.conf` | Shared settings (source dir, jobs, container image). Override in `omandroid.local.conf` |
| `docker/` | Ubuntu 24.04 build environment |
| `docs/DEVICES.md` | Supported-devices matrix |

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

Bringing up another Pixel, fixing a driver or improving the phone shell: start with [CONTRIBUTING.md](CONTRIBUTING.md). It covers the safety model (stock Android stays on slot A, the read-only storage guard, backups, dead-man switches), the build and flash loop, a step-by-step guide to bringing up a new device, and how to submit kernel and package changes. AI coding agents should also read [AGENTS.md](AGENTS.md). The status of each device is in [docs/DEVICES.md](docs/DEVICES.md).
