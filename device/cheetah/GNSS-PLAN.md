<!-- SPDX-License-Identifier: MIT -->
# GNSS plan (cheetah / gs201): BCM4775x, stock lhd and gpsd, GeoClue

Status: **built offline, 2026-10-12. Nothing has run on the phone.** Kernel
branch `omandroid-gnss` in `~/android/mainline/wt-gnss`, build in
`~/android/mainline/out-gnss` (release
`7.3.0-rc6-omandroid-push1-00209-gec375b274d61`, logs `logs/kernel-gnss.log`,
`logs/kernel-gnss2.log`). Everything new is disabled by default: the
S2MPG13 node, USI5/SPI5 and (for NFC) the HSI1 pin controller and the NFC
node are only turned on by the overlays below. RADIOS-CAMERA-PLAN.md
section 2 has the hardware survey this builds on.

Path abbreviations:

- `L/` = our kernel, branch `omandroid-gnss` (`~/android/mainline/wt-gnss`)
- `G/` = `~/android/omandroid/out-kernel/google/gs-6.1/private` (Google's GPL gs201 kernel)
- `R/` = `~/android/reference/cheetah-stock-cp2a-root` (stock live DT, logs)
- `X/` = `~/android/vendor-chroot-work/gnss` (the extract tool's output from the user's factory image; never committed)

---

## 1. Shape

```
lhd, gpsd (Broadcom, stock, unmodified)          GeoClue  gpsd (Linux)
   | /dev/ttyBCM, /dev/bbd_*, nstandby               ^        ^
   |   (vendor chroot, profile gnss)                 | sock   | pty
   v                                       omandroid-gnss-nmea
bcm4775x-gnss (kernel, SPI5)  ----NMEA FIFO----^ (/data/vendor/gps/nmea_out)
   | supplies: S2MPG13 LDO9S/10S/11S over ACPM (sec-acpm + s2mps11)
BCM4775x
```

## 2. Kernel (`omandroid-gnss`)

Based on `omandroid-int` @ `741b6ed1d`, with two merges first:
`omandroid-hsi1` (`f7a9852f1`, HSI1 pinctrl; the conflict with the HSI2
pinctrl in the aliases and `gs201-pinctrl.dtsi` is resolved here) and the
S2MPG12 commits of `omandroid-suspend` up to `93555da2a` (the S2MPG13 code
sits next to S2MPG12's in `sec-acpm.c`).

| Commit | What |
|---|---|
| `4a2cadde4` dt-bindings: firmware: google,gs101-acpm-ipc: allow the gs201 sub-PMIC | `pmic-2` = `samsung,s2mpg13-pmic` on gs201 |
| `7ef20d70e` dt-bindings: mfd: add Samsung S2MPG13 PMIC | MFD + regulator bindings (28 LDOs) |
| `3510a9c19` mfd: sec: add S2MPG13 | ACPM bus 1; common block read-only; PM block writable **only** in the LDO control registers 0x2c-0x49; INT1-4 never read; no IRQ (optional now), no meter |
| `c3937a59e` regulator: s2mps11: add S2MPG13 LDOs | from Google's `s2mpg13-regulator.c`; rails without a DT node get no constraints, so the core never switches them |
| `85664485f` dt-bindings: gnss: add Broadcom BCM4775x on SPI | `brcm,bcm4775-gnss` |
| `eb04c6c3c` misc: add a Broadcom BCM4775x GNSS driver for lhd | `L/drivers/misc/bcm4775x/`, module `bcm4775x-gnss` |
| `cad9624c0` dt-bindings: net: nfc: st,st-nci: add ST54J | `st,st54j-i2c` with `st,st21nfcc-i2c` fallback |
| `cb0505cc1` arm64: dts: exynos: google: gs201: add USI5 with its SPI | `usi5`/`spi_5` (SPI 678), pin groups; disabled |
| `bb576befa` ... gs201-cheetah: describe the GNSS receiver | `pmic-2` with LDO9S-11S (stock ranges, disabled), `gnss@0` on `spi_5` |
| `ec375b274` ... gs201-cheetah: describe the NFC controller | `nfc@8` on `hsi2c_8`, reset gph1-5; disabled |

Checks: full build exits 0; the changed C files build with `W=1` and no
warnings; `dt-doc-validate` of the five bindings passes; `dt-validate`
(dtschema 2026.9, schema from this tree) of the default DTB and of the DTB
with `gnss-pmic-test` + `gnss-test` + `nfc-test` applied reports only the
existing `soc_id` and simplefb items. `git merge-tree` against
`omandroid-int` @ `6def5bac7`: clean.

**Merge order for int:** `omandroid-gnss` alone. It carries `omandroid-hsi1`
and the S2MPG12 commits of `omandroid-suspend` (up to `93555da2a`), so
merge it before (or instead of) `omandroid-hsi1`; a later
`omandroid-suspend` merge only adds what came after `93555da2a`. Merging
`omandroid-hsi1` into int separately first gives the same aliases conflict
the branch already resolves (rerere has it): keep `pinctrl6` and `pinctrl7`,
and both `&pinctrl_hsi1` and `&pinctrl_hsi2` blocks.

### 2.1 The driver, against Google's

`bcm_gps_spi.c`, `bcm_gps_regs.c`, `bbd.c` from
`G/google-modules/gps/broadcom/bcm47765/`, same SSI framing, flow control
(PZC) and MCU wake handshake, same device nodes (`/dev/ttyBCM`,
`/dev/bbd_{sensor,control,patch,pwrstat}`, `nstandby` and `sspmcureq`
attributes). Changes:

- **Supplies on only while `/dev/ttyBCM` is open** (lhd running), chip back
  in standby and rails off on close. Stock keeps the rails always on.
  `nstandby` cannot be raised while the rails are off (`-EPERM`).
- **8-bit SPI words.** Google's switches to 32-bit words above 64 bytes,
  which relies on its controller's byte swap (`swap-mode`).
- The read command byte stays **0x70** as on stock: Google's
  `SSI_MODE == SSI_MODE_FULL_DUPLEX` test (1 vs 0x40) picks
  `SSI_READ_TRANS`, and the chip expects what stock sends.
- host_req is re-armed after resume only while `/dev/ttyBCM` is open.
- bbd: control strings matched with `strstr()` on a terminated copy
  (Google's `strcmp()` chain was inverted, so every string fell into the
  first branch and did nothing); the whole chrdev region freed; no sensor
  hub, coredump or 1 Hz statistics code. The 1 Hz timer that would wake an
  idle phone is compiled out in Google's build as well (`bbd.h:62`
  `//#define DEBUG_1HZ_STAT`), so RADIOS-CAMERA-PLAN.md 2.2 overstated it.
- debugfs `/sys/kernel/debug/spi5.0/`: `pins` (line levels, counters) and
  `probe` (G2 below).

### 2.2 Regulators: what was needed

Nothing could switch the GNSS rails before this branch: there is no S2MPG13
driver anywhere in our trees (the AoC work has a raw-ACPM bring-up module
for its own rails). This branch adds S2MPG13 to `sec-acpm` and `s2mps11`
the upstream way, deliberately narrow:

- writes reach only LDO control registers (regmap `wr_table`);
- only LDO9S-11S are in the DT, at stock's ranges (0.725-1.3 V,
  1.6-1.95 V, 1.6-1.95 V), so registering them writes nothing;
