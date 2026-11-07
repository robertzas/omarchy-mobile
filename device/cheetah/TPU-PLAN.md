<!-- SPDX-License-Identifier: MIT -->
# TPU / NPU plan: the Edge TPU (Abrolhos / Janeiro) on cheetah (gs201)

Status (2026-11-06): **T2.2-T2.5d, T3's ACPM shim, T4's first firmware load
and T5's device query passed on the phone.** The SysMMU at 1cc40000 is bound
as `samsung-sysmmu`; the TPU platform device, the IOMMU group and the
`janeiro` driver all probe; the vendor ACPM TPU power states now go through our
ACPM protocol (DVFS domain 7, channel 0). The GSA loaded the signed
`edgetpu-janeiro.fw`, and `/dev/janeiro` reports firmware 1.0 (KCI 3, VII 2);
the TPU powers up and down per wakelock with the AoC, UFS, PCIe and storage
unaffected. T6 (one inference) is next: the stock runtime is now identified
(`libedgetpu_util.so` in the vendor image, which opens `/dev/edgetpu`), but it
is a bionic vendor library and no client has run against this kernel yet; the
open Coral runtime is USB-only and cannot drive this device.**
The DT now carries the TPU and SysMMU v8 nodes (both disabled), and the SysMMU
v8 driver builds as `samsung_iommu.ko` with its group module. Google's GPL
gs201 janeiro driver is in the `omamobile-tpu` worktree and builds as
`janeiro.ko` against Linux 7.3-rc6 with `CONFIG_JANEIRO=m`; `W=1` is clean and
`modinfo` names `google/edgetpu-janeiro.fw`. T2.2 loaded the SysMMU module
(`samsung_iommu`) and its driver bound as `samsung-sysmmu`; `janeiro` stayed
blacklisted and unloaded. Our GSA driver now carries the TPU
firmware-management interface (`include/linux/gsa/gsa_tpu.h`,
`gsa_load_tpu_fw_image()`, `gsa_send_tpu_cmd()`, `gsa_unload_tpu_fw_image()`). The SysMMU v8 binding passes
`dt_binding_check`, and the T5 query client `tools/tpu-info` is written.
Written against `omamobile` (Linux
7.3-rc6), Google's GPL gs201 tree (`android-gs-pantah-6.1`) and the stock
build `cheetah-cp2a.260705.006`. Kernel branch `omamobile-tpu`, worktree
`~/omamobile-kernel/wt-tpu`, output `~/omamobile-kernel/out-tpu`.

Goal: run one real int8 model on the phone's Edge TPU from Linux, then make it
usable as a normal accelerator (a TFLite delegate or a small runtime), with
thermal and power limits, without touching the radio, calibration data or
Trusty's persistent state.

Non-goals: training; Android's NNAPI inside Waydroid; the camera pipeline's GXP
DSP (a different block, not a general-purpose NPU); secure-world firmware
changes; Google Play services.

---

## 0. Autonomy grant for this plan (owner, 2026-11-07)

The owner's standing grant (AGENTS.md §1.1, 2026-11-07) applies to this plan:
the slot-B development loop runs **unattended, without a per-step question**.
For this plan that means: builds in `wt-tpu`/`out-tpu`, `bin/omamobile push`
(slot-B images plus its `reboot-to`), `bin/omamobile flash` of the suffixed
slot-B images only, `reboot-to`, `systemctl poweroff` (then wait for the
human to press Power — a physical action, not a question), `insmod`/`rmmod`
of the TPU development modules (`samsung_iommu`, `janeiro`), the test clients
(`tools/tpu-test`, `tools/tpu-info`, `tools/edgetpu-run.c`, `/root/tpu-raw.sh`,
`/root/tpu-hal.sh`), and boots of the overlay-carrying images. A one-line
notice in this plan or the log still precedes anything that affects the screen
or the feel of the phone.

Still the human's explicit go, per step (permanent-brick / irreplaceable-data
class, AGENTS.md §1.1): any write to bootloader, radio, `devinfo`, `persist`,
`efs*`, `modem*` or `vbmeta`; any unsuffixed `fastboot flash`; `userdata` writes
outside `tools/install-phone`; weakening the storage guard; enabling/resetting
the modem NV overlay; PMU register access or reads of unpowered blocks;
booting stock on slot A; `tools/install-phone`; `omamobile-boot-update
write|rollback`; release/publish machinery. The safety nets (log stream,
`--watchdog`, USB deadman, hang marker), one change per boot, and the one-TPU-
run-per-cold-boot rule are unchanged.

Path abbreviations used below:

- `L/` = our kernel, branch `omamobile-tpu` (`~/omamobile-kernel/wt-tpu`)
- `G/` = Google's GPL gs201 tree (`android-gs-pantah-6.1`, the kernel and
  `private/google-modules/` as checked out for the GPU and AoC work)
- `J/` = `kernel/google-modules/edgetpu/janeiro` on
  `android.googlesource.com` (the gs201 chip configuration and driver)
- `E/` = `kernel/google-modules/edgetpu` on its `android-gs-raviole-mainline`
  branch (the shared Abrolhos driver, useful as the gs101 reference)
- `R/` = `~/android/reference/cheetah-stock-cp2a-root` (stock live DT, dmesg,
  `/proc/iomem`, `/proc/interrupts`)
- `S/` = the user's own factory image and, later, a vendor chroot built from it
  (never committed)
- `C/` = `google-coral/libedgetpu` (Apache-2.0; the archived Coral runtime)

---

## 1. The short version

1. **Do not start by reverse engineering the kernel driver.** Google's gs201
   TPU driver is published under GPL-2.0, in full, as
   `kernel/google-modules/edgetpu/janeiro` (the gs201 chip) plus the shared
   `abrolhos` driver code. The stock kernel module is a build of that source.
   Reverse engineering it would recover what is already readable, with worse
   provenance.
2. **The driver is not the hard part. Its platform is.** The TPU firmware is
   loaded and authenticated through the **GSA** (`gsa_load_tpu_fw_image`,
   `gsa_send_tpu_cmd`), its DMA goes through a **SysMMU v8** instance
   (`samsung,sysmmu-v8`, `0x1CC40000`), and its power/clock state is driven
   through **ACPM's TPU domain** (domain 7) rather than a Linux clock or genpd.
   Our tree has no SysMMU v8 driver, no vendor ACPM TPU state API and, as far
   as we know, no GSA TPU interface. Those are the real work.
3. **The userspace is the closed part.** The stock Android runtime
   (`libedgetpu.so`, `libedgetpu_client.google`, the Darwinn NNAPI HAL and the
   Edge TPU services) is proprietary. The open Coral `libedgetpu` supports USB
   and PCIe Coral devices, not the integrated Abrolhos/Janeiro device. We need
   either a minimal client against the driver's ioctl ABI, or the stock
   runtime in a vendor chroot for validation.
4. **The compiler is an open question.** `edgetpu_compiler` (x86-64) compiles
   TFLite models for Coral Edge TPUs. Whether its output runs on gs201's
   firmware has not been checked. If it does not, the compiler/runtime format
   is where reverse engineering (REA) actually earns its keep.
5. **Recommended order:** T0 stock facts, T1 offline driver port, T2 DT +
   SysMMU v8, T3 ACPM + GSA, T4 first firmware load, T5 device info, T6 one
   inference. Do not enable anything at boot before T6, and do not start with
   REA.
6. **If the actual need is "run ML faster today", the TPU is not the shortest
   path.** CPU XNNPACK, the Mali-G710 through Mesa, or an external Coral USB
   TPU are shorter projects. The internal TPU is worth it for int8 inference
   at low power, but budget months, not days.

### 1.1 What "working" means

| Milestone | Result | Gate |
| --- | --- | --- |
| M0 | The stock TPU facts are captured read-only: DT node, IRQs, IOMMU, power domain, carveouts, firmware, runtime libraries | T0 |
| M1 | The driver builds, the DT nodes exist, the SysMMU v8 probes, and the module loads without binding | T1-T2 |
| M2 | The GSA loads the user's `edgetpu-janeiro.fw`; the TPU boots; `/dev/edgetpu` and the `edgetpu` class appear | T3-T4 |
| M3 | A userspace query returns the firmware/KCI version and device info | T5 |
| M4 | One real int8 model runs, with output matching the CPU reference | T6 |
| M5 | A TFLite delegate (or our runtime) runs a normal model repeatably; thermal and power are measured | T7 |
| M6 | The module is on by default behind a package, survives suspend and 20 power cycles, and has a documented thermal cap | T8-T9 |

---

## 2. What the phone has

### 2.1 Block facts

| Item | Value | Evidence |
| --- | --- | --- |
| Block | Google Edge TPU, 4 TOPS class, intended for int8 CNN inference | Google's public Tensor G2 material; the "4 TOPS" figure is marketing, not a measured number [I] |
| SoC name | gs201, Tensor G2; the TPU driver family is **Abrolhos**, the gs201 chip configuration is **Janeiro** | `J/`; `device/google/gs201/device.mk` sets `edgetpu_config,chip=janeiro` and packages `edgetpu-janeiro.fw` [V] |
| DT node | `/soc@0/janeiro@1CE00000`, `compatible = "google,darwinn"` | `G/devices/google/gs201/dts/gs201-tpu.dtsi` [V] |
| CSR window | `0x1CE00000`, size `0x200000` (2 MiB), `reg-names = "tpu"` | same [V] |
| DMA window | `<0x18000000 0xE7FFF000>`; the comment says the TPU uses regions under `0x18000000` for special purpose | same [V] |
| IRQs | Eight level-high mailbox IRQs, `TPU2AP_NS_TPU_0` through `_7` | same; the numbers are macros in `dt-bindings/interrupt-controller/gs201.h` [V] |
| IOMMU | `sysmmu@1CC40000`, `samsung,sysmmu-v8`, `0x10000` bytes, NS and secure IRQs, `secure_base 0x1CC50000`, `port-name "TPU"`, `sysmmu,no-s2pf` | `G/devices/google/gs201/dts/gs201-sysmmu.dtsi` [V] |
| S2MPU | `s2mpus = <&s2mpu_tpu>` on the TPU SysMMU | same [V] |
| Power domain | `pd_tpu@18062900`, `cal_id = 0xB1380018`, `need_smc = 0x1CC10204`, `cmu_id = 0x1CC00000`, top-level, `status = "okay"` | `G/devices/google/gs201/dts/gs201-pm-domains.dtsi` [V] |
| CMU | CMU_TPU at `0x1CC00000`; BCL's fast-path registers are at `+0x830..0x844` | `G/devices/google/gs201/dts/gs201-pm-domains.dtsi`; `CPUFREQ-PLAN.md` §12.1-12.2 [V] |
| ACPM DVFS | Domain 7 = TPU; ECT levels 1150 ... 226 MHz, boot level 226 MHz | `device/cheetah/ACPM-PLAN.md` §2, from the phone's ECT [V] |
| Stock DVFS table | 1066, 967, 845, 712, 627, 455, 226 MHz, with average power 4420, 4101, 2578, 1982, 1749, 1277, 0 mW | `gs201-tpu.dtsi` `tpu_dvfs_table` [V] |
| Thermal | TMU id 5 = TPU; ACPM TMU channel 9; the TPU zone is critical at 110 °C (record its passive trips at T0) | `CPUFREQ-PLAN.md` §1; `R/dmesg.txt`; our `tpu-thermal` zone already exists (C1, 2026-10-31) [V] |
| Rail | S2MPG12 `B10M` (TPU buck) with its `OCP_WARN` pin on `gpp19-1`; `L13M_VDD_TPU_M` is the TPU memory LDO | `CPUFREQ-PLAN.md` §12.1; `docs/review/LESSONS.md` C-4 [V] |
| Firmware | A signed mobile image, packaged on stock as `edgetpu-janeiro.fw`; the driver requests `google/edgetpu-<chip>.fw` by default | `J/`; `device/google/gs201/device.mk`; `drivers/edgetpu/edgetpu-config.h` [V] |
| Firmware loading | Through the GSA, not by writing TPU registers from the AP: `gsa_load_tpu_fw_image()`, `gsa_unload_tpu_fw_image()`, `gsa_send_tpu_cmd(GSA_TPU_SHUTDOWN)` | `J/drivers/edgetpu/abrolhos-platform.c`, `abrolhos-pm.c` [V] |
| Firmware header | 4 KiB mobile header; signed header at `0x400`, image configuration at `0x560`; contains `carveout_base`, `firmware_base`, `firmware_size` and the firmware versions | `J/drivers/edgetpu/mobile-firmware.h` [V] |
| Reserved memory | Two regions, `tpu_fw_reserved` and `tpu_fw_ctx_reserved`; the first must be at least `EDGETPU_FW_SIZE_MAX + EDGETPU_REMAPPED_DATA_SIZE` | `gs201-tpu.dtsi`; `abrolhos-platform.c` [V] |
| Device interface | `/dev/edgetpu`, an `edgetpu` class, and a debugfs directory; stock may also expose `/dev/janeiro` (record it at T0) | `J/`; `device/google/gs201` init change [V/I] |
| Userspace | Stock `libedgetpu.so`, `libedgetpu_client.google`, `libedgetpu_util`, `vendor.google.edgetpu@1.0-service`, `vendor.google.edgetpu_app_service@1.0-service`, `android.hardware.neuralnetworks@service-darwinn-aidl`, the Edge TPU logging service and the DBA service | `device/google/gs-common/edgetpu/edgetpu.mk`; `device/google/gs201/device.mk` [V] |
| Open userspace | Coral `libedgetpu` is Apache-2.0 but its backends are USB and gasket/PCIe; the tree has no integrated Abrolhos/Janeiro backend | `C/driver/` listing (the repository is archived) [V; re-check at T0] |
| Upstream Linux | No Google Edge TPU driver in mainline. `drivers/accel/` has no edgetpu; `drivers/staging/gasket` is the Coral PCIe device, not this one | upstream 7.3-rc6 tree [V] |

### 2.2 Address space and carveouts

```
0x18000000  +--------------------------+  <- TPU DMA window base
            |  TPU's own DMA space      |     (dma-window = 0xE7FFF000 bytes)
            |  shared with nothing else |
0x1CC00000  +--------------------------+  <- CMU_TPU
0x1CC10204  |  DTZPC_TPU (SMC target)   |
0x1CC20000  |  edgetpu,shareability     |
0x1CC40000  +--------------------------+  <- sysmmu_tpu (SysMMU v8)
0x1CC50000  |  SysMMU secure base       |
0x1CE00000  +--------------------------+  <- TPU CSR window (2 MiB)
...
higher DRAM +--------------------------+  <- tpu_fw_reserved, tpu_fw_ctx_reserved
            |  firmware + remapped data |     (exact addresses/sizes from R/)
```

The two carveouts are the only memory the TPU firmware owns. They must be
`no-map` and must not appear as System RAM in our kernel's `/proc/iomem`; the
repo has already been bitten by stock reserved regions that were plain RAM
(`AGENTS.md` §4). **Do not copy the gs101 addresses.** Upstream gs101's
firmware carveout is 16 MiB at `0x93000000`; gs201's live tree has its own
addresses and sizes, and the first region must also hold the remapped data the
driver maps with `memremap(..., MEMREMAP_WC)`.

### 2.3 Power, clocks, thermal

The TPU is unusual for us: **its DT node has no `clocks` and no
`power-domains`.** The vendor driver does not use the Linux clock framework or
a genpd. It asks ACPM for a TPU power state, and ACPM programs the domain,
CMU_TPU and the rails together. The `pd_tpu` node is for the vendor PM-domain
driver and the SysMMU; the TPU device itself is powered by ACPM.

Consequences:

- We do **not** need a CMU_TPU clock driver for first light. There is no
  `clk` consumer in the TPU driver.
- We do **not** need a gs201 genpd driver for first light if ACPM can power
  `pd_tpu` and ABL leaves it on. That is the same bet the GPU work made with
  G3D (`GPU-PLAN.md` G2): keep the domain on, do not claim runtime power-off.
- The SysMMU's `power-domains = <&pd_tpu>` is a problem if the gs201 genpd
  provider does not exist: a consumer with an unresolved `power-domains`
  defers forever. For first light, **omit `power-domains` from our SysMMU
  node** and keep the domain on through ACPM/ABL; add the real PD provider in
  T9 for runtime power-off. Do not point it at a provider that cannot do the
  SMC/DTZPC/CMU save-restore.
- The ACPM TPU domain is **not** the generic `clk-acpm` kHz path. Google's
  driver passes TPU power-state values (`TPU_OFF`, `TPU_DEEP_SLEEP_CLOCKS_SLOW`,
  `TPU_ACTIVE_NOM`, ...) and uses `TPU_DEBUG_REQ | TPU_CLK_*_DEBUG` for
  individual clock reads/writes. Port the vendor TPU ACPM ops, or add a shim
  that maps the state machine to rates; do not blindly wire it to
  `clk_acpm`'s rate API. The DT's `tpu_dvfs_table` is the OPP table ACPM uses.
- Thermal already exists: our `gs101-acpm-tmu` registers `tpu-thermal` on
  cheetah (C1 passed, 2026-10-31). Use it for readings and cooling. Do not
  register a second zone with the same name; port only the cooling device or
  trip points if the vendor thermal file needs them.

### 2.4 Interrupts and mailboxes

The DT lists eight level-high interrupts for the TPU's mailbox block. The
platform driver takes **IRQ index 0** as its main interrupt
(`platform_get_irq(pdev, 0)`); the mailbox layer is expected to use the others
for the VII mailboxes (the per-group command queues; confirm in the port). The
order in the DT is part of the
ABI; keep it exactly. There is no `interrupt-names` property in Google's DT;
do not invent one unless the ported driver asks for it.

### 2.5 IOMMU and S2MPU

The TPU's DMA goes through a SysMMU v8 instance at `0x1CC40000`, with a secure
alias at `0x1CC50000`, and an S2MPU (`s2mpu_tpu`) in front of it. The driver's
generic IOMMU glue (`edgetpu-google-iommu.c`) expects a default IOMMU domain
for the device:

- `edgetpu_mmu_attach()` fails (with `-EINVAL`) if
  `iommu_get_domain_for_dev()` returns no domain.
- The driver warns that AUX domains are not supported, so all groups share
  the default domain. That is fine for one client; multi-client isolation is a
  later problem.
- The mapping path uses the standard DMA/IOMMU API (`dma_map_sg`), so the
  IOMMU core must be able to allocate an IOVA and program the SysMMU. Without
  a v8 driver, probe stops here.

The S2MPU is the second gate. The SysMMU DT points at `s2mpu_tpu`, andthe driver looks for a separate `"ssmt"` register resource; if it is missing,
it warns "SSMT setup failed ... Context isolation not enforced" and continues. First light can run with the S2MPU as
ABL left it, but **a pass with that warning is not a security pass**. Do not
disable the S2MPU or write it from userspace; if the TPU faults, fix the
IOMMU/S2MPU programming, not the guard.

### 2.6 Firmware and the GSA

The AP does not copy the firmware into the TPU by itself. The flow is:

1. The driver maps the first carveout and hands the firmware image to the GSA
   (`gsa_load_tpu_fw_image`).
2. The GSA verifies the signed image and loads it into the TPU's carveout.
3. The driver powers the TPU domain through ACPM and starts the control core.
4. On shutdown it asks the firmware to power down, then sends
   `GSA_TPU_SHUTDOWN`; if the p-channel request fails, it restarts the firmware
   or resets the TPU through the GSA.

This means **the GSA is a hard dependency of the TPU**, just as it is for the
AoC. Our AoC stack already talks to the GSA through Trusty. The TPU command set
(`gsa_tpu.h`, `GSA_TPU_SHUTDOWN`, the firmware load/unload calls) was a
separate interface; T3 ported it offline into `drivers/soc/google/gsa.c`, and
it still has to be tested on the phone. The GSA is also shared
with the fingerprint stack; never restart Trusty or a storage proxy to recover
a TPU test. Reboot instead.

The firmware itself is Google's signed blob. It is not ours to redistribute.
`tools/extract-vendor-firmware` now copies the user's
`vendor/firmware/edgetpu-janeiro.fw` to
`/usr/lib/firmware/updates/google/edgetpu-janeiro.fw` (the path the driver
requests), from the user's own factory image, and never commits it. The copy
is optional in the tool (a missing file prints a note rather than failing the
extraction), because the exact stock path is still T0's to confirm; the stock
package is `edgetpu-janeiro.fw`, while the driver's default is
`"google/edgetpu-" DRIVER_NAME ".fw"`.

### 2.7 What stock does at boot (to be captured, not assumed)

We know the static DT and the driver source. We do **not** yet know, on this
phone:

- whether `pd_tpu` is on at ABL handoff, and what its status register reads;
- whether the TPU firmware is already loaded at boot or loaded on first use
  (the driver powers the device down at probe and loads on the first client);
- which GSA commands stock issues, and in what order;
- whether stock's S2MPU configuration lets the TPU DMA without a Linux
  S2MPU write;
- the exact carveout addresses/sizes, IRQ numbers, and firmware hash;
- what the stock runtime opens and which ioctls it uses.

T0 answers these read-only. Do not infer them from gs101 or from the driver
source alone.

---

## 3. Software inventory

### 3.1 Google's GPL driver

The driver is split in two layers:

| Layer | Files (representative) | What it does |
| --- | --- | --- |
| Framework (`edgetpu-*`) | `edgetpu-core.c`, `edgetpu-device-group.c`, `edgetpu-mapping.c`, `edgetpu-dmabuf.c`, `edgetpu-fs.c`, `edgetpu-kci.c`, `edgetpu-mailbox.c`, `edgetpu-pm.c`, `edgetpu-firmware.c`, `edgetpu-telemetry.c`, `edgetpu-sw-watchdog.c`, `edgetpu-usage-stats.c`, `edgetpu-debug-dump.c`, `edgetpu-iremap-pool.c` | The device model: char device, groups, buffers, DMA-BUF import/export, KCI, mailboxes, telemetry, watchdog, firmware state machine, power hooks, debugfs |
| Chip / platform (`abrolhos-*`) | `abrolhos-platform.c`, `abrolhos-pm.c`, `abrolhos-iommu.c`, `abrolhos-firmware.c`, `abrolhos-core.c`, `abrolhos-device.c`, `abrolhos-device-group.c`, `abrolhos-fs.c`, `abrolhos-thermal.c`, `abrolhos-wakelock.c`, `abrolhos-debug-dump.c`, `abrolhos-usage-stats.c`, `abrolhos/config.h`, `abrolhos/csrs.h`, `abrolhos/config-mailbox.h`, `abrolhos/config-tpu-cpu.h` | The gs201/gs101-specific resources: CSR map, GSA firmware load, ACPM power states, IOMMU attach, thermal, wakelocks, register tables |
| IOMMU glue | `edgetpu-google-iommu.c` | Standard IOMMU API: default domain, `dma_map_sg`, map/unmap, fault handler; no AUX domains |
| UAPI | `edgetpu.h` (the ioctl ABI) | Open/close, buffer alloc/map, group submit, mailboxes, telemetry, usage stats; the stock runtime carries its own copy of the same ABI |
| Build | `Kbuild`, `Kconfig`, `EDGETPU_FRAMEWORK`, `ABROLHOS` (or the janeiro chip option), `EDGETPU_TELEMETRY_TRACE` | A module; the stock build uses the janeiro chip configuration |

The exact gs201 source is the `janeiro` repository, not the `abrolhos` one:
`J/` has the gs201 chip configuration and the `android-gs-pantah-6.1-*`
branches. `E/` is the shared/generic reference used by gs101 and is useful for
reading the framework, but its chip config is not gs201's. At T1, diff the two
and take the gs201 chip files from `J/`.

### 3.2 What the driver needs from the kernel and our tree

