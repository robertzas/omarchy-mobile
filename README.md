# Omarchy Mobile

Native Omarchy on Google Pixel phones: Arch Linux ARM, Hyprland and Omarchy's own packages running directly on the phone with a mainline kernel, with Android apps in Waydroid as a later goal. First device: Pixel 7 Pro (cheetah, gs201).

**Status (2026-10-13):** a pocket computer, not yet a phone. Each item's detail and the notes behind it: [docs/DEVICES.md](docs/DEVICES.md); what's missing and the plan to get there: [docs/ROADMAP.md](docs/ROADMAP.md).

- **Works:** display at 120 Hz, GPU, touch, buttons, USB networking, Wi-Fi, Bluetooth audio, battery, haptics, torch, sensors with auto-rotate, GNSS (Location tile, GeoClue), NFC (reading and writing tags, opening a tag's link) and fingerprint unlock alongside the PIN pad or password (opt-in, because its first run writes Trusty's secure storage).
- **Partial:** the speakers and microphones work but sound quiet and thin, with occasional static; a new speaker filter is built and not yet tuned on the phone. Of the cameras, the ultrawide works through libcamera (basic quality, loaded by hand); the main camera streams but its image doesn't capture yet, the front camera is probed and the telephoto not started. Charging works by hand.
- **In progress:** the modem boots Google's firmware and answers our IPC (SIM and radio state), but registration, SMS, data and calls need a SIM test that hasn't happened yet. Sleep on screen-off: s2idle cycles pass with Wi-Fi unloaded, and the Wi-Fi fix for sleep is still being soaked.
- **New on 2026-10-13:** home screens with 47+ built-in widgets (ported from Simon Schubert's MIT-licensed omarchy-widgets) and your own widgets made with "Create with AI" through Omarchy's default agent, behind a crash guard; 19 quick-settings tiles with an editor; one app per screen, with a "Show with…" action; the phone's screen and input on a computer over USB (`omamobile-mirror`, `tools/phone-mirror`); a device descriptor (`device.conf`) for more than one phone; and a first installer (below), new and going through its first clean reinstall now.

Plan: https://claude.ai/code/artifact/060038bc-beff-497e-9643-4f322318b2be

## Quick start

The installer is new: expect rough edges. You need a Pixel 7 Pro with an unlocked bootloader, an Omarchy (Arch) laptop with Docker, `android-tools` and `e2fsprogs`, and Google's factory image for the phone. Stock Android stays on slot A as the way back; installing erases `userdata`.

```sh
tools/build-packages                 # Omarchy Mobile's packages for aarch64 (out/repo)
tools/build-rootfs                   # the root image: Arch Linux ARM, Omarchy, our packages
tools/install-phone --dry-run        # phone in fastboot: checks it, asks for your user, shows every command
tools/install-phone                  # writes only slot B's boot images and userdata
tools/phone-provision FACTORY.zip    # after the first boot: firmware from your own factory image
```

The kernel and boot images come from `bin/omamobile kernel`, `modules`, `initramfs` and `images` (CONTRIBUTING.md §4). Step by step, with what to expect at each point: [device/cheetah/REINSTALL-RUNBOOK.md](device/cheetah/REINSTALL-RUNBOOK.md).

## Layout

| Path | What it is |
| --- | --- |
| `bin/omamobile` | Build and flash tooling: `capture`, `kernel`, `modules`, `initramfs`, `images`, `flash`, `push`, `kexec`, `fastboot` |
| `tools/build-packages`, `tools/build-rootfs`, `tools/install-phone`, `tools/phone-provision`, `tools/make-bundle` | The installer: aarch64 packages and the root image built on the laptop, the narrow fastboot installer, per-phone provisioning, release bundles (`rootfs/` holds the image's package lists; `tests/` their tests) |
| `tools/` | Staged bring-up and capture tools, on-phone probes, firmware extraction from the user's factory image, package and repository helpers |
| `packages/` | pacman packages: `omamobile-shell` (the phone profile for Omarchy's shell), `omamobile-apps` (the mobile apps desktop Omarchy lacks: Maps, NFC), `omamobile-device-cheetah` (Pixel 7 Pro support), `omamobile-sensors` (sensors and auto-rotate through the AoC), `omamobile-gnss` (location on demand), `omamobile-mirror` (the phone's screen and input on a computer over USB, VNC), `omamobile-audio` (PipeWire and speaker protection), `omamobile-speaker-tuning` (stock's speaker tuning, off by default), `omamobile-fingerprint` with a patched `libfprint`, `omamobile-modem` (the modem's vendor chroot profile), `omamobile-modem-sit` (the SIT client daemon; talks to the modem, registration untested), `neard`, `omamobile-keyring` (the `[omamobile]` repository's signing key), patched `mesa` and `hyprland`. `tools/phone-install-package` builds one on the phone and installs it |
| `patches/omarchy/` | Changes to Omarchy for touch devices, to send upstream (`bridge-*` ones are stopgaps for the phone's older Omarchy); a link to `packages/omamobile-omarchy/patches`, whose pacman hook re-applies them after every Omarchy upgrade |
| `bin/lineage-ref` | Builds LineageOS for the phone. Used as a rooted reference Android (M0) and, later, for Waydroid images |
| `kernel/configs/` | Our kernel config fragment, merged on top of arm64 `defconfig` |
| `device/cheetah/` | Pixel 7 Pro bring-up notes, one plan per subsystem, overlays, the initramfs and the device descriptor (`device.conf`) |
| `omamobile.conf` | Shared settings (source dir, jobs, container image). Override in `omamobile.local.conf` |
| `docker/` | Ubuntu 24.04 build environment |
| `docs/DEVICES.md` | Supported-devices matrix |
| `docs/ROADMAP.md` | Where things stand and the plan to a working phone |
| `docs/RELEASES.md` | How builds and releases work for several devices: device descriptors, the kernel package, release bundles |

Large trees live outside the repo, under `~/android/`:

| Path | Contents |
| --- | --- |
| `~/android/omamobile` | LineageOS 24.0 source. Includes Google's GPL Pixel 7 kernel at `out-kernel/google/gs-6.1` |
| `~/android/mainline/linux` | Our kernel repo: branch `omamobile` on mainline v7.3-rc6 (remote `upstream` is Linus's tree), one commit per subsystem so patches can go upstream. Published to [derekross/linux-omarchy-mobile](https://github.com/derekross/linux-omarchy-mobile) by `tools/publish-kernel` (a squashed upstream base, our commits unchanged on top) |
| `~/android/mainline/pmos-tensor` | postmarketOS Tensor kernel, for reference |
| `~/android/reference` | Captures from the phone. Contains serial numbers and partition backups: never commit |
| `~/android/factory` | Verified stock factory images, used to restore the phone |

## Ground rules

- We only ever flash the boot images and userdata. Never `bootloader`, `radio`, `devinfo`, `persist` or calibration partitions.
- **Licensing:** this repository is MIT ([LICENSE](LICENSE)) except where a file's SPDX header says otherwise. Kernel patches (and the board dtbo source) are GPL-2.0. The port of Google's Apache-2.0 boot-control code keeps that licence and Google's notice (`packages/omamobile-device-cheetah/src/omamobile-bootctl.c`). Every file we write carries an SPDX header.
- Google's proprietary firmware and binaries are never committed: our scripts extract them from the user's own factory image.
- No code from unlicensed sources. Google's GPL kernel, upstream Linux, postmarketOS and Mesa are fine.

## Contributing

Bringing up another Pixel, fixing a driver or improving the phone shell: start with [CONTRIBUTING.md](CONTRIBUTING.md). It covers the safety model (stock Android stays on slot A, the read-only storage guard, backups, dead-man switches), the build and flash loop, a step-by-step guide to bringing up a new device, and how to submit kernel and package changes. AI coding agents should also read [AGENTS.md](AGENTS.md). The status of each device is in [docs/DEVICES.md](docs/DEVICES.md), and what's next in [docs/ROADMAP.md](docs/ROADMAP.md).