- the other 25 LDOs exist without constraints and are never touched;
- no interrupt (stock: gpa0-1), no meter, no bucks.

**One write to know about:** the regulator core turns off unused rails that
have constraints about 30 s after late init. LDO9S-11S are GNSS-only
(`L9S_GNSS_CORE`, `L10S_GNSS_RF`, `L11S_GNSS_AUX`, `R/live.dts:14072-14104`
and the ODPM rail names), so that is harmless. G1 avoids it anyway by
loading `sec_acpm` after the 30 s.

## 3. Userspace (omandroid repo)

All of it is the `packages/omandroid-gnss` package (default-off; it moved
there from `vendor-chroot/`). Google's files are not in it.

| Path (in `packages/omandroid-gnss/`) | What |
|---|---|
| `lib/omandroid-vendor-chroot` | shared runner, `PROFILE check / start / ns / run`; grown from `fingerprint/omandroid-fp-chroot` (same tmpfs chroot, property store, shim, binderfs, supervision); profiles hold what differs |
| `profiles/gnss.conf` | binds `/dev/ttyBCM`, `/dev/bbd_*` and the `nstandby` attribute; writes lhd.conf/gps.xml from the image with the nstandby path, `/data` logs, logcat logging, `PpsEnable=false`; refreshes the LTO file on the host; resolves `HOSTS` into the chroot's hosts file; runs `lhd`, then `gpsd`, and asks for positions over the control pipe |
| `gnss/props.conf` | `ro.hardware` and the DNS properties |
| `bionic/` | `Makefile` and sources for the shim (from `fingerprint/shim`) and two stubs (`libcom.android.tethering.connectivity_native.so` for `libandroid_net`, `libomandroid-sitril-gps.so` preloaded in place of the SIT RIL). Built on the computer into `bionic/prebuilt/`, which is not committed |
| `lib/omandroid-gnss-start` | hang-safe start (marker file, as `omandroid-wifi-start`), `modprobe sec_acpm bcm4775x-gnss`, then the runner |
| `lib/omandroid-gnss-nmea` | reads the FIFO, serves checksummed sentences on `/run/omandroid-gnss/nmea.sock` (GeoClue; the socket comes from systemd) and a pty at `/run/omandroid-gnss/nmea-tty` (Linux gpsd); `--idle-exit 60` |
| `vendor/systemd/system/` | `omandroid-gnss-nmea.socket` (the Location switch), `omandroid-gnss-nmea.service` (BindsTo the stack), `omandroid-gnss.service` (StopWhenUnneeded), `omandroid-gnss-force.service`, `omandroid-gnss-location@.service` |
| `bin/omandroid-gnss` | `on`, `off`, `force`, `unforce`, `status [--json]` |
| `polkit/50-omandroid-gnss.rules` | the active local user may start `omandroid-gnss-location@{on,off,force,unforce}.service`, nothing else |
| `etc/geoclue/conf.d/90-omandroid-gnss.conf` | `[network-nmea] nmea-socket=/run/omandroid-gnss/nmea.sock`; Firefox, Chromium, GNOME Maps/Weather and `where-am-i` allowed as system apps (Omarchy has no GeoClue agent) |
| `vendor/modprobe.d/omandroid-gnss.conf` | `blacklist bcm4775x_gnss` (loaded only by the start script) |

Elsewhere in the repo:

| Path | What |
|---|---|
| `tools/extract-vendor-chroot` | `-p gnss`: lhd, gpsd, SensorHub.patch, configs, servicemanager, CA store and the library closure, from the user's factory image |
| `device/cheetah/overlays/gnss-pmic-test.dtso`, `gnss-test.dtso` | G1, G2 |

Offline results: `tools/extract-vendor-chroot -p gnss` on
`image-cheetah-cp2a.260705.006.zip` gives 264 files, 28 MB (`X/`), closure
complete with the one stub. `make -C packages/omandroid-gnss/bionic CLANG=... BIONIC=...
CHROOT=X/root` builds both `.so` files. The generated lhd.conf/gps.xml were
diffed against stock: only the four intended changes.

**For apps:** Firefox and GNOME apps use GeoClue. GeoClue only answers apps
an agent authorizes, or ones listed with `system=true` in its config; on
Omarchy there is no agent. The package's GeoClue config lists Firefox,
Chromium, GNOME Maps, GNOME Weather and `where-am-i` as system apps; the
Location switch (`omandroid-gnss on|off`) is the user's control. A real
agent (per-app prompts) is section 6, question 4.

## 4. Runbook (staged, read-only first)

Phone in Arch over USB, from the omandroid repo. The main session merges
`omandroid-gnss` into int and builds; `ov` is the overlay helper from
AUDIO-PLAN.md (rebuild the DTB from default + overlays, then images).

### G0: pin states (read-only, current kernel)

As RADIOS-CAMERA-PLAN.md 2.6:

```sh
tools/phone-ssh 'P=/sys/kernel/debug/pinctrl; grep -hE "\((gph2-[0-5])\)" $P/*14440000*/pins;
  grep -hE "\((gpp4-3|gpp10-[0-3]|gpp15-1)\)" $P/*10840000*/pins; grep -hE "\((gpa6-4)\)" $P/*180e0000*/pins'
```

