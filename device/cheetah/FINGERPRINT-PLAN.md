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
| TA load (F5) | Medium | Depends on F4. Fails silently if storage is not up (the loader waits 60 s). dma heap now handled |
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
Install the package and the vendor tree (installing writes nothing to
Trusty):

```sh
tools/phone-install-package packages/omandroid-fingerprint
tar -C out/fingerprint-vendor -cf - root MANIFEST SOURCE | tools/phone-ssh 'tar -C /usr/lib/omandroid-fp -xf -'
tools/phone-ssh '/usr/lib/omandroid-fp/omandroid-fp-chroot check'
# --- the irreversible step ---
tools/phone-ssh 'systemd-run --unit=omandroid-fp -p KillMode=control-group /usr/lib/omandroid-fp/omandroid-fp-chroot start storage'
tools/phone-ssh 'sleep 10; journalctl -u omandroid-fp -b --no-pager | tail -40; cat /dev/trusty-log0 2>/dev/null | tail -20'
```

Expect `check`: "preconditions met", RPMB `/dev/sgN`. Then
`[servicemanager]`, `[vndservicemanager]`, `[storageproxyd]` handling RPMB
requests, "secure storage ready"; Trusty's log mounting tp/td/tdp (td new,
the others loaded); files under `/var/lib/omandroid-fp/data/vendor/ss`.
**Stop** on storageproxyd errors or RPMB authentication failures ("MAC
mismatch", result codes): do not retry in a loop, collect the log. Rollback:
`systemctl stop omandroid-fp` (RPMB contents cannot be rolled back).

### F5: the TA (one change; risk low)

```sh
tools/phone-ssh 'systemctl stop omandroid-fp; systemd-run --unit=omandroid-fp -p KillMode=control-group /usr/lib/omandroid-fp/omandroid-fp-chroot start apploader'
tools/phone-ssh 'sleep 5; journalctl -u omandroid-fp -b --no-pager | grep -E "g7|apploader|storage" | tail; python3 - goodix' < packages/omandroid-fingerprint/lib/omandroid-tipc-probe
```

Expect "loading g7.app" then "g7.app loaded" within seconds (stock: 0.32 s),
the `goodix` port `open`. **Stop** on a 60 s timeout (storage not up) or a
policy failure in Trusty's log. Rollback: stop the unit; the app stays
loaded until reboot (harmless).

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
tools/phone-ssh 'systemctl stop omandroid-fp; systemd-run --unit=omandroid-fp -p KillMode=control-group /usr/lib/omandroid-fp/omandroid-fp-chroot start hal'
tools/phone-ssh 'sleep 15; journalctl -u omandroid-fp -b --no-pager | grep -E "\[fingerprint\]|\[keymint\]|\[gatekeeper\]" | tail -40; grep goodix /proc/interrupts'
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

- Lock UI: draw the target from `READY x y r`, keep the PIN pad clear of
  the sensor, "wake then touch" hint; an LHBM-friendly brightness.
- `RESETLOCKOUT` after a successful password unlock (a PAM session hook).
- sudo and polkit (`pam_fprintd` as in Omarchy's setup, with the password
  fallback).
- Boot ordering: `omandroid-fp.service` after `omandroid-aoc.service`.

## 7. Results

| Step | Date | `uname -r` | Result |
|---|---|---|---|
| F0 offline | 2026-10-12 | (build) `…-00295-g1e5a4a7011b6` | kernel, modules, images, W=1, dt-validate, bridge and shim build, package and libfprint tests pass |
