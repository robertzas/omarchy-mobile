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

| Path | What |
|---|---|
| `vendor-chroot/omandroid-vendor-chroot` | shared runner, `PROFILE check / start / ns / run`; grown from `fingerprint/omandroid-fp-chroot` (same tmpfs chroot, property store, shim, binderfs, supervision); profiles hold what differs |
| `vendor-chroot/profiles/gnss.conf` | binds `/dev/ttyBCM`, `/dev/bbd_*` and the `nstandby` attribute; writes lhd.conf/gps.xml from the image with the nstandby path, `/data` logs, `PpsEnable=false` and a `<job id="omandroid">` (continuous `req_pos`); runs `lhd`, then `gpsd -c gps.xml omandroid` |
| `vendor-chroot/gnss/props.conf` | `ro.hardware`, `net.dns1/2` (bionic resolver without netd, `ANDROID_DNS_MODE=local`) |
| `vendor-chroot/stubs/` | `libcom.android.tethering.connectivity_native.so` stand-in: `libandroid_net` (gpsd) needs one symbol from the compressed tethering APEX |
| `vendor-chroot/Makefile` | builds the shim (from `fingerprint/shim`) and the stub for bionic |
| `vendor-chroot/gnss/omandroid-gnss-start` | hang-safe start (marker file, as `omandroid-wifi-start`), `modprobe bcm4775x-gnss`, then the runner |
| `vendor-chroot/gnss/omandroid-gnss-nmea` | reads the FIFO, forwards checksummed sentences to `/run/omandroid-gnss/nmea.sock` (GeoClue) and a pty at `/run/omandroid-gnss/nmea-tty` (Linux gpsd) |
| `vendor-chroot/gnss/*.service` | `omandroid-gnss.service`, `omandroid-gnss-nmea.service`; not enabled |
| `vendor-chroot/gnss/geoclue-omandroid-gnss.conf` | `[network-nmea] nmea-socket=/run/omandroid-gnss/nmea.sock` |
| `vendor-chroot/gnss/modprobe-omandroid-gnss.conf` | `blacklist bcm4775x_gnss` |
| `tools/extract-vendor-chroot` | `-p gnss`: lhd, gpsd, SensorHub.patch, configs, servicemanager, CA store and the library closure, from the user's factory image |
| `device/cheetah/overlays/gnss-pmic-test.dtso`, `gnss-test.dtso` | G1, G2 |

Offline results: `tools/extract-vendor-chroot -p gnss` on
`image-cheetah-cp2a.260705.006.zip` gives 264 files, 28 MB (`X/`), closure
complete with the one stub. `make -C vendor-chroot CLANG=... BIONIC=...
CHROOT=X/root` builds both `.so` files. The generated lhd.conf/gps.xml were
diffed against stock: only the four intended changes.

**For apps:** Firefox and GNOME apps use GeoClue. GeoClue only answers apps
an agent authorizes, or ones listed with `system=true` in its config; on
Omarchy there is no agent yet. For the first tests use `where-am-i`
(geoclue demo) as root or `gpspipe -r`; the agent question is section 6.

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
tools/phone-ssh 'install -m644 /dev/stdin /etc/modprobe.d/omandroid-gnss.conf' < vendor-chroot/gnss/modprobe-omandroid-gnss.conf
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

### G3: lhd loads the patch

```sh
# laptop, once: build and copy the chroot pieces
make -C vendor-chroot CLANG=$HOME/android/omandroid/prebuilts/clang/host/linux-x86/clang-r596125/bin/clang \
  BIONIC=$HOME/android/omandroid/bionic/libc CHROOT=$HOME/android/vendor-chroot-work/gnss/root
tar -C ~/android/vendor-chroot-work/gnss -cf - root MANIFEST SOURCE STUBS |
  tools/phone-ssh 'mkdir -p /usr/lib/omandroid-vendor/gnss && tar -C /usr/lib/omandroid-vendor/gnss -xf -'
tar -C vendor-chroot -cf - omandroid-vendor-chroot profiles gnss/props.conf gnss/omandroid-gnss-start gnss/omandroid-gnss-nmea |
  tools/phone-ssh 'tar -C /usr/lib/omandroid-vendor -xf - && mv /usr/lib/omandroid-vendor/gnss/omandroid-gnss-* /usr/lib/omandroid-vendor/'
tar -C vendor-chroot/out -cf - omandroid-fp-shim.so stubs | tools/phone-ssh 'tar -C /usr/lib/omandroid-vendor -xf -'
# phone
tools/phone-ssh '/usr/lib/omandroid-vendor/omandroid-vendor-chroot gnss check'
tools/phone-ssh 'OMANDROID_GNSS_STAGE=lhd timeout 60 /usr/lib/omandroid-vendor/omandroid-vendor-chroot gnss start 2>&1 | tail -40;
  cat /sys/kernel/debug/spi5.0/pins'
#   pass: lhd opens the nodes, raises nstandby, downloads SensorHub.patch without
#   errors and keeps running; "packets" > 0, tx_fail 0. After the timeout: powered 0.
```

### G4: a fix

Outdoors, sky view, Wi-Fi up (LTO/SUPL).

```sh
tools/phone-ssh 'timeout 300 /usr/lib/omandroid-vendor/omandroid-vendor-chroot gnss start > /tmp/gnss.log 2>&1 &
  sleep 20; timeout 240 cat /var/lib/omandroid-vendor/gnss/data/vendor/gps/nmea_out | grep -E "GSV|RMC|GGA" | tail -20'
#   pass: GSV sentences with satellites and C/N0, then RMC with status A
#   nothing on the FIFO: try OMANDROID_GNSS_JOB= (gpsd as a plain daemon), see
#   open question 4; keep /tmp/gnss.log
```

### G5: Linux side and boot integration

```sh
tools/phone-ssh 'pacman -S --needed geoclue gpsd'
tools/phone-ssh 'install -Dm644 /dev/stdin /etc/geoclue/conf.d/90-omandroid-gnss.conf' < vendor-chroot/gnss/geoclue-omandroid-gnss.conf
for u in omandroid-gnss.service omandroid-gnss-nmea.service; do
  tools/phone-ssh "install -m644 /dev/stdin /etc/systemd/system/$u" < vendor-chroot/gnss/$u; done
tools/phone-ssh 'systemctl daemon-reload; systemctl start omandroid-gnss; sleep 60;
  systemctl status --no-pager omandroid-gnss-nmea | tail -3; gpspipe -r -n 20 tcp://localhost 2>/dev/null ||
  (gpsd -n /run/omandroid-gnss/nmea-tty && sleep 5 && gpspipe -w -n 10)'
#   then GeoClue: /usr/lib/geoclue-2.0/demos/where-am-i -t 60
#   boot: systemctl enable omandroid-gnss (after two good manual runs); a hang
#   leaves /var/lib/omandroid/gnss-bringup-started and the next boot skips GNSS
```

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

1. ABL's LDO9S-11S state (G1).
2. Does gpsd's job mode produce NMEA on `nmea_out` (G4)? If not, the bridge
   must speak the HAL's control pipe.
3. Does bionic's resolver work without netd with `ANDROID_DNS_MODE=local` and
   `net.dns1`? If not, LTO/SUPL fail and the first fix is slower (cold start).
4. GeoClue authorization on Omarchy: a small agent in the shell, or
   `system=true` entries per app.
5. PPS: mainline `pps-gpio` on gpp15-1 for time sync, later.
6. Move the fingerprint profile onto the shared runner once it has run on
   the phone (it needs its RPMB, panel and Trusty hooks as profile functions).
