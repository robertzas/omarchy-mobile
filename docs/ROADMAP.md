<!-- SPDX-License-Identifier: MIT -->
# Road map

Where Omandroid stands, what a good everyday phone still needs, and the order we plan to get there. Last updated 2026-10-13, from the subsystem plans in [`device/cheetah/`](../device/cheetah) and [NOTES.md](../device/cheetah/NOTES.md). The reference device is the Pixel 7 Pro (`cheetah`, gs201); other Pixels are in [DEVICES.md](DEVICES.md).

**In one paragraph:** the Pixel 7 Pro boots mainline Linux and Omarchy from slot B and works as a pocket computer: 120 Hz display with brightness and real screen-off, GPU acceleration, touch, Wi-Fi (now across s2idle), Bluetooth audio, battery level, haptics, torch, sensors with auto-rotate, GPS with an outdoor fix, NFC tags (read, write, tap to open a link), fingerprint unlock with a PIN or password, the ultrawide camera through libcamera, and the built-in speakers and microphones (working, but quiet and thin next to stock). It is **not yet a phone**: there are no calls, SMS or mobile data, and it doesn't sleep by itself when the screen is off. The modem is the long pole: its first boot is being debugged (M3.4), and calls come weeks to months after registration. On the software side the phone still needs its own home screen, more quick settings, notifications that matter, Android apps and over-the-air updates.

Effort figures below are quoted from the plans, which assume one developer writing code and the human running each gated step on the phone. They are estimates, not promises: every stage so far has turned up at least one surprise.

## 1. Where things stand

Statuses: **works** (on by default, verified on the phone), **partial** (works, with a known gap), **in progress** (some gates passed on the phone, or code built and waiting for its runbook), **not started**.

