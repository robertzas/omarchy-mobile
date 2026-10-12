<!-- SPDX-License-Identifier: MIT -->
# Modem plan (cheetah / gs201): S5300 on PCIe GEN4A_0

Status (2026-10-12): **M0 passed; M2 link works (Gen1 x1, 144d:a5a5).
M2.4 left the PHY out of isolation (fixed offline, `c22dc53b3`) and UFS
logged two recovered LINERESETs around modem power changes (analysis and
the M2.5 measurement below). M3 has started offline: the PCI bus with MSI
(`3a8f4c503`), the modem vendor-chroot profile, and the plan in 3.3.**
Kernel branch `omandroid-modem` in `~/android/mainline/wt-modem`, build in
`~/android/mainline/out-modem` (last full build
`7.3.0-rc6-omandroid-push1-00248-g3a8f4c503c80`, `logs/kernel-modem3.log`).
Everything new is disabled by default. RADIOS-CAMERA-PLAN.md section 1 is
the survey this follows.

**Hard rule, unchanged:** the modem's NV and firmware partitions (`efs`,
`efs_backup`, `modem_userdata`, `persist`, `modem_a`, `modem_b`) are never
written from Linux. `cbd` and `rfsd` will only ever see RAM copies made from
verified images (M3). Nothing in M0-M2 touches them; M0 adds a udev rule
that makes the first five read-only at the block layer.

Path abbreviations:

- `L/` = our kernel, branch `omandroid-modem` (`~/android/mainline/wt-modem`)
- `G/` = `~/android/omandroid/out-kernel/google/gs-6.1/private` (Google's GPL gs201 kernel)
- `PC/` = `G/google-modules/soc/gs/drivers/pci/controller/dwc-whi` (the PCIe driver stock gs201 runs: `pcie-exynos-gs.ko`, `G/devices/google/gs201/BUILD.bazel:55`)
- `CP/` = `G/google-modules/radio/samsung/s5300` (stock cheetah's CPIF: `G/devices/google/pantah/BUILD.bazel:37`, options in `pantah_defconfig:2-11`)
- `R/` = `~/android/reference/cheetah-stock-cp2a-root`
- `B/` = `~/android/reference/cheetah-partition-backup-20261011`

---

## 1. How stock brings the modem up

From `CP/modem_ctrl_s5100.c` and `PC/pcie-exynos-rc.c`:

1. **`power_on_cp()`** (`:992`) drives the control lines, raw levels:
   - `ap2cp_pda_active` = 1, `ap2cp_dump_noti` = 0.
   - `gpio_power_offon_cp()` (`:936`, `CONFIG_CP_WRESET_WA` unset):
     - **off:** `ap2cp_wakeup` 1 for 10 ms then 0, `nreset` 0,
       `cp_wrst_n` 0, `cp_pwr_on` 0 (30 ms), `pm_wrst_n` 0 (50 ms);
     - **on:** `pm_wrst_n` 1 (10 ms), `cp_pwr_on` 1 (10 ms), `nreset` 1
       (10 ms), `cp_wrst_n` 1.
2. **`start_normal_boot()`** (`:1335`) → `register_pcie()` (`:806`):
   - 200 ms, then `s5100_poweron_pcie(boot_on)` (`:1765`);
   - that calls `exynos_pcie_poweron(ch 0, Gen1)`, then enumerates
     `144d:*`;
   - `set_cp_rom_boot_img()`: the ROM DMAs the BOOT image from shared memory.
3. Check the CP status; power the link off; check again.
4. `s5100_poweron_pcie(Gen3)` for the main firmware: `ap2cp_wakeup` 1 and
   5 ms before it (`:1809`).

**The link itself** (`PC/pcie-exynos-rc.c`):
- `exynos_pcie_rc_poweron()` `:3358`: PHY isolation bypass, pins
  "active", PHY power-down clear, then `establish_link()`.
- `exynos_pcie_rc_establish_link()` `:3103`:
  - PHY config and lock checks;
  - soft power reset, RC mode, non-sticky reset;
  - EQ off (DBI 0x890 = 0x12000);
  - PERST# high and **18-20 ms** (Wi-Fi: 20-22);
  - ELBI 0x3bc/0x3a0/0x3a8/0x474/0x1078;
  - `dw_pcie_setup_rc()` + `exynos_pcie_setup_rc()` `:2720`, which for
    `EP_SAMSUNG_MODEM` also clears the root port BAR0 and ROM BAR
    (DBI 0x100010/0x100030);
  - IOCC: SYSREG_HSI1 **0x704** (`PC/pcie-exynos-rc.h:226`);
  - LTSSM, L0 within 48 ms (up to 10 tries);
  - 3 ms for the Gen1 → max change.
- Outbound ATU:
  - `prog_viewport_cfg0()` `:1361`: with `use-secure-atu` this is only
    **SMC 0x820020D8** (`:1343`, `PC/pcie-exynos-rc.h:311`);
  - `prog_viewport_mem_outbound()` `:1389` is skipped (EL3 owns the
    iATU);
  - config space is then read through the fixed config window
    (`0x40ffe000`).
- MSI:
  - the target is the modem's shared-memory MSI page (`cp_msi_rmem`
    0xf6200000, set by CPIF through `exynos_pcie_set_msi_ctrl_addr()`
    `:5109`);
  - separated vectors on GIC SPI 389-393, controller events on 388
    (`:4900-4950`, `R/live.dts:12058`).

## 2. M1: what is built (offline)

| Commit | What |
|---|---|
| `af92668ea` dt-bindings: soc: samsung: exynos-sysreg: add gs201 HSI1 | `google,gs201-hsi1-sysreg` |
| `d6b91d06d` dt-bindings: PCI: add Google gs201 PCIe GEN4A_0 (modem link) | `google,gs201-pcie-cp`, with a `modem` child for the control lines |
| `5f6a1a989` PCI: dwc: add a gs201 modem-link bring-up driver | `L/drivers/pci/controller/dwc/pcie-gs201-cp.c`, `CONFIG_PCIE_GS201_CP` (m) |
| `fb3537d02` arm64: dts: exynos: google: gs201: add PCIe GEN4A_0 and the modem MSI page | `cp-msi@f6200000` (no-map), `sysreg_hsi1`, `pcie_0` + `pcie_0_phy` (**disabled**), `pcie0_clkreq`/`pcie0_perst` pins |
| `665a08b47` arm64: dts: exynos: google: gs201-cheetah: describe the modem's control lines | `modem` child of `pcie_0` |
| `c22dc53b3` PCI: dwc: gs201-cp: isolate the PHY again after link_down | M2.4 fix: PMU 0x3ec0 back to 0 after the PHY is powered down; controller soft power reset as stock |
| `d04cff4b9` PCI: dwc: gs201-cp: optionally log the modem's cp2ap line changes | `watch_lines=1`: both-edge interrupts on the four cp2ap inputs, logged with kernel timestamps (M2.5) |
| `9c201b3f3` dt-bindings: PCI: google,gs201-pcie-cp: add the MSI page, isolation note | `memory-region` |
| `078ad0c76` arm64: dts: exynos: google: gs201: point PCIe GEN4A_0 at the modem MSI page | `cp_msi_mem` label, `memory-region` on `pcie_0` (still disabled) |
| `3a8f4c503` PCI: dwc: gs201-cp: register the modem's PCI bus on request, with MSI | `bus` step: host bridge, guarded config access, DWC MSI aimed at 0xf6200000 (M3.1) |

Checks (repeated for the five newer commits, 2026-10-12):
- full build exits 0 (`logs/kernel-modem2.log`, then `logs/kernel-modem3.log`);
  the driver builds `W=1` clean; checkpatch clean;
- `dt_binding_check` of `google,gs201-pcie-cp.yaml` passes;
- `dt-doc-validate` of both bindings passes;
- `dt-validate` of the default DTB and of the DTB with `modem-link-test`
  reports only the existing `soc_id`/simplefb items;
- `git merge-tree` against `omandroid-int`: clean.

**Merge order:** `omandroid-modem` alone, after `omandroid-gnss`; it is
based on int, which already has it.

**Default boot changes one thing:** 4 KiB at 0xf6200000 become reserved
(they were free RAM, and stock reserves them for the modem).

omandroid repo:
- `kernel/configs/omandroid.config`: `CONFIG_PCIE_GS201_CP=m`; for M3
  `CONFIG_F2FS_FS=m` (the RAM copies of the NV partitions are f2fs).
- Overlay `device/cheetah/overlays/modem-link-test.dtso`: enables the HSI1
  pin controller, `pcie_0` and `pcie_0_phy`.

**The driver** (`pcie-gs201-cp`) is deliberately not a PCI host yet:

- **Probe only maps and looks up.**
  - The PHY stays isolated.
  - PERST# and the eleven modem lines are taken with `GPIOD_ASIS`.
  - The PCIe pins are a pinctrl state named `active`, selected only by
    `link_up`.
- **Steps, one per write to `/sys/kernel/debug/gs201-pcie-cp/ctl`**, and
  only with the module parameter `allow_hw=1`:
  - `cp_on`, `cp_off`: the stock sequences above;
  - `link_up [1|2|3]`: Google's establish_link, reusing our
    `phy-gs201-pcie` (two lanes, PMU 0x3ec0) as the Wi-Fi link does, 3
    tries;
  - `atu`: the SMC;
  - `id`: vendor/device from the config window;
  - `link_down`: PERST#, LTSSM off, PHY power-down and isolation.
- **`status`** reads:
  - the line levels;
  - the PMU isolation bit, through the PMU regmap (the same path the PHY
    driver uses);
  - controller registers only once the PHY is out of isolation (the Wi-Fi
    lesson: an ELBI access while isolated hangs the SoC).
- `bus` (M3.1): register and scan the PCI bus, MSI on (3.3).
- **Not yet:** the API CPIF calls (`exynos_pcie_poweron()` and friends),
  the controller-event interrupt (link-down), suspend. They come with M3.

Why our own driver and not Google's: Google's RC driver is one module for
both channels, built around its vendor DWC fork, and the Wi-Fi link already
runs on our `pcie-gs201`. The modem link shares only the PHY. A separate
driver keeps the Wi-Fi driver untouched.

## 3. Runbooks

### M0: read-only, current int kernel

**M0.1-M0.3 as RADIOS-CAMERA-PLAN.md 1.6:**

```sh
# M0.1 partitions unchanged against the 2026-10-11 backup (reads ~430 MB)
tools/phone-ssh 'for p in efs efs_backup modem_userdata persist modem_a modem_b; do
  printf "%s  %s.img\n" "$(sha256sum < /dev/disk/by-partlabel/$p | cut -d" " -f1)" "$p"; done' \
  > logs/m0-partitions.sha256
grep -E ' (efs|efs_backup|modem_userdata|persist|modem_a|modem_b)\.img$' \
  ~/android/reference/cheetah-partition-backup-20261011/SHA256SUMS | sort -k2 | diff - <(sort -k2 logs/m0-partitions.sha256)
tools/phone-ssh 'grep -E "sda(1|5|6|7|19|29) " /proc/mounts'
# M0.2 memory map
tools/phone-ssh 'grep -iE "e8000000|ea400000|f6200000" /proc/iomem'
# M0.3 CP lines on ALIVE / FAR_ALIVE
tools/phone-ssh 'P=/sys/kernel/debug/pinctrl; grep -hE "\((gpa0-[23]|gpa8-[234])\)" $P/*180d0000*/pins $P/*180e0000*/pins'
```

**M0.4, HSI1 lines.** HSI1 pinctrl is in int now (via `omandroid-gnss`).
Add `hsi1-pinctrl-test` to the overlays the phone already boots with:

```sh
ov gnss-pmic-test gnss-test aoc-boot-test hsi1-pinctrl-test && bin/omandroid push   # reboots
tools/phone-ssh 'grep -hE "\((gph0-[0-5]|gph1-[0-6])\)" /sys/kernel/debug/pinctrl/*11840000*/pins'
```

Expected:
- gph0-0 (PERST#) and the ap2cp lines (gph0-2/3, gph1-1/2/3/6) inputs or
  low outputs;
- gph1-4/5 (eSE/NFC resets) as ABL left them;
- gph1-0 (AoC SPI select) untouched.

Record `PUD` for gpa8-3 (`cp2ap_wake_up`): keep whatever ABL set.

**M0.5, protection (no hardware access: block-layer flag only, undone by
reboot or `blockdev --setrw`):**

```sh
tools/phone-ssh 'cat > /etc/udev/rules.d/60-omandroid-modem-nv-ro.rules' <<'EOF'
# Omandroid: the modem's NV and firmware partitions are never written from Linux
SUBSYSTEM=="block", ENV{ID_PART_ENTRY_NAME}=="efs|efs_backup|modem_userdata|modem_a|modem_b", RUN+="/usr/bin/blockdev --setro $devnode"
EOF
tools/phone-ssh 'udevadm control --reload; udevadm trigger -s block -c change;
  for p in efs efs_backup modem_userdata modem_a modem_b; do echo $p $(blockdev --getro /dev/disk/by-partlabel/$p); done'
#   pass: all 1. (persist stays writable for the fingerprint work's own plan; nothing here writes it.)
```

**M0 result (2026-10-12, 7.3.0-rc6-omandroid-push1-00283-gafa4d777403d).**
This root has no `/dev/disk/by-partlabel`, so find each partition by its
`PARTNAME` instead:
`d=$(grep -l "^PARTNAME=$p\$" /sys/class/block/*/uevent | head -1 | cut -d/ -f5)`.
- **M0.1: mismatch, explained, new backup.** `modem_a` matched the
  2026-10-11 backup. `efs`, `efs_backup`, `modem_userdata` and `persist`
  differed: stock Android booted once on slot A after the backup (a
  fallback during bring-up), and its modem stack writes those. `modem_b`
  also differed, and now has exactly `modem_a`'s contents; nothing in our
  Linux writes it (all six read `ro=1` and none is mounted). The old backup
  still matches its own `SHA256SUMS`, so it was intact. A fresh read-only
  copy of the six went to
  `~/android/reference/cheetah-partition-backup-20261012-radio/` (off-repo,
  mode 600), and its checksums match the M0.1 reads. Compare against that
  one from now on; a stock boot will change the NV partitions again.
- **M0.2:** `e8000000-e9ffffff` and `ea400000-eabfffff` are reserved;
  `f6200000` is not listed.
- **M0.3:** gpa0-2/3 and gpa8-2/4 inputs, low, `PUD` 0x1; gpa8-3
  (`cp2ap_wake_up`) input, low, `PUD` 0x3 (keep it).
- **M0.4** runs on the M2 boot: `modem-link-test` enables the HSI1 pin
  controller too. **Result:** gph0-0..5 and gph1-0..3, gph1-6 are inputs,
  low, `PUD` 0x1; gph1-4 (eSE reset) is an output driven low, gph1-5 (NFC
  reset) an output driven high, both as ABL left them; gph1-0 (AoC SPI
  select) untouched.
- **M0.5: passed.** The udev rule is in place, and all five partitions read
  `blockdev --getro` 1.

**M2.0 result (same boot): passed.** `pcie_gs201_cp` is blacklisted
(device-cheetah 0.1.21) and was loaded by hand with `allow_hw=1`: "modem
PCIe ch0 bring-up: 2 lanes, steps enabled". Every ap2cp output and cp2ap
input is 0, PERST# is asserted, PMU 0x3ec0 is 0x0 (PHY isolated), and the
state is "cp 0, phy 0/0, link 0, atu 0". No controller access.

### M2: link only (int + `omandroid-modem`, overlay `modem-link-test`)

No firmware is involved and nothing reaches the NV partitions. The modem's
ROM only answers on PCIe and waits for a BOOT image it never gets. Watch the
kernel log from a second terminal (`tools/phone-ssh dmesg -w`). If anything
hangs, the watchdog resets the phone; the overlay is not in the default DTB.

```sh
ov gnss-pmic-test gnss-test aoc-boot-test modem-link-test && bin/omandroid push   # reboots
# M2.0 bind, read-only
tools/phone-ssh 'modprobe pcie-gs201-cp allow_hw=1; dmesg | grep -i "pcie-cp\|11920000" | tail -3;
  cat /sys/kernel/debug/gs201-pcie-cp/status'
#   pass: "modem PCIe ch0 bring-up: 2 lanes, steps enabled"; PMU 0x3ec0 bit 0 = 0 (isolated);
#   lines as in M0.3/M0.4; no LTSSM line (PHY isolated, so no controller reads)
# M2.1 modem power only, no PCIe (about 130 ms of GPIO steps)
tools/phone-ssh 'echo cp_on > /sys/kernel/debug/gs201-pcie-cp/ctl; sleep 2; cat /sys/kernel/debug/gs201-pcie-cp/status;
  sleep 8; cat /sys/kernel/debug/gs201-pcie-cp/status'
#   expect: outputs pda-active 1, pwr-on 1, nreset 1, cp-wrst 1, pm-wrst 1. The cp2ap inputs
#   may stay low: the ROM waits for the link. Record them.
#   then: echo cp_off > .../ctl ; status shows the outputs back at 0
# M2.2 link at Gen1 (the first ELBI/DBI accesses on this controller, after isolation release)
tools/phone-ssh 'echo cp_on > /sys/kernel/debug/gs201-pcie-cp/ctl; sleep 0.2;
  echo link_up > /sys/kernel/debug/gs201-pcie-cp/ctl; dmesg | tail -8; cat /sys/kernel/debug/gs201-pcie-cp/status'
#   pass: "link up: Gen1 x1|x2 (target Gen1)"; LTSSM 0x11 (L0)
#   "no L0" three times: send dmesg and status; then link_down + cp_off
# M2.3 secure ATU and the endpoint ID
tools/phone-ssh 'echo atu > /sys/kernel/debug/gs201-pcie-cp/ctl; echo id > /sys/kernel/debug/gs201-pcie-cp/ctl; dmesg | tail -3'
#   pass: "secure ATU SMC: 0"; "endpoint 144d:a5a5 class ..."
# M2.4 everything off
tools/phone-ssh 'echo link_down > /sys/kernel/debug/gs201-pcie-cp/ctl; echo cp_off > /sys/kernel/debug/gs201-pcie-cp/ctl;
  cat /sys/kernel/debug/gs201-pcie-cp/status; rmmod pcie_gs201_cp'
#   pass: PMU bit 0 back to 0, outputs 0, PERST# asserted
```

**M2.1-M2.4 result (2026-10-12, same boot): the link works; two open
problems.**
- **M2.1 passed.** All five ap2cp outputs went to 1. The modem raised
  `cp2ap-wakeup` 1 within 2 s (its ROM asking for the link);
  `cp2ap-cp-wrst`, `ps-hold` and `phone-active` stayed 0.
- **M2.2 passed.** PHY "PLL lock 1, CDR lock 1, OC done 1", "DBI ID
  0xa5a5144d", "link up: Gen1 x1 (target Gen1), try 1", LTSSM 0x11 (L0).
  Only one lane trained, at the Gen1 target.
- **M2.3 passed.** "secure ATU SMC: 0x0"; "endpoint 144d:a5a5 class
  000000".
- **M2.4 partial.** The outputs went back to 0 and PERST# was asserted,
  but **PMU 0x3ec0 stayed 0x1**: the PHY was not isolated again. Fixed in
  `c22dc53b3` (M2 analysis below); re-test in M2.5.3.
- **UFS errors around modem power changes.** UFS ran its error handler
  (`saved_err = 0x4; saved_uic_err = 0x40`, a PA-layer error), recovered
  at once (Gear 4, 2 lanes, HBA operational), and logged no I/O or
  filesystem errors. It happened twice, at 252.24 s (about 1 s before the
  M2.2 power cycle, with the modem powered since M2.1 at 231 s) and at
  277.14 s (0.23 s after the M2.4 power-off). The two previous boots had
  none. Until the cause is known (a shared supply, ground bounce or a
  reference clock between HSI1 and UFS are candidates), keep the modem
  powered only for short attended tests, and check
  `dmesg | grep ufshcd_err_handler` after each. Analysis and the M2.5
  measurement below.

### M2 analysis (offline, 2026-10-12)

**M2.4, the PHY stayed out of isolation: a driver bug, fixed in `c22dc53b3`.**
- `link_down` called `phy_exit()` and assumed it isolates the PHY. Our
  `phy-gs201-pcie` exit deliberately only drops the clocks: Google never
  isolates the Wi-Fi link's PHY after probe, and that controller is
  accessed after exit.
- Stock does not isolate ch0 at runtime either: `R/live.dts` has neither
  `use-phy-isol-en` (so `use_phy_isol_con` is false,
  `PC/pcie-exynos-rc.c:1934-1950`) and sets `phy-power-off = "false"`. It
  isolates a link that is down only when the system suspends
  (`exynos_pcie_rc_suspend_noirq()`, `PC/pcie-exynos-rc.c:5433-5442`).
- The modem link is down most of the time, so ours isolates at every
  `link_down`, after the PHY power-down and the clock release, through the
  same SMC-backed PMU regmap that `phy_init()` uses to release it (never
  devmem), and logs the value read back: "PHY isolated (PMU 0x3ec0 =
  0x0)". `link_down` now also pulses the controller's soft power reset
  after LTSSM is off, as `exynos_pcie_rc_poweroff()` does
  (`PC/pcie-exynos-rc.c:3626-3632`). Re-test in M2.5.3.

**M2.2, x1 instead of x2: expected.** CPIF asks for the ROM link with
`exynos_pcie_poweron(ch, 1, 1)` (Gen1, width 1) and for the main firmware
with `(ch, 3, 2)` (`CP/modem_ctrl_s5100.c:1824`). Google's RC driver
ignores the width (`PC/pcie-exynos-rc.c:4280`, two arguments), so the x1
comes from the modem's ROM.

**The UFS errors: what they are.** `saved_err 0x4` is `UIC_ERROR`,
`saved_uic_err 0x40` is `UFSHCD_UIC_PA_GENERIC_ERROR`: the PA layer
reported a **LINERESET** on the UFS M-PHY link (`L/drivers/ufs/core/ufshcd.c:7194-7206`).
With only that bit set, the error handler checks the power mode and
restores it if needed (`:7079-7090`); no reset, no aborted command. So
the UFS link saw a burst of errors bad enough for one side to send a line
reset, then carried on. That points at signal integrity or a reference
or supply disturbance on the UFS lanes, not at anything the modem driver
wrote.

**What UFS and the modem link share, from stock's DT and sources:**

| Candidate | Finding | Verdict |
|---|---|---|
| A PMIC rail | PCIe ch0 PHY: S2MPG12 LDO16M (`L16M_PCIE0`, 0.85 V) and LDO18M (`L18M_PCIE0`, 1.8 V), both `regulator-always-on` (`R/live.dts:13487-13520`), nothing else on them. UFS: `ufs-vcc` (a GPIO-switched fixed regulator, `:9829-9836`) and S2MPG13 LDO2S (`L2S_PLL_MIPI_UFS`, `:14002`). Our DT does not describe these regulators, so nothing switches them. | Not shared |
| A reference clock | UFS takes its 38.4 MHz reference from the AP's `ufs_refclk_out` pin gph3-0 in HSI2 (`R/live.dts:4870-4876`); the PCIe ch0 PHY is in HSI1, with no CMU clocks in stock (`pcie-clk-num = 0`). Both PHYs run from the TCXO, but the first error came with the ch0 PHY still isolated and never powered. | Unlikely for event 1; possible for event 2 (PHY power-down 0.2 s before) |
| PMU registers | PHY controls are neighbours (PCIe ch0 0x3ec0, ch1 0x3ec4, UFS 0x3ec8: `R/live.dts:9805`), each its own register, written with atomic set/clear SMCs. No PMU write happened near event 1. | No |
| Pins | The modem lines are in HSI1 (gph0/gph1) and ALIVE (gpa0/gpa8); the UFS pins are gph3 in HSI2. | No |
| The modem's own power | The S5300 has its own supply from VSYS (`VSYS_PWR_MODEM`, ODPM channel `R/live.dts:13717`), sequenced by `pm_wrst_n`/`cp_pwr_on`. Event 2 came 0.14 s after the last power line dropped (the modem's PMIC turning its rails off). Event 1 came 21 s after power-on with the ROM waiting for a link, and with no AP action: consistent with the ROM giving up and resetting itself, which stock never lets happen (CPIF trains the link 200 ms after power-on, `CP/modem_ctrl_s5100.c:870-872`). | Most likely: a load step on VSYS or ground bounce when the modem changes power state |
| DMA from the modem | Event 1 came before any link existed. The endpoint's bus mastering was never enabled. | No |

