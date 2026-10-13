<!-- SPDX-License-Identifier: MIT -->
# Road map

Where Omandroid stands, what a good everyday phone still needs, and the order we plan to get there. Last updated 2026-10-12, from the subsystem plans in [`device/cheetah/`](../device/cheetah) and [NOTES.md](../device/cheetah/NOTES.md). The reference device is the Pixel 7 Pro (`cheetah`, gs201); other Pixels are in [DEVICES.md](DEVICES.md).

**In one paragraph:** the Pixel 7 Pro boots mainline Linux and Omarchy from slot B and works as a pocket computer: 120 Hz display with brightness and real screen-off, GPU acceleration, touch, Wi-Fi, Bluetooth audio, battery level, haptics, torch, sensors with auto-rotate, and the built-in speakers and microphones (about 17 dB quieter than stock). It is **not yet a phone**: there are no calls, SMS or mobile data, no cameras, no fingerprint unlock, and it doesn't sleep when the screen is off. The modem is the long pole: realistically two to three months to network registration, with calls after that.

Effort figures below are quoted from the plans, which assume one developer writing code and the human running each gated step on the phone. They are estimates, not promises: every stage so far has turned up at least one surprise.

## 1. Where things stand

Statuses: **works** (on by default, verified on the phone), **partial** (works, with a known gap), **in progress** (some gates passed on the phone, or code built and waiting for its runbook), **not started**.

