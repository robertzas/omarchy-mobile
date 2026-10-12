<!-- SPDX-License-Identifier: MIT -->
# AoC plan (cheetah / gs201): audio and sensor DSP bring-up

Status: **offline research and the first kernel piece done, 2026-10-12.
Nothing has run on the phone.** Kernel branch `omandroid-aoc` in
`~/android/mainline/wt-aoc` (out dir `~/android/mainline/out-aoc`), on
`omandroid` @ `7b0f8b5d1`. Everything new is disabled by default. The
runbook is section 7; stage C1 is the first one to run.

The AoC (Always-on Compute) is Google's audio and sensor DSP. On gs201 every
on-device audio path ends there: the speaker amplifiers' TDM link, the three
PDM microphones, the earpiece (the top speaker amp) and Bluetooth SCO
(`AUDIO-PLAN.md` 0.1). It also runs the sensor hub: accelerometer (auto-rotate),
proximity, light, gyro, magnetometers, barometer. `AUDIO-PLAN.md` stage A6 is
this plan.

Path abbreviations (as in the other plans):

- `L/` = our kernel, branch `omandroid-aoc` (`~/android/mainline/wt-aoc`)
- `G/` = `~/android/omandroid/out-kernel/google/gs-6.1/private` (Google's GPL gs201 kernel, the one stock runs)
- `GA/` = `G/google-modules/aoc`, `GSA/` = `G/google-modules/soc/gs/drivers/soc/google/gsa`
- `GS/` = `G/google-modules/soc/gs`
- `R/` = `~/android/reference/cheetah-stock-cp2a-root` (stock live DT, dmesg)
- `V/` = `~/android/omandroid/vendor/google/cheetah/proprietary/vendor` (stock vendor blobs)

---

## 0. Top findings

1. **The AoC is started by Trusty, not by the GSA mailbox alone.** Stock
   loads `aoc.bin` from the kernel (`aoc 19000000.aoc: attempting to load
   firmware "aoc.bin"`, `R/dmesg.txt:5799`), the GSA authenticates it over its
   mailbox (`GSA_MB_CMD_LOAD_AOC_FW_IMG` = 90, `GSA/gsa_core.c:169-176`), and
   then `GSA_AOC_START` goes to the Trusty service
   `com.android.trusty.gsa.hwmgr.aoc` (`GSA/gsa_core.c:187-194`,
   `R/dmesg.txt:5886` "TZ: com.android.trusty.gsa.hwmgr.aoc connected").
   Every public Google kernel does the same, back to the first Pixel 6 branch
   (`android-gs-raviole-5.10-android12-d1`). So **Trusty is mandatory**
   unless one untested shortcut works (finding 4). Our Trusty port already
   exists on `omandroid-fingerprint` (`FINGERPRINT-RESEARCH.md` 3.1, gate F2
   not yet run): the AoC and fingerprint share it.
2. **The bootloader does not leave the AoC running.** Stock's kernel loads and
   starts it 4.07 s into boot and it reports "firmware version
   14022723-polygon did become online with 82 services" at 4.60 s
   (`R/dmesg.txt:5799-6042`). Nothing earlier touches it. So there is no
   running firmware for a minimal client to talk to; the full
   load-authenticate-start path is needed.
3. **The firmware and Google's 6.1 driver match, and the firmware carries its
   own IOMMU map.** Parsed offline from our `V/firmware/aoc.bin` (21,328,448
   bytes, auth header generation 1, superbin magic `0xaabbccdd`, release
   build "14022723-polygon"):
   - all 286 interface UUIDs that `GA/aoc-interface-gs201.h` checks
     (`AocInterfaceCheck()`) are in the firmware's 537-entry table, so the
     driver accepts this firmware;
   - the image config puts the body at `0x94000000` (`fw_size` 0x1600000,
     22 MiB), the IPC area at carve-out offset 0x1600000, and lists **six
     IOMMU windows** (AoC address → physical, size):

     | AoC VA | PA | Size | What |
     |---|---|---|---|
     | `0x98000000` | `0x94000000` | 48 MiB | the AoC carve-out (`aoc@94000000`) |
     | `0x9b000000` | `0x97000000` | 4 MiB | `xhci-dma` (USB audio offload) |
     | `0x9e000000` | `0x18200000` | 2 MiB | APM/AoC mailboxes (`0x18210000`, `0x18300000`-`0x18340000`) |
     | `0x9e200000` | `0x17c00000` | 1 MiB | GSA block (`0x17c60000` S2MPU, `0x17c90000` mailbox) |
     | `0x9e500000` | `0x11200000` | 1 MiB | USB PHY/dwc3 (HSI0) |
     | `0x9e300000` | `0x40000000` | 1 MiB | PCIe ch0 outbound window (modem) |

     All are 1 MiB multiples, so a first-level-only SysMMU v8 table (the
     format our Wi-Fi work already uses, `WIFI-BATTERY-PLAN.md` 9.17) covers
     them: about 300 lines instead of Google's 3,200-line IOMMU driver.
4. **One untested shortcut: AoC state commands over the GSA mailbox.**
   `GSA_MB_CMD_AOC_CMD` (91) is defined next to the load command
   (`GSA/gsa_mbox.h:49-52`) but no public driver sends it. If the production
   GSA firmware still serves it, `GSA_AOC_START` could skip Trusty. Stage C1
   asks it for `GSA_AOC_GET_STATE` (value 0, so harmless whatever the argument
   layout). Expect "unhandled"; plan for Trusty.
5. **ACPM channel 13 is a doorbell, not a queue, and is not needed to start
   the AoC.** Our A1 dump shows it as type 2 (buffer), all offsets 0, `mlen
   0` (`logs/acpm-20261012-112536-a1.log`). Google's driver handles a type-2
   channel by calling the client's callback on the APM→AP mailbox interrupt
   bit (`GS/drivers/soc/google/acpm/acpm_ipc.c:499-505`), and the AoC callback
   ignores the payload (`GA/aoc_v1.c:58-67`, sets `aoc_reset_done`). It is
   used only after an AoC watchdog reset (`aoc_watchdog_restart()`,
   `GA/aoc_v1.c:109-206`). So the fix for AoC restart is to watch bit 13 of the
   AP2APM mailbox status (SPI 78), not to read any SRAM ring. Until then the
   AoC starts once per boot and a crash needs a reboot.
6. **First sensor reading comes before first sound.** Sensors need the AoC
   core plus a character-device client in userspace; audio additionally
   needs the 16,700-line `aoc_alsa` port, the amplifiers and their protection.

What is mandatory, in boot order:

| Piece | Why | Source | Our status |
|---|---|---|---|
| GSA mailbox | authenticates and loads `aoc.bin` | `GSA/gsa_mbox.c` (600) + `gsa_core.c` load path | **written** (`omandroid-aoc`, status queries only) |
| S2MPU off for the GSA and the AoC | the GSA reads the image header by DMA; stock's pKVM programs both S2MPUs at power-up (`R/dmesg.txt:462`), nothing does without a hypervisor | `GS/drivers/soc/google/s2mpu/s2mpu-regs.h` (CTRL0 at 0x0, bit 0 enable) | to write: CTRL0 only, while powered |
| Trusty + GSA `hwmgr.aoc` client | `GSA_AOC_START` | `G/google-modules/trusty`, `GSA/gsa_tz.c` (236) | Trusty ported (fingerprint branch, not run); client to write |
| SysMMU `sysmmu_asoc` (`0x1a090000`, v8) | the AoC's view of DRAM and its peripherals | `GS/drivers/iommu/samsung-iommu.[ch]` (v8 VM register set) | to write: static six-window table |
| AoC mailboxes (`0x18300000`, `0x18320000`, `0x18340000`) | service doorbells | `GA/mailbox-wc.c` (412) | to port |
| AoC core | firmware parameters, services, rings, char devices | `GA/aoc.c`, `aoc_v1.c`, `aoc_firmware.c`, `aoc_service_core.c`, `aoc_channel_dev.c`, `aoc_char_dev.c`, `aoc_control_dev.c` (~6,200) | to port |
| PMIC rails over ACPM ch 2 | mics (LDO20M, LDO19S, LDO20S), sensors (LDO7S then LDO5S) | `GS/include/linux/mfd/samsung/s2mpg1[23]-register.h` | ACPM link works; no S2MPG12/13 driver (`ACPM-PLAN.md` 6) |
| `aoc_alsa` | the sound card | `GA/alsa/` (~16,700) | audio only; to port |
| ACPM ch 13 | AoC restart after a crash | above | later |

---

## 1. How stock brings the AoC up (evidence)

Order in `aoc_fw_callback()` (`GA/aoc.c:508-710`), with `gsa-enabled` set in
the stock DT (`R/live.dts:6068`):

1. `request_aoc_on(true)`: write 1 to `aoc_req` (`0x181d0000`); the
   acknowledge is `aoc_req + 0x40` (`GA/aoc_v1.c:87-106`).
2. Validate the superbin, check the interface UUIDs, refuse unsigned images.
3. Copy the image body (without the 4 KiB auth header) into the carve-out
   at `0x94000000` (`_aoc_fw_commit()`; `AOC_BINARY_DRAM_OFFSET` is 0).
4. `aoc_fw_authenticate()`: copy the 4 KiB header into a
   `dma_alloc_coherent()` buffer **of the GSA device**, then mailbox command
   90 with header DMA address (lo, hi) and body physical address (lo, hi)
   (`GSA/gsa_core.c:82-95`). The GSA authenticates, then locks the body: from
   here the AP must not touch `0x94000000`-`0x955fffff`.
5. `aoc_pass_fw_information()`: write the parameter block at the IPC area
   (carve-out + 0x1600000): magic `0x0a0cda7a`, then key/size/value triples:
   board id `0x30301`, board rev `0x10000` (DT `aoc-board-cfg = "C10"`),
   carve-out address and size, the three heap addresses (sensor direct 4 MiB,
   playback 16 KiB, capture 64 KiB, carved from the top of the carve-out and
   given as AoC addresses = PA - 0x94000000 + 0x98000000), chip revision,
   type and product id, a random seed, and zeros for the debug switches.
6. `gsa_send_aoc_cmd(GSA_AOC_START)` over Trusty.
7. Enable the watchdog IRQ (SPI 116), keep the AP out of deep idle for 2 s,
   and wait for the firmware to write `AOC_MAGIC` into the control block;
   then it enumerates its services (82) and the bus binds drivers by name:
   `aoc_alsa` to `audio_output_control` and friends, `aoc_channel_dev` to
   `com.google.usf`, `com.google.usf.non_wake_up`, `com.google.chre`
   (`R/dmesg.txt:6076-6082`), everything else to `aoc_char_dev`.

With `gsa-enabled`, the kernel does **not** install the firmware's IOMMU table
(`aoc_configure_iommu()` runs only on the non-GSA path); stock's samsung-iommu
driver owns `sysmmu_asoc` and restores its state on runtime resume
(`GA/aoc_v1.c:185-198`). Which side programs the six windows on stock (the
non-secure table, or the secure half at `sysmmu,secure_base = 0x1a0a0000`)
is not visible in the GPL code; on our kernel nothing programs it, so we
install the six windows ourselves (C4).

Other facts the port needs:

- `pd_aoc` (`0x18061880`) is `disabled` in the stock DT: the APM powers
  BLK_AOC on `aoc_req`, the kernel never does. AoC power status is PMU
  `0x18061884` (`GS/drivers/soc/google/cal-if/gs201/flexpmu_cal_local_gs201.h:8-23`),
  but **do not read the PMU from user space**: a `/dev/mem` read of a PMU
  power-domain register crashed the phone (`GPU-PLAN.md`, incident).
- No SSMT setup on gs201 (`aoc_configure_ssmt()` is gs101-only,
  `GA/aoc_v1.c:314-342`).
- Pins: `aoc_vsync_pins` = gpp3-1, gpp5-1, gpp7-1, gpp9-1, function 2
  (`R/live.dts:4212-4216`, PERIC0 pin controller): display TE to the AoC,
  which times the under-display light sensor.
- Sensor supplies `sensor_1v8` then `sensor_3v3` (`sensor_power_list`,
  `R/live.dts:6092-6094`); DMIC supplies are always-on regulators in the DT.
- The AoC's view of time: `aoc_clock_and_kernel_boottime`, used to stamp
  sensor events.

---

## 2. Shortcuts considered

| Idea | Verdict | Why |
|---|---|---|
| The bootloader leaves the AoC running; talk to it with a minimal mailbox client | **no** | stock's kernel loads and starts it (finding 2) |
| Load with the GSA mailbox, start without Trusty (mailbox cmd 91) | **unknown, cheap to test** | stage C1 `aoc_state` |
| Release the AoC from reset ourselves (`aoc_release_from_reset()`, PCU bit 0) | **no** | only for unsigned images without GSA; signed images are locked by the GSA, and the production firmware is signed |
| Skip the SysMMU (bypass) | **no** | the firmware addresses its carve-out at `0x98000000`, which is physically the GXP region; translation is required |
| Skip ACPM ch 13 | **yes, for the first start** | needed only for restart (finding 5) |
| Skip `aoc_alsa` for sensors | **yes** | sensors use `aoc_channel_dev` only |
| Skip the S2MPG12/13 regulator driver | **yes, at first** | five LDO enable bits over ACPM ch 2 (section 5); a proper regulator driver later |
| Port Google's samsung-iommu (3,200 lines) | **no** | a static six-window table is enough; the AoC needs no runtime maps for first light (the heaps are inside the 48 MiB window) |

### 2.1 Can the AoC client live in userspace, as Android's HAL does?

Partly. On stock the split is already kernel core + userspace HALs: the kernel
loads the firmware, runs the mailbox doorbells and the service rings, and
exposes each service as a character device (`/dev/acd-com.google.usf`,
`/dev/aoc`); the sensor HAL (`V/lib64/sensors.usf.so`, `libusf.so`) and the
audio HAL speak the services' message formats from userspace.

- **The kernel part cannot move to userspace.** Starting the AoC needs
  Trusty (SMCs from EL1), the GSA needs a DMA buffer below 4 GiB that it can
  read, the SysMMU and S2MPUs need privileged writes, and the services are
  interrupt-driven rings. A UIO/`/dev/mem` client would reimplement the same
  core worse and could not be upstreamed.
- **The sensor client should live in userspace**, exactly like stock: our own
  USF client over `/dev/acd-com.google.usf` (FlatBuffers messages; the
  stock registry in `V/etc/sensors/registry/cheetah_dvt.reg` and
  `persist:/sensors/registry`), feeding an iio-sensor-proxy-compatible
  D-Bus service for Hyprland rotation and brightness.
- **Audio could, in principle, skip `aoc_alsa`** with a userspace daemon
  that drives `audio_output_control` and a playback ring through
  `aoc_char_dev` and exposes a PipeWire node. But the command set it would
  have to replicate is `aoc_alsa_hw.c`/`aoc_alsa_ctl.c` (7,400 lines), and
  PipeWire/UCM/volume keys all expect an ALSA card. Port `aoc_alsa`
  out of tree (with the CS35L41 as TDM codecs) instead.

---

## 3. Effort

| Piece | Lines (Google) | Effort | Notes |
|---|---|---|---|
| GSA mailbox driver | 600 | **done** (C1 queries); +2 days for the load command | `L/drivers/soc/google/gsa.c` |
| S2MPU CTRL0 helper | - | 1 day | two registers, only when powered |
| GSA `hwmgr.aoc` client over Trusty IPC | 236 | 2-3 days | on top of the fingerprint branch's `tipc` kernel API |
| SysMMU six-window driver | (3,200) → ~300 | 3-5 days | v8 VM registers as in `GS/drivers/iommu/samsung-iommu.c:38-75,182-240`; same table format as `pcie-gs201-sysmmu` |
| AoC mailbox + core + char devices | ~6,600 | 2-3 weeks | out of tree first; vendor hooks (`exynos_pmu`, `dbg_snapshot`, `acpm_ipc`, `gs_chipid`, ITMON, power-mode) become stubs or upstream equivalents |
| Rails over ACPM ch 2 | - | 2-3 days for five LDO bits; 2-3 weeks for a real S2MPG12/13 regulator driver | `ACPM-PLAN.md` 6 |
| USF sensor client + D-Bus service | - | 2-4 weeks | clean-room from the stock library's behaviour |
| `aoc_alsa` port to 7.3 ASoC | ~16,700 | 3-6 weeks | dummy codec on links with no driver, TDM slots from the DT |
| Machine/UCM/calibration/protection | - | 2 weeks | `AUDIO-PLAN.md` A7 |
| ACPM ch 13 doorbell + AoC restart | - | 3-5 days | upstream `exynos-mailbox` has no RX interrupt support yet |

Calendar, one developer: **first AoC "online" in 4-6 weeks, first
accelerometer reading 2-3 weeks after that, first protected speaker sound
6-10 weeks after "online"**. The order is shorter than the "months" estimate
in `AUDIO-PLAN.md` because Trusty is already ported, the IOMMU shrinks to a
static table, and ACPM is working.

---

## 4. Risks

| Risk | Mitigation |
|---|---|
| S2MPU registers other than CTRL0 can reset the SoC; any S2MPU register can abort while its block is off | touch only CTRL0, only after the GSA wakelock (`GSA_MB_CMD_WAKELOCK_ACQUIRE` 150) or `aoc_req` acknowledge; never from user space |
| PMU reads from user space crash the phone (`GPU-PLAN.md` incident) | AoC power state only through the kernel, via `aoc_req + 0x40` or the GSA/Trusty `GET_STATE` |
| After `LOAD_AOC_FW_IMG` the carve-out body is locked; an AP read faults | never read `0x94000000`-`0x955fffff` after load; the carve-out is already `no-map` (`gs201.dtsi`) |
| A failed start cannot be retried in the same boot | hang-safe marker as for Wi-Fi: write and sync `/var/lib/omandroid/aoc-bringup-started` before the load, skip on the next boot if present; reboot to retry |
| GSA mailbox command never answered | `gsa.c` times out after 1 s and disables the mailbox until reload (Google's waits forever) |
| AoC watchdog / IOMMU fault storms | IRQs requested disabled, enabled only after a successful start (as stock) |
| The AoC holds the AP awake or wakes MIF constantly (sensors at high rate) | non-wakeup USF channels for UI sensors; pause sensors when the screen is off |
| Firmware/driver mismatch after a vendor update | the UUID check refuses it; extract `aoc.bin` from the phone's own vendor partition with the matching kernel sources (checked offline for 14022723) |
| **Speaker damage** | `AUDIO-PLAN.md` section 4 limits apply unchanged: boost peak ≤ 2.5 A, `Analog PCM Volume` ≤ 6 for the top amp as earpiece and ≤ 10 for either amp with the DSP bypassed, `Digital PCM Volume` ≤ 657 for first sound, 1 kHz bursts of 1-2 s, ≤ 30 s without protection, mapping and calibration confirmed before tuning loads. Also AoC-specific: the amps take their PLL reference from the AoC's TDM BCLK, so the TDM link must run before an amp's `GLOBAL_EN` and the amp must be muted before the AoC stops TDM |
| Mic rails off: recordings are a burst then zeros | turn LDO20M, LDO19S, LDO20S on (ACPM ch 2) before the first capture |
| Sensor rails off when the registry loads: only virtual sensors until the AoC restarts | LDO7S then LDO5S on before loading the registry |
| Under-display light/proximity (TMD3719) never converts | send the display state (panel on/off, brightness, refresh rate) to the AoC's display-info service at start and on every change |

---

## 5. Kernel and repo changes made

Kernel branch `omandroid-aoc` (`L/`), on `omandroid` @ `7b0f8b5d1`:

| Commit | What | Default |
|---|---|---|
| `58e9fb0a2` dt-bindings: soc: google: add the gs201 GSA mailbox | `google,gs201-gsa`: reg, one interrupt | - |
| `21aa277d2` soc: google: add a GSA mailbox driver | `drivers/soc/google/gsa.c` (`CONFIG_GOOGLE_GSA`): Google's register protocol, 1 s timeout per command, then the mailbox is refused. Debugfs only: `sjtag_status` (cmd 100, what stock sends at boot), and `aoc_state` (cmd 91, `GET_STATE`) only with `aoc_query=1` | module; nothing binds without the DT node |
| `aed858b94` arm64: dts: exynos: google: gs201: add the GSA mailbox | `gsa@17c90000`, GIC SPI 363, from `R/live.dts:7209-7216` | `disabled` |

Built into `out-aoc`: release `7.3.0-rc6-omandroid-push1-00061-gaed858b9421c`,
`gsa.ko`, modules tarball and images (default DTB, GSA node disabled).
`gsa.c` builds with `W=1` and no warnings and passes `checkpatch.pl`; the DTB
has only the existing framebuffer `unit_address_vs_reg` warning; the
overlay applies with `fdtoverlay`. Not run: `dt_binding_check` (no dtschema
on this host). `git merge-tree` shows the branch merges into
`omandroid-int` @ `907128673` without conflicts.

Repo:

- `kernel/configs/omandroid.config`: `CONFIG_GOOGLE_GSA=m`.
- `device/cheetah/overlays/aoc-gsa-test.dtso`: enables the GSA node (C1).

Not written yet, in order: the S2MPU CTRL0 helper and the load command in
`gsa.c`; the Trusty `hwmgr.aoc` client (needs the Trusty commits from
`omandroid-fingerprint`); the `sysmmu_asoc` six-window driver; the AoC core
port.

---

## 6. Stages

| Stage | What | Writes to hardware | Risk | Needs |
|---|---|---|---|---|
| C0 | offline: firmware header, IOMMU windows, UUID check | none | none | **done** (section 0) |
| **C1** | GSA mailbox: `sjtag_status`, then `aoc_state` (cmd 91) | mailbox registers only (mask, doorbell) | low | this branch |
| C2 | Trusty up (`FINGERPRINT-RESEARCH.md` F2), then `hwmgr.aoc` `GET_STATE` | Trusty SMCs as stock | low | fingerprint branch + client |
| C3 | read the five LDO control registers over ACPM ch 2 | none (reads) | low | a read-only PMIC debug path on the ACPM branch |
| C4 | AoC core probe with `aoc_autoload_firmware=0`; SysMMU windows programmed, not used | SysMMU registers | medium | core port, SysMMU driver |
| C5 | load, authenticate, start; "online with 82 services" | S2MPU CTRL0, GSA, `aoc_req` | **high** (one try per boot) | C1-C4 |
| C6 | first sensor reading: rails LDO7S → LDO5S, registry load, accelerometer samples; then rotation in Hyprland | PMIC LDO enable bits | medium | C5, USF client |
| C7 | microphones: rails, capture EP1 (PCM 8), record the noise floor | PMIC, AoC | low | C5, `aoc_alsa` |
| C8 | first sound: top amp alone, DSP bypassed, section 4 limits | amps, AoC TDM | **speaker damage** | `AUDIO-PLAN.md` A2/A3, C7 |
| C9 | protection firmware + calibration, UCM, PipeWire | amps | medium | `AUDIO-PLAN.md` A7 |
| C10 | ACPM ch 13 doorbell, AoC watchdog restart | AoC PCU watchdog | medium | C5 |

---

## 7. Runbook

From the omandroid repo, phone in Arch over USB, a second terminal running
`tools/phone-ssh dmesg -w` so the last line before any hang is on the laptop.
Overlays as in `HAPTICS-TORCH-PLAN.md` 4.

### C1: GSA mailbox status queries (read-only)

Run it on the integration kernel, so Wi-Fi, the GPU and the rest stay as
they are: merge `omandroid-aoc` into `omandroid-int` (three commits; it
merges cleanly) and build int as usual. (`out-aoc` holds a build of the
branch alone, on `omandroid`, which lacks the int-only features; use it only
to check the module.)

```sh
export KERNEL_DIR=$HOME/android/mainline/wt-int KERNEL_OUT=$HOME/android/mainline/out-int
O=$KERNEL_OUT D=$O/arch/arm64/boot/dts/exynos/google/gs201-cheetah.dtb
git -C $KERNEL_DIR merge --no-edit omandroid-aoc
bin/omandroid kernel && bin/omandroid modules && bin/omandroid initramfs && bin/omandroid images
# keep the module from autoloading during bring-up
tools/phone-ssh 'echo "blacklist gsa" > /etc/modprobe.d/omandroid-aoc-bringup.conf'
cp "$D" "$D.default"     # the fresh default DTB
$O/scripts/dtc/dtc -q -I dts -O dtb -o out/aoc-gsa-test.dtbo device/cheetah/overlays/aoc-gsa-test.dtso
$O/scripts/dtc/fdtoverlay -i "$D.default" -o "$D" out/aoc-gsa-test.dtbo
bin/omandroid images && bin/omandroid modules-push && bin/omandroid push
```

After the reboot:

```sh
tools/phone-ssh 'ls /sys/bus/platform/devices/ | grep 17c90000; lsmod | grep -c "^gsa "'
tools/phone-ssh 'modprobe gsa; dmesg | grep google-gsa; grep gsa /proc/interrupts'
tools/phone-ssh 'cat /sys/kernel/debug/17c90000.gsa/sjtag_status; dmesg | grep google-gsa | tail -2'
```

- **Expect:** `17c90000.gsa` present, module count 0 before `modprobe`;
  "mailbox ready, irq N"; one `gsa` line in `/proc/interrupts`. Then
  `sjtag_status` prints `args 3: debug_allowed 0x… hw_status 0x… debug_time
  0x…` and dmesg "cmd 100: answer 0x80000064 err 0 argc 3". Stock prints
  "Cmd status: 0x00000010-0" for the same command (`R/dmesg.txt:2012`).
  The interrupt count goes up by one.
- **Stop:** "cmd 100: no answer in 1000 ms" (the GSA is not listening, or the
  interrupt is wrong: report `/proc/interrupts`), or any abort/hang.

Then the shortcut test:

```sh
tools/phone-ssh 'rmmod gsa; modprobe gsa aoc_query=1; cat /sys/kernel/debug/17c90000.gsa/aoc_state; dmesg | grep google-gsa | tail -2'
```

- **Expect (likely):** `error -5 (gsa err N)` or `error -22`, with dmesg
  "cmd 91: answer 0x8000005b err N": the GSA firmware no longer serves AoC
  commands on the mailbox. Trusty is then the only way to start the AoC (C2).
- **If it answers** `args 1: 0x00000000 … (state inactive)`: the mailbox
  serves AoC state commands. That opens a Trusty-free start (`GSA_AOC_START`
  = 1 the same way), to be tried only in C5, after the load.
- **Stop:** a timeout here wedges only our driver (`rmmod gsa` to reset).
  Report it; do not retry in the same boot.
- **Rollback:** `rmmod gsa`; `cp "$D.default" "$D"; bin/omandroid images &&
  bin/omandroid push`; `rm /etc/modprobe.d/omandroid-aoc-bringup.conf`.

### C2 onwards

Written when C1 has answered. C2 reuses `FINGERPRINT-RESEARCH.md` F2
(`tools/fingerprint-capture --watchdog trusty-core`, `trusty-log`,
`trusty-ipc`), then adds one `hwmgr.aoc` `GET_STATE` call. C5 follows the
Wi-Fi pattern: a guarded start script with a synced marker, the hardware
watchdog armed, and one attempt per boot.

---

## 8. Open questions

1. Does the GSA firmware serve `GSA_MB_CMD_AOC_CMD` (91)? (C1)
2. Who programs `sysmmu_asoc` on stock, the non-secure table or the secure
   half? If the secure world expects its own table, our non-secure windows
   may be ignored or conflict. C4 reads `CTRL`, `CFG`, `VERSION`, `CAPA1`
   and the per-VID registers first, as F1 did for HSI2.
3. Which VID does the AoC's traffic use on `sysmmu_asoc`? Stock gives no
   VID property for it (single domain); expect VID 0, and confirm with a
   window-only negative test before the first start.
4. Where does the GSA's DMA reach? Allocate the header with a 32-bit mask
   until proven otherwise.
5. The GSA S2MPU (`0x17c60000`, `off-at-boot` in the stock DT) state after
   ABL on a non-pKVM boot: read CTRL0 once, after a GSA wakelock (C5 prep).
6. Chip revision/type/product id for the firmware parameter block: from
   upstream `exynos-chipid` (gs101 has it) or the DT `soc_id`
   (`0x09855001`).
7. Are the mic and sensor LDOs on or off at hand-off? (C3)
8. Is the factory sensor calibration in `persist:/sensors/registry` intact
   on this phone (read-only, as `speaker.cal` was read)?