Record: gph2-3 (nstandby) and gpp4-3 (mcu_req) as ABL left them; expect
output-low or input.

**G0 result (2026-10-12, kernel `...-00214-g6def5bac7547`): passed.**

| Pin | Role | CON | DAT | PUD | Note |
|---|---|---|---|---|---|
| gph2-0 | Wi-Fi PERST# | 0x1 | 1 | 0 | ours (Wi-Fi up) |
| gph2-1 | Wi-Fi CLKREQ# | 0x2 | 0 | 3 | ours |
| gph2-2 | GNSS mcu_resp | 0 | 0 | 1 | input, pull-down (= stock pin group) |
| gph2-3 | GNSS nstandby | 0 | 0 | 1 | input, pull-down: chip held in standby |
| gph2-4 | WL_REG_ON | 0x1 | 1 | 0 | ours |
| gph2-5 | Wi-Fi dev-wake | 0 | 0 | 1 | ours |
| gpp4-3 | GNSS mcu_req | 0 | 0 | 1 | input, pull-down |
| gpp10-0..3 | SPI5 SCLK/MOSI/MISO/CS | 0 | 0 | 1 | inputs: ABL never sets up USI5/SPI5 |
| gpp15-1 | GNSS PPS | 0 | 0 | 1 | input |
| gpa6-4 | GNSS host_req | 0 | 0 | 1 | input, pull-down (not yet EINT) |

PERIC0 power-down states: CON_PDN 2, PUD_PDN 1 on the PERIC0 pins.

What this means for G1/G2:
- The GNSS chip is idle and in standby, and nothing else uses its pins.
- ABL leaves SPI5 entirely unconfigured, so the USI5 mode, clock and pins
  all come from our DT. If the G2 probe reads all 0xff with
  `mcu_resp: answered`, check the USI5 mode and the PERIC0 USI5 clock
  first.
- gph2-3 and gpp4-3 are inputs with pull-down. The driver drives them low
  as outputs at probe, which keeps the same level.
- Our host_req group takes away the pull-down (stock: none) once it
  becomes the EINT.
- int merged `omandroid-gnss` at `7af02fa41`; G1 and G2 run on the next
  push.

### G1: the sub-PMIC, read-only (int + `gnss-pmic-test`)

```sh
# 0. modules installed with the int kernel; keep sec_acpm from autoloading
#    so it registers after the regulator core's 30 s cleanup
tools/phone-ssh 'echo "blacklist sec_acpm" > /etc/modprobe.d/omandroid-g1.conf'
ov gnss-pmic-test && bin/omandroid push                        # reboots
# 1. after 60 s uptime
tools/phone-ssh 'cut -d. -f1 /proc/uptime; modprobe sec_acpm; sleep 2; dmesg | grep -iE "s2mpg13|sec-acpm|pmic-2" | tail'
#   pass: the pmic-2 device probed, no errors; three regulators registered
tools/phone-ssh 'for r in /sys/class/regulator/regulator.*; do n=$(cat $r/name); case $n in vdd_gnss*) echo "$n $(cat $r/state) $(cat $r/microvolts 2>/dev/null)";; esac; done'
#   record: on/off and voltage of each GNSS rail as ABL left them (open question 1)
tools/phone-ssh 'grep -E "^(34|35|36):" /sys/kernel/debug/regmap/*pmic-2*pmic*/registers; grep "^0b:" /sys/kernel/debug/regmap/*pmic-2*common*/registers'
#   raw L9S/L10S/L11S_CTRL (bit 7 enable, bits 5:0 selector) and CHIPID
# rollback: images without the overlay; rm /etc/modprobe.d/omandroid-g1.conf
```

The only ACPM traffic is reads on PMIC bus 1. If any read hangs the phone,
stop: the bus number or the access type is wrong (`sec-acpm.c`,
`speedy_channel = 1`, `G/.../mfd/s2mpg13-core.c:57`).

### G2: driver and link (int + `gnss-pmic-test` + `gnss-test`)

```sh
tools/phone-ssh 'install -m644 /dev/stdin /etc/modprobe.d/omandroid-gnss.conf' < packages/omandroid-gnss/vendor/modprobe.d/omandroid-gnss.conf
ov gnss-pmic-test gnss-test && bin/omandroid push              # reboots
tools/phone-ssh 'modprobe sec_acpm; modprobe bcm4775x-gnss; dmesg | grep -iE "bcm4775|spi5|10940000" | tail -5;
  ls -l /dev/ttyBCM /dev/bbd_*; cat /sys/kernel/debug/spi5.0/pins; grep ttyBCM /proc/interrupts'
#   pass: "BCM4775x GNSS on SPI, irq N; supplies off..."; five nodes; powered 0,
#   nstandby 0; the ttyBCM interrupt count 0 (it is armed only while open)
# first writes: rails on, nstandby high, MCU wake, two register reads, all off again
tools/phone-ssh 'cat /sys/kernel/debug/spi5.0/probe; cat /sys/kernel/debug/spi5.0/pins'
#   pass: "mcu_resp: answered", HSI_STATUS not 0xff, HSI_ERROR_STATUS 0x00; powered 0 after
#   "no answer": check G1's rail values and the gph2-2/3 pins (debugfs pinctrl pins);
#   all 0xff/0x00 with an answer: SPI mode or chip select (try spi-max-frequency 12 MHz)
# rollback: rmmod bcm4775x-gnss; images without the overlays
```

**G1 and G2 passed (2026-10-12, int `...-00238-g3393f8dee945`, DTB +
gnss-pmic-test + gnss-test + aoc-boot-test):**

- **G1** (`sec_acpm` loaded at 144 s):
  - All three rails are **off** from ABL, at stock voltages: `vdd_gnss_core`
    1.2 V, `vdd_gnss_rf` 1.8 V, `vdd_gnss_aux` 1.8 V.
  - Raw registers: L9S_CTRL 0x26 (selector 38 = 1.2 V, enable bit 7
    clear), L10S/L11S 0x2c (44 = 1.8 V), CHIPID 0x05.
  - This answers open question 1. The ACPM bus-1 reads work.
- **G2**:
  - The driver binds (`irq 119` on gpa6-4, count 0) and creates all five
    nodes.
  - `probe`: `mcu_resp: answered`, HSI_STATUS 0x00, HSI_ERROR_STATUS
    0x00, twice.
  - Afterwards the pins are back at 0 and all rails are disabled.
  - So the supplies, standby, the MCU wake handshake and the SSI debug
    frames on SPI5 all work.

