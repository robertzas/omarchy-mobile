# USB-C and charging plan: gates B3 (charger) and B4 (Type-C) (cheetah / gs201)

Follows `WIFI-BATTERY-PLAN.md` sections 4-5 (MAX77759 wiring, gates B1/B1b
done, B2 pending). Written 2026-10-12, offline: nothing here has run on the
phone yet. Kernel: branch `omandroid-usbc` in `~/android/mainline/wt-usbc`,
out dir `~/android/mainline/out-usbc`.

Sources: `L/` = the worktree, `G/` = Google's GPL kernel
(`~/android/omandroid/out-kernel/google/gs-6.1/private`), `R/` = the stock
root capture (`~/android/reference/cheetah-stock-cp2a-root`).

## 1. Facts this plan rests on

| Fact | Evidence |
|---|---|
| The bootloader hands over with the charger in mode 5 (charger + buck on), which stock keeps | B1 read `0x69/0xb9 = 0x05`; `R/dmesg.txt:2408` "CHG_CNFG_00=5->5" |
| The upstream charger driver sets mode OFF at probe and turns charging on only when a power supply named `tcpm-source*` reports online **with a current limit > 0** | `L/drivers/power/supply/max77759_charger.c`, `max77759_charger_init()` and `psy_work_item()` |
| TCPM reports current 0 for a source with Type-C default power (PC ports, USB-A to C cables), because TCPCI has no `get_current_limit` | `L/drivers/usb/typec/tcpm/tcpm.c` `tcpm_get_current_limit()`; `tcpci.c` sets no `get_current_limit`. So upstream TCPM + charger does **not charge** from a default-power port at all |
| Stock's float voltage limit is 4.45 V; its step charging lowers the current at 4.3 and 4.45 V and with temperature | `R/live.dts:18205` `google,fv-max-uv = <4450000>`; `:17774-17776` cv-limits 4.2/4.3/4.45 V, temp limits 0/10/20/42/46/48/55 °C, cc-limits in % of capacity (`G/google-modules/bms/google_bms.c:195-199`) |
| The bootloader leaves a lower float voltage, so charging can stop short of 100 % | to be read in B3.0 (`CHG_CNFG_04`, expect a selector below 45 = 4.45 V) |
| The MAX77759 opens its USB2 data switch (TCPC vendor `USBSW_CTRL`, 0x93) on unplug and Linux never closes it: this is the "USB doesn't come back after a replug" bug (NOTES.md) | Google's driver writes `USBSW_CONNECT` (0x09) on **every** attach with a data role ("b/188614064 ... always enable the switches here", `G/google-modules/soc/gs/drivers/usb/typec/tcpm/google/tcpci_max77759.c:1117-1215`, register in `tcpci_max77759_vendor_reg.h:94-96`). Upstream `tcpci_maxim` writes 0x09 only when a USB PD partner says it is USB communications capable, and 0 on every port reset, including at probe |
| The USB PHY forces VBUS valid unless it is an orientation switch; with `orientation-switch` it leaves VBUS valid entirely to the Type-C driver | `L/drivers/phy/samsung/phy-exynos5-usbdrd.c`, `exynos850_usbdrd_utmi_init()` (`if (!phy_drd->sw)`) and `exynos5_usbdrd_orien_sw_set()` |
| On this board VBUS is sourced by an external boost, not the MAX77759's own reverse boost | `R/live.dts:8366,8375` `max77759,ext-otg-only`, `bst-on` = index 4 of stock's 6-line MAX77759 GPIO chip, i.e. GPIO5 (mainline line 0); `extbst-ctl` = TCPC GPIO 0, which Google's driver maps to vendor reg 0x92 `EXT_BST_EN` (`tcpci_max77759.c:750-780`). Index 5, GPIO6 (mainline line 1), is the VBUS input/OVP switch (`in-switch-gpio`, active low, `R/live.dts:8218`) |
| A panic reboots the phone; a missing USB gadget at boot crashes it after 45 s; after ABL's retries slot A (stock) boots | `device/cheetah/initramfs/init` (self-recovery block), NOTES.md "Slot B fallback works" |
| The s3c2410 watchdog resets the phone about 15 s after its feeder stops | `tools/wifi-w1-capture --watchdog`, NOTES.md "Watchdogs" |

