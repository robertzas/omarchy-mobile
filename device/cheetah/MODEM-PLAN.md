<!-- SPDX-License-Identifier: MIT -->
# Modem plan (cheetah / gs201): S5300 on PCIe GEN4A_0

Status (2026-10-12): **M0, M2.5 and M3.1 passed** (link at stock timing,
PHY re-isolated, the modem enumerates as 144d:a5a5). **Every modem
power-off is followed by one recovered UFS error-handler pass**, so the
modem now stays on once up (M2.6: analysis, policy, a one-power-off
measurement). Offline: M3.2 done; CPIF stage 1 (boot, IPC, RFS) builds;
the modem profile is ready for M3.4. Next on the phone: M2.6, M3.3-B
(bind only), M3.4 (boot from a RAM copy, modem left on), then
MODEM-CLIENT.md M4.0.
Kernel branch `omandroid-modem` in `~/android/mainline/wt-modem` (head
`781b9c3d8`), build in `~/android/mainline/out-modem` (last full build
`7.3.0-rc6-omandroid-push1-00349-g781b9c3d8523`, `logs/kernel-modem7.log`).
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
- Since M3.2 (section 2.1): the API CPIF calls (`gs201_pcie_cp_*()`) and
  the controller-event interrupt (link-down, completion timeout). **Not
  yet:** suspend.

Why our own driver and not Google's: Google's RC driver is one module for
both channels, built around its vendor DWC fork, and the Wi-Fi link already
runs on our `pcie-gs201`. The modem link shares only the PHY. A separate
driver keeps the Wi-Fi driver untouched.

### 2.1 M3.2 and the first M3.3 stage (offline, 2026-10-12)

Branch `omandroid-modem`, back-merged from `omandroid-int` first (a fast
forward: int already had the modem branch), then:

| Commit | What |
|---|---|
| `e760ccf73` dt-bindings: PCI: google,gs201-pcie-cp: let the modem driver own the lines | the `modem` child may be disabled |
| `ce6c974f8` PCI: dwc: gs201-cp: leave the modem lines to the modem driver | lines taken only while `modem` is available; otherwise `cp_on`/`cp_off` return -ENODEV and `status` says so |
| `4513ebe14` soc: google: cpif: import Google's S5300 modem interface driver | `CP/` files for boot, IPC, RFS, verbatim, not built (`L/drivers/soc/google/cpif/`) |
| `acfb82374` PCI: dwc: gs201-cp: export the modem link to the modem driver | `gs201_pcie_cp_*()` (`L/include/linux/soc/google/gs201-pcie-cp.h`) and the "ctrl" interrupt |
| `ff5b99009` soc: google: aoc: alsa: notify voice calls through the modem notifier only | AoC card built again once `EXYNOS_MODEM_IF` exists; no behaviour change |
| `f521c0894` soc: google: cpif: port the S5300 boot, IPC and RFS path to Linux 7.3 | `cpif.ko`, `shm_ipc.ko`, `pcie-gs201-compat.c` |
| `3ec0e495a` soc: google: cpif: shm_ipc: index regions by their memory-region position | no `rmem_index` needed on our reserved-memory nodes |
| `4983fc51e` dt-bindings: PCI: google,gs201-pcie-cp: add the modem's shared memory | `memory-region` on `modem` |
| `2afb0db3f` arm64: dts: exynos: google: gs201-cheetah: describe the modem's shared memory | IPC 0xea400000, MSI 0xf6200000, packets 0xe8000000, stock's order |
| `6ff2a4690` soc: google: cpif: take the lines and regions from the board's modem node | see "where the lines live" below |
| `4dce2136a` PCI: dwc: gs201-cp: refuse the modem driver's poweron without allow_hw | bind CPIF with the link provably down |
| `1344a9e0b` soc: google: cpif: do not let the driver be unloaded | no `remove()`, so no `module_exit()`: permanent |

**The link API (M3.2).** CPIF's ~20 `exynos_pcie_*()` calls map onto
`gs201_pcie_cp_*()` in `L/drivers/soc/google/cpif/pcie-gs201-compat.c`:

| Google's call | Ours | Notes |
|---|---|---|
| `exynos_pcie_poweron(ch, spd, width)` | `gs201_pcie_cp_poweron(spd)` | `link_up` + secure ATU + bus (scanned the first time, then MSI re-armed and the endpoint's saved config restored, as `PC/pcie-exynos-rc.c:3358-3530`); faults cleared; width ignored, as Google; **-EPERM without `allow_hw=1`** |
| `exynos_pcie_poweroff(ch)` | `gs201_pcie_cp_poweroff()` | PME_Turn_Off and the wait for L2 idle (`:3033-3101`), then our `link_down` (PHY isolated again); bus kept |
| `exynos_pcie_rc_chk_link_status(ch)` | `gs201_pcie_cp_link_ok()` | LTSSM 0x0d-0x14 = up (`:4299-4349`); lock-free, reads ELBI only while the PHY is out of isolation |
| `exynos_pcie_set_msi_ctrl_addr(ch, a)` | `gs201_pcie_cp_check_msi_addr(a)` | the target is the controller's `memory-region`; a mismatch is an error |
| `exynos_pcie_set_perst_gpio(ch, on)` | `gs201_pcie_cp_set_perst_level()` | raw level |
| `exynos_pcie_rc_l1ss_ctrl()` | `gs201_pcie_cp_l1ss()` | no-op: L1SS never enabled yet (open question 5) |
| `exynos_pcie_register_event()` / `deregister` | `gs201_pcie_cp_register_event()` | one client; callback from a work item with Google's event codes |
| `rc_get/set_sudden_linkdown_state`, `rc_get/set_cpl_timeout_state` | `gs201_pcie_cp_faults()` / `clear_faults()` | |
| `exynos_pcie_rc_force_linkdown_work()` | `gs201_pcie_cp_force_linkdown()` | atomic-safe; CPIF calls it with a spinlock held |
| `exynos_pcie_set_ready_cto_recovery()` | `gs201_pcie_cp_prepare_recovery()` | our `link_down` |
| `rc_register_dump`, `rc_dump_all_status`, `rc_print_msi_register` | `gs201_pcie_cp_dump()` | LTSSM, IRQ0-2, faults |
| `rc_set_outbound_atu` (BTL), `register_separated_msi_vector` (pktproc) | -EOPNOTSUPP | parts not ported |

**The "ctrl" interrupt (SPI 388).** Enabled after `link_up`, disabled first
in `link_down` (ELBI is readable only between them). IRQ1 bit 10 = link
down, IRQ2 bit 24 = completion timeout, as `exynos_pcie_rc_irq_handler()`
(`PC/pcie-exynos-rc.c:2853-2920`). The first fault is kept until CPIF
clears it, later ones are only logged (Google ignores them during a
recovery). After a link-down the endpoint's config space reads as absent
and the link-down source stays masked until the next `link_up`, so a dead
link cannot storm. Without a client the driver only logs "event ...: no
client". `status` shows `faults: <bits>, ctrl irq on|off`. This also
applies to the debugfs `link_up` from now on (M2.5.3 and M3.1 log a
link-down if the ROM's link drops).

**Where the lines live.** The plan said "move the lines to a CPIF node
(overlay)". That cannot work with our overlays: the base DTB has no
`__symbols__`, and our dtc refuses `<&{/path}>` references in an overlay
("Can't generate fixup for reference to path"), so an overlay cannot give a
new node GPIO or memory-region phandles. Putting Google's CPIF node in the
base DTS instead adds ~200 dt-validate items (vendor properties, no
binding). So the board describes the modem once, in the documented
`samsung,s5300-modem` child of `pcie_0` (lines, and now the three shared
regions); CPIF's own nodes carry only CPIF's configuration, and CPIF takes
the lines and regions from the modem node (`cp_lines_node()`,
`cp_rmem_node()`). Ownership is the node's status: the `modem-cpif-test`
overlay disables it, so the link driver leaves the lines alone and CPIF
owns them. Never apply `modem-link-test` and `modem-cpif-test` together.

**The CPIF port, stage 1 (M3.3).** `CONFIG_EXYNOS_MODEM_IF=m`,
`SEC_MODEM_S5100=y`, `SHM_IPC=m` (in `kernel/configs/omandroid.config`).
Built: the platform driver and DT parsing, the boot/dump device
(`/dev/umts_boot0`), the IPC/RFS character devices (`umts_ipc0/1`,
`umts_rfs0`, ...), the rmnet network devices, the shared-memory link with
legacy buffers, the S5100 control, the PCIe endpoint driver and the region
driver. Not built (as planned): packet processor (data goes through the
legacy raw buffers, `pktproc_*` left out of the node), DIT, PCIe IOMMU,
S2MPU, BTL, throughput monitor, thermal zones, SPI boot. Port changes
beyond API drift:
- GPIO descriptors from the modem node (raw levels, outputs start low).
- Regions are `no-map` here: `memremap()` (WB for cached, WC otherwise)
  instead of `phys_to_virt()`/`vmap()`; nothing is ever given back to the
  page allocator.
- Every `panic()` and `BUG()` is an error or a log line, including the one
  cbd can request (`IOCTL_TRIGGER_KERNEL_PANIC`).
- The PCI driver matches 144d:a5a5 only (stock: any Samsung function,
  which would take our root port 144d:ecec).
- `cpif` has no `remove()`, so it has no `module_exit()` either: once loaded
  it stays until reboot (`rmmod` refuses). Lesson from the AoC `rmmod` oops.
- `pcie-gs201-cp` refuses `gs201_pcie_cp_poweron()` unless loaded with
  `allow_hw=1`, so binding CPIF without it cannot touch the link.

DT: the modem node gets `memory-region` (base DTS); the overlay
`device/cheetah/overlays/modem-cpif-test.dtso` enables the HSI1 pins, the
controller and the PHY, disables the modem node for the link driver, and
adds `cpif` and `cp-shmem` from stock's nodes (`R/live.dts:18238`,
`:18649`), compared property by property with stock after `fdtoverlay`:
identical except the left-out parts, the GPIO property names, `pinctrl`
(below) and the AoC voice window. The modules are blacklisted by a new
file, `packages/omandroid-device-cheetah/vendor/modprobe.d/omandroid-cpif.conf`
(package version unchanged; reinstall it before the overlay boots).

**Stock's line pin states, not ported yet.** Stock's `cpif` node selects
11 pinctrl states: the seven ap2cp outputs with no pull and
`pin-con-pdn = 3` (keep the level in power-down), cp2ap-wakeup and
cp2ap-phone-active as EINT (function 0xf) with pull-down (`pin-pud = 1`),
ps-hold and cp2ap-cp-wrst with pull-down. M0.3 found ABL leaves gpa8-3
(cp2ap-wakeup) at `PUD` 0x3. Irrelevant for bind and boot with the AP
awake; needed before any suspend with the modem on (M3.4+).

**After M2.5 (2026-10-12, on int `606b84c7a`, back-merged as a fast forward):**

| Commit | What |
|---|---|
| `4bcede988` PCI: dwc: gs201-cp: power the modem off as stock does, and trace the lines | `cp_off` = stock's sequence (pda-active untouched), `pda_off`, `trace_lines` |
| `1aa72188d` soc: google: cpif: keep the modem on unless a power-off is allowed | `allow_poweroff` (default off), `trace_lines` |
| `d01e1ebbe` soc: google: cpif: s51xx: map the doorbell only inside the bridge window | stock maps BAR0 + offset from the window start even when the window is unassigned |
| `781b9c3d8` PCI: dwc: gs201-cp: add a slow power-off step to tell the edges apart | `cp_off_slow`, 1 s between edges |

Same checks as below: full build exits 0 (`logs/kernel-modem7.log`),
`W=1` clean, checkpatch clean on the changes. Repo:
`packages/omandroid-modem/profiles/modem.conf` binds `by-name/modem`
(rfsd and cbd open it unsuffixed), `/dev/kmsg`, CPIF's sysfs device,
`/chosen/plat` and `/chosen/config` read-only, and a stand-in
`/sys/power/wake_lock`, and refuses to start without CPIF's device.

**Checks (2026-10-12):**
- full build exits 0: `logs/kernel-modem6.log` (release in the last line
  of this list);
- `W=1`: `pcie-gs201-cp.o` and all of `drivers/soc/google/cpif/` build with
  no warnings (16 missing-prototype warnings in Google's code fixed);
- checkpatch `--strict`: clean on our new code (driver, header,
  `pcie-gs201-compat.c`, `cpif-compat.h`, Kconfig, Makefile); the imported
  Google files keep Google's style, as with the AoC port;
- `dt_binding_check` of `google,gs201-pcie-cp.yaml`: passes;
- `dt-validate` of the default DTB: only the existing `soc_id`,
  simplefb and gs201 PMU/watchdog compatible items; with `modem-cpif-test`:
  the same plus the vendor properties of `cpif` and `cp-shmem` (no binding,
  overlay only);
- `modinfo`: `cpif` depends on `shm_ipc` and `pcie-gs201-cp`.
- release `7.3.0-rc6-omandroid-push1-00318-g1344a9e0b9ea` (head `1344a9e0b`);
  `git merge-tree` against `omandroid-int`: clean.

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

### M2.5: isolation re-test and the UFS measurement (int + `omandroid-modem` @ `3a8f4c503` or later)

**Before:** the human merges `omandroid-modem` into `omandroid-int` (merge
tree clean on 2026-10-12) and builds int into `out-int`. The DTB changes
(`memory-region`), so push the images, not only the modules. Same overlays
as M2 (`modem-link-test`, never `modem-cpif-test`). **Risk: medium.** UFS
is the root disk and M2.5.2/M2.5.3 deliberately repeat the two transitions
that coincided with LINERESETs. Each was seen once and recovered at once.

The same runbook works at the M3.2 head (section 2.1): the steps are
unchanged; the driver also enables the "ctrl" interrupt after `link_up`,
so a link that drops during M2.5.3 now logs "link down (IRQ0/1/2 ...)",
and `status` has a `faults:` line (expect `0x0`, `ctrl irq off` after
`link_down`).

**Modem power is attended and short.** M2.5.2 and M2.5.3 keep the modem
powered for 60 s each, under load, with a human watching the kmsg stream.
Each is one SSH command that ends with `cp_off`; in case the session dies
in between, arm a dead-man timer first that powers the modem off after
100 s, and stop it after the step (it does nothing if the modem is
already off):

```sh
tools/phone-ssh 'systemd-run --unit=x-modem-off --on-active=100 sh -c "C=/sys/kernel/debug/gs201-pcie-cp/ctl; echo link_down > \$C; echo cp_off > \$C"'
# ... the step ...
tools/phone-ssh 'systemctl stop x-modem-off.timer 2>/dev/null; cat /sys/kernel/debug/gs201-pcie-cp/status | grep -E "pwr-on|PMU|state"'
#   pass: ap2cp-cp-pwr-on 0, PMU 0x3ec0: 0x0, "state: cp 0"
```

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
#   (dead-man armed as above)
tools/phone-ssh 'C=/sys/kernel/debug/gs201-pcie-cp/ctl
  (timeout 70 sh -c "while :; do dd if=/var/tmp/ufsload of=/dev/null bs=1M iflag=direct status=none; done") &
  echo cp_on > $C; sleep 60; echo cp_off > $C; wait
  dmesg | grep -E "cp2ap|power-|ufshcd_err_handler|saved_err" | tail -30; cat /sys/kernel/debug/ufshcd/14700000.ufs/stats'
#   record: the time of every cp2ap edge (expect cp2ap-wakeup -> 1 within 2 s of
#   "modem power-on sequence"; anything at about +20 s is the ROM giving up),
#   and of every ufshcd_err_handler, against "modem power-on/off sequence".

# M2.5.3 stock timing: link 0.2 s after power-on, 60 s up under load, then down and off under load
#   (dead-man armed as above)
tools/phone-ssh 'C=/sys/kernel/debug/gs201-pcie-cp/ctl
  (timeout 70 sh -c "while :; do dd if=/var/tmp/ufsload of=/dev/null bs=1M iflag=direct status=none; done") &
  echo cp_on > $C; sleep 0.2; echo link_up > $C; sleep 60; echo link_down > $C; echo cp_off > $C; wait
  dmesg | grep -E "cp2ap|power-|link up|PHY isolated|ufshcd_err_handler|saved_err" | tail -30
  cat /sys/kernel/debug/gs201-pcie-cp/status; cat /sys/kernel/debug/ufshcd/14700000.ufs/stats'
#   pass (the M2.4 fix): "link up: Gen1 x1", then "PHY isolated (PMU 0x3ec0 = 0x0)";
#   status shows PMU 0x3ec0: 0x0, outputs 0, perst 1, "state: cp 0, phy 0/0, link 0, atu 0"
#   (M3.2 head: also "faults: 0x0, ctrl irq off"; a "link down" line during the 60 s
#   means the ROM dropped its link: record its time against the cp2ap edges)
#   record: ufshcd_err_handler times as in M2.5.2
tools/phone-ssh 'rmmod pcie_gs201_cp; rm -f /var/tmp/ufsload'
```

**Expect/Pass** per step above. **Stop** at once (`echo link_down > $C;
echo cp_off > $C; rmmod pcie_gs201_cp`, no more modem power until
analysed) if UFS logs anything
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

### M2.6: the modem power-off and UFS (after the M2.5 result)

**What M2.5 found** (result below, in M3): every modem power-off is
followed, 0.08-0.15 s after "modem power-off sequence", by one recovered
UFS error-handler pass (`saved_uic_err 0x40`, a PA LINERESET) and
thousands of Data Link Layer errors (76021 over three power-offs, 12 PHY
Adapter). Power-on, a 60 s link under load and `link_down` before the
power-off were not separated in time from it, so M2.5 cannot say whether
`link_down` alone disturbs UFS. No I/O errors, resets or aborts.

**Our sequence against stock's, edge by edge** (`CP/modem_ctrl_s5100.c`):

| | stock `power_off_cp()` (cbd's POWER_OFF) | stock `power_shutdown_cp()` (shutdown) | ours, M2.5 (`link_down` + `cp_off`) |
|---|---|---|---|
| before the lines | state OFFLINE; link off first (`pcie_clean_dislink()` -> `s5100_poweroff_pcie()`: ap2cp-wakeup 0 + 5 ms, PME_Turn_Off, PERST# low, LTSSM off, soft reset, PHY powered down, **not isolated**) | cp2ap interrupts off; waits up to 3 s for phone-active high (CP running); the link stays up | `link_down`: PERST# low, LTSSM off, soft reset, PHY powered down **and isolated** (no PME_Turn_Off in the debugfs step) |
| lines (`gpio_power_off_cp()`) | wakeup 1, 10 ms, wakeup 0, nreset 0, cp-wrst 0, pwr-on 0, 30 ms, pm-wrst 0, 50 ms | the same | the same |
| after | nothing | link off afterwards | **pda-active 0** (never in stock: stock drives it low only for AP suspend) |

There is no graceful shutdown handshake in stock's kernel driver: cbd/RIL
may turn the radio off first, then the same line sequence cuts the
modem's power. The only differences were the trailing pda-active edge
and the PHY isolation. The PHY can't be the cause: in M2.5.2 it was never
released (no link) and the error came anyway. The timing argues against
pda-active too (it came at +90 ms, one error at +80 ms), which leaves the
modem's own power-down (pwr-on at +10 ms, pm-wrst at +40 ms): its PMIC
turning its rails off. Stock reaches that edge only at shutdown and in
crash recovery, so it would not show there.

**Changes (offline, kernel `4bcede988`, `1aa72188d`, `781b9c3d8`):**
- `cp_off` is now stock's sequence exactly: pda-active stays high; a
  separate `pda_off` step (only with the modem off) drives it low, so
  each edge is measured on its own. Module removal still leaves all lines
  low.
- `trace_lines=1` (`pcie-gs201-cp` and `cpif`) logs every output edge with
  its time.
- `cp_off_slow`: the same edges, same order, 1 s apart: a diagnostic to
  attribute the disturbance to one edge.
- **Policy: the modem stays on once it is up.** CPIF refuses cbd's
  `IOCTL_POWER_OFF` unless loaded with `allow_poweroff=1` ("power off
  refused, the modem stays on"); stopping the modem profile leaves it on.
  The modem is powered off only by: shutdown/reboot (stock's
  `power_shutdown_cp()`, one UFS event per reboot, as now), crash
  recovery (cbd's reset: a power cycle), and an explicit, attended
  request (`allow_poweroff=1` and the profile's stop, or `cp_off` on the
  link driver when it owns the lines). Restarting cbd power-cycles the
  modem (its POWER_ON starts with the off sequence): don't, reboot
  instead.

**M2.6 runbook: one power-off with the new sequence, edges apart in time.**
Kernel: int with `omandroid-modem` at `781b9c3d8` or later; overlays as
M2.5 (`modem-link-test`, not `modem-cpif-test`). **Risk: medium**: one
deliberate modem power-off, which so far always gave one recovered UFS
handler pass; the root disk is under load as in M2.5 for an A/B
comparison. Attended; kmsg streamed (`tools/phone-ssh dmesg -w | tee
logs/m2.6-kmsg.log`).

```sh
# M2.6.0 load with tracing (reads only), baseline
tools/phone-ssh 'modprobe pcie-gs201-cp allow_hw=1 watch_lines=1 trace_lines=1;
  cat /sys/bus/platform/devices/14700000.ufs/auto_hibern8 2>&1; dmesg | grep -c ufshcd_err_handler;
  cat /sys/kernel/debug/ufshcd/14700000.ufs/stats; test -f /var/tmp/ufsload || head -c 1G /dev/zero > /var/tmp/ufsload'
#   record: auto_hibern8, the err_handler count, the stats

# M2.6.1 dead-man, then one power cycle with each transition 5 s apart, under load
tools/phone-ssh 'systemd-run --unit=x-modem-off --on-active=100 sh -c "C=/sys/kernel/debug/gs201-pcie-cp/ctl; echo link_down > \$C; echo cp_off > \$C"'
tools/phone-ssh 'C=/sys/kernel/debug/gs201-pcie-cp/ctl; S=/sys/kernel/debug/ufshcd/14700000.ufs/stats
  (timeout 50 sh -c "while :; do dd if=/var/tmp/ufsload of=/dev/null bs=1M iflag=direct status=none; done") &
  echo cp_on > $C; sleep 0.2; echo link_up > $C; sleep 20
  echo "== link_down"; echo link_down > $C; sleep 5; grep -E "Data Link|PHY Adapter" $S
  echo "== cp_off";    echo cp_off > $C;    sleep 5; grep -E "Data Link|PHY Adapter" $S
  echo "== pda_off";   echo pda_off > $C;   sleep 5; grep -E "Data Link|PHY Adapter" $S; wait
  systemctl stop x-modem-off.timer
  dmesg | grep -E "pcie-cp|ufshcd_err_handler|saved_err" | tail -40; cat /sys/kernel/debug/gs201-pcie-cp/status'
#   expect: "link up: Gen1 x1"; at link_down "PHY isolated (PMU 0x3ec0 = 0x0)"; the traced edges
#   "ap2cp-wakeup = 1", "... = 0", "ap2cp-nreset = 0", "ap2cp-cp-wrst = 0", "ap2cp-cp-pwr-on = 0",
#   "ap2cp-pm-wrst = 0", then 5 s later "ap2cp-pda-active = 0"; status: outputs 0, PMU 0x0
#   record: the time of every ufshcd_err_handler and the stats after each phase
```

| UFS errors after | Meaning | Next |
|---|---|---|
| `link_down` | taking the link down (PERST#, PHY power-down or isolation) disturbs UFS: CPIF does that whenever the modem idles | offline: stop isolating at runtime (stock doesn't), measure again; before M3.4 |
| `cp_off` only | the modem's power-down itself; stock's sequence doesn't avoid it | keep the policy; optional M2.6.2 attributes the edge; go on to M3.3-B |
| `pda_off` only | the extra pda-active edge was the cause; fixed by matching stock | go on |
| none | the M2.5 events needed the old edge timing, or chance | keep the policy; go on |

```sh
# M2.6.2 OPTIONAL, only on the human's go (a second power-off): which edge
tools/phone-ssh 'systemd-run --unit=x-modem-off --on-active=100 sh -c "C=/sys/kernel/debug/gs201-pcie-cp/ctl; echo link_down > \$C; echo cp_off > \$C"'
tools/phone-ssh 'C=/sys/kernel/debug/gs201-pcie-cp/ctl
  (timeout 30 sh -c "while :; do dd if=/var/tmp/ufsload of=/dev/null bs=1M iflag=direct status=none; done") &
  echo cp_on > $C; sleep 2; echo cp_off_slow > $C; sleep 3; wait; systemctl stop x-modem-off.timer
  dmesg | grep -E "pcie-cp|ufshcd_err_handler" | tail -20'
#   record: which traced edge (1 s apart) the ufshcd_err_handler follows
tools/phone-ssh 'rmmod pcie_gs201_cp; rm -f /var/tmp/ufsload'
```

**Stop** as M2.5 (an I/O error, Host Resets or SCSI aborts going up,
"link broken", an ext4 error): no more modem power until analysed.
**Rollback:** `link_down`, `cp_off`, `systemctl stop x-modem-off.timer`,
`rmmod pcie_gs201_cp` (leaves all lines low).

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
| M3.2 | `gs201_pcie_cp_*` API + compat names; lines handed to CPIF (overlay); "ctrl" IRQ for link-down | offline | **done 2026-10-12** (2.1) | none |
| M3.3 | CPIF port, in-tree modules (`L/drivers/soc/google/cpif/`): stage 1 (boot, IPC, RFS, legacy buffers; 18 C files, 13.6k lines) **builds, 2026-10-12** (2.1); then M3.3-B on the phone (bind only); pktproc later | offline + phone | stage 1 done; M3.3-B an hour | low-medium |
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


**M2.5 result (2026-10-12, 7.3.0-rc6-omandroid-push1-00345-g606b84c7a9fd, int
with omandroid-modem 1344a9e0b; overlays incl. `modem-link-test`): power-off
of the modem disturbs UFS every time; the rest is clean.**
- M2.5.0: four "watching cp2ap-... (now 0)", "steps enabled, modem lines here".
- M2.5.1 baseline, 60 s of `dd` reads with the modem off: err_handler count 0,
  every UFS stats counter 0.
- M2.5.2 (powered, no link, 60 s under load): `cp2ap-wakeup -> 1` 18 ms after
  "modem power-on sequence"; **no** event at +20 s (the M2 event at 21 s did
  not repeat); no UFS error while powered. 0.15 s after "modem power-off
  sequence": `ufshcd_err_handler` (saved_err 0x4, saved_uic_err 0x40), back
  to operational; stats then PHY Adapter 6, Data Link 20518.
- M2.5.3 (stock timing): "link up: Gen1 x1 (target Gen1), try 1" 0.28 s after
  power-on; 60 s up under load with no link-down and no UFS error; at
  link_down + cp_off: **"PHY isolated (PMU 0x3ec0 = 0x0)"** (the M2.4 fix
  works), status PMU 0x0, perst 1, "faults: 0x0, ctrl irq off". 0.08 s after
  the power-off sequence: the same UFS handler pass (+3 PHY Adapter, +5540
  Data Link).
- In every case: no I/O error, no ext4 error, Host Resets 0, SCSI aborts 0,
  Logical Unit Resets 0.
- **Conclusion:** the modem's power-off sequence (not power-on, not a running
  link) disturbs the UFS link, as the agent's analysis suspected (the
  modem's own supplies collapsing; stock powers the modem off only at
  shutdown). The modem stack must keep the modem on once it's up and avoid
  power cycles; investigate the power-off ordering (PDA_ACTIVE, PM/CP reset
  lines, a delay) and whether quiescing UFS around a power-off is needed.

**M3.1 result (same boot): passed.** ASPM policy set to `performance`. One
command did power-on, link, ATU, ID and bus scan: "bridge configuration
invalid ... reconfiguring" (normal for a fresh bus), then `0001:00:00.0
144d:ecec` (root port) and `0001:01:00.0 [144d:a5a5] type 00 class 0x000000
PCIe Endpoint`, BARs 0 and 2-5 sized 1 MiB (unassigned: CPIF assigns them),
ROM 64 KiB, "ASPM: default states L1"; LTSSM 0x11, "faults: 0x0, ctrl irq
on". No driver bound to the endpoint (and none to the root port).
`link_down` + `cp_off`: config space read `ffffffff` (no hang), PMU 0x3ec0
0x0, "state: cp 0, phy 0/0, link 0, atu 0", "faults: 0x0, ctrl irq off",
no link-down event. The power-off again gave one recovered UFS handler pass.
`rmmod pcie_gs201_cp` removed domain 0001. UFS totals after M2.5 and M3.1:
PHY Adapter 12, Data Link 76021, no resets or aborts, no I/O errors.
Next: M3.3-B (bind only) needs a boot with `modem-cpif-test` instead of
`modem-link-test`.

#### M3.1: the bus on the ROM link (after M2.5, same boot or the next)

**Kernel:** int with `omandroid-modem` at the M3.2 head (section 2.1) or
at `3a8f4c503`; overlays as M2.5 (`modem-link-test`, never
`modem-cpif-test`). **Risk: medium.** The first enumeration through the
secure monitor's config window, and the first root-port services
(`pcieport`: AER, PME, bandwidth notification) on this controller. ASPM is
set to `performance` first so the core does not put the ROM's link into L1
while we look. Nothing binds to the endpoint, so its bus mastering stays
off. **Modem power:** about 30 s, attended, under a 90 s dead-man; the
power-on and the bus scan are one command so the ROM never waits for a
link (the M2 analysis).

Keep the kmsg stream from M2.5 running (`tools/phone-ssh dmesg -w | tee logs/m3.1-kmsg.log`).

```sh
# M3.1.0 read-only: ASPM policy, then load (no hardware access)
tools/phone-ssh 'cat /sys/module/pcie_aspm/parameters/policy; echo performance > /sys/module/pcie_aspm/parameters/policy;
  lsmod | grep -c pcie_gs201_cp || modprobe pcie-gs201-cp allow_hw=1 watch_lines=1;
  dmesg | grep -c ufshcd_err_handler; cat /sys/kernel/debug/gs201-pcie-cp/status | grep -E "PMU|state|faults"'
#   expect: "PMU 0x3ec0: 0x0", "state: cp 0, phy 0/0, link 0, atu 0", "faults: 0x0, ctrl irq off"
#   record: the err_handler count

# M3.1.1 dead-man, then power-on, link, ATU, bus in one go
tools/phone-ssh 'systemd-run --unit=x-modem-off --on-active=90 sh -c "C=/sys/kernel/debug/gs201-pcie-cp/ctl; echo link_down > \$C; echo cp_off > \$C"'
tools/phone-ssh 'C=/sys/kernel/debug/gs201-pcie-cp/ctl; echo cp_on > $C; sleep 0.2; echo link_up > $C &&
  echo atu > $C && echo id > $C && echo bus > $C; dmesg | grep -E "pcie-cp|11920000|pcieport|144d" | tail -20;
  cat /sys/kernel/debug/gs201-pcie-cp/status | grep -E "LTSSM|faults"'
#   pass: "link up: Gen1 x1"; "MSI: 160 vectors, target 0x00000000f6200000";
#   "<dom>:00:00.0 144d:ecec class 060400" and "<dom>:01:00.0 144d:a5a5 class ..." (dom 0001 or the next free);
#   M3.2 head: "faults: 0x0, ctrl irq on", LTSSM 0x11

# M3.1.2 read-only look at the bus (same power window)
tools/phone-ssh 'for d in /sys/bus/pci/devices/*; do echo "$d $(cat $d/vendor):$(cat $d/device)"; done;
  E=$(grep -l 0xa5a5 /sys/bus/pci/devices/*/device | head -1 | xargs dirname);
  cat $E/resource | head -2; grep -E "PCI-MSI|pcie" /proc/interrupts'
#   pass: BAR0 of the endpoint inside 0x40000000-0x40feffff (or unassigned: CPIF sets it itself);
#   the root port's MSI vectors listed (pcieport); no driver bound to the a5a5 function

# M3.1.3 link down with the bus kept: config space must read as absent, not hang; then power off
tools/phone-ssh 'C=/sys/kernel/debug/gs201-pcie-cp/ctl; E=$(grep -l 0xa5a5 /sys/bus/pci/devices/*/device | head -1 | xargs dirname);
  echo link_down > $C; echo cp_off > $C; od -An -tx4 -N4 $E/config; cat /sys/kernel/debug/gs201-pcie-cp/status;
  systemctl stop x-modem-off.timer'
#   pass: ffffffff; PMU 0x3ec0: 0x0; outputs 0; "state: cp 0, phy 0/0, link 0, atu 0";
#   M3.2 head: "faults: 0x0, ctrl irq off" (a link-down event logged at link_down would be a bug: report it)

# M3.1.4 unload (the bus goes with the module)
tools/phone-ssh 'rmmod pcie_gs201_cp; ls /sys/bus/pci/devices; dmesg | grep -c ufshcd_err_handler'
#   pass: the modem's domain is gone; the err_handler count as in M3.1.0
```

**Stop:** `bus` does not return, or the phone resets (the watchdog): the
config window or DBI path is wrong; send `logs/m3.1-kmsg.log`. "no L0":
as M2.2 (`link_down`, `cp_off`, analyse). A "link down" or "completion
timeout" line while the link should be up: power off (`link_down`,
`cp_off`) and send the log. Any UFS message beyond a recovered error
handler: as M2.5.
**Rollback:** `link_down`, `cp_off`, `systemctl stop x-modem-off.timer`,
`rmmod pcie_gs201_cp`; reboot clears the ASPM policy. If the phone stops
answering, wait for the watchdog (or the dead-man) and ask the human; send
no more commands.

#### M3.3-B: bind CPIF, no firmware, no modem power

**What it proves:** the port probes on the phone: `shm_ipc` finds and maps
the three regions, CPIF parses its node, takes the eleven lines from the
modem node, registers its interrupts and creates its devices, and the
link driver hands over the lines. CPIF requests the cp2ap interrupts
only once the modem has booted (`complete_normal_boot()`), so none are
requested here. **Nothing powers the modem:**
`pcie-gs201-cp` is loaded *without* `allow_hw`, so the link API refuses
`poweron` (and the debugfs steps); CPIF powers the modem only when `cbd`
asks (`IOCTL_POWER_ON`/`BOOT`), and nothing here opens its devices. The NV
and firmware partitions are not involved at all (no `cbd`, no `rfsd`, no
chroot).

**Before:** M2.5 and M3.1 passed (M3.1 proves the bus that CPIF will scan
in M3.4). Int with `omandroid-modem` at the M3.2 head, built, and
`modules-<release>.tar.zst` pushed with the images (CPIF is new). **Risk:
low-medium**: first probe of a large vendor driver (13.6k lines), which
maps 8 MiB of reserved memory (`memremap()` of no-map RAM) and takes the
eleven lines. Binding drives the ap2cp outputs low; M0.4 found them low
already. CPIF cannot be unloaded once loaded (no `remove()`): undo by
reboot.

```sh
# M3.3-B.0 blacklist first (AGENTS: before the DTB that enables the node).
# Same package version, reinstalled with the new omandroid-cpif.conf:
tools/phone-install-package packages/omandroid-device-cheetah
tools/phone-ssh 'modprobe -c | grep -E "^blacklist (cpif|shm_ipc|pcie_gs201_cp)$"; ls /etc/modprobe.d/'
#   pass: the three blacklist lines; no omandroid-*.conf copies in /etc/modprobe.d
# M0.1-style checksums of the six partitions against the 20261012-radio backup (read-only)
#   pass: all match (M0 result); if a stock boot happened since, take a fresh backup first (AGENTS)

# M3.3-B.1 boot the overlay (asks the human: reboots)
ov gnss-pmic-test gnss-test aoc-boot-test modem-cpif-test && bin/omandroid push
tools/phone-ssh 'uname -r; lsmod | grep -E "^(cpif|shm_ipc|pcie_gs201_cp) " ; ls /dev/umts_* 2>&1 | head -2;
  cat /sys/kernel/debug/gpio | grep -E "gph0-[23]|gph1-[1236]|gpa0-[23]|gpa8-[234]"'
#   pass: none of the three modules loaded; no /dev/umts_*; the eleven lines as M0.3/M0.4 (no owner)

# second terminal for the rest:
tools/phone-ssh dmesg -w | tee logs/m3.3b-kmsg.log

# M3.3-B.2 link driver without hardware access
tools/phone-ssh 'modprobe pcie-gs201-cp; dmesg | grep pcie-cp | tail -2; cat /sys/kernel/debug/gs201-pcie-cp/status'
#   pass: "steps disabled (allow_hw=0), modem lines left to the modem driver";
#   status: "modem lines: owned by the modem driver", "PMU 0x3ec0: 0x0", "state: cp 0, phy 0/0, link 0, atu 0",
#   "faults: 0x0, ctrl irq off"

# M3.3-B.3 the regions
tools/phone-ssh 'modprobe shm_ipc; dmesg | grep -iE "rmem|shmem|cp_shmem" | tail -12'
#   pass: "rmem 0 cp-rmem@ea400000 0xea400000 0x00800000", "rmem 1 cp-msi@f6200000 0xf6200000 0x00001000",
#   "rmem 2 cp-rmem1@e8000000 0xe8000000 0x02000000", then the four regions; no "failed"

# M3.3-B.4 CPIF
tools/phone-ssh 'modprobe cpif; dmesg | grep -iE "cpif|cp_interface|s5100|s51xx|mif|xxx" | tail -40'
#   pass: the probe ends without "xxx" (CPIF's failure marker) and without an Oops;
#   "num_iodevs:52"; "PCIe Channel Number:0"; no "Failed to vmap"/"Failed to map"; no "poweron" line
tools/phone-ssh 'ls /dev/umts_*; ls /sys/class/net | grep -c rmnet; grep -ciE "cp2ap|phone_active" /proc/interrupts;
  cat /sys/kernel/debug/gpio | grep -E "AP2CP|CP2AP"; cat /sys/kernel/debug/gs201-pcie-cp/status | grep -E "PMU|state|faults";
  grep "^cpif " /proc/modules; dmesg | grep -c ufshcd_err_handler'
#   pass: /dev/umts_boot0, umts_ipc0, umts_ipc1, umts_rfs0 (and the other iodevs); 30 rmnet devices;
#   0 cp2ap interrupts (requested only after a boot); every AP2CP_* line "out lo", CP2AP_* "in";
#   link status unchanged (PMU 0x0, state all 0); /proc/modules shows cpif "[permanent]";
#   err_handler count unchanged

# M3.3-B.5 nothing changes on its own: wait 60 s, look again
tools/phone-ssh 'sleep 60; cat /sys/kernel/debug/gpio | grep -E "AP2CP|CP2AP"; dmesg | tail -5'
#   pass: AP2CP lines still low, CP2AP inputs low (the modem is unpowered); no new CPIF lines
```

**Record** in this plan: the date, `uname -r`, the probe log lines (no
addresses beyond the region bases above), the `/dev/umts_*` list.
**Stop** (and reboot, never `rmmod cpif`): an Oops or a panic; any
`AP2CP_*` line high, or `ap2cp-cp-pwr-on`/`nreset` driven; "PMU 0x3ec0"
not 0x0; a "poweron" or "link up" line (the `allow_hw` gate failed: report
it, it must not happen); a CP2AP input high while the modem is unpowered
(a floating line: compare gpa8-3's `PUD` with stock's pull-down, section
2.1); anything from UFS beyond the M2.5 baseline.
**Rollback:** reboot (`reboot-to omandroid`); CPIF's reboot handler only
sets a flag, and its shutdown runs the power-off line sequence on an
already unpowered modem. Then images without `modem-cpif-test`: `cp
"$D.default" "$D"; bin/omandroid images && bin/omandroid push`.
**Next:** M3.4 below, on a fresh boot (`allow_hw` is fixed at load time,
and CPIF can't be unloaded): the modem was never powered in M3.3-B, so
that reboot costs no UFS event.

#### M3.4: boot the S5300 firmware from a RAM copy, and leave it on

**What it does:** the stock `cbd` and `rfsd` run in the modem vendor
chroot (`packages/omandroid-modem/profiles/modem.conf`) on RAM copies of
`modem_a`, `efs`, `efs_backup`, `modem_userdata` and `persist/modem`,
each checked against the human's off-repo backup before any daemon runs.
cbd powers the modem through CPIF, trains the link at Gen1, hands the ROM
the BOOT image over PCIe (`/dev/umts_boot0`), then the main firmware at
Gen3, and the CP reaches ONLINE with rfsd serving NV from the copies.
The radio stays off (nothing sends SIT). **The modem is left on at the
end**, until the next reboot, unless the human says otherwise: every
power-off costs a UFS error-handler pass (M2.5/M2.6).

**Never:** a real NV or firmware partition in the chroot, a write to one,
`rmmod cpif`, restarting cbd (a power cycle), or stopping the profile
while the modem runs (rfsd gone: the modem loses its NV; reboot instead).

**Before (offline / laptop):**
1. M2.6 done (its table decides whether `link_down` disturbs UFS: if it
   does, the runtime-isolation change comes first, because CPIF takes the
   link down between the BOOT and main stages and whenever the modem
   idles).
2. M3.3-B passed (bind, no power).
3. Kernel: int with `omandroid-modem` at `781b9c3d8` or later, built, the
   modules tarball pushed with the images.
4. The modem chroot image, from the user's own factory image, never
   committed: `tools/extract-vendor-chroot -p modem -o
   ~/android/vendor-chroot-work/modem <image-cheetah-...zip>` (2026-10-12:
   22 files, 7.9 MB, CP2A.260705.006).
5. The checksum file for the phone, from the newest off-repo backup (the
   two 2026-10-12 backups hold the same sums): only the five lines the
   profile reads, never committed:
   `grep -E ' (modem_a|efs|efs_backup|modem_userdata|persist)\.img$' ~/android/reference/cheetah-modem-nv-backup-20261012-1402/SHA256SUMS > /tmp/modem-nv.sha256`

**What cbd needs, read from the binaries (2026-10-12):** `/dev/umts_boot0`,
`/dev/block/by-name/modem` and `modem_a` (both bound to the RAM copy),
`/mnt/vendor/modem_img/images/default/...` (the image's ext4),
`/mnt/vendor/efs/nv_*.bin` (the RAM copy: cbd writes NV files there),
`/sys/devices/platform/cpif/sim/ds_detect`,
`/sys/firmware/devicetree/base/chosen/{plat,config}` (bound read-only if
the bootloader put them in our DTB; the profile says so if not),
`/sys/power/wake_lock` (a stand-in: no `CONFIG_PM_WAKELOCKS`), and the
properties `ro.boot.cdt_hwid` / `persist.vendor.modem.cdt_hwid` (the
board's hardware id; without them cbd falls back to the default hardware
config). rfsd needs `/dev/umts_rfs0`, `/mnt/vendor/efs*` and
`by-name/modem`. cbd can ask the kernel to panic
(`IOCTL_TRIGGER_KERNEL_PANIC`): the port only logs it.

**Risk: medium-high**: the first boot of the modem's firmware from Linux.
The modem becomes a bus master with no IOMMU (M3.6) and DMAs into the
reserved regions; a crash makes cbd collect a dump and reset the modem (a
power cycle: one UFS handler pass); the root disk's link has been shown
to take recovered errors around modem power changes. Attended throughout;
kmsg streamed.

```sh
# M3.4.0 install the profile and the image (no hardware access; asks the human: writes /usr/lib)
tar -C ~/android/vendor-chroot-work/modem -cf - root MANIFEST SOURCE STUBS |
  tools/phone-ssh 'mkdir -p /usr/lib/omandroid-vendor/modem && tar --no-same-owner -C /usr/lib/omandroid-vendor/modem -xf -'
tools/phone-ssh 'install -Dm644 /dev/stdin /usr/lib/omandroid-vendor/profiles/modem.conf' < packages/omandroid-modem/profiles/modem.conf
tools/phone-ssh 'install -Dm644 /dev/stdin /usr/lib/omandroid-vendor/modem/props.conf' < packages/omandroid-modem/modem/props.conf
tools/phone-ssh 'install -Dm600 /dev/stdin /etc/omandroid/modem-nv.sha256' < /tmp/modem-nv.sha256; rm /tmp/modem-nv.sha256
tools/phone-ssh 'cat /usr/lib/omandroid-vendor/modem/SOURCE; ls /usr/lib/omandroid-vendor/omandroid-vendor-chroot; wc -l /etc/omandroid/modem-nv.sha256'
#   pass: the CP2A source line; the runner (from omandroid-gnss) present; 5 lines
# Optional, if cbd later logs that it can't find its hardware config: the human copies the
# ro.boot.cdt_hwid value from the stock capture's getprop into
# /var/lib/omandroid-vendor/modem/props.conf as ro.boot.cdt_hwid=... and
# persist.vendor.modem.cdt_hwid=... (per-phone, never in the repo).

# M3.4.1 read-only: the six partitions against the backup, ro=1, nothing mounted
tools/phone-ssh 'for p in efs efs_backup modem_userdata persist modem_a modem_b; do
  d=$(grep -lx "PARTNAME=$p" /sys/class/block/*/uevent | head -1 | cut -d/ -f5);
  echo "$(sha256sum < /dev/$d | cut -d" " -f1)  $p.img ro=$(cat /sys/class/block/$d/ro)"; done' > logs/m3.4-before.sha256
grep -E ' (efs|efs_backup|modem_userdata|persist|modem_a|modem_b)\.img$' \
  ~/android/reference/cheetah-modem-nv-backup-20261012-1402/SHA256SUMS | sort -k2 |
  diff - <(sed 's/ ro=.*//' logs/m3.4-before.sha256 | sort -k2); grep -c 'ro=1' logs/m3.4-before.sha256
#   pass: no diff; 5 (persist is the one writable partition, and the profile never sees it)
#   stop: any mismatch: a stock boot changed NV; take a fresh read-only backup first (AGENTS)

# M3.4.2 boot with the CPIF overlay (as M3.3-B.1; asks the human: reboots), then load, link enabled
ov gnss-pmic-test gnss-test aoc-boot-test modem-cpif-test && bin/omandroid push
tools/phone-ssh dmesg -w | tee logs/m3.4-kmsg.log        # second terminal, until the end
tools/phone-ssh 'modprobe pcie-gs201-cp allow_hw=1; modprobe shm_ipc; modprobe cpif trace_lines=1;
  cat /sys/module/cpif/parameters/allow_poweroff; cat /sys/devices/platform/cpif/modem_state;
  /usr/lib/omandroid-vendor/omandroid-vendor-chroot modem check; dmesg | grep -c ufshcd_err_handler'
#   pass: as M3.3-B.2-B.4 but "steps enabled"; allow_poweroff N; modem_state OFFLINE;
#   "check" ends with "preconditions met"; record the err_handler count

# M3.4.3 rfsd only (no modem power): the RAM copies and the chroot
tools/phone-ssh 'systemd-run --unit=omandroid-modem-rfsd -E OMANDROID_MODEM_STAGE=rfsd \
  /usr/lib/omandroid-vendor/omandroid-vendor-chroot modem start; sleep 20;
  journalctl -u omandroid-modem-rfsd --no-pager | tail -20; cat /sys/devices/platform/cpif/modem_state'
#   pass: "modem_a: RAM copy matches the backup" and the same for efs, efs_backup, modem_userdata,
#   persist; "starting rfsd"; "running"; rfsd opens umts_rfs0 and waits; modem_state OFFLINE;
#   no "no /chosen/..." warning (record it if there is one); AP2CP lines still low
#   stop: "differs from the backup": the profile stops by itself before rfsd; take a fresh backup
tools/phone-ssh 'systemctl stop omandroid-modem-rfsd; losetup -l; grep -c modem-nv /proc/mounts'
#   pass: no loop devices left from the profile, no modem-nv mount (the namespace took them)

# M3.4.4 cbd: the modem powers on and boots (announce: the modem starts; it stays on)
tools/phone-ssh 'systemd-run --unit=omandroid-modem /usr/lib/omandroid-vendor/omandroid-vendor-chroot modem start'
#   watch the kmsg terminal; expect, in this order (about 10-30 s):
#   - "IOCTL_POWER_ON", the traced power-on edges (pm-wrst, pwr-on, nreset, cp-wrst = 1);
#   - "link up: Gen1 x1", "secure ATU SMC: 0x0", the bus scan with 0001:01:00.0 144d:a5a5,
#     then the s51xx probe: "db_addr : 0x14e60000 , val : 0x14e00000, offset : 0x60000",
#     the doorbell mapped inside the bridge window, 4 MSI vectors;
#   - cbd's boot steps (its log in kmsg and in journalctl -u omandroid-modem), the boot stage
#     changing in CPIF's log, a link_down and "link up: Gen3 x2" for the main firmware;
#   - CPIF "ONLINE" / modem_state ONLINE.
tools/phone-ssh 'cat /sys/devices/platform/cpif/modem_state; cat /sys/devices/platform/cpif/power_stats;
  journalctl -u omandroid-modem --no-pager | tail -40; dmesg | grep -c ufshcd_err_handler;
  cat /sys/kernel/debug/gs201-pcie-cp/status | grep -E "LTSSM|faults"'
#   pass: modem_state ONLINE; rfsd logs NV file requests (names only); "faults: 0x0";
#   the err_handler count as in M3.4.2 (power-on and a running link were clean in M2.5)
#   record: the Gen/width of the main link, the time from POWER_ON to ONLINE, cbd's last lines

# M3.4.5 leave it on; M3.5: the real partitions unchanged (read-only)
tools/phone-ssh 'sleep 120; cat /sys/devices/platform/cpif/modem_state; dmesg | grep -cE "link down|completion timeout";
  dmesg | grep -c ufshcd_err_handler'
#   pass: still ONLINE; 0 link faults (CPIF may cycle the link when the modem idles: record any
#   link_down/link up pairs and the UFS count around them); err_handler count unchanged
#   then repeat the M3.4.1 checksum commands into logs/m3.4-after.sha256 and diff: pass, no change
```

**Stop** (record, then `reboot-to omandroid`, which powers the modem off
through CPIF's shutdown: expect one UFS handler pass):
- an Oops, a panic line, the watchdog;
- "doorbell ... outside the bridge window" (the s51xx probe refused: the
  bus has no memory window; send the log);
- `modem_state` CRASH_EXIT or CRASH_RESET, or cbd starting a dump: let
  cbd finish the dump (it lands in the chroot's `/data/vendor/ssrdump`
  under `/var/lib/omandroid-vendor/modem`), then stop. Don't let it retry
  in a loop: a crash reset is a power cycle;
- no ONLINE 60 s after "link up: Gen1";
- repeated "link down" or "completion timeout" events;
- UFS beyond recovered handler passes (I/O error, resets, aborts), or any
  handler pass while the modem is up and not changing power;
- a checksum change in M3.5 (stop all modem work; NV was written).

**Rollback:** reboot (above). For a boot without CPIF: images without
`modem-cpif-test` (`cp "$D.default" "$D"; bin/omandroid images && bin/omandroid push`).
The RAM copies vanish with the profile; nothing persistent changed
except `/var/lib/omandroid-vendor/modem` (the chroot's /data: logs, dumps).

**Hand-over to M4** (`device/cheetah/MODEM-CLIENT.md`, section 4): with
M3.4.5 passed and the modem left ONLINE in the `omandroid-modem` unit,
start at M4.0 (install `omandroid-modem-sit`, enable nothing), then M4.1
and M4.2, whose precondition is exactly this state: the modem profile
running and CP ONLINE. Keep the M3.4 kmsg stream; M4 checks the
`ufshcd_err_handler` count after each step the same way.

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
7. Does the S5300 firmware boot and serve IPC/RFS with the packet
   processor absent on the AP side (`pktproc_*` left out of the CPIF node,
   AP capabilities 0)? Stock negotiates capabilities at boot
   (`capability_offset`); if the firmware insists, the packet processor
   (`link_rx_pktproc.c`, `link_tx_pktproc.c`, ~2.8k lines) is the next port
   stage, with `use_exclusive_irq` off (3.3).