| Dependency | Use in the driver | Status in our tree | Work |
| --- | --- | --- | --- |
| GSA TPU interface (`linux/gsa/gsa_tpu.h`, `gsa_load_tpu_fw_image`, `gsa_unload_tpu_fw_image`, `gsa_send_tpu_cmd`) | Firmware load/unload, shutdown, reset | **Ported offline** (2026-11-05): mailbox commands 50-52, the `hwmgr.tpu` Trusty service and the S2MPU/wakelock window in `drivers/soc/google/gsa.c` [V] | Test on the phone in T3/T4 |
| SysMMU v8 (`samsung,sysmmu-v8`) | Default IOMMU domain, `dma_map_sg`, map/unmap, faults | **Ported offline** (2026-11-05): Google's v8 driver (`samsung_iommu.ko`) and its binding; the probe is untested [V] | T2 runbook; S2MPU and multi-context later |
| S2MPU (`s2mpu_tpu`) | DMA protection for the TPU | The DT exists in Google's tree; our tree's S2MPU support is partial/used by other blocks [I] | First light with ABL's state; verify no faults; then program/retain it properly. Never weaken it |
| ACPM TPU domain | Power state, DVFS, clock debug | `clk-acpm` supports ACPM rates; Google's `exynos_acpm_set_rate`/`set_init_freq`/`set_policy` TPU state API is vendor-only [I] | Port the TPU state ops or add a shim; test `get_rate`/`set_rate` read-only first |
| `pd_tpu` genpd | Runtime power-off, CMU/DTZPC save/restore | Upstream `exynos-pm-domains.c` cannot do the SMC/DTZPC/CMU sequence; the GPU work has the same gap (`GPU-PLAN.md` §5, Gate G4) [V] | First light: omit `power-domains`, keep it on. Later: gs201 PD provider |
| BCL (`soc/google/bcl.h`) | `google_retrieve_bcl_handle`, TPU ratio, DVFS caps | No BCL driver ([CPUFREQ-PLAN](CPUFREQ-PLAN.md) §12) [V] | Omit/stub first (`CONFIG_GOOGLE_BCL=n`), port later if needed for max frequency |
| BTS (`soc/google/bts.h`) | `tpu_performance` scenario, bus bandwidth vote | Not present [I] | Stub (return -ENODEV) first; performance only |
| Exynos PM QoS (`exynos_pm_qos_*`) | INT/MIF minimum votes | May exist for other drivers [I] | Add the small API or stub; performance only |
| SSCOREDUMP (`linux/platform_data/sscoredump.h`) | Crash dump registration | Not in mainline [I] | Stub/disable first |
| DMA-BUF, `sync_file`, `genalloc`, `IOMMU_API` | Buffers, fences, remap pool | Mainline has all [V] | Port API churn |
| Thermal | `devm_tpu_thermal_create` | Our `tpu-thermal` zone exists (C1) [V] | Reuse the ACPM zone; do not register a duplicate |
| Debugfs, cdev, class | `/dev/edgetpu`, class, debugfs | Mainline has all [V] | Port API churn |
| `memremap`/carveout | Firmware and remapped data | Mainline [V] | Check the carveouts against `/proc/iomem`; declare them `no-map` |

### 3.3 Userspace: what is open, what is closed

| Component | License/status | Use for us |
| --- | --- | --- |
| Coral `libedgetpu` (`C/`) | Apache-2.0; archived 2025-10-14 | USB and gasket/PCIe backends; **no** integrated Abrolhos/Janeiro backend found in the tree [V, re-check]. Its `api/` and `driver/` are a good reference for the model/request model, not a drop-in runtime |
| Coral `edgetpu_compiler` | Proprietary, free download, x86-64 | Compiles TFLite models to the Edge TPU custom op on the laptop; compatibility with gs201 is unverified [I] |
| Stock `libedgetpu.so` | Proprietary, in `/vendor` | Fastest way to validate the kernel driver: run it in the vendor chroot with a tiny client; do not ship it |
| Stock `libedgetpu_client.google` | Proprietary | The HAL's client library; useful for ioctl tracing/RE, not for redistribution |
| Stock Darwinn NNAPI HAL / Edge TPU services | Proprietary | Not needed for a first inference if we drive the device directly; useful as a reference for the ABI |
| Google Tensor SDK / LiteRT dispatch | 2026-era, likely closed and Android/G3+ oriented [I] | Check whether it supports Tensor G2 and Linux before depending on it; do not make it a gate |

### 3.4 The compiler and model format

The Coral flow is: a TFLite model -> `edgetpu_compiler` -> a `.tflite` whose
graph contains an `edgetpu` custom op with a compiled package (instruction
bitstreams + metadata) -> the runtime loads the package, allocates buffers and
submits requests.

Open questions that T6/T7 must answer:

- Does the Coral compiler's package target the same Edge TPU generation as
  gs201's firmware? The Pixel 7 is "4 TOPS" like Coral, but the firmware and
  ISA versions may differ.
- Does the stock runtime verify a package signature that the Coral compiler
  does not produce? If yes, a clean-room runtime that ignores the signature
  may still work because the kernel/firmware do not verify the user package;
  confirm.
- Does the stock phone ship a compiler or only precompiled models? Check
  `/vendor/bin`, `/vendor/lib64` and the HAL strings at T0.

If the Coral package is incompatible, the options are: use the stock runtime
in a chroot with a stock-compiled model; find a stock compiler; or reverse the
package format/compiler behavior with REA. Do not start with the last one.

### 3.5 Upstream status and prior art

- Mainline has no Google Edge TPU driver. The GPL vendor driver depends on
  `soc/google` hooks (GSA, BCL, BTS, PM QoS, SSCOREDUMP) and would need a
  cleanup before it could be proposed. Do not plan on upstreaming it.
- The open Coral runtime is for USB/PCIe Coral devices; it is not an
  integrated-TPU runtime. Its archived state means it will not gain gs201
  support upstream.
- The only complete gs201 implementation is Google's GPL tree plus the stock
  userspace. That is the reference.

---

## 4. Architecture

```
Userspace
  stock libedgetpu / our client / TFLite delegate
        |  open("/dev/edgetpu"), ioctl(...)
        v
Kernel: abrolhos driver
  edgetpu-fs        -> cdev, class, debugfs
  edgetpu-mapping   -> dma-buf import/export, IOMMU map/unmap
  edgetpu-device-group -> groups, VII mailboxes, KCI
  edgetpu-kci       -> command/response queues, firmware control
  edgetpu-pm        -> power up/down, firmware run/restart
  edgetpu-firmware  -> request_firmware("google/edgetpu-janeiro.fw")
        |                         |
        | MMIO (2 MiB CSR)        | GSA mailbox
        v                         v
  TPU CSRs / mailboxes       GSA (Trusty)
        |                         |  verify + load signed image
        |                         v
        |                    tpu_fw_reserved (carveout)
        v
  TPU core (Janeiro)  <--- ACPM: pd_tpu, CMU_TPU, rails, DVFS
        |
        | DMA (IOVA in 0x18000000..)
        v
  sysmmu_tpu (SysMMU v8) -> s2mpu_tpu -> DRAM
```

The request path for an inference is roughly:

1. Userspace opens `/dev/edgetpu`, joins/creates a device group, and maps its
   input/output buffers (DMA-BUF or the driver's allocation ioctls).
2. The runtime uploads the compiled package and the instruction buffers; KCI
   tells the firmware to run.
3. The TPU DMAs the input, executes the bitstream, writes the output, and
   signals completion through a mailbox/eventfd or a fence.
4. The driver's IOMMU mapping confines the TPU to the buffers it was given.

The first version only needs steps 1, 3 and 4 for a single client; the
multi-group, multi-context and P2P paths can stay unused.

---

## 5. Strategy and decisions

### 5.1 Source first, RE second

| Part | Status | What to do |
| --- | --- | --- |
| Kernel TPU driver | GPL-2.0, public | Read and port it; no RE |
| GSA TPU interface | GPL-2.0, public | Read and port it; no RE |
| SysMMU v8 | GPL-2.0, public | Read and port it; no RE |
| TPU firmware | Proprietary signed blob | Load it as-is; no patch, no RE unless a command is unexplained |
| Stock userspace (`libedgetpu`, HAL, services) | Proprietary | Trace it (`strace`), then REA only for the specific ioctl/ABI questions |
| Compiled model format | Mixed (Coral schema is open; stock packages may be signed) | Start with the Coral compiler; RE only if it is rejected |
| Compiler | Proprietary | Use it on the laptop; do not try to port it to the phone |

This is the most important decision in the plan. The user's REA suggestion is
right for the closed userspace, but starting with REA on the kernel module
would waste weeks re-deriving GPL source.

### 5.2 In-tree or external module?

Recommendation: **in-tree on `omamobile-tpu`**, as a module
(`CONFIG_EDGETPU_FRAMEWORK=m`, `CONFIG_ABROLHOS=m` or the janeiro option).
Reasons:

- `bin/omamobile kernel` builds and packages modules from the kernel tree;
  an out-of-tree module would need a separate build, install and `depmod`
  path, and the TPU depends on in-tree GSA/IOMMU/ACPM changes anyway.
- The repo already carries ported Google drivers in-tree (AoC, modem); this
  matches the convention.
- It keeps `kernel-pr-check --build` and `W=1` meaningful.

Do not copy the driver into `drivers/staging/` or claim it is upstreamable.
Keep the Google `SPDX` headers and attribution; add a `README` in the driver
directory that names the source branch and the local changes.

### 5.3 What to port for first light vs later

**First light (T1-T6):**

- Framework: core, device group, mapping, KCI, mailboxes, PM, firmware,
  telemetry (optional), fs, wakelock, usage stats (optional), debug dump
  (optional).
- Chip: platform, PM, IOMMU attach, firmware, core, device, fs, thermal
  (reuse the ACPM zone), config/CSR tables.
- GSA: firmware load/unload/shutdown.
- IOMMU: SysMMU v8, default domain, map/unmap, fault reporting.
- ACPM: TPU state get/set, initial power state.
- DT: TPU node, SysMMU node, two carveouts, GSA phandle, 8 IRQs, DMA window.
- Userspace: one query client and one inference path.

**Strip or stub for first light:**

- BCL (`CONFIG_GOOGLE_BCL=n`): no TPU ratio/DVFS cap.
- BTS (`bts_*`): return `-ENODEV`; no bus scenario vote.
- Exynos PM QoS: return success; no INT/MIF vote.
- SSCOREDUMP: do not register the platform device.
- Multi-device (MCP), P2P, USR links: compile out.
- `EDGETPU_TELEMETRY_TRACE`: can stay on; it only adds buffers.
- Firmware tracing/telemetry: on, but do not depend on it.
- `devm_tpu_thermal_create`: adapt to the existing `tpu-thermal` zone; do not
  register a second zone.

**Later (T7-T9):**

- BCL for max frequency and brownout caps.
- BTS and PM QoS for full throughput.
- A real gs201 `pd_tpu` genpd with SMC/DTZPC/CMU save-restore for runtime
  power-off.
- S2MPU programming/verification and multi-context IOMMU domains.
- Suspend/resume and runtime PM.
- Multi-client isolation and error recovery.
- Upstream cleanup, if ever.

### 5.4 API churn (5.10/6.1 -> 7.3)

The driver was written against Android 5.10/6.1. Expect to fix, at minimum:

- `class_create()` arguments and `device_create()`/`device_destroy()`.
- `platform_driver.remove` returning `void` (6.11+).
- `dma_buf` ops: `attach`/`detach`/`map_dma_buf`/`unmap_dma_buf` signatures,
  dynamic import/export, `dma_resv` locking, `MODULE_IMPORT_NS("DMA_BUF")`
  (string namespace since 6.13).
- `mmap` locking: `mmap_read_lock`/`mmap_write_lock`, `vma->vm_flags`,
  `vmf_insert_pfn`/`remap_pfn_range` return types.
- `pin_user_pages`/`unpin_user_pages`, FOLL_* flags, `get_user_pages` removal.
- `iommu_map`/`iommu_map_sg`/`iommu_unmap` return types and page-size calls;
  `iommu_fault_handler`/`iommu_register_device_fault_handler` changes;
  `IOMMU_PBHA_PROT` is a vendor macro — remove or map it.
- `eventfd_signal` (one argument in 6.8+), `fdget`/`fdput`.
- `debugfs_create_*` constness and return values; `debugfs_remove_recursive`.
- `thermal_zone_device_register`/`devm_thermal_of_zone_register` changes;
  `thermal_cooling_device_register` changes.
- `timer_setup`, `del_timer_sync`, workqueue APIs.
- `device_property_read_*`, `of_parse_phandle` refcounts.
- `dma_alloc_attrs`/`dma_free_attrs`, `dma_set_mask_and_coherent`,
  `dma_map_sg_attrs` return type.
- `sg_alloc_table`/`sg_free_table`, `scatterlist` helpers.
- `platform_get_irq` return handling; `request_threaded_irq` flags.
- `PM` callbacks and `pm_runtime_*` semantics.
- `MODULE_FIRMWARE` path; `firmware_request_nowarn` vs `request_firmware`.

Build with `W=1`, `make dtbs_check` and `tools/kernel-pr-check --build` after
each batch. Do not add `-Wno-*` suppressions; fix the API use. The port is
large enough that a mechanical "make it compile" pass followed by a semantic
review is expected; keep the two in separate commits so a bisect can tell them
apart.

### 5.5 DT strategy

- Base `gs201.dtsi`: add `sysmmu_tpu`, `tpu`, and the two reserved-memory
  nodes with `status = "disabled"` (the reserved-memory nodes are always
  reserved, but the devices stay disabled).
- `device/cheetah/overlays/tpu-test.dtso`: enable `&sysmmu_tpu` only, for
  T2.2. `tpu-enable.dtso`: enable `&sysmmu_tpu` and `&edgetpu`, for T2.3 and
  T4. Both are applied by `bin/omamobile images`; neither is in
  `device.conf`'s `DTB_OVERLAYS` until T8.
- Add the `sysmmu_group` node (`samsung,sysmmu-group`) and the
  `samsung,iommu-group = <&sysmmu_group>` phandle on `edgetpu`: the vendor
  SysMMU driver's `device_group` requires it, and T2.3 logged
  `group is not registered` without it. Do not add `clocks` or `power-domains`
  to the TPU node, and do not add `s2mpus` yet.
- Keep `dma-window`, `#dma-address-cells`, `#dma-size-cells`,
  `edgetpu,shareability`, `gsa-device`, `memory-region`, and the
  `tpu_dvfs_table`/`tpu_dvfs_table_size` properties: the driver reads them.
- Check every carveout against `/proc/iomem` on our kernel before enabling the
  node. A carveout that is System RAM in our tree is a bug, not a detail.
- The TPU node name (`janeiro@1CE00000`) is stock's; the driver matches the
  compatible, not the name. Keep the stock name for diffability.

### 5.6 Userspace strategy

| Option | What | Pros | Cons | When |
| --- | --- | --- | --- | --- |
| U0 | Stock `libedgetpu_util.so` + the vendor service/client in a bionic chroot | Fastest validation of the kernel; uses Google's tested runtime | Proprietary; Android/bionic dependencies; not shippable; the runtime only has the `DarwinnApi2_*` C API | T6 first attempt |
| U1 | Clean-room minimal client against `edgetpu.h` | Open; small; exactly what we need to test the driver; shippable as a tool | Needs the UAPI and a compatible compiled model; no delegate | T5-T6 |
| U2 | Fork/port the open Coral runtime with an Abrolhos backend | Open; reusable; a real delegate | The open runtime has no integrated backend; its driver model is Darwinn 1.x; months | After T6 |
| U3 | Google Tensor SDK / LiteRT dispatch | If it supports G2 and Linux, the best app path | Likely Android-only/closed/G3+; unverified | Check at T0; do not gate |
| U4 | External Coral USB / GPU / CPU | Works today (with caveats) | Not the internal TPU; USB host/role limits; GPU needs a compute stack | Fallback for real work now |

Recommended: **U0 to prove the kernel, U1 to own the ABI, U2 only if the
project needs a general runtime.** Do not ship U0.

For U0, the chroot needs the vendor linker, `libc++`, `libbase`, `liblog`,
`libcutils`, `libutils`, `libbinder_ndk` (if the HAL is used) and the
`/vendor/lib64` libraries the runtime links. The fingerprint and GNSS work
already show how to run vendor binaries against the vendor linker
(`FINGERPRINT-PLAN.md`, `GNSS-PLAN.md`). The TPU runtime may also need
`/dev/dma_heap` or `ion`; the driver's own allocation ioctls avoid gralloc, but
check. If the stock lib insists on the NNAPI HAL, start the HAL service in the
chroot first; if that needs binder service registration, it is a bigger
chroot job than a simple client.

For U1, the first ioctls are the device-info and the buffer/queue setup. The
exact names and structs are in `J/drivers/edgetpu/edgetpu.h`; do not invent
them. The tool must be root-only initially (the device node is `0600` or
`0660` with a `tpu` group), and it must not map arbitrary physical memory.

### 5.7 Power and thermal policy

- Start at the boot state (226 MHz) and the stock table's low levels. Do not
  jump to 1066 MHz.
- Cap at 627 or 712 MHz until the `tpu-thermal` zone has a cooling device and
  a measured sustained limit. Stock's table says 1066 MHz averages 4.4 W,
  which is a lot for a phone; the thermal path is not optional.
- Use ACPM for every rate/state change. Never write CMU_TPU PLL/mux registers
  directly; the voltage would not follow.
- If BCL is not ported, do not use the top OPP; the brownout/overcurrent caps
  are part of stock's safety envelope.
- Measure with `power-ab` off the cable and with the `tpu-thermal` zone; record
  the kernel release and the model.

### 5.8 Security and DMA

- Keep the IOMMU attached for every TPU mapping. Do not add `dma-coherent`,
  do not bypass the IOMMU, and do not give the TPU a physical address that is
  not mapped.
- Treat "SSMT setup failed ... Context isolation not enforced" as a warning
  that blocks any claim of isolation. The first goal is functionality; the
  second is the S2MPU.
- The device node is root-only until a `tpu` group and udev rule exist. A
  world-writable TPU node would let any local process submit work and read
  DMA buffers.
- Do not load the TPU firmware while the fingerprint stack is in the middle of
  a session, and never restart Trusty/storageproxyd. If a TPU test wedges the
  GSA, reboot; do not try to recover in place.
- No persistent TPU state is written by Linux; the only persistent data is the
  stock firmware file on disk. A failed test costs a reboot, not data.

### 5.9 Licensing

- The driver and GSA code are GPL-2.0; keep the notices and the source
  provenance in the commit messages and a `README` in the driver directory.
- The firmware is Google's; do not commit, mirror or redistribute it. Extract
  it from the user's own factory image at install/provision time.
- The stock runtime is proprietary; do not commit it or decompiled output.
  A clean-room client written from the ABI facts is ours.
- `libedgetpu` is Apache-2.0; if we reuse code, keep its notices.
- `edgetpu_compiler` is proprietary; do not bundle it in the repo or the root
  image. The user runs it on the laptop.

---

## 6. Bring-up gates

Every gate follows the repo's rules: read-only first, one change per boot, a
log stream before a risky step, `--watchdog`, a stop condition, a rollback and
a risk level. The phone is shared; announce anything that can hang it. Since
2026-11-07 (section 0, AGENTS.md §1.1) reboots, `push` and `flash` of the
slot-B images run unattended; the permanent-brick class still needs the
human's go per step.

### T0: stock facts (read-only, no risk)

**Goal:** capture the live TPU facts from stock Android, before writing code.

**Do:**

```sh
# On the laptop, with the phone booted to stock Android on slot A (human's call).
mkdir -p ~/android/reference/cheetah-stock-tpu
adb shell 'uname -r'                       # one fact, not a dump
adb shell 'find /proc/device-tree -iname "*tpu*" -o -iname "*janeiro*"'
adb shell 'ls -l /sys/class/edgetpu /dev/edgetpu /dev/janeiro 2>/dev/null'
adb shell 'cat /proc/iomem | grep -i -E "tpu|janeiro"'
adb shell 'dmesg | grep -i -E "edgetpu|abrolhos|janeiro|tpu"' > ~/android/reference/cheetah-stock-tpu/dmesg-tpu.txt
adb shell 'cat /proc/interrupts | grep -i tpu'
adb shell 'find /vendor/firmware -maxdepth 2 -iname "*edgetpu*" -o -iname "*janeiro*"'
adb shell 'find /vendor/firmware -maxdepth 2 -iname "*edgetpu*" -exec sha256sum {} +'
adb shell 'ls -l /vendor/lib64 /vendor/bin | grep -i -E "edgetpu|darwinn"'
adb shell 'for z in /sys/class/thermal/thermal_zone*; do echo "$z $(cat $z/type) $(cat $z/temp)"; done | grep -i tpu'
adb shell 'cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -i tpu'
adb shell 'ls /sys/kernel/debug/iommu 2>/dev/null'
```

Also capture the live DT subtree, not a whole dmesg dump:

```sh
adb shell 'find /proc/device-tree -iname "*janeiro*" -o -iname "*tpu*"' | while read p; do
  echo "== $p"; adb shell "ls $p; for f in $p/*; do echo -n \"$f=\"; od -An -tx1 \"$f\" | tr -d \"\n\"; echo; done"
done > ~/android/reference/cheetah-stock-tpu/live-dt-tpu.txt
```

Check for identifiers before keeping or sharing anything. The captures are
private (`~/android/reference/`), never committed.

**Expect/Pass:** the live node matches Google's GPL `gs201-tpu.dtsi` (address,
8 IRQs, two memory regions, GSA phandle); the firmware file exists and its
sha256 is recorded; `/dev/edgetpu` exists when the stock TPU stack is up;
the `tpu-thermal` zone is present; `pd_tpu` status and ACPM rate are recorded.

**Stop:** anything needs a write, a reboot or `adb root`; ask the human first.
Do not run `getprop` dumps or paste them.

**Rollback:** none (read-only).

**Risk:** none, apart from booting stock (which writes `efs`/`persist`; take a
fresh NV backup afterwards per `AGENTS.md` §1).

**Time:** 0.5-1 day.

### T1: offline port (no phone)

**Goal:** build the gs201 driver and its dependencies in our tree, with the DT
node disabled, and prove the build is clean.

**Do:**

1. Branch `omamobile-tpu` from `omamobile`; worktree
   `~/omamobile-kernel/wt-tpu`, output `~/omamobile-kernel/out-tpu`.
2. Import `J/drivers/edgetpu/` into `L/drivers/edgetpu/` with its `Kconfig`,
   `Kbuild`, `Makefile` and `SPDX` headers. Keep the janeiro chip files.
3. Keep the test config in `out-tpu/.config` (`CONFIG_EDGETPU_FRAMEWORK=m`,
   `CONFIG_JANEIRO=m`). Do not add it to `kernel/configs/omamobile.config`
   until the driver is on the published `omamobile` branch: the release
   fragment must not name a symbol the release tree does not carry. When the
   module is packaged, blacklist `janeiro` (not `abrolhos`) in
   `/etc/modprobe.d/omamobile-tpu.conf`, so a boot with the new DTB cannot
   autoload it.
4. Port the API churn (§5.4). Stub BCL/BTS/PM QoS/SSCOREDUMP. Make the GSA
   TPU calls compile behind a small `tpu_gsa_*` shim that returns
   `-EOPNOTSUPP` until T3.
5. Build the test config directly (`make ARCH=arm64 LLVM=1 O=out-tpu
   drivers/edgetpu/janeiro.ko`); `W=1`; `checkpatch` on the files we write.
   `tools/kernel-pr-check --build` applies once this is a commit or PR.
6. `modinfo` the module; confirm the firmware name and the module dependencies.

**Expect/Pass:** the kernel and module build; `modinfo janeiro` shows
`google/edgetpu-janeiro.fw`; no unresolved vendor symbols; `dt-validate` is
clean for the unchanged DTB; the module loads on a running phone only when
explicitly requested, and no device binds because the DT node is disabled.

**Stop:** the port needs a core API that does not exist and cannot be shimmed;
document the exact symbol and stop. Do not hack around the IOMMU/PM core.

**Rollback:** drop the branch/worktree; no phone changes.

**Risk:** none (build only).