Stock's error-free record does not contradict this: stock powers the modem
once per boot and keeps it running; it powers it off only at shutdown. Our
M2 sat the ROM on a missing link for 21 s and cut its power with the UFS
link busy, two states stock does not reach.

**Proposed fix: follow stock's timing; no software can remove a supply
transient.**
1. Never leave the modem powered without a link for more than a few
   seconds: `cp_on` is followed by `link_up` within 0.2 s (M2.5.3, M3.1),
   and from M3 on CPIF does this itself.
2. Power the modem off only when it has to be (stock: shutdown, crash
   reset). The M3 service keeps it on.
3. The measurement below tells which of the two transitions disturbs UFS
   and whether stock's timing avoids it. If a transition still causes a
   LINERESET with stock timing, the next step is hardware (a scope on VSYS
   and the UFS supplies), which is out of reach here. The errors recovered
   cleanly, so that would be a nuisance at boot and shutdown, not a risk to
   data.

### M2.5: isolation re-test and the UFS measurement (int + `omandroid-modem` @ `3a8f4c503`)

**Before:** the human merges `omandroid-modem` into `omandroid-int` (merge
tree clean on 2026-10-12) and builds int into `out-int`. The DTB changes
(`memory-region`), so push the images, not only the modules. Same overlays
as M2. **Risk: medium.** UFS is the root disk and M2.5.2/M2.5.3
deliberately repeat the two transitions that coincided with LINERESETs.
Each was seen once and recovered at once.