### G3: lhd loads the patch

What's on the phone: the int kernel with both GNSS overlays, and
`/etc/modprobe.d/omandroid-g1.conf` (blacklists `sec_acpm`) and
`omandroid-gnss.conf` (blacklists `bcm4775x_gnss`). So after each boot
load both by hand, `sec_acpm` once uptime is past 60 s. Nothing else from
`packages/omandroid-gnss/` (then `vendor-chroot/`) is installed yet.

Laptop, from the omandroid repo:

```sh
# 1. shim + stub (already built in packages/omandroid-gnss/bionic/prebuilt; rebuilding is harmless)
make -C packages/omandroid-gnss/bionic CLANG=$HOME/android/omandroid/prebuilts/clang/host/linux-x86/clang-r596125/bin/clang \
  BIONIC=$HOME/android/omandroid/bionic/libc CHROOT=$HOME/android/vendor-chroot-work/gnss/root
# 2. the profile's Android tree (28 MB, the user's own image) and our pieces, root-owned
tar -C ~/android/vendor-chroot-work/gnss -cf - root MANIFEST SOURCE STUBS |
  tools/phone-ssh 'mkdir -p /usr/lib/omandroid-vendor/gnss && tar --no-same-owner -C /usr/lib/omandroid-vendor/gnss -xf -'
tar -C packages/omandroid-gnss -cf - profiles/gnss.conf -C lib omandroid-vendor-chroot |
  tools/phone-ssh 'tar --no-same-owner -C /usr/lib/omandroid-vendor -xf -'
tar -C packages/omandroid-gnss/bionic/prebuilt -cf - omandroid-fp-shim.so stubs |
  tools/phone-ssh 'tar --no-same-owner -C /usr/lib/omandroid-vendor -xf -'
tools/phone-ssh 'install -m644 /dev/stdin /usr/lib/omandroid-vendor/gnss/props.conf' < packages/omandroid-gnss/gnss/props.conf
tools/phone-ssh 'ls -l /usr/lib/omandroid-vendor /usr/lib/omandroid-vendor/stubs; cat /usr/lib/omandroid-vendor/gnss/SOURCE'
# 3. drivers (once uptime is past 60 s), then the preconditions check (reads only)
tools/phone-ssh 'cut -d. -f1 /proc/uptime; modprobe sec_acpm; modprobe bcm4775x-gnss;
  /usr/lib/omandroid-vendor/omandroid-vendor-chroot gnss check'
#   pass: "preconditions met"
# 4. lhd alone for 60 s: the chip is powered only while lhd holds /dev/ttyBCM open
tools/phone-ssh '(OMANDROID_GNSS_STAGE=lhd OMANDROID_VENDOR_LOGLEVEL=3 timeout 60 \
    /usr/lib/omandroid-vendor/omandroid-vendor-chroot gnss start > /tmp/g3.log 2>&1 &);
  sleep 25; echo "== during"; cat /sys/kernel/debug/spi5.0/pins;
  sleep 45; echo "== after"; cat /sys/kernel/debug/spi5.0/pins;
  for r in /sys/class/regulator/regulator.*; do case $(cat $r/name) in vdd_gnss*) echo $(cat $r/name) $(cat $r/state);; esac; done;
  echo "== log"; tail -n 80 /tmp/g3.log; dmesg | grep -iE "bcm4775|ttyBCM" | tail -5'
```

Pass:
- **During:** `powered: 1`, `nstandby: 1`, `packets` rising, `tx_fail: 0`.
- **Log:** lhd opens the nodes and downloads `SensorHub.patch` without
  errors, and keeps running.
- **After:** `powered: 0`, `nstandby: 0`, all three `vdd_gnss_*` disabled.
  The timeout kills the namespace, lhd's `/dev/ttyBCM` closes, and the
  driver powers the chip down.

Failure clues:
- `nstandby` write errors (`EPERM`): lhd raised standby before opening
  `/dev/ttyBCM`. The driver only allows it while powered. Send the log;
  the fix is a driver change (power on at the nstandby write too).
- `servicemanager` or linker errors: `run`-test a binary inside, e.g.
  `omandroid-vendor-chroot gnss ns ls /dev`, and send the log.

**G3 result (2026-10-12, runner `9163788`):**
- servicemanager starts. lhd starts, reads our lhd.conf and logs only the
  expected errors.
- **lhd never opened `/dev/ttyBCM`:** the chip stayed in standby with its
  rails off, and the stop was clean.
- **What we thought (corrected under G3c):** that lhd waits for gpsd
  before touching the chip. In fact lhd starts the chip at start-up and
  failed within a second; the 25 s sample missed it.
- **`/sys/bbd/lk_enable`:** lhd's "killer" switch. Google's GPL bbd driver
  (the one stock runs) has no such attribute either, so stock lhd logs the
  same error. No stub is needed.
- **gpsd starts a position session only when asked.** The profile now asks
  through gpsd's control pipe (`CtrlPipe`, `/data/vendor/gps/glgpsctrl`)
  with `$pglirm,req_pos,omandroid,period,1000`. The command format and its
  `$pglirm,stop,...` counterpart are strings in gpsd. The NMEA of that
  request goes to the `NmeaOutName` FIFO.
- gpsd runs as a plain daemon by default now (`OMANDROID_GNSS_JOB` empty).

### G3b: lhd + gpsd together, 90 s, indoors

Reinstall the profile (`packages/omandroid-gnss/profiles/gnss.conf`); the tree and
the runner are unchanged. Keep a reader on the NMEA FIFO, so gpsd never
blocks opening it.

