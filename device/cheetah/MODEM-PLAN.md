<!-- SPDX-License-Identifier: MIT -->
# Modem plan (cheetah / gs201): S5300 on PCIe GEN4A_0

Status (2026-10-12): **offline. M0 is ready to run (read-only); M1 is
built.** Kernel branch `omandroid-modem` in `~/android/mainline/wt-modem`
(on `omandroid-int` @ `3393f8dee`), build in `~/android/mainline/out-modem`.
Everything new is disabled by default. RADIOS-CAMERA-PLAN.md section 1 is the
survey this follows.

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

Checks:
- full build exits 0 (`logs/kernel-modem2.log`); the driver builds `W=1`
  clean;
- `dt-doc-validate` of both bindings passes;
- `dt-validate` of the default DTB and of the DTB with `modem-link-test`
  reports only the existing `soc_id`/simplefb items;
- `git merge-tree` against `omandroid-int`: clean.

**Merge order:** `omandroid-modem` alone, after `omandroid-gnss`; it is
based on int, which already has it.

**Default boot changes one thing:** 4 KiB at 0xf6200000 become reserved
(they were free RAM, and stock reserves them for the modem).

omandroid repo:
- `kernel/configs/omandroid.config`: `CONFIG_PCIE_GS201_CP=m`.
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
- **Not yet:** MSI, a PCI host bridge, the API CPIF calls
  (`exynos_pcie_poweron()` and friends), suspend. They come with M3.

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
  controller too.

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

After M2 passes, **M3**: the host side CPIF needs (bus, MSI, the
`exynos_pcie_*` API), the CPIF port (`CP/`, CPIF-20220408R1), and the
`modem` vendor-chroot profile for `cbd`/`rfsd` with private NV copies.

## 4. Risks

- **First accesses to HSI1's controller.** Isolation is released before any
  ELBI read (as for Wi-Fi). If `link_up` hangs, the cause is the PHY or a
  clock: HSI1 has no CMU driver, and stock manages no clocks for ch0
  (`pcie-clk-num = 0`).
- **The modem is a bus master** once the link is up. M2 never enables bus
  mastering in the endpoint, and the endpoint's BAR is not assigned.
- **Power.** The S5300 powered for minutes with no firmware draws power;
  `cp_off` and `rmmod` turn it off, and so does reboot (shutdown callback).
- **Shared HSI1 pins.** gph1-0 (AoC), gph1-4/5 (eSE, NFC) and gph0-5 (NFC)
  are not touched.

## 5. Open questions

1. Does `link_up` need the CMU_HSI1 gates, or does the Q-channel/auto
   gating keep the controller clocked as on stock?
2. Does the ROM link come up at x2 or x1 (the ROM trains Gen1, the main
   firmware Gen3)?
3. The `cp2ap` input levels after `cp_on` without a link: is the ROM's
   behaviour what CPIF's `check_cp_status()` expects?
