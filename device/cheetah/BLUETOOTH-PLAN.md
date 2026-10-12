<!-- SPDX-License-Identifier: MIT -->
# Bluetooth plan (cheetah / gs201): BCM4389 on the APM UART

Status: **BT0 (offline) done, 2026-10-12. Nothing has run on the phone.**
Kernel branch `omandroid-bt` in `~/android/mainline/wt-bt` (out dir
`out-bt`), on `omandroid` @ `e7cb10fe5`. Everything new is off by default;
bring-up uses the overlays in `device/cheetah/overlays/bt-*.dtso` and
`tools/bt-uart-test`. This replaces section 3 of `WIFI-BATTERY-PLAN.md`
(which now points here). Bluetooth does not depend on any of the Wi-Fi or
PCIe work.

Path abbreviations as in `WIFI-BATTERY-PLAN.md`: `L/` = our kernel
(`wt-bt`), `G/` = Google's GPL kernel (`out-kernel/google/gs-6.1/private`),
`GS/` = `G/google-modules/soc/gs`, `R/` = stock captures
(`reference/cheetah-stock-cp2a-root`), `V/` = the LineageOS vendor blobs
(`~/android/omandroid/vendor/google/cheetah/proprietary/vendor`).

---

## 1. Hardware, with evidence

| Item | Value | Evidence |
|---|---|---|
| UART | APM USI1 UART at **`0x181b0000`**, GIC SPI **69**, FIFO 256, 32-bit access; stock name `ttySAC18` | `R/live.dts:9369-9389`; `G/devices/google/gs201/dts/gs201-usi.dtsi:1079-1102`; `V/etc/bluetooth/bt_vendor_overlay.conf:4` |
| USI wrapper | Yes, the standard USIv2 one at UART base **+0xc0**: `USI_CON` at +0xc4, `USI_OPTION` at +0xc8. Google sets `CLKREQ_ON` (UART Rx needs the clock while idle) | `GS/drivers/tty/serial/exynos_tty.c:290-307` (`usi-serial-v2`) |
| USI mode | `sysreg_apm` SW_CONF at **`0x180204e4`** := 1 (UART). Stock logs "set usi mode - 0x1" | `R/live.dts:7669-7673` (sysreg at `0x180204e0`, usi-offset 4); `R/dmesg.txt:967`; `exynos_tty.c:2653-2667` |
| UART clocks | CMU_APM (`0x18000000`): `MUX_CLKCMU_APM_FUNC` (0x1000, sel [1:0]: osc, FUNCSRC, pad 100 MHz, osc) <- `MUX_CLKCMU_APM_FUNCSRC` (0x1004: PLL_ALV/2 394 MHz, /4 197, /16 50, /8 99) -> gate `APM_FUNC` (0x2084) -> `DIV_CLK_APM_USI1_UART` (0x1814, 7 bits) -> gates IPCLK 0x20ac, PCLK 0x20b0, reset-sync 0x2100 | `GS/.../cal-if/gs201/cmucal-sfr.c:188-191,644,1076,1104,1107,1111`; `cmucal-node.c:145-156,3530-3535` |
| UART clock rate | **197 MHz** (`DIV_CLK_APM_USI1_UART` ratio 1 from 394 MHz). Stock clock names: "gate" = `MUX_APM_FUNC`, "ipclk" = `DOUT_CLK_APM_USI1_UART`; both hardware auto-gated (`HWACG_VCLK`) | `GS/.../cal-if/gs201/cmucal-vclk.c:4615-4616` (LUT 197000 kHz); `GS/drivers/clk/gs/clk-gs201.c:95-101,1107-1112` |
| UART pins | `gpa3-0..3` (ALIVE) function 2, no pull: RXD, TXD, RTS_N, CTS_N | `R/live.dts:2887-2912` |
| BT_REG_ON | **`gpp16-2`** on PERIC0 (`pinctrl@10840000`, stock `pinctrl_4`, SPI 664), output, active high | `R/live.dts:3539-3543,4218-4226,12683` |
| BT_DEV_WAKE | `gpp16-3`, output, active high | `R/live.dts:4228-4235,12685` |
| BT_HOST_WAKE | `gpa6-6` (FAR_ALIVE, EINT, SPI 50), pull-down, active high ("IRQ: 475 active: High") | `R/live.dts:3119-3126,12684`; `R/dmesg.txt:4406` |
| Wi-Fi power | `WL_REG_ON` is `gph2-4` on HSI2, a different pin. **BT is powered alone by BT_REG_ON**; no shared regulator in the stock DT (`goog,nitrous` has no supplies) | `WIFI-BATTERY-PLAN.md` 1.2; `R/live.dts:12679-12688` |
| Power-on delay | stock HAL waits 100 ms after BT_REG_ON | `V/etc/bluetooth/bt_vendor.conf:25` (`BigHammerBtRegOnDelay = 100`) |
| BD address | ABL writes `/chosen/config/bt_addr` (a string) into the DT it boots | `R/live.dts:12657-12664` |
| Firmware | `V/firmware/brcm/BCM.hcd`: `BCM4389C1 ES1PX_GG_C10`, 478,867 bytes = 3061 Write RAM (0xfc4c) records + 1 Launch RAM (0xfc4e), max 255 bytes each | the file itself (parsed offline) |
| Stock driver | `goog,nitrous` (power + LPM only); the HAL opens the tty itself. Stock HAL leaves `FastDownloadDisable = false` | `R/live.dts:12679-12688`; `V/etc/bluetooth/bt_vendor.conf:15` |