```sh
tools/phone-ssh 'install -m644 /dev/stdin /usr/lib/omandroid-vendor/profiles/gnss.conf' < packages/omandroid-gnss/profiles/gnss.conf
tools/phone-ssh 'F=/var/lib/omandroid-vendor/gnss/data/vendor/gps/nmea_out; mkdir -p $(dirname $F); [ -p $F ] || mkfifo -m 600 $F;
  /usr/lib/omandroid-vendor/omandroid-vendor-chroot gnss check;
  (timeout 100 cat $F > /tmp/g3b-nmea.txt &);
  (OMANDROID_VENDOR_LOGLEVEL=2 timeout 90 /usr/lib/omandroid-vendor/omandroid-vendor-chroot gnss start > /tmp/g3b.log 2>&1 &);
  sleep 30; echo "== during"; cat /sys/kernel/debug/spi5.0/pins;
  sleep 70; echo "== after"; cat /sys/kernel/debug/spi5.0/pins;
  for r in /sys/class/regulator/regulator.*; do case $(cat $r/name) in vdd_gnss*) echo $(cat $r/name) $(cat $r/state);; esac; done;
  pgrep -a "lhd|gpsd" || echo "none left"; ls -l /var/lib/omandroid-vendor/gnss/data/vendor/gps/;
  echo "== nmea"; wc -l /tmp/g3b-nmea.txt; grep -E "GSV|RMC|GGA" /tmp/g3b-nmea.txt | tail -8;
  echo "== log"; grep -E "omandroid-vendor|\[gpsd\].* [EFW] |ESW|Broadcom" /tmp/g3b.log | head -40; tail -n 40 /tmp/g3b.log'
```

Pass:
- **During:** `powered 1`, `nstandby 1`, packets rising, `tx_fail 0`.
- **Log:** "control pipe: req_pos"; gpsd identifies the chip as a Broadcom
  BCM477x (expect "BCM4776"); no gpsd exit.
- **NMEA:** GSV sentences. Indoors there may be few or no satellites; RMC
  with status V is fine here.
- **After:** one "stopping", no lhd or gpsd left, `powered 0`, all three
  rails disabled.

If it fails:
- "a service exited" early: send `/tmp/g3b.log` (gpsd failing on binder,
  the RIL client library or the sensor service).
- "no control pipe ... after 60 s": gpsd never created `glgpsctrl`. Send
  the `ls -l` of the gps directory.
- No NMEA but lhd powered the chip: send both files.

**G3c result (2026-10-12, profile `7c281bf`):**
- The RIL stub worked (no SIT RIL failure); one sensor lookup.
- gpsd took the control-pipe request, lhd spent 220 ms on it, then gpsd
  logged `OnChipReset: GPSD exit`.
- The pins showed powered 0 at 30 s and after; no NMEA.

**Why, found offline (lhd verbose, under qemu, `LogLevel=*:V` with
`LogEnabled=true`, `Log=LOGCAT`):** lhd starts the chip on its own at
start-up. G3's "lhd waits for gpsd" was wrong; the pin sampling just
missed it. Its sequence (`BrcmGpsHalGpio::Standby/Normal`, then
`Bbd::Open`):
1. nstandby 0, then 1;
2. 20 ms ("Power enable delay");
3. open `/dev/bbd_control` and `/dev/ttyBCM`;
4. `BBD:PassThru=1`, auto-baud, patch download.

Our driver broke that order in two ways:
1. Writing nstandby=1 while `/dev/ttyBCM` was closed failed with `EPERM`
   (supplies followed the open).
2. Opening `/dev/ttyBCM` then powered the supplies and **forced nstandby
   low**.

So the chip sat in standby while lhd tried to sync with its ROM. lhd then
declares the chip crashed and resets it (`ESW:CRASHED`, gpsd
`OnChipReset`).

**Fix, kernel `omandroid-gnss` @ `7f4083e7c`:** raising nstandby now
powers the supplies itself, and drops them when nstandby falls with nobody
holding the device. The open finds the chip powered and leaves nstandby
alone. The same commit adds bring-up logging (module parameter `events`, on
by default):
- `/dev/ttyBCM` open/close and by whom;
- power on/off;
- every nstandby write with the state it found;
- wake handshake failures, rate limited;
- host requests with empty frames;
- the first 16 SSI frames of each session.

`ssi_dump=1` hex-dumps transfers from the next open. The profile now
makes lhd log verbosely (`OMANDROID_GNSS_LHD_LOG`, default `*:V`).

What else was checked:
- **Word size:** 8-bit vs Google's 32-bit DMA words gives the same bytes
  on the wire; Google's controller swaps bytes for 32-bit words, so its
  byte stream is the same.
- **Read command byte:** 0x70 is what stock sends.
- **host_req interrupt:** delivered as on stock (level, re-armed by the
  worker).
- **Handshake:** none of these explain a failure in the first 220 ms;
  standby does.

### G3d: lhd + gpsd with kernel events and a 200 ms pin sampler

Needs the new module: merge `omandroid-gnss` (`7f4083e7c`) into int,
build, then `bin/omandroid modules && bin/omandroid modules-push`. No
reboot is needed, since only the module changed. Reinstall the profile.

```sh
tools/phone-ssh 'install -m644 /dev/stdin /usr/lib/omandroid-vendor/profiles/gnss.conf' < packages/omandroid-gnss/profiles/gnss.conf
tools/phone-ssh 'rmmod bcm4775x_gnss 2>/dev/null; modprobe bcm4775x-gnss; cat /sys/module/bcm4775x_gnss/parameters/events'
#   expect Y
tools/phone-ssh 'P=/sys/kernel/debug/spi5.0/pins; F=/var/lib/omandroid-vendor/gnss/data/vendor/gps/nmea_out;
  mkdir -p $(dirname $F); [ -p $F ] || mkfifo -m 600 $F;
  /usr/lib/omandroid-vendor/omandroid-vendor-chroot gnss check; dmesg -C;
  (timeout 100 cat $F > /tmp/g3d-nmea.txt &);
  (OMANDROID_VENDOR_LOGLEVEL=2 timeout 90 /usr/lib/omandroid-vendor/omandroid-vendor-chroot gnss start > /tmp/g3d.log 2>&1 &);
  # 200 ms samples for the first 15 s (lhd starts the chip within a second or two), then every 5 s
  for i in $(seq 75); do printf "%s %s\n" "$(date +%s.%N | cut -c1-14)" "$(grep -E "^(powered|nstandby|packets|tx_fail)" $P | tr "\n" " ")"; sleep 0.2; done > /tmp/g3d-pins.txt;
  for i in $(seq 16); do printf "%s %s\n" "$(date +%s.%N | cut -c1-14)" "$(grep -E "^(powered|nstandby|packets|tx_fail)" $P | tr "\n" " ")"; sleep 5; done >> /tmp/g3d-pins.txt;
  echo "== pins (changes only)"; awk "{k=\$0; sub(/^[^ ]* /,\"\",k)} k!=last {print; last=k}" /tmp/g3d-pins.txt;
  for r in /sys/class/regulator/regulator.*; do case $(cat $r/name) in vdd_gnss*) echo $(cat $r/name) $(cat $r/state);; esac; done;
  pgrep -a "lhd|gpsd" || echo "none left";
  echo "== kernel"; dmesg | grep -iE "bcm4775|spi5|ttyBCM" | head -60;
  echo "== nmea"; wc -l /tmp/g3d-nmea.txt; grep -E "GSV|RMC|GGA" /tmp/g3d-nmea.txt | tail -8;
  echo "== lhd"; grep -E "\[lhd\]" /tmp/g3d.log | grep -vE "SetCfgValue|^\[lhd\] $" | head -120;
  echo "== rest"; grep -E "omandroid-vendor|OnChipReset|ESW|CRASH|terminat" /tmp/g3d.log | head -20'
```

