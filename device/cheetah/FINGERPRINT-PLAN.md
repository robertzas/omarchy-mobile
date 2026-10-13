<!-- SPDX-License-Identifier: MIT -->
# Fingerprint plan (cheetah / gs201): fingerprint unlock on the lock screen

Status (2026-10-12): **offline work done, nothing run on the phone for
fingerprint yet.** Kernel branch `omandroid-fingerprint` in
`~/android/mainline/wt-fingerprint` @ `1e5a4a701`, output
`~/android/mainline/out-fingerprint`, release
`7.3.0-rc6-omandroid-push1-00295-g1e5a4a7011b6` (images and modules built).
The branch now contains `omandroid-int` @ `3ff963085` and **merges into int
cleanly** (section 1; rechecked against int @ `908670416`, which has moved on
with NFC). Next step for the human: **FB, then F1** (section 6).

The research, the architecture and the evidence are in
[FINGERPRINT-RESEARCH.md](FINGERPRINT-RESEARCH.md) (sections 1-6). This plan
supersedes its section 7 runbook: Trusty already runs on int (the AoC starts
through it, [AOC-PLAN.md](AOC-PLAN.md) C4t/C5), so the old F2 is mostly done,
and the steps below add the pieces built since.

**Goal.** Omarchy's lock screen accepts a finger on the under-display sensor
as an alternative to the PIN/password. Omarchy's lock already runs a second
PAM conversation, `omarchy-lock-fingerprint` (`pam_fprintd`), whenever
`fprintd-list $USER` shows an enrolled finger, so the end of the chain is
stock fprintd. Everything between fprintd and the sensor is ours or Google's:

```
Omarchy lock (Quickshell PAM "omarchy-lock-fingerprint") / sudo / polkit
  -> fprintd -> libfprint driver omandroid_udfps        packages/libfprint
       | /run/omandroid-fp/sock/bridge.sock (root only, line protocol)
  -> omandroid-fp-bridge (bionic, in the chroot)        fingerprint/bridge
       | AIDL over vndbinder
  -> Goodix HAL, Trusty KeyMint + Gatekeeper, storageproxyd  (Google's, from
     the user's factory image; packages/omandroid-fingerprint runs them)
       | /dev/trusty-ipc-dev0, /dev/goodix_fp, /dev/sg (RPMB), dma_heap
  -> Trusty: g7.app (capture, matching, templates), KeyMint, Gatekeeper
```

---

## 0. Where things stand

| Piece | State |
|---|---|
| Trusty driver (`trusty_core/log/ipc/virtio`) | **On the phone** (int): loaded by `omandroid-aoc-start`; `/dev/trusty-ipc-dev0` exists; `hwmgr.aoc` answers |
| Trusty CPU hotplug (`kthread_set_per_cpu`, `allow_cpu_offline=0`) | In int. Nothing in Omandroid takes CPUs offline today; keep it that way (section 4) |
| `goodix-fp` (`/dev/goodix_fp`, netlink 25) | Built, not run. Blacklisted from autoload |
| Sensor supply S2MPG13 LDO15S | **New**: described under `pmic-2` (stock range 2.5-3.3 V) and wired as the sensor's `vdd-supply`. The sub-PMIC path is proven by GNSS G1/G2 |
| PERIC0 pinctrl (reset `gpp1-1`) | In int already, enabled (Bluetooth uses it) |
| Panel LHBM (`local_hbm_mode`, `local_hbm_max_timeout`) | **Redone** on int's panel driver (prepare/unprepare, refresh-rate switching), built, not run |
| Chroot runner, preload shim | Built; runner now loads `sg`/`system_heap`/`goodix_fp` itself, binds the DMA heap, skips the app loader when g7.app is already up, runs the bridge |
| `omandroid-fp-bridge` | **New**, builds warning-free against the image's libbinder_ndk; cannot run off the phone |
| libfprint `omandroid_udfps` | **New**, builds warning-free in libfprint 1.94.100; passes 19 checks against a fake bridge (`packages/libfprint/test/run`) |
| fprintd, PAM, lock UI | Stock fprintd and Omarchy's PAM file; lock-screen polish is F11 |

## 1. Kernel: merge state

`omandroid-fingerprint` had six commits that int did not (the first five
fingerprint commits reached int earlier through `omandroid-aoc`). Against
int @ `3ff963085`, `git merge-tree` found four conflicts:

| File | Cause | Resolution |
|---|---|---|
| `gs201.dtsi` | int got the Trusty node (identical, `477a82e16`) and the PERIC0 pin controller with all banks (`523b1e0e0`, `b5f61a9bc`) from other branches | int's version |
| `gs201-pinctrl.dtsi` | the same PERIC0 banks | int's version |
| `gs201-cheetah.dts` | battery and modem lines added next to the fingerprint node and pins | keep both |
| `panel-samsung-s6e3hc4.c` | int added a panel lock, `prepared`, prepare/unprepare and refresh-rate switching (display branches) | int's driver, LHBM redone on top (below) |