The stock BT pins also carry `pin-con-pdn`/`pin-pud-pdn` (suspend states:
BT_REG_ON "previous", BT_DEV_WAKE pull-down). That matters once the kernel
suspends; until then it is ignored.

## 2. Design

### 2.1 Clocks: a read-only CMU_APM subset (not a fixed clock)

The old blocker was "no CMU_APM driver". A `fixed-clock` at the stock rate
would have worked only if the firmware left the divider at /2, which we can't
know offline, and it would hide a wrong rate as garbage on the wire. Instead
`clk-gs201.c` gains a CMU_APM provider that **describes the real tree but
never writes it**:

- muxes `CLK_MUX_READ_ONLY`, divider `CLK_DIVIDER_READ_ONLY`;
- no `clk_regs` (so no init-time `GATE_MANUAL` writes and no suspend/resume
  register save/restore), no `option_offset` (the CMU controller option
  register stays as the APM firmware set it);
- gates in the framework's automatic mode (the node's `reg` is 64 KiB), where
  enable/disable are no-ops and `is_enabled` reads the gate's debug register
  (+0x4000); `gout_apm_func` is also `CLK_IS_CRITICAL`, so it can never be
  gated whatever the mode;
- no `samsung,sysreg`, so no DRCG write to `sysreg_apm` (the driver prints
  "Unable to get CMU sysreg", as for our other gs201 CMUs).

So the OS only *reads* CMU_APM, and `clk_summary` shows what the firmware
left. The UART's rate comes from the real divider. Only the UART path is
described (`google,gs201.h`: `CLK_APM_*`, `CLK_MOUT_APM_FUNC{,SRC}`,
`CLK_GOUT_APM_FUNC`, `CLK_DOUT_APM_USI1_UART`, three USI1 gates). Google's own
AP kernel reads and writes these registers (`cal-if` maps `CMU_APM`,
`cmucal-sfr.c:22`), so they are non-secure and powered while the AP runs.

The ALIVE/FAR_ALIVE pin controllers still use `clocks = <0>`; moving them to
`CMU_APM` gates is a later, separate change (their gates are not described yet).

### 2.2 USI, sysreg, pinctrl

- `sysreg_apm: syscon@18020000` (`google,gs201-apm-sysreg`, no clock, as gs101).
- `usi_apm1: usi@181b00c0` (`google,gs201-usi`, `samsung,exynos850-usi`):
  `samsung,sysreg = <&sysreg_apm 0x4e4>`, `samsung,mode = <USI_MODE_UART>`,
  `samsung,clkreq-on`. The upstream USI driver then does exactly what Google's
  UART driver does: SW_CONF = 1, clear `USI_CON` reset, set `USI_OPTION`
  CLKREQ_ON.
- `serial_apm1: serial@181b0000` (`google,gs201-uart`, `google,gs101-uart`,
  binding updated; no driver change). No `serialN` alias: with
  `CONFIG_SERIAL_SAMSUNG_UARTS=4`, alias 18 would fail, so the port is
  `ttySAC0` (the only Samsung UART in our DT).