Pass:
- **Kernel:** "nstandby <- 0", "nstandby <- 1 … unpowered" followed by
  "power on", "ttyBCM opened by lhd", then rx/tx frames with non-zero
  sizes.
- **Pins:** `powered 1`, `nstandby 1` while lhd runs; packets rising,
  `tx_fail 0`.
- **lhd:** the patch download finishes (`ESW:READY`), with no
  `ROM SYNC failure` and no `ESW:CRASHED`.
- **NMEA:** GSV sentences.
- **After:** one "stopping", nothing left, `powered 0`, rails disabled.

If it still fails, the kernel event lines plus lhd's verbose log show
which step: wake handshake, empty frames, or transfer errors.

### G4: a fix outdoors, unattended, rails off afterwards

Same set-up as G3b (after it passes), plus Wi-Fi in range if possible (orbit predictions and
SUPL; without them a cold start can take several minutes). Everything runs
under systemd with a hard time limit. When it ends, the namespace dies,
`/dev/ttyBCM` closes and the chip loses power, whether the run worked or
not. The phone can be unplugged and carried outside.

```sh
# before going out (USB still connected): drivers loaded as in G3 step 3, then
tools/phone-ssh 'F=/var/lib/omandroid-vendor/gnss/data/vendor/gps/nmea_out;
  mkdir -p $(dirname $F); [ -p $F ] || mkfifo -m 600 $F;
  systemd-run --unit=g4-nmea --property=RuntimeMaxSec=1000 sh -c "cat $F > /var/tmp/g4-nmea.txt";
  systemd-run --unit=g4-gnss --property=RuntimeMaxSec=900 \
    /usr/lib/omandroid-vendor/omandroid-vendor-chroot gnss start;
  sleep 20; systemctl --no-pager status g4-gnss | tail -5; cat /sys/kernel/debug/spi5.0/pins'
#   expect: g4-gnss active, powered 1. Unplug, put the phone outdoors with a clear
#   sky for 10-15 minutes, bring it back, reconnect.
tools/phone-ssh 'systemctl is-active g4-gnss g4-nmea; cat /sys/kernel/debug/spi5.0/pins;
  journalctl -u g4-gnss --no-pager | tail -60; wc -l /var/tmp/g4-nmea.txt;
  grep -E "GSV" /var/tmp/g4-nmea.txt | tail -5; grep -E "RMC" /var/tmp/g4-nmea.txt | grep ",A," | head -3'
#   pass: both units inactive (time limit), powered 0; GSV lines with satellites and
#   SNRs; RMC lines with status A (a fix).
#   empty file: no NMEA from the control-pipe request; repeat with
#   --setenv=OMANDROID_GNSS_JOB=omandroid (job mode) and send both journals.
# stop early at any time (rails go off the same way):
tools/phone-ssh 'systemctl stop g4-gnss g4-nmea; cat /sys/kernel/debug/spi5.0/pins'
```

### G4b: outdoors with assistance (LTO), multi-GNSS check

Like G4, still with the hand-installed runner (G5's package replaces it
afterwards). New since G4 (commits `2873e27`, `cf392de`):
- the chroot gets a hosts file, filled on the host at start;
- the profile downloads `lto2.dat` (4-day orbits) on the host with curl;
- gpsd's own log goes to logcat, so to the journal.

The phone needs internet at start (Wi-Fi in range) for the LTO download.
Without it the run still works, as a cold start.

```sh
# laptop, after git pull: runner + profile (the tree, shim and stubs are unchanged)
tools/phone-ssh 'install -m755 /dev/stdin /usr/lib/omandroid-vendor/omandroid-vendor-chroot' < packages/omandroid-gnss/lib/omandroid-vendor-chroot
tools/phone-ssh 'install -m644 /dev/stdin /usr/lib/omandroid-vendor/profiles/gnss.conf' < packages/omandroid-gnss/profiles/gnss.conf
# drivers as in G3 step 3 (sec_acpm past 60 s uptime), then, USB connected:
tools/phone-ssh 'F=/var/lib/omandroid-vendor/gnss/data/vendor/gps/nmea_out;
  mkdir -p $(dirname $F); [ -p $F ] || mkfifo -m 600 $F;
  systemd-run --unit=g4b-nmea --property=RuntimeMaxSec=1000 sh -c "cat $F > /var/tmp/g4b-nmea.txt";
  systemd-run --unit=g4b-gnss --property=RuntimeMaxSec=900 \
    /usr/lib/omandroid-vendor/omandroid-vendor-chroot gnss start;
  sleep 30; journalctl -u g4b-gnss --no-pager | grep -E "LTO:|resolve|hosts" ; cat /sys/kernel/debug/spi5.0/pins'
#   expect: "LTO: downloaded ~120000 bytes" (or "less than a day old"), no
#   "cannot resolve", powered 1. Unplug; outdoors, clear sky, 10-15 min; reconnect.
tools/phone-ssh 'systemctl is-active g4b-gnss g4b-nmea; cat /sys/kernel/debug/spi5.0/pins;
  N=/var/tmp/g4b-nmea.txt; wc -l $N;
  echo "== talkers"; cut -c2-6 $N | sort | uniq -c | sort -rn | head -20;
  echo "== first fix"; grep -m1 -E "^\\\$G.RMC,[^,]*,A," $N; grep -m3 -E "^\\\$G.GGA" $N | tail -1;
  echo "== last GSA"; grep -E "^\\\$G.GSA" $N | tail -4;
  echo "== assistance"; journalctl -u g4b-gnss --no-pager | grep -iE "lto|xtra|supl|glpals|assist|almanac|ephem" | head -30;
  echo "== gpsd tail"; journalctl -u g4b-gnss --no-pager | tail -40'
# stop early at any time: systemctl stop g4b-gnss g4b-nmea  (rails go off at close)
```