| Subsystem | Status | Why | Plan |
| --- | --- | --- | --- |
| Boot, storage, USB networking | works | Slot B with stock kept on slot A, the read-only storage guard, Arch on `userdata`; USB reconnects after a replug through `omandroid-usb-rescue` until the Type-C driver lands | [BRINGUP-M1](../device/cheetah/BRINGUP-M1.md), [USB-C-PLAN](../device/cheetah/USB-C-PLAN.md) |
| Display | works | Our flip-only KMS driver at 120 Hz, brightness, DPMS, the panel really off with the screen | [DISPLAY-PLAN](../device/cheetah/DISPLAY-PLAN.md) |
| GPU | works | Mali-G710 on Panthor and patched Mesa, DVFS through ACPM | [GPU-PLAN](../device/cheetah/GPU-PLAN.md), [ACPM-PLAN](../device/cheetah/ACPM-PLAN.md) |
| Touch, buttons | works | Our Synaptics TouchComm driver; `gpio-keys` | [NOTES](../device/cheetah/NOTES.md) |
| Wi-Fi | works | brcmfmac behind a restricted DMA pool. The D3 handshake keeps it up across s2idle (S5b-3 passed); the long soak (S5c) is next | [WIFI-BATTERY-PLAN](../device/cheetah/WIFI-BATTERY-PLAN.md), [SUSPEND-PLAN](../device/cheetah/SUSPEND-PLAN.md) S5 |
| Bluetooth | works | Pairing and A2DP audio; headset calls (HFP) need the chip's SCO routing changed, not yet done | [BLUETOOTH-PLAN](../device/cheetah/BLUETOOTH-PLAN.md), [AUDIO-PLAN](../device/cheetah/AUDIO-PLAN.md) |
| Battery | works | MAX77759 fuel gauge with the stock battery model | [WIFI-BATTERY-PLAN](../device/cheetah/WIFI-BATTERY-PLAN.md) |
| Charging | partial | Works by hand; off by default until the temperature guard (B3g) is in. Type-C (B4) not yet run | [USB-C-PLAN](../device/cheetah/USB-C-PLAN.md) |
| Haptics, torch | works | CS40L26 through feedbackd; LM3644 with a quick-settings tile | [HAPTICS-TORCH-PLAN](../device/cheetah/HAPTICS-TORCH-PLAN.md) |
| AoC (audio and sensor DSP) | works | Starts at boot through the GSA and Trusty | [AOC-PLAN](../device/cheetah/AOC-PLAN.md) |
| Sensors | works | Accelerometer, light, proximity and compass at every boot; auto-rotate | [AOC-PLAN](../device/cheetah/AOC-PLAN.md) C6, [USF-PROTOCOL](../device/cheetah/USF-PROTOCOL.md) |
| Speakers, microphones | partial | Both speakers in stereo under Google's speaker protection, mics at stock gain. The everyday level (stage `media`, 737/10) is about 17 dB below stock and sounds thin; stock's 817/17 still trips the coil temperature (C9d-3..6). Next: a measured speaker filter (C9g), the V/I feedback and impedance work (C9d-7/8), and stock's Waves processing on the AoC (T3b/T4) | [AOC-PLAN](../device/cheetah/AOC-PLAN.md) C8-C10, [AOC-TUNING-RESEARCH](../device/cheetah/AOC-TUNING-RESEARCH.md) |
| CPU idle, power | partial | C2 idle on all cores is in the default DTB; battery-drain numbers off the cable not yet measured | [POWER-PLAN](../device/cheetah/POWER-PLAN.md) |
| Suspend | in progress | s2idle freezes and wakes cleanly (S1-S4), now with Wi-Fi up across sleep (S5b-3). Not on by default: the S5c soak, AoC and sensors across sleep (S6), battery numbers (S7) and the screen-off policy (S8) first. Deep sleep (SYS_SLEEP), which stock's standby drain needs, not started | [SUSPEND-PLAN](../device/cheetah/SUSPEND-PLAN.md) |
| GNSS | works | Google's GNSS stack in a chroot behind GeoClue, on demand from the Location tile; first outdoor fix (G4b), GNOME Maps through GeoClue (G5-2) | [GNSS-PLAN](../device/cheetah/GNSS-PLAN.md) |
| NFC | works | ST54J through st-nci with our plain-NCI link, loaded at boot; neard reads and writes tags, and a tag with a web link opens it. Card emulation and payments are out of scope | [RADIOS-CAMERA-PLAN](../device/cheetah/RADIOS-CAMERA-PLAN.md) §3 |
| Fingerprint | works | Google's HAL and Trusty TA on mainline (F3-F9), fprintd and our libfprint driver; the lock screen unlocks with a finger, PIN or password is the user's choice, enrollment from the shell (F10-F18) | [FINGERPRINT-PLAN](../device/cheetah/FINGERPRINT-PLAN.md) |
| Modem | in progress | The PCIe link, the S5300 on the bus and Google's modem interface driver (CPIF) work without firmware (M2.5-M3.3-B). The modem boots Google's firmware from RAM copies of its NV to ONLINE and stays up (M3.4.5b, M3.4.6, 2026-10-13); the AP-CP IPC handshake isn't complete yet, so the first control message (M4.1) waits. The client stack (`omandroid-modem`, `omandroid-modem-sit`) is packaged. Each modem power-off triggers one recovered UFS error-handler pass, so the stack keeps the modem on once it is up | [MODEM-PLAN](../device/cheetah/MODEM-PLAN.md), [MODEM-SIT-RESEARCH](../device/cheetah/MODEM-SIT-RESEARCH.md), [MODEM-CLIENT](../device/cheetah/MODEM-CLIENT.md) |
| Cameras | partial | The ultrawide (Sony IMX386, CSIS link 2) works end to end through libcamera's simple pipeline and software ISP (CAM5). The main camera (Samsung S5KGN1, C-PHY) is built and waits for its runbook (CAM-M); image quality (CAM5.3), Snapshot (CAM5.4), the front camera (CAM7) and the telephoto follow | [CAMERA-PLAN](../device/cheetah/CAMERA-PLAN.md) |
| Phone shell | partial | Status bar, swipeable home screens with apps and widgets and an edit mode, quick settings with 19 tiles and a tile editor, launcher, switcher, the lock screen with PIN pad and fingerprint, squeekboard on demand. User-built widgets (made with Omarchy's default agent) in progress; desktop-shaped system dialogs | [`packages/omandroid-shell`](../packages/omandroid-shell), [NOTES](../device/cheetah/NOTES.md) "Phone UX to-dos" |
| Android apps (Waydroid) | in progress | Planned and packaged offline: the kernel options are found and checked, `omandroid-waydroid` is drafted with the container kept away from debugfs, the camera nodes and every block device. Nothing run on the phone yet | [WAYDROID-PLAN](../device/cheetah/WAYDROID-PLAN.md) |
| Installer | not started | Putting Arch onto `userdata` is done by hand today ([CONTRIBUTING](../CONTRIBUTING.md) §4); designed with the release bundles (3.8) | [RELEASES](RELEASES.md) |
| Updates | partial | Packages ship through a signed `[omandroid]` pacman repository and `omarchy update`, but the repository is copied to the phone over USB (`tools/repo-push`), not yet hosted; kernel updates go through `bin/omandroid push` | [CONTRIBUTING](../CONTRIBUTING.md) §4 |
| Upstream kernel | in progress | Ready commits are prepared as `omandroid-next` for the published kernel, not yet pushed | [KERNEL-PUBLISH](../device/cheetah/KERNEL-PUBLISH.md) |

## 2. What an everyday phone still needs

In priority order: the first four make it a phone, the rest make it a good one.

| Need | Today | What's missing |
| --- | --- | --- |
| **Calls** | no | The modem chain (M3.4 first CP boot, M4 registration), a front end (oFono or ModemManager), IMS (VoLTE: most networks have no 2G/3G left), the AoC voice path and an earpiece mode under the speaker protection. Then a dialer: GNOME Calls is already an optional app |
| **SMS** | no | M4 (`omandroid-sitd`), the front end, then Chatty (optional app today) |
| **Mobile data** | no | M4's data call (`rmnet`), the front end, then suspend with the modem online (M6) |
| **Standby and battery life** | unmeasured | s2idle on screen-off (S5c-S8), then measured drain (S7, `power-ab`). s2idle alone won't reach Android's standby (the plan quotes about 274-286 mA in s2idle against 32-50 mA in deep sleep): deep sleep (SYS_SLEEP) is the real fix |
| **A phone home screen** | pages, apps, built-in widgets | Touch testing, folders, user-built widgets (in progress) |
| **Notifications** | desktop-style | Phone-shaped banners, a shade with actions, heads-up on the lock screen, do-not-disturb; incoming calls and SMS once the modem works |
| **Quick settings** | 19 tiles, editable | On-phone checks of airplane, hotspot and mobile data; mobile data needs the modem's M4 |
| **Loud, full speakers** | about 17 dB below stock, thin | C9g filter, then stock gains with verified protection (C9), or Waves on the AoC (T3b-T6) |
| **Cameras** | ultrawide only, through `cam` | Main camera (CAM-M), quality (CAM5.3), Snapshot as the camera app (CAM5.4), front (CAM7), telephoto |
| **Updates over the air** | over USB | Host the `[omandroid]` repository so `omarchy update` reaches it on Wi-Fi; a phone-friendly update notice; kernel updates as a package instead of `bin/omandroid push` |
| **Apps: store and updates** | pacman in a terminal | A touch app store front end (GNOME Software or a small one of ours over pacman and Flathub), updates included |
| **Android apps** | no | Waydroid ([WAYDROID-PLAN](../device/cheetah/WAYDROID-PLAN.md), W0-W8) |
| **Safe charging by default** | by hand | The temperature guard (B3g), then Type-C (B4) for USB that survives a replug without the rescue service |
| **Accessibility** | none phone-specific | Font and display scaling from settings, the screen reader (Orca) with touch exploration, high contrast, larger touch targets in our plugins |
| **System dialogs, first run** | desktop-shaped | Keyring, polkit and portal dialogs, the screensaver, Omarchy's first run ([NOTES](../device/cheetah/NOTES.md), "Phone UX to-dos") |
| **Installer** | no | A scripted, safe install to `userdata` and slot B for people who aren't developers |

## 3. The plan

Tracks in rough priority order. Most are independent and run in parallel; the arrows inside a track are hard dependencies. "Next" is the next concrete step, usually a gated runbook already written in the plan.

### 3.1 Telephony: modem, data, SMS, calls

The highest-value track and the longest. [MODEM-PLAN](../device/cheetah/MODEM-PLAN.md), [MODEM-CLIENT](../device/cheetah/MODEM-CLIENT.md):

```
M2.5, M3.1, M3.3-B, M3.4.0-3 (passed) ─> M3.4.4-5 firmware boot, CP ONLINE ─> M3.6 SysMMU
                                                         │
                                                         └─> M4 SIT client: registration, SMS, data ─> oFono / ModemManager ─> Calls, Chatty
                                                                    │
                                                                    └─> M5 IMS (VoLTE) ─> calls with audio ◄─ AoC voice path + earpiece mode
                                                                    └─> M6 boot integration, suspend with the modem online
```

| Milestone | Effort (from the plans) | Next concrete step |
| --- | --- | --- |
| M3.4: Google's boot loader for the modem in the RAM-only NV chroot, firmware over PCIe, CP ONLINE | Done 2026-10-13: ONLINE, 10 min clean, NV unchanged | The main link trains at Gen1 x2, not Gen3 x2 (open) |
| M3.6: the HSI1 SysMMU confines the modem's DMA | 1 week | Offline, after M3.4 |
| M4: SIT client to registration, a data call and SMS | 3-6 weeks; `omandroid-sitd` is written and passes against a simulator | M4.1 (read-only) reached the CP but CPIF's IPC init handshake (INIT_END) never completes: the CPIF fix first, then M4.1 again; M4.2 needs a SIM |
| Front end | oFono driver about 2-3 weeks, ModemManager plugin 2-4 weeks | MODEM-CLIENT §3 leans to oFono; decide once `omandroid-sitd` has run on the phone |
| Calls and messages UI | days once the front end works, for GNOME Calls and Chatty (already optional in `omandroid-apps`); phone-shaped layout and lock-screen incoming-call UI on top | After the front end; the incoming-call screen belongs to the shell (3.5) |
| M5: IMS and calls with audio | weeks more; needs the AoC voice path and the earpiece design in AOC-PLAN | Design only today |
| M6: suspend with the modem online | after S8 and M4 | Design only |

The modem's NV is never written from Linux: the chroot works on checksum-verified RAM copies.

### 3.2 Standby and battery

[SUSPEND-PLAN](../device/cheetah/SUSPEND-PLAN.md), [POWER-PLAN](../device/cheetah/POWER-PLAN.md), [USB-C-PLAN](../device/cheetah/USB-C-PLAN.md):

1. **S5c** (Wi-Fi across sleep, soaked), **S6** (AoC and sensors across sleep), **S7** (battery numbers), **S8** (screen-off sleep on by default; the sleep hook is already in `omandroid-device-cheetah`). Next: S5c.
2. **Measure drain** off the cable: POWER-PLAN's B0 baseline and `power-ab c2`.
3. **Deep sleep (SYS_SLEEP)**: the gs201 SoC sleep sequence through the PMU and ACPM, as stock does. Researched in SUSPEND-PLAN §5, no estimate yet. This is what gets standby near Android's, and the single biggest battery item.
4. **Safe charging by default**: the temperature guard (B3g), then Type-C with role switching (B4a, B4b). Next: the B3g runbook.
5. **Power UX**: battery saver (CPU and refresh-rate caps, Wi-Fi power save), a short power-key press that sleeps, wake on the fingerprint sensor if the hardware allows it.

### 3.3 Speakers and audio

[AOC-PLAN](../device/cheetah/AOC-PLAN.md) C9-C10, [AUDIO-PLAN](../device/cheetah/AUDIO-PLAN.md):

1. **C9g**: `omandroid-audio` 0.4.0's speaker filter, measured with the phone's own microphone and checked by ear. Lowest risk, fixes "thin" first.
2. **C9d-7/C9d-8**: the V/I feedback stream stock runs and the firmware's own impedance reading, for the runaway at analog gain 17; then stock's gains as the default (C9e, C9f).
3. **Waves on the AoC** ([AOC-TUNING-RESEARCH](../device/cheetah/AOC-TUNING-RESEARCH.md)): T3b (one exchange during a tone), then T4-T6.
4. **Bluetooth HFP**: route the BCM4389's SCO over HCI (AUDIO-PLAN A1).
5. **Earpiece and call audio**: designed in AOC-PLAN; built with the modem's M5.

### 3.4 Cameras

[CAMERA-PLAN](../device/cheetah/CAMERA-PLAN.md): the ultrawide works through libcamera's simple pipeline and software ISP (CAM5). Next: the CAM-M runbook (the main camera's S5KGN1 on C-PHY, with focus through the AK7375 actuator), then quality (CAM5.3: tuning, autofocus, exposure), Snapshot as the default camera app (CAM5.4, moving `snapshot` from optional to default in `omandroid-apps`), the front camera (CAM7, 1-2 weeks) and the telephoto. Video and QR scanning come with Snapshot.