- `pinctrl_peric0: pinctrl@10840000` (alias `pinctrl4`, SPI 664, pclk
  `CLK_GOUT_PERIC0_GPIO_PERIC0_PCLK`) with banks `gpp0`-`gpp19` (driver data
  already upstream: `pinctrl-exynos-arm64.c`, `gs201_pin_peric0`).
- `uart_apm1_bus` pin group in `gs201-pinctrl.dtsi`; `bt_reg_on`,
  `bt_dev_wake`, `bt_host_wake` in `gs201-cheetah.dts`.

### 2.3 The Bluetooth node

```dts
&serial_apm1 {
	bluetooth {
		compatible = "brcm,bcm4389-bt";
		shutdown-gpios = <&gpp16 2 GPIO_ACTIVE_HIGH>;        /* BT_REG_ON */
		device-wakeup-gpios = <&gpp16 3 GPIO_ACTIVE_HIGH>;   /* BT_DEV_WAKE */
		interrupts-extended = <&gpa6 6 IRQ_TYPE_EDGE_RISING>;
		interrupt-names = "host-wakeup";   /* rising = active high to hci_bcm */
		max-speed = <3000000>;
		status = "disabled";
	};
};
```

No `clocks`: the 32.768 kHz LPO comes from the PMIC and the stock DT gives
the BT core none, so ABL leaves it running (an assumption, checked at BT1.3).

### 2.4 Driver path, firmware name, baud rates

`hci_uart` (module) with `CONFIG_BT_HCIUART_BCM=y` and `btbcm` (module), all
already in our config. Our earlier commit added `brcm,bcm4389-bt` to
`hci_bcm`. Sequence (`L/drivers/bluetooth/hci_serdev.c:178-214`,
`hci_bcm.c:440-653`, `btbcm.c`):

1. `bcm_open`: BT_REG_ON high (via the GPIO), tty at **115200** (the chip's
   power-on rate), RTS/CTS on.
2. Because `max-speed` is set, `hci_uart_setup` sends Broadcom Update
   Baudrate (0xfc18) for **3000000** and switches the host, **before** the
   firmware download (no 0xfc45 clock VSC is needed at exactly 3 Mbaud).
3. `btbcm_initialize`: HCI_Reset, Read Local Version, "BCM: chip id N",
   features, local name, then the patch. The LMP subversion has no entry in
   `bcm_uart_subver_table`, so the names tried are
   `brcm/BCM.google,gs201-cheetah.hcd` then `brcm/BCM.hcd` (board name = the
   first root compatible). `tools/extract-vendor-firmware` already writes the
   first one under `/usr/lib/firmware/updates/brcm/`.
4. Download Minidriver (0xfc2e), 50 ms, the 3061 Write RAM records each
   waiting for Command Complete, Launch RAM, 250 ms; the chip is back at
   115200, so `bcm_setup` drops the host to 115200, sets 3 Mbaud again, and
   `btbcm_finalize` re-reads the version (now the patched one).
5. Sleep mode VSC (0xfc27) with host-wake active high; runtime PM drives
   BT_DEV_WAKE.

At 3 Mbaud on a 197 MHz clock the UART divider is 4 + 2/16, about 0.5 %
error, within UART tolerance.

**Fallback built in, off by default:** `btbcm.patchram_nowait=1` streams the
Write RAM records without waiting for each Command Complete (UART flow
control paces them, plus 1-2 ms per record) and waits only for Launch RAM.
The stock HAL runs with "fast download" enabled, so it is possible this chip
does not acknowledge every record; if BT2 stops at
`BCM: Patch command fc4c failed (-110)`, this is the next try. It is a
bring-up knob, not meant for upstream as is.

## 3. Kernel commits (`omandroid-bt`)

| Commit | What |
|---|---|
| `c059c9f2a` dt-bindings: clock: google,gs201: add CMU_APM | binding + 12 IDs |
| `13b9350ba` dt-bindings: soc: samsung: exynos-sysreg: add gs201 APM sysreg | |
| `9e489c0b2` dt-bindings: serial: samsung: add Google gs201 UART | gs201 with gs101 fallback |
| `d0eb1ab5e` clk: samsung: gs201: add a read-only CMU_APM subset for the APM UART | 2.1 |
| `b5f61a9bc` arm64: dts: exynos: google: gs201: add the APM UART, CMU_APM and PERIC0 pinctrl | all `disabled` except the inert syscon |
| `8d84a3cd7` arm64: dts: exynos: google: gs201-cheetah: describe the BCM4389 Bluetooth | child `disabled` |
| `d273f95bf` Bluetooth: btbcm: add a patchram_nowait bring-up option | default off |