Pass: both units inactive, `powered: 0`; RMC with status `A`; gpsd's log
mentions the LTO file being read or injected.

Reading the talkers:
- `GN` RMC/GGA/GSA with more than one GSA per epoch (one per system),
  or `GL`/`GA`/`GB` sentences: several constellations are in use. Nothing
  to change.
- Only `GP` everywhere and a fix: the fix may still use other systems.
  gpsd's NMEA output may describe GPS satellites only. Stock gps.xml has
  no constellation keys, so the engine runs on its built-in defaults,
  which are stock's. Optional second run with the same commands plus
  `--setenv=OMANDROID_GNSS_NMEA411=1` on the `g4b-gnss` line. This sets
  `EnableNmeaV411` in `<gll>`; 4.11 GSA/GSV carry a system ID field.
- Only `GP` and no fix after 15 min with a clear sky: send the journal.
  The assistance lines show whether LTO was used.

### G5: the package (Location on demand)

`packages/omandroid-gnss` replaces the hand-installed files. Nothing
starts until `omandroid-gnss on`; then GeoClue's NMEA source connecting to
`/run/omandroid-gnss/nmea.sock` starts the bridge, which pulls in the GNSS
stack. When the last client has been gone 60 s the bridge exits, the
stack stops (`StopWhenUnneeded`), `/dev/ttyBCM` closes and the rails go
off. `omandroid-gnss off` stops everything and removes the socket.

The shim and stubs are built on the laptop into `bionic/prebuilt/` (not
committed). The Android tree stays the user's own extract, as before.

```sh
# laptop: the bionic pieces, then the static checks
make -C packages/omandroid-gnss/bionic CLANG=$HOME/android/omandroid/prebuilts/clang/host/linux-x86/clang-r596125/bin/clang \
  BIONIC=$HOME/android/omandroid/bionic/libc CHROOT=$HOME/android/vendor-chroot-work/gnss/root
packages/omandroid-gnss/test/all
# phone: remove the hand-installed copies (pacman would refuse to overwrite them);
# the Android tree in /usr/lib/omandroid-vendor/gnss/{root,MANIFEST,SOURCE,STUBS} stays
tools/phone-ssh 'cd /usr/lib/omandroid-vendor && rm -f omandroid-vendor-chroot profiles/gnss.conf omandroid-fp-shim.so stubs/*.so gnss/props.conf;
  rm -f /etc/modprobe.d/omandroid-gnss.conf /etc/geoclue/conf.d/90-omandroid-gnss.conf;
  rm -f /etc/systemd/system/omandroid-gnss.service /etc/systemd/system/omandroid-gnss-nmea.service; systemctl daemon-reload'
tools/phone-install-package packages/omandroid-gnss      # or tools/repo-build packages/omandroid-gnss + repo-push
tools/phone-ssh 'pacman -S --needed --noconfirm geoclue; omandroid-gnss status'
#   expect: location off, receiver running no, chip powered no (sec_acpm/driver
#   loaded) or unknown (not loaded yet; the start script loads both)
```

`/etc/modprobe.d/omandroid-g1.conf` (blacklists `sec_acpm`) can stay; the
start script loads `sec_acpm` itself. Keep the 30 s rule in mind: don't
switch Location on in the first minute after boot.

```sh
# 1. on, nothing running yet
tools/phone-ssh 'omandroid-gnss on; omandroid-gnss status; ls -l /run/omandroid-gnss/'
#   expect: location on, receiver no, nmea.sock present
# 2. a GeoClue client starts it (indoors is fine for the plumbing)
tools/phone-ssh 'systemctl restart geoclue; (timeout 120 /usr/lib/geoclue-2.0/demos/where-am-i -a 8 -t 110 > /tmp/g5-wai.txt 2>&1 &);
  sleep 30; omandroid-gnss status; journalctl -u omandroid-gnss-nmea -u omandroid-gnss --no-pager -n 20'
#   expect: receiver yes, chip powered yes, "client connected (1)", "first NMEA sentence received"
# 3. idle exit: where-am-i ends at 120 s; 60 s later the stack stops
tools/phone-ssh 'sleep 150; omandroid-gnss status; cat /sys/kernel/debug/spi5.0/pins; cat /tmp/g5-wai.txt | tail -15;
  for r in /sys/class/regulator/regulator.*; do case $(cat $r/name) in vdd_gnss*) echo $(cat $r/name) $(cat $r/state);; esac; done'
#   pass: receiver no, powered 0, vdd_gnss_* disabled; where-am-i printed a location
#   if there was a fix (indoors it may only show Wi-Fi/IP sources or nothing)
# 4. the switch as the desktop user (polkit), then off
tools/phone-ssh 'su - omandroid -c "omandroid-gnss off; omandroid-gnss status --json; omandroid-gnss on; omandroid-gnss status --json"'
tools/phone-ssh 'omandroid-gnss force; sleep 30; omandroid-gnss status; omandroid-gnss unforce; sleep 80; omandroid-gnss status'
#   expect: force runs it with no client; after unforce it stops within ~65 s
tools/phone-ssh 'omandroid-gnss off; omandroid-gnss status'
# rollback: omandroid-gnss off; pacman -R omandroid-gnss
```

The `su` step: polkit allows only the active local session. Over ssh the
`omandroid` user is not active, so the call may be refused there. If so,
try it in a terminal on the phone. Root over ssh skips polkit.

**Quick-settings tile (for the shell):**
- State: `omandroid-gnss status --json` gives
  `{"location":"on|off","running":"yes|no","forced":"yes|no","powered":"yes|no|unknown","installed":true|false}`.
- Toggle: run `omandroid-gnss on` or `omandroid-gnss off` as the user.
  This goes through `omandroid-gnss-location@.service` and polkit, with no
  password.
- Hide the tile when `installed` is false or the command is missing.
- The QML tile itself is left to the shell's owner.

**Boot:**
- `omandroid-gnss on` enables the socket (`sockets.target`), so it
  persists: after a reboot Location is still on, and nothing runs until
  GeoClue connects.