```sh
ov gnss-pmic-test gnss-test aoc-boot-test modem-link-test && bin/omandroid push   # reboots
# second terminal, for all of M2.5 and M3.1:
tools/phone-ssh dmesg -w | tee logs/m2.5-kmsg.log

# M2.5.0 load with the line watch (reads only)
tools/phone-ssh 'modprobe pcie-gs201-cp allow_hw=1 watch_lines=1; dmesg | grep -E "pcie-cp|watching" | tail -6'
#   pass: "steps enabled" and four "watching cp2ap-... (now 0)". A "no interrupt" or
#   "cannot watch" warning for a line: record it and go on (the others still log).
# UFS counters (debugfs) and a 1 GiB file to read (once; a normal file on the root fs)
tools/phone-ssh 'cat /sys/kernel/debug/ufshcd/14700000.ufs/stats; dmesg | grep -c ufshcd_err_handler;
  test -f /var/tmp/ufsload || head -c 1G /dev/zero > /var/tmp/ufsload'

# M2.5.1 baseline: 60 s of UFS reads, modem off
tools/phone-ssh 'timeout 60 sh -c "while :; do dd if=/var/tmp/ufsload of=/dev/null bs=1M iflag=direct status=none; done";
  dmesg | grep -c ufshcd_err_handler; cat /sys/kernel/debug/ufshcd/14700000.ufs/stats'
#   pass: the err_handler count and every counter unchanged

# M2.5.2 M2's timing: modem powered with no link for 60 s under load, then off under load
tools/phone-ssh 'C=/sys/kernel/debug/gs201-pcie-cp/ctl
  (timeout 70 sh -c "while :; do dd if=/var/tmp/ufsload of=/dev/null bs=1M iflag=direct status=none; done") &
  echo cp_on > $C; sleep 60; echo cp_off > $C; wait
  dmesg | grep -E "cp2ap|power-|ufshcd_err_handler|saved_err" | tail -30; cat /sys/kernel/debug/ufshcd/14700000.ufs/stats'
#   record: the time of every cp2ap edge (expect cp2ap-wakeup -> 1 within 2 s of
#   "modem power-on sequence"; anything at about +20 s is the ROM giving up),
#   and of every ufshcd_err_handler, against "modem power-on/off sequence".

# M2.5.3 stock timing: link 0.2 s after power-on, 60 s up under load, then down and off under load
tools/phone-ssh 'C=/sys/kernel/debug/gs201-pcie-cp/ctl
  (timeout 70 sh -c "while :; do dd if=/var/tmp/ufsload of=/dev/null bs=1M iflag=direct status=none; done") &
  echo cp_on > $C; sleep 0.2; echo link_up > $C; sleep 60; echo link_down > $C; echo cp_off > $C; wait
  dmesg | grep -E "cp2ap|power-|link up|PHY isolated|ufshcd_err_handler|saved_err" | tail -30
  cat /sys/kernel/debug/gs201-pcie-cp/status; cat /sys/kernel/debug/ufshcd/14700000.ufs/stats'
#   pass (the M2.4 fix): "link up: Gen1 x1", then "PHY isolated (PMU 0x3ec0 = 0x0)";
#   status shows PMU 0x3ec0: 0x0, outputs 0, perst 1, "state: cp 0, phy 0/0, link 0, atu 0"
#   record: ufshcd_err_handler times as in M2.5.2
tools/phone-ssh 'rmmod pcie_gs201_cp; rm -f /var/tmp/ufsload'
```