Resolved as one back-merge on the branch, `2b97a385b` ("Merge omandroid-int
into omandroid-fingerprint"), as `omandroid-modem` does. After it,
`git merge-tree omandroid-int omandroid-fingerprint` is clean (also against
int @ `908670416`, after the NFC merge).
The redundant DT commits (`0c28d9948` Trusty node, `4d4c7bef5` PERIC0
pinctrl) stay in history but add nothing; drop them when curating for
`omandroid`.

LHBM on int's panel driver: `guard(mutex)` throughout; LHBM refused unless
the panel is prepared, displayed, unblanked, at brightness > 0 and
`allow_lhbm=1`; turned off (`s6e3hc4_lhbm_stop()`) by `disable()`,
`unprepare()`, blanking and brightness 0; the off timer is set up after the
backlight device so devres cancels it first.

New commit `1e5a4a701` "gs201-cheetah: supply the fingerprint sensor":
`ldo15s` (`vdd_udfps`, 2.5-3.3 V) under `pmic-2`, `vdd-supply = <&ldo15s>`
on the sensor. Both nodes stay disabled by default.

Checks (laptop): `bin/omandroid kernel`, `modules`, `initramfs`, `images`
exit 0 (`logs/fp-*-ldo15s.log`); `W=1` on `panel-samsung-s6e3hc4.o` and
`goodix-fp.o`: no warnings (`logs/fp-w1.log`); checkpatch `-f` on the panel
driver: clean (the commit trailer warnings are the usual no-Signed-off-by
ones); `dt-validate` (dtschema 2026.9) on the default DTB and on
default + `aoc-core-test` + `fingerprint-sensor`: only the existing
`soc_id` and framebuffer `post-init-providers` reports.

## 2. Userspace built offline

| Path | What | Tested on the laptop |
|---|---|---|
| `fingerprint/bridge/omandroid-fp-bridge.c` | The HAL's client (FingerprintService + keystore + SystemUI's part): one session, shared secret, Gatekeeper tokens for enrollment, touchscreen + LHBM, the line protocol | Builds (`-Wall -Wextra -Werror`, bionic, against the image's `libbinder_ndk.so`); needs binder and the HAL to run |
| `fingerprint/Makefile` | Shim and bridge, `CLANG= BIONIC= CHROOT=` (the LineageOS tree's clang and bionic) or `NDK=` | Yes |
| `packages/omandroid-fingerprint/` | Runner, `omandroid-tipc-probe`, `omandroid-fp-ctl`, props, `omandroid-fp.service` (not enabled), fprintd drop-in (`FP_OMANDROID_UDFPS`) | `test/all` passes; `omandroid-fp-ctl` against a fake bridge; the probe's ioctl path (ENOTTY on `/dev/null`) |
| `packages/libfprint/` | Upstream 1.94.100 + `omandroid_udfps` (`omandroid-udfps.c`, meson patch) | `test/run`: 19/19 (enroll with retries, list, verify match/other id/no match, identify, lockout, cancel, delete, missing print, bridge lost) |

Build the bionic programs before packaging (they are not committed):

```sh
cd ~/Projects/omandroid
tools/extract-fingerprint-vendor -o out/fingerprint-vendor ~/android/factory/cheetah-*/image-cheetah-*.zip
make -C fingerprint CLANG=$(ls -d ~/android/omandroid/prebuilts/clang/host/linux-x86/clang-r* | sort | tail -1)/bin/clang \
  BIONIC=$HOME/android/omandroid/bionic/libc CHROOT=$PWD/out/fingerprint-vendor/root \
  OUT=$PWD/packages/omandroid-fingerprint/prebuilt
packages/omandroid-fingerprint/test/all
packages/libfprint/test/run
```

Findings that shaped these (from the vendor binaries and our captures):

- `trusty_apploader` hands `g7.app` to Trusty in a dma-buf from
  `libdmabufheap` (`/dev/dma_heap/system`, `CONFIG_DMABUF_HEAPS_SYSTEM=m`,
  module `system_heap`). The research chroot did not bind it.
- The vendor tree ships its own `libbinder.so` (`__ANDROID_VNDK__`, default
  driver `/dev/vndbinder`), and the runner puts `/vendor/lib64` first for
  vendor binaries. So the HALs register with `vndservicemanager`, and the
  bridge runs with the same search order to find them there.
- Port names, read from the binaries: `com.android.trusty.apploader`,
  `.keymaster`, `.gatekeeper`, `.storage.proxy`, `com.goodix.fingerprint.test`.
  A connect-only probe of `storage.proxy` would look to Trusty like
  storageproxyd arriving, so `omandroid-tipc-probe` refuses that port.
- A load request that timed out can still complete inside Trusty once storage
  comes up; a second load then fails with "port already registered". The
  runner probes the app's port first.
- The HAL allows one session; the bridge holds it for its whole life and is
  the only client. fprintd reaches it only through the bridge.

## 3. Effort and blockers, honestly

| Item | Risk | Notes |
|---|---|---|
| **Secure storage (F4)** | **Irreversible**, human decision | The first `storageproxyd` run writes the RPMB (write counter, super blocks). Stock's TD state is already gone with the old userdata; TP/TDP are reused. Decide TDP before F4 (section 5) |
| TA load (F5) | Medium | Depends on F4. Fails silently if storage is not up (the loader waits 60 s). dma heap handled; the memref oops of the first run is fixed in `b9af5fe2d` |
| Sensor power (F6) | Low-medium | LDO15S over ACPM like the GNSS rails. Its voltage at hand-off is unknown: FB2 reads it before any kernel change |
| HAL dependencies (F6c) | Medium | Absent services are short-circuited by the shim; KeyMint wants version and patch-level properties (system and vendor `build.prop` give them); `mfg_data` is a read-only copy. Expect one or two shim/props iterations |
| LHBM (F7) | Medium | No TE-aligned trigger and no peak-refresh switch yet (Google's driver does both); int can now switch 60/120 Hz, so F7 tries 60 Hz first, then 120 Hz. Stop on flicker or a wrong circle |
| Touch over the sensor | UX | The lock surface also receives the finger; the lock's PIN pad must keep clear of (720, 2360) ± 180 px and should draw the target (F11) |
| Lockout | Policy | Timed lockout is the TA's; permanent lockout needs `RESETLOCKOUT`, which the bridge can do with its own Gatekeeper secret. Only allow it after a password unlock (F11) |
| CPU offline | Must hold | g7.app pins itself to CPUs 4 (idle) and 6 (operations); `trusty_core.allow_cpu_offline=0` refuses runtime offlining. Any future power hook must not offline CPUs |
| Dual boot | Accepted | Fingerprints and Gatekeeper state do not cross to slot A Android, which needs a factory reset anyway |

Effort from here: about six phone sessions if nothing surprises (FB+F1,
F2-F3, F4-F5, F6, F7-F8, F9-F10), each one boot at most. The likely
surprises are in F6c (what the HAL waits on) and F7 (LHBM timing).

## 4. Rules for this subsystem

- **Never write `persist` or the RPMB without the human's explicit say-so.**
  The first `storageproxyd` run (F4) counts as an irreversible write: ask,
  and record the answer here. Every later start of `omandroid-fp.service` or
  `omandroid-fp-chroot start` also runs storageproxyd: after F4 that is
  normal operation, before F4 it is F4.
- `persist` and `mfg_data` are only ever read (read-only mount, `dd`
  from the by-partlabel node). Never add them to the storage guard's
  `UFS_RW` allowlist without the human's decision (section 5).
- `sg` stays blacklisted from autoload. The runner loads it, binds only the
  RPMB LUN's node into the chroot, and `modprobe -r sg` removes the rest.
- Check the partition backups before F3 (FB, as `MODEM-PLAN.md` M0.1).
- Never commit or paste vendor files, `persist`/`mfg_data` contents,
  enrolled ids from a real finger, or logs with serials. `out/` and `logs/`
  are gitignored; quote only the relevant lines.
- Announce anything visible before running it: F7 and later light a very
  bright circle on the panel.
- Nothing may take CPUs offline at runtime while Trusty is bound.

## 5. Decision needed before F4: where TDP lives

Trusty's tamper-detect-persistent files are on `persist/ss` on stock.

- **A (default, nothing written to `persist`):** F3 copies `persist/ss` once
  (read-only) to `/var/lib/omandroid-fp/persist-ss`; the chroot serves that
  copy. Linux and the RPMB stay consistent; the real `persist/ss` goes stale,
  so a later stock Android may see its TDP state as rolled back (it needs a
  factory reset anyway).
- **B:** let Linux write the real `persist/ss` (a guard allowlist change and
  a read-write mount of `persist`). Consistent for both systems, at the cost
  of writing a calibration partition. Only with the human's explicit go.

Record the decision and the date here before F4.

**Decision (2026-10-13):** the human gave the go for F4 (the first RPMB
write from Linux), with **A**: Trusty's TDP files are served from F3's
read-only copy, and nothing is written to `persist`.

## 6. Runbook

Variables (laptop):

```sh
cd ~/Projects/omandroid
O=~/android/mainline/out-int D=$O/arch/arm64/boot/dts/exynos/google/gs201-cheetah.dtb
export KERNEL_DIR=~/android/mainline/wt-int KERNEL_OUT=$O
# ov NAME...: CONTRIBUTING.md section 4 (default DTB + overlays, then images)
# OVL = the overlays the phone boots with today; it must include aoc-core-test
# (Trusty) and gnss-pmic-test (pmic-2), e.g.
OVL="gnss-pmic-test gnss-test aoc-core-test audio-amps-test aoc-sound-test"
```

### FB: backups (read-only, before anything else; risk none)

FB1, the M0.1 check against the latest off-repo backup:

```sh
tools/phone-ssh 'for p in efs efs_backup modem_userdata persist modem_a modem_b; do
  printf "%s  %s.img\n" "$(sha256sum < /dev/disk/by-partlabel/$p | cut -d" " -f1)" "$p"; done' > logs/fb-partitions.sha256
sort -k2 ~/android/reference/cheetah-partition-backup-20261012-radio/SHA256SUMS | grep -E ' (efs|efs_backup|modem_userdata|persist|modem_a|modem_b)\.img$' |
  diff - <(sort -k2 logs/fb-partitions.sha256)
```

Pass: no diff (or a diff explained by a stock boot since, then a fresh
read-only backup first). **Stop** if there is no backup.

FB2, LDO15S as it is now, on the kernel the phone runs (pmic-2 bound by
`gnss-pmic-test`; register `0x3a` is `L15S_CTRL`):

```sh
tools/phone-ssh 'grep "^3a:" /sys/kernel/debug/regmap/*pmic-2*pmic*/registers; grep "^3[4-6]:" /sys/kernel/debug/regmap/*pmic-2*pmic*/registers'
```

Expect bit 7 clear (off). Voltage = 1.8 V + 25 mV × (value & 0x3f). Pass:
inside 2.5-3.3 V (0x1c-0x3c), so registering `ldo15s` in F1 writes nothing.
If outside: the regulator core will set it to 2.5 V at F1's boot (stock's
kernel does the same with the same constraints); note it here and decide.
**Stop** if the regmap file is missing (pmic-2 not bound: use the FB2 read
after F1 with `gnss-pmic-test` instead).

**FB result (2026-10-12, 7.3.0-rc6-omandroid-push1-00306-g60d3ca176c80).**
FB1 passed: all six partitions match
`~/android/reference/cheetah-partition-backup-20261012-radio/SHA256SUMS`.
FB2 hit its stop condition: no `pmic-2` regmap in debugfs on this boot.
The sub-PMIC binds with the GNSS power stack, which loads only while
Location is in use, so read FB2 with GNSS running (`omandroid-gnss force`,
then the read, then `unforce`), or after F1 as the note says.

**FB2 result (2026-10-12, same kernel, read while GNSS ran so pmic-2 was
bound): passed.** `L15S_CTRL` (0x3a) = 0x3c: bit 7 clear (off), 1.8 V + 25
mV × 0x3c = 3.3 V, inside 2.5-3.3 V. Registering `ldo15s` writes nothing.

### F1: int + fingerprint kernel, overlays as today (one boot; risk low)

The human merges and builds int (the branch is int + 7 commits):

```sh
git -C ~/android/mainline/wt-int merge omandroid-fingerprint      # clean (merge-tree checked)
bin/omandroid kernel && bin/omandroid modules && ov $OVL
tools/phone-ssh 'ls /usr/lib/modprobe.d /etc/modprobe.d | grep -c fingerprint'   # the blacklist must be there
bin/omandroid push                                                  # reboots
tools/phone-ssh 'uname -r; lsmod | grep -E "^(trusty|goodix_fp|sg) "; ls /sys/class/backlight/*/local_hbm_mode;
  cat /sys/class/backlight/*/local_hbm_mode /sys/class/backlight/*/local_hbm_max_timeout;
  cat /sys/class/regulator/*/name | grep -c vdd_udfps; dmesg | grep -iE "s6e3hc4|ldo15|vdd_udfps" | tail'
```

Expect: boots as before (display, touch, USB, the AoC up); `trusty_*` loaded
by `omandroid-aoc-start`, no `goodix_fp`, no `sg`; `local_hbm_mode` 0,
`local_hbm_max_timeout` 3000; one `vdd_udfps` regulator. A write of 1 to
`local_hbm_mode` fails with "Operation not permitted" (`allow_lhbm=0`).
Then exercise the panel paths that changed (announce: the screen blanks):
`hyprctl dispatch 'hl.dsp.dpms({ action = "disable" })'`, then `"enable"`, and
a brightness change. **Stop**: no boot, display or touch regressions, any
panel error in dmesg, the blacklist count 0 (install the device package
first). Rollback: `cp "$D.default" "$D"`, rebuild int without the merge
(`git -C ~/android/mainline/wt-int reset --hard <previous int>` is the
human's call), push; or let ABL fall back to slot A.


**F1 result (2026-10-12, 7.3.0-rc6-omandroid-push1-00317-gdea700f6eec2):
passed.** int with `omandroid-fingerprint` merged (`dea700f6e`), overlays as
before. `goodix_fp` and `sg` not loaded (blacklisted); `local_hbm_mode`
reads 0, and writing 1 is refused ("Operation not permitted",
`allow_lhbm=N`). No `vdd_udfps` regulator: pmic-2 binds only with the GNSS
power stack, as FB2 found, so that check moves to the first GNSS-on boot.
Display: brightness 512 → 256 → 512 fine; the power key turns the panel
fully off and wakes to the PIN pad (the human). A DPMS-off sent by hand
through `hyprctl dispatch` over two shell layers left the last frame on
screen; that was the test command, not the panel, so use the power key for
this check.

### F2: Trusty for fingerprint (read-only; risk low)

```sh
tools/phone-ssh 'dmesg | grep -iE "trusty (version|.*api version)|trusty_ipc|trusty-virtio" | head; ls -l /dev/trusty-ipc-dev0 /dev/trusty-log0'
tools/phone-ssh 'cat /sys/module/trusty_core/parameters/allow_cpu_offline'
tools/phone-ssh 'python3 - apploader keymint gatekeeper' < packages/omandroid-fingerprint/lib/omandroid-tipc-probe
```

Expect "Project: cloudripper", API version 5, "is online"; `N`; three ports
`open` (connect and close, no message). `goodix` is not open yet (the app is
not loaded). **Stop** on a refused port or a hung probe (a connect waits at
most a few seconds). Rollback: none needed.

F2c (one change, reversible): CPU hotplug refusal.

```sh
tools/phone-ssh 'echo 0 > /sys/devices/system/cpu/cpu7/online; echo rc=$?; cat /sys/devices/system/cpu/online; dmesg | tail -2'
```

Expect "write error: Device or resource busy", CPUs 0-7 online, "refusing to
take cpu 7 offline". If CPU 7 went offline: `echo 1 > .../cpu7/online` and
**stop** (the guard is not active).

**F2 result (2026-10-12, 7.3.0-rc6-omandroid-push1-00365-g23c2869425ea,
unattended): passed.** "trusty version: Project: cloudripper", "selected api
version: 5", trusty-virtio initialised; /dev/trusty-ipc-dev0 and
/dev/trusty-log0 present; `allow_cpu_offline` N; the probe opened
`com.android.trusty.apploader`, `.keymaster` and `.gatekeeper` (connect and
close). F2c: `echo 0 > cpu7/online` → "Device or resource busy", online
0-7, "refusing to take cpu 7 offline (trusty_core.allow_cpu_offline=0)".

**Before F3 (not run):** this root has no `/dev/disk/by-partlabel`; find
`persist` and `mfg_data` by `PARTNAME` (as MODEM-PLAN M0). And a read-only
ext4 mount still replays a dirty journal, which writes to the partition:
mount `persist` with `-o ro,noload` (or read the files with `debugfs`, as
the speaker calibration does), never plain `-o ro`. Waits for the human.

### F3: the RPMB node and read-only copies (no writes; risk low)

```sh
tools/phone-ssh 'modprobe sg; for d in /sys/class/scsi_generic/sg*; do echo "$d $(basename $(readlink -f $d/device))"; done'
tools/phone-ssh 'install -d -m 0700 /var/lib/omandroid-fp &&
  dd if=/dev/disk/by-partlabel/mfg_data of=/var/lib/omandroid-fp/mfg_data.img bs=1M status=none &&
  mkdir -p /mnt/persist-ro && mount -o ro /dev/disk/by-partlabel/persist /mnt/persist-ro &&
  install -d -m 0700 /var/lib/omandroid-fp/persist-ss && cp -a /mnt/persist-ro/ss/. /var/lib/omandroid-fp/persist-ss/;
  umount /mnt/persist-ro; ls -la /var/lib/omandroid-fp /var/lib/omandroid-fp/persist-ss | head'
tools/phone-ssh 'cat /dev/disk/by-partlabel/persist' > ~/android/reference/cheetah-persist-$(date +%F).img
tools/phone-ssh 'cat /dev/disk/by-partlabel/mfg_data' > ~/android/reference/cheetah-mfg_data-$(date +%F).img
chmod 600 ~/android/reference/cheetah-{persist,mfg_data}-$(date +%F).img
tools/phone-ssh 'modprobe -r sg'
```

Expect one sg node at `0:0:0:49476` (the RPMB well-known LUN). Pass: the
copies and backups exist (sizes match the partitions). **Stop** if `persist`
mounts read-write or the storage guard complains. Rollback: `modprobe -r sg`.

### F4: secure storage (IRREVERSIBLE: the first RPMB write from Linux)

**Ask the human; record the yes and the section 5 choice here first.**
The staged runs use the transient unit `omandroid-fp-stage`. The package
ships its own `omandroid-fp.service` (disabled, the full bridge), so
`systemd-run --unit=omandroid-fp` fails with "already loaded or has a
fragment file".


Install the package and the vendor tree (installing writes nothing to
Trusty):

```sh
tools/phone-install-package packages/omandroid-fingerprint
tar -C out/fingerprint-vendor -cf - root MANIFEST SOURCE | tools/phone-ssh 'tar -C /usr/lib/omandroid-fp -xf -'
tools/phone-ssh '/usr/lib/omandroid-fp/omandroid-fp-chroot check'
# --- the irreversible step ---
tools/phone-ssh 'systemd-run --unit=omandroid-fp-stage -p KillMode=control-group /usr/lib/omandroid-fp/omandroid-fp-chroot start storage'
tools/phone-ssh 'sleep 10; journalctl -u omandroid-fp-stage -b --no-pager | tail -40; cat /dev/trusty-log0 2>/dev/null | tail -20'
```

Expect `check`: "preconditions met", RPMB `/dev/sgN`. Then
`[servicemanager]`, `[vndservicemanager]`, `[storageproxyd]` handling RPMB
requests, "secure storage ready"; Trusty's log mounting tp/td/tdp (td new,
the others loaded); files under `/var/lib/omandroid-fp/data/vendor/ss`.
**Stop** on storageproxyd errors or RPMB authentication failures ("MAC
mismatch", result codes): do not retry in a loop, collect the log. Rollback:
`systemctl stop omandroid-fp-stage` (RPMB contents cannot be rolled back).

### F5: the TA (one change; risk low)

```sh
tools/phone-ssh 'systemctl stop omandroid-fp-stage; systemd-run --unit=omandroid-fp-stage -p KillMode=control-group /usr/lib/omandroid-fp/omandroid-fp-chroot start apploader'
tools/phone-ssh 'sleep 5; journalctl -u omandroid-fp-stage -b --no-pager | grep -E "g7|apploader|storage" | tail; python3 - goodix' < packages/omandroid-fingerprint/lib/omandroid-tipc-probe
```

Expect "loading g7.app" then "g7.app loaded" within seconds (stock: 0.32 s),
the `goodix` port `open`. **Stop** on a 60 s timeout (storage not up) or a
policy failure in Trusty's log. Rollback: stop the unit; the app stays
loaded until reboot (harmless).

#### F5 first run (2026-10-13): kernel oops in the memref path; fixed, re-run

The first F5 (on int `7.3.0-rc6-omandroid-push1-00395-g6c0e876bd580`, after
F4 passed) oopsed in the kernel as soon as `trusty_apploader` sent `g7.app`:
a level 1 translation fault at `ffff801000000000` in
`dcache_clean_poc_nosync`, called from `dma_direct_map_sg` <-
`trusty_transfer_memory` <- `tipc_ioctl`. The heap was not the problem:
the loader allocates from `/dev/dma_heap/system` (ordinary linear-mapped
pages). The Trusty driver mapped the dma-buf twice: once properly, through
the attachment, and then again with `dma_map_sg()` on the table it got back.
The second mapping reads the table's struct pages, which an importer must
not use, and our config has `CONFIG_DMABUF_DEBUG=y` (the default with
`DEBUG_KERNEL`): the dma-buf core then hands importers a copy of the table
with only DMA addresses and NULL pages. A NULL page became a physical
address far outside RAM (`0x801080000000`), and the cache clean for it
faulted. Google's 6.1 kernel builds without that check, which is why the
same code works on stock.

Fix: `omandroid-fingerprint` `b9af5fe2d` "trusty: share a dma-buf by its
attachment's DMA addresses". The memref path now shares the attachment's
DMA addresses (dma-direct, no offset, so they are the physical addresses
FF-A wants) and no longer maps a second time; new
`trusty_transfer_mapped_memory()`/`trusty_reclaim_mapped_memory()`, other
callers unchanged. Built in `out-fingerprint`
(`7.3.0-rc6-omandroid-push1-00296-gb9af5fe2d95d`), W=1 clean for
`drivers/trusty`, checkpatch clean apart from the Signed-off-by the human
adds; `git merge-tree` against `omandroid-int` is clean.

**F5 re-run** (after the human merges `omandroid-fingerprint` into int,
builds int and pushes it; one boot; risk low). Storage must come up first,
as in F4; the TDP choice and the RPMB state are unchanged:

```sh
tools/phone-ssh 'uname -r; grep -c trusty_transfer_mapped_memory /proc/kallsyms'
tools/phone-ssh 'systemd-run --unit=omandroid-fp-stage -p KillMode=control-group /usr/lib/omandroid-fp/omandroid-fp-chroot start apploader'
tools/phone-ssh 'sleep 5; journalctl -u omandroid-fp-stage -b --no-pager | grep -E "g7|apploader|storage" | tail; dmesg | grep -E "trusty|Unable to handle|Internal error" | tail -20'
tools/phone-ssh 'python3 - goodix' < packages/omandroid-fingerprint/lib/omandroid-tipc-probe
```

Expect: the new release, a non-zero `kallsyms` count (`trusty_core`
loaded with the fix), "loading g7.app" then "g7.app loaded" within seconds,
no oops, the `goodix` port `open`, and Trusty's log showing the app
starting. **Stop** on any oops (collect `dmesg` and `--pstore`), on
`trusty_transfer_memory`/`SMC_FC_FFA_MEM_SHARE failed` errors (Trusty
refused the share: note r1/r2), or on a 60 s loader timeout (storage not
up). Rollback: `systemctl stop omandroid-fp-stage`; the app stays loaded
until reboot. The old int kernel must not run F5 again: it oopses the same
way (a reboot recovers; nothing is written).

### F6: sensor power and the HAL

F6a (boot with the sensor node; `goodix_fp` stays blacklisted, so nothing
powers):

```sh
ov $OVL fingerprint-sensor && bin/omandroid push                   # reboots
tools/phone-ssh 'grep -E "vdd_udfps" -A0 /sys/kernel/debug/regulator/regulator_summary;
  for r in /sys/class/regulator/*; do [ "$(cat $r/name)" = vdd_udfps ] && cat $r/state $r/microvolts $r/num_users; done'
```

Expect `vdd_udfps` disabled, a voltage in range, 0 users. **Stop** if it
reads enabled.

F6b (power the sensor once, by hand; risk low-medium):

```sh
tools/phone-ssh 'modprobe goodix_fp; dmesg | grep -i goodix | tail -3; ls -l /dev/goodix_fp'
tools/phone-ssh 'grep goodix /proc/interrupts; python3 -c "import time; f=open(\"/dev/goodix_fp\",\"rb\"); time.sleep(2)";
  grep goodix /proc/interrupts; dmesg | grep -i goodix | tail -4'
```

Expect "irq N, supply switched, netlink 25" at probe, then on open
"enabling sensor supply" (every open also resets the sensor, which answers
with an interrupt: the goodix count in `/proc/interrupts` rises), on close
"disabling sensor supply"; the regulator back at 0 users. **Stop** on
regulator errors or a PMIC fault. Rollback: `modprobe -r goodix_fp` (powers
down), DTB without `fingerprint-sensor`.

F6c (the HAL):

```sh
tools/phone-ssh 'systemctl stop omandroid-fp-stage; systemd-run --unit=omandroid-fp-stage -p KillMode=control-group /usr/lib/omandroid-fp/omandroid-fp-chroot start hal'
tools/phone-ssh 'sleep 15; journalctl -u omandroid-fp-stage -b --no-pager | grep -E "\[fingerprint\]|\[keymint\]|\[gatekeeper\]" | tail -40; grep goodix /proc/interrupts'
```

Expect "HAL/TA version is match", "Initialization successful", the sensor
location near (720, 2360), radius about 120; goodix interrupts counting
after the HAL's resets; KeyMint and Gatekeeper up. **Stop** if a service
waits on a lookup (add its prefix to `OMANDROID_FP_NO_SERVICES` or a prop to
`/var/lib/omandroid-fp/props.conf`, one change per run) or crashes. Rollback:
stop the unit, `modprobe -r goodix_fp`.

### F7: LHBM (announce first: a very bright circle; risk medium)

With the screen on and unlocked:

```sh
tools/phone-ssh 'echo 1 > /sys/module/panel_samsung_s6e3hc4/parameters/allow_lhbm;
  b=$(dirname /sys/class/backlight/*/local_hbm_mode); echo 1 > $b/local_hbm_mode; sleep 4; cat $b/local_hbm_mode; dmesg | tail -2'
```

Expect a bright circle around (720, 2361) for 3 s, then off ("local HBM
timed out"), reads 0. Repeat at 120 Hz if the display stack can switch.
**Stop**: a circle elsewhere, wrong size, flicker that stays, or a panel
that misbehaves after off. Rollback: `echo 0 > .../local_hbm_mode`,
blank/unblank, `allow_lhbm=0`, reboot.

### F8: enroll through the bridge (writes a template to Trusty storage)

```sh
tools/phone-ssh 'systemctl stop omandroid-fp; systemd-run --unit=omandroid-fp -p KillMode=control-group /usr/lib/omandroid-fp/omandroid-fp-chroot start bridge'
tools/phone-ssh '/usr/lib/omandroid-fp/omandroid-fp-ctl status'
tools/phone-ssh '/usr/lib/omandroid-fp/omandroid-fp-ctl --timeout 120 enroll'     # touch the circle again and again
tools/phone-ssh '/usr/lib/omandroid-fp/omandroid-fp-ctl list'
```

Expect "auth-token key agreed", "gatekeeper: enrolled" (first time), then
for each touch FINGER DOWN, ACQUIRED, PROGRESS id N counting down, FINGER
UP, ending ENROLLED id. Tune `OMANDROID_FP_LHBM_SETTLE_MS` (default 120) if
captures come back TOO_DARK. **Stop** on "auth token" refusals (the shared
secret), ERROR 1, or a LOCKOUT. Rollback: `omandroid-fp-ctl delete <id>`.

### F9: verify, then fprintd

```sh
tools/phone-ssh '/usr/lib/omandroid-fp/omandroid-fp-ctl auth'            # enrolled finger: MATCH id
tools/phone-ssh '/usr/lib/omandroid-fp/omandroid-fp-ctl auth'            # another finger: NOMATCH
tools/phone-install-package packages/libfprint                           # our libfprint (builds on the phone)
tools/phone-ssh 'OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm fprintd; systemctl daemon-reload'
tools/phone-ssh 'fprintd-list omandroid; fprintd-enroll -f right-thumb omandroid; fprintd-verify omandroid'
```

Expect fprintd to list the device "Pixel 7 Pro under-display fingerprint
sensor (Omandroid)"; enroll with ~20 stages; verify-match. **Stop** if
fprintd sees no device (the drop-in, `systemctl show fprintd -p Environment`)
or Omarchy's `libfprint-git` replaced ours (`pacman -Q libfprint`).
Rollback: `fprintd-delete omandroid`.

### F10: the lock screen

```sh
tools/phone-ssh 'printf "#%%PAM-1.0\nauth       required                    pam_fprintd.so\naccount    include                     system-local-login\n" > /etc/pam.d/omarchy-lock-fingerprint'
tools/phone-ssh 'systemctl enable omandroid-fp.service'
```

(The PAM file is Omarchy's own `setup_lock_fingerprint_pam`; Omarchy's
`omarchy-setup-security-fingerprint` cannot be used here: it looks for a USB
reader and installs `libfprint-git`.) Lock, wake the screen, touch the
circle: unlocks. The PIN still unlocks; with the service stopped the lock
falls back to the PIN. Rollback: `rm /etc/pam.d/omarchy-lock-fingerprint`,
`systemctl disable --now omandroid-fp`.

### F11: later

- Lock UI: done in F12/F13 (the target over the sensor, the PIN pad clear
  of it, the hint). Left: an LHBM-friendly brightness.
- `RESETLOCKOUT` after a successful password unlock (a PAM session hook).
- sudo and polkit (`pam_fprintd` as in Omarchy's setup, with the password
  fallback).
- Boot ordering: `omandroid-fp.service` after `omandroid-aoc.service`.

### F12: the sensor in the shell (omandroid-fingerprint 0.1.3, omandroid-shell 0.1.32; risk low)

Built offline (2026-10-13): the bridge publishes `/run/omandroid-fp-ui/state.json`
(`--ui-state`, world-readable; the runner binds the directory in and removes
the file at stop, the unit too); `omandroid-shell`'s `omandroid.fingerprint`
draws the target over the sensor during verification, blocks the desktop's
long-press while any operation runs, and has an on-screen enrollment flow
through fprintd (`omandroid-fp-enroll`, polkit first), opened from the
Fingerprint tile in quick settings or Setup > Security > Fingerprint. Design
and the state file's fields: `packages/omandroid-shell/plugins/README.md`.
Checked in the desktop harness with a fake bridge (screenshots), not on the
phone. `omandroid-fp-ctl --timeout` now waits for the bridge's answer to
CANCEL and exits 1 (2 if none comes) instead of raising.

Announce first: the overlay and the enrollment screen change what the screen
shows; enrollment lights the LHBM circle.

```sh
tools/phone-install-package packages/omandroid-fingerprint      # restart the stack:
tools/phone-ssh 'systemctl restart omandroid-fp; sleep 20; cat /run/omandroid-fp-ui/state.json; ls -l /run/omandroid-fp-ui'
tools/phone-install-package packages/omandroid-shell
tools/phone-ssh 'su - <user> -c "omandroid-setup-user"; su - <user> -c omarchy-restart-shell'
```

Expect `{"op":"idle",...,"x":717,"y":2360,"r":121,...}`, the directory 0755
and the file 0644. **Stop** if the file is missing (the bridge logs "ui
state: ..."), or the bridge no longer answers `omandroid-fp-ctl status`.

1. Verify: `fprintd-verify <user>` over SSH. Expect a faint fingerprint
   exactly over the sensor, gone when a finger lands (the LHBM circle takes
   over), back on NOMATCH, gone about a second after the end. Hold a finger
   on the sensor over the empty desktop: no long-press menu; anywhere on the
   wallpaper while verify runs: no menu either; apps and the dock still
   work. **Stop** if the glyph is off the sensor (record `omarchy-shell shell
   call omandroid.fingerprint state ''`) or touches outside the circle stop
   reaching apps.
2. Lock (`omarchy-system-lock`), wake: the glyph shows above the lock; the
   PIN pad still works (with F13 the pad sits clear of the sensor).
3. Enroll from quick settings > Fingerprint: polkit asks for the password,
   then "Touch the sensor", the ring fills with each touch, hints for bad
   touches, "Now place the edges of your finger" past half, "Fingerprint
   added". Then `fprintd-list <user>` shows the new finger, and the lock
   unlocks with it. Cancel midway: the screen closes and `fprintd-list`
   is unchanged. **Stop** on a screen that stays up after the helper exits
   (`pgrep -a omandroid-fp-enroll`).
4. Rotation: with rotation unlocked, turn the phone during `fprintd-verify`:
   the glyph follows the sensor (transforms 1 and 3 are the ones to check;
   if they are swapped, `SensorModel.place` swaps them).

Rollback: `omarchy-shell shell call omandroid.fingerprint closeScreen ''`;
remove `{"id": "omandroid.fingerprint"}` from `~/.config/omarchy/shell.json`;
the previous packages.

### F13: the lock's PIN pad clear of the sensor (Omarchy patch 0003; omandroid-shell 0.1.33; risk low)

Omarchy's number pad (`patches/omarchy/0003`) sat with its 8 key on the
sensor (about 240, 806 logical against 239, 787): a finger on the sensor
typed an 8. 0003 now keeps the lower third of the screen clear when the pad
is on and fingerprints are set up (pad bottom at 34% of the height: 686 of
1040 logical, the sensor circle starts at 747), shrinks the keys if a short
screen needs it, says "Touch the fingerprint sensor or enter your PIN" above
the field, and puts "Fingerprint reader unavailable" in the same place
(under the field is the pad). Without fingerprints the layout is unchanged.
Checked in the desktop harness on Omarchy b83d3df + 0003 + 0004 + 0009, with
a real session lock and the `above_lock` rule:
screenshots show the hint, the pad above the glyph, digits typed from the
keyboard reaching the field, and the unavailable state keeping the layout.
omandroid-shell 0.1.33 only fixes the target's screen choice (a fallback
output) and updates comments.

Versions. The phone runs Omarchy **4.0.4** (package 4.0.4-2;
`/usr/share/omarchy/version` reads `4.0.0.alpha`) with the patch series
applied by hand. The repo's 0003 now targets upstream **b83d3df084** (main
after v4.0.4, the Qt 6.12 `Commons.Color` fix) for `LockView.qml` and
`Keypad.qml`, a newer `LockView.qml` (reader-unavailable notice, video
backgrounds) than the phone's; its `Service.qml` part is still the one made
on the phone's 4.0.4. So the series (0003, then 0004, then 0009) applies to
b83d3df; check 0003 against 4.0.4 too before applying it to a fresh phone, or
rebase it when the phone moves to an Omarchy with b83d3df. 4.0.4 has no
"reader unavailable" state, so the phone's version of the change has no
notice to move.

Deploy (do it unlocked; the shell restarts). The phone takes a delta made
against its own files, `0003-delta-for-phone-4.0.4.patch` (the phone's
`LockView.qml` and `Keypad.qml` as the old 0003 left them, to the same
behaviour as the new 0003). Checked with `patch --dry-run` against the
phone's copies and in the desktop harness on the laptop's Omarchy 4.0.4 with
a real lock (hint, pad above the glyph, digits reach the field). Check the
files first:

```sh
tools/phone-ssh 'cd /usr/share/omarchy/shell/plugins/lock && sha256sum LockView.qml Keypad.qml'
# expect 6fd9c06b877cee601f0c05a986f42084e2c19c887099701b42628178df136fba  LockView.qml
#        c3686101eef63107a3e18a9de069ee187ae1de3d7fdbdc3813a88dd79c084d44  Keypad.qml
tools/phone-ssh 'cd /usr/share/omarchy/shell/plugins/lock && cp LockView.qml /root/LockView.qml.pre-f13 && cp Keypad.qml /root/Keypad.qml.pre-f13'
tools/phone-ssh 'cd /usr/share/omarchy && patch -p1 --dry-run && patch -p1' < 0003-delta-for-phone-4.0.4.patch
tools/phone-ssh 'cd /usr/share/omarchy/shell/plugins/lock && sha256sum LockView.qml Keypad.qml'
# expect aa91c000b448bdccf5ac0be96f2ee932f819865cc837f727bcdb26cdbae30e63  LockView.qml
#        61126b254baebfaac713ae16980af5975de16f50e5835f26bf9a9295572af80f  Keypad.qml
tools/phone-ssh 'su - <user> -c omarchy-restart-shell'
```

**Stop** if the hashes before differ. Then lock: the hint, the pad above the
sensor glyph, a PIN unlocks, the finger unlocks. Rollback: copy the
`.pre-f13` files back and restart the shell.

### F14: password prompts usable with the on-screen keyboard (Omarchy patch 0010; omandroid-shell 0.1.35; risk low)

Fingerprint setup asks polkit first, and Omarchy's polkit prompt was unusable
on the phone: its full-screen scrim on the overlay layer covered squeekboard
(a top-layer surface that maps when a text field takes focus), and its
`Exclusive` keyboard focus makes Hyprland send every touch to it
(InputManager's exclusive layer list), so the keyboard could not be typed on
even where visible. That breaks any polkit password prompt on the phone.
`patches/omarchy/0010` makes the prompt `OnDemand` (Hyprland still focuses
an on-demand layer when it maps) and `ExclusionMode.Normal` (it stays out of
the keyboard's exclusive zone). It applies to b83d3df and to Omarchy 4.0.4
(the laptop's; offset 1). Not testable in the harness: the laptop's own
polkit agent holds the registration.

omandroid-shell 0.1.35: `omandroid-fp-enroll` claims asynchronously, so a
cancel on stdin, SIGTERM or SIGINT ends it at once, also while polkit is
asking (0.1.34 blocked in Claim; SIGTERM did nothing until it returned); it
reports `claimed` when polkit is answered. The enrollment screen stays
unmapped until then (0.1.34 already did; the phone showed "Getting ready" under
the prompt, which means the old plugin was still loaded: restart the shell
after installing, and check `omarchy-shell shell call omandroid.fingerprint
state ''` shows `"authPending":true,"enrollWindow":false` while the prompt is
up). Cancel stops a helper that does not answer within 2 s.

```sh
tools/phone-ssh 'cp /usr/share/omarchy/shell/plugins/polkit/PolkitAgent.qml /root/PolkitAgent.qml.pre-f14'
tools/phone-ssh 'cd /usr/share/omarchy && patch -p1 --dry-run && patch -p1' < patches/omarchy/0010-polkit-leave-the-on-screen-keyboard-usable.patch
tools/phone-install-package packages/omandroid-shell
tools/phone-ssh 'su - <user> -c omarchy-restart-shell'
```

**Stop** if the dry run fails (send the phone's file for a delta). Then
Quick settings > Fingerprint > Start: the prompt sits above the keyboard, the
keys type into the field, the password lets enrollment start; the prompt's
Cancel (or Escape) ends on "needs your permission". Rollback: copy the
`.pre-f14` file back and restart the shell.

### F15: enrollment through fprintd without lockouts; the prompt's keyboard after a wrong password (libfprint 1.94.100-1.2, Omarchy 0010; risk low)

Found on the phone (2026-10-13): fprintd 1.94.5 runs an identify over every
stored print before each enrollment, to refuse duplicates. On this sensor
that is an AUTH: one more touch and, for a new finger, a failed
authentication that the TA counts toward its lockout. A few enrollments
gave timed lockouts, ERROR 7s and a permanent one (`LOCKOUT -1`, cleared with
`omandroid-fp-ctl resetlockout`). Android does no such check. The driver now
answers that identify "no match" at once without a capture: it is the only
identify fprintd starts without a match callback (VerifyStart passes one),
read from libfprint's task data as fpi-device.c does (pinned to libfprint
1.94.x). `test/run`: 20/20, including "identify without a match callback: no
match, no AUTH". The first "enroll failed (2)" (UNABLE_TO_PROCESS, the
bridge's answer when generateChallenge, Gatekeeper or enroll fails) came
after those failed AUTHs; if it recurs without them, the bridge's journal
lines just before it (`generateChallenge`, `gatekeeper`) say which.

Omarchy's polkit prompt (`patches/omarchy/0010`, now also on the top layer
as tested on the phone): after a wrong password the field is read-only for
1.2 s, the input method hides the keyboard, and a field that keeps focus
never asks for it again. `refocus()` now moves focus off and back, and runs
when the field is writable again.

```sh
tools/phone-install-package packages/libfprint            # builds on the phone
tools/phone-ssh 'systemctl restart fprintd 2>/dev/null; pacman -Q libfprint'   # 1.94.100-1.2
tools/phone-ssh 'cp /usr/share/omarchy/shell/plugins/polkit/PolkitAgent.qml /root/PolkitAgent.qml.pre-f15'
tools/phone-ssh 'cd /usr/share/omarchy && patch -p1 --dry-run && patch -p1' < 0010-delta-for-phone-4.0.4.patch
tools/phone-ssh 'su - <user> -c omarchy-restart-shell'
```

The delta takes the phone's prompt (0010 as first sent, plus the top layer
set by hand) to the new 0010. Then: a wrong password brings the keyboard
back after "Wrong"; enrollment from quick settings starts on the first touch
(the journal shows ENROLL and no AUTH before it); `fprintd-list` shows the
finger; the lock unlocks with it.

### F16: PIN or password, the user's choice (Omarchy patch 0011; omandroid-shell 0.1.37; risk low)

Like Android, the phone unlocks with a PIN or a password, and every prompt
starts on the matching input with a switch to the other:

- `omandroid-set-pin` (System > PIN, and onboarding) asks "PIN (numbers
  only)" or "Password", then runs `passwd` as before (the secret is the
  account password, checked through PAM). It records the type in
  `~/.config/omandroid/credential` (`pin` or `password`, never the secret)
  and mirrors it to Omarchy's toggles: `lock-keypad` (a touch phone) always,
  `credential-password` for a password. The lock and the polkit prompt run
  in the user's session, so a per-user file is enough. Phones set up before
  this are recorded as PIN once (`omandroid-setup-user`).
- Lock screen (`patches/omarchy/0011` on 0003): a PIN opens the number pad
  (raised clear of the sensor, as F13); a password opens the text field high
  on the screen with the on-screen keyboard. "ABC" / "123" inside the
  field's left edge swaps them for this lock. The field is placed with `y`
  now: anchors switched while the lock was up left it squashed.
  `hypr/phone.lua` lets squeekboard (namespace `osk`, top layer) draw and
  take touches above the session lock (`above_lock = 2`); without it no
  keyboard can show over a lock. A failed attempt or a tap refocuses the
  field, so the keyboard comes back.
- Polkit prompt (0011 on 0010): the field asks for squeekboard's digit
  layout for a PIN (`Qt.ImhDigitsOnly`, which Qt sends as text-input-v3
  purpose `digits`; squeekboard maps that to its `number` layout) and the
  full layout for a password, "Enter PIN" or "Enter password", and an
  ABC/123 switch beside it (a refocus sends the new content type).
- The fingerprint target hides while the `osk` layer is up (Hyprland's
  `openlayer`/`closelayer` events): it would sit on the keyboard.

Checked in the desktop harness on Omarchy 4.0.4 with the phone's files plus
the delta (screenshots: lock as PIN, as password, and back while locked;
the prompt as PIN and as password). Not checked there: squeekboard (not
installed on the laptop), its digit layout, and the keyboard above the lock.

Deploy (unlocked; the shell restarts):

```sh
tools/phone-ssh 'cd /usr/share/omarchy/shell/plugins && cp lock/LockView.qml /root/LockView.qml.pre-f16 && cp polkit/PolkitAgent.qml /root/PolkitAgent.qml.pre-f16'
tools/phone-ssh 'cd /usr/share/omarchy && patch -p1 --dry-run && patch -p1' < 0011-delta-for-phone-4.0.4.patch
tools/phone-install-package packages/omandroid-shell
tools/phone-ssh 'su - <user> -c omandroid-setup-user; su - <user> -c omarchy-restart-shell'
tools/phone-ssh 'su - <user> -c "HYPRLAND_INSTANCE_SIGNATURE=\$(ls /run/user/\$(id -u <user>)/hypr | head -1) hyprctl reload"'   # the osk layer rule
```

The delta takes the phone's `LockView.qml` as F13 left it (`aa91c000…`) and
its `PolkitAgent.qml` as F15 left it (dry run is the check: the phone's copy
qualifies `Commons.Color`). Then: lock (PIN): pad, ABC shows the field and
the keyboard above the lock, 123 back; System > PIN, choose Password, lock:
field and keyboard first; a polkit prompt (`pkexec true`) shows the digit
layout for a PIN, the full one for a password, and the switch. **Stop** if
no keyboard shows above the lock in password mode (the `osk` layer rule:
`hyprctl layers` while it shows); the pad (123) still unlocks. Rollback: the
`.pre-f16` files, the previous omandroid-shell; `rm
~/.local/state/omarchy/toggles/credential-password` returns to the pad.

## 7. Results

| Step | Date | `uname -r` | Result |
|---|---|---|---|
| F0 offline | 2026-10-12 | (build) `…-00295-g1e5a4a7011b6` | kernel, modules, images, W=1, dt-validate, bridge and shim build, package and libfprint tests pass |
| F5 | 2026-10-13 | `7.3.0-rc6-omandroid-push1-00395-g6c0e876bd580` | **Oops**: `trusty_transfer_memory` re-mapped the dma-buf's importer table, whose pages `CONFIG_DMABUF_DEBUG` hides; cache clean at a bogus address. Fixed in `b9af5fe2d` (section 6, F5 first run); re-run below |
| F3 | 2026-10-13 | `…-00395-g6c0e876bd580` | **Passed**: RPMB LUN `sg1` (`0:0:0:49476`); `mfg_data` copied; `persist/ss` copied from an `ro,noload` mount; backups in `~/android/reference`. All six radio/persist partitions matched the 2026-10-12 backup first |
| F4 | 2026-10-13 | `…-00395-g6c0e876bd580` | **Passed** (the human ran it; choice A): "secure storage ready". Trusty: `tp` loaded, `tdp` loaded, `nsp` loaded, `td` created. No MAC errors |
| F5 re-run | 2026-10-13 | `7.3.0-rc6-omandroid-push1-00402-g92a933e3e446` | **Passed**: "g7.app loaded", `goodix` port open, no oops |
| F6a | 2026-10-13 | `…-00402` | **Passed**: `/fingerprint` okay; `vdd_udfps` 3.3 V disabled, 0 users (after `modprobe sec_acpm`) |
| F6b | 2026-10-13 | `…-00402` | **Passed**: "irq 131, supply switched, netlink 25"; open → supply on, 103 sensor interrupts; close → off |
| F6c | 2026-10-13 | `…-00402` | First run: `vndservicemanager` aborted ("Did not get context from PID 154", Gatekeeper): no LSM, so no caller context. Shim 0.1.1 answers `IPCThreadState::getCallingSid()` with its fixed context when none arrived (human-approved). **Passed**: KeyMint, Gatekeeper and the Goodix HAL up; sensor at (717, 2360) r 121 |
| F7 | 2026-10-13 | `…-00402` | **Passed** (the human ran it): a bright circle over the sensor, timed out by itself. `allow_lhbm` resets at boot: package 0.1.2+ sets it with a modprobe option |
| F8 | 2026-10-13 | `7.3.0-rc6-omandroid-push1-00405-g3bc8d8565645` | First tries: Gatekeeper enroll failed with `UNEXPECTED_NULL` (the bridge sent null arrays; fixed to empty arrays in 0.1.2); the HAL couldn't open `mfg_data` read-write (now a per-run scratch copy); `allow_lhbm` off after a reboot (no circle). A cancel the HAL never answers leaves the bridge stuck; restarting the service then fails (Trusty keeps the old storage proxy) until a reboot. **Passed**: about 17 good touches, `PROGRESS` 34 → 0, `ENROLLED`. `ACQUIRED 11` (immobile) when the finger isn't moved between touches |
| F9 (HAL) | 2026-10-13 | `…-00405` | **Passed**: enrolled finger → `MATCH`; another finger → `NOMATCH`. fprintd next |
