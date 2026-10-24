<!-- SPDX-License-Identifier: MIT -->
# Reinstall runbook (cheetah): a clean Omarchy Mobile install with the installer

Status (2026-10-13): **written and tested offline, not run.** Phase 5 of the
rename plan: wipe the hand-installed root on `userdata` and install the
renamed system with `tools/install-phone`, then put the phone's own data back
with `tools/phone-provision`. The human runs or approves every step. Nothing
here writes anything but slot B and `userdata`; stock Android on slot A stays
the way back.

The tools, all offline-tested (`tests/all`):

| Tool | Runs on | Does |
| --- | --- | --- |
| `tools/build-packages` | laptop (Arch Linux ARM container, qemu) | builds `packages/*` for aarch64, signs them, `out/repo/aarch64` |
| `bin/omamobile kernel/modules/initramfs/images` | laptop (build container) | kernel, modules tarball, initramfs (now with `resize2fs`), slot B images |
| `tools/build-rootfs` | laptop (Arch Linux ARM container) | `out/omamobile-rootfs-<date>-aarch64.img.zst` (+ `.sha256`, `.MANIFEST`) |
| `tools/install-phone` | laptop, phone in fastboot | checks, questions, `firstboot.conf` into a local image copy, then only `fastboot flash <img>_b`, `flash userdata`, `--set-active=b`, `reboot` |
| `omamobile-firstboot` | phone, first boot | user, keys, firewall, Omarchy's setup, autologin and lock |
| `tools/phone-provision` | laptop, over USB SSH | Google's firmware and vendor trees from the factory image; modem props, NV sums, camera data, home screens, fingerprint state from the backup |

Each step lists its commands, what to expect, a **stop** condition, the
rollback and a risk level. Read-only steps come first. Quote results (with
`uname -r`) into section 7 when done; check every quote for identifiers
(MAC addresses, serials, SSIDs) first.

## 0. What changes and what doesn't

- **Written:** `boot_b`, `init_boot_b`, `vendor_boot_b`, `vendor_kernel_boot_b`,
  `dtbo_b` (device.conf `BOOT_IMAGES`) and `userdata` (the whole Arch root:
  **everything on the current install is gone**, including the hand-made
  state not in the backup), then the active slot.
- **Not written:** slot A, `bootloader`, `radio`/`modem_a/b`, `persist`,
  `efs*`, `modem_userdata`, `devinfo` (apart from the boot-success marker the
  new system sets, as today), `vbmeta`, RPMB.