**Stop** at once (`echo link_down > $C; echo cp_off > $C; rmmod
pcie_gs201_cp`, no more modem power until analysed) if UFS logs anything
beyond the error handler and its recovery: an I/O error, `Host Resets` or
`SCSI command aborts` going up in `stats`, "link broken", an ext4 error.
If the root filesystem stops answering, wait for the watchdog, or ask the
human to force a restart.
**Rollback:** `rmmod pcie_gs201_cp`; images without `modem-link-test`.

**Reading the result:**

| Errors seen in | Meaning | Next |
|---|---|---|
| none of 1-3 | Neither transition disturbs UFS at this load; M2's two events need the ROM timeout or chance | Go on to M3.1 with stock timing |
| 2 only, with a cp2ap edge at about +20 s | The ROM's own reset after the link timeout | Fix 1 is enough; go on |
| 2 and 3, at `cp_off` | The modem's power-down disturbs UFS | Fix 2: power off only at shutdown; repeat 3 without the load to see whether an idle (hibernated) UFS link is immune |
| 1 | Not the modem | Stop modem work; investigate UFS on its own |

### M3: boot the modem

**Goal:** the S5300 boots its stock firmware from a RAM copy of
`modem_a` and reaches ONLINE (`IOCTL_GET_CP_STATUS`), with `rfsd` serving
NV from RAM copies. The radio stays off: nothing sends the SIT request
that turns it on (that is M4). The real NV and firmware partitions are
never written and never enter the chroot.