## 2. Order: B3 before B4, with evidence

1. **B3 (charger) never touches the USB data path.** The charger only
   programs mode, float voltage, fast-charge and input current. Its only way
   to hurt the link is to load the laptop's port past its limit, so the
   port cuts VBUS (and, today, data never comes back). The new
   `default_ilim_ua` keeps the input at 500 mA, the USB 2.0 limit every port
   must supply to a configured device.
2. **B4 changes who owns VBUS valid and the data switch**, by design costs
   one re-enumeration when TCPM takes over, and has more ways to fail.
3. **B4 needs the B3 change to charge at all** from the laptop: with TCPM,
   a default-power port reports current 0 and the upstream charger turns
   charging off. With `default_ilim_ua` it charges at 500 mA instead.
4. Without B3, B4 still leaves charging as the bootloader set it (mode 5,
   no driver), so B4 does not depend on B3 for safety. B3 first because it
   is lower risk and B4 benefits from it.

Before both: **R1**, the replug fix by itself (one I2C write, no kernel
change), and a dead-man drill.

## 3. What was built

### Kernel (`omandroid-usbc`, on `omandroid` @ `7b0f8b5d1`)

| Commit | What | Default state |
|---|---|---|
| `power: supply: max77759: zero the regulator and power supply configs` | fix: two stack structs were half uninitialised (masked by `INIT_STACK_ALL_ZERO`) | upstreamable fix |
| `power: supply: max77759: charge at a default input limit without a source report` | `default_ilim_ua` module parameter (max 900 mA): charge from probe without TCPM, use it for an online source with current 0, leave charging on at unbind. Logs `found:` and `probed:` lines with mode, FV, CC, ILIM | parameter 0 = upstream behaviour; module blacklisted |
| `usb: typec: tcpci: let chip drivers follow role changes` | optional `set_roles()` hook in `struct tcpci_data` | no user but tcpci_maxim |
| `usb: typec: tcpci_maxim: connect the USB data switches on attach` | writes `USBSW_CTRL = 0x09` on every TCPM attach, as Google's driver does; PD can still open it | module blacklisted |
| `phy: samsung: usbdrd: keep VBUS valid until Type-C reports a connection` | with an orientation switch, VBUS stays forced valid until the Type-C driver reports an orientation for the first time; writable `force_vbus_valid` parameter forces it again at runtime | no change without `orientation-switch` in the DT |
| `dt-bindings: phy: samsung,usb3-drd-phy: add Google gs201` | the gs201 PHY compatible was undocumented; orientation switch optional | |
| `arm64: dts: exynos: google: gs201-cheetah: charger limits and a sink-only port` | battery `constant-charge-voltage-max` 4.45 V, `constant-charge-current-max` 1.47 A (0.3 C, the lowest stock cc-limit between 10 and 46 °C at any voltage tier); `monitored-battery` on `pmic@66` (the charger cell uses the parent's node); the still disabled connector becomes sink only (no driver for the external boost, so no `vbus-supply`) | TCPC node `disabled` |

Hashes, oldest first: `1074d2178`, `49a930690`, `6cb72374d`, `80ffae6d5`,
`45e5489db`, `06e60a228`, `c86bd2db7`. Built: release
`7.3.0-rc6-omandroid-push1-00065-gc86bd2db7c72`, `kernel`/`modules`/`images`
exit 0 (`logs/kernel-usbc.log`, `modules-usbc.log`, `images-usbc.log`); the
changed C files build W=1 clean; `dt-doc-validate` passes for the PHY
binding; `dt-validate` of the base DTB, base + B4a and base + B4a + B4b
reports only the existing `soc_id` and simplefb `post-init-providers`
messages.

Not changed in the base DT on purpose: the PHY (`orientation-switch`, graph
port) and dwc3 (`dr_mode`, role switch). Those come from overlays, so the
default DTB keeps today's USB exactly.

### omandroid repo

- `device/cheetah/overlays/usbc-tcpm-test.dtso` (B4a): TCPC `okay`, connector
  port@0 <-> PHY port, PHY `orientation-switch`.
- `device/cheetah/overlays/usbc-role-test.dtso` (B4b, on top of B4a): dwc3
  `dr_mode = "otg"`, `usb-role-switch`, default peripheral, connector port@1
  <-> dwc3 port.
- `tools/usbc-deadman` (laptop) and `tools/usbc-deadman-phone` (phone): the
  dead-man switch, register dump, replug rescue.
- No change to `omandroid-max77759.conf`: `max77759`, `max77759_charger`
  and `tcpci_maxim` stay blacklisted; every step loads them by hand.

## 4. The dead-man switch (`tools/usbc-deadman`)

Every risky step runs as `tools/usbc-deadman STEP`:

1. The laptop installs `usbc-deadman-phone` in `/usr/local/bin`, streams
   `/dev/kmsg` into `logs/usbc-STEP-<time>.log` (reconnecting after drops)
   and starts the step **detached** with `systemd-run` (falls back to
   `setsid nohup`), so an SSH drop cannot stop it.
2. On the phone: the hardware watchdog is armed first (refuses to run if
   `/dev/watchdog0` cannot be opened, unless `--no-watchdog`); registers the
   step touches are saved to `/run/usbc-deadman/`; the step is applied;
   everything is logged before it happens to `/dev/kmsg` (pstore) and
   `/var/log/usbc-deadman.log`.
3. The laptop keeps trying **new** SSH logins and runs
   `usbc-deadman-phone confirm` once one works (for `replug`, only after it
   has seen the link drop and come back).
4. No confirmation within `--confirm` seconds (90; replug 120): the phone
   undoes the step (unload the module, restore the saved charger registers,
   `force_vbus_valid=1`), then runs the **rescue**: if the charger sees valid
   VBUS (`CHG_DETAILS_00` bits 6:5 = 3) it writes `USBSW_CTRL = 0x09`. Then it
   waits `--grace` seconds (60) for a confirmation again; the result is
   `reverted`.
5. Still nothing: it stops feeding the watchdog. ~15 s later the phone does a
   warm reset into slot B with all MAX77759 drivers blacklisted (known-good
   USB). If the watchdog was not armed, `sysrq c` (panic=10 reboots).

`tools/usbc-deadman undo STEP` reverts a confirmed step by hand. `--no-confirm`
deliberately lets the undo run (to test it).

### Physical recovery (also printed by the tool)

1. Wait 2 minutes (undo, then watchdog reset, then boot).
2. Unplug and replug once.
3. Hold Power ~30 s (off), press Power: slot B boots with the drivers
   blacklisted.
4. Only after an overlay DTB that kills USB at boot: the initramfs crashes
   after 45 s without a configured gadget; after ABL's retries, stock
   Android boots from slot A; `adb reboot bootloader`, then flash images
   built without the overlay. Keep that out dir (`D.default`) before any
   overlay build.
5. Fastboot by hand: Power ~30 s off, then Volume Down + Power ~20 s until
   "Fastboot Mode".

## 5. Reading the charger read-only first (B3.0)

`tools/usbc-deadman dump` runs `i2cget -f` only (bus = the `10d60000.i2c`
adapter, `i2c-0` in B1). No module needs to be loaded. Expected on the
laptop's port, with only the fuel gauge loaded:

| Reg | Name | Expected | Meaning |
|---|---|---|---|
| 0x69/0xb9 | CHG_CNFG_00 | low nibble **5** | charger + buck on (B1: 0x05) |
| 0x69/0xbd | CHG_CNFG_04 | `CHG_CV_PRM` (bits 5:0) **< 45** | float voltage 4000 + 10 x sel mV; 45 = 4.45 V (stock fv-max). **Write it down**: the bootloader's value is why charging stops short of 100 % |
| 0x69/0xbb | CHG_CNFG_02 | any, write down | fast charge: 200 + (sel - 3) x 66.67 mA (sel >= 3) |
| 0x69/0xc2 | CHG_CNFG_09 | any, write down | input limit: 100 + (sel - 3) x 25 mA; bit 7 NO_AUTOIBUS |
| 0x69/0xbf | CHG_CNFG_06 | bits 3:2 = **0** | protected registers locked |
| 0x69/0xc5 | CHG_CNFG_12 | bit 5 (CHGINSEL) = **1** | USB input enabled |
| 0x69/0xcb | CHG_CNFG_18 | bit 0 (WDTEN) = **0** | no charger watchdog (if 1, charging stops 80 s after nobody kicks it; the driver clears it) |
| 0x69/0xb5 | CHG_DETAILS_00 | bits 6:5 = **3** | VBUS valid |
| 0x69/0xb6 | CHG_DETAILS_01 | CHG_DTLS (3:0) 1/2/3/4, BAT_DTLS (6:4) 3 | CC / CV / top-off / done; battery OK |
| 0x25/0x00-01 | VENDOR_ID | **0x6a 0x0b** | Maxim (0x0b6a) |
| 0x25/0x93 | USBSW_CTRL | **0x09** while the link works | data switch closed |

Stop if mode is not 5, WDTEN is 1, the vendor ID is wrong, or reads fail.

## 6. Runbook

Shorthand: `O=~/android/mainline/out-usbc`,
`D=$O/arch/arm64/boot/dts/exynos/google/gs201-cheetah.dtb`. Second terminal:
`tools/phone-ssh dmesg -w`. Battery above 50 %, phone at room temperature.

### R0: dead-man drill (current kernel is fine)

```sh
tools/phone-ssh 'pacman -S --needed --noconfirm i2c-tools'
tools/usbc-deadman install
tools/usbc-deadman dump                       # section 5 table; keep the output
tools/usbc-deadman noop                       # expect: CONFIRMED within ~10 s
tools/usbc-deadman noop --no-confirm          # expect: REVERTED after ~90 s, link up
```

**Pass:** both results as stated, watchdog disarmed (`usbc-deadman log`),
no reset. If the phone resets during the second one, the confirm path is
broken: stop and fix the tool before any real step.

### R1: the replug fix alone (current kernel is fine)

The PHY forces VBUS valid today, so the gadget never notices an unplug; only
the data switch is open after a replug. Closing it is the whole fix until B4.

```sh
tools/phone-ssh 'systemd-run --unit=usbc-rescue-watch /usr/local/bin/usbc-deadman-phone rescue-watch'
tools/usbc-deadman replug     # unplug, wait 5 s, replug (try the other cable orientation too)
```

**Pass:** `CONFIRMED` after the replug, the phone log shows
`rescue: VBUS valid, USBSW_CTRL was 0x00` then `i2cset 0x25 reg 0x93 = 0x09`.
Even without the watcher, `replug` ends `REVERTED` (its undo runs the
rescue), which proves the same thing more slowly. Stop the watcher with
`systemctl stop usbc-rescue-watch` before B4 (TCPM owns the switch then).
Packaging the watcher as a service is a follow-up if B4 is far off.

### B3: charger

```sh
# B3.1 new kernel and modules (default DTB, no overlay); everything still blacklisted
KERNEL_DIR=~/android/mainline/wt-usbc KERNEL_OUT=$O bin/omandroid modules > logs/modules-usbc.log 2>&1
KERNEL_DIR=~/android/mainline/wt-usbc KERNEL_OUT=$O bin/omandroid images > logs/images-usbc.log 2>&1
KERNEL_OUT=$O bin/omandroid modules-push && KERNEL_OUT=$O bin/omandroid push
tools/phone-ssh 'cat /sys/module/phy_exynos5_usbdrd/parameters/force_vbus_valid'   # N
tools/usbc-deadman dump                       # same as R0 (the battery node changed, nothing else)
# B3.2 MFD core + GPIO (gate B2) under the dead-man
tools/usbc-deadman b2-core
#   pass: max77759 bound, gpiochip "max77759-gpio" with 2 lines, `grep gpa9 /proc/interrupts`
#         twice a few seconds apart: no storm. Nothing may request GPIO5/GPIO6.
# B3.3 the charger, 500 mA input
tools/usbc-deadman b3-charger --ilim 500000
```

**B3.3 pass** (the tool prints the dump and dmesg once confirmed):

- dmesg `max77759-charger ...: found: mode 0x5, float voltage <bootloader> mV,
  ...` then `probed: mode 0x5, float voltage 4450 mV, fast charge 1466730 uA,
  input limit 500000 uA`.
- dump: `CHG_CNFG_04` sel 45, `CHG_CNFG_02` sel 22, `CHG_CNFG_09` sel 19,
  mode 5, `CHG_DTLS` 1 (CC) or 2 (CV), `USBSW_CTRL` 0x09.
- `/sys/class/power_supply/max77759-charger/`: `online` 1, `status`
  Charging, `constant_charge_voltage_max` 4450 (the upstream driver reports
  mV here, not µV), `input_current_limit` 500000.
- The gauge's `current_now` is positive and at most ~550 mA.
- Watch 10 minutes: gauge `temp` rises less than 5 °C; no
  "Battery over-current" lines; link stays up.

**B3.4 (attended):** leave it on the cable until full. **Pass:** CV phase
near 4.45 V, then `CHG_DTLS` 3/4 (top-off/done), capacity 100 %. **Fail
actions:** `tools/usbc-deadman undo b3-charger` restores the bootloader's
registers.

**Not yet safe to make permanent.** Without Google's google_battery there is
no temperature policy: stock stops charging above 4.3 V below 10 °C or
between 46 and 48 °C, above 4.2 V from 48 to 55 °C, and completely outside
0-55 °C. Whether the MAX77759's
own JEITA (`CHG_DTLS` 0xc) is configured by the bootloader is unknown.
Before `options max77759_charger default_ilim_ua=500000` goes into the
device package, add a temperature guard (a small userspace or kernel policy
that sets mode OFF outside 10-45 °C from the gauge's `temp`).

### B4a: TCPM drives VBUS valid and the data switch (device only)

```sh
# B4a.1 DTB with the overlay; keep the default one for recovery
cp "$D" "$D.default"
$O/scripts/dtc/dtc -q -I dts -O dtb -o out/usbc-tcpm-test.dtbo device/cheetah/overlays/usbc-tcpm-test.dtso
$O/scripts/dtc/fdtoverlay -i "$D.default" -o "$D" out/usbc-tcpm-test.dtbo
KERNEL_DIR=~/android/mainline/wt-usbc KERNEL_OUT=$O bin/omandroid images > logs/images-usbc-b4a.log 2>&1
cp -r $O/images $O/images.b4a
KERNEL_OUT=$O bin/omandroid push
tools/phone-ssh 'ls /proc/device-tree/soc@0/phy@11200000/; cat /sys/module/phy_exynos5_usbdrd/parameters/force_vbus_valid;
  cat /sys/class/udc/*/state; ls /sys/bus/i2c/devices/ | grep 0025'
```

**B4a.1 pass:** boots with USB as before (the PHY keeps VBUS forced until a
Type-C driver speaks), `orientation-switch` and `port` listed, `N`,
`configured`, client `0-0025` present but unbound. **Fail** (no USB at
boot): the initramfs crash/slot A path, section 4 step 4.

```sh
# B4a.2 TCPM takes over (one re-enumeration of the link is expected)
tools/usbc-deadman b4a-tcpm
```

**B4a.2 pass:**

- dmesg: `usbdrd31 ... Type-C reported orientation 0, VBUS valid follows it
  from now on`, then the gadget reconnecting.
- `cat /sys/class/typec/port0/{power_role,data_role,power_operation_mode}`:
  `[sink]`, `host [device]`, `default` / `1.5A` / `3.0A`;
  `/sys/class/typec/port0-partner` exists.
- `/sys/class/power_supply/tcpm-source-psy-0-0025/online` 1, `current_max`
  0 (default power) or 1500000/3000000.
- `usbc-deadman-phone dump`: `USBSW_CTRL` 0x09. With the B3 charger loaded:
  mode 5 and input limit = `current_max`, or 500000 for default power.
- TCPM's own log: `cat /sys/kernel/debug/usb/tcpm-0-0025` (debugfs).

```sh
# B4a.3 the replug bug, now fixed in the kernel (rescue-watch NOT running)
tools/usbc-deadman replug       # unplug 5 s, replug; then again in the other orientation
```

**B4a.3 pass:** `CONFIRMED`; dmesg shows the detach (orientation 0, VBUS
valid dropped, gadget disconnect) and the attach (orientation 1 or 2). This
is the "USB doesn't reconnect after unplugging" fix for NOTES.md.

### B4b: dwc3 behind the role switch

```sh
$O/scripts/dtc/dtc -q -I dts -O dtb -o out/usbc-role-test.dtbo device/cheetah/overlays/usbc-role-test.dtso
$O/scripts/dtc/fdtoverlay -i "$D.default" -o "$D" out/usbc-tcpm-test.dtbo out/usbc-role-test.dtbo
KERNEL_DIR=~/android/mainline/wt-usbc KERNEL_OUT=$O bin/omandroid images > logs/images-usbc-b4b.log 2>&1
KERNEL_OUT=$O bin/omandroid push
tools/phone-ssh 'cat /sys/class/usb_role/*/role; cat /sys/class/udc/*/state'   # device, configured
tools/usbc-deadman b4b-role
tools/usbc-deadman replug
```

The UDC now appears from dwc3's role-switch work, slightly later; the
initramfs waits up to 30 s for it. **Pass:** as B4a, plus
`/sys/class/usb_role/11210000.usb-role-switch/role` = `device` after TCPM.

### After B4b: make it the default

Fold both overlays into `gs201-cheetah.dts` (that is also what upstream
wants: gs101 has the same graph), remove `tcpci_maxim` from the blacklist,
stop shipping the rescue watcher. Keep `force_vbus_valid` as the recovery
knob.

### B4c: host mode (design only)

- Needs VBUS sourcing. Stock uses the **external boost**
  (`max77759,ext-otg-only`): MAX77759 GPIO5 (`bst-on`) plus TCPC
  `EXTBST_CTRL` (0x92 bit 0), with the OVP input switch (GPIO6) toggled
  around it (`tcpci_max77759.c:754-778`, "b/309900468"). Upstream has only the
  charger's reverse boost (`chgin-otg-regulator`, mode 0xA); whether that
  path is usable on cheetah with the input switch is unknown. Candidate: a
  small regulator for the external boost in `tcpci_maxim` (EXTBST_CTRL)
  plus a `gpio` enable on MAX77759 GPIO5, as `vbus-supply`.
- Then the connector goes back to `power-role = "dual"`,
  `try-power-role = "sink"`, and the stock source PDO (5 V, 900 mA).
- Testing host mode unplugs the laptop, so the test must run detached:
  apply, wait for the keyboard/drive to enumerate, write `lsusb` to a file,
  `echo sink > /sys/class/typec/port0/port_type` after N seconds, then
  replug the laptop. Better with Wi-Fi (gate W3) as a second way in.
- USB PD (`pd-disable` off) and SuperSpeed (lane muxing by orientation,
  `maximum-speed`) are later steps.

## 7. Risks

| Risk | Mitigation |
|---|---|
| Laptop port cuts VBUS when the charger draws more | 500 mA default (USB 2.0), capped at 900 mA in the driver; AICL in the chip; dead-man undo + rescue |
| Charging outside a safe temperature (no step charging) | attended tests only; CC 0.3 C; temperature guard before making it default |
| `tcpci_maxim` probe drops the link | sink-only port: no DRP toggling, so the laptop never sees Rp from us and the contaminant check (which runs only while toggling) never runs; the PHY keeps VBUS until TCPM reports; dead-man undo forces VBUS valid, unloads TCPM, closes the switch |
| Overlay DTB breaks USB at boot | nothing loads TCPM at boot (blacklist), PHY change keeps VBUS forced; worst case the initramfs crash -> slot A path |
| `dr_mode = "otg"` changes the boot path | separate gate (B4b), after B4a passed |
| Watchdog cannot be armed (in use) | the tool refuses; `--no-watchdog` falls back to a crash reboot |
| Something requests MAX77759 GPIO5/6 | nothing in the DT does; GPIO6 is the VBUS input switch: never drive it during bring-up |