- **Comes back from the backup** (`~/android/reference/phone-backup-20261013`):
  modem `props.conf` (cdt_hwid), `modem-nv.sha256`, camera data (if the
  factory extraction can't regenerate it), `/etc/omamobile/*.conf`, Wi-Fi
  connections, home screens, quick settings, widgets, and (only with the
  human's go) the fingerprint state.
- **Is new:** the user account (its name is asked by the installer; it is no
  longer the project name), host name, SSH host keys, pacman keyring,
  machine id. The laptop's `known_hosts` doesn't matter (`tools/phone-ssh`
  ignores it).

## 1. Pre-flight (read-only; old install still running)

### P1. The Phase 0 backups exist and verify (laptop; risk none)

```sh
cd ~/android/reference/phone-backup-20261013
(cd partitions && sha256sum -c SHA256SUMS)
for f in phone-config.tar var-lib-*-fp.tar; do sha256sum -c "$f.sha256"; done
```

Expect every line `OK`. **Stop** if any file is missing or fails: take the
Phase 0 backup again before anything else (MODEM-PLAN M0.1, by `PARTNAME`).

### P2. Radio partitions on the phone match the backup (phone, read-only, ~430 MB read; risk none)

```sh
mkdir -p logs
tools/phone-ssh 'for p in efs efs_backup modem_userdata persist modem_a modem_b; do
  for s in /sys/block/sda/sda*; do grep -qx "PARTNAME=$p" $s/uevent &&
    printf "%s  %s.img\n" "$(sha256sum < /dev/${s##*/} | cut -d" " -f1)" "$p"; done; done' > logs/reinstall-p2.sha256
diff <(sort -k2 ~/android/reference/phone-backup-20261013/partitions/SHA256SUMS) <(sort -k2 logs/reinstall-p2.sha256) && echo SAME
```

Expect `SAME`. **Stop** on any difference: find out why (a stock boot on slot
A writes `efs`, `persist`, `modem_userdata`) and take a fresh backup first.

### P3. The modem was not started on this boot (phone, read-only; risk none)

```sh
tools/phone-ssh 'pgrep -a "cbd|rfsd" || echo "no modem daemons"; lsmod | grep -E "^(cpif|pcie_gs201_cp) " || echo "no modem modules"'
```

Expect both "no ...". **Stop** otherwise: reboot first (the modem's power-down
is what hung the last shutdown), then run P2 again.

### P4. Laptop side ready (risk none)

- The NetworkManager profile `omamobile-phone` exists
  (`nmcli -g connection.id,ipv4.method connection show omamobile-phone` gives
  `omamobile-phone:shared`; docs/RENAME-HOST-STEPS.md §4). The first boot
  needs it for the phone's internet (Omarchy's user setup fetches Node through
  it; it continues without).
- The factory image for P5 of section 5: `~/android/factory/cheetah-*-factory-*.zip`
  (the build the phone's stock slot A runs; its `.sha256` from Google checked).
- A kmsg log stream for the first boot: `tools/phone-ssh 'cat /dev/kmsg' | tee logs/reinstall-kmsg.log`
  (start it once the phone answers SSH in section 4; the initramfs answers
  before Arch starts).

## 2. Build (laptop only; no phone)

### B1. Packages (risk none on the laptop; the old phone only compiles)

```sh
tools/build-packages --list
tools/build-packages                                   # everything but Mesa, Hyprland, libcamera (~20 min)
tools/repo-build packages/hyprland packages/libcamera packages/mesa   # on the old phone, natively
tools/build-packages --list                            # nothing "to build" or "missing"
```

`tools/build-packages` builds in an Arch Linux ARM container (the official
tarball, signature-checked) under qemu, signs with `keys/` and indexes
`out/repo/aarch64`. Each package's `test/all` runs natively first (its
`check()` times out under qemu). **Stop** on a failed test; fix the package,
don't `--nocheck` past it. Mesa, Hyprland and libcamera take many hours under
qemu, so they're built natively on the old phone with `tools/repo-build`
(makepkg as the logged-in user, nothing installed; makedepends must already
be on the phone), which signs them and re-indexes the same `out/repo`. Before
that, make sure the phone's `~/build/mesa` holds no older Mesa packages:
`repo-build` also collects whatever is there. `out/repo` must end with one
version of each package, all signed, and Mesa, `vulkan-panfrost`, Hyprland
and the libcamera packages from these builds (`tools/build-rootfs` refuses
them from any other repository).

### B2. Kernel, modules, initramfs, images (risk none)

```sh
export KERNEL_DIR=~/android/mainline/wt-int KERNEL_OUT=~/android/mainline/out-int
bin/omamobile kernel && bin/omamobile modules && bin/omamobile initramfs && bin/omamobile images
cat $KERNEL_OUT/include/config/kernel.release            # 7.3.0-rc6-omamobile-push1-...
$KERNEL_OUT/scripts/dtc/dtc -q -I dtb -O dts $KERNEL_OUT/arch/arm64/boot/dts/exynos/google/gs201-cheetah.dtb | grep bootargs
lz4 -dc $KERNEL_OUT/initramfs.cpio.lz4 | cpio -t 2>/dev/null | grep -E 'sbin/(resize2fs|dumpe2fs)$'
```

Expect: the release names `omamobile`; the bootargs carry the renamed
`omamobile.*` flags (Phase 2), `panic=10`; the initramfs lists both e2fsprogs
tools. **Stop** if the DTB still says the old flag names: Phase 2 hasn't
reached `omamobile-int`. The initramfs still holds this laptop's
`~/.ssh/*.pub` as root's key for the initramfs shell (development build,
RELEASES §5.2).

### B3. Root image (risk none; about 20 minutes)