**What the host side needs, from `CP/` (CPIF-20220408R1, the pantah
options in `G/devices/google/pantah/pantah_defconfig:2-11`):**

- **A PCI device to bind to.** `s51xx_pcie.c` is a `pci_driver` for
  `144d:a5a5`. It allocates four MSI vectors with
  `pci_alloc_irq_vectors_affinity()` (`CP/s51xx_pcie.c:305-316`,
  `CP/modem_ctrl_s5100.c:733-804`) and rewrites BAR0 itself to
  `pci_db_addr` (0x14e60000, the doorbell; `CP/s51xx_pcie.c:381-420`),
  which is inside our MEM window. **Done offline:** the `bus` step
  (`3a8f4c503`), tested in M3.1.
- **MSI.** Separated MSI: one GIC SPI per DWC MSI block (SPI 389-393 =
  blocks 0-4; `PC/pcie-exynos-rc.c:4913-4945`), the same split mainline's
  DWC core handles with `msi0`..`msi4`. The target is `cp_msi_rmem`
  (0xf6200000). **Done offline**, with one gap: pktproc's "exclusive" IRQs
  take a raw block IRQ through Google's `register_separated_msi_vector()`
  (`PC/pcie-exynos-rc.c:4856-4895`). Mainline's chained handlers own those
  SPIs, so the port runs pktproc with `use_exclusive_irq` off (all queues
  on the shared vectors) first.