| Subsystem | Status | Why | Plan |
| --- | --- | --- | --- |
| Boot, storage, USB networking | works | Slot B with stock kept on slot A, the read-only storage guard, Arch on `userdata`; USB reconnects after a replug through `omandroid-usb-rescue` until the Type-C driver lands | [BRINGUP-M1](../device/cheetah/BRINGUP-M1.md), [USB-C-PLAN](../device/cheetah/USB-C-PLAN.md) |
| Display | works | Our flip-only KMS driver at 120 Hz, brightness, DPMS, the panel really off with the screen | [DISPLAY-PLAN](../device/cheetah/DISPLAY-PLAN.md) |
| GPU | works | Mali-G710 on Panthor and patched Mesa, DVFS through ACPM | [GPU-PLAN](../device/cheetah/GPU-PLAN.md), [ACPM-PLAN](../device/cheetah/ACPM-PLAN.md) |
| Touch, buttons | works | Our Synaptics TouchComm driver; `gpio-keys` | [NOTES](../device/cheetah/NOTES.md) |
| Wi-Fi | works | brcmfmac behind a restricted DMA pool. Its D3 handshake (needed across suspend) is built, not yet run | [WIFI-BATTERY-PLAN](../device/cheetah/WIFI-BATTERY-PLAN.md), [SUSPEND-PLAN](../device/cheetah/SUSPEND-PLAN.md) S5 |
| Bluetooth | works | Pairing and A2DP audio; headset calls (HFP) need the chip's SCO routing changed, not yet done | [BLUETOOTH-PLAN](../device/cheetah/BLUETOOTH-PLAN.md), [AUDIO-PLAN](../device/cheetah/AUDIO-PLAN.md) |
| Battery | works | MAX77759 fuel gauge with the stock battery model | [WIFI-BATTERY-PLAN](../device/cheetah/WIFI-BATTERY-PLAN.md) |
| Charging | partial | Works by hand; off by default until the temperature guard (B3g) is in. Type-C (B4) not yet run | [USB-C-PLAN](../device/cheetah/USB-C-PLAN.md) |
| Haptics, torch | works | CS40L26 through feedbackd; LM3644 with a quick-settings tile | [HAPTICS-TORCH-PLAN](../device/cheetah/HAPTICS-TORCH-PLAN.md) |
| AoC (audio and sensor DSP) | works | Starts at boot through the GSA and Trusty | [AOC-PLAN](../device/cheetah/AOC-PLAN.md) |
| Sensors | works | Accelerometer, light, proximity and compass at every boot; auto-rotate | [AOC-PLAN](../device/cheetah/AOC-PLAN.md) C6, [USF-PROTOCOL](../device/cheetah/USF-PROTOCOL.md) |
| Speakers, microphones | partial | Both speakers in stereo under Google's speaker protection, mics at stock gain. `omandroid-audio` 0.3.0 plays at stage `media` (digital 737, analog 10), inside the no-protection limits and about 17 dB below stock; stock's gains wait for verified protection (C9), and stock's loudness comes from the Waves processing on the AoC. `omandroid-speaker-tuning` (off by default) runs Waves' own controller from the user's image in a sealed chroot; the AoC answers its exchanges (T3.2), and sending the tuning during playback (T3b) is next | [AOC-PLAN](../device/cheetah/AOC-PLAN.md) C8-C10, [AOC-TUNING-RESEARCH](../device/cheetah/AOC-TUNING-RESEARCH.md) |
| CPU idle, power | partial | C2 idle on all cores is in the default DTB; battery-drain numbers off the cable not yet measured | [POWER-PLAN](../device/cheetah/POWER-PLAN.md) |
| Suspend | in progress | s2idle freezes and wakes cleanly: by key, and 20 of 20 unattended RTC-alarm cycles with the AoC and sensors running (S1-S4). Not on by default: Wi-Fi across sleep (S5) and battery numbers first. Deep sleep (SYS_SLEEP), which stock's standby drain needs, not started | [SUSPEND-PLAN](../device/cheetah/SUSPEND-PLAN.md) |
| GNSS | in progress | Google's GNSS stack in a chroot behind GeoClue streams NMEA; no fix yet (only a windowsill test). Package 0.2.0's assistance, time injection and clean stop passed indoors (G4b step 1); the outdoor fix (step 2) is next | [GNSS-PLAN](../device/cheetah/GNSS-PLAN.md) |
| NFC | in progress | With our plain-NCI fix to st-nci (upstream framed it in NDLC), the ST54J powers up, polls and cycles power (N2.4b-N2.6). Reading a tag (N3) is next; the driver is still blacklisted | [RADIOS-CAMERA-PLAN](../device/cheetah/RADIOS-CAMERA-PLAN.md) §3 |
| Fingerprint | in progress | Trusty runs at every boot; the kernel side passed F1, the sensor's rail reads off at the right voltage (FB2), and Trusty serves the fingerprint side read-only (F2). The HAL bridge and libfprint driver are built; the first secure-storage write (F4) is irreversible and waits for the human's go | [FINGERPRINT-PLAN](../device/cheetah/FINGERPRINT-PLAN.md) |
| Modem | in progress | The PCIe link comes up at stock timing, the S5300 enumerates on the bus, and Google's modem interface driver (CPIF) binds with its 52 I/O devices, the modem unpowered (M2.5-M3.3-B); the SIT protocol is documented and a SIT client daemon (`omandroid-modem-sit`) is built and tested against a simulator. No firmware sent yet. Each modem power-off triggers one recovered UFS error-handler pass, so the stack now keeps the modem on once it is up | [MODEM-PLAN](../device/cheetah/MODEM-PLAN.md), [MODEM-SIT-RESEARCH](../device/cheetah/MODEM-SIT-RESEARCH.md), [MODEM-CLIENT](../device/cheetah/MODEM-CLIENT.md) |
| Cameras | in progress | The ultrawide powers up in stock's order and identifies as a Sony IMX386 (CAM1-CAM3a). Its sensor driver probes and the receiver drivers bind (CAM3b.0-CAM3b.2); libcamera's simple pipeline is packaged. The first stream (CAM3b.3) is next; no frame yet | [CAMERA-PLAN](../device/cheetah/CAMERA-PLAN.md) |
| Android apps (Waydroid) | not started | A goal of the project; no work yet | |
| Installer | not started | Putting Arch onto `userdata` is done by hand today ([CONTRIBUTING](../CONTRIBUTING.md) §4) | |
| Updates | partial | Packages ship through a signed `[omandroid]` pacman repository and `omarchy update`, but the repository is copied to the phone over USB (`tools/repo-push`), not yet hosted; kernel updates go through `bin/omandroid push` | [CONTRIBUTING](../CONTRIBUTING.md) §4 |
| Upstream kernel | in progress | 65 ready commits are prepared as `omandroid-next` for the published kernel, not yet pushed | [KERNEL-PUBLISH](../device/cheetah/KERNEL-PUBLISH.md) |