Checks: full build clean, W=1 clean for `clk-gs201.c` and `btbcm.c`,
checkpatch `--strict` clean, `dt-doc-validate` clean for the three bindings,
`dt-validate` of the default DTB and of the DTB with `bt-hci-test` applied
shows no new warnings (only the two existing ones: `soc_id`,
framebuffer `post-init-providers`), dtc adds no warnings.

The `hci_bcm` compatible and its binding were already on the branch.

## 4. Runbook (on the phone; each step has its rollback)

From the omandroid repo, phone in Arch over USB, a second terminal running
`tools/phone-ssh dmesg -w`. Overlays are applied to the built DTB exactly as
for Wi-Fi (`WIFI-BATTERY-PLAN.md` 7.5).

```sh
export KERNEL_DIR=$HOME/android/mainline/wt-bt KERNEL_OUT=$HOME/android/mainline/out-bt
O=$KERNEL_OUT D=$O/arch/arm64/boot/dts/exynos/google/gs201-cheetah.dtb
ov() {  # ov NAME: rebuild the DTB from default + overlay NAME, then images
  cp -n "$D" "$D.default"
  $O/scripts/dtc/dtc -q -I dts -O dtb -o out/$1.dtbo device/cheetah/overlays/$1.dtso
  $O/scripts/dtc/fdtoverlay -i "$D.default" -o "$D" out/$1.dtbo
  bin/omandroid images
}
# rollback for every overlay step: cp "$D.default" "$D"; bin/omandroid images && bin/omandroid push
```

### BT1.0 new kernel, default DTB (nothing Bluetooth is enabled)

```sh
bin/omandroid modules-push && bin/omandroid push          # slot B, reboots
tools/phone-ssh 'uname -r; ls /sys/bus/platform/devices | grep -E "18000000|10840000|181b00c0"; true'
```

Pass: boots as before (USB/SSH, UFS, touch, buttons, display); none of the
three devices is listed. The only new live node is the `sysreg_apm` syscon,
which nothing references while the USI is off.

### BT1.1 CMU_APM only (reads, never writes)

```sh
ov bt-cmu-test && bin/omandroid push
tools/phone-ssh 'grep -E "apm|pll_alv|pad_clk" /sys/kernel/debug/clk/clk_summary'
```

Pass: boots; `dout_apm_usi1_uart` at **197000000** under `gout_apm_func` <-
`mout_apm_func` <- `mout_apm_funcsrc` <- `pll_alv_div2_apm` (394 MHz). Write
down whatever differs (a different rate is not fatal: the UART uses the real
one, and 3 Mbaud needs at least 48 MHz).

The driver has now read CMU_APM (mux, divider and the gate debug registers),
which proves the block is readable from the AP. With that established, read
the three UART gate registers raw (read only; never write CMU_APM):

```sh
tools/phone-ssh 'for a in 0x180020ac 0x180020b0 0x18002100 0x18001814 0x1800306c; do echo "$a $(devmem $a)"; done'
```

Decode each gate (`0x20ac` IPCLK, `0x20b0` PCLK, `0x2100` reset-sync): bit 28
= automatic gating enabled, bit 20 = manual mode, bit 21 = manual value.