**Time:** 1-2 weeks.

**Result (2026-11-05): passed offline.**

- Source: `J/` at `android-gs-pantah-6.1-android16`, commit `ae39d75`; the
  driver is in `L/drivers/edgetpu/`, with the in-tree hooks in
  `drivers/Kconfig` and `drivers/Makefile`.
- Build: `CONFIG_EDGETPU_FRAMEWORK=m`, `CONFIG_JANEIRO=m`, Android clang
  22.0.2 (`clang-r596125`); `make ARCH=arm64 LLVM=1 O=out-tpu W=1
  drivers/edgetpu/janeiro.ko` completes with 0 warnings. The kernel release is
  `7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`.
- Artifact: `janeiro.ko`, 3.7 MiB, aarch64; `modinfo` reports
  `google/edgetpu-janeiro.fw`, `of:N*T*Cgoogle,darwinn`, empty `depends`; no
  unresolved vendor symbols (`gsa*`, `bts*`, `bcl*`, `exynos_pm_qos*`,
  `acpm*`, the TMU pause hook). `checkpatch --file` on the new stub: 0 errors,
  0 warnings.
- API churn ported: platform remove is `void`; the thermal cooling register
  takes the id; `fd_file()` instead of `struct fd.file`; `noop_llseek`;
  `vmalloc.h`; `eventfd_signal(ctx)`; `dma_fence` lock helpers and the void
  `dma_fence_signal_locked`; `MODULE_IMPORT_NS("DMA_BUF")`; the domain fault
  handler via `iommu_set_fault_handler`; `GFP_KERNEL` on `iommu_map*`;
  `iommu_paging_domain_alloc()`; a NULL attach handle for the PASID attach;
  `vzalloc`/`vfree` headers.
- Stubs: BCL off with a local `bcl.h`; BTS and PM QoS use their inline
  no-ops; the GSA fallback's load/unload/send and the ACPM setters return
  `-EOPNOTSUPP` (ACPM `get_rate` stays 0, no error channel); the vendor TMU
  pause hook is a no-op in `edgetpu-vendor-stubs.c`.
- Not touched: no DT changes, so `dt-validate` is not applicable; no phone
  write, reboot, module load or firmware copy. The test config is only
  `out-tpu/.config`; `kernel/configs/omamobile.config` and the package
  blacklist are unchanged until the driver is on the published branch.

### T2: DT + SysMMU v8 (build, then a careful boot)

**Goal:** the TPU and its SysMMU exist in our DT, the v8 driver probes, and the
kernel boots with the devices disabled (or the SysMMU enabled but the TPU
disabled).

**Do:**

1. Add the two reserved-memory nodes from T0 (`no-map`), the `sysmmu_tpu`
   node, and the `tpu` node with the stock properties. Start with
   `status = "disabled"` on both.
2. Port the SysMMU v8 driver from `G/` (`samsung,sysmmu-v8`) into
   `L/drivers/iommu/samsung/` with its binding. If the full driver is too
   large, implement the minimal single-instance path: probe, one-level page
   table, `map_pages`/`unmap_pages`, `iotlb_sync`, NS fault IRQ, no S2PF,
   secure IRQ masked. Do not pretend to support the other v8 instances.
3. The first boot: no overlay, TPU disabled, SysMMU disabled. Confirm the
   kernel boots and nothing changed.
4. The second boot: `tpu-test.dtso` enables the SysMMU only. Confirm it probes
   without touching TPU registers; record `dmesg`, `ls /sys/bus/platform/...`,
   `/sys/kernel/debug/iommu`.
5. The third boot: enable the TPU node too, but keep the driver blacklisted.
   Confirm no register access happens (the driver is not loaded).

**Expect/Pass:** `dt-validate`/`dtbs_check` clean for the new nodes; the
SysMMU probe logs a domain/group; the TPU platform device exists; no SError,
no hang, no UFS/PCIe regression.

**Stop:** any hang or SError on the SysMMU boot; any change in UFS/PCIe/AoC
behavior; a carveout that is System RAM. Roll back the overlay and reboot.

**Rollback:** images without `tpu-test.dtso`/`tpu-enable.dtso`; the base DTB
keeps the nodes disabled.

**Risk:** medium-high. The SysMMU is a new register block; a read of an
unpowered block can abort the SoC. Arm the watchdog and stream `dmesg` first.

**Time:** 2-4 weeks.

**Result (2026-11-05): offline port passed; no phone step has run.**

- DT (`L/arch/arm64/boot/dts/exynos/google/gs201.dtsi`): labels on the
  existing `tpu-ctx@91e00000` and `tpu-fw@93000000` reserved-memory nodes; a
  `tpu-cooling` node; a disabled `sysmmu_tpu: sysmmu@1cc40000` with the stock
  register window, IRQs, QoS, secure base and TLB properties; and a disabled
  `edgetpu: janeiro@1ce00000` with the stock regs, eight IRQs, `dma-window`,
  `memory-region`, GSA and DVFS table. For first light both nodes omit
  `power-domains`, `s2mpus` and `samsung,iommu-group`: the TPU power domain is
  T3 work and pKVM is not running. The `soc@0` bus is 1 address/1 size cell,
  so the regs are `<0x1cc40000 0x10000>` and `<0x1ce00000 0x200000
  0x1ccf0000 0x10000>`; the first build's 2-cell regs produced a
  `reg_format` warning.
- Boot values are stock: SysMMU `qos = <15>`, `secure_base 0x1cc50000`,
  `sysmmu,no-s2pf`, `sysmmu,async-fault`, `sysmmu,default_tlb` and three TLB
  property entries; TPU `dma-window <0x18000000 0xe7fff000>`,
  `edgetpu,shareability 0x1cc20000`, `gsa-device = <&gsa>` and the seven-row
  DVFS table.
- Overlays: `device/cheetah/overlays/tpu-test.dtso` enables only
  `&sysmmu_tpu`; `tpu-enable.dtso` enables the TPU too for T2.3/T4, with
  janeiro still blacklisted. The overlay compiles, and its two fragments
  target the base DTB's `sysmmu_tpu` and `edgetpu` labels; the base DTB keeps
  both nodes `disabled`. `fdtoverlay` is not installed on this host, so the
  apply itself was checked by decompiling both DTBs, not by merging them.
- Validation: `make ... dtbs` builds `gs201-cheetah.dtb` with no dtc or `checkpatch --strict` warning.
  Applied to the base DTB with `fdtoverlay`; the applied tree has the SysMMU
  `status = "okay"` and the TPU `status = "disabled"`. `dt-validate` against a
  DTB built from the same tree without the TPU changes: the only new messages
  are the byte-type artifact that every node's properties produce on this
  dtschema (2026.9), and the overlay adds no warning at all.
- Driver: Google's v8 driver from `G/drivers/iommu/` at `057ab18`
  (`samsung-iommu.c`, `samsung-iommu-fault.c`, `samsung-iommu-group.c`, `.h`)
  is in `L/drivers/iommu/` (not a `samsung/` subdirectory), with
  `CONFIG_SAMSUNG_IOMMU` and `CONFIG_SAMSUNG_IOMMU_GROUP` in
  `drivers/iommu/Kconfig` and the composite module in its `Makefile`.
- API port (6.1 -> 7.3): `domain_alloc_paging` instead of `domain_alloc`;
  `map_pages` (a loop over the existing map helper) and `unmap_pages` only;
  the `detach_dev`, `map`, `unmap`, `remove_dev_pasid` and per-device feature
  callbacks are gone, so detach is a static `IOMMU_DOMAIN_BLOCKED`
  release/blocked domain whose `attach_dev`/`set_dev_pasid` detach the old
  domain; `set_dev_pasid` takes the old domain; no `fwspec->ops` and no
  `iommu_fwspec_free`; `pgsize_bitmap` is set on the domain; `of_xlate` takes
  a const `of_phandle_args`; `iotlb_sync_map` returns int; the
  `iommu_get_domain_for_dev_pasid` getter is gone.
- Fault path: 7.3 has no interface for unrecoverable faults, so the IRQ
  thread logs and clears the fault and then applies the vendor
  `panic-action`: `panic()` when it is `GO_PANIC_ID` (1, the default) or the
  DPM policy stub otherwise. This is a behavior change to review at T3/T4:
  with a client attached, any unhandled SysMMU fault panics the phone unless
  the DT sets another `panic-action`.
- Stubs: `include/soc/google/debug-snapshot.h` (no-op DPM hook,
  `GO_PANIC_ID 1`) and `include/soc/google/pkvm-s2mpu.h`
  (`pkvm_s2mpu_of_link()` returns 0: no pKVM, the bootloader's S2MPUs
  stand). The `<linux/smc.h>` include is dropped; the secure SFR helpers
  compile out with `CONFIG_EXYNOS_CONTENT_PATH_PROTECTION=n`, which is how the
  test config runs.
- Build: `samsung_iommu.ko` (562 KiB) and `samsung-iommu-group.ko`
  (266 KiB), aarch64; `W=1` clean, `MODULE_DESCRIPTION` present, no vendor
  symbols undefined, `depends=` empty. `checkpatch --strict -f` on the
  driver: 0 errors; two `kzalloc_obj` warnings and two vendor checks
  (`BUG()` in the detach path, alignment) remain for the upstream series.
- Binding: `Documentation/devicetree/bindings/iommu/samsung,sysmmu-v8.yaml`
  is added with the driver (mainline's `samsung,sysmmu.yaml` is the old Exynos
  controller and does not describe v8). It passes `dt_binding_check`
  (dtschema 2026.9, 2026-11-05); the PR gate no longer misses it.
- Not done: no module load, no phone reboot, no image write, no
  `kernel/configs/omamobile.config` change, no packaging and no blacklist on
  the phone. PASID/VCR and secure IRQ paths are compiled but untested.

**Build and boot result (2026-11-06).** The full test kernel builds (`Image` 42
MiB, `Image.gz` 15 MiB), the module tarball has `janeiro.ko`,
`samsung_iommu.ko` and `samsung-iommu-group.ko`. The T2.2 image set has
`cheetah-overlaid.dtb` with `sysmmu@1cc40000 status = "okay"` and
`janeiro@1ce00000 status = "disabled"`; the T2.3 set has both `status =
"okay"`. The T2.4 set adds `sysmmu-group` and
`samsung,iommu-group = <&sysmmu_group>` on `edgetpu`; all three nodes are
`okay` after the overlay. The read-only base check passed on the phone (`tools/tpu-test
--expect none`). `devinfo` 3.19 is a verified layout; the mark was written
(slot B bytes `02 06`: active yes, successful yes, retry-count 2; backup in
`logs/devinfo-before-20261106T175530Z.bin`), and the T2.2 images were pushed
and booted. Both block devices were read-only again after the mark. The T2.3 images
were then booted, followed by T2.4; see those results below.

**T2.2 result (2026-11-06, `7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`,
slot `_b`): passed.** `samsung-sysmmu 1cc40000.sysmmu: initialized IOMMU. Ver
8.1.0, no gate clock`; `samsung_iommu` and `samsung_iommu_group` are loaded;
`janeiro` is blacklisted and not loaded; `/dev/edgetpu` does not exist. The
SysMMU check first looked for a driver directory named `samsung-iommu`, but
the driver's name is `samsung-sysmmu` (module `samsung_iommu`), so the first
run was a false negative; after fixing `tools/tpu-check`, `tools/tpu-test
--expect sysmmu` passes. No SError, hang, UFS or PCIe error appeared. The
image push's host command hit its 300 s wrapper timeout after printing
"Rebooting into the new images"; the phone itself returned on the new kernel
and the check ran.

**T2.3 result (2026-11-06, same kernel, slot `_b`): passed the node gate,
with the T4 blocker in dmesg.** Both `/sys/bus/platform/devices/1cc40000.sysmmu`
and `1ce00000.janeiro` exist; the SysMMU is bound; `janeiro` is blacklisted
and not loaded; `/dev/edgetpu` is absent; no SError, hang, UFS or PCIe error;
`tools/tpu-test --expect nodes` passes. The push's own post-reboot wait
reported no SSH and exited 1, but the phone was up on slot B within 10 s and
`tools/phone-usb` passed; there was no slot A fallback. dmesg says:
`platform 1ce00000.janeiro: has sysmmu 1cc40000.sysmmu (total count:1)` and
`platform 1ce00000.janeiro: group is not registered`.
The IOMMU core cannot create the TPU's group because the DT lacks the
`samsung,iommu-group` phandle; a T4 `janeiro` attach would fail. T2.4 adds
the `sysmmu-group` node and the phandle, with `janeiro` still blacklisted.

**T2.4 result (2026-11-06, same kernel, slot `_b`): passed.** The
`soc@0:sysmmu-group` platform device is bound to the `sysmmu-group` driver;
`samsung_iommu` has one user; dmesg no longer says `group is not registered`;
`janeiro` is blacklisted and unloaded; `/dev/edgetpu` is absent; no SError,
hang, UFS or PCIe error. `tools/tpu-test --expect group` passes. The phone
stayed on slot B; the push's own post-reboot SSH wait again exited 1, but the
phone returned within 10 s. T4 (the janeiro module and signed firmware) is
next.

**T2.5d result (2026-11-06, same kernel, slot `_b`): passed.** This is the
first boot with the TPU SysMMU driver and its group as modules rather than
disabled nodes: `samsung_iommu` and `samsung_iommu_group` are loaded,
`1cc40000.sysmmu` is bound to `samsung-sysmmu`, the `sysmmu-group` device is
bound, `janeiro` is blacklisted and unloaded, and `/dev/edgetpu` is absent.
dmesg records `samsung-sysmmu 1cc40000.sysmmu: initialized IOMMU. Ver 8.1.0,
no gate clock` and the TPU platform device's IOMMU attachment; no SError,
hang, UFS or PCIe error appears. `tools/tpu-test --expect group` passes. The
push wrote and verified all five slot-B images. Its host-side post-reboot wait
timed out because a second USB phone (a OnePlus 8T at 172.16.42.1) had taken
the host's default route; the Pixel was up on slot B, and `tools/phone-usb`
then selected the Pixel by `USB_PRODUCT` and restored the 172.16.42.3/32
route. The temporary `device/cheetah/kernel.config` supplies
`CONFIG_SAMSUNG_IOMMU=m`, `CONFIG_SAMSUNG_IOMMU_GROUP=m`,
`CONFIG_EDGETPU_FRAMEWORK=m` and `CONFIG_JANEIRO=m`; keep it until T4. T4 (the
janeiro module and signed firmware) is next.

**Test automation (2026-11-06).** `tools/phone-usb` finds the Pixel by
`USB_PRODUCT`, activates the `omamobile-pixel` NetworkManager profile with
172.16.42.3/32 and a /32 route to 172.16.42.1, and checks root SSH. It refuses
to pick another USB phone. `tools/tpu-check` is the on-phone read-only check;
`tools/tpu-test` wraps it, saves `logs/tpu/<UTC>/check.txt` and optionally
`info.txt`, and never pushes or reboots. Use `--expect none|sysmmu|nodes|group|device`;
the exit status is the gate. The build loop is:

```sh
KERNEL_DIR=~/omamobile-kernel/wt-tpu KERNEL_OUT=~/omamobile-kernel/out-tpu \
  bin/omamobile kernel
KERNEL_OUT=~/omamobile-kernel/out-tpu bin/omamobile modules
WORK=~/omamobile-kernel/work KERNEL_OUT=~/omamobile-kernel/out-tpu \
  bin/omamobile initramfs
# Extend DTB_OVERLAYS with tpu-test for T2.2 (tpu-enable for T2.3), then:
KERNEL_OUT=~/omamobile-kernel/out-tpu bin/omamobile images
```