## 2. What an everyday phone still needs

| Need | Today | What's missing |
| --- | --- | --- |
| **Calls** | no | The whole modem chain (M3-M5 below), then IMS (VoLTE: most networks have no 2G/3G left), then the AoC voice path and an earpiece mode under the speaker protection. A dialer UI on top |
| **SMS** | no | Modem M3 and M4: a SIT client, then an oFono or ModemManager front end; a messaging app |
| **Mobile data** | no | Modem M3 and M4 (one data call, `rmnet0`), the front end, then suspend with the modem online (M6) |
| **Cameras** | no | Raw capture through the CSIS, then libcamera's software ISP; four sensors, focus |
| **Fingerprint unlock** | no | F2-F10: secure storage, the TA, sensor power, the panel's local high-brightness mode, enrolment, fprintd and Omarchy's lock |
| **Suspend on screen-off** | no | s2idle on by default (S5-S8), then deep sleep for real standby |
| **Battery life** | unmeasured | s2idle alone won't reach Android's standby: the plan quotes about 274-286 mA in s2idle against about 32-50 mA in deep sleep on this phone. Deep sleep is the fix; the first job is to measure (S7, `power-ab`) |
| **Loud speakers** | about 17 dB below stock | C9 (protection verified at stock gains), then the AoC's Waves speaker processing ([AOC-TUNING-RESEARCH](../device/cheetah/AOC-TUNING-RESEARCH.md), T0-T6) or a PipeWire loudness filter |
| **NFC** | powers up | N3 (read a tag), then neard on by default; payments are out of scope |
| **Outdoor GPS** | untested | G4b step 2: a first fix outdoors |
| **Notifications, UX polish** | partial | The phone shell (status bar, quick settings, launcher, PIN lock, on-screen keyboard) works. Still desktop-shaped: system dialogs, the screensaver, parts of first run ([NOTES](../device/cheetah/NOTES.md), "Phone UX to-dos"). No incoming-call or SMS notifications until the modem works |
| **Safe charging by default** | no | The temperature guard (B3g), then Type-C (B4) for USB that survives a replug without the rescue service |
| **OTA updates** | partial | Host the `[omandroid]` repository publicly so `omarchy update` reaches it without a cable |
| **Installer** | no | A scripted, safe install to `userdata` and slot B for people who aren't developers |
| **Android apps** | no | Waydroid on our kernel (binder, the GPU) |

## 3. The plan

Milestones in rough priority order. Most tracks are independent and run in parallel; the arrows inside a track are hard dependencies. "Next" is the next concrete step, usually a gated runbook already written in the plan.

### 3.1 Telephony: modem, data, SMS, calls

The highest-value track and the longest. [MODEM-PLAN](../device/cheetah/MODEM-PLAN.md) and [RADIOS-CAMERA-PLAN](../device/cheetah/RADIOS-CAMERA-PLAN.md) §1:

```
M2.5, M3.1, M3.3-B (passed) ─> M2.6 ─> M3.4 firmware boot, CP ONLINE ─> M3.6 SysMMU
                                                              │
                                                              └─> M4 SIT client: attach, data, SMS ─> oFono / ModemManager
                                                                        │
                                                                        └─> M5 IMS (VoLTE) ─> calls with audio ◄─ AoC voice path + earpiece mode
                                                                        └─> M6 boot integration, suspend with the modem online
```