### 3.5 Shell and UX

The phone's own software, all offline-heavy and parallel to the hardware tracks. Omarchy changes go upstream first ([`patches/omarchy/`](../patches/omarchy)); the running list is "Phone UX to-dos" in [NOTES.md](../device/cheetah/NOTES.md).

1. **Home screen** (`omandroid-shell` 0.1.42): swipeable pages of apps and widgets (clock, weather, battery, media, calendar, note, toggles, command) with an edit mode. Next: user-built widgets made with Omarchy's default agent, folders, and touch testing.
2. **Quick settings** (`omandroid-shell` 0.1.42): a collapsed and an expanded sheet, 19 tiles, an editor to add, remove and reorder them; long-press opens the full setting.
3. **Notifications**: phone-shaped banners and shade with actions and inline reply, grouping per app, lock-screen privacy, do-not-disturb with exceptions; the incoming-call screen (full screen over the lock) for 3.1.
4. **Settings for a phone**: display (scale, font size, refresh rate), sound (volume steps per stream, ringtone), battery, mobile network and SIM, about phone; mostly front ends to what Omarchy already has.
5. **Accessibility**: scaling and font size first, then Orca with touch exploration, high contrast, and a pass over our plugins' touch targets and labels.
6. **System dialogs, screensaver, first run**: keyring, polkit and portal dialogs sized and styled for the phone; a portrait screensaver; Omarchy's whole user install at first boot, with phone-specific first-run steps (Wi-Fi, PIN, fingerprint).