- The hang marker still protects the bring-up. A hang leaves
  `/var/lib/omandroid/gnss-bringup-started`, and later starts are skipped
  until `/usr/lib/omandroid-vendor/omandroid-gnss-start --retry`.

Suspend: with lhd open the host_req line is a wake source; measure the
drain with GNSS running and idle (POWER-PLAN.md) before enabling at boot.

## 5. Risks

- **ACPM bus 1.** First traffic to the sub-PMIC from Linux. Reads only in
  G1; the regmap can't write anything but LDO control registers.
- **Rails.** Only GNSS-only rails are described, at stock's ranges.
- **gph2 is shared with Wi-Fi** (pins 0, 1, 4, 5); the GNSS node claims only
  2 and 3.
- **host_req has no pull** (stock); an interrupt storm would show in
  `/proc/interrupts` in G3.
- **Proprietary blobs** stay on the phone, from the user's image.

## 6. Open questions

1. ~~ABL's LDO9S-11S state~~: off, at stock voltages (G1).
2. Does gpsd's job mode produce NMEA on `nmea_out` (G4)? If not, the bridge
   must speak the HAL's control pipe.
3. Does bionic's resolver work without netd with `ANDROID_DNS_MODE=local` and
   `net.dns1`? If not, LTO/SUPL fail and the first fix is slower (cold start).
4. GeoClue authorization on Omarchy: the package ships `system=true`
   entries for a few apps (G5). A small agent in the shell, with per-app
   prompts, would replace them.
5. PPS: mainline `pps-gpio` on gpp15-1 for time sync, later.
6. Move the fingerprint profile onto the shared runner once it has run on
   the phone (it needs its RPMB, panel and Trusty hooks as profile functions).

## Checkpoint 2026-10-12

**Done (on the phone):**
- G0-G3d passed. lhd powers the chip in about 1.5 s, the patch loads
  (`ESW:READY`), there are no transfer errors, gpsd runs a session
  (control-pipe `req_pos`), NMEA reaches the FIFO, and the rails go off
  cleanly at close.
- G4 (windowsill, unplugged, about 8 min): 17834 NMEA lines, at most 2 GPS
  satellites in view, RMC always V, no fix. Only GP talkers.

**Done (offline, not yet run on the phone):**
- Runner + gnss profile: the chroot gets a hosts file, and HOSTS are
  resolved on the host at start (`gllto2.glpals.com`, `gllto.glpals.com`,
  `supl.google.com`).
  - bionic can't resolve names without netd. This was tested under qemu:
    `getaddrinfo` fails in both resolver modes, and works with
    `/system/etc/hosts`.
  - The LTO file is reachable over plain HTTP from the laptop: 121603
    bytes from `http://gllto2.glpals.com/4day/v5/latest/lto2.dat`.
- gps.xml facts for multi-GNSS:
  - `<hal>` rejects unknown keys and asserts (`EnableGlonass` there kills
    gpsd);
  - `<gll>` silently ignores unknown keys, so a key placed there proves
    nothing;
  - gpsd knows `EnableGlonass`, `EnableGalileo`, `EnableBeidou` and
    `EnableNmeaV411`, but which section they belong to is not known yet.
  - Nothing is changed for constellations yet. The GP-only output may
    simply be the poor sky view: GSV lists tracked satellites only on a
    cold start without assistance.

**Half done:**
- **G5 design** (not written):
  - a systemd socket unit for `/run/omandroid-gnss/nmea.sock`;
  - the bridge started by GeoClue connecting, exiting after an idle period
    with no clients;
  - `omandroid-gnss.service` with `StopWhenUnneeded=yes`, so the stack and
    the rails run only while GeoClue has a client;
  - an `omandroid-gnss on|off|status` command;
  - a new `packages/omandroid-gnss` package, default-off, with the small
    bionic `.so` files (shim, stubs) prebuilt from `packages/omandroid-gnss/bionic/Makefile`.
- **Multi-GNSS:** find the section for the Enable* keys, e.g. by trying
  each one in `<gll_features>` under qemu and watching gpsd's parser.

**Next steps:**
1. On the phone: reinstall the runner and profile (commit `2873e27`, commands below) and
   repeat G4 with Wi-Fi in range. Expect assistance downloads in gpsd's
   log (LTO/SUPL) and a faster fix.
2. Compare talker IDs with a clear sky view before changing constellation
   settings.
3. G5 as designed above.

**Ready to run on the phone** (after `git pull`; the tree, shim and stubs
are unchanged):

```sh
tools/phone-ssh 'install -m755 /dev/stdin /usr/lib/omandroid-vendor/omandroid-vendor-chroot' < packages/omandroid-gnss/lib/omandroid-vendor-chroot
tools/phone-ssh 'install -m644 /dev/stdin /usr/lib/omandroid-vendor/profiles/gnss.conf' < packages/omandroid-gnss/profiles/gnss.conf
# then the G3d command (section 4); check that the log has no "cannot resolve" lines and
# look for LTO/SUPL activity in the gpsd lines, then G4 as before (with Wi-Fi in range)
```

After any unplug/replug, reboot or use the USB rescue watcher (USB-C-PLAN
R1).

## Update 2026-10-12, after the checkpoint (offline)

- **Assistance in G3d:** the G3d log has no gpsd lines at all. gpsd's own
  log was off (stock `LogEnabled="false"`, `Log="JAVA"`), so it can't show
  whether LTO/SUPL were tried. There were no "cannot resolve" lines.
  - Since `cf392de`, gpsd logs to logcat (journal), and the profile fetches
    `lto2.dat` on the host before gpsd starts.
  - G4b checks both.
- **Multi-GNSS:** stock's gps.xml sets no constellation keys, so the
  engine runs on its built-in defaults. Those are what stock ships, and
  nothing is changed.
  - GP-only NMEA may be how gpsd's NMEA output reports satellites. On
    Android the framework's satellite list comes from the HAL callbacks,
    not from this NMEA.
  - `OMANDROID_GNSS_NMEA411=1` is an optional G4b run (`EnableNmeaV411`
    in `<gll>`).
- **G5 package:** `packages/omandroid-gnss` (section 3), default-off.
  `vendor-chroot/` moved into it. The runbooks are G4b and G5 in
  section 4.
