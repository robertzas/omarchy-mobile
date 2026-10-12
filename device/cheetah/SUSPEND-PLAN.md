<!-- SPDX-License-Identifier: MIT -->
# Suspend plan: s2idle first, then SYS_SLEEP (cheetah / gs201)

Status (2026-10-12): research done and kernel side written and built offline.
**S0 (read-only) ran on the phone** (section 8.0, results). S1 is next. Kernel branch `omandroid-suspend` in
`~/android/mainline/wt-suspend` (off `omandroid`, with `omandroid-acpm`
merged in, because the RTC sits on ACPM), built into
`~/android/mainline/out-suspend`. The runbook is section 8. The first stage
(S0) is read-only and runs on the kernel that is on the phone now.

**Goal.** Android-like standby. Screen off means sleep. The power key, USB,
Bluetooth, Wi-Fi and (later) the modem wake the phone, and the drain is very
low. That takes two kinds of sleep:

1. **s2idle** ("freeze"): userspace frozen, devices suspended, CPUs in their
   deepest cpuidle state (C2), and the SoC and every PMIC rail left on. This
   is the generic Linux mechanism. It needs no secure-world sequence, only
   drivers that suspend and resume cleanly and interrupts that can wake.
   It saves little power, but it proves the drivers, the wake sources and
   the userspace policy. Everything later builds on it.
2. **SYS_SLEEP** (what stock Android does): the PMU and the APM firmware
   power the SoC down, put DRAM in self-refresh and drop PWREN, so about 30
   PMIC rails switch off. Entered through PSCI SYSTEM_SUSPEND after a
   table-driven PMU sequence. This is where the tens-of-mA standby comes
   from.

Path abbreviations (as in the other plans):