### 3.6 Android apps (Waydroid)

[WAYDROID-PLAN](../device/cheetah/WAYDROID-PLAN.md): LineageOS (Android 13) in Waydroid's LXC container, each Android app in its own Hyprland window from our launcher, GLES on the Mali-G710, sound through PipeWire, networking behind ufw.

- **Kernel (W1):** binder, binderfs, PSI, memfd, cgroups and the container network were already on; Android's netd needs legacy iptables and ip6tables with its xt matches and targets, and policy routing (`IP_MULTIPLE_TABLES`, `IPV6_MULTIPLE_TABLES`, `INET_DIAG_DESTROY`). The block is in `kernel/configs/omandroid.config`, verified against `omandroid-int`'s configuration. No new driver code.
- **GPU:** the image's Mesa has no G710 row; `omandroid-waydroid` patches a copy into Waydroid's vendor overlay until the row is upstream.
- **Safety:** Waydroid's container is privileged and binds debugfs and the camera nodes; the package removes those binds and denies every block device, so Android can never reach the UFS or undo the storage guard.
- **Next:** W0 (read-only check on the current kernel), then W1-W5 on the phone; W6-W8 make Android apps behave like phone apps (back gesture, keyboard, notifications, power).

### 3.7 Distribution: updates, app store, installer, upstream