```sh
tools/build-rootfs                         # out/omamobile-rootfs-<date>-aarch64.img.zst, runs tests/rootfs-smoke
less out/omamobile-rootfs-*-aarch64.MANIFEST
```

Expect the smoke test's `ok` lines; the MANIFEST lists the device package,
`kernel modules: <B2's release>`, which Omarchy patches applied and which
Omarchy packages aren't built for aarch64. The test build of 2026-10-13
(without Mesa, Hyprland and libcamera) took 18 minutes: 8.5 GB of files in
an 11 GB file system, 2.6 GB compressed; every package of Omarchy's list was
available for aarch64 (Omarchy 4.0.4-2 from the edge channel).
**Stop** if a patch in `patches/omarchy` didn't apply (the lock screen's PIN
pad needs 0003 and 0011): rebase it on the Omarchy version in the MANIFEST
first. **2026-10-13:** all twelve apply to Omarchy 4.0.4-2 (edge; the same
files as tag v4.0.4), 0008 through the `/usr/bin` link. 0000 backports
upstream b83d3df (`Commons.Color`: Qt 6.12's `QtQuick` `Color` shadows the
palette, and edge 4.0.4 lacks the fix; drop 0000 once edge has it) and
applies first; 0003, 0005, 0006 and 0011 were rebased onto 4.0.4 plus 0000.
With the series, the lock's `LockView.qml` is byte for byte the phone's
tested file (`4c72b5be…`, F16b). Expect the MANIFEST's "not applied" line
to read `none`.

### B4. Offline tests (risk none)

```sh
tests/all
```

Expect only `ok` lines (the installer against a fake fastboot, provisioning
against a container, the initramfs growth, first boot against a scratch
root, the smoke test of B3's image).

## 3. Install (phone in fastboot; the irreversible step is I3)

### I1. Reach fastboot and read the bootloader (risk low; the screen goes to the bootloader)

Tell the human the screen will change, then:

```sh
bin/omamobile fastboot
fastboot getvar all 2>&1 | grep -E 'product|unlocked|current-slot|version-bootloader'
```

Expect `product: cheetah`, `unlocked: yes`. Coming from our Linux, the
current slot is `b`: `version-bootloader` is slot B's. Compare it with slot
A's from the stock capture (`~/android/reference/cheetah-stock-cp2a/fastboot-getvar-all.txt`,
taken with slot A current). **Stop** if they differ: setting slot B active
runs slot B's bootloader; flash the same factory bootloader to both from
stock first. If equal, that value is the `--bootloader-slots-match` below.

### I2. Dry run (risk none: reads variables, prepares a local copy, writes nothing)

```sh
tools/install-phone --dry-run --bootloader-slots-match <version from I1>
```

Answer the questions (user name, PIN or password twice, host name, time
zone, git name and email if wanted, Wi-Fi if wanted, the SSH key), then
type `cheetah`. Expect "These commands, and only these" listing exactly the
five `fastboot flash <image>_b`, `fastboot flash userdata <work>/root.simg`,
`--set-active=b`, `reboot`, and the same eight lines as "would run".
**Stop** on any other line.

### I3. Install (risk HIGH: erases userdata; slot A untouched)

```sh
tools/install-phone --bootloader-slots-match <version from I1>
```

Same answers; type `cheetah`. Expect `OKAY` from fastboot for each image,
the userdata transfer in sparse chunks (several minutes over USB), then the
reboot. **Stop** on any `FAILED`: the script stops itself; do not rerun in a
loop, read the message, and ask. **Rollback:** the phone is still in fastboot
with slot A untouched; rerunning the installer after fixing the cause is
safe. To go back to stock: `fastboot --set-active=a` and `fastboot reboot`
(stock Android then needs a factory reset: its data was erased).

## 4. First boot (phone; watch, change nothing)

### F1. Growth and first boot (risk low)