- **The link API.** About 20 `exynos_pcie_*` calls (`CP/` grep): the ones
  that matter are `exynos_pcie_poweron(ch, speed, width)` (link_up + secure
  ATU + MSI re-arm + restore the endpoint's saved config),
  `exynos_pcie_poweroff(ch)` (link_down; the bus stays), `chk_link_status`,
  `set_msi_ctrl_addr` (check it equals the memory-region),
  `set_perst_gpio`, `l1ss_ctrl` (no-op at first), `register_event`
  (link-down callback from the "ctrl" IRQ 388, later). The rest are dump,
  recovery-state and BTL helpers that can be stubs. **M3.2**: export them
  from `pcie-gs201-cp` as `gs201_pcie_cp_*()` with a header, and give the
  CPIF port a small compat file that maps the `exynos_pcie_*` names.
- **The modem's lines.** Stock CPIF drives them itself from its own DT node
  (`CP/modem_ctrl_s5100.c:906-934`). M3.2 moves them from our `modem` child
  node to the CPIF node (an overlay), so there is one owner; our `cp_on` /
  `cp_off` steps stay for debugging without CPIF.
- **Shared memory.** `cp_rmem` (0xea400000, 8 MiB IPC) and `cp_rmem_1`
  (0xe8000000, 32 MiB packet rings) are reserved `no-map` already
  (`e7cb10fe5`); CPIF maps them itself. `cp_aoc_rmem` (0x197fd000, AoC
  SRAM, voice) is left out of the CPIF node: never mapped until the AoC
  voice path is designed (RADIOS-CAMERA-PLAN 1.5).
- **Left out of the port:** `LINK_DEVICE_PCIE_IOMMU` (Google's pcie
  sysmmu), `GS_S2MPU`, DIT, SPI boot, `CP_THERMAL`, BTL, logbuffer (stubbed),
  the AP-suspend-during-call path. CPIF must return errors where stock
  panics.
- **DMA.** Without the HSI1 SysMMU/S2MPU the modem can write anywhere in
  RAM once CPIF enables bus mastering. Unlike HSI2, HSI1's SysMMU serves
  only PCIe ch0 (`R/live.dts:12093-12105`), so confining it is possible:
  M3.6, after the modem boots, under the S2MPU rule (touch only CTRL0).

**Userspace (built offline, in the repo, not packaged yet):**
- `tools/extract-vendor-chroot -p modem`: `cbd`, `rfsd`, their libraries
  (`libjson`, `libz`, `libcutils`, `libutils`, `libcrypto`, `libc++`,
  `liblog`; no binder) and `cbd.rc`, `rfsd.rc`, `fstab.modem`. Tested on
  the laptop against CP2A.260705.006: 22 files, 7.9 MB.
  `ro.vendor.cbd.modem_type=s5100sit` comes from the vendor `build.prop`.
- `packages/omandroid-modem/profiles/modem.conf` for
  `omandroid-vendor-chroot`, with `modem/props.conf`. At start it checks
  that the five NV/firmware partitions read `ro=1` and none of the six is
  mounted, reads `modem_a`, `efs`, `efs_backup`, `modem_userdata` and
  `persist` **into a tmpfs**, compares each copy with
  `/etc/omandroid/modem-nv.sha256` (the human copies the matching lines
  from the off-repo backup's `SHA256SUMS`; the phone keeps them, the repo
  never does) and stops on any mismatch. The chroot gets loop devices of
  the copies only: `modem_a` read-only at `by-name/modem_a` and
  `/mnt/vendor/modem_img`, the three f2fs images read-write at
  `/mnt/vendor/{efs,efs_backup,modem_userdata}`, and a copy of
  `persist/modem`. Then `rfsd -d`, and `cbd -d -t s5100sit -P
  by-name/modem_a -s 2` as `cbd.rc` runs it. Whatever the modem writes to
  NV is lost at stop.
- Pinned properties (`modem/props.conf`): slot `_a`, normal boot mode,
  `persist.vendor.modem.efs.clear.action` empty, recovery off, modem
  logging off.
- `CONFIG_F2FS_FS=m` in `kernel/configs/omandroid.config`.

**Stages:**

| Stage | What | Where | Effort | Risk |
|---|---|---|---|---|
| M3.1 | `bus` on the ROM link: enumerate, MSI domain, guarded config space | phone, runbook below | an hour | medium |
| M3.2 | `gs201_pcie_cp_*` API + compat names; lines moved to a CPIF node (overlay); "ctrl" IRQ for link-down | offline | 3-5 days | none |
| M3.3 | CPIF port as an out-of-tree module set built against our tree: about 21k lines in 21 C files plus headers (the pantah set minus the parts above). API drift (class, netdev, GPIO, timers), panics turned into errors | offline | 2-3 weeks | none |
| M3.4 | Load the port with the line overlay; the modem profile with `OMANDROID_MODEM_STAGE=rfsd`, then `cbd`: BOOT image over PCIe at Gen1, main firmware at Gen3 x2, CP ONLINE | phone | 1-2 weeks of debugging (boot handshake, shared-memory layout, doorbell, MSI) | medium: the modem DMAs into reserved memory with no IOMMU |
| M3.5 | After every M3.4 run: the M0.1 checksums of the six partitions against the 20261012-radio backup | phone, read-only | minutes | none |
| M3.6 | HSI1 SysMMU confining the modem's DMA to its shared memory | offline, then phone | 1 week | medium |

M4 (attach, one data call, SMS) needs a SIT client: the protocol is not
public, so its layouts come from the stock libraries' requests. Expect 3-6
weeks to data and SMS, then 2-4 weeks for a ModemManager plugin; oFono has
no SIT driver either. "Registers on the network under ModemManager" is
realistically two to three months away, M3 included, and calls need the
AoC voice path on top (M5).
The SIT transport, message IDs, layouts and a minimal client are in [MODEM-SIT-RESEARCH.md](MODEM-SIT-RESEARCH.md).

#### M3.1: the bus on the ROM link (after M2.5, same boot or the next)

**Risk: medium.** The first enumeration through the secure monitor's
config window, and the first root-port services (`pcieport`: AER, PME,
bandwidth notification) on this controller. ASPM is set to `performance`
first so the core does not put the ROM's link into L1 while we look.
Nothing binds to the endpoint, so its bus mastering stays off.

```sh
tools/phone-ssh 'cat /sys/module/pcie_aspm/parameters/policy; echo performance > /sys/module/pcie_aspm/parameters/policy'
tools/phone-ssh 'modprobe pcie-gs201-cp allow_hw=1 watch_lines=1'
tools/phone-ssh 'C=/sys/kernel/debug/gs201-pcie-cp/ctl; echo cp_on > $C; sleep 0.2; echo link_up > $C;
  echo atu > $C; echo id > $C; echo bus > $C; dmesg | grep -E "pcie-cp|11920000|pcieport|144d" | tail -20'
#   pass: "MSI: 160 vectors, target 0x00000000f6200000"; "<dom>:00:00.0 144d:ecec class 060400"
#   and "<dom>:01:00.0 144d:a5a5 class ..." (dom is 0001 or the next free domain)
tools/phone-ssh 'for d in /sys/bus/pci/devices/*; do echo "$d $(cat $d/vendor):$(cat $d/device)"; done;
  E=$(grep -l 0xa5a5 /sys/bus/pci/devices/*/device | head -1 | xargs dirname);
  cat $E/resource | head -2; grep -E "PCI-MSI|pcie" /proc/interrupts'
#   pass: BAR0 of the endpoint inside 0x40000000-0x40feffff (or unassigned: CPIF sets it itself);
#   the root port's MSI vectors listed (pcieport)
# link down with the bus kept: config space must read as absent, not hang
tools/phone-ssh 'C=/sys/kernel/debug/gs201-pcie-cp/ctl; E=$(grep -l 0xa5a5 /sys/bus/pci/devices/*/device | head -1 | xargs dirname);
  echo link_down > $C; echo cp_off > $C; od -An -tx4 -N4 $E/config; cat /sys/kernel/debug/gs201-pcie-cp/status'
#   pass: ffffffff; PMU 0x3ec0: 0x0
tools/phone-ssh 'rmmod pcie_gs201_cp; ls /sys/bus/pci/devices; dmesg | grep -c ufshcd_err_handler'
#   pass: the modem's domain is gone; the err_handler count as after M2.5
```

**Stop:** `bus` does not return, or the phone resets (the watchdog): the
config window or DBI path is wrong; send `logs/m2.5-kmsg.log`. "no L0":
as M2.2. Any UFS message beyond a recovered error handler: as M2.5.
**Rollback:** `link_down`, `cp_off`, `rmmod pcie_gs201_cp`; reboot clears
the ASPM policy.

## 4. Risks

- **First accesses to HSI1's controller.** Isolation is released before any
  ELBI read (as for Wi-Fi). If `link_up` hangs, the cause is the PHY or a
  clock: HSI1 has no CMU driver, and stock manages no clocks for ch0
  (`pcie-clk-num = 0`).
- **The modem is a bus master** once the link is up. M2 never enables bus
  mastering in the endpoint, and the endpoint's BAR is not assigned. From
  M3.1 the BAR is assigned but nothing enables bus mastering; from M3.4
  CPIF does, with no IOMMU until M3.6.
- **UFS line resets** around modem power changes (M2 analysis): keep stock's
  timing, check `ufshcd_err_handler` after each step, stop on anything
  worse than a recovered handler.
- **NV.** From M3.4 the daemons run; they only ever see RAM copies (the
  modem profile), and M3.5 re-checks the real partitions after each run.
- **Power.** The S5300 powered for minutes with no firmware draws power;
  `cp_off` and `rmmod` turn it off, and so does reboot (shutdown callback).
- **Shared HSI1 pins.** gph1-0 (AoC), gph1-4/5 (eSE, NFC) and gph0-5 (NFC)
  are not touched.

## 5. Open questions

1. ~~Does `link_up` need the CMU_HSI1 gates?~~ No: M2.2 trained and
   read DBI with no HSI1 clock driver, as stock (`pcie-clk-num = 0`).
2. ~~x2 or x1 for the ROM link?~~ x1, which is what CPIF asks for
   (M2 analysis); the main firmware should train Gen3 x2 (M3.4).
3. The `cp2ap` levels without a link: `cp2ap-wakeup` goes to 1 within
   2 s, the others stay 0 (M2.1). Whether the ROM gives up later is M2.5.2.
4. Which modem transition disturbs UFS, and does stock's timing avoid it
   (M2.5)?
5. Does the endpoint keep answering config reads with ASPM on (M3.1 turns
   it off), and does CPIF's own L1SS control work without Google's
   `exynos_pcie_rc_l1ss_ctrl()` (M3.2 starts with a no-op)?
6. `cbd -s 2` and the `persist.vendor.modem.efs.clear.action` paths: read
   from the binaries before M3.4 (strings and disassembly, offline); the
   RAM copies make a wrong guess cost a copy, not NV.