- **OTA: host the `[omandroid]` repository** publicly, so `omarchy update` updates the phone on Wi-Fi (signing and the keyring package already exist). Then an update notice in the shell, and the kernel and its modules as a package with a safe slot-B install path, so `bin/omandroid push` becomes a developer tool.
- **App store**: a touch front end for installing and updating apps (pacman packages, Flathub, web apps), probably GNOME Software with a phone-shaped layout or a small plugin of ours; updates and the OTA notice in one place.
- **An installer** that sets up slot B and `userdata` with the safety model built in ([CONTRIBUTING](../CONTRIBUTING.md) §3). Not started.
- **Publish the kernel**: review, test and push `omandroid-next` ([KERNEL-PUBLISH](../device/cheetah/KERNEL-PUBLISH.md)), then send ready series upstream, with the Mesa G710 row and the Omarchy patches.

The kernel package, the update path for slot B and the installer are designed together in 3.8.

### 3.8 Multi-device builds and releases

[RELEASES.md](RELEASES.md): one kernel `Image` and module set for every Pixel with each board's DTB beside it, a descriptor per device (`device/<codename>/device.conf`), the kernel as a package, slot B written by a pacman hook instead of `bin/omandroid push`, and per-device bundles with a one-command installer that only touches slot B and `userdata`. Google's firmware stays extracted on the user's side. In order:

1. **Device descriptor and `DEVICE=`** (done 2026-10-13): `device/cheetah/device.conf`; `bin/omandroid` reads the DTB, `soc_id`s, dtbo, boot image values and storage-guard allowlist from it, and checks the allowlist against the initramfs. Cheetah's images came out byte-identical.
2. **Shared initramfs**: one `init` with the per-device quirks (the guard list, cheetah's display trigger write, the USB name) generated from the descriptor, release builds without developer keys or bring-up probes, packed reproducibly; `bin/omandroid overlay` replaces the hand-written `ov` helper. Changes what boots: its own runbook and a test boot on cheetah.
3. **Kernel package**: `linux-omandroid` (`Image`, modules, every DTB) from a tagged `omandroid-int` snapshot, release `LOCALVERSION`, in `[omandroid]`; `omandroid-device` as the virtual package the device packages provide.
4. **Device package hook**: `omandroid-boot-update` in `omandroid-device-cheetah` builds the images on the phone and writes slot B through the same guarded, verified path as `push`, keeps the previous set for rollback, never reboots, and is opt-in so development phones keep `bin/omandroid push`. Firmware maps move from the extraction scripts into per-device files.
5. **Release bundles and the installer**: per-device slot-B images, a shared Arch root image, signed checksums, and an `install` script that checks the phone and the factory image, adds the user's own firmware and SSH key to a local copy of the root image, and flashes only `<image>_b` and `userdata`. Replaces the "Installer: not started" row in §1.
6. **CI**: lint and package tests on every push; kernel, DTB validation and twice-built images per device on kernel tags; unsigned bundles on release. Pinned container and toolchain, so the maintainer can rebuild and compare before signing.
7. **Second device bring-up as the proof**: a second Pixel (a gs201 sibling first, or a gs101 phone to test the smaller boot image set) built, packaged and installed by the same tools with nothing but its descriptor, DTS, firmware map and device package added.

Alongside every release, **keep linux-omandroid's branches honest**: publish `omandroid-int` as a tagged snapshot for builders, and run a curation pass that moves what has passed on the phone into the upstream-ready `omandroid` branch (the `omandroid-next` process) and publishes it, so the gap between the two shrinks release by release.

## 4. How to help

- **Start with [CONTRIBUTING.md](../CONTRIBUTING.md).** It has the safety model, the build and flash loop and how to submit changes. AI coding agents also read [AGENTS.md](../AGENTS.md).
- **Pick a plan.** Each subsystem's plan in [`device/cheetah/`](../device/cheetah) has a status line, the evidence, and a gated runbook with the next step. Offline work (drivers, reviews, checkpatch and `dt-validate` runs, packaging, shell UX, accessibility) needs no phone.
- **Bring up another Pixel.** [DEVICES.md](DEVICES.md) lists the devices we'd like and their closest starting point; CONTRIBUTING §5 is the bring-up guide. Most gs201 phones need mainly a board DTS.
- **Upstream review.** Kernel series from `omandroid-next` and the Mesa and Omarchy patches benefit from review by people who know those subsystems.