| Milestone | Effort (from the plans) | Next concrete step |
| --- | --- | --- |
| M2.5, M3.1: UFS around modem power changes, enumerate the bus | passed 2026-10-12 | Done; modem power-offs disturb UFS once each, so later stages keep power cycles to a minimum |
| M3.3-B: bind CPIF without firmware | passed 2026-10-12 (52 iodevs, no modem power) | Done |
| M2.6: one slow power-off, to find which line edge disturbs UFS | an hour | The M2.6 runbook; the kernel now runs stock's exact power-off and keeps the modem on once up |
| M3.4: Google's boot loader for the modem in the RAM-only NV chroot, firmware over PCIe, CP ONLINE | 1-2 weeks of debugging (MODEM-PLAN) | The M3.4 runbook (rfsd alone first, then cbd); the partition checksums (M3.5) after every run |
| M3.6: the HSI1 SysMMU confines the modem's DMA | 1 week (MODEM-PLAN) | Offline, after M3.4 |
| M4: SIT client to registration, a data call and SMS | 3-6 weeks (MODEM-PLAN; MODEM-SIT-RESEARCH breaks it down: daemon 3-5 days, data 1 week, SMS 2-3 days). The daemon, `omandroid-sitd`, is now written and passes against a simulator | The gated M4 runbook in MODEM-CLIENT, once M3.4 reaches ONLINE; the long data-call form and the signal layout are still open |
| Front end | oFono driver about 2-3 weeks, ModemManager plugin 2-4 weeks (MODEM-PLAN) or 3-4 weeks (MODEM-SIT-RESEARCH, MODEM-CLIENT) | MODEM-CLIENT §3 leans to oFono (its atoms match SIT's families); decide once `omandroid-sitd` has run on the phone |
| M5: IMS and calls | "weeks more" (RADIOS-CAMERA-PLAN 1.5); needs the AoC voice path and the earpiece design in AOC-PLAN | Design only today |

"Registers on the network under ModemManager" is, in MODEM-PLAN's words, realistically two to three months away, M3 included. Calls come after that. The modem's NV is never written from Linux: the chroot works on checksum-verified RAM copies.

### 3.2 Standby and battery

[SUSPEND-PLAN](../device/cheetah/SUSPEND-PLAN.md), [POWER-PLAN](../device/cheetah/POWER-PLAN.md), [USB-C-PLAN](../device/cheetah/USB-C-PLAN.md):

1. **S3b** (the RTC) and **S4**'s 20-cycle loop passed. Then **S5** (Wi-Fi across sleep with the D3 branch), **S6** (AoC and sensors across sleep), **S7** (battery numbers), **S8** (screen-off sleep on by default, with the sleep hook already in `omandroid-device-cheetah`). Next: S5. The RTC also needs `sec_acpm` loaded at every boot (S3b).
2. **Measure drain** off the cable: POWER-PLAN's B0 baseline and `power-ab c2`.
3. **Deep sleep (SYS_SLEEP)**: the gs201 SoC sleep sequence through the PMU and ACPM, as stock does. Researched in SUSPEND-PLAN §5, no estimate yet. This is what gets standby near Android's.
4. **Safe charging by default**: the temperature guard (B3g), then Type-C with role switching (B4a, B4b). WIFI-BATTERY-PLAN puts B3-B4 at 2-4 days. Next: the B3g runbook.

### 3.3 Fingerprint unlock

[FINGERPRINT-PLAN](../device/cheetah/FINGERPRINT-PLAN.md): about six phone sessions if nothing surprises (F2-F3, F4-F5, F6, F7-F8, F9-F10). F4, the first secure-storage write, is irreversible and needs the human's explicit decision. FB2 and F2 passed. Next: F3 (the RPMB node and read-only copies; `persist` must be mounted with `noload`), then the F4 decision.

### 3.4 Speakers and audio

[AOC-PLAN](../device/cheetah/AOC-PLAN.md) C9-C10, [AUDIO-PLAN](../device/cheetah/AUDIO-PLAN.md):

1. **C9**: the protection firmware only measures the coil at the analog gain its tuning expects (17); at 817/10 it read a false 80 °C. Verify it at stock's gains, then balance (C9e) and real use (C9f), which make stock's levels the default.
2. **Loudness**: stock's comes from Waves processing inside the AoC. `omandroid-speaker-tuning` runs Waves' controller from the user's own image in a sealed chroot and sends its buffers to the AoC under an allowlist, only during playback and only with the protection watchdog running ([AOC-TUNING-RESEARCH](../device/cheetah/AOC-TUNING-RESEARCH.md)). T1-T3.2 passed; next, T3b (one exchange during a tone); `music` mode also waits for C9. A PipeWire limiter (C9g) is the fallback.
3. **Bluetooth HFP**: route the BCM4389's SCO over HCI (AUDIO-PLAN A1).
4. **Earpiece and call audio**: designed in AOC-PLAN; built with the modem's M5.

### 3.5 Location and NFC

- **GNSS** ([GNSS-PLAN](../device/cheetah/GNSS-PLAN.md) G4b): the indoor check of `omandroid-gnss` 0.2.0 passed; next, 15 minutes outdoors recording time to first fix.
- **NFC** ([RADIOS-CAMERA-PLAN](../device/cheetah/RADIOS-CAMERA-PLAN.md) §3): power-up passed (N2.4b-N2.6); next, N3 (a tag's type, with a card in hand), then the driver and neard on by default.

### 3.6 Cameras

[CAMERA-PLAN](../device/cheetah/CAMERA-PLAN.md): raw Bayer capture through the CSIS write DMA, then libcamera's software ISP. Its timeline: a first raw frame from the ultrawide in 6-9 weeks, a photo in `cam` and a PipeWire app in 8-12 weeks, video 2-3 weeks later, all four cameras with focus in 4-6 months. The main and tele cameras carry most of the risk. K through CAM3a passed (the ultrawide is a Sony IMX386), and the capture path for CAM3b-CAM5 is built; CAM3b.0-CAM3b.2 passed too (the sensor driver probes, the PHY and CSIS bind); next, the corrected CAM3b.3: the sensor streams a test pattern and the receiver counts frames, then CAM4, the first DMA to memory.

### 3.7 Distribution: updates, installer, upstream

- **Host the `[omandroid]` repository** publicly, so `omarchy update` updates the phone without a cable (signing and the keyring package already exist).
- **An installer** that sets up slot B and `userdata` with the safety model built in ([CONTRIBUTING](../CONTRIBUTING.md) §3). Not started.
- **Publish the kernel**: review, test and push `omandroid-next` ([KERNEL-PUBLISH](../device/cheetah/KERNEL-PUBLISH.md)), then send ready series upstream.
- **Waydroid** for Android apps. Not started.

### 3.8 Shell and UX

Make the remaining desktop pieces phone-shaped (system dialogs, the screensaver, first run), and add what telephony will need: incoming-call and SMS notifications, a dialer and a messages app. The running list is "Phone UX to-dos" in [NOTES.md](../device/cheetah/NOTES.md); Omarchy changes go upstream first ([`patches/omarchy/`](../patches/omarchy)).

## 4. How to help

- **Start with [CONTRIBUTING.md](../CONTRIBUTING.md).** It has the safety model, the build and flash loop and how to submit changes. AI coding agents also read [AGENTS.md](../AGENTS.md).
- **Pick a plan.** Each subsystem's plan in [`device/cheetah/`](../device/cheetah) has a status line, the evidence, and a gated runbook with the next step. Offline work (drivers, reviews, checkpatch and `dt-validate` runs, packaging, shell UX) needs no phone.
- **Bring up another Pixel.** [DEVICES.md](DEVICES.md) lists the devices we'd like and their closest starting point; CONTRIBUTING §5 is the bring-up guide. Most gs201 phones need mainly a board DTS.
- **Upstream review.** Kernel series from `omandroid-next` and the Mesa and Omarchy patches benefit from review by people who know those subsystems.