The initramfs grows the 6-10 GB image to the whole `userdata` partition
before mounting it ("growing the root file system", then "root file system
grown", in kmsg and on screen); its no-USB crash waits for that to finish.
Then Arch starts and `omamobile-firstboot` runs before SDDM, for a few
minutes.

```sh
tools/phone-ssh 'journalctl -fu omamobile-firstboot'     # or: cat /var/log/omamobile/firstboot.log
```

Expect, in order: pacman keyring, hostname/time zone/locale, the user,
SSH keys, Omarchy's system setup (four `skip` lines: `post-install/pacman.sh`,
`hardware/pacman.sh`, `config/snapper.sh`, `hardware/network.sh`; some
hardware leaves for other machines may `fail`, which is normal), services
and firewall, Wi-Fi, login, user setup, then `=== firstboot done ===`.
**Stop** on `firstboot incomplete`: the conf stays, SSH as root still works;
read the log, fix, and `systemctl start omamobile-firstboot` (it is
idempotent). **Rollback:** reinstall (I3) or slot A.

### F2. Checks (read-only; risk none)

```sh
tools/phone-ssh 'uname -r; df -h / | tail -1; hostname; id <user>; ls /etc/omamobile/firstboot.conf 2>&1
  systemctl is-active sddm sshd NetworkManager systemd-networkd omamobile-boot-success
  systemctl --failed --no-legend; pacman -Q | grep -c omamobile; ufw status | head -1
  grep -rl omandroid /etc /usr/lib/systemd /usr/share /home 2>/dev/null | head'
```

Expect: B2's release; `/` at about the size of `userdata` (~110 GB); the
chosen host name; the user in `wheel`, `audio`, `video`, `input`; no
`firstboot.conf`; all active; no failed units (or only ones explained in
the log); `ufw` "inactive" (it turns on at the next boot, as Omarchy's
installer leaves it); no file with the old name. The human sees the Omarchy
desktop with the phone shell, behind the lock screen's PIN pad.

### F3. Firewall under a dead-man switch, then the second boot (risk medium: can cut SSH)

```sh
tools/phone-ssh 'ufw show added | grep "usb0"'
tools/phone-ssh 'systemd-run --unit=fw-deadman --on-active=90 /usr/bin/ufw disable && ufw --force enable'
tools/phone-ssh --fresh 'echo fresh login works; ufw status | head -3'   # a NEW connection
tools/phone-ssh 'systemctl stop fw-deadman.timer'
tools/phone-ssh '(sleep 1; reboot-to omamobile) >/dev/null 2>&1 &'
tools/phone-ssh 'uptime; ufw status | head -1; systemctl is-active omamobile-firstboot'   # after ~40 s
```

Expect the `usb0` rule, a fresh login with ufw active, then after the reboot
ufw active and `omamobile-firstboot` inactive (its condition is gone).
**Stop** if the fresh login fails: wait 90 s for the dead-man to disable ufw.

## 5. Provision (laptop over USB SSH)

### V1. Dry run (risk none: extracts nothing, contacts nothing)

```sh
F=~/android/factory/cheetah-*-factory-*.zip
tools/phone-provision --dry-run --user <user> --import-home --restore-config --restore-wifi $F
```

Expect the extraction commands, then the path mapping from the backup's old
names to the new (`/var/lib/omamobile-vendor/modem/props.conf`,
`/etc/omamobile/modem-nv.sha256`, `/etc/omamobile/*.conf`, the user's
`~/.config/omamobile/{home.json,quicksettings.json,widgets}`).

### V2. Provision (risk low: files only, no hardware)

```sh
tools/phone-provision --import-home --restore-config --restore-wifi $F
```

Expect each push "verified", camera data from the factory extraction if the
unicorn venv exists (`~/.cache/omamobile-venv`), otherwise from the backup.
Everything lands owned by root (the home files by the user). **Stop** on a
failed extraction or verify. Rollback: rerun (idempotent), or remove the
pushed trees.

### V3. Reboot and the radio partitions again (risk low; read-only check)

```sh
tools/phone-ssh '(sleep 1; reboot-to omamobile) >/dev/null 2>&1 &'
# after ~40 s: P2's command into logs/reinstall-v3.sha256, then the diff
```

Expect `SAME`: the reinstall never touched them. **Stop** on a difference.

## 6. Subsystem checklist (DEVICES.md; the human looks and listens)