`bin/omamobile push` and the reboot were explicit human-approved steps until
2026-11-07; under section 0 they now run unattended. T2.2 was the first boot
that read the SysMMU, and it passed. T2.3 passed the
node gate but logged the missing IOMMU group; T2.4 fixed it and passed the
group gate. The signed
`edgetpu-janeiro.fw` is still needed for T4; it is not on the phone, and
`PARTNAME=vendor_a` is not a GPT partition (Android's vendor is dynamic).
The CP41 URL returned 404. The stable CP2A factory image
(`cheetah-cp2a.260705.006`, 3,910,686,132 bytes, sha256
`23d564ad5d0db2d04fa4bbde43930c9b0f8e570a51e8090c8d37c71dc96a2c0c`) was
extracted with `debugfs`; its vendor image has no `edgetpu-janeiro.fw`.
The Android 14 full OTA (`cheetah-ota-up1a.231005.007-7b69c467.zip`,
2,375,185,484 bytes, sha256
`7b69c467532aa84f6d8353cb8671f370d5bce3008879c222b39240f2940f00c5`) was
unpacked with `payload-dumper-go`: its `vendor.img` is ext4 and carries
`firmware/google/edgetpu-janeiro.fw` (985,344 bytes, sha256
`145993a4e300c64d95f5d811008062f47c083f17ed649f5c046d44eb23160b21`), now
installed on the phone. Its `aoc.bin` is older than this kernel's AoC driver
("firmware and drivers are incompatible"), so the CP2A factory image is the
next source for a matching AoC firmware and the TPU image; its vendor path is
`firmware/google/edgetpu-janeiro.fw`, not the unprefixed path the first check
looked at. The phone's own `super` read started but was stopped after 77 MiB;
the factory image is the current path.

**Runbook (phone steps pre-authorized under section 0 since 2026-11-07; run
them with the safety nets, stop conditions and rollbacks below).**

T2.0 (read-only, laptop). Confirm the base DTB has both nodes disabled, and
that the phone has the janeiro blacklist before any boot that carries the new
DTB: `fdtget -ts out-tpu/arch/arm64/boot/dts/exynos/google/gs201-cheetah.dtb
/soc@0/sysmmu@1cc40000 status` (and the `janeiro` node) -> `disabled`;
`tools/phone-ssh 'cat /etc/modprobe.d/omamobile-tpu.conf'` -> `blacklist
janeiro`. Stop if either is missing: an autoloading janeiro would touch the
TPU. `tools/phone-usb` must pass, and `tools/tpu-test --expect none` must
pass on the base kernel.

T2.1 (medium). Boot the base DTB with no overlay, streaming `dmesg` to
`logs/` first and with the USB deadman armed. Expect `uname -r` as built; no
`samsung_iommu` or `janeiro` in `lsmod`; `dmesg | grep -iE
"sysmmu|SError|serror"` shows no new line; UFS, PCIe and AoC behave as
before. Stop on any SError, hang or UFS error; roll back by rebooting the same
(unchanged) images.

T2.2 (medium-high). Boot with `tpu-test.dtso` applied (SysMMU enabled, TPU
disabled, janeiro blacklisted), stream `dmesg` to `logs/` and arm the
watchdog. Run `tools/tpu-test --expect sysmmu` after the boot; it requires
the platform device, a bound `samsung-sysmmu` driver (module `samsung_iommu`),
no janeiro load and the blacklist. The module and group auto-loaded in the
T2.2 run; no manual load was needed. If the device is unbound, stop and ask
before a manual bind. Expect the probe to log the SysMMU, no SError, no fault
IRQ storm, and no change in UFS/PCIe/AoC. This probe reads `0x1cc40000` while the TPU power
domain is still off: if it aborts or hangs, stop and do not retry; the next
step is T3's ACPM domain. Stop on the first SError/hang. Rollback: reboot
without the overlay (the base DTB keeps both nodes disabled); no image
changes.

T2.3 (medium-high). Only after T2.2 passes: boot with `tpu-enable.dtso`
(`&sysmmu_tpu` and `&edgetpu` enabled) and the janeiro module still
blacklisted. Run `tools/tpu-test --expect nodes`; expect both platform
devices and nothing to bind; no TPU register is touched. The T2.3 run
logged `platform 1ce00000.janeiro: group is not registered`; that is the T4
blocker fixed by T2.4, not a node failure. Stop on any fault or hang; roll
back to the T2.2 overlay.

T2.4 (medium-high). Only after T2.3: add the `sysmmu_group` node
(`samsung,sysmmu-group`) and `samsung,iommu-group = <&sysmmu_group>` on
`edgetpu`; keep janeiro blacklisted. Build the T2.4 images and boot with
`tpu-enable.dtso`. Run `tools/tpu-test --expect group`; expect the group
driver bound, no `group is not registered`, no janeiro load and no TPU
register access. Stop on any fault or hang; roll back to the T2.3 images.

Record in this plan, for each step: the date, `uname -r`, the exact dmesg
lines, `/sys/kernel/debug/iommu` (if present), and any UFS/PCIe line.

### T3: ACPM + GSA groundwork (attended, high risk)

**Goal:** the TPU domain can be queried and the GSA TPU interface is present,
without loading the TPU firmware yet.

**Do:**

1. Read `pd_tpu` status through the PMU SMC (the `exynos-pmu` regmap, as
   `GPU-PLAN.md` §2.3); do **not** use `/dev/mem`. Read `0x18062904` one
   register per call.
2. Read the ACPM TPU state/rate (`exynos_acpm_get_rate(TPU_ACPM_DOMAIN, 0)`)
   and the `tpu-thermal` zone. Confirm the boot state is 226 MHz and the
   thermal zone reads.
3. Port the vendor ACPM TPU state ops (`set_rate`, `set_init_freq`,
   `set_policy`) or add a shim that maps the driver's state enum to our ACPM
   API. Do not wire it to `clk_acpm` blind.
4. Port the GSA TPU interface: the header, the firmware load/unload commands,
   `GSA_TPU_SHUTDOWN`, and the device lookup. Verify the GSA/Trusty stack is
   healthy before and after. Do not restart it; reboot if it is not.
5. Keep the TPU module blacklisted. No firmware load in this gate.

**Expect/Pass:** `pd_tpu` is on (or the SMC read says otherwise, recorded);
ACPM returns 226 MHz; `tpu-thermal` reads 30-65 °C; the GSA TPU calls compile
and a no-op/version query returns success; the AoC, fingerprint and modem are
unaffected.

**Stop:** any Trusty/GSA error, any storageproxyd/fingerprint error, a hang, or
a TPU thermal reading above 80 °C. Reboot; do not retry in the same boot.

**Rollback:** revert the GSA/ACPM patches; the TPU remains disabled; no
persistent state.

**Risk:** high. The GSA is shared with the AoC and fingerprint; the TPU power
state touches a new domain.

**Time:** 1-2 weeks.

**ACPM result (2026-11-06): passed on the phone.**

- The shim is `drivers/edgetpu/edgetpu-acpm.c`: it gets the `struct acpm_handle`
  from `devm_acpm_get_by_phandle()` (falling back to
  `of_find_compatible_node("google,gs201-acpm-ipc")` until the TPU node carries
  `samsung,acpm-ipc = <&acpm_ipc>`) and maps `exynos_acpm_set_rate`,
  `get_rate`, `set_init_freq` and `set_policy` onto `handle->ops->dvfs` with
  ACPM channel 0 and `TPU_ACPM_DOMAIN` (7) as the clk_id. Evidence for domain
  7: `include/dt-bindings/clock/google,gs201-acpm.h` numbers
  `GS201_CLK_ACPM_DVFS_TPU` 7 "as in the firmware messages", the stock
  `exynos_dm` node's `devfreq_tpu` has `cal_id = <ACPM_DVFS_TPU>`, and
  `janeiro/config-pwr-state.h` has `TPU_ACPM_DOMAIN 7`; `clk-acpm.c` uses
  channel 0 for DVFS. The vendor callers in `mobile-pm.c` and
  `janeiro-pm.c` are unchanged.
- The real blocker was `mobile-pm.h`'s local no-op `exynos_acpm_*` stubs,
  compiled in when `CONFIG_ACPM_DVFS` was off: the old module probed
  successfully without ever asking ACPM to power the TPU. The stubs are gone,
  the header declares the shim, and the module builds `edgetpu-acpm.o`.
- Probe now logs `Initial power state: 226000`, `Powering up`/`Powering down`
  and `TPU cmd 4 (Trusty): 0`; `/sys/kernel/debug/edgetpu/power/state` reads 0
  when idle. The nodes are `/dev/janeiro` (the default interface, named by
  `DRIVER_NAME "janeiro"`) and `/dev/edgetpu-soc`; there is no
  `/dev/edgetpu`. The platform device binds to the `edgetpu_platform` driver
  (`/sys/bus/platform/drivers/edgetpu_platform`), while the module, the
  firmware name and the interface use `janeiro`.
- Two warnings remain, neither fatal: `iommu_set_fault_handler` WARNs because
  the default domain carries `IOMMU_COOKIE_DMA_IOVA` (dma-iommu) and refuses a
  fault handler, so a TPU fault is not reported through the driver (the SysMMU
  still panics on an unrecoverable one); and the first power-up logged
  `Set LPM0 failed: -110` (the PSM0 status poll timed out) while the firmware
  load and handshake succeeded. Both need a follow-up before T8.
- Next: T6, one inference. The userspace is still the closed part; the plan's
  U0 path (stock `libedgetpu.so` in a vendor chroot with a small client) has
  not been tried against this driver yet.

**Result (2026-11-05): the GSA half is ported offline; no phone step has run.**

- `include/linux/gsa/gsa_tpu.h` is the real interface now (Google's
  GPL-2.0-only header): the `enum gsa_tpu_state`/`enum gsa_tpu_cmd` values and
  the three calls, with `-EOPNOTSUPP` inline stubs when `CONFIG_GOOGLE_GSA` is
  off. The driver's own fallback header in
  `drivers/edgetpu/include/linux/gsa/` is deleted, so `janeiro.ko` binds to
  our GSA driver instead of a stub and `modinfo` lists it in `depends`.
- `drivers/soc/google/gsa.c`: mailbox commands 50 (`LOAD_TPU_FW_IMG`), 51
  (`TPU_CMD`) and 52 (`UNLOAD_TPU_FW_IMG`) from Google's `gsa_mbox.h`; the
  load shares the AoC path (GSA wakelock, the S2MPU CTRL0 window, the 10 s
  timeout). State and unload commands go to
  `com.android.trusty.gsa.hwmgr.tpu` through the same hwmgr protocol as the
  AoC; the per-service Trusty channel is now a parameter (`gsa_tz.port`,
  `tz` for the AoC, `tz_tpu` for the TPU) instead of a hardcoded AoC port.
  `tpu_cmd_mbox=1` tries the mailbox (commands 51/52) instead, for a phone
  A/B test without a rebuild.
- Build and checks: with `CONFIG_GOOGLE_GSA=m` and
  `CONFIG_GOOGLE_GSA_TRUSTY=y` in `out-tpu/.config`, one `make ... modules`
  for `drivers/trusty/trusty-core.ko`, `trusty-virtio.ko`, `trusty-ipc.ko`,
  `gsa.ko` and `janeiro.ko` completes with `W=1` and no warning. `janeiro.ko`
  now has `depends=gsa` and undefined `gsa_load_tpu_fw_image`,
  `gsa_send_tpu_cmd` and `gsa_unload_tpu_fw_image` symbols instead of the
  inline stubs; `gsa.ko` exports the three TPU symbols and has
  `depends=trusty-ipc`. `checkpatch --strict` reports 0 errors on the `gsa.c`
  diff and the new header.
- Not done: the vendor ACPM TPU state ops (`exynos_acpm_set_rate`,
  `set_init_freq`, `set_policy`) are still T1's no-ops, so the driver cannot
  power the TPU domain; `pd_tpu` has not been read; the Trusty
  `hwmgr.tpu` service's presence is unverified; nothing has loaded the
  module, touched a TPU register or talked to the GSA's TPU service.
- Next offline step: the ACPM TPU state shim. Its shape is now known: our
  ACPM API is `acpm_dvfs_set_rate(handle, chan, id, rate)` and
  `acpm_dvfs_get_rate(handle, chan, id)` (`struct acpm_handle` from the ACPM
  node, plus a channel id), while the vendor API is global
  (`exynos_acpm_*`, domain 7, the TPU state values as the "rate"). The TPU
  node has no `acpm` phandle or channel, so T3.1/T3.2 must say which channel
  and cal-id the domain uses before the shim can be written; a guess here
  would send another domain's requests.

### T4: first firmware load and probe (attended, highest risk)

**Goal:** the GSA loads the user's firmware, the TPU boots, and the driver
creates `/dev/edgetpu` without a crash.

**Do:**

1. Install the firmware from the user's own image:
   `tools/extract-vendor-firmware` (extended for `edgetpu-janeiro.fw`) copies
   it to `/usr/lib/firmware/updates/google/edgetpu-janeiro.fw`; verify sha256
   against T0.
2. Stream `dmesg` to the laptop first, then `modprobe` the driver with the
   watchdog armed. Do not autoload.
3. Watch for: firmware request, GSA load, ACPM power-up, KCI version, TPU
   device name, `/dev/edgetpu`, `edgetpu` class, debugfs `edgetpu/`.
4. Read the firmware version and KCI version; compare with the stock dmesg
   from T0.

**Expect/Pass:** the driver logs "edgetpu initialized", the firmware and KCI
versions are sane, `/dev/edgetpu` and `/sys/class/edgetpu/` appear, no IOMMU
faults, no GSA/Trusty errors, the TPU thermal rises only when expected.

**Stop:** no SSH within 2 minutes; an SError; a firmware load/GSA error; a
trusty/storage error; the thermal zone above 80 °C. The watchdog resets the
phone; do not retry in the same boot.

**Rollback:** blacklist the module, remove the overlay, reboot. No persistent
TPU state.

**Risk:** highest. This is the first TPU register access, the first GSA TPU
command and the first ACPM TPU power-up in one step. If it is too much, split
it: GSA no-op first, then ACPM state, then the probe.

**Time:** 3-7 days.

**T4/T5 result (2026-11-06, `7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`,
slot `_b`): passed.**

- `modprobe janeiro` under a deadman probes the platform device and creates
  `/dev/janeiro`; `tools/tpu-info --device /dev/janeiro --load` then acquires
  the wakelock, which powers the TPU through the ACPM shim and loads the
  firmware through the GSA, queries it and releases the wakelock.
- dmesg on the first load: `edgetpu janeiro: Powering up`;
  `google-gsa: TPU cmd 0 (Trusty): 0`; `google-gsa: cmd 150: answer
  0x80000096 err 0 argc 0`; `google-gsa: loading TPU image: header
  0x82e43000 body 0x93000000`; `google-gsa: cmd 50: answer 0x80000032 err 0
  argc 0`; `google-gsa: cmd 151: answer 0x80000097 err 0 argc 0`;
  `google-gsa: TPU cmd 1 (Trusty): 2`; `edgetpu janeiro: loaded prod firmware
  (1.0 895567958)`; then `Powering down` on the release.
- The query returned `firmware: 1.0 (KCI 3, VII 2)` and `dram: 0 bytes
  allocated, 0 bytes available`; `power/state` read 0 after the release,
  `tpu-thermal` 39-40 °C, `omamobile-aoc` stayed active, and dmesg had no
  SError, UFS or PCIe error. The module installed for the run has sha256
  `6ff0d62e92ed806aaf330c76b3d8c636edd258009ee0c046e0cab9e279ed4ccb`
  (3,960,504 bytes, unstripped).
- The driver needs `O_RDWR` even for the read-only version query (its ioctl
  permission check requires `FMODE_WRITE`), and opening alone does not load
  firmware: the first power get does, hence `--load`. One load per boot.
- Firmware: `google/edgetpu-janeiro.fw` from the CP2A factory image, sha256
  `52c1cccdf0e243d12fbc9f3b3911fe9c780a11d9a5bfda61744c7c3fdaded7c3`
  (1,038,272 bytes), installed under
  `/usr/lib/firmware/updates/google/`.

### T5: device interface query (attended)

**Goal:** a userspace program opens `/dev/edgetpu` and queries the device.

**Do:**

1. `tools/tpu-info` (Python 3, standard library only, so the phone runs it
   with `python3 -`) opens `/dev/edgetpu` read-only and runs
   `EDGETPU_FIRMWARE_VERSION` (27) and `EDGETPU_GET_DRAM_USAGE` (29); it
   prints the firmware/KCI/VII versions and the device DRAM figures. The
   ioctl numbers and structs are written out from the driver's GPL-2.0 ABI;
   it does not link the kernel tree.
2. Run it as root while streaming `dmesg`; no loops, one query per boot.

**Expect/Pass:** the values match the driver log; the tool exits cleanly;
no kernel warnings.

**Stop:** any ioctl hang or firmware crash; reboot.

**Rollback:** remove the tool; the driver stays blacklisted.

**Risk:** medium.

**Time:** 3-5 days.

**Result (2026-11-05): the client is written offline; it ran on 2026-11-06
(see the T4/T5 result above).**

- `tools/tpu-info` is Python 3 with the standard library only (the phone has
  python3; `tools/phone-ssh 'python3 -' < tools/tpu-info` runs it without an
  install). Its two ioctl numbers match C's `_IOR` for the same structs
  (`0x8010ed1b`, `0x8010ed1d`). It does not map buffers or submit work.
- Two things the phone taught: the node must be opened `O_RDWR` (the driver
  refuses every ioctl on a read-only file, even the version query), and the
  firmware load is not triggered by the open but by the first power get, so
  `--load` acquires `EDGETPU_ACQUIRE_WAKE_LOCK` first and releases it after.
  `/dev/edgetpu` does not exist; the interface is `/dev/janeiro`.
- `tools/tpu-check --expect device` accepts either node name.

### T6: one inference (attended)

**Goal:** one real int8 model produces correct output on the TPU.

**Do:**

1. Start from an already compiled model: the Coral test data's
   `mobilenet_v1_1.0_224_quant_edgetpu.tflite` (4,749,998 bytes) avoids the
   compiler for the first run. The stock compiler is also on the vendor image
   (`libedgetpu_tflite_compiler.so`, `CompileTfliteFlatbuffer2`), so a model
   can be compiled on the phone later.
2. Run the stock runtime (U0). The open Coral `libedgetpu` cannot drive this
   device: the feranick arm64 build (16.0) links only `libusb` and has no
   gasket/Janeiro backend. The vendor image's `libedgetpu_util.so` is the
   Jainero TFLite runtime and opens `/dev/edgetpu`; `/dev/janeiro` is the same
   device under the driver's name, so add a `/dev/edgetpu` udev symlink first.
   Use the stock runtime only for validation; do not ship it.
3. Compare the output with the CPU TFLite reference (same input, tolerance
   for int8 quantization). Record latency and the TPU temperature.
4. If the stock lib rejects the Coral-compiled package, record the exact
   error; do not patch the firmware. That is the signal to test a
   stock-compiled model or start the RE work.

**Expect/Pass:** output matches the CPU reference within tolerance; no
firmware crash; latency and temperature recorded; repeat 10 times.

**Stop:** wrong output at the first run, a firmware crash, an IOMMU fault, or
a hang. Reboot; do not loop.

**Rollback:** stop the client; unload the module; reboot if the GSA/Trusty is
unhappy.

**Risk:** medium-high.

**Time:** 1-2 weeks.

**Runtime inventory (2026-11-06).** From the Android 14 OTA's `vendor.img`
(`out/android14-ota/extracted/vendor.img`), for the chroot:

| File | Size | Notes |
| --- | --- | --- |
| `lib64/libedgetpu_util.so` | 3,400,592 | the Jainero TFLite runtime: opens `/dev/edgetpu`, exports `DarwinnApi2_*`; needs only `liblog`, `libdl`, `libc`, `libm` |
| `lib64/libedgetpu_tflite_compiler.so` | 55,305,184 | `CompileTfliteFlatbuffer2`, `LibEdgetpuTfliteCompilerFree`; self-contained |
| `lib64/libedgetpu_client.google.so` | 41,456 | binder client: `libbinder_ndk`, `libbase`, `libcutils`, `libutils`, `libc++`, the two `com.google.edgetpu_*` NDK libs |
| `lib64/libdarwinn_hal.so` | 49,768,952 | HAL runtime |
| `lib64/libdarwinn_dba_hal_runtime.so` | 3,785,000 | |
| `bin/hw/android.hardware.neuralnetworks@service-darwinn-aidl` | 817,752 | NNAPI HAL service |
| `bin/hw/vendor.google.edgetpu_vendor_service@1.0-service` | 33,808 | vendor service |
| `bin/hw/com.google.edgetpu.dba-service` | 86,120 | |
| `lib64/com.google.edgetpu_app_service-V2-ndk.so`, `com.google.edgetpu_vendor_service-V2-ndk.so` | 42,072 / 37,656 | binder interfaces |

The util lib exports no `TfLiteInterpreter*` symbols: the TFLite layer is
above it (the client/service), and its own API is the unversioned
`DarwinnApi2_*` family (`VirtualDevice_RegisterGraphByBuffer`, `Request_*`,
`BufferFactory_*`). So T6 is either the vendor service plus client in a
bionic chroot (U0) or a small client against `DarwinnApi2_*` whose signatures
have to be recovered from the library (U1). The chroot needs servicemanager
and the same bionic/runtime-APEX files as the GNSS profile;
`tools/extract-vendor-chroot` is the place for an `edgetpu` profile once the
file list is confirmed.

**U0 result (2026-11-06, `7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`):
reached the runtime's first VII command; the firmware rejects it because the
runtime never sends the setup command.** The client is `tools/edgetpu-run.c`, a
freestanding bionic binary that interposes `open`, `ioctl`, `mmap` and
`__system_property_get`, links `libedgetpu_util.so` and takes the driver
wakelock at `open` so the VII mailbox attaches at finalize. Working: the
runtime's own `DarwinnDelegate_GetDefaultDeviceSpec` returns `3 1 0 1` with one
path `/dev/edgetpu`; `CreateGroup` succeeds (the mailbox attr is `cmdq_kb 24
rspq_kb 12 cmd 48 rsp 24`, matching the driver's 48-byte VII command element);
the device group finalizes, both queues and the CSR mmap, the wakelock
succeeds and the firmware version reads back. Then the first VII command fails.

- Firmware, from dmesg: `ERR vii_handler_layer.cc:247 - Setup is not done yet
  received a command of type 0.` The runtime logs `Sync VII command failed:
  error_code=9` and returns status 13. The queue at that point reads `cq
  00000000 00000000 000b0000 00000000`, `rhead 0 rtail 1`: exactly one 48-byte
  command was submitted, and the firmware rejects it because its global
  scratches were never configured.
- gdb over SSH (attach to the stopped client; `/dev` bind-mounted into the
  chroot plus a `/dev/edgetpu` symlink) shows `VirtualDevice::CreateDriver` at
  `.so+0x13ad98` called twice from `DarwinnDelegate_CreateVirtualDevice3`, and
  its per-command firmware-setup path (the `Firmware setup failed for
  commands[%d]` message at `.so+0x67ce7`, setup function `+0x13be6c`, loop at
  `+0x13c1c0`) never runs. The prologue checks pass (`num_chips` 1,
  `chip_family` 0), so an early argument check is not what returns.
- Retrying `CreateDevice` in the same process does not help: the second attempt
  fails earlier (`Could not finalize device group … Connection timed out`) and
  the firmware stays unconfigured. One run per boot remains the rule.
- A second, separate blocker appeared on some boots: after `insmod`, the first
  power-up logs `Set LPM0 failed: -110` and then `firmware handshake failed:
  -110`, although the GSA reports `TPU cmd 1 (Trusty): 2` and the image load.
  The same module on other boots hands the firmware up. Reboot and retry; this
  is the T3 follow-up already noted above, not a regression of the client.
- Next: the vendor image carries `lib64/libdarwinn_hal.so` (49 MB),
  `lib64/libdarwinn_dba_hal_runtime.so` and
  `bin/hw/android.hardware.neuralnetworks@service-darwinn-aidl`, none of which
  the util runtime needs. Stock's VII setup command has to come from one of
  them (or from the util runtime's own service client above it), so the next
  step is to run the AIDL service path in the chroot and watch the same queue
  and dmesg, rather than guessing at the util runtime's skipped branch.

**U0 result, stock HAL path (2026-11-06, same kernel).** The vendor image is
plain ext4, so `debugfs` pulls files out without mounting it. Done:

- `libdarwinn_hal.so` and `libdarwinn_dba_hal_runtime.so` are in both chroots
  (the laptop tree and the phone's copy), and the client's `hal` mode dumps the
  HAL's function table: `GetDarwinnHalFunctions` returns a struct whose first
  word is version 4 and whose entries are function pointers at file offsets
  `0x831318`, `0x8314a4`, `0x8314c8`, `0x831614`, `0x831638`, … The AIDL
  service calls entry [1] with an out pointer (`+0x2764c`) and entry [3] with
  the service object (`+0x2768c`, out at `+0x10`). `libdarwinn_hal.so` carries
  the same `Firmware setup failed for commands[%d], cluster_id_bitset in hex:
  %x.` string as the util runtime, so it is the same code, not a second
  implementation.
- The kernel already has binder: `CONFIG_ANDROID_BINDER_IPC=y`,
  `CONFIG_ANDROID_BINDERFS=y`, `CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"`;
  `mount -t binder binder /dev/binderfs` creates `binder`, `hwbinder`,
  `vndbinder` and `binder-control` on the phone. No kernel work is needed for
  the binder half of the AIDL path.
- `android.hardware.neuralnetworks@service-darwinn-aidl` now execs in the
  chroot (its interpreter is `/system/bin/linker64`, not the bootstrap one) and
  stops at its first missing library, `libui.so`. The closure needs the system
  image: the chroot's `/system` is only the runtime-APEX pieces. `debugfs` on
  `vendor.img` has the NNAPI AIDL libs and `libprotobuf-cpp-full-21.7.so`, but
  `libui.so`, `libhardware.so` and `libnativewindow.so` are system libs.
- The original vendor driver tree (`~/omamobile-kernel/edgetpu-janeiro`) is
  file-for-file the same as the port apart from `gsa_tpu.h` and the port's own
  additions (`edgetpu-acpm.c`, the stub headers). So no kernel setup path was
  dropped in the port: the missing VII setup is userspace's.
- The util runtime's skip is now a single branch to explain: at
  `.so+0x13ae6c` `CreateDriver` calls `+0x1969e4`, and at `+0x13ae90`–`0x13aea0`
  it compares the returned vector's begin and end and jumps to `+0x13b314`
  when they are equal, before the setup loop. Either make that vector
  non-empty (find what fills it) or run the stock HAL service, which is the
  path that does the setup on Android.
- **Correction (2026-11-06, later gdb runs): the setup does run.** On a fresh
  boot, gdb shows `VirtualDevice::CreateDriver` calling `SetupFirmware`
  (`+0x13befc`, `x1=1`, `x2=0x100000000`) with one command
  (`SETUP LOOP index=0`). The memory-option filter (`+0x196a88`) returns two
  entries whose byte 6 is 0, so the `+0x13b314` "No memory option suitable for
  VII commands was found." path is not taken. The failure is inside the
  per-command call `+0x13c614`, which returns a non-OK StatusOr (the word the
  loop tests is an error-object pointer, not the OK value 1); the loop bails to
  `+0x13c2a0`, `firmware_setup_done_` at `+0x13c228` is never set, and the
  runtime's next VII command is then rejected with `Setup is not done yet`.
  Inside `+0x13c614` the scratch/option factory at `+0x143e80` returns OK and
  the VII send at `+0x1442a0` is entered with `type(w2)=11`, so the command is
  built and submitted.
- **The setup command reaches the queue and the firmware rejects its type
  (2026-11-06).** With the driver's VII IRQ dump extended to all 48 bytes of a
  command element, the element `SetupFirmware` wrote reads
  `00000000 00000000 000b0000 00000000 ffeff000 00000000 00000080` then zeros:
  seq 0, a `u16` 0 at byte 8, `u16` 11 at byte 10, and a small payload at byte
  16. The firmware still answers `Setup is not done yet … type 0` with response
  code 9. The driver has no VII submit ioctl: the runtime writes the command
  queue through its own mmap and rings the tail, so these bytes are exactly
  what the firmware reads. The remaining question is semantic rather than
  transport: either this firmware's setup type is not the value the runtime
  writes at byte 8, or the payload is not the flatbuffer it expects (the
  firmware carries the schema name `platforms::darwinn::vii::RequestAllocation`,
  and its own strings name the contract: "No global scratches were provided in
  setup command." and "Setup is already done, yet received another setup
  command.").  Next: dump the payload as bytes and compare the firmware build in
  `edgetpu-janeiro.fw` with the runtime's expected firmware version, to tell a
  version mismatch from a wrong command type.
- **The writer's layout is exact (2026-11-06).** The queue write is the virtual
  method at `+0x137888` (vtable `+0x18` of the queue object at `[dev+0xc8]`,
  found live with gdb). It builds the 48-byte element as: `+0 u64 seq`,
  `+8 u16 0`, `+10 u8 type` (the send's `w3`, 11 for the setup), `+11 u8 0`,
  `+12 u32 0`, `+16 u64 arg1` (`0xffeff000`), `+24 u64 arg2` (`0x80`),
  `+32 u64 0`, `+40 u32 0`, `+44..47` flags. The firmware's "type 0" is
  therefore a `u16` read at `+8`, where this writer put 0 — two bytes before the
  util runtime's type byte. Either the stock HAL writes the type at `+8` (and
  `libedgetpu_util.so` is not the path Android uses), or the firmware's reader
  is offset from the runtime's writer.  Next test: find the same writer in
  `libdarwinn_hal.so` by its `Cannot enqueue command after VII is shut down.`
  string and compare where it stores the type.
- **Both stock runtimes agree (2026-11-06).** The HAL's writer is at
  `libdarwinn_hal.so+0x25369f4` and builds the same header:
  `strh wzr,[sp,#0xb0]` (the u16 at `+8`) and `strb w26,[sp,#0xb2]` (the type at
  `+10`). A gdb run that patched the u16 at `+8` to 11 hit a *different*
  command (`+10` held `0x4f`, 79) and that boot failed the power-on, so the
  patch was inconclusive: the byte at `+10` is a per-command type, not a
  constant. The open question stays the same — the firmware reads a u16 at `+8`
  where both stock writers put 0 — and the way to settle it is the raw-queue
  experiment in `prompt.md`: write candidate elements ourselves, vary the `+8`
  and `+10` fields, and read the response code.
- **U1 result: the TPU power-state manager wedges across warm reboots
  (2026-11-06).** After the last run that reached finalize, every later boot
  failed the *first* power-up with `Set LPM0 failed: -110`, and the failure
  survives a reboot, so it is not the "one run per boot" budget. Measured on a
  live run (the driver's failure path now prints the registers):
  `PSM0_STATUS=0x5644c13`, `PSM1_STATUS=0xe893`, `LPM_CONTROL=0x1240`
  (PACTIVE, bit 6, set; bit 12, the shutdown-done bit `janeiro_lpm_down`
  waits for, also set). The AON block's registers (`AON_RESET`,
  `AON_CLOCK_ENABLE`, `AON_FORCE_QUIESCE`) and `POWER_CONTROL` read
  `0xdeadfeed`, the driver's value for a CSR janeiro does not implement, so
  they carry no information. Bit 7 of PSM0_STATUS, the one `janeiro_lpm_up`
  polls, never sets.
- What does *not* clear it: a module reload (probe powers down and back up),
  the debugfs `power/state` 0 → 226000 (`core_rate` reads back 226000, so ACPM
  accepts the state), leaving the block at state 0 for 4 s, and a GSA reset
  (`GSA_TPU_GET_STATE` 1 → `GSA_TPU_SHUTDOWN` + `gsa_unload_tpu_fw_image()` →
  state 0). GSA did report the stale image (state 1, LOADED, TPU in reset) that
  a warm reboot leaves behind; the driver now resets that at the start of every
  power-up, which removes one warm-boot failure mode but did not move PSM0.
- The trap that makes it permanent: `mobile_power_down()` returns `-EAGAIN`
  before it calls `mobile_pwr_state_set(TPU_OFF)` when the GSA CPU reset fails,
  so an interrupted or failed run leaves the TPU powered and the PSM in the bad
  state, and the next boot inherits it and fails the same way. Only a true
  power cycle (all rails off) resets the PSM; a warm `reboot-to` does not.
- The raw client is ready for the experiment (`tools/edgetpu-run.c`, `raw`
  mode): it takes the driver wakelock, creates and finalizes a group, mmaps
  CSR/command/response queues at `0x1800000`/`0x1900000`/`0x1A00000`, and
  submits 16 candidate 48-byte elements varying the `u16` at `+8`, with the
  type byte at `+10` = 11 and arg1 `0xffeff000`, arg2 `0x80`, printing the
  24-byte response and the CSR words for each. `/root/tpu-raw.sh` on the phone
  runs the whole post-boot sequence and must be the first TPU access of a boot.

### T7: a normal model and a delegate (attended)

**Goal:** a usable inference path, not just a test.

**Do:**

1. Run MobileNet/SSD through the stock delegate or our runtime; measure
   latency, throughput and power; compare CPU/GPU.
2. Package the userspace as `omamobile-tpu` (library, `tpu-info`, udev rule,
   firmware extraction hook, docs). Add it to `ROOTFS_PACKAGES` only when it
   is ready.
3. Add a `tpu` group and a `0660` device node; no world-writable device.

**Expect/Pass:** repeatable results across 20 runs; no thermal trip; the power
delta is measured; the tool is documented.

**Stop:** any instability; the model output drifts; the phone overheats.

**Rollback:** remove the package; blacklist the module.

**Risk:** medium.

**Time:** 1-2 weeks.

### T8: default-on, power and suspend (attended)

**Goal:** the TPU is available by default and safe when idle.

**Do:**

1. Decide the autoload policy: udev modalias or a systemd unit. Keep it
   blacklisted until T7 passes.
2. Add the cooling device/trip points to the `tpu-thermal` zone; cap the OPPs
   at a measured sustained level (start at 627/712 MHz).
3. Runtime PM: power down when idle; s2idle: no TPU work in flight, resume
   cleanly, no wake source. 20 cycles.
4. Measure screen-off drain with the TPU idle and with a workload; record.

**Expect/Pass:** boot, idle, suspend/resume and 20 power cycles with no TPU
fault; the thermal cap holds; no AoC/modem/fingerprint regression.

**Stop:** any suspend hang or resume fault; any thermal trip; any GSA/Trusty
error.

**Rollback:** the module blacklist and the overlay removal; reboot.

**Risk:** medium-high (suspend is fragile on this phone).

**Time:** 1-2 weeks.

### T9: upstream and long-term

**Goal:** keep the port maintainable without pretending it is upstream.

**Do:**

- Keep the driver in-tree behind `CONFIG_EDGETPU_FRAMEWORK`, with a
  `README` naming the source branch and the local changes.
- Do not propose the vendor driver upstream as-is; it depends on `soc/google`.
  If the project wants upstream, split the generic framework and propose a
  clean `drivers/accel/edgetpu` with standard IOMMU/PM, separately.
- Track Google's janeiro branch changes; the stock firmware and the driver's
  KCI version are a pair. A kernel update that changes the ABI needs the
  matching firmware, which the user must extract again.
- Re-run `tools/kernel-pr-check` on every change; keep the DT binding and the
  driver in separate commits.

**Time:** ongoing.

---

## 7. Verification

| Area | Check | Pass |
| --- | --- | --- |
| Build | `bin/omamobile kernel`, `W=1`, `dtbs_check`, `kernel-pr-check --build` | clean for the touched files |
| DT | `dt-validate` for `gs201-cheetah.dtb` with the overlay | no new warnings |
| Boot | boot with the overlay, driver blacklisted | no change in UFS/USB/AoC/modem |
| Probe | `dmesg | grep -i -E "edgetpu|abrolhos|janeiro|tpu"` | firmware/KCI versions, no faults |
| Device | `ls -l /dev/edgetpu /sys/class/edgetpu` | node and class exist |
| Debugfs | `find /sys/kernel/debug/edgetpu -maxdepth 2` | power, usage stats, debug dump (as ported) |
| IOMMU | `/sys/kernel/debug/iommu`, `dmesg` faults | domain attached; no faults |
| Interrupts | `grep -i tpu /proc/interrupts` | the 8 IRQs are not spurious |
| Thermal | `tpu-thermal` before/during/after | under the cap; no trip |
| Power | `power-ab` / `upower` with the TPU idle and busy | measured delta |
| Inference | CPU reference vs TPU | within tolerance, 10/10 |
| Suspend | 20 s2idle cycles with the TPU idle | wake, no faults |
| Regression | `tools/phone-smoke` | no new failures |

Do not claim a speedup without a measurement. Do not claim isolation while
the "SSMT setup failed" warning is present.

---

## 8. Performance and power expectations

- The stock table says 1066 MHz averages 4.4 W, 845 MHz 2.6 W, 627 MHz 1.7 W,
  455 MHz 1.3 W, 226 MHz ~0 W. These are Google's numbers, not ours; measure
  on this phone.
- The 4 TOPS figure is the marketing peak. Real throughput depends on the
  model, the batch size, the number of tiles and the memory path. Compare
  against CPU XNNPACK and the Mali-G710 with the same model.
- Sustained performance is thermal-limited. Stock's CPU/GPU zones throttle
  from 100 °C, and the TPU zone is critical at 110 °C; our first cap should be
  lower (80-85 °C) until the TPU's cooling device is proven.
- The TPU is a separate power domain; idle it should be off/deep-sleep, and
  the screen-off drain should not change. Measure it.
- Do not use the top OPP without BCL; the brownout caps are part of stock's
  safety envelope.

---

## 9. Risks

| # | Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- | --- |
| 1 | The GSA TPU interface is missing or cannot be ported without secure-world changes | Medium | Blocks everything | Read the GPL GSA module first; test a no-op command in T3; if it needs Trusty changes, stop and reassess |
| 2 | SysMMU v8 is too large to port correctly | Medium-high | Blocks probe | Start with a minimal single-instance driver; use Google's GPL driver as the reference; test with the TPU disabled |
| 3 | The S2MPU blocks TPU DMA and we cannot program it | Medium | Blocks inference | First light with ABL's state; read-only S2MPU facts at T0; do not weaken the guard |
| 4 | ACPM TPU state API differs from the vendor calls | Medium | Blocks power-up | Read the vendor `exynos_acpm` code; test `get_rate`/`set_rate` read-only before the probe |
| 5 | The firmware is version-locked to the stock kernel/driver | Medium | Blocks probe | Extract the firmware from the matching stock build; compare the KCI version; do not mix builds |
| 6 | The Coral compiler's package is incompatible with gs201 | Medium | Blocks inference | Test a tiny model first; try a stock-compiled model; RE the package only if needed |
| 7 | The stock runtime does not run in the chroot | Medium | Slows validation | Use U1 (UAPI client) instead; the chroot is a shortcut, not a dependency |
| 8 | Thermal/power make the TPU impractical | Low-medium | Limits use | Cap the OPPs; measure; add cooling; do not chase the top bin |
| 9 | The TPU test wedges the GSA/Trusty and affects the fingerprint/AoC | Low-medium | Phone unusable until reboot | Never restart Trusty/storageproxyd; test when the fingerprint is idle; reboot on any error |
| 10 | The IOMMU/S2MPU is bypassed and the TPU can DMA anywhere | Low | Security | Keep the IOMMU attached; treat the SSMT warning as a blocker for isolation claims; root-only node |
| 11 | Upstream will not take the driver | High | Maintenance burden | Keep it in-tree behind a config; document the provenance; do not promise upstream |
| 12 | Legal: shipping Google's firmware or userspace | Low | Project risk | Extract from the user's image; never commit; clean-room client |

---

## 10. Effort

Assumes one developer writing code and the human running each gated step.

| Gate | Work | Best | Likely | Worst |
| --- | --- | --- | --- | --- |
| T0 stock facts | read-only captures | 0.5 d | 1 d | 2 d |
| T1 offline port | driver import, API churn, build | 1 wk | 2 wk | 3 wk |
| T2 DT + SysMMU v8 | minimal v8 driver, DT, boot tests | 1.5 wk | 3 wk | 5 wk |
| T3 ACPM + GSA | vendor ops, GSA TPU, no firmware | 1 wk | 2 wk | 3 wk |
| T4 first probe | firmware, GSA load, power | 3 d | 1 wk | 2 wk |
| T5 device query | UAPI client | 3 d | 1 wk | 1.5 wk |
| T6 one inference | compiler, runtime, correctness | 1 wk | 2 wk | 4 wk |
| **First inference (T0-T6)** | | **~5 wk** | **~10 wk** | **~18 wk** |
| T7 normal model + package | delegate/runtime, power | 1 wk | 2 wk | 3 wk |
| T8 default-on + suspend | thermal, PM, 20 cycles | 1 wk | 2 wk | 4 wk |
| **Usable + default-on** | | **~7 wk** | **~14 wk** | **~25 wk** |

The wide range is real: the SysMMU v8 and GSA work are the two unknowns. If
the v8 driver can be reduced to the single TPU instance and the GSA TPU calls
already exist in our GSA driver, the low end is plausible. If either needs a
new subsystem, the high end is more likely.

---

## 11. Open questions

1. Does the live gs201 DT match Google's GPL `gs201-tpu.dtsi` exactly
   (address, 8 IRQs, two memory regions, GSA phandle)?
2. What are the carveout addresses and sizes, and are they System RAM in our
   kernel's `/proc/iomem`?
3. Is `pd_tpu` on at ABL handoff, and what does its status register read
   through the PMU SMC?
4. Does our GSA driver have the TPU commands, or do we need to port
   `gsa_tpu.c`? What does it need from Trusty?
5. Is `s2mpu_tpu` already programmed by ABL, and does TPU DMA work without a
   Linux S2MPU write?
6. How much of the SysMMU v8 driver is needed for one TPU instance, and does
   the secure IRQ matter for non-secure DMA?
7. Which `edgetpu-janeiro.fw` matches `cheetah-cp2a.260705.006`, and what KCI
   version does it report?
8. Does `exynos_acpm_set_rate(TPU, state)` work on our ACPM driver, including
   `set_init_freq`/`set_policy`?
9. Does `devm_tpu_thermal_create` conflict with our `tpu-thermal` zone?
10. Does the Coral `edgetpu_compiler` output run on gs201's firmware? If not,
    what compiles models for it, and is a stock-compiled model available?
11. Does the stock `libedgetpu.so` run in the vendor chroot, and what ABI
    libraries does it need?
12. What ioctls does the stock runtime use, and do they match the GPL UAPI?
13. Does the TPU work with the modem on, and does it interact with UFS/PCIe
    through ACPM/DVFS?
14. Does s2idle with the TPU idle and resumed work; does the TPU need a wake
    source or a power-down hook?
15. What is the sustained thermal/power limit on this phone, and what OPP cap
    should the default use?
16. Is there a DTZPC/S2MPU state that must be restored after a TPU power-off,
    and does the vendor PD driver do it correctly?
17. Does the `dma-window` overlap any of our AoC/GPU/camera carveouts or
    IOMMU mappings?
18. What is the exact TPU revision/tile count the firmware reports, and does
    it match the Coral compiler's target?
19. Does loading the TPU firmware disturb the GSA/Trusty state used by the
    fingerprint and AoC? What is the safe order at boot?
20. What is the licensing/redistribution path for the firmware and the stock
    userspace? (Never ship; extract from the user's image.)

---

## 12. References

- Google's GPL gs201 device tree: `devices/google/gs201/dts/gs201-tpu.dtsi`,
  `gs201-sysmmu.dtsi` and `gs201-pm-domains.dtsi` in the
  `android-gs-pantah-6.1` tree (the same `G/` tree the CPUFREQ plan cites).
  The DT names and values above come from those files; the live values come
  from T0.
- Google's GPL gs201 TPU driver:
  `https://android.googlesource.com/kernel/google-modules/edgetpu/janeiro`
  (the gs201 chip; branches `android-gs-pantah-6.1-*`), and the shared
  `.../edgetpu` `android-gs-raviole-mainline` tree.
- Driver files cited above: `abrolhos-platform.c`, `abrolhos-pm.c`,
  `edgetpu-google-iommu.c`, `edgetpu-config.h`, `mobile-firmware.h`,
  `edgetpu.h`, `Kconfig`.
- Google's gs201 device makefiles:
  `device/google/gs201/device.mk` and `device/google/gs-common/edgetpu/edgetpu.mk`.
- Upstream gs101 TPU carveout (reference only, do not copy):
  `https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/exynos/google/gs101.dtsi`.
- Coral `libedgetpu` (Apache-2.0):
  `https://github.com/google-coral/libedgetpu`.
- Coral Edge TPU compiler documentation:
  `https://coral.ai/docs/edgetpu/compiler/`.
- REA (MIT), the reverse-engineering MCP/CLI:
  `https://github.com/morluto/rea`.
- Our plans: [GPU-PLAN](GPU-PLAN.md) (the G3D power/ACPM pattern),
  [ACPM-PLAN](ACPM-PLAN.md) (TPU domain 7, the ACPM API),
  [AOC-PLAN](AOC-PLAN.md) (GSA/Trusty and the log-first pattern),
  [FINGERPRINT-PLAN](FINGERPRINT-PLAN.md) (the GSA/Trusty rules),
  [CAMERA-PLAN](CAMERA-PLAN.md) (SysMMU v8 is also missing there).
- `AGENTS.md` §1 (safety), §4 (PMU/SysMMU gotchas), `CONTRIBUTING.md` §3
  (the storage guard and the way back).

---

## Appendix A: stock recon command sheet

```sh
# Read-only. Boot stock on slot A first; the human approves the boot.
adb shell 'uname -r'
adb shell 'find /proc/device-tree -iname "*tpu*" -o -iname "*janeiro*"'
adb shell 'ls -l /sys/class/edgetpu /dev/edgetpu /dev/janeiro 2>/dev/null'
adb shell 'cat /proc/iomem | grep -i -E "tpu|janeiro"'
adb shell 'cat /proc/interrupts | grep -i tpu'
adb shell 'dmesg | grep -i -E "edgetpu|abrolhos|janeiro|tpu"'
adb shell 'find /vendor/firmware -maxdepth 2 -iname "*edgetpu*" -o -iname "*janeiro*"'
adb shell 'find /vendor/firmware -maxdepth 2 -iname "*edgetpu*" -exec sha256sum {} +'
adb shell 'ls -l /vendor/lib64 /vendor/bin | grep -i -E "edgetpu|darwinn"'
adb shell 'for z in /sys/class/thermal/thermal_zone*; do echo "$z $(cat $z/type) $(cat $z/temp)"; done | grep -i tpu'
adb shell 'cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -i tpu'
adb shell 'ls /sys/kernel/debug/iommu 2>/dev/null'
```

If `adb root` is not available, use the readable paths and the stock dmesg;
do not flash anything to get root.

## Appendix B: DT sketch (values from `G/`; verify against `R/`)

```dts
/ {
	reserved-memory {
		tpu_fw_reserved: tpu-fw@0 {
			/* exact address/size from the live DT; no-map */
			reg = <0x0 0x00000000 0x00000000>;
			no-map;
		};
		tpu_fw_ctx_reserved: tpu-fw-ctx@0 {
			reg = <0x0 0x00000000 0x00000000>;
			no-map;
		};
	};

	sysmmu_tpu: iommu@1cc40000 {
		compatible = "samsung,sysmmu-v8";
		reg = <0x0 0x1cc40000 0x10000>;
		interrupts = <GIC_SPI 0 IRQ_TYPE_LEVEL_HIGH>,
			     <GIC_SPI 0 IRQ_TYPE_LEVEL_HIGH>;
		#iommu-cells = <0>;
		/* no power-domains for first light: keep pd_tpu on via ACPM */
		status = "disabled";
	};

	tpu: tpu@1ce00000 {
		compatible = "google,darwinn";
		reg = <0x0 0x1ce00000 0x200000>;
		reg-names = "tpu";
		interrupts = <GIC_SPI 0 IRQ_TYPE_LEVEL_HIGH>,
			     /* ... 8 entries, the stock order ... */;
		iommus = <&sysmmu_tpu>;
		dma-window = <0x18000000 0xE7FFF000>;
		#dma-address-cells = <1>;
		#dma-size-cells = <1>;
		memory-region = <&tpu_fw_reserved>, <&tpu_fw_ctx_reserved>;
		gsa-device = <&gsa>;
		edgetpu,shareability = <0x1cc20000>;
		tpu_dvfs_table_size = <7 2>;
		tpu_dvfs_table = <
			1066000 4420
			967000 4101
			845000 2578
			712000 1982
			627000 1749
			455000 1277
			226000 0
		>;
		status = "disabled";
	};
};
```

The IRQ numbers and carveouts are placeholders on purpose. Fill them from
`R/live.dts` and `R/iomem.txt`; never from another phone.

## Appendix C: kernel config fragment

```text
# Edge TPU (device/cheetah/TPU-PLAN.md). Modules; the DT nodes stay
# disabled until the tpu-test overlay, and the module is blacklisted.
CONFIG_EDGETPU_FRAMEWORK=m
# The exact chip option from the janeiro Kconfig (ABROLHOS or JANEIRO).
CONFIG_ABROLHOS=m
# IOMMU for the TPU's SysMMU v8
CONFIG_IOMMU_SUPPORT=y
CONFIG_IOMMU_IO_PGTABLE_LPAE=y
CONFIG_IOMMU_API=y
# Buffers and fences
CONFIG_DMA_SHARED_BUFFER=y
CONFIG_SYNC_FILE=y
CONFIG_GENERIC_ALLOCATOR=y
# Optional for first light; port BCL/BTS later
# CONFIG_GOOGLE_BCL is not set
```

Do not add `CONFIG_GOOGLE_BCL=y` until the TPU driver's BCL calls and the BCL
driver agree; a missing symbol is a build error, not a runtime surprise.

## Appendix D: the first userspace client

```c
/* Sketch only; the ioctl names/structs come from J/drivers/edgetpu/edgetpu.h. */
#include <fcntl.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "edgetpu.h"

int main(void)
{
	int fd = open("/dev/edgetpu", O_RDWR);
	if (fd < 0) {
		perror("open /dev/edgetpu");
		return 1;
	}
	/* Query device info, print firmware/KCI version, close.
	 * Use the driver's UAPI definitions verbatim; do not guess the ioctl
	 * numbers or struct layout. */
	close(fd);
	return 0;
}
```

Keep the tool root-only and do not add buffer/queue operations until the
device-info query returns sane values.

## Appendix E: where REA fits

REA is an MCP/CLI for reverse-engineering native binaries and runtime
behavior (`https://github.com/morluto/rea`, MIT). It is a community tool, not
vetted by this project; install it only with the human's go, and never point
it at the repository or at any file with identifiers.

Use it, in this order, only after T4/T5 have the kernel side working:

1. **Trace before decompiling.** On rooted stock Android, while an ML app runs:
   `strace -f -e trace=ioctl -xx -s 256 -o /tmp/tpu-ioctls.txt <pid>`.
   Map the ioctl numbers to `edgetpu.h`; this often answers the ABI question
   without any decompilation.
2. **Symbols and strings.** `readelf -d`, `nm -D`, `strings` on
   `/vendor/lib64/libedgetpu.so`, `libedgetpu_client.google` and the Darwinn
   HAL. Look for the device path, the ioctl wrappers, the model/package
   loader and any signature check.
3. **REA for the wrappers.** Ask it to decompile the functions that call
   `ioctl`/`open`/`mmap`, and to recover the struct layouts and the submit
   sequence. Compare with the GPL driver; write original code from the facts.
4. **Only if the model package is rejected:** compare a Coral-compiled package
   with a stock-compiled one, and recover the format/version fields. Do not
   patch the firmware or bypass a signature check.
5. **Do not** decompile the kernel module (the source is public), do not
   redistribute the stock binaries or the decompiled output, and keep all
   captures in `~/android/reference/` (private, never committed).

If a step needs a proprietary binary to answer a question, record the question
and the answer in this plan, not the binary.

---

## Appendix F: first-week checklist

- [ ] T0: capture the live DT, `/proc/iomem`, `/proc/interrupts`, dmesg,
      firmware hash, runtime library list. Keep them private.
- [ ] Confirm the driver source branch (`janeiro`, `android-gs-pantah-6.1-*`)
      and the Kconfig symbol.
- [ ] Check the local GPL tree for the GSA TPU interface and the SysMMU v8
      driver; write down the exact files and their license headers.
- [ ] Create `omamobile-tpu` and import the driver; make it build with the DT
      node disabled.
- [ ] Add the reserved-memory nodes only after checking `/proc/iomem`.
- [ ] Do not install REA or load the driver yet.

## U2: the VII setup contract, and where it blocks (2026-11-06)

Kernel `7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`, phone `cheetah`, one
cold boot per experiment as U1 requires.

### What works

- Group create, finalize and mailbox attach; VII IRQ; one 48-byte element in the
  command queue and its 24-byte response. The driver's queue dump prints both
  (`cq ...` / `rq ...`).
- Byte `+10` of the element is the command's **priority**. The firmware rejects
  an invalid one by name: `ERR vii_tracker.h:493 - Invalid priority: 68 for
  request: 0x<id>.` The stock runtime's element carries 11 there.
- The firmware only accepts a DMA descriptor it can reach. An element whose
  descriptor points into the command queue (a valid IOVA, but not in the
  firmware's reachable set) fails with `ERR vii_handler_layer.cc:43 - Buffer
  cannot be reached by firmware`. A page pinned with `EDGETPU_MAP_BUFFER`
  (`{host,size,dev,flags,die}`, 32 bytes, `_IOWR(0xED,0,...)`) returns
  `dev = 0xfffff000` and is accepted.
- A wakelock holder (`edgetpu-run hold`) keeps the TPU powered so one boot can
  run many groups; without it the first client to exit powers the TPU down and
  the next power-up wedges (`Set LPM0 failed: -110`).

### What does not work

Every element is answered with code 9 and
`ERR vii_handler_layer.cc:247 - Setup is not done yet received a command of
type 0.` regardless of:

- the u16 code at `+8` (all of 0..24; 1..24 is the runtime's whole command
  table, read from `libedgetpu_util.so`: one stub per code at file offsets
  `0x184ba0`-`0x184d70`, each `strh w8,[x0,#8]; str x9,[x0]`);
- the bytes at `+9` and `+11`..`+15` (nonzero there gives an earlier, silent
  code 9 with detail `0x14140000`, the firmware's reserved-field check);
- the payload contents (first word 0, 1, 11, or a zeroed page);
- the reachability of the payload (a mapped page only turns the 0x43 error into
  the 0x247 one).

The stock runtime fails the same way on this driver: `CreateVirtualDevice` ends
in `INTERNAL: Sync VII command failed: error_code=9`, and its first element is
code 0, priority 11, `dma 0xffeff000/0x80`. It never sends a setup command: the
gate is a byte at device-object `+0x130` bit 0 in `libedgetpu_util.so`
(`0x13c2ec: ldrb w8,[x20,#0x130]; tbnz w8,#0,skip; bl <setup>`), so the runtime
believes the firmware was already set up.

### The firmware's own words

The strings in `/lib/firmware/updates/google/edgetpu-janeiro.fw` name the state
machine and are the best specification we have:

- `Setup is not done yet received a command of type %d.`
- `Setup is already done, yet received another setup command.`
- `No global scratches were provided in setup command.`
- `Global scratch is too small to for fallback array allocator, %u bytes needed.`

So "Setup" is a command that **carries a global-scratch list**, and it is not
distinguishable by any element field the client can set today: the "type 0" in
the log is a placeholder and never changes.

### Next

1. Capture the setup payload instead of guessing it: the runtime builds it in a
   buffer it maps (`0xffeff000` in its own address space, 0x80 bytes). Either
   (a) extend the driver's VII IRQ dump to translate the element's descriptor
   IOVA through the group's mapping and hex-dump the payload into dmesg, or
   (b) run the runtime under gdb in the chroot and dump the host buffer behind
   that descriptor before the element is queued.
2. With the payload in hand, send it with `edgetpu-run mapped <code> <p0>`: the
   message to look for is `No global scratches were provided in setup command.`
   (the type was accepted) or `Setup is already done, yet received another setup
   command.` (setup ran).
3. Then the runtime path: `CreateVirtualDevice`, `RegisterGraphByBuffer` with
   `/vendor/graph.bin`, one inference compared with a CPU TFLite run.

### Client modes (tools/edgetpu-run.c)

`raw` (16 elements, varying +8), `hold` (keep the wakelock), `probe` (markers in
every candidate field), `setup OFFSET WIDTH VALUE` (one element field),
`payload CODE P0` (descriptor into the command queue at +0x1000; parses the
queue IOVA from /dev/kmsg), `mapped CODE P0` (descriptor into a page pinned with
EDGETPU_MAP_BUFFER). Build commands are at the bottom of `prompt.md`.

## U3. The runtime's VII payload, captured and replayed (2026-11-06)

**Tooling added.** `janeiro` now dumps the payload an element's DMA descriptor
points at. The dump runs from a workqueue (the VII handler is a hard IRQ, so it
cannot take the mapping lock) and reads through the mapping's pages, never
through the descriptor's address: `sg_copy_buffer()` for the group's host
mappings, `dma_buf_vmap()` in `edgetpu_read_dmabuf_mapping()` for its dma-buf
mappings. A first version dereferenced the host address from the kworker, which
has no `mm`, and the resulting fault rebooted the phone: never touch a user VA
outside the owning process. Output is four words per line:

```
edgetpu janeiro: vii-payload iova 0xffeff000 size 128 off 0 copied 64
edgetpu janeiro: vii-payload 0: 00000014 00000000 000a0000 00080012
```

**What the runtime sends.** With `edgetpu-run hold` holding the wakelock so the
TPU stays powered, the stock runtime's first `CreateVirtualDevice` submits one
element with descriptor `0xffeff000`, size `0x80`, and the same 128 bytes are
also present at `0xffefe000`. The first 64 bytes decode as a flatbuffer header
the parser accepts: root offset 20, soffset 10, vtable at 10, vtable 10 bytes,
table 18 bytes, three fields at offsets 8, 7 and 12. The tail of the buffer ends
in a 32-bit device address (`0xfff00000`), i.e. a list of references, as a
command list would be. `dmabuf_map_callback_release` / `edgetpu_unmap_dmabuf`
on the same unpark confirm the buffer is a dma-buf mapping, not a host one.

**Replay.** `edgetpu-run mapped CODE 0 /vendor/payload.bin` copies those 64 bytes
into a `MAP_BUFFER` page and submits them as the payload of elements with codes
0, 1, 2 and 11. Every run returns the same response (`0xf000009`, error 9), and
only code 0 prints `Setup is not done yet`: the firmware's setup check runs
before the command type is looked at, so this payload is the *sync* request's
buffer, not a setup command. Replaying it does not advance the setup gate.

**The full message.** The print bound is fixed (16 bytes per line, no
over-read), but the dump caps a payload at 64 bytes (`min(size, 64)`). A second
cold boot shows both descriptors (`0xffeff000` and `0xffefe000`) holding the
identical 64 bytes, and the flatbuffer's table plus its fields ends at byte 60;
the rest of the 128-byte buffer is padding. Decoding can proceed on these bytes.

**Next.** (1) Decode the flatbuffer's three fields against the runtime's known constants (48-byte
elements, 24-byte responses, priority 11, 24/12 KiB queues). (2) Find the
runtime's setup builder: the function holding
`Firmware setup failed for commands[%d], cluster_id_bitset in hex: %x.` builds a
command list; its callers and the flatbuffer field names in the binary give the
payload the firmware wants. (3) The fallback stays the stock HAL service, whose
own setup path is the authoritative one.

## U5. The setup function's shape (2026-11-06)

`0x13befc` is the function that owns the setup-failure log; it spans to about
`0x13c4f0`. Its structure, read from the disassembly:

- `object+0x180` is a "setup already failed" byte: the function loads it with
  acquire semantics at `0x13bf30` and returns early (`w20 = 1`) when it is set.
- It validates two vectors before doing anything: `[+0x238] - [+0x230]` must be
  at least 2 and `[+0x110] - [+0x110]` at least 5; otherwise it goes to the
  error path (`0x13bf90`) that builds a status object.
- It then walks the map at `+0x68`, calling the vtable slot at `+0x98` for each
  entry, and later walks the 40-byte command array (`x20 += 0x28`) before
  starting the response-waiter thread and setting `+0x180`.

So this function both *drives* the setup (it is the caller that walks the
command list and starts the waiter) and reports its failure. The send was found
at `0x13c0e4`-`0x13c110`: it fills a 40-byte entry (`+0`, `+8`, `+16`, `+0x20`)
after `0x13c514` prepares it, stores it into the object, and then calls
`[object+0x58] -> vtable[+0x18]` (`blr x9` at `0x13c13c`) — that is the VII
interface's submit method. The next step is the 40-byte entry's field layout and
reproducing it in `tools/edgetpu-run.c`; `0x13c514` is a `std::vector` push_back of 16-byte items: `ldr q0,[x1]` /
`str q0,[x9]` with begin/end/cap at `+0/+8/+0x10`, growing through `memcpy` at
`0x13c5d8`.

The 40-byte entry's layout, from `0x13c0c4`-`0x13c110`:

- `+0x00`-`+0x17`: a 24-byte inline area.
- `+0x18`: a flag byte (`strb w25`), set before the heap copy.
- `+0x20`: pointer to a 24-byte heap object holding three u64s copied from the
  source array at stride `0x18`.

So the setup command carries an array of 40-byte entries, each pointing at a
24-byte payload, plus a vector of 16-byte items. The next read is the submit
method behind `[object+0x58] -> vtable[+0x18]`, which turns those entries into
the VII elements the firmware consumes.

The HAL fallback cannot be started yet: `extract-vendor-chroot` records only the
factory build fingerprint in its `SOURCE` file, no image path, and no
`vendor.img`/`system.img` is left in the temporary directory. The owner's
factory zip is needed to add the system libraries the services link against.

## U4. Where the runtime gives up on setup (2026-11-06)

The runtime's setup-failure path sits in `libedgetpu_util.so` at
`0x13c1a0`-`0x13c2c0` (the message's literal is at file offset `0x67ce7`). Just
before it logs `Firmware setup failed for commands[%d]`, it calls `0x19e994`
with `x0 = object+0x258`, `x1 = &local`, `x2 = x21`, `x3 = x22`, then sets
`object+0x180 = 1` (`stlrb` at `0x13c230`). The create path's gate is a byte at
`object+0x130`; `0x180` is a separate "setup failed" marker. `0x19e994` is not a
sender: it allocates a 48-byte control block and starts the VII *response
waiter* thread (`pthread_create` at `0x19ea10`, body at `0x19ea90`), the one the
runtime later complains about (`ViiResponseEventWaiter was destroyed without
being terminated first`). The loop just before it walks entries of 0x28 (40)
bytes, the command list, so the send happens earlier in that function or in its
caller. Next: find the enclosing function's start and the call that writes the
command queue for setup.

The HAL fallback has all three Google services in the chroot but lacks their
system libraries: the chroot carries 9 files in `/system/lib64`, while
`android.hardware.neuralnetworks@service-darwinn-aidl` alone needs `libbase`,
`libbinder`, `libcutils`, `libui`, `libhardware`, `libhidlmemory` and
`libhidlbase`. Those come from the factory image's system partition, which
`tools/extract-vendor-chroot` unpacks; add them there before retrying the
service.

## U6. Debugger session on the setup flag (2026-11-06)

gdb 18.1 and gdbserver are on the phone. The vendor chroot has no `/usr` and no
`/proc`, so a session needs `mount --bind /usr "$R/usr"` and
`mount -t proc proc "$R/proc"` (plus `ln -s usr/lib "$R/lib"`), and the runtime
is started under `chroot "$R" /usr/bin/gdb --args /vendor/bin/edgetpu-run-new
/vendor/graph.bin`.

At `base + 0x13c2ec` (the `ldrb w8,[x20,#0x130]` check, base = the runtime
symbol's address minus `0xf07a0`), `x20` is the device object. Clearing
`*(u8 *)(x20+0x130)` and continuing changed nothing: the next element's queue
word was still code 0, priority 11, descriptor `0xffefd000`, size `0x80`, and
the response was `0x0009` again. So `+0x130` is not the setup gate that decides
whether the setup command is sent, and this runtime never submits a setup
command on its own — consistent with setup being the HAL's job, not the app
runtime's.

The driver has no VII setup path either: the only "setup" in it is
`chip_fw->setup_buffer` in `edgetpu-firmware.c` (the KCI firmware-load buffer)
and the MMU/IRQ plumbing.

## U7. The HAL function table (2026-11-06)

`GetDarwinnHalFunctions()` returns a versioned table (`version 4` at `[0]`) of
twenty function pointers into `libdarwinn_hal.so`, plus `0x430061` at `[21]`
and the sentinel `0x7fffffff` at `[22]`. The offsets from the library base are

```
[1] 0x831318  [2] 0x8314a4  [3] 0x8314c8  [4] 0x831614  [5] 0x831638
[6] 0x831728  [7] 0x83176c  [8] 0x831790  [9] 0x831b00  [10] 0x831c54
[11] 0x831d38 [12] 0x831e14 [13] 0x831e5c [14] 0x831ec8 [15] 0x831f34
[16] 0x831f6c [17] 0x832048 [18] 0x832090 [19] 0x8323a8 [20] 0x832848
```

`[1]` (`0x831318`) is a substantial function that builds two objects, looks up
strings at `0x430061` and `0x45c0e0`, and returns status codes 1-5 — it is the
HAL's own initialisation path, not a thin wrapper. The other entries follow it
closely in the same region, so they are the HAL API implementation, not stubs.
Calling one from the client needs its exact signature; the table gives no names
because the library is stripped.

The kernel gives no help either: the driver's KCI command set has no setup
command (only the open/map/firmware-info sequence it already runs at probe).

## U8. The VII brute force is exhausted (2026-11-06)

`edgetpu-run scratch CODE FLAGS` maps a page, writes one global-scratch entry
(`{u64 device_address; u64 0x1000}`) at its start, and submits it as the
element's payload (descriptor = the page, size 16, flags = FLAGS). With the
wakelock holder alive so the TPU stayed powered, the sweep covered code 0-40
with flags 0 and flags 0-255 with code 0: every run returned `0xf000009` and the
firmware logged exactly `Setup is not done yet received a command of type 0.`
No code or flag value changes the outcome, so the setup command cannot be
reached by guessing element fields.

Together with U6 (the runtime never sends setup) and U7 (the kernel has no setup
command), this leaves one producer: Google's HAL, whose service cannot start
without the factory image's system libraries.

## U9. The factory image is in, and the HAL service starts (2026-11-06)

The owner authorised downloading the factory image. `out/factory` (gitignored,
never commit) holds `cheetah-cp2a.260705.006-factory-23d564ad.zip` (3.9 GB,
the build the chroot's `vendor/build.prop` pins), its `image-*.zip`, and the
extracted `system.img` and `vendor.img`.

- `/system/lib64`: 768 libraries, extracted with `7z` (the image is ext4;
  `debugfs rdump` fails as non-root on chown, so use `7z x system.img
  "system/lib64/*"`).
- `/vendor`: the full Android 17 vendor tree, 489 libraries.
- The darwinn AIDL service's recursive `DT_NEEDED` closure is now **zero**
  missing: the earlier eight (`android.hardware.neuralnetworks-V4-ndk.so`,
  `@1.0`-`@1.3`, `power-V2-ndk.so`, `libprotobuf-cpp-full-21.7.so`,
  `com.google.edgetpu_app_service-V2-ndk.so`, ...) were the *old* A14 binary's
  needs. The A17 vendor's own service wants V3 and protobuf 6.33.5, both
  present.
- It starts: `chroot $R /vendor/bin/hw/android.hardware.neuralnetworks@service-darwinn-aidl`
  with `LD_LIBRARY_PATH=/system/lib64:/vendor/lib64:/apex/com.android.runtime/lib64/bionic`
  reaches main without a link error.
- It does **not** touch the TPU: 40 s, no output, no dmesg line, no mailbox IRQ.
  It is most likely blocked on `AServiceManager_addService` (no servicemanager
  in the chroot) before opening the device.
- Freeing the device for it killed the wakelock holder, so the TPU is down until
  the next cold boot.

Next: a cold boot with the service as the first client and a binder context
(`servicemanager` from `/system/bin` in the chroot), or calling the HAL entry
from the client directly (U7's table) to bypass binder entirely.

## U10. Binder exists, but the HAL service still does not open the device (2026-11-06)

The kernel has binder built in (`CONFIG_ANDROID_BINDER_IPC=y`,
`CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"`) but exposes it only
through binderfs, and nothing mounts it on this root, so `/dev/binder` was
missing and `servicemanager` aborted with "Binder driver '/dev/binder' could not
be opened".

Fixes that worked:

```sh
mount -t binder binder /dev/binderfs
ln -sfn /dev/binderfs/binder /dev/binder      # and hwbinder, vndbinder
mkdir -p $R/dev/binderfs
mount -t binder binder $R/dev/binderfs        # visible inside the chroot
ln -sfn /dev/binderfs/binder $R/dev/binder    # chroot-absolute target
mount -t proc proc $R/proc
```

With those, `servicemanager` gets past the driver open and past "Bad boot_id"
(it needs `/proc` inside the chroot), then aborts with no further message; the
darwinn service starts and links but still never touches `/dev/edgetpu` (no
dmesg line, no mailbox IRQ). The AIDL service expects an Android init
environment: property service, `/linkerconfig/ld.config.txt`, a populated
`/dev` and `/proc` with Android's mounts, and a servicemanager that survives.

Two ways forward, in order:

1. **Call the HAL entry directly** from `edgetpu-run hal` instead of running the
   AIDL service. The table is known (U7: version 4, entries at `0x831318`+) and
   every library it needs is now staged, so the client can pass a create-device
   request and watch `vii-payload` for the setup command, with no binder.
2. **Give the service an init-like environment**: a minimal `ld.config.txt` at
   `/linkerconfig`, `/system/etc` from the image, a property area, and a
   servicemanager that does not abort (logcat would name the assertion).

## U11. The HAL's device entry opens the TPU (2026-11-06)

The table is now mapped to real code. `GetDarwinnHalFunctions` is at file
offset `0x16946ec`, the table itself at `0x22b79a8`, and the entries are one
function each, in file order from `0x16946f8`:

| entry | file offset | what it does |
| --- | --- | --- |
| `[1]` | `0x16946f8` | `DarwinnHal::Init(Spawner **out)`: a null `out` returns 4 and logs `DarwinnHal: init was called with a null spawner pointer.`; a valid one forks the compiler spawner (the `fork` at `0x169a7f0`) and then busy-waits at 100 % CPU in userspace |
| `[2]` | `0x16947fc` | destroys that spawner |
| `[3]` | `0x1694828` | `CreateDevice(config, void **out)`, where `config` is the struct the AIDL service's `main` builds on its stack: `{u32 1, u32 1, char *"/dev/edgetpu", Spawner *, int -1}` |

The client's new `halcall device [SECONDS]` passes exactly that config to
`[3]`. It is the HAL's own device creation, and it reaches the driver:

```
ioctl fd 3 req 0x4008ed05 -> 0 event_id 0 efd 5      # create group
ioctl fd 3 req 0x4014ed06 -> 0 cmdq 24 rspq 12 ...   # attach
ioctl fd 3 req 0xed08 -> -1                          # finalize: power on
```

On this boot the TPU was already wedged (the earlier wakelock holder had been
killed): `Set LPM0 failed: -110 ... GSA state 1`, then `firmware handshake
failed: -110`, `finalize group: power on failed: -110`, and the HAL returned 2
with `Could not finalize device group ... Connection timed out`. That is the
known needs-a-real-power-cycle state, not a HAL fault: the same call is now one
cold boot from a live TPU.

Two older AIDL-service attempts from U9/U10 were still resident and spinning at
100 % CPU each, in `[1]`'s spawner wait; they were killed.

Next: cold boot, then `/root/tpu-hal.sh` (insmod, the chroot mounts, then
`edgetpu-run halcall device 40`) as the first client, and read `vii-payload`
for the setup command the app runtime never sent.

## U12. A fresh boot completes the HAL's device creation (2026-11-06)

After a real power cycle (poweroff, the owner pressed Power), `halcall device 40`
succeeded end to end:

```
runtime wakelock on fd 3: 0
ioctl 0x4014ed06 -> 0                      # attach
ioctl 0x4008ed05 -> 0                      # create group
ioctl 0xed08 -> 0                          # finalize
edgetpu janeiro: loaded prod firmware (1.0 895567958)
edgetpu janeiro: finalize: detachable 1 wakelock 1 context 1073741824
edgetpu janeiro: OPEN_DEVICE ret 0
edgetpu janeiro: finalize: kci_finalized ret 0
edgetpu janeiro: finalize: mailbox_attached 1 context 1
```

It held the device open for 40 s (a mailbox IRQ every ~15 s) and then exited
cleanly (`Powering down`). **No VII element was submitted**: no `vii-payload`
line and no mailbox command beyond the driver's own OPEN_DEVICE. So creating
and finalizing the HAL's device is not what sends setup either; it must come
from a later HAL call, probably the virtual-device/graph path.

The first attempt after the cold boot failed with `failed to open
/dev/edgetpu: No such file or directory` because the device node is
`/dev/janeiro`; the boot does not create the `/dev/edgetpu` symlink (the older
bring-up scripts did it by hand). `tpu-hal.sh` and the runbook must
`ln -sfn janeiro /dev/edgetpu` after insmod, before the chroot bind-mounts
`/dev`.

Next: find the HAL function that builds the setup command and the table entry
that reaches it. The HAL library holds the same `Firmware setup failed for
commands[%d]` string as the app runtime (at `0x4b8c71`), so its setup builder is
in there; locating its caller names the entry to call after `[3]`.

The one IRQ the driver sees while the HAL holds the device is a keepalive on
**mailbox 0** (the KCI mailbox, logged from `janeiro-device.c`, `status 1`);
the VII mailbox (1) raises nothing, and `edgetpu_vii_irq_handler` never runs.
So either the HAL writes no VII element at all, or it writes one the firmware
drops without a response. `halcall device` now starts a watchdog thread before
calling `[3]`: ten seconds later it maps the HAL's own group (its `/dev/edgetpu`
fd is kept in `tpu_fd`) at CSR `0x1800000`, command queue `0x1900000` and
response queue `0x1a00000` and prints the queue words, which shows whether the
HAL wrote a command before it blocked.

## U13. The HAL submits, and the firmware rejects it with 0xf000009 (2026-11-06)

On a cold boot `halcall device 0` printed, ten seconds into the blocked call:

```
watch: cq 0xffffbb090000 rq 0xffffbb08d000
watch: cq 0x69d449f1 0x0 0x3 0x35614856 0x0 ...
watch: rq 0x1 0x0 0xf000009 0x100164f5 0x0 0x0 0x2 0x0
```

The response element carries `0xf000009`, the same "Setup is not done yet"
(error 9) the app runtime gets. So the HAL **does** submit a command, and the
firmware rejects it at the same gate; the HAL then blocks waiting for a valid
response. The command queue's first word is not a valid element (the firmware
consumed it before the dump), but the response is the proof.

Together with the HAL table this closes the userspace question: neither the
app runtime nor the HAL can produce the setup state. It must be set below
them. The driver's KCI command enum skips code 6 (`KCI_CODE_SHUTDOWN = 7`) and
has no setup command, and the firmware-load path
(`mobile_firmware_setup_buffer`) only copies and authenticates the image.

Next: read the firmware itself. Locate the file the driver requests, confirm
it holds `Setup is not done yet`, and disassemble the check (Thumb) to find
which channel sets the flag and which command type clears it; then compare
Google's janeiro `edgetpu-kci.h` with ours for the command we lack.

## U14. The firmware image and its setup state machine (2026-11-06)

Google's newest janeiro `edgetpu-kci.h`
(`android-gs-shusky-6.1-android16`, blob `abb5801b1090`) skips code 6 exactly
like ours, so there is no KCI setup command to port: the setup is a VII
command, not KCI.

The file the driver requests, `google/edgetpu-janeiro.fw`, is not on the
phone's Arch root. It comes from the stock vendor partition; we took it
read-only out of the user's own factory image with `debugfs`:

```
out/factory/fw/img/vendor.img: /firmware/google/edgetpu-janeiro.fw (inode 2273)
-> out/tpu-firmware/edgetpu-janeiro.fw  1 038 272 bytes
sha256 52c1cccdf0e243d12fbc9f3b3911fe9c780a11d9a5bfda61744c7c3fdaded7c3
```

`out/` is gitignored: never commit the image.

Its header: magic `TPUF` at 0x400, ImageConfig at 0x560, `carveout_base`
`firmware_base` = 0x93000000, `firmware_size` 0xfd000, firmware version 1.0
(build 2/3), privilege level 1 (TZ), body at 0x1000 copied to 0x93000000. The
body starts with ARM branches (`ea000019`), so it is A32 code, not Thumb.

The strings hold the state machine, in plaintext:

```
0xefbdc  Setup is not done yet received a command of type %d.
0xefddc  Setup is already done, yet received another setup command.
0xefe18  No global scratches were provided in setup command.
0xe7b90  Request setup failed.
```

So the firmware expects one setup command, with global scratch buffers, before
it serves anything else, and it logs the type of the command it rejected. The
`0xf000009` both userspace runtimes get is this check (`Setup is not done yet`).

No absolute pointer to those strings exists in the image (the search covered
absolute, base-relative and movw/movt forms), so the firmware is position
independent and a static cross-reference is not the cheap way in. The cheap
way is the firmware's own log line: send an element with a distinctive byte
pattern and read which `type %d` it reports, which locates the type field of
the element; then walk the types until one is accepted (a setup without
scratches should answer `KCI_ERROR_INVALID_ARGUMENT`, not 9, which identifies
the opcode). The driver's debugfs node may expose the firmware log — check
`/sys/kernel/debug/edgetpu/janeiro` first.

## U15. The runtime's setup is a Tachyon "firmware setup" (2026-11-06)

The A17 vendor runtime names the pieces. `libedgetpu_tachyon.google.so`
exports `TachyonComputeSession::SetupCommandFmq(int*, int*)` and
`SetupResponseFmq(int*, int*)`. `libedgetpu_util.so` carries
`firmware_setup_done_`, a firmware-wakelock `RegisterCallbackPair` that clears
it, and the failure message
`Firmware setup failed for commands[%d], cluster_id_bitset in hex: %x.`

So the setup is the runtime's "firmware setup" sent over the Tachyon queues
after the FMQs are set up and the firmware wakelock is held, and it carries a
cluster bitset; the firmware's side of it wants global scratches. That is
consistent with the HAL: its device entry blocks before the runtime's setup
step, so the HAL never sends one.

Therefore the next experiment belongs in the runtime, not the firmware. Find
the setup message builder in the .so (`llvm-objdump` on the ELF; the symbols
are exported), reproduce its bytes from the driver's own group with
`tools/edgetpu-run.c`'s `scratch_mode`, and answer the firmware's setup gate.

One more datum from the same boot: the GSA does load the image (`loading TPU
image: header … body 0x93000000`), and a second device create in the same boot
wedges the PSM (`Set LPM0 failed: -110`, `GSA state 1`), so the one TPU run per
cold boot rule still stands.

## U16. Queue indexing fixed; type is a flatbuffer field, not the element code (2026-11-07)

Kernel `7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`, module `janeiro-new.ko` (vii-elem
header dump at the last-consumed cmd-queue slot, payload dump cap raised 64 -> 512).

- **The group's queues are 512 slots, not 24/12.** create_group attr is
  `{cmdq_kb=24, rspq_kb=12, cmd=48, rsp=24}`; element slot = `k % 512`, response
  slot = `k % 512`. With `% 24`/`% 12` the firmware's tracker desynced
  (`Received command.seq 0x<garbage>, expected 0x19`). With `% 512` and a
  serialized submit (wait for response word0 == seq at `rq+(k%512)*24`), 200/200
  submissions get proper responses.
- **Element code at +8 is not the firmware's command type.** Sweeping codes 0..199
  with the captured sync payload gave `0xf000009` and a firmware ring log of
  "command of type 0" for every one (200 entries in the log ring). Mutating each
  of the 64 payload bytes to 0x5a likewise never changed the logged type. So the
  type is an **absent field** of the payload's 3-field flatbuffer table (default 0),
  not any byte present in it.
- **The firmware log ring is userspace-readable**: mmap offset `0x1B00000`, 64 KiB,
  header `{head@0, size@4, tail@0x40, dropped@0x44}`, entries from 0x80, entry
  header `{s16 code, u16 len, u64 ts, u16 crc}` + text. The driver's printk of it is
  ratelimited (`etdev_*_ratelimited`); the ring keeps ~500 entries. `fwlog` mode in
  tools/edgetpu-run.c scans it. A cold boot resets head/tail to 0, so everything in
  the ring is from the current boot (scan `[0x80, tail&0xffff)`).
- `fw_tracing/request` debugfs: bit 8 (256) is the default vote; a request without
  bit 8 passes the firmware's own retval through.
- The app runtime (`edgetpu-payload2 /vendor/graph.bin`) on a cold boot submits
  exactly **one** VII command (the sync request) and gets `Sync VII command failed:
  error_code=9`; attempts 2/3 then wedge the PSM (second create in one boot). It
  never sends a setup command itself — on stock that must come from the Tachyon
  AIDL session (`TachyonComputeSession_setupCommandQueue`/`sendCommand` over
  binder+FMQ in `libedgetpu_tachyon.google.so`), which needs the vendor service
  environment we do not have.
- Next: `typesweep` mode — a crafted Command flatbuffer with fields f1..f8 all set
  to a candidate value v, swept v=1..200, watching for the response word or ring
  line to leave `0xf000009` / "type 0".

## U17. typesweep null: even a crafted Command table with f1..f8 set logs type 0 (2026-11-07)

Kernel `7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`. New `typesweep` mode in
tools/edgetpu-run.c builds a valid flatbuffer (root@0 -> table@0x20, vtable@0x04,
9 fields: f0 u64 @+8, f1..f8 u8 @+16..+23) with f1..f8 all set to v and sweeps
v = 1..200 (200 serialized submissions, one cold boot, script /root/tpu-tsweep.sh).
Result: every response word2 = 0xf000009, every ring entry still
"Setup is not done yet received a command of type 0" (ring head 0x1ea tail 0xab8,
~26 deduped lines for 200 commands — the firmware dedups identical log lines, so
per-submission types are not visible in the ring; only a *changed* type would log).

Combined with U16 this leaves two live explanations:
1. The firmware never DMAs our payload (host MAP_BUFFER page, dev addr
   0xfffff000), so the parsed Command is empty and type defaults to 0. The gate
   logs the type before any buffer-reachability check, so this is
   indistinguishable from "type really is 0" with the gate failing first.
   MAP_BUFFER flags we pass = 0 = MIRRORED (all dies) + TPU-CPU-accessible=yes
   (bit3=0), same address class as the runtime's dmabuf 0xffeff000, so
   reachability should be OK — but unverified from the firmware side.
2. The type lives in a field layout none of our sweeps touched (element +12
   was never swept; HAL's one command had +12 = 0x35614856).

Vendor-lib string probe: no flatbuffer field names for the VII Command schema in
libedgetpu_tachyon/util/hal (`global_scratch*` absent; only
`DarwinnApi2_InferenceRequest_GetCommandType` and hal's
`scratch_buffer_alignment_bytes` executable parameter). The runtime's setup path
is the Tachyon AIDL session (libedgetpu_tachyon.google.so:
TachyonComputeService_createSession@0x10bb0, setupCommandQueue@0xdf00,
setupResponseQueue@0xdfd0, sendCommand@0xe0a0, receiveResponse@0xe170), which
needs the vendor service environment; util builds per-cluster setup commands at
libedgetpu_util.so 0x13befc, hal at libdarwinn_hal.so 0x14d9a24.

Open driver/client bugs to fix next boot: (a) edgetpu-mailbox.c dump_schedule uses
slot = REAL_INDEX(head) % size but the firmware already advanced head at IRQ time,
so it dumps the empty next slot — use (REAL_INDEX(head)+size-1) % size; (b) fwlog
scan must treat tail&0xffff < 128 as empty (observed tail 0x62 on a fresh boot).
Phone state: last boot's TPU run spent (typesweep consumed the one run); next client
run needs poweroff + Power.

## U18. The firmware's type is a Command flatbuffer field; a schema sweep with the ring as oracle (2026-11-07)

Kernel `7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`. Offline work on the
laptop (the boot in progress had already spent its one TPU run on the U17
typesweep, so nothing here touched the TPU).

### What the firmware says it does

The strings in `out/tpu-firmware/edgetpu-janeiro.fw` (`third_party/darwinn/
firmware/driver/mailbox/vii_handler_layer.cc`) put the parse and the gate in
one function, in this order:

```
efb34  Unknown command type
efb4c  Buffer cannot be reached by firmware.
efbb8  Could not parse Command flatbuffer.
efbdc  Setup is not done yet received a command of type %d.
efc14  Invalid command.
efdc8  Setup is already done, yet received another setup command.
efe18  No global scratches were provided in setup command.
```

So the firmware (1) parses the element's DMA payload as a **Command
flatbuffer**, (2) takes the command *type* from that flatbuffer, and (3) refuses
every type but setup while the setup flag is clear, logging the parsed type.
The element's `u16` at `+8` is not that type: the two stock writers put 0 there
and the runtime's type byte at `+10` (11 for its setup) never reaches the log
either — every sweep in U8/U16/U17 read back `type 0` because the *payload*
never parsed to a nonzero type. A parse failure is a separate line
(`Could not parse Command flatbuffer.`), so the ring distinguishes "type is
absent" from "type is wrong".

### The runtime's command table

`libedgetpu_util.so` maps its command enum to VII element codes with a byte
table at file offset `0x7a344` (entry *n* is a byte offset / 4 from
`0x184b64`). Entries 1..23 land on the 12-byte stubs at `0x184ba0`-`0x184d70`,
each `strh w8,[x0,#8]` with `w8` = 1..24: enum *n* writes element code *n*.
Entry 0 does not: it jumps to `0x184b64`, a logging path that builds an error
status, i.e. **type 0 is "not a command"** in the runtime. That is also the
type the firmware reports for the runtime's own sync payload, which is why the
gate and the runtime's `Sync VII command failed: error_code=9` agree.

### New client mode: `cmdsweep`

`tools/edgetpu-run.c` gains `cmdsweep [/vendor/payload.bin]`, one group, one
cold boot:

- **A** the captured runtime payload as the baseline (expect `type 0`);
- **B** a Command flatbuffer with 32 declared fields, all set at once to
  `(i % 24) + 1`, then to `((i * 7) % 24) + 1`. The firmware prints the value
  of whichever vtable slot its schema reads as the type, so the two answers
  name the field by elimination (the patterns collide only where the index is
  congruent mod 24, and the second pattern separates those);
- **C** with the field known, sweep its value 0..24 (the runtime's whole
  command table). A setup type that clears the gate answers with a different
  error and the firmware's own `No global scratches were provided in setup
  command.` instead of `Setup is not done yet` — the definition of done for
  this cycle;
- **D** if B reads 0 for both patterns, each field alone with 1, which tells a
  non-scalar type (a union offset, or a field outside the table) from a parse
  failure.

The client reads the answer from the firmware's own log ring (mmap
`0x1B00000`), not from the response word: the gate runs before any dispatch,
so the response is always `0xf000009` even when the type is finally right.

Build (laptop, Android clang, bionic from the vendor chroot):

```sh
CL=~/.cache/omamobile/toolchain/clang-r596125/bin/clang
C=out/vendor-chroot-edgetpu/root
$CL --target=aarch64-linux-android30 -O2 -fPIE -pie -nostdlib -fuse-ld=lld \
    -Wl,-e,_start -Wl,-dynamic-linker,/system/bin/linker64 \
    -o out/tpu-client/edgetpu-run-new tools/edgetpu-run.c \
    -L$C/apex/com.android.runtime/lib64/bionic -L$C/system/lib64 -L$C/vendor/lib64 \
    -llog -lc -lm -ldl -ledgetpu_util -ldarwinn_hal
```

Result of this run: recorded below once the phone has been power-cycled.

### Result (2026-11-07, `7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`)

Cold boot (poweroff, the owner pressed Power; 20 s to SSH), `janeiro-new.ko`,
one group, 35 submissions, `/root/tpu-cmdsweep.sh`:

```
cmdsweep: create_group -> 0
cmdsweep: finalize -> 0
cmdsweep: map_buffer -> 0 dev 0xfffff000
cmdsweep: A baseline ring type 0
cmdsweep: B1 ring type 0
cmdsweep: B2 ring type 0
...
cmdsweep: D field 26 ring -1 ... done, submissions 35
fwlog head 0x62 tail 0x126
log@0x8e: ERR vii_handler_layer.cc:247 - Setup is not done yet received a command of type 0.
```

Every response was `0xf000009`, every ring line `type 0`, and — the part that
matters — **no `Could not parse Command flatbuffer.` line at all**, although one
submission carried a 32-field table with every field set. Two readings survive:

1. The payload is parsed and its type field is not one of the 4-byte-aligned
   table slots (our fields sit at table+4, +8, +12, ...). U3's decode of the
   runtime's own payload found its three fields at table offsets **8, 7 and
   12** — offset 7 is a byte-aligned slot, and no sweep has ever written there
   (`typesweep` used +16..+23, `cmdsweep` uses 4+4i).
2. The firmware never reads the payload for this command at all; the gate then
   runs on an element field. U16/U17 argue against the element being the type,
   but no run has yet proved the parse *can* fail on this path.

One control settles which: submit a deliberately unparseable payload (all
`0xFF`). A `Could not parse Command flatbuffer.` line proves the parse runs and
that reading 1 is the one to chase; silence proves the gate precedes the parse.
The next experiment does that first, then sweeps every byte-aligned vtable slot.

### New client mode: `bytesweep`

`tools/edgetpu-run.c` gains `bytesweep [/vendor/payload.bin]`, one group:

- **0** an all-`0xFF` 64-byte payload — the parse-error control;
- **A** the captured runtime payload (expect `type 0`);
- **B** a table with **60 byte-aligned vtable slots** (table+4 .. table+63), all
  set to `(i % 24) + 1`, then to `((i * 7) % 24) + 1`: whichever byte the schema
  reads as the type is printed by the firmware, and the two patterns name it;
- **C** that byte swept 0..24, the runtime's whole command table;
- **D** fallback per byte, alone, value 1.

Responses are read from the ring after a settle delay (the firmware's printer
is asynchronous), never from the response word, which stays `0xf000009` behind
the gate.

### Result (2026-11-07, `7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`, bytesweep)

Cold boot (20 s to SSH), one group, 64 submissions, `/root/tpu-bytesweep.sh`:

```
bytesweep: D byte 59 ring 0
bytesweep: done, submissions 64
fwlog head 0x1ea tail 0x1880 dropped 0
log@0x8e: ERR vii_handler_layer.cc:247 - Setup is not done yet received a command of type 0.
... (29 deduplicated copies, one per distinct submission slot)
```

**Phase 0 is the answer: an all-`0xFF` payload produced no
`Could not parse Command flatbuffer.` line.** The firmware never parses the
payload before the gate, so the gate's `type %d` is not a payload field, and
the two flatbuffer sweeps (U17's typesweep, U18's cmdsweep) could never have
moved it. The 60 byte-aligned slots changed nothing either, as expected once
the parse is out of the picture.

That leaves the element header. Ruled out so far: `+8` (u16, swept 0..199 in
U16), `+10` (priority, 11 in every submission), `+4`/`+6` (probe markers), and
`+9`, `+11`..`+15` (nonzero there trips the reserved-field check with detail
`0x14140000`). Untested: `+12` (u32; the HAL's one command carried
`0x35614856`, which has the shape of stack garbage) and `+32..+47`. The `with
%d` may also simply be a variable the firmware fills after the gate — the
`type 0` is a constant across four different payload shapes, so a placeholder
is now the leading explanation.

Next, in order: (1) sweep the remaining element fields (`+12`, `+32..+47`) in
one group and watch the ring; (2) if the line is a placeholder, stop reading
the log and read the firmware's gate code instead — locate
`vii_handler_layer.cc:247` in the A32 image by its string table entry, which
names the element field the gate reads.

### Result (2026-11-07, `7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`, elemsweep)

Cold boot (20 s to SSH), one group, 144 submissions, `/root/tpu-elemsweep.sh`.
The element header is exhausted too:

```
k=0  rsp 0x1 0x0 0xf000009 0x100164f5   ...   (+4, v=1: the gate, as before)
k=138 rsp 0x8b 0x0 0x9 0x14140000       ...   (+40..+44: reserved-field check)
log@0x2fd2: ERR vii_tracker.h:465 - Received command.seq 0x8a, expected 0x100000002
```

- `+4` and `+12`, swept 1..24 each, keep the gate line at `type 0`.
- `+36..+44` are inside the firmware's reserved-field check (`0x14140000`), so
  they are not a type field either.
- Past about 128 submissions in one group the firmware's expected seq desyncs
  (`expected 0x100000002`), and every later response is noise; the "response
  changed" lines in the +4/+12 phases came from that, not from a real change.
  The client now caps a sweep at 120 submissions.

Conclusion after four cold boots today: neither the element header nor the
payload changes the string the gate prints. The `%d` is a constant zero for a
command it refuses, so the log cannot name the setup type. Two live
explanations remain:

1. the gate checks a **per-context setup state** that a command on another
   channel sets, not a field of this command; or
2. the setup command is identified by a field outside the 48-byte element we
   write (e.g. the firmware reads a `CommandInfo` word the driver's queue
   mapping does not expose).

Both point away from more userspace sweeps. The next cycle should either find
the KCI-side setup (code 6 is the one code the driver's enum skips, and the
firmware wants a DMA buffer of global scratches, which a KCI command carries in
its `struct edgetpu_dma_descriptor`) or read the firmware's gate code, whose
file/line `vii_handler_layer.cc:247` is in the image but whose address is not
reachable by an absolute or movw/movt reference.

### U19: the KCI side, first attempt (2026-11-07, `7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`)

No KCI command carries a setup command: both driver headers run 0-5, skip 6, and
continue at 7, and a KCI element's `dma` descriptor is exactly the shape a
"global scratches" setup would need. So the driver gained a development-only
debugfs hook (`/sys/kernel/debug/edgetpu/janeiro/kci_send`, write a decimal
code; it allocates a page of coherent memory, points the element's DMA
descriptor at it, calls `edgetpu_kci_send_cmd()` and logs the response):

```
[   13.280843] edgetpu janeiro: kci_send code 6 tpu_addr 0xfffff000 -> -110
[   14.308794] edgetpu janeiro: kci_send code 15 tpu_addr 0xffffe000 -> -110
...
```

All of 0..40 time out (`-110`), **including 4 and 7, which the driver itself
sends successfully at run time**. So the hook as written runs before anything
has opened the device and the response path is not live; this says nothing
about code 6 yet. It needs to run with a client holding the device open (or
from an ioctl on an already-open device).

Two other checks the same day:

- **Firmware gate address.** No reference to the gate string (`0xefbdc`), its
  vaddr (`0x93efbdc`), the file string (`0xefa80`), or `Invalid command.`
  (`0xefc14`) exists anywhere in the body as a 32-bit literal, absolute or
  relative, at any alignment. The log records therefore address their strings
  some other way (an index table, or a segment base other than `0x93000000`),
  so a plain xref hunt cannot find the gate.
- **Runtime/firmware version.** The runtime only ever says
  `Unable to detect firmware version.`; it carries no expected-version
  constant, so a version mismatch cannot be the gate (and the firmware, not
  the runtime, would log a mismatch).

After six KCI sends the client still ran normally in the same boot, so the hook
does not wedge the device; a group created after it still answers `0xf000009`
for element type 8 = 0..10.

### U19 addendum: the ioctl path (same boot series)

Moving the send behind an ioctl (`_IOW(0xed, 33, u32)`, added next to the other
private codes) so it runs with the device open:

```
elemsweep: create_group -> 0
elemsweep: finalize -> 0
elemsweep: map_buffer -> 0 dev 0xfffff000
kci: code 4 -> -1
kci: code 9 -> -1
kci: code 6 -> -1
k=0 rsp 0x1 0x0 0xf000009 0x100164f5 ...
```

`dmesg` has no `kci_send(ioctl)` line, so the ioctl fails **before** the send:
`edgetpu_alloc_coherent()` with `EDGETPU_CONTEXT_DOMAIN_TOKEN` refuses a
client-side allocation (-EPERM). The next attempt should allocate in the
client's own context (or point the KCI descriptor at the group's already-mapped
buffer), then repeat 4/9 as the control.

Vermagic note for the next build: `setlocalversion` takes the git hash from the
worktree tip, so a module built after committing on `omamobile-tpu` does not
load on a phone running the kernel built from the commit before it
(`version magic '...-g537403c986a6-dirty' should be '...-g29a7a9326bf0-dirty'`).
Building with the tip moved back to the running kernel's commit (`git reset
--soft HEAD~1`, changes stay staged, so `-dirty` still matches) produces a
loadable module.

### U20: KCI code 6 is implemented and answers (2026-11-07)

With the device open and a group live, the debug-only ioctl now reaches the
firmware:

```
[   12.485658] edgetpu janeiro: kci_send(ioctl) enter f_mode 0x408001f
[   12.485778] edgetpu janeiro: kci_send(ioctl) code 4 -> 12
[   12.485968] edgetpu janeiro: kci_send(ioctl) code 9 -> 3
[   12.486095] edgetpu janeiro: kci_send(ioctl) code 6 -> 3
```

KCI response 3 is **failed precondition**. So code 6 — the one code both
driver headers skip — is a real command: it answers instead of timing out.
The firmware's own `No global scratches were provided in setup command.` fits
the precondition exactly: the descriptor pointed at a zeroed page, which reads
as an empty scratch list. That is the strongest lead so far.

Two traps this cost, both now fixed:

- the request number is `_IOW(0xed, 33, u32)` = **0x4004ed21**; 0x4001ed21
  encodes size 1, the driver answers `ENOTTY` and never logs, and `ioctl()`
  only shows -1 either way — log on entry, not just on success.
- the VII responses after the KCI sends (`0xff0003`) are the tracker desync
  (`Received command.seq 0x2, expected 0x100000002`), not a gate change; the
  ring still holds one gate line per group.

### U21: the device stops opening after a module reload (2026-11-07)

The variant sweep never ran. On the boots after U20, `open("/dev/edgetpu",
O_RDWR)` inside the chroot returns -1 with the node present (`502:0`) and the
driver logs nothing, so the failure is before any logged path. What the boots
did establish, all worth keeping:

- the module is now loaded by the boot itself. Its probe logs
  `Failed to fetch pasid-num-bits, defaulting to 8 PASIDs (-22)`, a WARN in
  `iommu_set_fault_handler` and one in `__setup_irq`, then "initialized".
- **a second load in one boot oopses**: `rmmod janeiro; insmod …` after the
  boot's own load crashed in `edgetpu_mmu_attach+0x110` (SMMU state is not
  reset by `rmmod`), and that boot then had no usable device. One load per
  cold boot, before anything opens the device.
- the chroot has its own `/dev`: it held `edgetpu -> janeiro`, a dangling
  link, so every chroot run failed to open even with a good host node. Real
  nodes (`mknod … c 502 0` and `502 1`) plus
  `LD_LIBRARY_PATH=/apex/com.android.runtime/lib64/bionic:/system/lib64:/vendor/lib64`
  make the client run.
- the module file is `janeiro.ko`; the boot copies it from
  `/usr/lib/modules/<release>/kernel/drivers/edgetpu/`, not from the worktree.

Next cycle: replace that copy with the ioctl build, cold boot, and open the
device **before** any `rmmod`; then run `kciv`.

### U22: KCI is closed — code 6 is not a command (2026-11-07)

`kcistate` sends code 6 right after open, then maps codes 0-15 with a zeroed
page, then resends 6 after each group step. With the driver's own enum
(`edgetpu-kci.h`) to name them:

```
code 0  ACK                 -> 0
code 1  UNMAP_BUFFER        -> 0
code 2  MAP_LOG_BUFFER      -> 0
code 3  JOIN_GROUP          -> 12  (UNIMPLEMENTED)
code 4  LEAVE_GROUP         -> 12  (UNIMPLEMENTED)
code 5  MAP_TRACE_BUFFER    -> 0
code 6  (not in the enum)   -> 3   (INVALID_ARGUMENT)
code 7  SHUTDOWN            -> 0
code 8  GET_DEBUG_DUMP      -> -110
code 9  OPEN_DEVICE         -> -110
code 10 CLOSE_DEVICE        -> -110
code 11 FIRMWARE_INFO       -> -110
code 12 GET_USAGE_V1        -> -110
code 13 NOTIFY_THROTTLING   -> -110
code 14 BLOCK_BUS_SPEED     -> -110
code 15 (not implemented)   -> -110
```

Three conclusions:

- the firmware implements only 0-7, and `JOIN_GROUP`/`LEAVE_GROUP` are
  unimplemented in this branch, so group state is the driver's business;
- **code 6 is not a setup command**: the enum skips it, and 3 is
  INVALID_ARGUMENT, not "failed precondition". U20's reading was wrong;
- one unimplemented code poisons the channel: after code 8's timeout every
  later send answers -110 for the rest of the boot. Never sweep past 7.

So the VII setup gate cannot be reached through KCI. The reference path left
is the vendor HAL: it exports `DarwinnApi2_Request_CreateViiCommand`,
`DarwinnApi2_VirtualDevice_CreateInferenceRequest` and
`DarwinnApi2_RequestQueue_Submit`, which build exactly the VII commands the
firmware expects. Drive those and read the firmware ring: if the gate line
disappears, the HAL performed the setup, and the queue can then be dumped to
see what it wrote.

### U23: the stock runtime finalizes the group, then hangs (2026-11-07)

The vendor image carries `/vendor/bin/edgetpu-run MODEL`, which drives the
stock delegate. Run as the **first** TPU operation of a boot, it reaches the
furthest point yet:

```
edgetpu janeiro: loaded prod firmware (1.0 895567958)
edgetpu janeiro: finalize: detachable 1 wakelock 1 context 1073741824
edgetpu janeiro: edgetpu_mailbox_init_vii: pasid 1 mailbox 1
edgetpu janeiro: edgetpu_mailbox_init_vii: mbox 1 cmdq iova=0x1015c000 dma=0x1015c000 rspq iova=0x10162000 ...
edgetpu janeiro: OPEN_DEVICE: mailbox_map 0x2 priv 1 vcid 1 first 1 state_ret 0
edgetpu janeiro: OPEN_DEVICE ret 0
edgetpu janeiro: finalize: kci_finalized ret 0
edgetpu janeiro: finalize: mailbox_attached 1 context 1
```

`edgetpu-run` then hangs inside `DarwinnDelegate_CreateVirtualDevice`, before
it submits any VII command. The mailbox doorbell then fires every 15 s with
status 1 and nothing consumes it. So:

- the driver's open/create/set_eventfd/finalize path matches the stock runtime,
  and the firmware accepts it (`OPEN_DEVICE ret 0`, `kci_finalized ret 0`);
- the VII gate is never reached by the delegate, so the gate is not what hangs
  it. The hang is a missing host-side response after finalize.

Two operational facts, both cost a boot to learn:

- **the TPU powers up once per boot.** After any power-down the next attempt
  logs `TPU in GSA state 1, resetting`, `Set LPM0 failed: -110`, `firmware
  handshake failed: -110`. Every experiment needs its own cold boot.
- the chroot's `/dev` and `/vendor/etc` are recreated at boot: make
  `dev/janeiro` (`c 502 0`) and `dev/edgetpu-soc` (`c 502 1`), and copy the
  model in again each boot.

U23 addendum: the hang is a **userspace busy loop**, not a blocked syscall.
While `edgetpu-run` hung, `/proc/<pid>/syscall` read `running` and
`/proc/<pid>/wchan` read `0`; the process held fd 4 (`dev/janeiro`), fd 5 and
fd 7 (eventfd), fd 6 (epoll) and fd 8 (timerfd). So `CreateVirtualDevice`
spins on an event that never arrives, after the driver has already finalized
the group and attached the mailbox. The binary is not stripped, so the next
step is to read `/proc/<pid>/maps`, subtract the module base from the spinning
PC and `addr2line` it — that names the exact function to fix.

### U24: the delegate creates its virtual device, then needs a DMA-BUF heap (2026-11-07)

With `tools/edgetpu-nometrics.c` preloaded, `DarwinnDelegate_CreateVirtualDevice`
no longer spins in `AServiceManager_isDeclared` → `WaitForPropertyCreation`
(that wait is an Android servicemanager property, and it never returns on a
Linux userspace). The delegate then gets a virtual device, sets a second
eventfd (`0x4008ed05 event_id 1 efd 11`) and dies allocating its tensors:

```
E file.cc:60] INTERNAL: Failed to open DMA-BUF heap: No such file or directory
W :47] Failed to allocate tensor buffer: ... Attempting to allocate it with the next memory option if available.
E file.cc:55] INTERNAL: Failed to allocate buffer after trying with all available memory options.
F :54] Check failed: allocated_bytes_ == 0 (1048576 vs. 0)
```

So the next dependency is the Android DMA-BUF heap (`/dev/dma_heap/system`).
The driver's own coherent allocator is not what the delegate reaches for: it
asks the heap by Android's path. The kernel config and the phone must provide
it, or the HAL must be given a memory option that does not need it.

### U25: even the stock delegate gets error 9 (2026-11-07)

With `dev/dma_heap/system` (c 249 0) in the chroot and the servicemanager shim
preloaded, `edgetpu-run` runs the whole reference sequence and gets as far as
its **Sync VII command**:

```
ioctl fd 4 req 0x4014ed06 -> 0        create group
ioctl fd 4 req 0x4008ed05 -> 0        eventfd 0
ioctl fd 4 req 0xed08      -> 0        finalize
ioctl fd 4 req 0x4008ed05 -> 0        eventfd 1
ioctl fd 15 req 0xc0184800 -> 0       dma-buf heap alloc
ioctl fd 4 req 0xc028ed11  -> 0       map dmabuf
ioctl fd 4 req 0xed1a      -> 0
ioctl fd 4 req 0x8010ed1b  -> 0
E0000 file.cc:1506] INTERNAL: Sync VII command failed: error_code=9
```

9 is FAILED_PRECONDITION, the same answer the firmware gives every hand-built
element, and the driver's dump of that element's payload reads zeros. So the
reference runtime cannot get past the gate either: **the setup is a step whose
host half is missing in this environment**, not a malformed element of ours.

Next places to look for that host half, in order:

- `edgetpu_mailbox_init_vii` in our driver against the vendor kernel's: a setup
  element may be written there before any doorbell;
- `com.google.edgetpu_vendor_service`, which may send the setup at device open
  before any client does;
- the GSA/PSM firmware configuration path, which would carry the global
  scratches the firmware names.

Keep: the dma-buf heap node makes allocations succeed, and
`tools/edgetpu-nometrics.c` clears the servicemanager wait. The captured
`out/edgetpu-runtime/model.tflite` is a COCO detector (98 label strings), so it
is the right model for the benchmark once the gate opens.

### U26: two candidate host halves for the setup (2026-11-07)

Strings in `libedgetpu_util.so` show the delegate does track a firmware setup:

```
Firmware setup failed for commands[%d], cluster_id_bitset in hex: %x.
... RegisterCallbackPair(... firmware_setup_done_ = false ...)
DarwinnApi2_Request_CreateViiCommand
```

and the vendor image ships a second, newer compute API beside the VII one:

```
libedgetpu_tachyon.google.so: TachyonComputeSession_setupCommandQueue,
  TachyonComputeSession_setupResponseQueue, SetupCommandFmq, SetupResponseFmq
com.google.edgetpu.tachyon-ndk.so
com.google.edgetpu_vendor_service-V2-ndk.so
```

So the missing setup is one of two things: the VII "firmware setup" inside
libedgetpu_util (per command and cluster, gated by `firmware_setup_done_`), or
the Tachyon compute session, whose FMQ queues the vendor service uses. The
delegate's Sync runs before either, or its setup failed silently; the HAL has
to be made to say which, with glog verbosity.

U26 addendum: with `GLOG_v=3 GLOG_logtostderr=1`, the delegate's log holds
exactly one error — `Sync VII command failed: error_code=9` — and **no setup
attempt at all**. So the "firmware setup" path in libedgetpu_util is not
entered by `edgetpu-run`; the host half the firmware wants is sent by something
else on stock Android (the vendor service or the Tachyon compute session), not
by the delegate.

### U27: the Tachyon service path is binder-only (2026-11-07)

The vendor image's Tachyon stack is not usable from a Linux userspace, and the
reason is structural rather than a missing file:

- `com.google.edgetpu.tachyon-service` aborts at start with
  `Binder driver '/dev/binder' could not be opened. Error: 2`. Arch has no
  binder at all, so the service never reaches the TPU and the delegate's next
  run still answers `error_code=9`.
- `libedgetpu_tachyon.google.so`'s `TachyonComputeService_create` is a binder
  **client**: it calls `AServiceManager_isDeclared` and then
  `AServiceManager_waitForService`, and only wraps the resulting
  `IComputeService` proxy. It never opens `/dev/edgetpu` itself.
- `TachyonComputeSession_setupCommandQueue` only calls
  `ComputeSession::SetupCommandFmq(int*, int*)` on a session object the service
  handed out. The fds come from the service, so a session cannot be built
  in-process without binder either.

So the Tachyon compute API is a thin AIDL skin over a device-owning service,
and that service is Android-only. The VII setup it would send is not reachable
from the phone's Linux side without a binder driver plus a servicemanager,
which is an Android userspace, not a shim.

The firmware's own words narrow what is missing (strings in
`edgetpu-janeiro.fw`, `out/tpu-firmware/`):

```
Setup is not done yet received a command of type %d.
Setup is already done, yet received another setup command.
No global scratches were provided in setup command.
Global scratch is too small to for fallback array allocator, %u bytes needed.
```

So the setup is one VII command, once per firmware boot, carrying the global
scratch list. `libedgetpu_util.so` contains the builder (`Firmware setup failed
for commands[%d]`, `firmware_setup_done_`) but `GLOG_v=3` shows the delegate
never enters it: on stock Android the vendor service does, at boot, before any
client. With binder out of reach and the lib stripped, the host half cannot be
reproduced from the vendor image alone. Reproducing it would mean reverse
engineering the flatbuffer from the service binary by hand.

Decision: the VII/Tachyon gate stays closed for this bring-up. The TPU work
continues from the kernel side (mailbox, firmware load, MMU, power) and the
userspace client stays in `tools/edgetpu-run`; inference is blocked until a
host-side setup implementation exists, and that is not a kernel problem.

### U27 addendum: where the setup builder logs (2026-11-07)

`Firmware setup failed for commands[%d]` sits at file offset `0x67ce7` in
`libedgetpu_util.so`, and its `LOG(ERROR)` site is at **`0x13c2bc`**:

```
13c2b8: adrp x0, 0x67000
13c2bc: add  x0, x0, #0xce7
13c2c0: add  x2, sp, #0x90
13c2c4: mov  w1, #0x45          ; line 69
```

`llvm-objdump` labels nothing after `0xfca90` in this stripped library, so the
enclosing function has no name and its start is only findable by a prologue
scan. That function is the setup builder: it is the thing the missing host half
does, and it is either callable through an exported path or copyable field by
field from its disassembly. `tools/edgetpu-run.c` gains a `firmware` mode when
the buffer layout is known.

### U28: binder does exist, and the vendor stack runs under shims (2026-11-07)

U27's conclusion held only for a userspace without binder. The kernel has
`CONFIG_ANDROID_BINDER_IPC=y` and `CONFIG_ANDROID_BINDERFS=y`
(`CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"`), and
`/proc/filesystems` lists `binder`; nothing ever mounted it. After
`mount -t binder binder /dev/binderfs` the four nodes appear (`binder` is
507:1, not 507:0).

With binder present the vendor stack needed two more things, both now tools:

- **a servicemanager**: extracted from the stock system image
  (`debugfs -R "dump /system/bin/servicemanager"` on `out/cp2a-system.img`);
- **two LD_PRELOAD shims**, because this is not Android:
  `tools/android-log-stderr.c` routes liblog to stderr (logd does not exist),
  and `tools/android-selinux-allow.c` satisfies libselinux (the kernel has
  `CONFIG_SECURITY_SELINUX` unset, and servicemanager aborts in
  `Check failed: selinux_status_open(true ) >= 0`).

With both preloaded, servicemanager runs (it prints `SELINUX-SHIM` and
`Using old property service protocol`), and
`/vendor/bin/hw/com.google.edgetpu.tachyon-service` starts and stays up
instead of aborting on `/dev/binder`. The full sequence is packaged as
`tools/tpu-tachyon-run`, which also creates `/dev/dma_heap/system`, mounts the
chroot's `/dev`, `/proc` and `/sys`, and runs the delegate.

Benchmark baseline meanwhile, on the host (16 cores), the COCO SSD int8 model
from Google's `coco_ssd_mobilenet_v1_1.0_quant_2018_06_29` bundle over a 720p
mosaic clip of COCO val2017 images (`out/bench/mosaic720.mp4`, 60 frames):

```
cpu-xnnpack-t1   11.52 ms mean   86.8 fps   10 detections/frame (th 0.4)
cpu-xnnpack-t4    3.98 ms mean  251.1 fps   10 detections/frame (th 0.4)
```

`tools/bench-object-detection.py` produced those numbers; the TPU row is added
when the VII gate opens.

### U29: the service runs, but the delegate never asks it (2026-11-07)

Cold boot with `tools/tpu-tachyon-run` (kernel
`7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`): janeiro autoloads from
`/etc/modprobe.d/omamobile-tpu.conf` (`blacklist janeiro` is *not* in it; the
file only marks it), the TPU powers up, `loaded prod firmware (1.0 895567958)`,
`OPEN_DEVICE ret 0`, `kci_finalized ret 0`, mailbox 1 VII queues created, and
the delegate gets through create-group / eventfd / finalize / its mmaps. Then
it hangs and `timeout` returns 124, no sync and no error.

With the nometrics shim preloaded instead, the same binary skips the service
check, reaches Sync and gets `error_code=9`. So the two paths differ exactly at
the Android service lookup: without a property service the delegate spins in
`CreateVirtualDevice` before it can use the now-running Tachyon service.

Both servicemanager and the Tachyon service were up in that boot (the script's
earlier abort was its missing `LD_PRELOAD`, now fixed). What is missing is
`__system_property_*`: a shim that answers the property wait would let the
delegate reach the service, and a small client calling
`TachyonComputeService_create` + `createSession` would test the same path
without the delegate.

### U30: property shims are not the hang (2026-11-07)

`tools/android-props-stub.c` now answers every `__system_property_get` with
`1` (`ro.build.version.sdk` with `34`), and `servicemanager.ready` was already
true. The delegate still ends in `timeout` 124 after it loads the model
(`model bytes: 4749998`) and maps its buffers, with the driver's
`OPEN_DEVICE ret 0` already logged. So the spin is no longer a property wait;
it happens after the device is open and before the first VII element.

The direct Tachyon API is now mapped for the next attempt: `SessionConfig` is
0x28 bytes with a bool at 0, int32 fields at 4, 8 and 0xc, a
`shared_ptr<IGetFdsResponseCallback>` at 0x10, and int32 fields at 0x20 and
0x24; `TachyonComputeService_createSession(service, &config, &ret)` writes a
`CreateSessionReturn`, and the session's queue fds come from
`TachyonComputeSession_setupCommandQueue(session, &fd, &size)`.

Next, before writing that client: attach gdb to the hung delegate (the binary
is unstripped) and read the spinning frame; that names the exact call instead
of guessing.

### U31: ready=true ends the spin, then a stack-protector abort (2026-11-07)

The 500 MB log was the delegate itself: `libbinder.BackendUnifiedServiceManager`
waited for the `servicemanager.ready` property in a loop that printed without
sleeping (`wchan 0`, `syscall running`). Android sets that property to the
string `true`; the first shim returned `1`, which never matched.

With `true`, the spin stops and the delegate moves on, then aborts in 0.1 s:

```
[libbinder.IPCThreadState] Binder transaction failure. id: 4, cmd:
  BR_FAILED_REPLY, error: 4294967201 (Operation not supported on transport endpoint)
[libbinder.ServiceManagerCppClient] Failed to get isDeclared for
  android.frameworks.stats.IStats/default: Status(-129, EX_TRANSACTION_FAILED)
stack corruption detected (-fstack-protector)
libc: Fatal signal 6 (SIGABRT) ... tid 4170 (edgetpu-run)
delegate rc: 134
```

That is after `OPEN_DEVICE ret 0` and `kci_finalized ret 0`, with the TPU
powered down at 39.58 s, i.e. before any VII element. The shim now echoes the
name the caller asked for (a mismatched name was the first suspect) and the
abort is unchanged, so the corruption is either in libbinder's `isDeclared`
fallback or in the delegate's own stats/perfetto path, not in the property
name. Next is a gdb run that stops at SIGABRT, with the chroot follow-exec
method that already worked for servicemanager.

U31 addendum: gdb follows the delegate's exec but cannot load bionic symbols
("Could not load symbols ... Do you need set sysroot?"), so the SIGABRT
backtrace is `#0 0x0000fffff634ea10 in ?? ()` and `#1 0x...20`, i.e. libc's
abort plus a garbage frame. The way to name the smashed function is an
`LD_PRELOAD` `__stack_chk_fail` that writes its return address, paired with
the delegate's load base from `/proc/self/maps`.

### U32 (2026-11-07): the abort was inside stock liblog, and the VII gate is next

`uname -r` 7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty.

A preloaded shim cannot intercept liblog's own hidden-alias calls, and the
frame whose canary fired (`__system_property_find` plus a `getprogname` tag
string, then `__stack_chk_fail` at file offset 0x60d4 of the stock
`liblog.so`) is one of them. So the shim now exports all 21 liblog symbols the
chroot's libraries import (`tools/android-log-stderr.c`), and the runner
installs it as the chroot's `liblog.so`.

Result: no `stack corruption detected`, no SIGABRT. The delegate runs to its
own end and fails with `INTERNAL: Sync VII command failed: error_code=9` and
rc 1. The crash was in liblog, not in the delegate; the remaining wall is the
same one as U27: the VII global-scratch setup has to come from the Tachyon
service, and the delegate is still taking its direct path.

Note: the stock `liblog.so` in the chroot was overwritten without a backup
(the backup step ran in the same command as a copy that failed). Regenerate
the chroot with `tools/extract-vendor-chroot` before any step that needs
stock liblog.

### U33 (2026-11-07): the client libraries load; the delegate still picks the direct path

`uname -r` 7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty.

`tools/dlopen-check.c`, preloaded through the runner (`PROBE=1`), loads all five
vendor client libraries with `RTLD_NOW`: `libedgetpu_client.google.so`,
`libedgetpu_tachyon.google.so`, `libtachyon_core.so`,
`com.google.edgetpu.tachyon-ndk.so` and
`com.google.edgetpu_vendor_service-V2-ndk.so` all return OK. So the delegate's
fallback to direct ioctls is a choice it makes, not a missing library.

With servicemanager and `com.google.edgetpu.tachyon-service` both alive (pids
confirmed), the delegate still runs its own VII sync:
`INTERNAL: Sync VII command failed: error_code=9`, then
`create device status: 13`, `device: 0x0`, rc 1. Nothing in its log mentions
connecting to the Tachyon service, though
`libedgetpu_tachyon.google.so` carries `com.google.edgetpu.tachyon.
IComputeService/default` and the message `Failed to connect to the Tachyon
Compute Service`.

Two chroot facts that cost time here: the chroot has no `/root` directory
(created now; shims the runner needs live in `/system/lib64`), and its
`/system/lib64/libc.so` is a symlink to a stale extraction path
`/tmp/sysx/apex/...`, so an inline repro must set
`LD_LIBRARY_PATH=/system/lib64:/vendor/lib64:/apex/com.android.runtime/lib64/bionic`
exactly as the runner does.

### U34 (2026-11-07): the service chain needs the vendor binder domain

`uname -r` 7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty.

The vendor util library picks the Tachyon path only for a non-root uid above
9984 whose `open("/dev/edgetpu")` fails with `EACCES`: at `0x1bf4f4` it takes
the `getuid()` branch, and only uid>>4 > 0x270 with errno 13 reaches the
`dlopen("libedgetpu_client.google.so")` helper at `0x1bf8a8`. Running the
delegate as root always goes direct, which is why every earlier run hammered
the VII gate. `RUN_UID=10000` in `tools/tpu-tachyon-run` runs it as an app uid
(the binder nodes are opened up for that; `/dev/edgetpu` stays root-only).

As uid 10000 the delegate now asks servicemanager for
`com.google.edgetpu.IEdgeTpuAppService/default`, the service stock's Darwinn
NNAPI HAL publishes, and reports "Failed to open device fd from EdgeTPU
service". So the client side is in place; what is missing is the service.

The chain is vendor-service (owns /dev/edgetpu) then tachyon-service then the
Darwinn HAL. All three abort on registration:

- Their own log says vendor binaries bind on `/dev/vndbinder`
  ("Not able to get context object on /dev/vndbinder"), so the chain has to run
  with `/vendor/lib64` first and a servicemanager started as
  `servicemanager /dev/vndbinder`.
- `registerLazyService` is answered `ENOTSUP` by that servicemanager
  (`BR_FAILED_REPLY`, error 4294967201), and AidlLazyServiceRegistrar aborts on
  any non-OK status. `tools/android-lazysvc-shim.c` interposes
  `AServiceManager_registerLazyService*` and calls `AServiceManager_addService`
  instead (marker `LAZYSVC-SHIM` proves interposition), but that call comes back
  non-OK too.
- The shim must not be preloaded into servicemanager itself: that binary links
  libbinder (C++), not libbinder_ndk, so an unresolvable
  `AServiceManager_addService` stops it from starting ("CANNOT LINK EXECUTABLE").

Reading `AStatus` fields by hand faulted the service; the next probe uses the
exported `AStatus_getExceptionCode` to name the failing status.

## U35 (2026-11-07): the kernel refuses the transactions: no LSM provides secid_to_secctx

The registration failure is not servicemanager's doing. dmesg during a chain run:

    binder: 16769:16767 failed to get security context
    binder: 16769:16767 transaction call to 16751:0 failed 413/29201/-95, code 4 size 168-0 line 3376

`drivers/android/binder.c:3366` translates the caller's secid for every
transaction whose target node carries `FLAT_BINDER_FLAG_TXN_SECURITY_CTX`
(binder.c:782, set from the `flat_binder_object` flags). Android's libbinder sets
that flag on the nodes it publishes, so each `addService` needs
`security_secid_to_secctx()`. This kernel has no LSM that implements it --
SELinux is not built in and `/sys/kernel/security/lsm` reads `capability,landlock`
-- so `call_int_hook(secid_to_secctx, -EOPNOTSUPP, ...)` returns -95 and the
transaction fails with `BR_FAILED_REPLY`. That is the ENOTSUP seen through
`registerLazyService` too: same code, one layer down.

Tried and measured, all on the same boot as before (no reboot between runs):

- `tools/android-nosid-shim.c` (interposes `AIBinder_setRequestingSid` and
  `BBinder::setRequestingSid` to drop the flag): preloaded into the three
  services, never called -- neither marker printed, and the count stayed at 14.
- Byte patch of the flag computation in both libbinder copies (`mov w10,#0x1100`
  -> `#0x100`, at 0x505bc in `/system/lib64/libbinder.so` and 0x4ffac in
  `/vendor/lib64/libbinder.so`): the vendor copy is the one servicemanager maps
  (`/proc/<pid>/maps` shows `/vendor/lib64/libbinder.so`), the patch is in place
  (md5 7781e1b16999...), and the secctx count still reads 14. The patched site is
  `flatten_binder`'s `isRequestingSid()` branch; the context-manager node's flag
  comes from somewhere else (`becomeContextManager` at 0x9cb50 builds its
  `flat_binder_object` with `flags = 0`, so the flag is not from there either).
  The originals are kept next to the patched files as `libbinder.so.orig`.

So the honest options are (a) find the remaining flag site in libbinder and clear
it, or (b) give the kernel an LSM that implements `secid_to_secctx`, i.e. build
with `CONFIG_SECURITY_SELINUX=y` and `CONFIG_LSM="landlock,lockdown,yama,integrity,selinux,bpf"`.
With no policy loaded SELinux still answers the initial SIDs from
`initial_sid_to_string` (`security_sid_to_context_core`, services.c:1371), which is
exactly the "no labels matter here" answer this chroot needs; it is a kernel
build, a `push` and a reboot, so it needs its own gated run.

## U36 (2026-11-07): the binder fix works; the blockers move to servicemanager and janeiro

The kernel's binder driver now carries the fix this plan needs: when
`security_secid_to_secctx()` answers `-EOPNOTSUPP` (no LSM here translates
secids), `binder_transaction` sends the transaction without a context instead of
failing it. Built at `29a7a9326` + that patch, `push`ed, and measured on the
phone (`7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`):

    secctx failures, before: 14   after: 0

With the transactions actually arriving, `com.google.edgetpu.tachyon-service`
**stays alive** (`tachyon pid: 3591`), which it never did before. Three new
facts came out of the same run:

- `vendor.google.edgetpu_vendor_service@1.0-service` still dies, and the fault
  address is the same one U34 recorded: `SIGSEGV ... fault addr 0xffffff7f`,
  which is `-129` (`EX_TRANSACTION_FAILED`) read as a pointer. Our
  `android-lazysvc-shim` hands that value to `AStatus_getExceptionCode`, so the
  shim must not assume `AServiceManager_addService` returns a real `AStatus`.
- `servicemanager` itself aborts: `Fatal signal 6 (SIGABRT) ... in tid 3410
  (servicemanager)`. Its own stderr is the next place to read (the AIDL
  servicemanager CHECKs when a client dies mid-call).
- janeiro probes now that `tpu-enable.dtso` is part of `DTB_OVERLAYS`:
  `edgetpu_platform 1ce00000.janeiro: janeiro edgetpu initialized. Build:
  052da7097-dirty`, then `Powering down`. The probe logs a backtrace through
  `edgetpu_register_irq` (dmesg, ~27.3 s) and `/dev/janeiro` never appears, so
  the IRQ registration is where to look next. `1cc40000.sysmmu` is present.

Also learned the hard way, and worth keeping: `bin/omamobile push` reuses
`$KERNEL_OUT/images` when it exists, so a kernel rebuild alone changes nothing on
the phone -- delete that directory after building. `bin/omamobile initramfs`
needs a writable `$WORK` (it defaults to `$HOME/android`, which is root-owned
here), and `make modules_install` skipped depmod in the container, so
`/usr/lib/modules/<release>/modules.dep` had to be regenerated on the phone
(`depmod -a $(uname -r)`) before `modprobe janeiro` resolved its dependencies.