- `L/` = `~/android/mainline/wt-suspend` (our kernel, this branch)
- `G/` = `~/android/omandroid/out-kernel/google/gs-6.1/private` (Google's GPL gs201 kernel)
- `GS/` = `G/google-modules/soc/gs`
- `GD/` = `G/devices/google/gs201/dts`
- `R/` = `~/android/reference/cheetah-stock-cp2a-root` (stock live DT, dmesg, interrupts)
- `P/` = this repository

---

## 1. Firmware: what PSCI offers, and the trap in "mem"

- **PSCI 1.1, platform-coordinated.** Our boots print "PSCIv1.1 detected in
  firmware" and "MIGRATE_INFO_TYPE not supported" (`P/logs/acpm-kernel.log`,
  `R/dmesg.txt:94-98`). Stock's DT is `psci { compatible = "arm,psci-1.0";
  method = "smc"; }` (`R/live.dts:2593-2596`).
- **CPU_SUSPEND (C2) works with the PMU hint.** `arm,psci-suspend-param =
  <0x10000>` (power-down, level 0) on all cores. The firmware accepts it
  only if CPU_INFORM(cpu) = 1 was written first (POWER-PLAN 1.3-1.4). C2
  passed on the phone with overlays (POWER-PLAN section 7). It is not in
  the default DTB yet (`omandroid-power-on` not merged).
- **SYSTEM_SUSPEND is implemented.** Stock enters every system sleep through
  the generic PSCI SYSTEM_SUSPEND (`cpu_suspend(0, psci_system_suspend)`,
  SMC `0xC400000E`, entry = `__pa(cpu_resume)`, context 0), with no vendor
  PSCI code. Google's boot metrics also time EL3's
  `psci_system_suspend` (`GS/drivers/soc/google/debug/pixel-boot-metrics.c:141-148`).
  External bring-up reports agree that the firmware advertises it.
- **The trap.** With SYSTEM_SUSPEND advertised, mainline's
  `psci_init_system_suspend()` (`L/drivers/firmware/psci/psci.c:582-593`)
  registers `psci_suspend_ops`. `suspend_set_ops()` then makes `deep` the
  default (`L/kernel/power/suspend.c:228-238`), so `/sys/power/mem_sleep`
  reads `s2idle [deep]`. `systemctl suspend` and `echo mem > /sys/power/state`
  would then call SYSTEM_SUSPEND **without** stock's PMU preparation: no
  CPU_INFORM = 4, no wake masks, no CMU save, no pad-retention release on
  exit. The likely outcome is no wake, or a reset.
  - **Fix (kernel):** `mem_sleep_default=s2idle` in the DTB bootargs (commit in
    section 7). After that, "mem" means s2idle until SYS_SLEEP exists.
  - **Fix (userspace, belt and braces):** `MemorySleepMode=s2idle` in a
    `systemd/sleep.conf.d` drop-in of `omandroid-device-cheetah`.
  - **Until either is in:** use only `echo freeze > /sys/power/state`
    (`rtcwake -m freeze`). Never `mem`.

## 2. s2idle on gs201: what happens

Without cpuidle states (int before `741b6ed1d`), in s2idle the CPUs sit in WFI
(`L/kernel/sched/idle.c:196-199`, `default_idle_call()`), and the last CPU
freezes the tick and timekeeping. The arch counter is
`CLOCK_SOURCE_SUSPEND_NONSTOP`, so time stays right.

With the C2 overlays (or `omandroid-power-on`), each plain DT idle state also
gets `enter_s2idle` (`L/drivers/cpuidle/dt_idle_states.c:38`). s2idle then
uses C2 directly. **Upstream bug for this path, fixed on this branch:**
`exynos-pmu`'s `suspend_noirq` sets `sys_insuspend`, and from then on its CPU
PM notifier stops writing the CPU_INFORM hint
(`L/drivers/soc/samsung/exynos-pmu.c:326-349, 557-583`). That is right for a
firmware system suspend, where the hint must stay SLEEP (stock's cpupm does
the same with `system_suspended`, `GS/drivers/soc/google/exynos-cpupm.c:991-993`).
It is wrong for s2idle: the firmware then refuses every C2 entry (POWER-PLAN
1.3), each refusal returns at once, and the CPUs spin on PSCI calls until
wakeup. Commit `8d820bc0a` keeps the hint when the target is s2idle. The
proof is `state1/rejected` staying a small fraction of `state1/usage` across
a freeze (stage S4).

**What s2idle can't save.** PWREN stays high and the SoC never leaves its
active power state, so the rails, DRAM refresh and the always-on blocks keep
their awake cost. External numbers on this phone with mainline: about
274-286 mA from the battery in s2idle, display off, Wi-Fi unloaded, against
about 50 mA (later 32-45 mA) in SYS_SLEEP. Expect s2idle to beat
"screen off, awake" only by what the CPUs, devices and timers stop drawing.
Measure it (section 8, S6) and don't sell it as Android standby.

## 3. Wake sources

| Source | Line | Our state | Wakes s2idle? |
|---|---|---|---|
| Power key | gpa10-0 (`PMIC_PWRON_OD_L`), ALIVE EINT, GIC SPI 42 | `gpio-keys`, `wakeup-source` (`gs201-cheetah.dts`) | Yes. `gs101_wkup_irq_set_wake` only records the mask bit; the SPI stays live |
| Volume down / up | gpa10-1 (SPI 43) / gpa8-5 (FAR_ALIVE) | same node | Yes. **Use Volume Up to wake in tests**: Hyprland binds the power key to lock and screen off (`omandroid-keys`) |
| RTC alarm | S2MPG12 RTC over ACPM channel 2, PMIC interrupt in-band (I3C IBI), raised by SYSREG_VGPIO2AP as GIC SPI 72, level high (`R/live.dts:13103-13107`; `R/interrupts.txt`: "GICv3 104 Level s2mpg12-irq") | **New on this branch**, node disabled (section 7) | Yes once enabled. `rtcwake` needs it |
| Fuel gauge | gpa9-3, level low, shared | `max17042_battery` calls `enable_irq_wake` unconditionally in suspend | Yes. **Can cause unexpected wakes or an immediate abort** if the alert line is held low |
| Bluetooth host wake | gpa6-6 (FAR_ALIVE), rising edge | `hci_bcm` arms it in suspend | Yes: BT traffic wakes the phone |
| Wi-Fi host wake | gpa6-1 (FAR_ALIVE) | **no consumer**: not requested by `pcie-gs201` or brcmfmac | No |
| USB / Type-C | TCPCI MAX77759 on gpa9-7 (stock enables wake unconditionally, `tcpci_max77759.c:2420-2433`) | TCPC blacklisted, node disabled (USB-C-PLAN) | No. USB plug-in can't wake yet |
| Touch | gpa7-0, level low | `synaptics_tcm`, not wake-armed | No (stock doesn't wake on touch either, except AOD gestures) |
| Modem | CP2AP_WAKEUP gpa8-3 | no modem driver | Later |

Stock's PMU wake set for SYS_SLEEP, for later: `WAKEUP_INT_EN` (PMU `0x3944`)
= `0x1001f0bf` and `WAKEUP2_INT_EN` (`0x3964`) = `0x1f0`. That covers the RTC,
EINT and EINT_FAR, the AoC mailbox, PCIe, USB_REWA, and the APM/AoC/debug
mailboxes (`GD/gs201.dtsi:382-430`, `R/live.dts:12844-12872`). In s2idle these
PMU registers don't matter: the GIC is awake.

## 4. Drivers across s2idle (our integration kernel)

From an audit of `omandroid-int` (head `907128673`), with Google's handling for
comparison.

| Driver | What happens in s2idle | Risk / action |
|---|---|---|
| **UFS** (`ufs-exynos.c`, gs201 data) | Core default `spm_lvl` = 3: device SLEEP, link Hibern8. The gs101/gs201 vendor `suspend` (`gs101_ufs_suspend`, `L/drivers/ufs/host/ufs-exynos.c:1806-1810`) writes `HCI_GPIO_OUT = 0`, which **asserts the device reset**. Then `phy_power_off` if the link isn't active. Resume does `phy_power_on`, SMU and FMP; nothing deasserts reset, so the Hibern8 exit fails and the core's link recovery resets the host and device (`exynos_ufs_dev_hw_reset`). Stock uses `spm_lvl` 5 (device powered down, link off) for system suspend (`GS/drivers/ufs/ufs-exynos.c:702-705`), so its resume is always a full re-init, which matches the reset. | **Medium, root FS.** Stage S1 reads `spm_lvl`/`rpm_lvl` and whether the device WLUN already runtime-suspends (if it does, this reset path already runs every day). Before the first real freeze, `echo 5 > spm_lvl` (runtime, a reboot undoes it), as stock. Promote to a gs201 default only after S3 passes. `sync` before every test |
| **Display** (simpledrm on ABL's framebuffer; `gs_dsim_cmd` + `panel-samsung-s6e3hc4` for commands and `bl_power`) | simpledrm's suspend only disables its software CRTC. DECON0 → DSIM0 → panel keep running on ABL's setup plus our `TRIG_CON` write from init (`P/device/cheetah/initramfs/init:90`), all powered (`pd_ignore_unused`). The panel driver has no PM ops. | Low for s2idle: the picture stays (a frozen picture is the visible sign of a freeze). Userspace blanks with `bl_power = 4` before sleeping and unblanks on a user wake. For SYS_SLEEP the DPU domain powers off: TRIG_CON is lost, the panel needs its full init (DISPLAY-PLAN D3b/D4c), and with stock's PWREN rails off a powered display domain stopped the wake in external tests |
| **GPU** (Panthor, `clk_acpm`) | System sleep uses `pm_runtime_force_suspend` even though our udev rule pins runtime PM on (`P/packages/omandroid-device-cheetah/vendor/udev/rules.d/20-omandroid-gpu-always-on.rules`). `panthor_device_suspend` stops the scheduler, firmware and MMU, then devfreq, then `clk_disable`. `clk_acpm` has no gate ops, and there is no G3D PD driver, so the GPU stays powered. Resume reboots the MCU firmware. | Medium: the first run of this path. S2 watches for "FW slow reset" or job timeouts after resume |
| **Wi-Fi** (`pcie_gs201` + brcmfmac) | brcmfmac `.suspend` sends D3_INFORM and waits 2 s for D3_ACK; on timeout it returns **-EIO and aborts the suspend** (`pcie.c:3310-3335`). **It can't work today:** our BCM4389 firmware reports shared flags `0x70050107` (version 7, no `PCIE_SHARED_USE_MAILBOX` `0x2000000`, `bcmpcie.h:103` in Google's driver), so, as in Broadcom's driver, mailbox data (D3 inform/ack, deep sleep) travels as control-ring messages (types `0x23`/`0x24`); brcmfmac writes the TCM mailbox, which this firmware ignores, and logs the replies as "Unsupported msgtype 36". Fixed on branch `omandroid-wifi-d3` (section 7). `pcie-gs201` has **no PM ops**: no PME_Turn_Off, no L2, no PERST, no PHY isolation; the link stays up and the PCI core puts the endpoint in D3hot. Host wake gpa6-1 has no consumer. | **Unload Wi-Fi for stages S1-S4** (`systemctl stop omandroid-wifi`, then `modprobe -r brcmfmac pcie_gs201`). Wi-Fi across s2idle is stage S5 (section 6.3). External reports with mainline brcmfmac on this chip: the D3 ack arrives as a control-ring message and was missed until D3 completion was published only after the IRQ thread finished RX; even then about 2 in 20 s2idle resumes hung the firmware ("Failed to reserve space in commonring", then -EIO on every later suspend) |
| **Bluetooth** (`hci_bcm`, `samsung_tty`) | `bcm_suspend` drops BT_DEV_WAKE (gpp16-3) and arms host wake. The UART has suspend, resume and resume_noirq. | Low. For SYS_SLEEP BT_REG_ON (gpp16-2) needs stock's "previous" PDN state, or the chip loses power (BLUETOOTH-PLAN 367) |
| **Haptics** (`cs40l26-vibra`, ours) | No PM ops. The DSP is kept out of hibernate; `play_work` on the system workqueue could hit the suspended I2C adapter (-ESHUTDOWN) if a buzz is in flight. | Low/medium. Add a suspend that stops playback and lets the DSP hibernate (Google's `cs40l26.c` PM ops) |
| **Touch** (`synaptics_tcm`, ours) | No PM ops, no sleep command. The controller keeps scanning; its IRQ is masked as suspended and the pending ATTN replays on resume. | Power drain; add suspend = TouchComm sleep (or hold reset as stock does at screen off), resume = wake + re-read |
| **Torch** (`leds-lm3644`) | `LED_CORE_SUSPENDRESUME`: off in suspend, restored on resume. | OK |
| **Fuel gauge** (`max17042_battery`) | Disables its IRQ and arms it for wake. | See section 3. Charger/TCPC are blacklisted |
| **ACPM, `clk_acpm`, mailbox** | No PM ops; transfers are polled, the mailbox uses no IRQ. Stock also sends **no** ACPM message around suspend; it only reads the FlexPMU counters (`GS/drivers/soc/google/exynos-pm.c:221-229`). | Low. The S2MPG12 core reads the PMIC over ACPM in its resume path, which works because ACPM is polled |
| **Watchdogs** (`s3c2410_wdt`) | Inactive (`tmr_atboot=0`). Suspend saves and stops, resume restores. systemd doesn't hold `/dev/watchdog0` at runtime (only `RebootWatchdogSec`). | OK. The test feeder (POWER-PLAN 5.4) is frozen with userspace, and the driver stops the timer first, so it can't fire during sleep |
| **USB** (dwc3 peripheral, `phy-exynos5-usbdrd`) | `dwc3_gadget_suspend` (soft disconnect), then core exit; resume re-inits core and PHY, forced VBUS valid. | **The SSH link drops** for the whole sleep and must re-enumerate. Tests run detached and log to UFS. If USB doesn't come back, the log and the screen still tell the story |
| **I2C, SPI, USI** | `i2c-exynos5` and `exynos-usi` have noirq PM; `spi-s3c64xx` may return -EBUSY if busy. | Low |
| **MCT / arch timer** | MCT has `resume` and `tick_resume`; MISC stays powered in s2idle. | OK. In SYS_SLEEP MISC powers off and the MCT counter must be restarted on resume |
| **PMIC / RTC** (new) | `sec_pmic_suspend` arms its IRQ for wake and disables it; resume reverses. | New, stage S3 |

## 5. SYS_SLEEP (deep), for later: what stock does

Order, from Google's GPL sources:

1. `suspend_noirq`: PCIe PHY isolation for a link that is down; cpupm stops
   hinting (`system_suspended`).
2. **syscore, `exynos-pm`** (`GS/drivers/soc/google/exynos-pm.c:150-232`):
   - EINT wake masks to PMU `0x3a80/0x3a84/0x3a88` (1 = masked), from the
     pinctrl wake bitmap;
   - `WAKEUP_STAT`/`WAKEUP2_STAT` (`0x3950`/`0x3970`) = 0, then the two
     `WAKEUP_INT_EN` values above;
   - `cal_pm_enter(SYS_SLEEP)` (mode index 8; the PCIe-on HSI1ON mode 13 is
     never chosen, because the hook that registers it is commented out at
     `GS/.../pcie-exynos-rc.c:5785`): CPU_INFORM(cpu0) = **4**, save 545
     CMU registers (all MMIO), then 3 enter writes (PMU_INTR_GEN GRP2
     enable bit 0 and GRP1 pending clear, MMIO; `CLUSTER0_CPU0_INT_EN`
     `0x18061044` bit 3, SMC). Tables: `GS/drivers/soc/google/cal-if/gs201/flexpmu_cal_system_gs201.h:140-745`.
   - Every PMU_ALIVE (`0x1806xxxx`) write goes through SMC `0x82000504`;
     atomic set/clear use `offset | 0xc000` / `| 0x8000`
     (`GS/drivers/soc/google/cal-if/pmucal_rae.c:149-188`).
3. Pinctrl syscore saves CON/DAT/PUD/DRV/PDN of every bank and forces the
   sleep state.
4. PSCI SYSTEM_SUSPEND. EL3 and the APM firmware do the rest (SoC down, DRAM
   self-refresh, MIF down, PWREN low).
5. On wake, the FlexPMU AP-down counter tells a real sleep from an early
   wake: 37 exit writes (wake enables off, intr-gen pending clears, MIF
   `PwrMgmtMode` bit 31 = 0 at `0x20[8-b]40000 + 0xf23c`, bus DRCG
   re-enables, UFS MISC `0x147011b4` bit 8, **PMU `TOP_OUT` `0x3920` set
   bits 7, 9, 11-14** = pad-retention release) or 9 early-wake writes, then
   the 545 restores. Stock prints the wake reason from `WAKEUP_STAT`.

What Linux needs before that can work, in dependency order (external
bring-up experience on this phone, every item matching Google's sources):

- **PMU sleep driver**: the sequence above as a syscore driver in
  `drivers/soc/samsung/`, tables generated from Google's GPL `flexpmu_cal_*`
  headers, plus the CPU_INFORM handover with `exynos-pmu` (its
  `sys_insuspend` path is exactly the hook for this).
- **EINT wake-mask numbering is wrong in mainline for gs201.** Mainline numbers
  wake bits with a running count (`L/drivers/pinctrl/samsung/pinctrl-exynos.c:811`),
  so gpa3 gets 19, but the PMU (and Google's table) uses 20 for gpa3
  (`GS/drivers/pinctrl/gs/pinctrl-gs201.c:74-89`, EINT19 does not exist).
  Every bank from gpa3 on, FAR_ALIVE included, is one bit low. The power key
  (gpa10-0) must be bit 43, BT host wake 51, WL host wake 46. Needs a per-bank
  EINT offset in the gs201 bank data. Harmless for s2idle.
- **GPIO power-down states.** ABL leaves CON_PDN/PUD_PDN of many pins at input
  pull-down; in SYS_SLEEP that drops BT_REG_ON, the modem reset lines and
  UFS RST_N/REFCLK. Stock's DT sets only 49 PDN values and relies on the
  rest; we must set the ones we use (`samsung,pin-con-pdn`).
- **USI and CMU restore** (I2C/SPI lose their mode), **MCT restart**,
  **S2MPU CTRL0 restore** for HSI1/HSI2 (and G3D, MFC, CSIS when used),
  **UFS**: link off, PHY isolation (PMU `0x3ec8`), IOCC (SYSREG_HSI2 `0x710`),
  and on resume the FMP/SMU SMCs. Stock resumes with
  `SMC_CMD_FMP_SECURITY` `0xC2001810` then `SMC_CMD_FMP_SMU_RESUME`
  `0xC2001860` (`GS/drivers/ufs/ufs-exynos-crypto.c:139-157`); `0xC2001850`
  (SMU_INIT) is the probe-time call.
- **PMIC opmodes**: stock gives 31 rails `regulator-initial-mode = 1`
  (follow PWREN); ABL leaves them always-on. Needs S2MPG12/13 regulator
  support over ACPM (this branch adds only the S2MPG12 core and RTC).
- **Display off** before sleep (DPU and DISP domains down).
- **Never clear `MIF_ALWAYS_ON`** (externally reported to reset the phone;
  stock never writes it).
- External results to calibrate against: SYS_SLEEP entered and exited
  repeatedly, about 50 mA unplugged at first, 32-45 mA after pin PDN fixes,
  touch in reset and UFS idle Hibern8; a held sensor stream kept MIF waking
  about 28 times a second (+17 mA).

## 6. Userspace: screen off, sleep, wake

### 6.1 Policy (Android-like)

- **Power key, short press** (today: lock + screen off, `omandroid-keys`):
  after the screen is off and the lock is up, suspend. Long press keeps
  the system menu; power + volume down stays the screenshot.
- **Idle**: Omarchy's idle chain (screensaver, lock, display off). Add a final
  step: display off for N seconds (start with 10-30 s) → suspend, using
  whatever Omarchy schedules those steps with. Check its shipped config
  first; the phone has `bl_power` display off (patches/omarchy/0008).
- **Wake**: power key → screen on to the PIN pad (today's `wake_locked`).
  Other wakes (RTC, BT, Wi-Fi, gauge) should **not** light the screen. They
  run briefly and sleep again ("dark resume").
- **Inhibit**: logind inhibitor locks (`systemd-inhibit --what=sleep`) for
  calls, audio playback, `omarchy update`/pacman, downloads the user asked to
  keep running. Logind honours them for `systemctl suspend`.

### 6.2 Pieces

- **logind**: `HandlePowerKey=ignore` stays (Hyprland owns the key).
  `systemctl suspend` goes through logind, so inhibitors and the sleep hooks
  apply. Never write `/sys/power/state` from the session.
- **`omandroid-device-cheetah`**:
  - `systemd/sleep.conf.d/10-omandroid.conf`: `[Sleep] MemorySleepMode=s2idle`
    (until SYS_SLEEP), `AllowHibernation=no`, `AllowHybridSleep=no`,
    `AllowSuspendThenHibernate=no` (there is no swap to hibernate to).
  - `/usr/lib/systemd/system-sleep/omandroid`: `pre` stops Wi-Fi until S5
    passes, blanks the panel; `post` reads the wake reason
    (`/sys/power/pm_wakeup_irq`, wakeup source deltas) into the journal and
    for the shell. The dark-resume decision comes later.
  - Optionally `WakeupSource` hygiene: a udev rule that disables
    `power/wakeup` for sources we don't want (gauge alerts, if they turn out
    noisy).
- **Omarchy's `suspend-off` toggle**: Omarchy hides Suspend in its system menu
  while the toggle is set; we set it in the first-run setup until the kernel
  can suspend (NOTES, "power button menu"). **Clear it only after stage S4
  passes** on the image that ships, in the same package release that adds
  the sleep drop-in and hook.
- **`omandroid-keys`**: after `short_press` turns the screen off and the lock
  is up, call `systemctl suspend` unless an inhibitor is held (check with
  `systemd-inhibit --list`). Gate it behind a toggle file (for example
  `omarchy-toggle-enabled omandroid-sleep-on-power`) for the first release.
- **Sensors and timers**: anything that keeps waking the CPU (shell timers,
  polling widgets, a sensor stream) defeats sleep. Measure with
  `/sys/kernel/debug/wakeup_sources` and powertop before blaming the kernel.

### 6.3 Wi-Fi and Bluetooth across sleep

- Stage S5 adds Wi-Fi: brcmfmac's D3 handshake, then (kernel work) `pcie-gs201`
  PM ops: `suspend_noirq` = PME_Turn_Off, wait for L2, PERST#, PHY
  isolation (PMU `0x3ec4`), as Google's `exynos_pcie_rc_poweroff`
  (`GS/.../pcie-exynos-rc.c:3979-4116`); `resume_noirq` = the probe-time
  bring-up. A link torn down in L1.2 is known to make the next link training
  hang: exit L1 first. Wake-on-WLAN = request WL_HOST_WAKE (gpa6-1,
  FAR_ALIVE, active high) as a wake IRQ in brcmfmac's OOB path.
- Until then the sleep hook unloads Wi-Fi and the resume path reloads it
  (`omandroid-wifi.service`'s hang-safe start), so the phone reconnects
  after each user wake.
- Bluetooth stays up: its host-wake works today.

## 7. Kernel work on this branch

Branch `omandroid-suspend` (`~/android/mainline/wt-suspend`), off `omandroid`
(`7b0f8b5d1`):

| Commit | What | Default |
|---|---|---|
| `8d820bc0a` soc: samsung: exynos-pmu: keep the CPU idle hint in suspend-to-idle | `exynos_cpupm_suspend_noirq()` returns early when `pm_suspend_target_state == PM_SUSPEND_TO_IDLE`, so C2 keeps its CPU_INFORM hint in s2idle | Only acts in s2idle, which nothing enters today |
| `17239293a` merge `omandroid-acpm` | ACPM link, needed by the PMIC | as in `omandroid-int` |
| `279130ea5` dt-bindings: soc: samsung: exynos-sysreg: add gs201 VGPIO2AP | `google,gs201-vgpio2ap-sysreg` | n/a |
| `a0cdfa111` dt-bindings: mfd: add Samsung S2MPG12 PMIC (and allow it under the gs201 ACPM node) | `samsung,s2mpg12-pmic` with `google,vgpio2ap-sysreg` | n/a |
| `6c0840744` mfd: sec: add S2MPG12 | ACPM regmaps (common, PM, RTC, meter) with **writes limited to the interrupt masks and the RTC**, no caching; a one-level regmap-irq on PM INT1-5 (bulk read, clear on read), whose pre-handler writes back VGPIO2AP `INTC0_IPEND` (`0x182f0290`); meter interrupts masked; IBIM1 = `0xfe` (PMIC source only), as Google's `s2mpg12_irq_init()`. Only cell: the RTC; **no regulators** | module (`CONFIG_MFD_SEC_ACPM=m`) |
| `9270c1a8c` rtc: s5m: add S2MPG12 | same RTC registers as S2MPG10 (checked against `GS/include/linux/mfd/samsung/rtc-s2mpg12.h`); alarm pending from PM STATUS2 bit 2 | built in with `RTC_DRV_S5M` |
| `9f0ff0acc` arm64: dts: exynos: google: gs201: add the VGPIO2AP sysreg | `syscon@182f0000` | node only, unused until the PMIC is enabled |
| `93555da2a` arm64: dts: exynos: google: gs201-cheetah: describe the main PMIC | `&acpm_ipc { pmic-1 }`, GIC SPI 72 level high, `wakeup-source` | **`status = "disabled"`**; overlay `suspend-pmic-test.dtso` enables it |
| `025624c64` arm64: dts: exynos: google: gs201-cheetah: default to suspend-to-idle | `mem_sleep_default=s2idle` in bootargs | on: removes the unsafe default (section 1) |

Notes on the PMIC work:

- **Why the RTC first:** `rtcwake` is the only unattended wake for tests, and
  later the alarm clock and background checks. With `RTC_HCTOSYS=y` it also
  sets the clock at boot.
- The RTC init writes `RTC_CTRL` = binary, 24 h (`MODEL24`), the value Google's
  driver writes. Upstream S2MPG10 code registers a WTSR restart handler only
  with `system-power-controller`, which our node doesn't have.
- `sec_pmic_suspend` arms SPI 72 for wake and disables it across sleep; the
  RTC driver arms its nested alarm IRQ. Stock does the same
  (`GS/drivers/mfd/s2mpg12-core.c:534-571`).
- External reports: reading INT2 alone left the interrupt asserted (storm),
  and the VGPIO pending bit must be cleared. regmap-irq reads INT1-5 in one
  bulk read, and the pre-handler clears the latch.

**Wi-Fi D3 (branch `omandroid-wifi-d3`, `~/android/mainline/wt-wifi-d3`, off
`omandroid-w4` `242602382`):** `73a5c5ccf` wifi: brcmfmac: pcie: exchange
mailbox data as control messages. For shared version >= 6 without
`USE_MAILBOX`, H2D mailbox data goes out as `MSGBUF_TYPE_H2D_MAILBOX_DATA` on
the control submit ring and D2H `MSGBUF_TYPE_D2H_MAILBOX_DATA` is handled; no
D0 inform on resume (the host-ready doorbell resumes the device). The D3 ack
is published only after RX processing (ISR thread and poll worker), so the
suspend path can't set STATE_DOWN before the control ring's read pointer is
written back (`brcmf_pcie_ring_mb_write_rptr()` refuses writes once DOWN).
External tests with that ordering: 8 of 8 RTC sleep/resume cycles with
Wi-Fi working after each. **Not compile-tested** (the tool environment
refused the build): build it before merging.

Not done here, for later branches: per-bank EINT offsets for gs201 (deep
only); `pcie-gs201` PM ops; Synaptics and CS40L26 suspend; S2MPG12/13
regulators; the SYS_SLEEP driver.

Config: `kernel/configs/omandroid.config` should gain `CONFIG_PM_DEBUG=y`,
`CONFIG_PM_ADVANCED_DEBUG=y` and `CONFIG_PM_SLEEP_DEBUG=y` (`/sys/power/pm_test`,
`pm_print_times`, `pm_debug_messages`). The out-suspend build adds them from
`out-suspend/suspend-debug.config` (section "Build result"), because the
shared fragment had uncommitted changes from other work.

## 8. Staged runbook (on the phone, run by the main session)

Rules: one change at a time; slot B only; keep the previous images to flash
back; `sync` before every sleep; log to UFS, not the USB link. Each real
sleep drops the USB gadget, so commands run detached with `systemd-run` and
are read back after reconnecting.

Recovery for every stage:

- **Phone doesn't wake** (black or frozen screen, no reaction to Volume Up or
  Power for 60 s): hold Power about 30 s (PMIC long-press reset). The next
  boot is our slot B; after repeated failures ABL falls back to stock slot A
  (NOTES, "Slot B fallback works"), then `adb reboot bootloader` and flash
  the previous images.
- **Phone wakes but USB doesn't come back**: the screen should show the
  session again. Reboot from the power menu (long press). Then read the log.
- **Phone wakes with UFS errors** (`ufshcd` error handler, I/O errors,
  read-only remount): reboot at once, run `fsck` on the next boot if the
  journal says so, stop and report. Don't sleep again on that kernel.
- **Suspend refuses** (`echo` returns an error, phone never sleeps): not
  dangerous. Read `dmesg` for the device that failed and stop.

Stop conditions: any UFS error; any RCU stall, soft lockup or "SMC failed";
a wake that needs the 30 s reset; an IRQ storm on the PMIC interrupt (S3);
`state1/rejected` close to `state1/usage` across a freeze (S4).

### S0 results (2026-10-12, `omandroid-int` 00186-ga0b0c0ebb3f6)

- `state` "freeze mem disk"; `mem_sleep` "s2idle [deep]": the firmware's
  SYSTEM_SUSPEND is advertised, as predicted (section 1). No `pm_test`, no
  RTC.
- No cpuidle at all, broadcast `bc_hrtimer`: C2 and the MCT were only on
  `omandroid-power-on`, since merged into int (`741b6ed1d`). From now on
  every s2idle test runs with C2, so the exynos-pmu fix (`8d820bc0a`) must
  be in before S2.
- UFS `spm_lvl` 3, `rpm_lvl` 3, `runtime_status` active.
- Wake-enabled: BT serdev, `max170xx_battery`, the Wi-Fi function
  `0000:01:00.0`, gpio-keys. `wakeup_count` 1.
- Loaded: brcmfmac (+wcc), pcie_gs201, hci_uart, btbcm, panthor,
  cs40l26_vibra, max17042_battery.

### S0: read-only state (current kernel, no flash)

```sh
tools/phone-ssh 'uname -r; cat /proc/cmdline
cat /sys/power/state /sys/power/mem_sleep          # expect "freeze mem" and "s2idle [deep]"
ls /sys/power/pm_test 2>&1                         # expect: No such file (no PM_DEBUG yet)
ls /sys/class/rtc/                                 # expect: empty (no RTC yet)
ls /sys/devices/system/cpu/cpu0/cpuidle 2>&1 | head -3
cat /sys/devices/system/clockevents/broadcast/current_device
U=$(ls -d /sys/bus/platform/devices/*.ufs); echo $U
cat $U/spm_lvl $U/rpm_lvl $U/power/runtime_status
for d in /sys/bus/scsi/devices/*:49488; do echo "$d $(cat $d/power/runtime_status) $(cat $d/power/control)"; done
grep -E "gpio-keys|max17042|host-wake|bcm|ufs|dwc3" /proc/interrupts
grep -l enabled $(find /sys/devices -path "*power/wakeup" 2>/dev/null) 2>/dev/null
cat /sys/power/wakeup_count
cat /sys/kernel/debug/wakeup_sources 2>/dev/null | awk "NR==1 || \$2>0" | head -30
systemd-analyze cat-config systemd/sleep.conf | grep -v "^#" | grep .
lsmod | grep -E "brcmfmac|pcie_gs201|panthor|cs40l26|hci_uart|btbcm|max17042"
cat /sys/class/power_supply/max170xx_battery/{status,current_now}'
```

As the logged-in user on the phone: `omarchy-toggle-enabled suspend-off && echo
"suspend hidden"`.

Record in NOTES. What decides the next stages:

- `mem_sleep` showing `deep` confirms section 1 (and that "mem" is unsafe on
  this kernel).
- If the device WLUN (`:49488`) is `suspended` or `control` is `auto`, UFS
  runtime suspend already runs the reset path daily (good evidence for S2).
- The list of enabled wakeup devices; any gauge interrupt counting fast.

### S1: new kernel, dry runs with pm_test (flash)

Merge order into `omandroid-int` (each merges cleanly on `741b6ed1d`, checked
with `git merge-tree`):

1. `omandroid-suspend` (`025624c64`): s2idle default, exynos-pmu hint fix,
   S2MPG12 + RTC (node disabled).
2. `omandroid-chgguard` (`37a83337c`, on `omandroid-usbc`, already in int):
   the charger temperature guard, off by default (USB-C-PLAN B3g).
3. Not yet: `omandroid-wifi-d3` (`73a5c5ccf`). Build it first; merge for S5.

`kernel/configs/omandroid.config` has the PM debug options since `38358ac`.
Build and flash slot B as usual. This
kernel changes nothing at runtime except `mem_sleep` (now `[s2idle] deep`)
and the new `/sys/power/pm_test`. The PMIC node is still disabled.

```sh
tools/phone-ssh 'cat /sys/power/mem_sleep /sys/power/pm_test   # expect "[s2idle] deep", "[none] core processors platform devices freezer"
systemctl stop omandroid-wifi; modprobe -r brcmfmac pcie_gs201; lsmod | grep -c brcmfmac'
```

Then three dry runs, each 5 s and automatic (no wake source needed), freezer
first. They keep USB down for a few seconds, so run detached:

```sh
tools/phone-ssh 'mkdir -p /var/lib/omandroid/suspend; systemd-run --unit=s1-test sh -c "
  L=/var/lib/omandroid/suspend/s1-\$(date +%H%M%S).log
  echo 1 > /sys/power/pm_print_times; echo 1 > /sys/power/pm_debug_messages
  for t in freezer devices platform; do
    sync; echo \$t > /sys/power/pm_test
    echo == \$t >> \$L; date >> \$L
    echo freeze > /sys/power/state; echo rc=\$? >> \$L
    sleep 10
  done
  echo none > /sys/power/pm_test; dmesg | tail -300 >> \$L; sync"'
# wait about a minute, reconnect
tools/phone-ssh 'tail -5 /var/lib/omandroid/suspend/s1-*.log; dmesg | grep -iE "PM:|suspend|resume|ufshcd|error|fail" | tail -60'
```

**Pass:** three `rc=0`; "PM: suspend debug: Waiting for 5 second(s)" at each
level; no device "failed to suspend"; no `ufshcd` errors; Hyprland and
the touch screen work afterwards; the GPU renders (Panthor resumed). Note the
slowest devices from `pm_print_times`. **Fail:** read which device returned
an error, stop and report.

**S1 result (2026-10-12, 7.3.0-rc6-omandroid-push1-00283-gafa4d777403d,
int with `omandroid-suspend`, `omandroid-chgguard` and `omandroid-modem`
merged): passed, with one UFS finding.** `mem_sleep` `[s2idle] deep`,
`pm_test` present. Wi-Fi unloaded. `freezer`, `devices` and `platform`
each returned `rc=0`; the phone came back on USB about a minute later and
the session was still running. The log keeps only the last level
(`platform`):
- UFS failed its first hibern8 exit on resume (`ufshcd_uic_hibern8_exit:
  hibern8 exit failed. ret = 5`, `__ufshcd_wl_resume`), then a host reset
  restored the link (`Power mode changed to : FAST series_B G_4 L_2`), and
  the device WLUN resumed with 0 after 250 ms. No I/O or filesystem
  errors. This is what S2's `spm_lvl` question is about.
- Slowest resumes: the UFS device WLUN 250 ms (the reset), dwc3 113 ms.
  Device resume took 252 ms in total.

### S2: first real freeze, woken by Volume Up (attended)

```sh
tools/phone-ssh 'U=$(ls -d /sys/bus/platform/devices/*.ufs); echo 5 > $U/spm_lvl
systemd-run --unit=s2-test sh -c "L=/var/lib/omandroid/suspend/s2-\$(date +%H%M%S).log
  date >> \$L; sync; echo freeze > /sys/power/state; echo rc=\$? >> \$L; date >> \$L
  cat /sys/power/pm_wakeup_irq >> \$L 2>&1; dmesg | tail -200 >> \$L; sync"'
# after about 20 s press Volume Up once; the screen should respond; reconnect USB
```

**Pass:** the phone resumes on Volume Up; `pm_wakeup_irq` is the gpio-keys
interrupt; no UFS errors; touch, display and GPU work. Then repeat with
`spm_lvl` 3 once, to learn whether the default level survives (if it does
not, a gs201 `spm_lvl` 5 default becomes a kernel commit).

**S2 result (2026-10-12, 7.3.0-rc6-omandroid-push1-00287-g3ff963085301):
passed on the second try.** Wi-Fi unloaded, UFS `spm_lvl` 3 -> 5.
- **First run:** `rc=0`, but it resumed about 3 s after suspend entry.
  `pm_wakeup_irq` was 106, the gpio-keys `KEY_VOLUMEUP` line (gpa8-5), and
  the human reports not touching the button. Volume Up is the one key with
  no internal pull (`PUD` 0x0, as stock; Volume Down and Power have 0x3),
  so a false edge as the pins enter their power-down state is possible. It
  is not proven: two edges were counted on that line, as one press makes.
  Watch for spurious wakes; if they recur, check gpa8-5's `PUD_PDN` and
  try a pull-up in the DT.
- **Second run:** asleep 39 s (wall clock), woken by Volume Up (IRQ 106) as
  intended. **No UFS error** on resume at `spm_lvl` 5 (S1 at 3 needed a
  link reset). Bluetooth logged "Opcode 0x0c24 failed: -112" on suspend
  entry (harmless here; the controller stays up).
- The `spm_lvl` 5 result argues for making 5 the gs201 default (a kernel
  commit), pending more cycles.

### S3: the RTC (PMIC overlay)

```sh
cd ~/Projects/omandroid
O=~/android/mainline/out-int; D=$O/arch/arm64/boot/dts/exynos/google/gs201-cheetah.dtb
cp "$D" "$D.default"
$O/scripts/dtc/dtc -q -I dts -O dtb -o out/suspend-pmic-test.dtbo device/cheetah/overlays/suspend-pmic-test.dtso
$O/scripts/dtc/fdtoverlay -i "$D.default" -o "$D" out/suspend-pmic-test.dtbo
KERNEL_DIR=~/android/mainline/wt-int KERNEL_OUT=$O bin/omandroid images > logs/images-suspend-s3.log 2>&1
# flash slot B, boot
tools/phone-ssh 'dmesg | grep -iE "s2mpg12|sec-pmic|rtc|acpm"; ls /sys/class/rtc
grep -E "s2mpg12|rtc" /proc/interrupts; sleep 10; grep -E "s2mpg12|rtc" /proc/interrupts
hwclock -r; date -u'
```

**Expect:** `sec-pmic-acpm` probes, `rtc0` registered, "setting system clock
to ..." from HCTOSYS, the RTC within a few seconds of NTP time, and the
SPI 72 count **not growing** while idle (a growing count = storm: stop,
`modprobe -r sec_acpm` if possible, reflash). Then an alarm while awake, then
a sleep:

```sh
tools/phone-ssh 'rtcwake -m no -s 15; sleep 20; grep -E "s2mpg12|rtc" /proc/interrupts; cat /sys/class/rtc/rtc0/wakealarm'
tools/phone-ssh 'systemd-run --unit=s3-test sh -c "L=/var/lib/omandroid/suspend/s3-\$(date +%H%M%S).log
  sync; rtcwake -m freeze -s 30 >> \$L 2>&1; echo rc=\$? >> \$L; cat /sys/power/pm_wakeup_irq >> \$L; dmesg | tail -100 >> \$L; sync"'
```

**Pass:** the awake alarm raises exactly one interrupt; the freeze returns on
its own after 30 s with `pm_wakeup_irq` = the PMIC interrupt. If USB comes
back by itself, S3 is also the unattended test from here on.

### S4: C2 in s2idle

C2 and the MCT are in the default DTB since `omandroid-power-on` was merged
into int, so only the PMIC overlay is needed. Before and
after one `rtcwake -m freeze -s 60`, record per CPU `state1/usage`,
`state1/rejected`, `state1/s2idle/usage` and `state1/s2idle/time`.
**Pass:** `s2idle/usage` grows on every CPU; `rejected` grows by a small
fraction of `usage` (as when awake, POWER-PLAN 7); about 60 s of
`s2idle/time` (us) per CPU. Then a loop of 20 cycles of 30 s sleep / 15 s awake;
any failed cycle stops the loop.

### S5: Wi-Fi across sleep

Wi-Fi loaded and connected; 10 cycles. Watch for brcmfmac D3 timeouts (-EIO
aborts), "Failed to reserve space in commonring", and whether the network
comes back. Failures here make the sleep hook unload Wi-Fi (6.2) and start the
`pcie-gs201` PM work (6.3).

### S6: battery numbers

Cable out, as POWER-PLAN section 4 (`power-ab`): A = screen off and awake,
B = screen off in s2idle (one long `rtcwake -m freeze` per phase). Wi-Fi and
BT as they would be in use. This gives the honest s2idle number to set
against SYS_SLEEP.

### S7: userspace on

New `omandroid-device-cheetah` with the sleep drop-in and hook, the
`omandroid-keys` change behind its toggle, then clear `suspend-off`. A day of
normal use: power key → sleep → power key, idle → sleep, and alarms.

## 9. Risks and rollback

| Change | Risk | Default | Rollback |
|---|---|---|---|
| `mem_sleep_default=s2idle` | none known; "mem" stops meaning firmware sleep | on | drop the bootarg |
| exynos-pmu s2idle hint | firmware treats a hinted C2 in s2idle differently | acts only in s2idle | revert; or disable `state1` at runtime |
| S2MPG12 core + RTC | IRQ storm on SPI 72; ACPM traffic at probe; RTC time written | node disabled; overlay | images without the overlay |
| `spm_lvl` 5 | slower resume (full UFS re-init) | runtime sysfs only | write 3 back, reboot |
| PM debug config | negligible | on in test kernels | n/a |
| Clearing `suspend-off` | users suspend a kernel that can't | only after S4 on the shipping image | set the toggle again |

## 10. Open questions

- Does the default `spm_lvl` 3 survive resume with `gs101_ufs_suspend`
  asserting reset, or does every resume go through link recovery? (S0, S2)
- Is the gauge's interrupt quiet enough to be a wake source, or should its
  wakeup be disabled from userspace?
- Does `dwc3` peripheral mode re-enumerate after resume with VBUS forced, and
  does the gadget come back without a cable replug?
- Does the RTC wake still arrive in SYS_SLEEP through the APM mailbox
  (WAKEUP2 bit 4), or through VGPIO2PMU (WAKEUP2 bit 13, not in stock's
  enable mask)? External tests saw bit 13.
- Can the S2MPG12 RTC's WTSR restart (as upstream does for S2MPG10) fix our
  hanging `reboot -f` (NOTES, "PMU and reboot")?
- With stock's own pin PDN table being sparse, which pins must we pin down
  before SYS_SLEEP (BT_REG_ON, UFS RST_N/REFCLK, Wi-Fi, haptics, touch)?

---

## Build result (2026-10-12)

- Kernel `7.3.0-rc6-omandroid-push1-00075-g025624c64c3f` (branch head
  `025624c64`) in `~/android/mainline/out-suspend`: `Image.gz`, DTBs and
  modules build (`out-suspend/build-kernel.log`, then
  `build-kernel2.log`). The second build merges
  `out-suspend/suspend-debug.config` (`PM_DEBUG`, `PM_ADVANCED_DEBUG`,
  `PM_SLEEP_DEBUG`) after `omandroid.config`.
- `sec-irq.o`, `sec-acpm.o`, `sec-common.o`, `rtc-s5m.o` and `exynos-pmu.o`
  build with `W=1` and no warnings. `CONFIG_MFD_SEC_ACPM=m`,
  `CONFIG_RTC_DRV_S5M=y`.
- `dt-doc-validate` and yamllint pass for the S2MPG12, ACPM and sysreg
  bindings. `dt-validate` of the default DTB with `suspend-pmic-test`
  applied reports only the existing `soc_id` and `/chosen/framebuffer`
  items. The default DTB has `pmic-1` disabled, the VGPIO2AP syscon and
  `mem_sleep_default=s2idle`; the overlay sets only `pmic-1` to okay.
- No boot images were made: this branch is meant to be merged into
  `omandroid-int` (it merges cleanly) and flashed from there (stage S1).