| # | Subsystem | Check | Pass |
| --- | --- | --- | --- |
| S1 | Display | `tools/display-hz` | ~120 Hz, no underruns |
| S2 | Touch, buttons | tap, swipe; power key locks, volume keys | as before |
| S3 | Wi-Fi | `nmcli -t -f DEVICE,STATE dev` | wlan0 connected (restored or installer network) |
| S4 | Bluetooth | pair headphones, play | A2DP audio |
| S5 | Speakers | quick settings volume, a short sound | both speakers, stage media (`/etc/omamobile/speaker.conf`) |
| S6 | Sensors | rotate the phone | auto-rotate; light and proximity in `monitor-sensor` |
| S7 | GNSS | Location tile on, a map app | a fix outdoors |
| S8 | NFC | tap a tag with a link | the link opens |
| S9 | Battery, haptics, torch | battery tile, a buzz, torch tile | as before |
| S10 | Camera | `cam -c1 --capture=1` (ultrawide) | a frame (libcamera 0.7.2-4.6) |
| S11 | Shell | home screens, widgets, quick settings, one app per screen | the imported layout |
| S12 | Update path | `omarchy update` in a terminal | finishes; `[omamobile]` first |

Record each result in section 7.

## 7. Fingerprint (needs the human's explicit go; IRREVERSIBLE)

The fingerprint state in the backup is Trusty's secure storage for this
phone. Restoring it copies files; **starting storageproxyd on it writes the
phone's RPMB**, and that is FINGERPRINT-PLAN F4's irreversible step. Do not
run the second command without the human's recorded yes.

```sh
tools/phone-provision --skip-extract --fingerprint          # copies; omamobile-fp stays stopped
# --- only with the human's go, following FINGERPRINT-PLAN F4-F6 ---
```

Then re-enrol fingers through Setup > Security > Fingerprint (the enrolment
state may not survive the new install's Gatekeeper secret).

## 8. Modem

Not part of the reinstall. The M4.1i repeat comes after the M3.5 checksums
(MODEM-PLAN), on the new install, attended.

## 9. Rollback, at any point

- Before I3: nothing on the phone changed.
- After I3: slot A is stock Android, untouched. From fastboot,
  `fastboot --set-active=a` and `fastboot reboot`, then a factory reset in
  Android (its data is gone). Or reinstall with `tools/install-phone` (it
  only ever writes slot B and `userdata`).
- The old root is not recoverable from the phone after I3; only what the
  backup holds comes back.

## 10. Results

(Date, `uname -r`, image version and size, each step's outcome.)

### 2026-10-13: first clean reinstall (cheetah, 7.3.0-rc6-omamobile-push1-00470-g0db95c439674)

Passed: P1-P4, B1-B4 (root image 15 min, 2.5 GB compressed, all smoke checks
ok, 36 offline tests ok), I1 (bootloader `cloudripper-17.0-15199429` on both
slots), I2, I3, first boot (user account, Omarchy's full user setup, file
system grown to 109 GB), V1-V3 (radio partitions unchanged).

Found and fixed in the repository (c8762a2) after the install; a new install
no longer needs these by hand:
- `aoc.bin` and the AoC sensor registry weren't extracted or pushed: no AoC,
  audio or sensors until they were (extract-vendor-firmware, phone-provision);
- extract-camera-data didn't create its output directory;
- the sensor proxy, speaker protection, NFC opener and GNSS socket/timer
  weren't enabled (omamobile-setup-system 0.1.29 enables them);
- fprintd wasn't a dependency, and the lock's fingerprint PAM file was
  missing (omamobile-fingerprint 0.1.7).
Also: `bin/omamobile fastboot`'s crash fallback looped the old install's
reboots; reach fastboot with Volume Down + Power instead when the phone runs
Linux and adb isn't available (I1).
The bring-up overlays are applied by `bin/omamobile images` from
`device.conf`'s `DTB_OVERLAYS` (b46a2de); without them the image boots with
no audio, NFC, GNSS, fingerprint or cameras.
Fingerprint: state restored from the Phase 0 backup, service started with the
human's go, a finger re-enrolled.
