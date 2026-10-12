<!-- SPDX-License-Identifier: MIT -->
# AGENTS.md: working on Omandroid as an AI coding agent

Omandroid runs native Omarchy (Arch Linux ARM, Hyprland, Omarchy's packages) on Google Pixel phones with a mainline kernel and no Android. The reference device is the Pixel 7 Pro (`cheetah`, gs201). Read [CONTRIBUTING.md](CONTRIBUTING.md) for the project, the safety model and the bring-up order. This file holds the rules and gotchas for agents, each with the reason behind it.

**The repositories are public.** Anything you commit, push, or write into a plan, a log excerpt or a screenshot is published.

## 1. Safety rules (non-negotiable)

- **Ask the human before every reboot, flash, `push`, overlay boot or irreversible write.** That includes RPMB writes, a first `storageproxyd` run, `devinfo` and anything under `/dev/sd*`. The phone is real hardware with calibration data that can't be replaced, and a human has to be ready to recover it.
- **The phone is shared with a human. Announce anything that affects the screen or the feel of the phone before you run it**: DPMS, display modes and refresh rate, brightness, `bl_power`, haptics, the torch, the shell restarting, rotation. Otherwise they think the phone is broken, or it buzzes in their hand.
- **Only slot B and `userdata` are ours.** Write only `boot_b`, `init_boot_b`, `vendor_boot_b`, `vendor_kernel_boot_b` and `dtbo_b`, and only through `bin/omandroid flash|push`. Never touch bootloader, radio, `devinfo`, `persist`, `efs*`, `modem*` or `vbmeta`, and never run an unsuffixed `fastboot flash`. Slot A's stock Android is the way back.
- **Never weaken the storage guard.** Don't `blockdev --setrw` a partition or recreate `/dev/sda`. Don't mount Android partitions read-write, and don't add names to the `UFS_RW` allowlist without the human's say-so. The guard is what keeps a bad command from erasing the IMEI.
- **Check backups before radio, PMIC, AoC or Trusty work.** Run the checksum check of `efs`, `efs_backup`, `modem_userdata`, `persist` and `modem_a/b` against the off-repo backup first ([MODEM-PLAN.md](device/cheetah/MODEM-PLAN.md) M0.1). If there's no backup, stop.
- **Never read or write PMU registers from userspace** (no `devmem`, no `debugfs/regmap/*pmu*/registers`). PMU writes from userspace are silently ignored, and one read of a PMU G3D register crashed the phone. Use the kernel's SMC-backed `exynos-pmu` regmap.
- **`devmem` is `devmem ADDR [VALUE]`.** A second argument is written, so `devmem ADDR 32` writes 0x20. This once clobbered live DSIM timing registers.
- **Read only blocks that are known powered and clocked, one register per call on a first probe.** A read of an unpowered block aborts the SoC and kills the session.
- **Read-only steps first, then one change per boot.** New DT nodes stay `disabled` and are enabled by an overlay in [`device/cheetah/overlays/`](device/cheetah/overlays). Blacklist a module before installing a DTB that enables its node. Two new things that fail together tell you nothing.
- **Arm a safety net before every risky step:**
  - for anything that loads drivers or pokes hardware, a log stream to the laptop first and `--watchdog` (the stage tools do both);
  - for anything that can cut USB, a dead-man switch: `tools/usbc-deadman`, or `systemd-run --unit=x-deadman --on-active=90 <undo>`, then confirm over a *fresh* SSH login and stop the timer;
  - for anything at boot, a hang marker.

  USB is the only link, so a step that can kill it must be able to undo itself.
- **When a reboot gets stuck:** systemd's `RebootWatchdogSec=1min` resets the phone a minute into a hung shutdown, so wait. If it's still stuck, ask the human to force a restart: Power held about 30 s, then Power. For fastboot by hand: Volume Down + Power held about 20 s. Don't send more commands to a phone that has stopped answering, and don't guess at its state. Ask.
- **Never commit or paste identifying data or vendor blobs.** That means MAC and Bluetooth addresses, serial numbers, IMEIs, SSIDs, account names, `getprop` dumps, `persist` or `efs` contents, partition images, Google firmware and binaries. Grep your diff before committing (`[0-9a-f]{2}(:[0-9a-f]{2}){5}`, the SSID, the serial). Use placeholders such as `<SSID>`.
- **Cite only properly licensed, citable sources** in commits, docs and code: upstream Linux, Google's GPL kernel, postmarketOS, Mesa, Omarchy and our own captures.

## 2. Workflow

- **Read before you touch anything:**
  1. the subsystem's plan in `device/<codename>/*-PLAN.md`: its status line names the kernel branch, the worktree (`~/android/mainline/wt-<subsystem>`) and the output directory (`out-<subsystem>`);
  2. the newest entries in [NOTES.md](device/cheetah/NOTES.md);
  3. the gotchas below.

  Plans record what already failed and why.
- **Work offline and hand the human a runbook.** Write the code, build it, and run checkpatch, `W=1` and `dt-validate` yourself. Then add a gated runbook to the plan: the commands, Expect/Pass, a **stop condition**, a Rollback and a risk level for each step, read-only steps first. The human runs or approves each step. Record the results in the plan with the date and the kernel release (`uname -r`).
- **Build with an explicit worktree and output directory:** `KERNEL_DIR=~/android/mainline/wt-X KERNEL_OUT=~/android/mainline/out-X bin/omandroid kernel`. Other agents build in parallel, and a shared output directory mixes their builds.
- **Kernel branches:** one subsystem per branch (`omandroid-<subsystem>`). The human merges branches into the local integration branch `omandroid-int` that the phone runs. Curated, upstream-ready commits go to `omandroid`, the branch published to GitHub. Don't rebase or force-push branches someone else is merging from.
- **Commit messages:**
  - Kernel commits are upstream-style: the subsystem prefix from `git log --oneline <file>`, the why, and the evidence. AI agents never add `Signed-off-by:` (`Documentation/process/coding-assistants.rst`): the human signs off.
  - This repository uses an area prefix (`omandroid-gnss: …`, `device-cheetah 0.1.15: …`, `DISPLAY-PLAN: …`), a body that explains why, and the attribution trailer the session asks for.
- **Commit only your own files when others have uncommitted work**, with a temporary index:

  ```sh
  export GIT_INDEX_FILE=$(mktemp -u)      # a path git creates
  git read-tree HEAD
  git add -- path/you/changed other/path
  git commit -m "…"
  unset GIT_INDEX_FILE
  git reset -q -- path/you/changed other/path   # sync the real index with the new HEAD
  ```

  This leaves other people's staged and unstaged changes alone.
- **Moving a feature from bring-up into a package:** bump the package `version`, enable nothing that isn't hang-safe, and delete the bring-up blacklist from `/etc/modprobe.d` on the phone. Stale ones override the package's options.
- **Kernel releases change with every push** (`7.3.0-rc6-omandroid-push1-NNNNN-g<sha>`). `bin/omandroid push` runs `modules-push` when the tarball's checksum differs. Without its modules a new kernel boots without its drivers, the GPU among them.

## 3. How the tools fit together

```
laptop                                              phone (172.16.42.1, root over USB)
------                                              ----------------------------------
bin/omandroid kernel   -> Image, dtbs, modules  (docker build env)
bin/omandroid modules  -> modules-<rel>.tar.zst
bin/omandroid initramfs-> Alpine + dropbear + device/cheetah/initramfs/init
                          (storage guard, USB gadget, ssh, switch_root to Arch on userdata)
ov <overlay...>        -> DTB = default + device/cheetah/overlays/*.dtso (fdtoverlay)
bin/omandroid images   -> boot/init_boot/vendor_boot/vendor_kernel_boot/dtbo .img
bin/omandroid push     -> modules-push, dd into *_b, sha256 verify, reboot-to omandroid
bin/omandroid flash    -> the same images through fastboot (first install, recovery)
                                                    omandroid-boot-success marks slot B good
tools/phone-ssh CMD    -> run anything; stream files with  ssh 'cat > f' < f
```

| Tool | Use |
| --- | --- |
| `bin/omandroid capture` | Stock facts over adb/fastboot (live DT, dmesg, iomem with root) into `~/android/reference` (never commit) |
| `bin/omandroid kexec` | Try a kernel without flashing (USB does not come back after kexec on cheetah) |
| `bin/omandroid fastboot` | Reach fastboot without buttons: adb, `reboot-to bootloader`, or a crash that falls back to slot A |
| `tools/wifi-w1-capture`, `acpm-stage`, `aoc-stage`, `fingerprint-capture` | Staged bring-up: kmsg streamed to `logs/` first, optional `--watchdog` feeder, `--pstore` afterwards |
| `tools/usbc-deadman` (+ `usbc-deadman-phone`) | USB-C/charger steps under a dead-man switch; `dump` is read-only |
| `tools/display-hz` | Read-only refresh-rate measurement from DECON's frame counter |
| `tools/power-ab` | On-phone A/B battery-drain test (runs detached; the cable is out) |
| `tools/bt-uart-test`, `cs35l41-id`, `ff-rumble`, `usf.py` | On-phone probes, streamed with `tools/phone-ssh python3 - < tool` |
| `tools/extract-vendor-firmware`, `extract-vendor-chroot`, `extract-fingerprint-vendor` | Google's files from the user's own factory image, on the laptop |
| `tools/phone-install-package packages/X` | Build a package on the phone and install it |
| `tools/repo-build`, `tools/repo-push` | Maintainer only: the signed `[omandroid]` repository (needs `keys/`, never committed) |
| `tools/publish-kernel` | Maintainer only: publish `omandroid` to GitHub on a squashed upstream base |

Logs from these tools land in `logs/` (gitignored). Quote the relevant lines in the plan, not whole logs, and check them for identifiers first.

## 4. Gotchas we hit on gs201

Each entry gives the gotcha, then the reason or the fix. Details are in the linked plan.

### Boot chain and device tree

- **ABL ignores the `vendor_boot` cmdline:** put kernel arguments in `/chosen/bootargs`. ABL appends `console=null`, so a panic is invisible: use `panic=10`. [BRINGUP-M1](device/cheetah/BRINGUP-M1.md)
- **ABL leaves both cluster watchdogs running:** the phone resets at about 60 s of uptime unless `s3c2410_wdt` takes them over at probe.
- **ABL picks the base DTB by `soc_id`:** `bin/omandroid images` ships both silicon revisions. It also needs an empty `/ect` node and `/chosen/bootargs`, and applies a DPM overlay that needs label stubs (build with `-@`).
- **`reboot -f` and busybox `reboot` hang:** use `reboot-to <reason>` (`LINUX_REBOOT_CMD_RESTART2`). ABL often ignores the `bootloader` reason anyway.
- **Reserved memory on gs201 is `#address-cells = <2>`, `#size-cells = <1>`,** so each `reg`/`alloc-ranges` entry is 12 bytes. A 16-byte value is silently ignored, and the pool lands anywhere. The display pool's `alignment` must be two cells too, or `of_reserved_mem` rejects it. `/proc/device-tree` shows the raw property, so it *looks* right. [WIFI-BATTERY-PLAN](device/cheetah/WIFI-BATTERY-PLAN.md) 9.x, [NOTES](device/cheetah/NOTES.md)
- **Check every stock `reserved-memory` region against `/proc/iomem`:** five were plain System RAM in our kernel, and firmware writes into them at runtime.
- **gs201 EINT numbering skips EINT19:** from EINT20 the GIC SPI is the EINT number minus one. gs201 SPIs differ from gs101's, so never copy IRQ numbers.
- **USI IPCLK gates need `CLK_SET_RATE_PARENT`:** without it, SPI ran from the undivided 400 MHz source and never shifted a byte.

### Registers that abort the SoC

- **PMU G3D (`0x18061e00`-`0x18062010`) from `/dev/mem`:** an immediate crash. [GPU-PLAN](device/cheetah/GPU-PLAN.md)
- **The AoC PCU (`0x19a00000`) while the AoC's A32 is in reset:** an abort. Also never read the AoC carve-out after the firmware is loaded: it is locked. [AOC-PLAN](device/cheetah/AOC-PLAN.md)
- **PCIe ELBI while the PHY is isolated:** the SoC hangs. Reading HSI2 SysMMU/S2MPU register groups can hang it too: raise the probe one group per run. [MODEM-PLAN](device/cheetah/MODEM-PLAN.md), [WIFI-BATTERY-PLAN](device/cheetah/WIFI-BATTERY-PLAN.md)

### Display

- **Google's DPP format codes are named by byte order:** DRM `XRGB8888` is DPP code 4. Code 7 gives a green screen. [DISPLAY-PLAN](device/cheetah/DISPLAY-PLAN.md)
- **The panel is DSI command mode:** a frame goes out only on a TE-triggered DECON trigger. The initramfs unmasks `TRIG_CON` for simplefb. That write is cheetah-specific: never run it on another device.
- **A CRTC check must not demand a primary plane on a CRTC being turned off,** or DPMS off and `remove_fb` fail with -EINVAL.
- **Hyprland refused DPMS commits while a flip was in flight,** and gave up after one retry. Our `packages/hyprland` patch keeps retrying. [packages/hyprland/README.md](packages/hyprland/README.md)
- **Hyprland 0.56 on Omarchy uses the Lua config,** so dispatchers take Lua syntax: `hyprctl dispatch 'hl.dsp.dpms({ action = "disable" })'` (or `"enable"`), not `dpms off`.

### Buses and drivers

- **Exynos HSI2C gave every message a fixed 100 ms timeout:** large writes (the 20 KiB CS40L26 firmware block) timed out. Fixed by scaling the timeout with the message length in `i2c-exynos5`.
- **`cs_dsp_coeff_write_ctrl()` returns 1 for "changed":** that is not an error. cs_dsp's write sequence treated it as one.
- **regmap takes `max_raw_write` from the bus, not the config, when the map has a bus:** capping it in the driver's `regmap_config` did nothing. The fix belonged in the I2C host.
- **The HSI2 SysMMU and S2MPU select by VID, and PCIe (AxID 0x0) and UFS (AxID 0x2) both arrive on VID 0:** translating VID 0 starved storage and wedged the phone. Wi-Fi ships with a restricted DMA pool instead, and the driver refuses VID 0. [WIFI-BATTERY-PLAN](device/cheetah/WIFI-BATTERY-PLAN.md) W4
- **ACPM reads its channel table from APM SRAM, and some channels are unusable** (a type-2 buffer channel with queues in DRAM): skip them rather than failing the probe. DVFS is channel 0, PMIC 2, thermal 9. Upstream supports polling only. [ACPM-PLAN](device/cheetah/ACPM-PLAN.md)
- **The regulator core turns off unused rails that have constraints about 30 s after late init:** load PMIC regulator modules after that, or make sure the rails are claimed. [GNSS-PLAN](device/cheetah/GNSS-PLAN.md)
- **The AoC starts only through Trusty** (`com.android.trusty.gsa.hwmgr.aoc`). The GSA mailbox `START` leaves the A32 held. So Trusty is a dependency of audio and sensors, not just of fingerprint.
- **Set the Bluetooth address only after powering the controller on:** set on a never-powered controller, the kernel withdrew the index for good.
- **brcmfmac on BCM4389 needs control-ring D3 messages:** this firmware ignores the TCM mailbox. Unload Wi-Fi for suspend tests until that lands. [SUSPEND-PLAN](device/cheetah/SUSPEND-PLAN.md)

### USB

- **The MAX77759 opens the USB2 data switch on unplug, and nothing closes it until a Type-C driver owns the chip:** the phone stays off the bus after a replug. `omandroid-usb-rescue` closes it while VBUS is valid. Tests that need the cable out (`power-ab`) must run detached and must not assume USB comes back. [USB-C-PLAN](device/cheetah/USB-C-PLAN.md)
- **USB doesn't come back after `kexec`.**
- **PID 1 must never exit:** a missing busybox applet once made init exit, and the resulting panic looked like a USB fault because of `console=null`.

### Userspace

- **`grep -q` under `set -o pipefail`:** `grep -q` exits early, SIGPIPEs the writer, and the pipeline fails on large input. Use `grep -c … >/dev/null`.
- **Omarchy's Chromium launcher splits each line of `chromium-flags.conf` on spaces:** quote a flag whose value has spaces (`"--user-agent=…"`).
- **The screensaver runs in a terminal, so focusing it pops up the on-screen keyboard:** `patches/omarchy/0006-*` turns `org.gnome.desktop.a11y.applications screen-keyboard-enabled` off for the screensaver and back on afterwards. If the keyboard stops appearing, check that key first.
- **Vendor chroots:** bootstrap binaries such as `servicemanager` use `/system/bin/bootstrap/linker64` as their interpreter. `extract-vendor-chroot` links it to the runtime APEX linker. Run the chroot by path, without `env chroot`.
- **Quickshell plugins:**
  - live reload can keep the old code, so run `omarchy-restart-shell`;
  - pointer handlers declared directly on a window get no events, so put them on an Item inside it;
  - Qt 6.12's `QtQuick/Color` shadows Omarchy's `Commons.Color`, so import `qs.Commons as Commons`.
- **pacman.conf order on aarch64:** `[omandroid]`, then `[omarchy]`, then Arch Linux ARM's repositories, so our Mesa and Omarchy's builds win. Use `omarchy update`, not `pacman -Syu`.
- **Firewall changes** (ufw is on): arm `systemd-run --on-active=90 /usr/bin/ufw disable` first, then check with a fresh SSH connection.

## 5. Where things are

| Path | What |
| --- | --- |
| `device/cheetah/NOTES.md` | Findings from real hardware, newest first |
| `device/cheetah/*-PLAN.md`, `*-RESEARCH.md` | One plan per subsystem: facts, design, gated runbook, results |
| `device/cheetah/overlays/*.dtso` | Bring-up overlays that turn on disabled nodes |
| `device/cheetah/initramfs/init` | Storage guard, USB gadget, SSH, switch to Arch |
| `kernel/configs/omandroid.config` | Config fragment on top of arm64 `defconfig`, commented by plan |
| `packages/omandroid-device-cheetah` | Boot-success marker, Wi-Fi and AoC start scripts, udev, modprobe and systemd policy |
| `packages/omandroid-shell`, `-sensors`, `-gnss`, `mesa`, `hyprland`, `omandroid-keyring` | Userspace packages |
| `patches/omarchy/` | Omarchy changes waiting to land upstream |
| `docs/DEVICES.md` | Supported-devices matrix |
| `~/android/mainline/wt-*`, `out-*` | Kernel worktrees and build outputs (outside the repo) |
| `~/android/reference/` | Stock captures and partition backups: private, never committed |