- bit 28 set, or bits 20 and 21 both set: the clock runs when used. Go on.
- **bit 20 set and bit 21 clear: the gate is forced off. STOP.** Any UART
  register access would hang the bus. Report the values; the fix is a staged
  write (as Google's cal-if does) behind its own gate.

`0x1814` bits [6:0] is the divider ratio (expect 1). `0x306c` is the UART's
Q-channel (information only).

### BT1.2 UART up, loopback (chip stays off)

```sh
ov bt-uart-test && bin/omandroid push
tools/phone-ssh 'dmesg | grep -E "181b0000|181b00c0|10840000"; ls -l /dev/ttySAC0'
tools/phone-ssh python3 - loop < tools/bt-uart-test
```

Pass: `181b0000.serial: ttySAC0 at MMIO 0x181b0000 (irq = N, base_baud = 0) is a S3C6400/10`,
no USI error, and `loopback PASS` at 115200 and 3000000 (the UART feeds TX
back into RX internally: proves the IP, its PCLK, IPCLK and IRQ; independent
of the baud clock's accuracy).
If the phone hangs at boot (no USB): hold Power ~30 s; ABL falls back to
slot A after the retries; then roll back the DTB. That would mean the UART
clocks are gated despite BT1.1, so stop there.

### BT1.3 power the BT core alone, HCI_Reset by hand

```sh
tools/phone-ssh python3 - hci < tools/bt-uart-test
```

The tool requests `gpp16` lines 2 and 3 as outputs (low), raises BT_DEV_WAKE
then BT_REG_ON, waits 200 ms, sends HCI_Reset at 115200 with RTS/CTS, then
Read Local Version and Broadcom Read Verbose Config, and drops BT_REG_ON.
Wi-Fi's WL_REG_ON is never touched.

Pass: `04 0e 04 01 03 0c 00` for the reset, then a version line (write down
the **LMP subversion** and **chip id**; they go into `btbcm`'s table later
and tell whether the BCM4387 quirk set applies). This proves the pins, the
power, the LPO, the baud clock and flow control together.

Fail, 0 bytes back: BT_REG_ON, the LPO, or CTS never asserted by the chip.
Rerun with `--on-ms 5000` and, meanwhile, check in a second terminal that
`gpp16` lines 2 and 3 read high (`grep -A5 gpp16 /sys/kernel/debug/gpio`).
Garbage bytes: the baud clock; compare with BT1.1's rate.

Rollback: nothing to undo (the tool drops BT_REG_ON on exit).

### BT2 hci_uart, firmware patch

```sh
# firmware (laptop -> phone; only the BT patch is needed)
tools/extract-vendor-firmware -o out/vendor-firmware \
  ~/android/factory/cheetah-cp2a.260705.006/image-cheetah-cp2a.260705.006.zip
tar -C out/vendor-firmware -cf - usr | tools/phone-ssh 'tar -C / -xf -'
tools/phone-ssh 'ls -l "/usr/lib/firmware/updates/brcm/BCM.google,gs201-cheetah.hcd"'
# keep hci_uart from loading at boot, so it loads with dmesg -w running
tools/phone-ssh 'echo "blacklist hci_uart" > /etc/modprobe.d/omandroid-bt-test.conf'
ov bt-hci-test && bin/omandroid push
tools/phone-ssh 'modprobe hci_uart; sleep 15; dmesg | grep -iE "bluetooth|hci0|btbcm|serial"'
```

Pass (dmesg, in order): `hci0: BCM: chip id N`, `hci0: BCM (x.y.z) build NNNN`,
`hci0: BCM 'brcm/BCM.google,gs201-cheetah.hcd' Patch`, then after the
download a second version line with a new build number and the local name
`BCM4389C1 ...`; no `Patch command ... failed`, `Failed to set baudrate` or
`Reset failed`. `btmgmt info` lists hci0.

If it stops at `BCM: Patch command fc4c failed (-110)`:

```sh
tools/phone-ssh 'modprobe -r hci_uart btbcm; modprobe btbcm patchram_nowait=1; modprobe hci_uart'
```

If `Failed to set baudrate` or the reset after the 3 Mbaud switch times out,
retry at 115200 only: add an overlay that sets
`max-speed = <115200>` on `.../serial@181b0000/bluetooth` (the download then
takes about 45 s).

Rollback: `modprobe -r hci_uart` (powers the chip down); the DTB rollback above.

### BT3 BlueZ, scan, pair, low power

```sh
tools/phone-ssh 'rm /etc/modprobe.d/omandroid-bt-test.conf'
tools/phone-ssh 'systemctl enable --now bluetooth; rfkill list; bluetoothctl show'
tools/phone-ssh 'timeout 20 bluetoothctl --timeout 15 scan on'
```

Pass: `bluetoothctl show` lists the controller, `Powered: yes`; the scan
lists nearby devices with RSSI. Then pair a headset or another phone with
`bluetoothctl` (pair, trust, connect) and play audio through PipeWire.

- **Address.** If `bluetoothctl show` reports a Broadcom default address (or
  none), set the board's real one from what ABL put in the DT, at runtime
  (never store it in the repo):
  `btmgmt power off; btmgmt public-addr "$(tr -d '\0' < /proc/device-tree/chosen/config/bt_addr)"; btmgmt power on`.
  First check that our DTB gets that property at all
  (`ls /proc/device-tree/chosen/config/`). A small unit in
  `omandroid-device-cheetah` does this at every boot once proven.
- **Low power.** `grep host-wake /proc/interrupts` (or the gpa6 line) counts
  host-wake edges; with the link idle for 10 s, `hci_bcm` runtime-suspends
  and drops BT_DEV_WAKE; an incoming connection must still wake it.
- **Quirks.** Watch dmesg for `Opcode 0x.... failed` during power-on (LE
  extended scan, MWS transport config, LE coded PHY). Those are the
  commands that need `HCI_QUIRK_BROKEN_*` flags on related Broadcom chips;
  add only what this chip actually rejects.

Rollback: `systemctl disable --now bluetooth`, `modprobe -r hci_uart`.

### After BT3: default-on

Enable `cmu_apm`, `pinctrl_peric0`, `usi_apm1`, `serial_apm1` and the
`bluetooth` child in `gs201-cheetah.dts`, record the subversion in `btbcm`,
and drop `patchram_nowait` if it was not needed.

## 5. What Omarchy's Bluetooth UI needs

- **Packages:** `bluez`, `bluez-utils` (and `bluez-tools`) are in
  `omarchy-base.packages`; Omarchy's `install/hardware/bluetooth.sh` enables
  `bluetooth.service`. Check both on the phone (`pacman -Q bluez`,
  `systemctl is-enabled bluetooth`): the per-user install never fully ran there.
- **Power state:** `omarchy-bluetooth-power` keeps on/off in the rfkill soft
  block (restored by `systemd-rfkill`), so `rfkill` (module, in our config)
  and `systemd-rfkill` must work; hci_uart registers the rfkill switch.
- **Quick settings tile:** `omandroid.quicksettings` already has a Bluetooth
  tile (`Quickshell.Bluetooth` adapter state, `omarchy-bluetooth-power`
  on/off), and `omandroid.bar` shows the icon when a device is connected.
  Both read "No adapter" today and should come alive as soon as BlueZ has
  hci0, with no code change. Check with
  `omarchy-shell shell call omandroid.quicksettings state ''`.
- **Device list / pairing:** Omarchy's `omarchy.bluetooth` panel (device
  list, connect, forget) is a desktop bar widget; the phone bar doesn't host
  it. Next UI step: a long-press on the tile opens a phone-sized device list
  built on the same `omarchy-bluetooth-device` helper.
- **Audio:** PipeWire/WirePlumber already handle A2DP/HFP once BlueZ is up.

## 6. Risks and open questions

| Risk | How it is answered |
|---|---|
| UART gates forced off by the firmware: any UART access hangs | BT1.1 raw gate read (after the driver proved CMU_APM readable) before BT1.2 enables the UART |
| CMU_APM writes by the OS disturbing the APM firmware | none happen: read-only muxes/divider, no clk_regs, no option, auto-mode gates (2.1) |
| sysreg_apm SW_CONF write | same value and same register Google's driver writes at every boot (`R/dmesg.txt:967`) |
| Divider not at 197 MHz | BT1.1 shows it; the UART computes from the real rate |
| LPO (32 kHz) not running | BT1.3 fails with no answer while BT_REG_ON is high; then look at the PMIC 32k buffer (needs the ACPM/S2MPG12 work) |
| Write RAM not acknowledged | `btbcm.patchram_nowait=1` (2.4) |
| Baud switch fails | retry with `max-speed = <115200>` (slow but works) |
| BD address is a default | `btmgmt public-addr` from `/chosen/config/bt_addr` (BT3) |
| Suspend | BT pins' power-down states are not programmed; irrelevant until the kernel suspends |
| Coexistence with Wi-Fi | separate REG_ON lines; both on at once is the stock case; test after W3 |

First step: **BT1.0** (new kernel, default DTB), then BT1.1.
