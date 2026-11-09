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

Status (2026-11-08): **T6 is blocked on the firmware's one-time setup.** The
direct VII path now delivers any payload to the firmware and reads its reply
(U117), but every command before the setup is rejected as `type 0`; the
element-code and 32-slot scalar sweeps are ruled out, and the only setup
producer is the stripped Tachyon core. The CPU/GPU benchmark is measured
(U118); there is no TPU inference number to compare yet.
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

## U37 (2026-11-07): servicemanager's CHECK, and why the SELinux shim never bound

Two findings that explain the whole servicemanager failure.

**The abort message was invisible.** gdb cannot unwind bionic here ("previous
frame identical ... corrupt stack?"), and libbase's `DefaultAborter` only hands
the string to the crash reporter. Interposing `android_set_abort_message()`
(`tools/android-abort-msg.c`) prints it:

    ABORT-MSG Check failed: selinux_status_open(true) >= 0
    ABORT-MSG Check failed: nullptr == IPCThreadState::self()->getServingStackPointer() ...
      Did not get context from PID N. We should always get contexts from other processes.

**The SELinux shim never interposed.** `nm -D` on the vendor libselinux shows
`getpidcon@@LIBSELINUX_R`, `selinux_status_open@@LIBSELINUX_R` and so on: every
entry point is versioned, and the dynamic linker will not let an unversioned
LD_PRELOAD definition satisfy a versioned reference. So `tools/android-selinux-allow.c`
was loaded (its SELINUX-SHIM marker printed) and still every call went to the
real libselinux, which needs selinuxfs and this kernel has none. Building the
shim with `tools/android-selinux-allow.map` (`LIBSELINUX_R { global: *; };`)
gives its definitions the same version; `nm` now reports
`getpidcon@@LIBSELINUX_R` on the shim too. Patching the chroot's
`libselinux.so` (`selinux_status_open` -> `mov w0,#0; ret`) also fixed the first
CHECK and the original is kept as `libselinux.so.orig`.

What remains is the second CHECK: servicemanager calls its access check with no
serving transaction (`getServingStackPointer()` null, so `getCallingPid()` is 0
and there is no peer context), and aborts. That is servicemanager's own startup
path, not a client's call, so the next step is either the flag/argument that
makes the AIDL servicemanager skip access checks, or a patch of that CHECK in
the chroot's `system/bin/servicemanager` (private chroot, never committed).

Measured alongside: `secctx` failures stay at 0, tachyon stays alive
(`tachyon pid: 6981`), and the vendor service's `addService` returns
`0xffffff7f` (`-129`, EX_TRANSACTION_FAILED) exactly because servicemanager had
just died.

## U38 (2026-11-07): the access check is not a servicemanager variant problem

The vendor image ships its own context manager (`vendor/bin/vndservicemanager`,
78 KiB), so the obvious next try was to run that instead of the system one. With
the chain processes killed first, it starts and survives:

    vsm=8575

and then dies as soon as the vendor service registers:

    ABORT-MSG Check failed: nullptr == IPCThreadState::self()->getServingStackPointer()
      ... Did not get context from PID 8594. We should always get contexts from other processes.
    ABORT-MSG Check failed: status == STATUS_OK      (the vendor service, after it)

So both context managers abort on the same client call: it is the transaction
that lacks something, not the binary. `getServingStackPointer()` is nullptr and
`getCallingPid()` is a real pid, i.e. servicemanager is inside a transaction but
libbinder does not consider it to be serving one - which is what the
security-context bookkeeping feeds.

Our binder patch made that worse by dropping the context entirely: a node
published with `FLAT_BINDER_FLAG_TXN_SECURITY_CTX` then gets a plain
`BR_TRANSACTION` with no context at all. The driver now hands out a fixed label
(`u:object_r:system:s0`, a static string, never freed - `security_release_secctx()`
only frees when an LSM that implements it is enabled) so the transaction keeps
the shape libbinder expects. Rebuilt as
`7.3.0-rc6-omamobile-push1-g<synthetic-secctx>`; result in U39.

Two operational notes: `pkill -f` with a pattern that also appears in the remote
command line kills the ssh session mid-command (exit 255, no output), so match
with `pkill -x` on the 15-character `comm`; and killing the chain in the right
order matters, because a leftover tachyon service keeps reconnecting to
servicemanager and triggers the same abort.

## U39 (2026-11-07): the synthetic context works; VINTF is the next gate

Pushed the build with the fixed context (`uname -v` `Sat Nov 7 16:40:07 UTC 2026`)
and ran the chain. Servicemanager no longer aborts - the log shows the label
arriving and the registration being decided on its own merits:

    Caller(pid=4200,uid=0,sid=u:object_r:system:s0) Could not find
      com.google.edgetpu.IEdgeTpuVendorService/default in the VINTF manifest.
      No alternative instances declared in VINTF.
    registerLazySer 00000000fffffffd000
    [] registerLazyService took 2 milliseconds.
    [] Check failed: status == STATUS_OK

So `getServingStackPointer()`/context is settled (U38), and registration fails
with status `-3` because servicemanager validates every registration against the
VINTF manifests, and the chroot has none it can parse (`NULL VINTF MANIFEST!:
device` / `framework`). The chroot was extracted from a factory image; the VINTF
manifests live in `vendor/etc/vintf` and `system/etc/vintf` on the device, and
they are what lists the Google TPU interfaces. Next: assemble a manifest for the
chroot that declares `com.google.edgetpu.IEdgeTpuVendorService/default`,
`com.google.edgetpu.IEdgeTpuAppService/default` and whatever tachyon registers,
then run the chain again.

Also worth keeping: with the abort gone, `tachyon pid: 4337` stays up across the
whole attempt, and the Darwinn HAL's only complaint is that nobody ever published
`com.google.edgetpu.IEdgeTpuAppService/default`.

## U40 (2026-11-07): VINTF schema, and the last two deaths

The device manifest has to be installed as `vendor/etc/vintf/manifest.xml` in the
chroot (`device/cheetah/tpu-vintf-manifest.xml` in the repo). The schema detail
that cost the most: for an AIDL HAL, `<name>` is the AIDL **package** and each
`<fqname>` is an interface and instance inside it. Writing the interface name in
`<name>` (the obvious reading) yields a manifest that parses and answers for the
other entries while every lookup for that package fails:

    Could not find com.google.edgetpu.IEdgeTpuVendorService/default ... No alternative instances declared

With package-scoped entries every lookup succeeds and the chain registers:

    Found com.google.edgetpu.IEdgeTpuVendorService/default in device VINTF manifest.
    registerLazySer 0000000000000000000      (the vendor service)
    [] registerLazyService took 2 milliseconds.
    registerLazySer 0000000000000000000      (the tachyon service)

What is left is one death each side of that registration:

* vendor service: registers, prints `Starting cache cleanup.`, then SIGABRT;
* Darwinn HAL: `Non-ok status from HAL: 2` right after it lands, then SIGTRAP;
* servicemanager and the tachyon service stay up throughout, and tachyon's
  service name is `com.google.edgetpu.tachyon.IComputeService/default` (that is
  why the manifest entry is scoped to `com.google.edgetpu.tachyon`).

So the transport is finally healthy and the remaining failures are inside the
vendor binaries, where the abort-message shim (`tools/android-abort-msg.c`) and
the runner's per-service logs are the tools: the vendor service's abort text is
not in the filtered log tail yet, and `status 2` from the HAL is
`android::base::Error`-style, i.e. its own check rather than binder's.

## U41 (2026-11-07): the chroot needs /data/vendor, and the HAL names its provider

Both deaths were missing path state, not protocol. The Darwinn HAL said it
plainly:

    INTERNAL: Socket server bind failed:
      /data/vendor/hal_neuralnetworks_darwinn/NnapiHalSocketHalProcess errno [No such file or directory]

The chroot had no `/data` at all. After `mkdir -p` of
`data/vendor/hal_neuralnetworks_darwinn`, `data/vendor/edgetpu` and
`data/edgetpu` (writable), the HAL gets past the socket and reports the next
thing it cares about:

    INVALID_ARGUMENT: Incorrect driver provider is used for the current device.
    file.cc:397  (status 4)

That is a real, nameable condition: the HAL picks a driver provider (PCIe vs.
platform, or a board-specific one) and does not think this device matches the
one it was built/defaulted for. It is decided inside the binary from device
properties, so the next probe is `strings` on the HAL for the provider names and
the property it reads, then set that property for the chroot's `env`.

The vendor service still aborts one line after `Start cache cleanup.`, and not
through libbase: no `ABORT-MSG` appears, so it is a libc++ `__libcpp_verbose_abort`
or a direct `abort()`, and the next tool is gdb with `catch signal SIGABRT` on
that binary alone (the chroot is private, so running it under gdb is fine).

Where this leaves the chain: servicemanager up, vendor service registering and
dying in its cache cleanup, tachyon service up, Darwinn HAL dying on its driver
provider. `/dev/janeiro` and janeiro's probe are not in question any more.

## U42 (2026-11-07): userspace reaches the driver; the TPU does not answer

There was no Edge TPU model anywhere in the tree and the compiler is x86-64 only,
so the first thing to build was the model. Coral publishes the compiler as a
self-contained bundle in its own repository (`compiler/x86_64/`: the binary plus
its own `ld-linux` and libc++), which runs on any x86-64 Linux without apt:

    /tmp/ecx/ld-linux-x86-64.so.2 --library-path /tmp/ecx /tmp/ecx/edgetpu_compiler \
        out/bench/detect.tflite
    Number of Edge TPU subgraphs: 1
    Number of operations that will run on Edge TPU: 63   (of 64)

That produced `detect_edgetpu.tflite` (4.65 MB). Feeding it to the stock runtime
inside the chroot (`/vendor/bin/edgetpu-run`, which drives `libedgetpu_util.so`
directly and needs no servicemanager) gets much further than the service chain
ever did:

    mmap fd -1 len 0x40000 off 0x0 -> 0xfffdc2809000   (x3)
    E0000 file.cc:163] INTERNAL: Could not finalize device group:
        master_fd=3 (Connection timed out)
    create device status: 13

So the whole userspace path now works: the runtime opens `/dev/edgetpu`
(`/dev/janeiro`, char 502:0, janeiro loaded), maps the buffer pools, and issues
the device-group finalize the driver forwards to the TPU. What times out is the
TPU's own response.

Where to look next is the driver, not the chroot:

* `edgetpu_platform_setup_irq()` (`drivers/edgetpu/edgetpu-mobile-platform.c`)
  requests each DT irq with `IRQF_ONESHOT` and logs `failed to request irq`;
  a missing/incorrect irq in `tpu-enable.dtso` would leave every completion
  unanswered, which is exactly a finalize timeout.
* janeiro logged a WARN inside `edgetpu_device_add` -> `edgetpu_register_irq`
  at boot on this kernel; the earlier splat is no longer in `dmesg` (it was
  captured in the runner's kmsg copy), so a fresh boot with the splat quoted is
  the next evidence to collect.
* janeiro also prints `Powering down` immediately after `edgetpu initialized`,
  which is worth reading as "the block was never brought out of reset".

The direct-runtime route also removes any need for the vendor service chain for
a first inference: `/vendor/bin/edgetpu-run` is the shortest path to the driver,
and the servicemanager/VINTF work (U37-U41) is what the NNAPI HAL path needs
later, for the benchmark against other backends.

## U43 (2026-11-07): the power-up path is the blocker, and it says so

`edgetpu-run` against the compiled model made the driver try to bring the TPU up,
and dmesg names every step:

    WARNING: drivers/iommu/iommu.c:2061 at iommu_set_fault_handler
      lr : edgetpu_mmu_alloc_domain+0xa0/0x134 [janeiro]        <- iommu_set_fault_handler
      edgetpu_device_group_alloc -> edgetpu_ioctl_create_group
    edgetpu_platform 1ce00000.janeiro: Initial power state: 226000
    edgetpu janeiro: Powering up
    edgetpu janeiro: Set LPM0 failed: -110
      (PSM0_STATUS=0x5644c13 PSM1_STATUS=0xe893 LPM_CONTROL=0x1240
       AON_RESET=0xdeadfeed AON_CLK=0xdeadfeed AON_QUIESCE=0xdeadfeed
       POWER_CONTROL=0xdeadfeed GSA state=0)
    edgetpu janeiro: firmware handshake failed: -110
    edgetpu janeiro: Powering down
    edgetpu janeiro: finalize group: power on failed: -110

Read together: `janeiro_lpm_up()` (`drivers/edgetpu/janeiro-pm.c`) writes
`PSM0_START` and polls `PSM0_STATUS` for bit 0x80 with a 30 ms timeout. The poll
fails (-110), and every AON register in the diagnostic prints the same
`0xdeadfeed`, i.e. the AON half of the TPU block is not answering at all, while
the PSM registers (`0x1c1888` etc.) do. `GSA state=0` means the GSA mailbox has
not started the AON domain either, and the firmware handshake then times out
because nothing is running. So this is the TPU's AON power/clock bring-up, not
the IOMMU, not the userspace chain.

Two candidate causes, in order:

1. the AON registers are reached through a different resource than `regs.mem`
   (`reg = <0x1CE00000 0x200000>, <0x1CCF0000 0x10000>` in `gs201.dtsi`, names
   `"tpu"` and `"ssmt"`), and the vendor DT may carry an extra region for the AON
   block that this node lacks;
2. the AON domain must be started through GSA (`gsa_send_tpu_cmd(...,
   GSA_TPU_START)`) before its registers answer, and the mainline path only
   starts it after LPM0 succeeds - a chicken-and-egg that stock resolves by
   letting GSA own the power-up.

The iommu WARN is a separate, smaller issue: `edgetpu_mmu_alloc_domain()` calls
`iommu_set_fault_handler()` on a domain the mainline IOMMU API does not support
for that, and the warning is benign for this failure (the group is created, then
the power-on fails).

## U44 (2026-11-07): ACPM does set the TPU state; PSM0 is what never comes up

The driver's own debugfs (`/sys/kernel/debug/edgetpu/power/`) answered the ACPM
question without a rebuild:

    before: state=0        min=0  policy=1066000
    after writing 226000:  state=226000  core=226000  ctl=226000

So the ACPM shim (`drivers/edgetpu/edgetpu-acpm.c`) is fine: the TPU DVFS domain
takes the request and reports it back. What does not happen is the block coming
out of reset - `PSM0_STATUS=0x5644c13` has bit 0x80 clear, so `janeiro_lpm_up()`
polls until the 30 ms timeout, and the AON registers still read `0xdeadfeed`
while the PSM ones at 0x1CFCxxxx read real data.

Pre-setting the state through debugfs and running again changes the failure and
confirms the ordering:

    finalize group: power on failed: -11      (was -110)
    "is_block_down" loop exhausted: the driver insists on seeing the block
    down before a cold power-up, and a pre-set state refuses that

So the cold sequence is: ACPM state -> TPU_OFF -> (block down confirmed) -> ACPM
state 226000 -> PSM0 start -> firmware. The break is at the PSM0 start: the TPU
core does not acknowledge, which is why GSA's image load and `GSA_TPU_START`
(cmd 1) are followed by `firmware handshake failed: -110`.

Next candidates, narrowest first: the PSM0_CFG value the vendor driver writes
before start (mainline writes it only after LPM0 succeeds), the AON clock enable
(ACPM or the `aon` clock in the DT), and whether the vendor node carries extra
regions or a `power-domains` link that our `janeiro@1ce00000` lacks. The vendor
DT capture is not on this laptop (`~/android/reference` is empty), so the next
run needs it from the phone's stock slot or the factory image.

## U45 (2026-11-07): the node major is dynamic; the PSM reorder did not help

Two findings, one of them a trap that had been masking the other.

**The device node must come from sysfs.** `/sys/class/edgetpu/janeiro/dev` read
`501:0` this boot, while the chroot (and the host) carried a hard-coded node
`502:0` from an earlier boot. With the wrong major every ioctl returns `ENOTTY`
("Could not create device group ... Inappropriate ioctl for device"), which reads
like a driver bug but is a node bug. Create `/dev/janeiro` from that sysfs value
at every start and symlink `/dev/edgetpu` to it; the runner should do the same
instead of `ln -sfn janeiro /dev/edgetpu` only.

**With the right node, the group is created and the mailbox works.** The driver
logs its ioctl round trip and then, while the client holds the device, the TPU
mailbox interrupts arrive:

    ioctl fd 3 req 0x4014ed06 -> 0
    ioctl fd 3 req 0x4008ed05 -> 0 event_id 0 efd 4
    edgetpu janeiro: irq 163 idx 0 mailbox ffff00081a28c240 status 1   (repeating)

So the irq wiring and `edgetpu_register_irq()` are fine, and the AP/TPU mailbox
path carries interrupts. What still fails is the power-up before the handshake:

    edgetpu janeiro: Set LPM0 failed: -110 (PSM0_STATUS=0x5644c13 ... AON_RESET=0xdeadfeed
      AON_CLK=0xdeadfeed AON_QUIESCE=0xdeadfeed POWER_CONTROL=0xdeadfeed GSA state=0)
    edgetpu janeiro: firmware handshake failed: -110

**The PSM0_CFG-before-PSM0_START reorder did not change it.** `janeiro_lpm_up()`
now writes `PSM0_CFG`/`PSM1_CFG` before starting either PSM (matching the vendor
order), rebuilt and pushed as module srcversion `713ADC800D632B5AEF88A1D`; the
timeout and the `0xdeadfeed` AON reads are identical. So the missing piece is not
the PSM configuration order but the AON island itself: its clock/power enable.

Operational note: a client that hangs on the 60 s timeout keeps the device and
the TPU in a half-powered state, and stray `edgetpu-run` processes keep the irq
line busy; kill them by exact name before each attempt.

## U46 (2026-11-07): the janeiro node has no clocks or power domains at all

The decisive structural finding came from one `ls` of the live tree:

    /sys/firmware/devicetree/base/janeiro@1ce00000/
      clocks:            absent
      power-domains:     absent
      samsung,acpm-ipc:  absent
      reg:               absent      (reg is present as an unnamed property)

Our `janeiro@1ce00000` carries `reg`, `interrupts`, `iommus`, `memory-region`,
`gsa-device` and the DVFS table, but **no `clocks` and no `power-domains`**. Every
AON register reading `0xdeadfeed` is exactly what an unclocked island returns, so
this is the missing link rather than a subtlety of the PSM sequence: the driver
asks ACPM for a DVFS state, which works, but nothing in the DT lets Linux (or the
TPU's own AON block) gate its clock, and the PSM0 acknowledge never comes.

The stock node is the source of truth and it is on the phone: `dtbo_a` is
`/dev/sda14` (`dtbo_b` is `/dev/sda24`). Reading it is read-only and safe; the
node in it lists the real `clocks`, `power-domains` and any extra regions, and
those properties are what `tpu-enable.dtso` and `gs201.dtsi` need.

Also fixed this round: the runner derived `/dev/edgetpu` only by symlink, so a
stale node major silently broke every ioctl (U45). `/root/tpu-tachyon-run` now
reads `/sys/class/edgetpu/janeiro/dev` and creates the node from it at every
start.

## U47 (2026-11-07): the TPU node is not in dtbo_a

Read `dtbo_a` (`/dev/sda14`) read-only and parsed it: an Android DTBO image
(magic `d7b7ab1e`) with the embedded FDT at offset 0x800. Its strings list
fragments for the camera, `gsa_gsc`, `st21nfc` and friends, and **no janeiro or
TPU fragment at all**. So the stock TPU node is not an overlay: it lives in the
stock *base* DTB, which is why `tpu-enable.dtso` had to invent the node in the
first place.

That also means the missing `clocks`/`power-domains` (U46) must be recovered from
the base DTB, not from `dtbo_a`. The base DTB partition is the next read (the
partition list on the phone gives the name; `dtb`/`dtb_a` rather than `dtbo_a`).
`dtc` is not installed on the laptop, so parsing needs the project container's
`dtc`/`fdtdump`, or a small FDT reader; the strings scan is enough to confirm the
node and the names of its `clock-names`/`power-domain-names` values.

## U48 (2026-11-07): the stock DTB is not a plain FDT in boot_a or vendor_boot_a

Read both stock partitions read-only and searched them for an FDT header:

    /dev/sda10 boot_a       64 MB   fdt magic: none   "janeiro": 0
    /dev/sda12 vendor_boot_a 24 MB  fdt magic: none   "janeiro": 1

`boot_a` is an Android boot image (its kernel payload is compressed, and gs201
keeps the DTB in `vendor_boot`), and `vendor_boot_a` carries the string "janeiro"
exactly once - the single base-DTB reference - but not as a plain FDT at any
offset in the first 24 MB. So the node has to be reached through the vendor_boot
container: unpack the boot-image header (vendor ramdisk + dtb section), then
`dtc`/`fdtdump` the section. `dtc` is not installed on the laptop; the project
container has one, and `unpack_bootimg`-style parsing of the header (page size,
vendor ramdisk size, dtb size) is enough to locate it without any Android tool.

So the sequence to close this is fully specified now: unpack `vendor_boot_a`'s
DTB section, read `janeiro@1ce00000`'s `clocks`/`power-domains`, add what the
mainline tree lacks to `gs201.dtsi` (or a bring-up overlay), then re-test with the
sysfs device node. Nothing about the TPU's blocker is unknown any more; it is one
DTB read and one DT edit away.

### U48 addendum: the whole 64 MB partition has no FDT header

Read `vendor_boot_a` end to end (all 64 MB, not just the first 24 MB) and searched
for the FDT magic: **zero occurrences**. So the stock DTB is not stored as a
plain flattened tree anywhere in that partition either; it is inside the
vendor_boot payload (compressed kernel/vendor ramdisk or the DTB section of a
boot-image header this scan did not walk), and reading it needs a real
boot-image unpacker rather than a magic scan. That is a laptop-side step with the
project container's tooling or an `unpack_bootimg`-style parser, not something to
iterate on the phone.

## U49 (2026-11-07): the vendor node is identical - GSA is what starts the TPU

Fetched Google's own gs201 TPU device tree (`arch/arm64/boot/dts/google/
gs201-tpu.dtsi` from the public GPL kernel tree) and compared it with ours. The
properties are the same set, and the important part is what it does **not** have:
no `clocks`, no `power-domains`, exactly like our node. So U46's "DT gap" reading
was wrong - the node is not supposed to carry them. Stock's TPU is brought out of
reset by the GSA, not by a Linux clock/PM-domain link.

That lines up with our own log, which had been read as noise:

    google-gsa 17c90000.gsa: loading TPU image: header 0x82e63000 body 0x93000000
    google-gsa 17c90000.gsa: TPU cmd 1 (Trusty): 2      <- GSA_TPU_START result

The image load is attempted and `GSA_TPU_START` (cmd 1) comes back **2**, i.e.
not success; the TPU therefore stays in reset, `PSM0_STATUS` never reports 0x80,
every AON register reads `0xdeadfeed`, and the firmware handshake times out. The
PSM/ACPM work in U44/U45 was chasing a consequence: with GSA refusing to start
the core, no register sequence can bring it up.

So the next target is `drivers/soc/google/gsa.c`'s Trusty path for the TPU
commands (`gsa_send_tpu_cmd()` and the firmware load/unload helpers) and what
result 2 means there - a Trusty service that is not present, a wrong command id,
or a rejected image - rather than any device-tree property.

### U49 correction: `2` is GSA_TPU_STATE_RUNNING, not an error

`gsa_send_tpu_cmd()` returns the **new TPU state**, and the enum is
`INACTIVE=0, LOADED=1, RUNNING=2, SUSPENDED=3`. So the boot log line

    google-gsa 17c90000.gsa: TPU cmd 1 (Trusty): 2

means `GSA_TPU_START` **succeeded** and the GSA reports the TPU running (the
shutdown that follows logs `TPU cmd 4 (Trusty): 1` = LOADED, also correct). U49's
"GSA refuses to start" reading was wrong; the Trusty path is not a stub in this
build (that stub is the `#else` branch for `CONFIG_GOOGLE_GSA=n`).

The real order, from one failing attempt:

    723.167 Powering up
    723.197 Set LPM0 failed: -110        <- janeiro_lpm_up, before firmware
    723.198 loading TPU image: header ... body ...
    723.203 TPU cmd 1 (Trusty): 2        <- GSA started the core
    724.224 firmware handshake failed: -110
    724.229 Powering down

So the core *is* started by GSA, and what fails is the driver's own LPM0 check
(which runs before the firmware load and returns -110 immediately) plus the KCI
handshake afterwards. Since `Set LPM0 failed` is what aborts `mobile_power_up`,
the PSM0 poll is the gate to fix first - and it is being run before the GSA has
started the core, which is exactly why it cannot succeed. The vendor order starts
the firmware first; ours polls PSM0 first.

### U49 second correction: `lpm_up` is not fatal; the -110 is the firmware handshake

Read `mobile_power_up()` again: `platform_pwr->lpm_up(etdev);` is called with its
result **ignored**, so a failed PSM0 poll cannot abort anything. The `-110` that
ends the attempt comes later, from the firmware restart path, which logs
`firmware handshake failed: -110` and then calls `mobile_power_down()`.

So the chain is: ACPM state ok -> `lpm_up` poll fails (logged, ignored) ->
`edgetpu_chip_init` -> GSA loads the image and `GSA_TPU_START` returns 2
(RUNNING) -> `edgetpu_firmware_restart_locked()` waits for the firmware's KCI
handshake and gets nothing -> `-110` -> power down.

That makes the KCI handshake the thing to debug, with two candidate causes: the
PSM0/LPM0 failure is not cosmetic after all (the core may be running with its
AON island unclocked, so it cannot answer), or the wait is on a mailbox that the
mainline driver has not configured the way the vendor runtime expects. The
`dmesg` already shows the mailbox interrupts arriving (`irq 163 idx 0 ... status
1`) when a client holds the device, so the AP side of the mailbox is alive.

Next measurement: enable the driver's own debug (`edgetpu.debug` /
`CONFIG_EDGETPU_DEBUG`) and watch the KCI send/receive around
`firmware handshake failed`, and read `kci_send`/`fw_tracing` in
`/sys/kernel/debug/edgetpu/janeiro/`; that separates "firmware never answers" from
"driver never sends".

## U50 (2026-11-07): `lpm_up` is the KCI handshake gate

The 2026-11-07 boots failed at `KCI timeout code 11 ... head 0 doorbell 0` while
GSA reported `TPU cmd 1 (Trusty): 2` (RUNNING), so the core was started but the
firmware never consumed a command. The intermediate builds had removed
`platform_pwr->lpm_up(etdev)` from `mobile_power_up()` on the theory that a
PSM0 start before `GSA_TPU_START` wedged the AON island.

That theory is wrong, and the T4-working module proves it. `/root/janeiro-bootstock.ko`
(`srcversion 5121F420…`, built for `g29a7a9326bf0`) was loaded on the current
`g052da70970d6` kernel after patching only its `vermagic` hash (both are the same
length, `CONFIG_MODVERSIONS` and `CONFIG_MODULE_SIG` are off). As the first TPU
access of a cold boot it still completes the handshake:

    Powering up
    TPU cmd 0 (Trusty): 0
    loading TPU image: header 0x82e3e000 body 0x93000000
    TPU cmd 1 (Trusty): 2
    loaded prod firmware (1.0 895567958)

and its `mobile_power_up` disassembly contains the indirect call our tree had
deleted (`ldr x8, [x19, #0x398]; blr x8`, the `platform_pwr->lpm_up` pointer),
while the failing module jumps straight to `edgetpu_chip_init`. Google's
original `mobile-pm.c` has exactly that call before `edgetpu_chip_init`; our
port had removed it.

So the cold-boot order is the vendor order: ACPM state → `lpm_up` (PSM0/PSM1
start, `LPM_CONTROL` = `0x1240`) → `edgetpu_chip_init` (GSA load and
`GSA_TPU_START`) → KCI handshake. GSA starts the core either way, but without
the LPM state machines the firmware never reads the KCI queue. The earlier
`Set LPM0 failed: -110` runs were warm boots (GSA state LOADED / PSM already
wedged), not evidence about a cold start.

Also measured this round, read-only: the KCI queues live in the TPU carveout
(`cmd tpu=0x10150000`, `resp tpu=0x10158000`), and at the timeout the command
queue head and the response doorbell are both 0, i.e. the firmware had not
taken the element. A diagnostic build that added reads of
`EDGETPU_REG_CPUNS_TIMESTAMP`/`RESET_CONTROL` (0x1a00e0 / 0x190010) to the
post-start dump reset the phone during the power-up; those reads were removed
and the reset did not recur. The dump keeps only the previously safe PSM/AON
reads.

## U51 (2026-11-07): the firmware runs; only its one-time setup command is missing

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, `janeiro` srcversion
`B651879D4EDBABC691FA642`, one true power cycle per attempt.

**The KCI fix is confirmed.** Restoring `platform_pwr->lpm_up(etdev)` in
`mobile_power_up()` (U50) gives the full cold-boot sequence:

    TPU cmd 0 (Trusty): 0
    loading TPU image: header 0x82e3e000 body 0x93000000
    TPU cmd 1 (Trusty): 2
    loaded prod firmware (1.0 895567958)
    power-up ok: PSM0_STATUS=0x4b27091 LPM_CONTROL=0x148 POWER_CONTROL=0x54

and every KCI command the driver sends is answered (codes 2, 5, 7, 9, 10, 21).
The group create/finalize path is complete: `OPEN_DEVICE ret 0`,
`kci_finalized ret 0`, `mailbox_attached 1`, and the VII IRQ fires.

**The one remaining gate is the firmware's setup command.** Every client (the
direct runtime, the stock delegate as root, and the stock delegate as uid 10000
through the Tachyon service) submits the same first VII element and gets:

    ERR vii_handler_layer.cc:247 - Setup is not done yet received a command of type 0.
    vii-elem: ... 000b0000 ... ffeff000 ... 0x80 ...   (type 0, priority 11, dma 0xffeff000/0x80)

with the same 128-byte flatbuffer payload at `0xffeff000` (U3). Response
`0xf000009`, error 9.

This round ruled out the cheap fixes:

- **Forcing the runtime's setup call changes nothing.** `libedgetpu_util.so`
  skips it at `0x13c2ec` (`ldrb w8,[x20,#0x130]`; `tbnz w8,#0,0x13c2fc`;
  `bl 0x227918`). Patching the load to `mov w8, wzr` and running the client
  produced a byte-identical first element, so the call is not the VII setup (U15:
  setup is a Tachyon message with a cluster bitset and global scratches).
- **The stock service chain is up but incomplete.** servicemanager runs; the
  vendor service registers `com.google.edgetpu.IEdgeTpuVendorService/default`
  and then SIGABRTs one line after `Start cache cleanup` (no ABORT-MSG; a libc++
  abort, needs gdb). The tachyon service stays up; the Darwinn HAL still dies on
  `Incorrect driver provider` (U41). The app-uid delegate reaches the driver
  (`OPEN_DEVICE ret 0`, finalize, same VII element) after fixing two real
  bring-up bugs: `chmod 666 /dev/dma_heap/system` (it died on
  `Failed to open DMA-BUF heap: Permission denied`) and the writable
  `/data/vendor/{hal_neuralnetworks_darwinn,edgetpu}` and `/data/edgetpu`
  directories. Both are now in `tools/tpu-tachyon-run`.
- `RUN_UID=10000` is required for the Tachyon client path (U34); as root the
  util library always goes direct.

**Next, in order:**

1. Make the Tachyon session's setup run before the delegate's first sync:
   `TachyonComputeSession::SetupCommandFmq` / `SetupResponseFmq` in
   `libedgetpu_tachyon.google.so`, `firmware_setup_done_` and its wakelock
   `RegisterCallbackPair` in `libedgetpu_util.so`, and
   `TachyonComputeSession_setupCommandQueue` (exported, U15). The service that
   owns `/dev/edgetpu` must send the setup message with the global scratches
   (the firmware strings: `No global scratches were provided in setup command.`).
2. Fix the vendor service abort and the HAL driver-provider property (U41); the
   HAL is the stock path that builds the setup command.
3. If the service remains unusable, reproduce the setup message bytes with
   `tools/edgetpu-run.c`'s `scratch_mode`/`mapped` and send them to the VII
   queue, watching for `No global scratches were provided` (type accepted) or
   `Setup is already done` (setup ran).

Once setup is accepted: register `detect_edgetpu.tflite`, run one inference,
then the 720p benchmark against the recorded CPU baseline (x86 XNNPACK t4
3.98 ms/frame, 10 detections/frame at threshold 0.4) and the phone's CPU/GPU
backends.

## U52 (2026-11-07): the vendor service was aborting on a missing cache dir; the provider check is the next gate

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`. This round was
userspace-only; the TPU was not powered (no new `janeiro` PM log after 44.8 s).

**The vendor service abort is fixed.** It was not a libc++ mystery: `CacheCleanup`
walks `/data/vendor/edgetpu/cache/`, which did not exist, so it aborted
immediately after `Start cache cleanup.`. With the directory present:

    [] Start cache cleanup.
    [] Cache cleanup is done.
    [libbinder.AidlLazyServiceRegistrar] Registering service com.google.edgetpu.IEdgeTpuVendorService/default
    [] registerLazyService took 2 milliseconds.

and the process stays up. `tools/tpu-tachyon-run` created that directory only
just before the delegate, after the vendor service had already started and died;
the dma-heap chmod and all `/data` directories now run before servicemanager and
the services.

**The app-uid delegate was not using the client path.** udev leaves
`/dev/janeiro` 0666, so uid 10000 opened the driver directly; the runner's
comment said EACCES selects the client path but nothing enforced it. The runner
now `chmod 600 /dev/janeiro`; the services run as root and still open it, while
the delegate must go through the Tachyon/app service.

**The `ld.so ... cannot be preloaded` lines are the host's glibc `chroot`, not
the Android linker.** The Android linker inside loads the shims
(`SHIM-LOADED`, `SELINUX-SHIM`, `LAZYSVC-SHIM registerLazyService`). No fix is
needed; earlier notes that treated these as load failures were wrong.

**servicemanager is not supervised.** Once it was gone, the vendor service got
`DEAD_OBJECT` on `registerLazyService` and CHECK-failed (`status == STATUS_OK`),
and the HAL spun on a missing `/dev/vndbinder` context object. Restart
servicemanager before the chain (the runner does).

**The property shim now builds and answers `ro.board.platform`.**
`clang --target=aarch64-linux-gnu` needs `-fuse-ld=lld`; the host `ld` has no
aarch64 emulation. The shim's default is now `mmio` (`-DPLATFORM_VALUE=...` for
another). `DarwinnApi2_PlatformTypeFromString` (util `0xf8a28`) and
`DarwinnApi2_ChipFamilyFromString` (`0xf8ab4`) both go through one helper
(`0xf8b74`) that compares immediates, not string literals: the accepted
platform values are `mmio`, `reference`, `simulator` and `remote_simulator`
(lengths 4, 9, 9, 16). `gs201` is not one of them.

**Still the gate: `Incorrect driver provider is used for the current device`
(`libedgetpu_util.so` 0x66f18; HAL `file.cc:162`/`397`).** It happens before
any `/dev/edgetpu` ioctl (no new dmesg) and with both `ro.board.platform=mmio`
and `gs201`, so it is not that lookup. The HAL loads the util dynamically; the
check compares the device resource's provider/platform type with
`JaneiroDriverProvider` and rejects it. The next step is the call site of the
error string (find the `adrp/add` for `0x66f18` and the compared value) and the
vendor service's `EnumeratePhysicalResources`, plus the missing top-level
`/vendor/etc/vintf/manifest.xml` (`NULL VINTF MANIFEST!: framework`).

The phone is left up, TPU powered down, servicemanager restarted, vendor and
HAL processes stopped. A full-chain test still needs one cold boot.

## U53 (2026-11-07): the service chain is unstable; the provider check is not the platform property

The vendor service fix from U52 holds: with `/data/vendor/edgetpu/cache/` present
it registers and stays up. Two new facts.

**servicemanager segfaults while serving the chain.** A fresh one registers the
vendor service, then dies:

    libc: Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 9891 (servicemanager)
    sm before: (empty)

so the "reference"/"mmio" HAL runs that follow a dead servicemanager are
inconclusive (the vendor service gets `DEAD_OBJECT` and CHECK-fails). The
top-level VINTF manifest is still missing (`NULL VINTF MANIFEST!: framework`),
and the property shim's `__system_property_find` returns a fake `prop_info` for
every name; either can be the crash. Fix/stabilise servicemanager before judging
the provider check.

**The HAL's provider check survives every property value tested.** With a fresh
servicemanager, a registered vendor service and `ro.board.platform` set to
`mmio`, `gs201` and `reference`, the HAL still logs
`INVALID_ARGUMENT: Incorrect driver provider is used for the current device`
(`file.cc:162`/`397`) and exits with SIGTRAP, before any `/dev/edgetpu` ioctl
(no new `janeiro` dmesg). So either the shim does not interpose for the HAL's
property calls (the HAL links its own libcutils/libbase), or the value is not the
input to this check.

The util path to the error is now mapped: `0x107788: b.ne 0x107970` when the
cached getter at `0x2240d4` returns something other than 1. `0x2240d4` reads
`ro.board.platform` through `0x224a70` and calls `0x22403c`, which is a small
hash/character-class switch (returns 0-6 from `x0 & 0x7f` after `0x224268`), not
`DarwinnApi2_PlatformTypeFromString`. The `PlatformTypeFromString` immediates
are `mmio`=0, `reference`=1, `remote_simulator`=2, `simulator`=3; the error
path is not that parser. Next: disassemble `0x224268` and the HAL's
`GetDarwinnHalFunctions`/`EdgeTpuServiceAppConnector::GetEdgeTpuFd`, and check
whether the shim interposes versioned `__system_property_get`/`find` in the HAL
(build a tiny client that prints `ro.board.platform` and `ro.build.version.sdk`).

Phone state: up; servicemanager restarted; vendor/HAL stopped; TPU powered down.
The default `mmio` shim is restored in `/root/libpropsshim.so` and the chroot.

## U54 (2026-11-07): the provider gate is bypassed; the HAL reaches the TPU

`libdarwinn_hal.so` `0x1569ae0` is the driver-provider getter. It must return 1
for the on-device provider; `AbrolhosDriverProvider` checks it at `0x14b6368`
(`cmp w0, #1; b.ne "Incorrect driver provider is used for the current
device."`). Patching the getter to `mov w0, #1; ret` (dev-only; backups
`out/vendor-chroot-edgetpu/root/vendor/lib64/libdarwinn_hal.so.orig` and
`/root/libdarwinn_hal.so.orig`) removes the error.

With the patch, servicemanager + vendor service + HAL ran past the check:
`Non-ok status from HAL` changed to a real device path:
`edgetpu_ioctl_create_group`, `Initial power state: 226000`, `Powering up`.
It failed only because this boot had already powered the TPU once (the
delegate run at 44 s). The second power-up reproduced the known wedge:
`Set LPM0 failed: PSM0_STATUS=0x5644c13 PSM1_STATUS=0xe893
LPM_CONTROL=0x1240`, KCI timeout code 11, SIGTRAP in the HAL. So the userspace
gate is fixed; a cold boot is required for the first power-up.

Servicemanager notes: it needs the props/selinux/log shims and a **fresh
binderfs**; without the props shim it aborts on `servicemanager.ready`. The
real `liblog.so` is restored; the log shim cannot stand in as `liblog.so`
without versioned symbols. `libedgetpu_util.so` is unpatched.

Next: cold boot, then `/root/tpu-tachyon-run` with `RUN_UID=10000` as the
**first** TPU user; expect `Set LPM0` success (`PSM0_STATUS=0x4b27091`) and
the firmware setup, not `Setup is not done yet`.

## U55 (2026-11-07): the A14 stack sends the pre-Tachyon setup; test it with the A14 firmware

The A14 HAL's `CreateDevice` is the first client seen to run the stock
`SetupFirmware` path against this driver: it creates the group, finalizes,
takes the wakelock, registers two eventfds (event ids 0 and 1), maps its
buffers and submits one `EDGETPU_IOCTL_SYNC` (nr 16) element with `+10`
priority 11, DMA `0xffcff000` and size `0x80`. The driver's payload dump shows
the same 128-byte `RequestAllocation` flatbuffer the A17 runtime sends (root
offset 20, soffset 10, three fields at 8/7/12), and the firmware answers
`Setup is not done yet received a command of type 0` (error 9). The HAL then
logs `Firmware setup failed for commands[0], cluster_id_bitset in hex: 0` and
returns status 2. It is not the setup producer: it sends the pre-Tachyon setup
command, which the A17 firmware does not accept.

The A14 vendor image carries its own `google/edgetpu-janeiro.fw` (985344
bytes, sha256 `145993a4e300c64d95f5d811008062f47c083f17ed649f5c046d44eb23160b21`,
ImageConfig build 2/2; the A17 file is 1038272 bytes, build 2/3). The A14 HAL
is the pair of that firmware, and the A14 setup command (`type 0`) is the one
its gate should accept.

Experiment (development, slot B, cold boot):
1. Back up the A17 firmware to `/root/edgetpu-janeiro-a17.fw` (sha
   `52c1ccc…`), write the A14 file to
   `/lib/firmware/updates/google/edgetpu-janeiro.fw`, verify its sha256.
2. `systemctl poweroff`; the owner presses Power. Expect SSH in about 20 s.
3. `modprobe janeiro` (it is not autoloaded on the Arch root), wait for
   `/dev/janeiro`, then as the first TPU user
   `chroot $R /vendor/bin/tpu-a14-hal`. Pass: `create_device: 0`, `dev 0x…`,
   no `Setup is not done yet` and no `Firmware setup failed`; the firmware
   line names the A14 build.
4. If the GSA refuses the image (no `loaded prod firmware`, a firmware load
   error, or `/dev/janeiro` absent), restore `/root/edgetpu-janeiro-a17.fw`
   and cold boot again.

Rollback: the A17 file over the firmware path, then a cold boot.
Risk: the first A14 attempt's worst case was assumed to be a TPU that does
not come up. The second attempt showed the real worst case: the GSA load
hangs the SoC and the watchdog resets the phone. The A17 file is restored;
the path stays closed.

First result (2026-11-07 19:39): the A14-firmware boot did not load the
module (it is not autoloaded on the Arch root), so that attempt never touched
the A14 image. Second attempt (19:41): with the A14 file in place,
`modprobe janeiro` blocked in the probe and the phone reset by itself at
19:42:26 (uptime 135 s, no pstore, the journal stops without an error line).
The A14 image is not refused with an error: its GSA load hangs the SoC until
the watchdog resets it. **The A14 firmware path is closed on this phone; do
not load it again.** The A17 firmware is restored (sha `52c1ccc…`).

## U56 (2026-11-07): the A17 userspace has no setup producer; the Tachyon core is a stub

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`. One cold boot per
test, TPU used once, `power-up ok: PSM0_STATUS=0x4b27091`.

**The HAL's obsolete setup is skipped, and that works.** `SetupFirmware`
(`libdarwinn_hal.so` 0x14d9a24) starts with `ldarb w8,[x19+0x180]` (its
`firmware_setup_done_` byte) and `tbz w8,#0,0x14d9a6c`; the fall-through is
the stock "already set up" path that returns 1. Replacing that `tbz` at
0x14d9a5c with `nop` (4 bytes, `36000088` → `d503201f`) makes the HAL send
nothing and report success. With it, the HAL's `CreateDevice` creates group
and context 1073741824 at 64.7 s and returns OK: no `Setup is not done yet`,
no `Firmware setup failed`, no `Sync VII command failed` from the HAL. The
provider patch from U54 (0x1569ae0) stays. Phone copy sha
`c04ad3249d3c…`; backups `libdarwinn_hal.so.orig` (stock) and `.provider`
(U54 only) in the chroot, stock also at `/root/libdarwinn_hal.so.orig`.

**The Tachyon service needs the Power HAL.** Its `TachyonCore_CreateClientSession`
first logged `Service android.hardware.power.IPower/default didn't start.
Returning NULL` and `[Darwinn] Unable to connect to Power HAL`. The stock
`android.hardware.power-service.pixel-libperfmgr` runs in the chroot (all its
NEEDED libs are there). It reads its hint table from the path in
`vendor.powerhal.config`; the props shim answers every property with `"1"`,
so it wants `/vendor/etc/1`. `powerhint.json` was missing from the chroot and
is now copied from the local extraction (57531 bytes), and `/vendor/etc/1` is
a copy of it, so the service starts and parses 275 actions. The debug path
`/data/vendor/etc/1` is not needed; the service falls back to `/vendor/etc/1`.
Restart the tachyon service **after** the Power HAL is up: it caches a failed
lookup, and a second `createSession` in the same process does not retry it.

**Still status 12, and the reason is structural.** With the Power HAL live,
app service and tachyon restarted in order, `createSession` still returns
`exception -8 service 12 "Non-ok status from HAL."`. gdb on the daemon
(`break TachyonCore_CreateClientSession`, `finish`) shows the core's own
return is `x0 = 0xc`; the daemon maps any non-zero return to UNIMPLEMENTED
with that message. The core links only liblog/libc/libm/libdl (no binder).

`libtachyon_core.so` **is a stub in this image**: `TachyonCore_Start`
(0x51590) stores its argument, calls a 3-instruction function that only
returns, and returns; `CreateClientSession` (0x51078) references the string
`InternalCreateClientSession is not implemented.` (0x19d67) at 0x51480 and
returns 12. The vendor service's call site even ignores `TachyonCore_Start`'s
return and builds an OK status (`bl TachyonCore_Start; bl AStatus_newOk`).
The `libtachyon_core.so` in `out/factory/fw/img/vendor.img`
(`out/vendor-libs/tachyon_core.img.so`, sha `47fb5f74…`) is byte-identical to
the chroot's, so this is what the A17 image ships, not a bad extraction.
The uid × privileged matrix (1000, 10000, 10123 × privileged 0/1) fails
identically, so it is not the caller's identity either.

**`com.google.edgetpu.dba-service` cannot be used.** The binary in the chroot
needs `com.google.edgetpu.dba-V1-ndk.so`, which is not in `/lib64` of the A17
`vendor.img` (the image ships the app service's V3 only). It is an orphan in
the extraction and fails at link time, so the Darwinn2 DBA path is not part of
this image's TPU stack.

Not the gate either: the HAL's VII-version check
(`Firmware VII version [%d] does not match runtime VII version [%d]`,
`libdarwinn_hal.so` 0x1525624) never logs on this firmware, so the type-0
setup is the HAL's normal path, not a fallback it takes after a mismatch.

**Conclusion:** on this A17 userspace no vendor component can produce the
firmware's setup command — the HAL sends the pre-Tachyon type 0 that the A17
firmware refuses, and the only Tachyon producer, `libtachyon_core.so`, is
compiled as a stub. The TPU stays at `Setup is not done yet` until one of
these changes.

Next, in order:
1. Look for a userspace that carries a real `libtachyon_core.so`: check the
   A17 `system.img` APEXes (e.g. `com.google.android.neuralnetworks.apex`)
   and any newer OTA, and compare `TachyonCore_CreateClientSession` for the
   `InternalCreateClientSession is not implemented.` reference before
   spending a boot on it.
2. If none exists, treat the setup as protocol work: the firmware wants a
   Tachyon setup message with a cluster bitset and global scratches (its own
   strings: `No global scratches were provided in setup command.`).
   `libedgetpu_tachyon.google.so` builds the queues (`SetupCommandFmq`,
   `SetupResponseFmq`) but the message comes from the stubbed core, so this
   needs the message layout from a firmware or a working userspace.
3. Do not retry the A14 firmware (U55), and do not expect the direct runtime
   or the HAL to change their first element: both send type 0.

Phone state: up, TPU powered by `tpu-hold`; servicemanager, vendor service
and app service left running, the spinning Darwinn HAL and the debug clients
stopped. `/vendor/etc/powerhint.json` and `/vendor/etc/1` are in the chroot;
`out/tpu-step.sh` is scratch (gitignored `out/`).

## U57 (2026-11-07): no producer in either current stock image; KCI 15/16/20 and the firmware ISA

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`; no cold boot was
spent on this round (the probe ran on the boot U56 left up).

**The newer stock image has the same stub.** `cheetah-cp3a.261005.002.a1`
(October 2026) is cached in `~/omamobile-kernel/downloads/`. Its
`vendor.img`'s `libtachyon_core.so` is byte-identical to cp2a's
(sha `47fb5f742638b5baf1e83f5ec81fe5c0c2da4cdd5b589c045e3757dab7895d49`,
`TachyonCore_Start` the same no-op, `CreateClientSession` the same
"not implemented" path), and its `system_ext.img` has the same app-service
libs only: no `libtachyon_core`, no `dba-V1-ndk`, no `dba-service`. The cp3a
firmware differs (1,039,168 bytes, sha `7ea9100f…`, vs 1,038,272 /
`52c1ccc…`) but carries the same setup strings at +0x3d0 in the file
(`Setup is not done yet…` 0xefefc, `No global scratches…` 0xf0138).
`com.google.android.neuralnetworks.apex` holds only `libneuralnetworks.so`
(4,823,528 bytes, 75 `ANeuralNetworks*` exports), so the APEX source is closed.

**Raw KCI 15/16/20 do not set up the firmware.** With a client holding
`/dev/janeiro` on the already-powered U56 boot, `EDGETPU_IOCTL_KCI_SEND_V`
(33 callers; `_IOW(0xed, 34, u32)`, base 0xED) gave

    code 6  -> 3   (INVALID_ARGUMENT)
    code 15 -> 3
    code 16 -> 3
    code 17 -> 12  (UNIMPLEMENTED)
    code 18 -> 12
    code 20 -> 0   (OK)

but the delegate run right after still logged `Sync VII command failed:
error_code=9`: code 20 is implemented and harmless, not the setup. The tool is
`tools/tpu-kci-probe.c` (built into `out/tpu-client/tpu-kci-probe`). This
extends U22 (which had 0..15): the implemented-but-unexplained codes are 15,
16 and 20, and none of them changes the VII gate.

**The firmware is 32-bit ARM, and a plain xref cannot find the gate.** Its own
flatbuffers strings say `size_t = unsigned int`, the body is a mix of ARM and
Thumb (`e92d` pushes 814, `bx lr` 978), and the ImageConfig at file 0x560
reports `firmware_base 0x93000000`, `firmware_size 0xfd000`, versions 2/3
(the body starts at file 0x1000, so the setup strings sit at VA
0x930eebdc/0x930eeddc/0x930eee18). A capstone sweep of the body for ADRP/ADR,
`ldr rX,[pc,#imm]` literals, `movw/movt` pairs and 32-bit absolute or
file-relative values found **no reference** to any of the four strings; that
matches U19, where the log ring addresses its strings from an index table, not
from code literals. So the gate is not reachable by a string xref and would
have to be found by pattern (the `vii_handler_layer.cc:247` dispatch) instead.

**Conclusion:** both A17 stock images ship a stubbed Tachyon core and the
legacy stack, and the firmware rejects the legacy setup. The producer exists
only where the Tachyon stack is real (a device image whose core is not the
stub). Next: inspect the Pixel 9a (tegu) A17 build's `libtachyon_core.so`; if
it has a real `CreateClientSession`, run it against cheetah's A17 firmware
(the protocol is host-side and the VII version is not checked before setup).
Download started to `out/factory/tegu-cp21.zip` (the stable A17 build;
QPR2 and QPR3 betas are the fallbacks).

Phone state: up, TPU powered, `tpu-hold` and the vendor/app services running;
the Darwinn NNAPI HAL and Power HAL were started for the registration test and
left in place. `tools/tpu-kci-probe.c` is new and uncommitted.

## U58 (2026-11-07): tegu ships the real Tachyon core; the session now needs a get_fds callback

The Pixel 9a's stable A17 image (`tegu_beta-cp21.260330.011`, 4.22 GB,
`out/factory/tegu-cp21.zip`) has what cheetah does not:

- `vendor/lib64/libtachyon_core.so` is **1,538,440 bytes** and exports 11
  `TachyonCore_*` symbols (`CreateClientSession`, `Start`, `Shutdown`,
  `SendClientAssignedFds`, `RequestFdsForGivenHandles`,
  `SendFdsForRequestedHandles`, `SetNpuManagerStatus`, `SetVlogLevel` and the
  NPU scheduling calls), against cheetah's four-symbol 1,015,720-byte stub.
- the stub is shipped beside it as `fake_libtachyon_core.so` (35,824 bytes),
  which is why cheetah's `libtachyon_core.so` looked like a real library.
- its tachyon service, `com.google.edgetpu.tachyon-service`, is 120,368 bytes
  against cheetah's 70,024, and links the V6 app-service AIDL and the dsp core.

**Tegu's libraries assume ARMv9 and crash on gs201.** The client library's
first call died with `SIGILL` at `retaa` (ARMv8.3 pointer authentication is
undefined on Cortex-X1/A78), then at `ldapur` (ARMv8.4 RCpc). Patching the
`.text` of the tegu client, core, service, NDK and dsp libraries fixes both:
`retaa`/`retab` -> `ret`, `paciasp`/`autiasp`/`pacibsp`/`autibsp` and the data
PAC/AUT forms -> `nop`, and LDAPUR/STLUR B/H/W/X -> LDUR/STUR (same `imm9`
layout; the acquire ordering is lost, which is acceptable for this bring-up).
After the patch the client connects, `create` returns OK, and the tegu service
parses the full session config (the "config smaller than core" warning is
gone).

**The remaining gate is the fd callback.** `createSession` now answers
`NOT-OK exception -3 "Missing get_fds_callback in SessionConfig"`, and the
service logs `[EdgetpuTachyonHalService] createSession rejected:
get_fds_callback is null`. The tegu client library exports the setters
`TachyonComputeSessionConfig_setGetFdsResponseCallback` and
`TachyonComputeSession_setCallbackForGetFdsResponse`, and the AIDL interface
`com.google.edgetpu.tachyon.IGetFdsResponseCallback` with
`BnGetFdsResponseCallback::onGetFds(vector<FileDescriptorWithId>, int64_t)`.
The next step is to run tegu's app service (which implements that callback on
stock) or to supply a callback from the client.

### Result: the core runs and authorizes a session

The C setter's signature is `void (*)(void *cookie, int *fds, long *handles,
int count, long session)` (from `ComputeSession::SetCallbackForGetFdsResponse`,
`EPFvPvPiPlilE`), set through
`TachyonComputeSessionConfig_setGetFdsResponseCallback(config, fn, cookie)`.
With it the client gets:

    create: OK
    get_fds_callback set
    createSession: OK
    setupCommandQueue: OK fds=11,12
    setupResponseQueue: OK fds=14,15
    [ClientSession ...].state CREATED to STARTED to AUTHORIZED

So the real tegu core runs on gs201, accepts the full config and authorizes a
client session. Two limits remain:

- **Creating a session does not send the firmware setup.** A delegate run
  alongside the live session still answers `Sync VII command failed:
  error_code=9`. The core must initialize the NPU lazily, on the first command
  through the command FMQ (fds 11/12), so the setup is a Tachyon command, not
  a side effect of `CreateClientSession`.
- **The tegu service dies right after the reply.** `SIGSEGV, fault addr 0x1`
  in the service thread, after `createSession` returns and before the client's
  next call. It is not the client's teardown: with
  `ABinderProcess_startThreadPool()` in the client the crash moved earlier,
  and without it the session is created and the service still dies. The fault
  is a null-pointer dereference on the callback path, not an ARMv9 instruction.

Next: read the service's faulting PC with gdb (the chroot gdb follows exec but
cannot load bionic symbols, so use the PC plus `/proc/<pid>/maps`), or run
tegu's Darwinn NNAPI HAL, which submits the first command on stock. The PSM has
been powered for hours across many failed sessions, so the next TPU series
starts from a cold boot.

Phone state: up, TPU powered once by `tpu-hold`; the tachyon service is now
the patched tegu binary, with the tegu core, dsp core and V6 AIDL in the
chroot. The cheetah originals are saved as `*.cheetah` next to each file.
`out/factory/tegu-cp21/` and `out/tegu-extract.sh` are scratch (gitignored).
`tools/tpu-tachyon-client.c` now sets the get_fds callback and sleeps 120 s so
a delegate can run while the session is alive.

## U59 (2026-11-08): the app service publishes IEdgeTpuAppService

`uname -r` 7.3.0-rc6-omamobile-push1-g052da70970d6-dirty.

The tegu app service (`system_ext/bin/hw/vendor.google.edgetpu_app_service@1.0-service`) never exec'd: the chroot's linker stopped at `libcom.android.tethering.connectivity_native.so` (needed by `/system/lib64/libandroid.so`) and, behind it, `libicu.so` (needed by `libharfbuzz_ng.so`). The tethering library is in the tethering APEX: `out/tethering.apex` is a compressed APEX, so unpack `original_apex`, then `apex_payload.img`, then

    debugfs -R 'dump /lib64/libcom.android.tethering.connectivity_native.so out/tethering-extract/libconnectivity_native.so' out/tethering-extract/apex_payload.img

The result is 68,848 bytes; install it as `apex/com.android.tethering/lib64/libcom.android.tethering.connectivity_native.so` in the chroot.

The app service's `libandroid.so` NEEDED is unused: its undefined symbols are the binder NDK and libc only, and none of its other libraries needs libandroid. Rewrite the dynstr string in place (14 bytes including the NUL; offset 9935) to `libc.so`; the file size and the auth patch at `0x10d44` stay:

    b[off:off+14] = b'libc.so' + b'\0' * 7

The app service then links, runs as uid 1000, and publishes `com.google.edgetpu.IEdgeTpuAppService/default`; its log says `Found ... in device VINTF manifest.` (pid 8431). The phone chroot's copy is sha256 `6e350d179079f046ae020a2f03f5b69f32e1f7d5d53d22aaf8e6f77425ecfaca`.

With the app service up the chain is servicemanager, vendor service, Tachyon service and app service. The HAL still aborts; the delegate no longer opens `/dev/edgetpu` itself (no `runtime wakelock` line; `/dev/janeiro` is 0660 root:gid 1000) and reaches `Sync VII command failed: error_code=9`, `create device status: 13`, rc 1.

## U60 (2026-11-08): the old log shim was the service's SIGSEGV

The gdb PC of the Tachyon service's `SIGSEGV` is `liblogstderr.so+0xe64` (LR `+0xc24`), not the Tachyon core. The runner copies `/root/liblogstderr.so`, and that file was the old 9,752-byte shim; its formatter let a conversion misalign the va_list, so a later `%s` read a wild pointer — the crash `tools/android-log-stderr.c` now prevents by consuming every conversion's argument. The fixed build is `out/tpu-client/liblogstderr.so`, 13,240 bytes, sha256 `8bdfede1616c3810453569ee0715b819f79a49d37d6d7250e8c124b8c16ca526`:

    $CL --target=aarch64-linux-android30 -shared -fPIC -nostdlib -o out/tpu-client/liblogstderr.so tools/android-log-stderr.c

Installed in `/root/liblogstderr.so` and the chroot's `/system/lib64/`, the Tachyon service survives `createSession` (pid 12682) and registers `com.google.edgetpu.tachyon.IComputeService/default`.

The client's next result is `create: NOT-OK ... exception -8 service 13 "Failed to connect to the Tachyon Compute Service"`, with the service still alive; VLOG 1 shows only `TachyonCore_SetVlogLevel`. The service `create` is the next wall: the app service (root caller), the vendor service, or the binder domain. Next: `vendor.tachyon.log_level` 2 (VLOG 3 trips `Unknown platform ID on Android: 6`, so not 3), with the app-service and vendor sections of the same log; then the client with the app service stopped (U58 had `create: OK` without it) to tell whether its presence is the change.

Phone state: up; TPU powered once (`tpu-hold`, pid 5147); servicemanager 11455, vendor service 11467, app service 11525, Tachyon service 12682. The fixed shim is in `/root` and the chroot; the delegate still stops at `Sync VII command failed: error_code=9`.

## U61 (2026-11-08): create works, and the core wants a platform name

`uname -r` 7.3.0-rc6-omamobile-push1-g052da70970d6-dirty.

The client's `create` failure was a dead servicemanager, not the app service. After the delegate's run the vendor servicemanager takes `SIGILL` right after `A service was removed when there are clients` (the Tachyon service's `AidlLazyServiceRegistrar` notification); every later client gets `BR_DEAD_REPLY` and "Failed to connect to the Tachyon Compute Service". With a fresh chain the client's `create: OK`, and the service calls `TachyonCore_CreateClientSession`.

That call then aborts in `edgetpu_android_property_util.cc:284`: `Unknown platform ID on Android: 6`. gdb shows the main thread in our `libabortshim.so`'s `abort`, which by design returns (`ABORT-SHIM returning`), so the client hangs instead of seeing the failure. The 6 is the utility's unknown sentinel, not the property's value: the `GetPlatformId` at `0xd5630` reads `ro.board.platform` (17 bytes) with `android::base::GetProperty`, and `0xd5598` hashes the string and switches on the hash's low 7 bits (cases 0-5, default 6); the helper at `0xd56ec` switches on the ID (cases 0-5, default fatal with the literal 6).

So the Tachyon service needs the platform name its A17 core knows, not `mmio` (the driver-provider value the delegate needs). The shim must be process-aware: `mmio` for the delegate and client, the platform name for the Tachyon service. The names are not stored as strings; the mapper at `0xd5598` is the way to find which one maps to a known ID. That gdb call was ready when the phone's SSH failed: no agent is running, and `~/.ssh/id_ed25519` asks for its passphrase. The candidates (gs201, gs101, zuma, zumapro, tegu, gs401) have not been called yet.

Next: unlock the phone key; call `base+0xd5598` with the candidates; give the Tachyon service the known name and the delegate `mmio`; rerun the client and then the delegate.

## U62 (2026-11-08): the platform is gs201 (1), evaluated offline

`uname -r` 7.3.0-rc6-omamobile-push1-g052da70970d6-dirty. Phone uptime 1:20 and `tpu-hold` (5147) alive, so the earlier USB drop was the host's cdc_ncm watchdog, not a phone reset.

The gdb mapper call did not answer: the injected call at `base+0xd5598` faulted at its first instruction (`str x30, [sp, #-0x10]!`), the detach delivered the SIGSEGV, and the Tachyon service died; the vendor (17897) and app (17932) services and the tpu-hold survived. The base was right (`0xffff996c7000`, the first LOAD is R E) and the phone's core hash equals the host's disassembled file.

So the mapper was evaluated offline. `0xd57d8` is CityHash64 (constant 0x9ae16a3b2f90404f; the 8-16 and 4-8 paths match); recomputing it in Python and taking the low 7 bits the mapper switches on gives:

- gs101 -> 0x3b -> platform 0
- gs201 -> 0x77 -> platform 1
- zuma -> 0x13 -> platform 2
- zumapro -> 0x1e -> platform 3
- (0x37 -> 4 and 0x5b -> 5 are two more names)
- mmio, tegu, gs401, android, cheetah -> 6 (unknown).

So the Tachyon service's `ro.board.platform` must be `gs201`, the Pixel 7 generation's ID, while the delegate keeps `mmio` (the driver-provider value). `tools/android-props-stub.c` now reads `/proc/self/cmdline` with raw `openat`/`read`/`close` syscalls and returns `gs201` only for `com.google.edgetpu.tachyon-service`; built with `clang --target=aarch64-linux-android30 -shared -fPIC -nostdlib` (6,824 bytes in `out/tpu-client/libpropsshim.so`).

The push is blocked: after the failed key offers, the phone's sshd refuses the key (`publickey,password,keyboard-interactive`) even after a 75 s wait; the key is unencrypted (`ssh-keygen -y -P ''` succeeds, comment `omamobile`), the host reaches the phone (ping), and sudo needs a password, so the serial console is not usable from the host.

Next: restore SSH (a phone reboot clears it; the authorized key is on userdata), push the shim to `/root` and the chroot's `/system/lib64`, restart the chain (the tpu-hold keeps the one power-up), and run the client; `createSession` should now pass the platform check.

## U63 (2026-11-08): createSession passes the platform check

`uname -r` 7.3.0-rc6-omamobile-push1-g052da70970d6-dirty, phone uptime 1:43.

The SSH refusals after 08:29 were the other phone: the OnePlus 8T's NCM interface (`enp0s20f0u5`) took `172.16.42.1` with a metric-0 /32 route and answered with its own key list. `tools/phone-usb` pins the Pixel (`enp0s20f0u4`, 172.16.42.3/32); the OnePlus profile is now `connection.autoconnect no` and the Pixel was reachable again.

With the process-aware `libpropsshim.so` installed, the Tachyon service reports `gs201`, and the tegu client (uid 10000) gets:

    create: OK
    createSession: OK
    setupCommandQueue: OK fds=11,12
    setupResponseQueue: OK fds=14,15
    sendCommand: OK
    receiveResponse: NOT-OK ... exception -8 service 8

The `Unknown platform ID on Android: 6` abort is gone.

The service then dies: every later lookup prints `Since 'com.google.edgetpu.tachyon.IComputeService/default' could not be found ...`, and `pgrep -x com.google.edge` is empty. That is the callback-path SIGSEGV at fault addr 0x1 from U18/U50-U58, now the first blocker again: after the client's first command the service's response callback dereferences a null pointer. The client then sleeps "for the service's setup" and never sees it.

The delegate's run in the same chain still ends `device: 0x0`, `delegate rc: 1`, with `samsung-iommu.c:726 unmap_slpt` warnings from `edgetpu_unmap_dmabuf`; that is the delegate's teardown, not the client's session path.

Next: restart the chain (the tpu-hold keeps the one power-up), run the client, and gdb the Tachyon service to get the crash PC (the runner's `BT=1` path stops the delegate early enough, or attach after the client's first command); patch the null callback or give the service a real one, then rerun the client and watch for the firmware setup.

## U64 (2026-11-08): the service does not die; the core holds the command in CREATED

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, phone uptime 2:04.

Three corrections to U63, each with the mechanism behind it:

- **The Tachyon service does not crash after the command.** The client's later
  lookups failed because `AidlLazyServiceRegistrar` shuts a service down when
  it has no clients, and the client had already exited: one
  `receiveResponse` read, 120 s of sleep, then `timeout`. With the delegate
  skipped the service stays up for the whole client run and logs its exit
  only after the client leaves: `ClientSession … STOPPING to STOPPED`, then
  `Process has 0 (of 1 available) client(s)` and `Unregistered all clients
  and exiting`. The earlier "service dies" was that shutdown, not the
  callback SIGSEGV (which U60's log shim fixed).
- **`receiveResponse`'s `exception -8 service 8` means "no answer yet".**
  `ComputeSession::ReceiveResponseMessage` (`libedgetpu_tachyon.google.so`,
  `0xf2c0`) asks the response FMQ for its available bytes and, when the count
  is `<= 0x7f`, returns
  `AStatus_fromServiceSpecificErrorWithMessage(8, …)`. A 100 × 100 ms poll
  loop never sees a different status, so the queue really stays empty; it is
  not a failed transaction and not a crash.
- **The Tachyon core needs the Power HAL before it is started.** The service
  logged `Service android.hardware.power.IPower/default didn't start.
  Returning NULL` and `[Darwinn] Unable to connect to Power HAL`, because the
  runner never started it; U56 had started it by hand. `tools/tpu-tachyon-run`
  now starts `vendor/bin/hw/android.hardware.power-service.pixel-libperfmgr`
  from the chroot before the vendor and Tachyon services. Its libperfmgr node
  writes fail (our kernel has no `devfreq_mif` interactive or
  `/proc/vendor_sched` nodes), which is expected and harmless.

The client also starts the binder threadpool the Tachyon library asks for
(`ABinderProcess_startThreadPool`, the lib's "The user of this library did
not start a threadpool"), so the core's `get_fds` callback can be delivered.
It is never called, and no response arrives.

Where the command stops: with a live session, `/proc/<tachyon>/task` holds
`MainTpuActor` in `do_epoll_wait`, `HighPriWorker`, `MedPriWorker` and
`LowPriWorker` in `futex_wait`, two `vndbinder` threads and the main thread
in `binder_ioctl_write_read`. The service has no `/dev/janeiro` fd of its
own; the app service owns the device and the group. The core's own strings
name the gate: `ClientSessionFmqCommandReady received event but it is not in
STARTED or AUTHORIZED state. Hold.` and `Failed to push firmware setup
command due to VII command queue is full`. So the command sits in the
command FMQ because the session never reaches STARTED, and the setup the
firmware wants is pushed only from a started session.

Next: the fd-assignment path. The client API also exports
`TachyonComputeSession_sendFileDescriptors`,
`begin/commitCommandQueueWrite`, `setSessionType` and `setClientVersion`,
none of which the probe calls; the core exports
`TachyonCore_SendClientAssignedFds` and
`TachyonCore_RequestFdsForGivenHandles`, and the setup command is the one
that carries the global scratches. Disassemble
`TachyonComputeSession_sendFileDescriptors` and the core's
`ClientSessionStart` to learn what the stock client assigns before its first
command, then assign the same from the probe.

Phone state: up, TPU powered once (`tpu-hold`, pid 5147). Chain left down
after the run; `tools/tpu-tachyon-run`, `tools/tpu-tachyon-client.c` and
`tools/android-props-stub.c` carry this round's changes. `core_pattern` is
still `/core.%e.%p` (the old value is in `/tmp/tpu-core-pattern.old`).

## U65 (2026-11-08): the Tachyon service dies in the GXP main actor; stock's `gxp` driver is the missing part

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, phone rebooted for a
clean TPU (uptime 150 s at the first test), TPU powered once by `tpu-hold`
(`power-up ok: PSM0_STATUS=0x4b27091 PSM1_STATUS=0xe893 LPM_CONTROL=0x148`).

**The session failure in this round is not the session config.** With a clean
boot, the client's `create` succeeds and then the Tachyon service dies before
`createSession`; the client sees `exception -129` and
`unlinkToDeath … DEAD_OBJECT`. The service's own log:

    I gxp_main_actor.cc:204 Loaded GXP Tachyon Server library with rapid
      version zpr_dsp_20260302.0.0 …
    E gxp_main_actor.cc:286 Could not setup the main actor.
    E scoped_eventfd.cc:34 INTERNAL: RET_CHECK failure … !fd.IsEmpty()
    E gxp_main_actor.cc:297 Failed to trigger exit loop event fd.
    libc: Fatal signal 11 … fault addr 0x0
    audit: … comm="com.google.edge" … sig=11

so the GXP (DSP) actor cannot set up and its teardown dereferences the empty
fd. The actor is created on the **first client connection**, which is why the
death looks like a `createSession` failure.

**Four things that are not the cause**, each tried on the live phone:

- the user: stock's rc runs the service as `user system`, so the runner now
  does too (`--userspec=1000:1000`); as root the same line appears;
- the DSP firmware: the chroot had no `/vendor/firmware` at all; tegu's
  `gxp_callisto_fw_core0/1/2` (296,960 bytes each) are now installed, no
  change;
- the device permissions: `/dev/edgetpu-soc` is now `0660 root:system`, as
  stock's ueventd makes it;
- `/dev/gxp`: stock's ueventd creates it `0666 system:camera`, and a symlink
  to `janeiro` changes nothing.

**The structural reason:** the GXP Tachyon Server is a client of the **vendor
`gxp` driver** (`/dev/gxp`; stock's gxp rc owns
`/sys/class/gxp/gxp/device/dsp_usage_0..2`, `preempt_count`,
`context_switch_count`). Our kernel has the mainline `janeiro` driver and no
`gxp` driver, no `/dev/gxp`, no `/sys/class/gxp`, so the A17 Tachyon DSP
server cannot start here. That is a harder wall than U56's stub core: the
tegu core is real, but its DSP half needs a driver we do not have.

**The way around it is the setup command itself.** The probe already owns the
command FMQ and can push any message the firmware accepts. In
`libtachyon_core.patched.so` (vaddr == file offset):

- `Sending firmware-setup VII command. type: ` at 0xcf73, logged at 0xa4d5c
  (`adrp x1,0xc000; add x1,x1,#0xf73`, length 0x2a) with the type byte from
  `[sp,#0xa0]`;
- `PushFirmwareSetupCmdToVII failed` at 0x8b7e, logged at 0xa4d84 from the
  push helper's return;
- `Failed to push firmware setup command due to VII command queue is full`
  at 0x111fd.

So the setup is a `CommandMessage` with a typed union member built next to
0xa4d5c and pushed by the helper at 0xa4dec. Recover its flatbuffer layout
(fields, union type, global scratches, cluster bitset) and build it in
`tools/tpu-tachyon-client.c` instead of the placeholder `build_cmd`; the
firmware's own rejections name the missing pieces (`No global scratches were
provided in setup command.`).

**The runner also learned not to leak an IOMMU domain.** On the previous boot
the HAL's aborted group creation left one behind and the next group
allocation oopsed: `edgetpu_mmu_alloc_domain+0xa0`, LR
`edgetpu_device_group_alloc+0xf4`, via `edgetpu_ioctl_create_group`; the
Tachyon service then took SIGSEGV. `NO_DELEGATE=1` runs therefore skip the
Darwinn HAL.

Phone state: up, TPU powered once (`tpu-hold`, pid 4054); services stopped
after the client left. `/dev/gxp -> janeiro` and the three
`/vendor/firmware/gxp_callisto_fw_core*` are installed in the chroot (test
state, reversible). `core_pattern` is the systemd default.

## U66 (2026-11-08): TeGu's HAL is the same legacy producer and SIGILLs; the setup type is the open question

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, phone up 2000+ s,
TPU held by `tpu-hold` (4054, the boot's one power-up).

**TeGu's vendor image carries the A17 NNAPI HAL and its library.** Its root is
the vendor partition (`/bin`, `/lib64`, `/firmware`), so:

    debugfs -R "dump /bin/hw/android.hardware.neuralnetworks@service-darwinn-aidl out/tegu-hal/darwinn-hal" out/factory/tegu-cp21/vendor.img
    debugfs -R "dump /lib64/libdarwinn_hal.so out/tegu-hal/libdarwinn_hal.so" out/factory/tegu-cp21/vendor.img

The HAL is 838,984 bytes and the library 57,764,584 bytes; the HAL NEEDs
`com.google.edgetpu_app_service-V6-ndk.so` (the chroot already has it) and is
otherwise the same NEEDED set as cheetah's. But tegu's library contains the
same `Firmware setup failed for commands[%d], cluster_id_bitset in hex: %x.`
string, so it is the **same legacy setup producer**, not a Tachyon-specific
one: the Tachyon setup lives in `libtachyon_core` (a stub on cheetah, real on
tegu) and is pushed by the core's DSP actor.

**Running tegu's HAL against `janeiro` does not work.** On the held power-up it
starts and links, then dies before any group:

    libc: Fatal signal 4 (SIGILL), code 1 (ILL_ILLOPC), fault addr 0xaaaac21301c4

so it never reaches `SetupFirmware`; `dmesg` shows only the `tpu-hold`
heartbeat (KCI code 21). Cheetah's HAL and library are restored, and
`tools/tpu-tachyon-run` gained `HAL_ONLY=1` to stop after the HAL for this
kind of experiment.

**What the firmware's own words now narrow:** a normal command is type 0
(the A14 HAL's sync and the delegate both send it and get `Setup is not done
yet received a command of type 0`); the core's hint path prints the setup
message type from a byte the code sets to **1**; and the setup must carry
`global scratches`. So the missing piece is a **type-1 setup payload**, not
another producer binary. The core's push sites are `0x7531c` and `0xd36e0`
(`PushFirmwareSetupCmdToVII failed`), and `0xd35c8` mmaps a region in 24-byte
entries (likely the scratch list) from a firmware-scratch fd.

**Host access, learned the hard way this round.** `tools/phone-ssh` without
`OMAMOBILE_SSH_KEY` offers every agent key and the phone refuses it ("Too
many authentication failures"); export
`OMAMOBILE_SSH_KEY=~/.ssh/id_ed25519`. The OnePlus 8T's DHCP hands out
`172.16.42.2/24` and steals `172.16.42.1` again after every reconnect, so
bind the connection to the Pixel (`ssh -B enp0s20f0u4`) or `nmcli device
disconnect enp0s20f0u5` first.

Phone state: up, TPU powered once (`tpu-hold` 4054), cheetah's HAL and
libdarwinn restored, chain left down.

## U67 (2026-11-08): the KCI code-6 lead is dead; the HAL bitset is patched for a clean run

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`.

**KCI code 6 is not the setup command.** U20 inferred it from one precondition
answer; the driver's `kci_send_v` variant sweep (ioctl `0x4004ed22`, eight
scratch layouts plus controls) answers 3 for every code-6 variant, and code 9
(GET_USAGE) answers 3 too. So 3 is a generic firmware precondition (setup not
done), not the global-scratch check; U20's conclusion is retracted, and the KCI
path is closed.

**The stock HAL's bitset can be forced.** `SetupFirmware` receives its
`cluster_id_bitset` in `x21` (`mov x21, x2` at file offset `0x14d9a48`; the
library maps vaddr == file offset), and the setup call is gated on bit `0x20`
(`tbz x21, #0x20` at `0x14d9cc0`). Patching `0x14d9a48` to `mov w21, #0x21`
(bytes `35 04 80 52`) forces the call with cluster 0 plus the gate bit. The
backup is `$R/vendor/lib64/libdarwinn_hal.so.bitset-orig`.

**The first patched run never reached the setup:** it oopsed in
`edgetpu_mmu_alloc_domain+0xa0` from `edgetpu_device_group_alloc` because the
kciv client's group had leaked an IOMMU domain (U65's failure mode). Rebooted.

On the fresh boot the module load logs a `__setup_irq` WARNING from
`edgetpu_chip_setup_mmu`, recovers, and powers up
(`power-up ok: PSM0_STATUS=0x4b27091 ...`). The patched HAL then started but its
log ends at `[Darwinn] Unable to connect to Power HAL`, with no setup line; the
HAL (pid 4186) was still running when the runner's 4 s window closed, and
`tpu-hold` (4109) holds the boot's one power-up. So the patched run has not been
evaluated yet: it needs the power HAL up and a longer settle.

**Host traps, again.** The OnePlus 8T re-took `172.16.42.1` after the reboot
(the key rejection is its sshd); disconnect `enp0s20f0u5` and set its profile
`connection.autoconnect no` by UUID (the profile name is duplicated). The
chroot root had become mode 0700, so the uid-10000 client could not exec or
read its preloads; `chmod 755 $R` fixes it. The delegate runs as root.

Phone state: up, TPU powered once (`tpu-hold` 4109), cheetah's HAL patched
(`.bitset-orig` backup) and the HAL service still up (4186); the Tachyon and
app services stopped after the runner.

## U68 (2026-11-08): the Power HAL waits for IStats and never publishes IPower

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`.

On the fresh boot the runner came up, but the patched HAL still stopped at
`[Darwinn] Unable to connect to Power HAL`. The cause is the Power HAL itself:
`android.hardware.power-service.pixel-libperfmgr` starts, loads its nodes, and
then blocks in `AServiceManager_waitForService("android.frameworks.stats.IStats/default")`
(`Waited one second for android.frameworks.stats.IStats/default` 33 times and
counting, after `NodeLooperThread will wait for 500000000ns`). It never reaches
`addService` for `android.hardware.power.IPower/default`, so the Tachyon core's
lookup fails and the session never dispatches a command.

- The chroot has no `statsd`, `/system/bin/service` or `dumpsys`, so registration
  can only be observed from a process (the core's log) or after extracting
  `service`. `android.hardware.power.stats-service.pixel` is present but is a
  client of IStats, not its server.
- A manual start needs the runner's `LD_LIBRARY_PATH`
  (`/apex/com.android.tethering/lib64:/system_ext/lib64:/vendor/lib64:/system/lib64:/apex/com.android.runtime/lib64/bionic`);
  without it the binary cannot even link `libc.so`.
- The runner starts the HAL as root (`USPEC` stays empty unless `RUN_UID` is
  set), although its comment says the HAL must run as the app uid. As root the
  util library opens `/dev/edgetpu` itself and allocates its own group, which
  oopsed in `edgetpu_mmu_alloc_domain+0xa0` from `edgetpu_device_group_alloc`
  twice (the leaked-domain oops of U65). It must run with `RUN_UID=10000`.
- A new group will fail for the rest of this boot: reboot before the next
  attempt and bring the Power HAL fully up before the tachyon service.
- Next: give the Power HAL an `IStats` server (a stub, or `statsd`), or patch
  `libperfmgr.so` so its wait returns without blocking, then confirm the core
  no longer logs `Unable to connect to Power HAL`.

## U69 (2026-11-08): the IStats wait is in the Power HAL binary and is gone; the HAL's registration is the next gate

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, one cold boot, one TPU
power-up (`power-up ok: PSM0_STATUS=0x4b378d0 PSM1_STATUS=0xe893
LPM_CONTROL=0x148 GSA state=2`), held by `tpu-hold`.

**U68's `libperfmgr.so` lead is wrong: the wait is in the service binary.**
`libperfmgr.so` imports no binder symbol at all (its only `wait` is
`pthread_cond_timedwait`). The wait is in
`vendor/bin/hw/android.hardware.power-service.pixel-libperfmgr`, which NEEDs
`android.frameworks.stats-V2-ndk.so` and imports
`AServiceManager_waitForService@LIBBINDER_NDK31`. Its PLT stub is at `0x48da0`
with two callers, `0x1f584` (IStats) and `0x35f60` (IThermal). Both follow the
call with `str x0,[sp]` and `cbz x0,<error path>`, so a null return is a path
the binary already handles ("Cannot get IStats binder!").

Patch, one instruction, reversible: at file offset `0x1f584`
(`07 a6 00 94`, `bl 0x48da0`) write `00 00 80 d2` (`mov x0, xzr`). The IStats
wait returns null immediately and the HAL continues; the IThermal call site is
untouched. Phone backup `...power-service.pixel-libperfmgr.orig` (sha256
`19dd2e4c…`), patched file sha256 `4b0a7e2c…`.

Result, with the runner's environment and shims:

    [libperfmgr] Pixel Power HAL AIDL Service with Extension is started.
    [powerhal-libperfmgr] Cannot get IStats binder!

and zero `Waited one second for android.frameworks.stats.IStats/default` lines.
`Failed to write to node: /proc/vendor_sched/…` remains, expected (U64).

**`tools/tpu-tachyon-run`'s `USPEC` never reached the Power HAL.** Its line
started `chroot "$R"` with no `$USPEC`, so `RUN_UID=10000` left that service as
root while the Darwinn HAL and the delegate got the app uid. It now passes
`$USPEC` like the HAL line. `chroot --userspec=10000:10000` is confirmed on the
phone (a static uid probe prints `uid=10000 euid=10000`), so the flag was the
only bug.

**With the Power HAL live the Darwinn HAL gets past "Unable to connect to Power
HAL" and reaches the TPU**, then dies at its NNAPI registration:

    [EdgetpuTachyonHalService] Loading Tachyon Hal interface...
    [Darwinn] CompilerSpawner: Started Loop. PID: ...
    [Darwinn] Could not register NNAPI IDevice service.
    libc++abi: terminating / ABORT-MSG terminating / ABORT-SHIM returning
    FORTIFY: pthread_mutex_lock called on a destroyed mutex
    libc: Fatal signal 6 (SIGABRT) ... (android.hardwar)
    [dmesg] edgetpu janeiro: finalize: detachable 1 wakelock 0 context 1073741824

so it created and finalized its group/context (the TPU stays powered) but never
opens a Tachyon session. The registration is refused because the HAL runs as
uid 10000: servicemanager only lets root and system register services, and
`Could not register` is the HAL's own check on the returned status. The abort
shim survives the abort, but the thread teardown then locks a destroyed mutex
and the process dies.

**Running it as system (uid 1000) gets past registration but not startup.** With
`--userspec=1000:1000` and `/dev/janeiro` masked (`chmod 000`) for its first 4 s
so it takes the Tachyon path, there is no `Could not register`, but:

    [Darwinn] Non-ok status from HAL: 2
    ABORT-MSG Check failed: hal_ != nullptr
    [Darwinn] Unable to connect to Power HAL

The Power HAL it started with had already exited (its `AidlLazyServiceRegistrar`
shuts it down when the Tachyon service's client goes away), so this run does not
separate "uid 1000 breaks the Power HAL lookup" from "the Power HAL was gone".
That is the next experiment: start the Darwinn HAL as system inside the runner's
settle window, while the Power HAL is certainly alive.

**The Tachyon client gets a full session, and still no setup.** On the same
chain (`tools/tpu-tachyon-client`, uid 1000):

    create: OK
    createSession: OK
    setupCommandQueue: OK fds=11,12
    setupResponseQueue: OK fds=14,15
    sendCommand: OK
    [Main TPU Actor] received ClientSession::Start
    [ClientSession …].state CREATED to STARTED
    [ClientSession …].state STARTED to AUTHORIZED
    receiveResponse: NOT-OK exception -8 service 8   (empty queue, U64)

No `Sending firmware-setup VII command.` line appears, the `get_fds` callback is
never called, and `dmesg` shows only the `tpu-hold` heartbeat (KCI code 21), no
VII command. So an AUTHORIZED session with a queued command is not enough: the
core's setup push is the DSP/GXP actor's, and that actor cannot set up without
the vendor `gxp` driver (U65).

No inference ran and no benchmark was measured this round.

Phone state: up, TPU powered once (`tpu-hold`), chain stopped; the HAL's aborted
process left no group. Next, in order:
1. Start the Darwinn HAL as system inside the runner's window, while the Power
   HAL is certainly alive, and watch for `Sending firmware-setup VII command.
   type: 1`; if it still reports `Non-ok status from HAL: 2`, read that status
   site with the uid-10000 run as the control.
2. If the HAL path stays closed, do the fallback: recover the type-1
   `CommandMessageT` layout from `libtachyon_core.patched.so` (builder near
   `0xa4d5c`, verifier at `0xb9c48`) and build the setup in the client, or port
   Google's `gxp` driver with `janeiro` blacklisted.
3. Only after a real inference: the 720p object-detection benchmark
   (`tools/bench-object-detection.py`, `mosaic720.mp4`) on TPU, CPU and GPU.

## U70 (2026-11-08): the HAL survives registration; the pool WARN and the unpublished IPower are the gates

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`.

**The registration gate is down.** The Darwinn HAL imports
`AServiceManager_addServiceWithFlags@LIBBINDER_NDK34` and tests its return as a
32-bit status (`mov w19, w0`, then `cbz w19` at file offsets `0x2153c` and
`0x21558`): a pointer is never zero, so the OK-filled `AStatus` that
`tools/android-addservice-shim.c` returned first still logged "Could not
register NNAPI IDevice service." and aborted. Returning `0` from that symbol
lets the HAL reach `ABinderProcess_startThreadPool` and stay up
(`ADDSVC-SHIM android.hardware.neuralnetworks.IDevice/google-edgetpu`, no
abort, two HAL processes both uid 10000). The symbol is interposed into the
HAL alone (`HAL_PRELOAD` in `tools/tpu-tachyon-run`); the services that must be
visible never get it.

**The `edgetpu_mmu_alloc_domain+0xa0` trace is a WARN, not an oops.**
`/proc/sys/kernel/panic_on_warn` reads 0, and the trace's callee is
`iommu_set_fault_handler()` (`drivers/iommu/iommu.c:2057`), which WARNs and
returns when `domain->cookie_type != IOMMU_COOKIE_NONE`. A domain handed out
from the pool a second time still carries `IOMMU_COOKIE_FAULT_HANDLER` from its
first `edgetpu_init_etdomain()`, so every second group create in a boot prints
the WARN. The group is still created and finalized
(`finalize: detachable 1 wakelock 0 context 1073741824`), the phone stays up,
and `panic_on_warn=0` means nothing dies. What is wrong is the stale
`handler_token`: it points at the previous, freed `etdomain`, a latent
use-after-free if the IOMMU ever faults. The fix is the pool's documented
dynamic mode: `EDGETPU_NUM_PREALLOCATED_DOMAINS` (`janeiro/config.h`, today
`EDGETPU_NUM_VCIDS`) set to 0, so `edgetpu_domain_pool_alloc()` returns a fresh
`iommu_paging_domain_alloc()` domain every time and
`edgetpu_domain_pool_free()` calls `iommu_domain_free()`.

**The Power HAL still publishes nothing.** Started as uid 1000 with the real
lazy-registration path (no `liblazysvc.so`), it logs "…with Extension is
started." and no `IPower/default` registration; the HAL and the core still log
`Unable to connect to Power HAL`. Stock servicemanager answers
`registerLazyService*` with ENOTSUP (U68), so the real registrar cannot publish
the name even for a uid it accepts. Publishing IPower needs an eager
`AServiceManager_addService` for uid 1000 (the Tachyon service's lazy call
succeeds for that uid) or a servicemanager that honours lazy registration.

**Phone state:** fresh boot, TPU powered once by this run's `tpu-hold`; chain
left up (servicemanager 4932, tachyon service 5017, HAL 5067/5069). The boot's
dmesg holds two `WARNING` lines, both the pool-cookie WARN above. No inference,
no benchmark.

**Addendum (same boot): the Power HAL does not call the lazy symbols.**
`tools/android-lazysvc-eager.c` interposes
`AServiceManager_registerLazyService{,WithFlags}` and calls the real eager
`AServiceManager_addService` (preloaded into the Power HAL, which runs as uid
1000). It printed no mark: the Power HAL never calls either symbol, so its
publisher path is something else (an eager `addService`
/`addServiceWithFlags`, or a registration that never happens). The Darwinn HAL
and the core still log `Unable to connect to Power HAL`; publishing IPower
needs the Power HAL's actual call site, not another lazy shim.

## U71 (2026-11-08): the Power HAL's registration was a VINTF gate; the lookup still misses it

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`.

**The refusal was the VINTF manifest.** servicemanager logged
`Caller(pid=…,uid=1000,sid=u:object_r:system:s0) Could not find
android.hardware.power.IPower/default in the VINTF manifest. No alternative
instances declared in VINTF.` and the Power HAL then died with `Fatal signal 11
… fault addr 0xfffffffd`. The chroot's `vendor/etc/vintf/manifest.xml` had no
`android.hardware.power` entry at all. `device/cheetah/tpu-vintf-manifest.xml`
now declares `android.hardware.power` (`IPower/default`) and
`google.hardware.power.extension.pixel` (`IPowerExt/default`); installed in the
chroot it makes servicemanager answer `Found
android.hardware.power.IPower/default in device VINTF manifest.`

**The Power HAL now survives**, both as uid 1000 and as root: it logs "…with
Extension is started." and stays up. The Darwinn HAL's lookup still fails:
`[libbinder.ServiceManagerCppClient] Waiting for service
'android.hardware.power.IPower/default' on '/dev/vndbinder'…`, then `Service
android.hardware.power.IPower/default didn't start. Returning NULL`, then
`[Darwinn] Unable to connect to Power HAL`. On its side the Power HAL prints
`[libbinder.BackendUnifiedServiceManager] Thread Pool max thread count is 0.
Cannot cache binder as linkToDeath cannot be implemented. serviceName:
android.hardware.power.IPower/default` right after the VINTF check, then reports
itself started, and servicemanager logs no further refusal. So either the
addService transaction fails after the manifest check and the Power HAL ignores
the status, or the service is published somewhere the C++ lookup does not look.

**The forwarder cannot call the real symbol.** `tools/android-addsvc-real.c`
overrides `AServiceManager_addService` and calls `dlsym(RTLD_NEXT, …)`; that
returns NULL in this chroot (the mark reads `REFUSED ex=0xdead`, our "status was
NULL" value), so nothing was forwarded and the probe told us nothing about the
real status. Use `dlopen("/system/lib64/libbinder_ndk.so", RTLD_NOW)` +
`dlsym(handle, …)` if a probe still needs it.

**Next probe:** a tiny root client in the chroot that starts the binder thread
pool, registers a test service with `AServiceManager_addService`, and looks the
same name up with `AServiceManager_getService` in the same process, printing
both `AStatus` codes. If the lookup fails there too, servicemanager drops the
add after the VINTF check; if it succeeds, the Power HAL's binder or instance
name is the difference.

**Phone state:** chain up (servicemanager 9599, tachyon service 9673, Darwinn
HAL 9724/9726, Power HAL 9615 as root). No inference, no benchmark.

## U72 (2026-11-08): the runner was killing the Power HAL; its service still misses

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`.

**A bug of ours, not of the HAL: `pkill -x android.hardwar`.** The runner killed
the old Darwinn HAL by its comm before starting a new one, and Linux truncates
comm to 15 characters, so `android.hardware.power-service.pixel-libperfmgr` has
the same comm, `android.hardwar`. Starting the HAL therefore killed the Power
HAL, and servicemanager dropped its service with the process. It is now
`pkill -f 'android.hardware.neuralnetworks@service-darwinn-aidl'`, and the Power
HAL stays up ("…with Extension is started.", pid 16920/17279).

**Its service is still not in the map.** `tools/svclookup-check.c` now looks up
the power names too; on a live chain started with `NO_DELEGATE=1` it prints, as
root: `SVC android.hardware.power.IPower/default NULL`,
`SVC …IPowerExt/default NULL`,
`SVC com.google.edgetpu.tachyon.IComputeService/default FOUND alive=1`. So
servicemanager serves the Tachyon service but never gets IPower, while the Power
HAL is alive. servicemanager logs `Caller(pid=<power hal>) Found
android.hardware.power.IPower/default in device VINTF manifest.`, and the
Darwinn HAL still logs `[Darwinn] Unable to connect to Power HAL`.

**The forwarder now reaches the real symbol but cannot read its status.**
`dlsym(RTLD_NEXT, …)` never resolves here; `dlopen("libbinder_ndk.so",
RTLD_NOW)` + `dlsym` does, and the run prints
`ADDSVC-REAL android.hardware.power.IPower/default ex=0xfffffffffffffc19`,
which is -999, the shim's "status was NULL or the accessor was missing" value.
The library does export both `AServiceManager_addService@@LIBBINDER_NDK` and
`AStatus_getExceptionCode@@LIBBINDER_NDK`, so the real call returned a NULL
status to the wrapper although servicemanager saw and VINTF-checked the call.
That needs one more field printed (the status pointer itself, and `AStatus_isOk`)
before any conclusion.

**The chroot has only the framework `libbinder_ndk`.** There is no
`/vendor/lib64/libbinder_ndk.so`; the framework one links `libbinder.so`, so the
NDK and C++ paths share one `ProcessState` and one binder device. That rules out
a simple device split between the Power HAL's add and the HAL's lookup.

**Probe caveat:** a standalone probe must preload `libnosid.so`; without it a
uid 1000/10000 lookup returns NULL for every name (the same reason the services
need it), so the earlier "uid 10000 finds nothing" result says nothing about
permissions. Root's result above is without preloads and is the meaningful one.

**Next:** print the status pointer and `AStatus_isOk` in the forwarder; then try
a registration through the C++ `defaultServiceManager()` from a shim, which
publishes on the same device the HAL and the core read from. Independently of
this, the firmware setup does not need the Power HAL: the client path with the
type-1 message and the HAL's `SetupFirmware` remain the direct routes (U67).

## U73 (2026-11-08): the setup command runs and the firmware refuses it (error 9)

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, no oops this boot.

**The client path now runs end to end.** With `NO_DELEGATE=1` and the client as
uid 1000 (`LD_PRELOAD` without `liblazysvc.so`, which references
`AServiceManager_addService` that a non-service binary does not import):
`createSession: OK`, `setupCommandQueue: OK fds=11,12`,
`setupResponseQueue: OK fds=14,15`, and the core logs
`state UNINITIALIZED to CREATED`, `CREATED to STARTED`, `STARTED to
AUTHORIZED`. `sendCommand: OK` three times; every `receiveResponse` is
`NOT-OK exception -8 service 8` (the empty-FMQ error), so no answer is
produced. No `Sending firmware-setup VII command` line appears and `get_fds`
is never called. This confirms U65/U66 from the client side: an AUTHORIZED
session with a queued command is not enough, because the core's setup push is
the DSP/GXP actor's and that actor has no vendor `gxp` driver.

**The HAL's setup path does run, and the firmware rejects it.**
`libdarwinn_hal.so` at `0x14d9a48` already reads `35 04 80 52`
(`mov w21, #0x21`, the U67 forced bitset), and no `.orig` copy was present, so
the patch was still in place. The HAL alone as system only allocates and
finalizes a group (`edgetpu_device_group_alloc+0xf4` in the dmesg trace) and
runs no setup. The full chain as system (HAL plus `/vendor/bin/edgetpu-run`)
does reach it: the delegate logs

```
INTERNAL: Sync VII command failed: error_code=9
file.cc:1506
create device status: 13
```

and `dmesg` shows `KCI tx code 10 seq 65` followed by `KCI tx code 21 seq 66`
and two mailbox IRQs. So the setup element is written to the queue, the
firmware answers it, and the answer is an error (9) that the lib reports as a
failed sync; the delegate then exits 1 (`delegate rc: 1`).

**Next:** decode `error_code=9` at `file.cc:1506` and the matching VII
response element (the driver's 48-byte dump), then give the firmware the
payload it accepts. U67 records that the firmware wants a **type-1** setup
carrying `global scratches`; the HAL writes a different type (its element has
`u16 11` at byte 10). Either build the type-1 payload for the HAL's setup call
or drive it through the client's `CommandMessage` (whose `build_cmd` is still a
placeholder). The client session being AUTHORIZED means the AIDL and FMQ sides
are no longer the blocker.

## U74 (2026-11-08): the HAL's setup element is not the firmware's setup

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`.

**The forced setup call and what follows it.** In `libdarwinn_hal.so` the gate
is `0x14d9cc0: tbz x21, #0x20, 0x14d9cf0`; the U67 patch (`mov w21, #0x21` at
`0x14d9a48`) makes it fall through to `0x14d9ce4: bl 0x15179fc`, the setup
builder. It allocates a **48-byte** element (`0x1517a50: mov w0, #0x30`), fills
it from a 16-byte source plus the bitset, and returns. After the call the HAL
sets `0x14d9cf4: mov w9, #1; 0x14d9cf8: stlrb w9, [x19, #0x180]` — that is
`firmware_setup_done_`. So the HAL **marks setup done even when the sync
fails**, which is why a second delegate run can skip it and why the flag is not
evidence that the firmware accepted anything.

**Error 9 is a precondition failure, not a transport error.**
`libdarwinn_hal.so` and `libdarwinn_dba_hal_runtime.so` carry the canonical
gRPC names (`FAILED_PRECONDITION`, `INVALID_ARGUMENT`, `UNIMPLEMENTED`,
`ABORTED`, `RESOURCE_EXHAUSTED`, `NOT_FOUND`, `PERMISSION_DENIED`), and the
runtime logs `Sync VII command failed: error_code=%u`. In that enumeration 9 is
FAILED_PRECONDITION, which matches the firmware's `Setup is not done yet`
answer: the element was delivered and answered, it just does not perform the
setup the firmware wants.

**The shape of the mismatch.** U67 recorded the HAL's element as
`00000000 00000000 000b0000 00000000 ffeff000 00000000 00000080` then zeros —
a `u16` 11 at byte 10. The core's own push logs `Sending firmware-setup VII
command. type: ` and, in the recorded runs, a type of **1**. The HAL's 48-byte
element is not the core's type-1 setup with global scratches.

**Next:** recover the core's type-1 setup element from `libtachyon_core.so`
(the push helper and the flatbuffer builder/verifier recorded in U67:
`0xa4dec`, `0xa4d5c`, `0xb9c48`), or, if the difference is only the type, patch
the 48-byte element's byte 10 from 11 to 1 in the HAL's builder and re-run the
full chain as system. The client session is no longer the problem: it reaches
AUTHORIZED with a working command queue.

## U75 (2026-11-08): the firmware's error 9 is its own status; the VII payload is dumped

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`.

**Error 9 is the firmware's code, not a host or transport error.**
`drivers/edgetpu/edgetpu-kci.h` names the whole table:
`KCI_ERROR_OK = 0`, `…CANCELLED = 1`, `…UNKNOWN = 2`, `…INVALID_ARGUMENT = 3`,
`…DEADLINE_EXCEEDED = 4`, `…NOT_FOUND = 5`, `…ALREADY_EXISTS = 6`,
`…PERMISSION_DENIED = 7`, `…RESOURCE_EXHAUSTED = 8`,
`KCI_ERROR_FAILED_PRECONDITION = 9`, then `…ABORTED = 10` and so on. So the
firmware answered the setup sync with FAILED_PRECONDITION, and the runtime's
`Sync VII command failed: error_code=%u` prints it from a `u16` in the response
element. The same header also explains the "KCI tx code 21" heartbeat in
`dmesg`: `KCI_CODE_GET_USAGE_V2 = 21` (and `KCI_CODE_FIRMWARE_INFO = 11`).

**The element's field names matter.** `struct edgetpu_command_element` is
`u64 seq; u16 code; u16 reserved[3]; struct edgetpu_dma_descriptor dma;`. The
`u16` at byte 8 is `code`; the value U67 read as "type 11" at byte 10 is
`reserved[0]`, not a type. The DMA descriptor's iova is at byte 16 and its size
at byte 24, which is what the mailbox dump reads.

**The driver dumps the setup payload.** `edgetpu-mailbox.c` has
`edgetpu_vii_payload_dump` (a bring-up aid) that copies the element and its
payload to `dmesg`. From the full-chain run as system, the 128 bytes the HAL's
`SetupFirmware` submitted are:

```
vii-payload 0:   00000014 00000000 000a0000 00080012
vii-payload 16:  000c0007 0000000a 05000000 00000030
vii-payload 32:  0000000c 00060000 00040008 00000006
vii-payload 48:  00000004 00000001 ffe80000 00000000
vii-payload 64:  00080000 00000000 00000000 00000000
```

The first `u32` is 0x14, a flatbuffer-shaped root offset, but the table at 20
does not parse as one (its vtable soffset lands on a zero size), so the layout
is not the core's `CommandMessage` as built by `libtachyon_core.so`. That is the
next thing to decode: the payload the HAL submits is host-built and is what the
firmware rejects.

**Next:** parse this 128-byte payload against the core's builder in
`libtachyon_core.so` (log at `0xa4d5c`, push at `0xa4dec`, verifier `0xb9c48`),
or replace it with the core's type-1 message built in the client and pushed
through the AUTHORIZED session. The response element (`u16` status) is visible
to the driver's IRQ handler, so every attempt can be read back.

**The element and its payload parse.** From the same run (dmesg, `vii-elem`):

```
00000000 00000000 000b0000 00000000 ffdff000 00000000 00000080
00000000 00000000 00000002 00000000 00000100
```

as `struct edgetpu_command_element`: `seq = 0`, `code = 0` (u16 at 8),
`reserved[0] = 11` (u16 at 10, the value U67 read as a type), `dma.iova =
0xffdff000` (u64 at 16), `dma.size = 0x80` (u32 at 24), then `2` at byte 36 and
`0x100` at byte 44.

The 128 bytes at that iova are a flatbuffer after all, read as bytes rather than
as printed words: root uoffset `0x14` at 0 → table at 20; at 20 a soffset of 10
→ vtable at 10; the vtable is `size 10, table size 18`, with fields at `+8`
(value 48), `+7` (value 5) and `+12` (a uoffset to 44, where the `u32` is 6).
So the HAL does send one command message with three fields, and the firmware
still answers FAILED_PRECONDITION. U67's note that the firmware names its own
missing piece — `No global scratches were provided in setup command.` — is the
next thing to match against these fields: the message carries the bitset (48)
and a small value (5), but no scratch descriptors.

## U76 (2026-11-08): the client's commands never reach the firmware; the HAL is the only VII writer

The chain (`NO_DELEGATE=1`, `RUN_UID=10000`) plus the client at uptime 26262,
two rounds: `createSession: OK`, `sendCommand: OK` both times,
`receiveResponse: NOT-OK exception -8 service 8` with an all-zero 256-byte
buffer. And `dmesg` over the client's window holds **no `vii-` and no
`janeiro` line at all**; the `vii-elem` count is 0.

So `sendCommand` only fills the session's command FMQ. The core's actor never
syncs that queue to the TPU — it is waiting on the DSP actor (U65) — so the
client path cannot reach VII no matter what message it builds. Every VII
element seen in dmesg so far came through the HAL's own group: the delegate's
`CreateDevice` (U75) and its setup sync (U55). The HAL is the only writer.

That also settles the firmware's "command of type 0": it is the element's
`code`, and the HAL's `SetupFirmware` sends a regular command, not a setup
message. To get a type-1 element to the firmware the HAL's element has to carry
it — either by patching where the HAL's command descriptor is built, or by
rewriting the element between the build and the ioctl.

## U77 (2026-11-08): the VII element is not built by the 0x15179fc store

A gdb breakpoint set just after the element store (`0x1517a70` in
`libdarwinn_hal.so`, at `base + 0x1517a74`) was attached to **every** process
that maps the library — 26 of them, both `android.hardwar` LWPs, the vendor
service, the Tachyon core and their threads. The delegate ran and the mailbox
still dumped the same element at uptime 3705:

```
vii-elem: 00000000 00000000 000b0000 ... ffdff000 ... 00000080 ...
```

with `code` 0 at byte 8, and **not one gdb hit**. So the VII element is not
assembled by that builder at all: the runtime writes it directly into the
mapped command queue and only `EDGETPU_SYNC_BUFFER` (nr 16) reaches the driver.
The 0x15179fc function belongs to a different message path (U67's call site
still explains the HAL's call, but not this element).

Two instruments are left, in this order:

1. **Userspace, no reboot.** Catch `EDGETPU_SYNC_BUFFER` (`_IOW(0xED, 16, 24)`
   = `0x4018ed10`) with gdb, and in that stopped process find the 48-byte
   element by its dumped bytes in the mapped queue, then rewrite byte 8 to 1
   before the doorbell. The element's bytes are known exactly from the dump, so
   `find` over the process's mappings is enough; the device address
   (`0xffdff000`) is the queue's TPU address, not a userspace one.
2. **Kernel, one dev build.** In `drivers/edgetpu/edgetpu-mailbox.c`, the VII
   receive path that schedules `edgetpu_vii_payload_dump` sees the element
   before the firmware does. A development-only rewrite of the first element's
   `code` to 1 there, then a module rebuild and a reboot, answers the same
   question without gdb.

If the firmware accepts a type-1 element, its next error names the next missing
field; if it still says "setup not done", the type is not the element code and
the core's message layout has to be recovered instead. `oops: 0` after all
three gdb runs.

## U78 (2026-11-08): the element is not in userspace; the type-0 path is closed

Scanning every readable mapping of the HAL, the vendor service, the Tachyon
core and servicemanager twice during a live delegate run, for the element's
full 48 bytes (including `iova 0xffdff000`, `size 0x80`, the `2` and the
`0x100`), found **nothing**. The element exists only in the driver's coherent
command queue (`group->vii.cmd_queue_mem`), which userspace maps uncached and
`/proc/<pid>/mem` will not read. So:

- a userspace rewrite before the doorbell is not possible;
- a kernel rewrite has no hook before the doorbell either — the dump runs from
  the IRQ after the firmware advanced the head, and the doorbell itself is a
  userspace store to the mapped CSR page.

And even a `code` of 1 would not be a setup message: the element is the HAL's
ordinary sync over an 0x80-byte command flatbuffer with no scratch descriptors,
which is exactly what the firmware's own string says it needs. The element-code
hypothesis is closed; U55/U67 stand: **the setup must come from the Tachyon
core's type-1 message**, and the core's actor cannot run without the vendor
`gxp` driver.

Next: recover that message. `libtachyon_core.so`'s push is at `0xa4d5c` with
the builder at `0xa4dec` and the verifier at `0xb9c48`; the same library
exports no setup symbol, so the call is either by address from a chroot
program (dlopen + base + `0xa4d5c`) or through the app service's own path.

## U79 (2026-11-08): the setup producer is the HAL's runtime, not the core

Searching every removed library for the setup strings puts them here:

```
libdarwinn_hal.so:    0x4b8c71  Firmware setup failed for commands[%d], cluster_id_bitset in hex: %x.
libedgetpu_util.so:   0x67ce7   (same string)
```

and the `firmware_setup_done_` wakelock lambda beside it. **Neither string is
in `libtachyon_core.so`.** Disassembling U67's `0xa4d5c` shows it inside a
hash/lookup helper starting at `0xa4d54` (it hashes two `w` arguments through a
virtual call and returns a small object), not a message builder, so that
address was a log site read out of context, not the push.

So the runtime that builds a firmware-setup command is the HAL's own
`libdarwinn_hal.so`, which does call the firmware setup and logs
`commands[0], cluster_id_bitset in hex: 0` when the firmware refuses. Its
command list's bitset is 0, and the payload it builds carries `0x30` in the
first field — two different numbers. The next probe is the HAL's command
construction itself: the xref of the `Firmware setup failed` string names the
function that walks `commands[]`, and its `cluster_id_bitset` and command type
are what the firmware is actually judging.

## U80 (2026-11-08): the HAL's setup runs and is the same pre-Tachyon message

U67's patch at `0x14d9a48` (`mov w21, #0x21`) was found to **disable** the
setup, not force it: the next gate is `tbz x21, #0x20` at `0x14d9cc0`, which
tests bit 32, and `mov w21, #0x21` clears it, so `SetupFirmware` branches past
its builder at `0x14d9ce4`. That is why every gdb breakpoint at the builder
missed and why the element seemed to come from nowhere.

Restoring the original `mov x21, x2` (`f5 03 02 aa`) and running the chain as an
app uid (`RUN_UID=10000`, so the delegate goes through the HAL) makes the HAL's
own setup run: three `create device status: 13` attempts, `delegate rc: 1`, and
the same element three times — `code` 0, `0x0b` in `reserved[0]`, iova
`0xffdff000`, size `0x80`, payload root offset 20 — exactly the pre-Tachyon
`RequestAllocation` message the delegate's own runtime sends.

So there is no bitset or type to fix in the HAL: both runtimes in the A17 image
send the obsolete message, and the firmware wants the Tachyon setup that only
the core implements. The core's actor needs the vendor `gxp` driver (U65), and
nothing else in the image produces that message. The TPU is blocked on that
producer, not on a number in the HAL.

Options, in order of cost:

1. **Hand-build the Tachyon setup message** from the firmware's parser (the
   flatbuffer it accepts, with global scratches) — research, no producer needed.
2. **Find another A17 producer**: the app-service APK/native side or another
   library that carries the Tachyon setup rather than the obsolete one.
3. **Run the CPU/GPU baseline** of the 720p benchmark now, so the comparison has
   measured numbers even while the TPU side is blocked.

## U81 (2026-11-08): the producer hunt and the first measured baseline

**The hunt.** No binary in the A17 image carries `global scratch` or
`RequestAllocation`; the only scratch string anywhere is `scratch_capacity >=
min_capacity` inside `libtachyon_dsp_core.so`. That library is the GXP **server**
(`gxp_tachyon_server`, virtual devices, command packets), and its own paths go
through `libgxp.so` to `/dev/gxp`; `libgxp.so` checks `Expected gxp kernel
driver version` and `Device creation failed`. The kernel tree has no
`drivers/gxp`, so the DSP side is closed on mainline for the same reason as U65,
not a separate bug.

So the two runtimes that do reach VII (`libdarwinn_hal.so` and
`libedgetpu_util.so`) both speak the pre-Tachyon message, and the only Tachyon
producer is a userspace server that cannot open its device. There is no
shortcut left in the image: the setup message must be hand-built, or a gxp
driver written.

**The baseline.** `tools/bench-object-detection.py` on `out/bench/` with
`detect.tflite` (SSD MobileNet, 300x300), `mosaic720.mp4`, 60 frames, CPU
XNNPACK, 4 threads:

- mean 3.86 ms, p50 3.79 ms, p95 4.27 ms, 259.37 fps
- detections: mean 9.0, max 9.0; person 420, teddy bear 120

The same run on the phone (LiteRT pip install) could not be done: PyPI is not
reachable from the phone within 5 s, so the install was abandoned and cleaned
up. The laptop CPU number is measured; the phone CPU and GPU legs still need a
runtime that exists on that image.

**What this means for the comparison.** The 60-frame clip has a mean of 9.0
detections per frame, so the "10+ objects" target is not met by this clip as
decoded at 300x300; a clip with more simultaneous objects (or a lower threshold,
which must be reported as such) is needed for that part of the request.

## U82 (2026-11-08): the firmware blob is not aarch64, and its code section is not readable

The driver loads `/lib/firmware/updates/google/edgetpu-janeiro.fw` (1,038,272
bytes). Pulled to `out/fw/` for local analysis (never committed). Its rodata is
plaintext: `Setup is not done yet received a command of type %d.` at 0xefbdc and
`No global scratches were provided in setup command.` at 0xefe18.

The blob is not a plain image: zero `\x7fELF` occurrences, no aarch64 `ADRP`+`ADD`
xref to 0xefe18 (and no `stp x29, x30` prologues), no qword or dword pointer to
the string either. Entropy per 256 KiB is 7.19, 7.22, 7.21 and 6.53, so the code
section is compressed or encrypted while the string table sits in the lower-
entropy tail. Reading the setup parser therefore needs the container format and
its key, not just a disassembler.

With U81 this makes three walls on the VII side: the HAL and the delegate's
runtime both send the obsolete message, the only Tachyon producer in the image
needs `/dev/gxp`, and the firmware that would define the new message cannot be
read. The realistic paths left are a gxp kernel driver (large, out of scope for
this bring-up) or Google's Tachyon host stack with the kernel side it expects.

## U83 (2026-11-08): measured CPU and GPU legs, and the GXP node is absent

The SSD benchmark (`detect.tflite`, 300x300, threshold 0.5, 60 frames) on the
laptop, same clips for every leg:

| clip | objects/frame | backend | mean ms | p50 | p95 | fps |
| --- | --- | --- | --- | --- | --- | --- |
| mosaic720.mp4 | 9.0 | CPU (XNNPACK, 4 threads) | 3.86 | 3.79 | 4.27 | 259.37 |
| mosaic720.mp4 | 9.0 | GPU (WebGPU, RTX 3070) | 2.79 | 2.43 | 2.83 | 357.78 |
| mosaic12.mp4 | 10.0 | CPU (XNNPACK, 4 threads) | 3.97 | 3.87 | 4.61 | 251.99 |
| mosaic12.mp4 | 10.0 | GPU (WebGPU, RTX 3070) | 3.00 | 2.54 | 3.65 | 333.29 |

`mosaic12.mp4` is a 1280x720, 60-frame clip built from `mosaic720.mp4`'s own
person crops (4 distinct patches cycled into a 4x3 grid, slight per-tile jitter),
so every frame carries 12 person instances and the detector finds 10.0 mean,
10 max at threshold 0.5. The GPU leg is LiteRT's `CompiledModel` with
`HardwareAccelerator.GPU | CPU` (WebGPU); the CPU leg is the plain interpreter.

No phone leg exists: the A17 image has no TFLite runtime library, and PyPI is
unreachable from the phone, so the CPU/GPU numbers above are the measured
comparison until a runtime exists there.

**The GXP node is absent from our DT.** A walk of `/proc/device-tree` finds no
node named or compatible with `gxp`, and no `edgetpu` node either (the janeiro
driver binds elsewhere); `/sys/bus/platform/drivers/edgetpu/` is empty. So a
minimal gxp driver has no register base in the device tree to start from: the
first step would be recovering that node's description from stock's A17 DT, then
a read-only probe of a register block whose power and clock state we do not yet
know. Both are outside the §1.1 grant (unknown block reads need the owner's go
per step), so nothing was probed.

**Conclusion for T6.** The VII route is closed on evidence: both A17 runtimes
send the pre-Tachyon setup the firmware rejects (error 9), the only Tachyon
producer is a userspace GXP server with no `/dev/gxp`, and the firmware's code
section is compressed or encrypted so its parser cannot define the message. The
TPU needs a gxp kernel driver (plus its DT description) before any inference is
possible; no TPU benchmark number exists and none is claimed.

## U84 (2026-11-08): the A17 gxp node recovered from the factory image

The project already holds the A17 factory image (`out/factory/cheetah-factory.zip`,
build `cheetah-cp2a.260705.006`). Its inner image zip carries
`vendor_kernel_boot.img`, and that image holds three DTBs with a `google,gxp`
node (file offsets 0x5f3000, 0x63a8d6 and 0x683be1; extracted to
`out/stock-a17/vkb/`, never committed). Read with a small FDT reader
(`out/stock-a17/fdt.py`; this host has no dtc):

```
/gxp@25C00000 {
    compatible = "google,gxp";
    reg-names = "aur", "mailbox0", "mailbox1", "mailbox2", "mailbox3",
                "cmu", "ssmt_idma", "ssmt_inst_data";
    reg = <0x0 0x25c00000 0x1400000>,   /* aur */
          <0x0 0x18380000 0x1000>,      /* mailbox0 */
          <0x0 0x183a0000 0x1000>,      /* mailbox1 */
          <0x0 0x183c0000 0x1000>,      /* mailbox2 */
          <0x0 0x183e0000 0x1000>,      /* mailbox3 */
          <0x0 0x25a00000 0x1000>,      /* cmu */
          <0x0 0x25ad0000 0x10000>,     /* ssmt_idma */
          <0x0 0x25ae0000 0x10000>;     /* ssmt_inst_data */
    interrupts = <0 0x4f 4>, <0 0x50 4>, <0 0x51 4>, <0 0x52 4>, <0 0x83 1>;
    iommus = <0xc7 0xc8>;  samsung,iommu-group = <0xc9>;
    gxp-fw-region = <0xca>;         /* gxp_fw@98000000, 0x400000, no-map */
    gxp-scratchpad-region = <0xcb>; /* gxp_scratchpad@98400000, 0x100000 */
    tpu-device = <0xc6>;  gsa-device = <0xb>;
    gxp-tpu-mbx-offset = <0xc0000>;
    pasid-num-bits = <3>;
    dma-window = <0x1000 0xfffff000>;
    gcip-dma-window = <0x30000000 0xc0000000>;
    gcip-reserved-map = <0x80000000 0x1000>;
    gxp-memory-per-core = <0x200>;
    gcip-dvfs-table = <7 entries of frequency/voltage pairs>;
};
/gxp-cooling { #cooling-cells = <2>; };
```

So the register base the last round said was missing exists: the AUR block at
0x25c00000, mailboxes at 0x18380000-0x183e0000, CMU at 0x25a00000, the two SSMT
windows, SPIs 0x4f-0x52 and a PPI. What still has to come from stock is the
iommu group wiring and the phandle targets (0xc6 TPU, 0xb GSA), which our tree
must express with its own labels.

The node's `reg` is the first hard requirement for a driver; the second is
`libgxp.so`'s ioctl contract on `/dev/gxp`. A direct ADRP+ADD xref to the
`/dev/gxp` string (vaddr 0x38a11) finds none, so the library reaches it through
a pointer table; locating that table and the `ioctl` call sites is the next
step.

### U84 follow-up: the libgxp scan

`libgxp.so` imports `open`, `close`, `read`, `write`, `ioctl` and `mmap` (LIBC),
so the device contract is reachable from its call sites. The `/dev/gxp` string
at vaddr 0x38a11 has no ADRP+ADD pair (the first scan's ADD mask was wrong,
which is fixed; the corrected scan still finds none), no 8-byte pointer to it in
any section, and no relocation with it as an addend. So the string is reached
through a GOT/PLT path or built at runtime. Next: dump the `.plt` stubs and the
`ioctl` GOT relocation, find the `bl` sites to that stub, and read the command
numbers and struct sizes from the argument setup around each call. That is the
contract a driver must satisfy before any register access.

## U85 (2026-11-08): the gxp ioctl contract, the node, and the skeleton driver

**The ioctl contract.** `libgxp.so` imports `ioctl` through its PLT; the stub
for the GOT slot at 0x1e0eb8 sits at 0x1cd8b0, and exactly three calls reach it
(decoded with capstone, since this host's binutils cannot disassemble aarch64):

- 0x12c1f8: cmd **0x40086200** (`_IOW('b', 0, u64)`), 8-byte argument at
  `sp+0x68`, fd from `[x19, #0xa8]`;
- 0x12e28c: cmd **0xc0184800** (`_IOWR('H', 0, 24)`), 24-byte argument at
  `sp+0x18`, fd in `w22`;
- 0x12e3d4: cmd **0x40086201** (`_IOW('b', 1, u64)`), pointer argument in
  `x2`, fd in `w25`.

The first is followed by the third on the error path, so the pair brackets a
virtual device's life; the middle one carries 24 bytes of device information.

**The node.** The base tree now carries `gxp: gxp@25c00000` with the recovered
reg/reg-names/interrupts, `gsa-device`, `tpu-device`, the mailbox offset and
the per-core memory, `status = "disabled"`. `device/cheetah/overlays/gxp-probe.dtso`
enables it. Compiled with the tree's `dtc` 1.7.2 and applied with `fdtoverlay`
onto a cpp+dtc build of `gs201-cheetah.dts`: the overlaid tree has the node
with `status = "okay"` and the eight register windows.

**The skeleton.** `drivers/gxp/` (`gxp.c`, `Kconfig`, `Makefile`), hooked into
`drivers/Kconfig` and `drivers/Makefile` under `CONFIG_GXP`: probe maps the
AUR window with `devm_ioremap_resource`, registers `/dev/gxp` as a misc
device, and the three commands above answer `-ENOSYS`. No register is read or
written, no firmware is loaded and no mailbox or CMU is touched.

Build: the module compiles in the project container with the pinned Android clang and `ARCH=arm64` (`CONFIG_GXP=m`; `gxp.ko` produced, `modinfo` shows `of:google,gxp`, aarch64). The blockers were the skeleton's missing `miscdevice` member, the host's missing `bc`, and an `olddefconfig` without `ARCH=arm64` that pointed the out tree at the host arch. The build used `M=$K/drivers/gxp` (absolute), so its artifacts landed in the source tree and were removed.

## U86: the gxp node probes and the ioctl lifetime runs (2026-11-08)

`gxp-probe` is in `device.conf`'s `DTB_OVERLAYS`, and `push` with it boots a
tree whose `/proc/device-tree/soc@0/gxp@25c00000/status` reads `okay`; the
skeleton module then binds, maps `[mem 0x25c00000-0x26ffffff]` and registers
`/dev/gxp` (10,258). No register is read and no firmware or mailbox is touched.

The three decoded commands now have a real lifetime: create (`0x40086200`,
the 8-byte argument is an input, libgxp passes 7) allocates an id and returns
it (test: handle 1), release (`0x40086201`) frees it, and info (`0xc0184800`,
24 bytes) answers `-EOPNOTSUPP` until its layout is known. On-phone run:
`create: ok, arg is now 1`, `info: errno 95`, `release: ok`.

The first create answered EINVAL because the xarray was `xa_init()`ed without
`XA_FLAGS_ALLOC`: `__xa_alloc()` hits `WARN_ON_ONCE(!xa_track_free(xa))` and
returns `-EINVAL`. `xa_init_flags(&gxp->devices, XA_FLAGS_ALLOC1)` fixes it.

Getting the DTB onto the phone took the `push` path: `flash` needs fastboot,
and ABL ignored the bootloader reason (the crash fallback booted Linux again),
so it was left for the owner's buttons. `push` requires
`modules-<release>.tar.zst`; it was built from the phone's own module tree plus
`extra/gxp.ko` (22M, `OMAMOBILE_MODULES_REPLACE=1`) after pinning
`CONFIG_LOCALVERSION` to the running kernel's exact string
(`-omamobile-push1-g052da70970d6-dirty`, AUTO off), so the module's vermagic
matches without `--force`.

## T-runbook: the first AUR register read (owner-gated, not run)

Preparation only; no step here has been executed. The AUR block's power and
clock state is not established: the bootloader leaves the GXP node present and
our driver only maps it, so a read of an unpowered AUR block can abort the SoC
(AGENTS.md, "Read only blocks that are known powered and clocked"). The
vendor kernel's GXP driver is the source for the power-on sequence, the CMU
gate that proves the block is up, and the first safe register; it must be read
before this runbook is filled in. Each step below needs the owner's explicit
go, one register per call, under `--watchdog`, with USB on the dead-man switch.

T0 (read-only, no phone write): record `uname -r`, `dmesg | grep -i gxp`, the
node's `status`, `/dev/gxp` and the module's refcount; confirm `oops: 0`.
Stop: any oops or a missing device.

T1 (waiting on the vendor driver): read the CMU register that gates the GXP
block, one 32-bit read at the address the vendor driver uses. Expect the gate
on. Stop: any value that does not match the vendor driver's "on" bit, or a
hang.

T2 (only after T1 passes): read one AUR register the vendor driver reads in
probe, one call. Stop: a hang, an abort, or a value that differs from the
vendor driver's reset value.

## U87: the Tachyon service reaches /dev/gxp (2026-11-08)

With `/dev/janeiro -> gxp` (the runner's readiness check passes, and its
`chown root:1000` on the symlink gives the service uid 1000 access),
`/root/tpu-tachyon-run` starts servicemanager, the power HAL and
`com.google.edgetpu.tachyon-service`; the service opens the node.

Its first GXP commands are not the three libgxp ones decoded in U85:

- `0xc018ed24` (24 bytes) -> ENOTTY;
- `0x4014ed06` (20 bytes, logged as `attr cmdq_kb 12 rspq_kb 6 cmd 48 rsp
  24 flags 0x58`) -> ENOTTY;

and it stops at `INTERNAL: Could not create device group: master_fd=3
(Inappropriate ioctl for device)`. `create device status: 13` appears before
them, so the Tachyon client path sends a different command set than the HAL
path that produced the U85 three.

Next: log both commands' argument bytes in `gxp.c` and answer `-EOPNOTSUPP`
until the layouts are decoded; the 20-byte command already carries the group's
queue sizes (cmdq 12 KiB, rspq 6 KiB, cmd 48, rsp 24, flags 0x58).

## U88: a clean boot powers the TPU and drives both drivers (2026-11-08)

The 0xed commands in U87 are **janeiro's**, not GXP's: the
`/dev/janeiro -> gxp` symlink had pointed the TPU driver's node at the wrong
driver. With the symlink removed and `janeiro.ko` loaded from
`/usr/lib/modules`, a cold boot with exactly one TPU power-up (`tpu-hold`)
runs the stack:

- janeiro's group create (`0x4014ed06`, the 20-byte attr: cmdq 12 KiB, rspq
  6 KiB, cmd 48, rsp 24, flags 0x58) returns 0, as do the eventfd
  registrations (`0x4008ed05`), `0xed08`, `0xed19`, `0x4004ed0e` and
  `0x4028ed12`;
- the Tachyon service exercises the GXP driver too: `0x40086200` (create) and
  `0x40086201` (release) both return 0 on `/dev/gxp`;
- dmesg shows KCI tx (code 10 seq 10, code 21 seq 11), so the firmware
  handshake completed.

What still fails: the delegate logs `create device status: 13` and exits 1,
and dmesg carries a trace through `edgetpu_mmu_tpu_unmap_sgt` /
`edgetpu_unmap_dmabuf` during teardown. The two 0xed cases added to `gxp.c`
for U87 were removed: the driver knows only its own three commands.

## U89: the app-uid delegate still fails on VII (2026-11-08)

Running the runner with `RUN_UID=10000` (the app uid whose EACCES on
`/dev/edgetpu` is supposed to select the Tachyon client path) changes nothing:
the delegate still logs `Sync VII command failed: error_code=9` three times,
then `create device status: 13` and `delegate rc: 1`. The Tachyon service is
up and janeiro's group create is 0, so the failing VII command is issued
inside the client path, not by a root delegate opening the node directly.

The same run repeats a kernel warning in the teardown path:
`iommu_set_fault_handler` (drivers/iommu/iommu.c:2061) and
`samsung-iommu.c:726 unmap_slpt`, reached through
`edgetpu_mmu_tpu_unmap_sgt` -> `dmabuf_map_callback_release` ->
`edgetpu_unmap_dmabuf`. It is a janeiro/samsung-iommu bug, not gxp's, and it
should be fixed before the next protocol step.

Next: find whether the Tachyon service ever issues the firmware's one-time
setup command (the VII error 9 is the pre-setup answer), and what the GXP
interface-version query returns to libgxp; the published gxp.h defines that
command as `_IOR(0xEE, 26, struct gxp_interface_version_ioctl)` with major 1,
minor 3.

## U90: the Tachyon client exists and its Ping round-trips (2026-11-08)

`/vendor/bin/tpu-tachyon-client` is the vendor's Tachyon protocol client (a
13 KiB C program that dlopens `libedgetpu_tachyon.google.so`). With the app
service and the Tachyon service up it creates a session, sets up the command
and response queues, sends a Ping and receives the 88-byte response; the
service logs `received command seq no: 1 of type : Ping`. Its own messages
show a fixed `sleep(120)` (`0x6094`) "for the service's setup" between the
first command and the rounds, so every earlier run that ended before 120 s
only saw the client's own wait.

`edgetpu-delegate` is not a Tachyon client: it is a second copy of the VII
delegate (`usage: edgetpu-run MODEL`, the same ioctls and the same status
13). The VII route stays closed.

The service only answers when it is in the state the boot-time vendor service
left it in. A service restarted by the runner with `NO_DELEGATE=1` logs the
session states but never `received command`; the client's rounds then fail
with `exception -8 service 8` and a 256-byte zero buffer. Next: find the
service's setup gate and what the vendor service does once at boot.

The published `gxp.h` ABI (`0xEE` base, `GXP_GET_INTERFACE_VERSION` 26) is
not what this libgxp uses: the service asks `0x40086200`, `0xc0184800` and
`0x40086201`, which our driver already answers. Adding the published command
would be a guess, so it stays out until a caller asks for it.

The two IOMMU warnings are fixed on `omamobile-tpu`: a domain may replace its
own fault handler (the pooled domain case), and unmapping an empty L1 entry
is a no-op instead of a warning.

## U91: the service's command path is not up on a fresh boot (2026-11-08)

A cold boot with `NO_DELEGATE=1` powers the TPU cleanly
(`PSM0_STATUS=0x4b27091`, `LPM_CONTROL=0x148`) and the client creates a
session, but every round answers `exception -8 service 8` with a 256-byte
zero buffer; the service logs `TachyonCore_CreateClientSession` and never
`received command`. Restarting only the Tachyon service on that boot gives
the same result.

The one good Ping (U90) happened on a service restart on a boot where the
vendor service had been up for half an hour and had already created its
group. So the missing piece is the service's transport setup, not the client:
its command queue is set up, but the service's actor never sees the Ping.

Also: `pkill -f "<service name>"` matches the SSH shell that carries the
pattern in its own command line and kills the session; use
`pkill -f "tachyon[.]service"`.

## U92: authorization is not the dispatch gate (2026-11-08)

With the Power HAL up (pid 3300), the real core (`libtachyon_core.so`,
1,538,440 bytes, sha `d1602625abb0`; the 1,015,720-byte
`libtachyon_core.so.cheetah-stub`, sha `47fb5f74`, is the A17 stub) and a
delegate run as uid 10000 first, a client session goes
CREATED -> STARTED -> AUTHORIZED within a millisecond. That delegate run is
what turned the earlier STARTED-only sessions into AUTHORIZED ones.

The Ping is still never dispatched: three spaced rounds and a 20 s wait
before the first command all answer `exception -8 service 8` with a
256-byte zero buffer, and the service never logs `received command`. So the
gate is the core's command-FMQ dispatch, not the Power HAL, the session
state or service startup timing.

The Tachyon service exits when its last client disconnects (the lazy
registrar shim), so every test must start it first. `pgrep -f` matches the
test shell's own command line when the pattern appears there; use
`ps -eo pid,args | grep '[c]om.google...'`.

The one good Ping (U90) remains the only dispatch ever seen.

## U93: the client's command queue is not the one sendCommand writes to (2026-11-08)

The phone's live core is the 1,538,440-byte `libtachyon_core.so` (sha
`d1602625abb0`): `] received command seq no: ` and ` of type : ` are in it.
The 1,015,720-byte copy in the laptop chroot is the stub, so every earlier
local `strings` check read the stub, not the phone's file.

The cheetah `libedgetpu_tachyon.google.so` (133,232 bytes) is not the
102,384-byte copy in the chroot either. It adds
`TachyonComputeSession_{begin,commit}CommandQueueWrite`,
`{begin,commit}ResponseQueueRead`, `setCallbackForGetFdsResponse`,
`getCoreVersion`, `getSessionHandle`, and config setters for the session
type, client version and queue slot counts.

Disassembly of it:

- `TachyonComputeSession_setupCommandQueue` / `setupResponseQueue` **move**
  two fds out of the session's state (offsets 0x68/0x6c and 0xc0/0xc4) and
  store -1 back, so the caller owns the raw queue fds after the call.
- `TachyonComputeSession_sendCommand` forwards to
  `ComputeSession::SendCommandMessage(TachyonMessage)`, which asks
  `BeginCommandQueueWrite(size, void** buf, size_t* a, size_t* b,
  size_t* c)`, memcpys the message and publishes the queue's write index
  with a `stlr`. It returns service-specific error 8 when the queue cannot
  take 128 bytes. No eventfd write is visible in that path.
- `begin/commitCommandQueueWrite` and `begin/commitResponseQueueRead` are
  the same queue object's explicit API (five out-parameters for begin, none
  for commit).

On the phone the service registers its queue fds when the session is
created (`registering fd 15 ... handler type: 0`, `registering fd 11 ...
handler type: 1`), the session reaches AUTHORIZED, and the actor logs its
**first epoll event only when the client is killed** 25 s later
(`received epoll event: 1 on fd 15`, then "Stopping due to client death or
protocol error"). A Ping sent in between produces no actor event and no
`received command`.

So the client's 64-byte Ping is written into a queue the actor never sees an
event for. Next: read the ring's write index on both sides after the send
(or drive begin/commit explicitly), and if the queue is dead after setup,
treat the two fds as the raw FMQ (128-byte slots, 12 KiB command queue) and
signal its eventfd.

The delegate as uid 10000 still does not take the Tachyon path: that run
logs no `TachyonCore_CreateClientSession` at all, only the VII group ioctl
and `create device status: 13`. Its app service is reachable
(`Found com.google.edgetpu.IEdgeTpuAppService/default in device VINTF
manifest`), but the binder warning `Thread Pool max thread count is 0`
appears for it.

The kernel the phone runs still shows the `samsung-iommu.c:726 unmap_slpt`
warning in the delegate's teardown; the source fix is committed
(`594acaf97`) but this boot predates it.

## U94: the client must ring the command eventfd itself (2026-11-08)

The Ping dispatches. With a session AUTHORIZED and the queue fds from
`setupCommandQueue`, the client writes its message and then writes 8 bytes
to the queue's eventfds; the actor logs

    [Main TPU Actor] received epoll event: 1 on fd 11
    [Client Session ...] received command seq no: 1 of type : Ping

and `receiveResponse` returns OK. Nothing else changed: the same lib, the
same session, the same 64-byte message.

The four fds `setupCommandQueue`/`setupResponseQueue` return are all
`anon_inode:[eventfd]`; the ring itself is another fd per queue. The lib's
`sendCommand` writes the message and publishes the ring's write index but
never signals the eventfd, so the actor's epoll never wakes and the command
sits in the queue until the client dies. That is the "received command"
gate U90-U93 were chasing.

`beginCommandQueueWrite` returns 0 (not an AStatus) and fills one 128-byte
slot; `commitCommandQueueWrite` returns 0 as well. Ringing the command
eventfd after either path is what matters.

Next: read the Ping's 88-byte response from the response queue, then find
the command that runs a model. The firmware's one-time setup is sent by the
core, not by this client.

## U95: the delegate's platform value is not the Tachyon switch (2026-11-08)

Rebuilding `libpropsshim.so` with `PLATFORM_VALUE="gs201"` (so the delegate
and the HAL see the Pixel 7 platform instead of `mmio`) changes nothing:
with `RUN_UID=10000` the delegate still logs three `Sync VII command failed:
error_code=9`, `create device status: 13` and `delegate rc: 1`, and the
Tachyon service logs no `CreateClientSession`. The util library's choice
between the direct VII path and the app-service/Tachyon path is therefore
not made from `ro.board.platform`.

The Ping path end to end (U94): `sendCommand` OK, ring fd 11,
`received command seq no: 1 of type : Ping`, `receiveResponse` OK,
`response size=88`.

## U96: the command union is mapped and the actor answers each type (2026-11-08)

The core's enum-name table at `.data.rel.ro` 0x16c2f8 is the command union,
in order: NONE, Ping, AllocateTpu, AllocateDspTpu, AllocateDsp,
ImportMemoryFromFd, ReleaseMemory, RegisterGraph, UnregisterGraph,
CreateExecution, DeleteExecution, Invoke, BindInputBuffersToTensors,
BindOutputBuffersToTensors, BindInputSyncFencesToExecution,
BindOutputFenceToExecution, ReleaseClientAssignedFd, AcquireTpuWakelock,
ReleaseTpuWakelock. Ping is 1, matching the actor's log.

Each command must be sent once per session: `sendCommand` plus a
`begin/commit` write of the same message makes the actor log it twice and
kill the session ("command sequence number ... must be larger"). With one
send and the eventfd ring, the actor answers every type:

- Ping: 88-byte response, OK (U94); the response ends with an 8-byte value
  (`b0 1f 30 15 de 3a e6 18`).
- AllocateTpu, empty table: 72 bytes, "Virtual device failure".
- AllocateDsp, empty table: 104 bytes, "Unimplemented...".
- RegisterGraph, empty table: 96 bytes, "Virtual device...".
- ImportMemoryFromFd, empty table: 184 bytes, "INVALID_ARGUMENT: Invalid
  client assigned fd handle: 0. Mus..." (truncated at the client's 160-byte
  dump).

The response flatbuffer carries a status text; the client prints it as
ASCII. What is left is each request's table layout, not the transport.

The vendor model `/vendor/etc/model.tflite` (4,653,936 bytes, md5
`f524e0f41d4c13a9c12a62b82af78496`) is Edge TPU-compiled
(`edgetpu-custom-op`, `TFLite_Detection_PostProcess`): a usable SSD
detector once a graph can be registered and invoked.

## U97: the virtual device initializes once /dev/edgetpu-soc exists (2026-11-08)

The core's virtual device failed with `ioctl_kernel_if.cc:123 INTERNAL:
device_fd >= 0 (-1 vs. 0) Failed to open device fd: /dev/edgetpu-soc` and
went `INITIALIZING -> IN_ERROR`, which surfaced as "Virtual device failure"
to the client. The chroot had `/dev/edgetpu` but not `/dev/edgetpu-soc`.
With `ln -sfn janeiro /dev/edgetpu-soc` (now in `tools/tpu-tachyon-run`),
AllocateTpu goes `VD 1: UNINITIALIZED -> INITIALIZING -> INITIALIZED` and
returns a 96-byte success response; dmesg shows janeiro's ioctls and
`finalize: detachable 1`.

`/dev/edgetpu-limited` is the next missing node, but only a warning (the
core continues without the limited device).

So the virtual device now exists; the remaining work is the graph and
execution commands (RegisterGraph, ImportMemoryFromFd, CreateExecution,
Invoke), each of which needs its request table.

## U98: AllocateTpu retires and the virtual device lives for the session (2026-11-08)

With `/dev/edgetpu-soc` present, a two-command session (AllocateTpu then
RegisterGraph, each with its own sequence number) allocates the device:
`Cmd 1 AllocateTpu` goes CREATED -> PENDING_EXECUTION -> RETIRED,
`[VD 1]` reaches INITIALIZED, and the client gets a 96-byte success
response. RegisterGraph is then written and its eventfds rung, but the
client's six-second poll window returns service-specific 8 (no response
yet), so whether the actor ran it needs the log lines after the AllocateTpu
retirement.

The client now takes `TYPES=2,7,...` to send a sequence of union members in
one session, using the round number as the sequence number, and no longer
breaks the loop after the first success.

## U99: RegisterGraph arrives but never completes with an empty table (2026-11-08)

A two-command session now reaches RegisterGraph: the actor logs
`received epoll event: 1 on fd 11`, `received command seq no: 2 of type :
RegisterGraph` and `[Cmd 2][RegisterGraph Handle 0] Command created`. No
response arrives within 30 s (300 polls), so the empty table leaves the
command pending; AllocateTpu's response came back in 0.1 s.

Transport, session and sequencing are all working. What remains is the
request payload: RegisterGraph needs the compiled graph from the model's
Edge TPU metadata, and then CreateExecution and Invoke.

## U100: the compiled graph is a DWN1 container, not a flatbuffer (2026-11-08)

The model is a single `edgetpu-custom-op` whose `custom_options` is
4,726,868 bytes: the compiled graph. It is not a bare flatbuffer. Its head
is `31 00 34 00 00 20 48 00 c8 0f 00 00 44 57 4e 31` — a "14" version
pair, `0x482000` (4,726,784, the file length less 84), `0xfc8`, then the
magic `DWN1`, and the payload carries the string `beagle`.

So RegisterGraph's graph field has to carry this DWN1 blob (or the core's
own parser of it), not a table built from the tflite ops. Extracted to
`out/edgetpu-runtime/graph.bin`.

The vendor delegate was re-tested after U98 with a working virtual device:
still `create device status: 13`, `delegate rc: 1`, and no
`TachyonCore_CreateClientSession` in the log, so the vendor util path stays
closed and the Tachyon client stays the route.

## U101: the DIVE image is a DWN1 container, but not the master schema (2026-11-08)

libedgetpu publishes `executable/executable.fbs` with `file_identifier
"DWN1"`, which identifies the blob: the 4,726,868-byte custom_options is an
8-byte header followed by a flatbuffer (root offset 0xfc8, so the root
table sits at 4048, and "DWN1" at +4 of the base at 8).

Its field order is older than the published master schema, though. The
root's vtable is 20 bytes (8 slots) and the executable version reads 12;
slot 1 carries a uoffset to a ~4.72 MB vector (4722688 bytes, the
`serialized_model`), not the `name` string the master schema puts there.
So the public file only confirms the container; the field mapping belongs to
the core's own copy of the schema.

That is enough: the core parses the DIVE image itself, so RegisterGraph only
has to hand it the bytes. The remaining unknown is the Tachyon request
schema, which is private. The next round captures one from the HAL:
LD_PRELOAD a hook over `TachyonComputeSession_sendCommand` and
`sendFileDescriptors`, drive the HAL's NNAPI device with a tiny client, and
hexdump the RegisterGraph it builds. If the HAL sends nothing, the core's
own log line "Register graph Litebuf command buffer info: vii_cmd size=%d,
dive_cmd size=%d, total=%d" is the oracle for a field-layout sweep.

## U102: the chroot had no device node, and the HAL segfaults once it does (2026-11-08)

The runner's `mount --rbind /dev "$R/dev"` was failing with `move_mount()...
No space left on device`, so the chroot had no `/dev/edgetpu` at all. The app
service therefore never opened the device it is supposed to own, and the
delegate's `create device status: 13` (EACCES) came from calling a service
that had no device to hand out, not from a driver or binder problem.

Two runner fixes: it now mounts the one node the chain needs
(`/dev/janeiro`) and the binder and dma_heap nodes explicitly, recreates
`/dev/edgetpu` and `/dev/edgetpu-soc`, and logs what the chroot sees; and it
splits `DELEGATE_UID` (default 10000) from `RUN_UID`. `RUN_UID=10000` used to
push the services to an app uid too, so the device owner could not open
`root:1000` mode-660 `/dev/janeiro` and nothing could ever serve a device.

With the nodes in place the vendor HAL (as root) opens `janeiro` and dies
with `Fatal signal 11 (SIGSEGV), SEGV_MAPERR, fault addr 0x72656b6e694c00`,
and the app service still does not open the device; the delegate still
reports status 13 and no Tachyon session is created. The chroot's
`/dev/janeiro` shows as `root:robertzas` (gid 1000), so the mode is right for
the system-uid services; the problem is now their own startup, not the node.

## U103: the delegate reaches VII, but its command payload has no mapping (2026-11-08)

The dmesg from the delegate run (uid 10000, `edgetpu-run` pid 59458) settles
what the userspace chain was doing:

```
vii-elem: ... 000b0000 ... (payload iova 0xffefe000, size 128)
vii-payload iova 0xffefe000 size 128: no mapping
ERR vii_handler_layer.cc:247 - Setup is not done yet received a command of type 0.
```

So the app service does hand the delegate a device, the delegate does reach
VII, and "Setup is not done yet" is not a missing service at all: the driver
cannot copy the 128-byte command payload, the VII element goes out without
it, and the firmware sees command type 0 and refuses it. The setup command
never arrives intact.

`drivers/edgetpu/edgetpu-mailbox.c` looks the client iova up in
`group->host_mappings` (ALL_DIES, then 0) and then in
`group->dmabuf_mappings`; neither tree contains 0xffefe000. The running
module was built from `~/omamobile-kernel/wt-tpu/drivers/edgetpu` (head
594acaf97, "iommu: let a driver replace its domain's fault handler"); the
`edgetpu-janeiro` clone is an older snapshot without this code.

Next is to read where a dma-buf map is inserted (`edgetpu-dmabuf.c` and the
MAP_BUFFER ioctl) and compare the key it stores with the iova the delegate
puts in the VII command. Either the map is keyed by the dma-buf's own
device address instead of the client iova, or that ioctl path never inserts
into `dmabuf_mappings` on this kernel.

## U104: the mapped dma-buf and the VII payload address do not coincide (2026-11-08)

`/sys/kernel/debug/edgetpu/janeiro/mappings` after a delegate run shows one
dma-buf mapping for the group:

```
group 39 ...: dma-buf buffer mappings (1):
  <system> die 0: iova=0x00000000fff00000 pages=256 rw
```

The payload the VII layer failed on was `0xffefe000`, exactly 8 KiB below
that map's base, and `edgetpu_mapping_find_locked()` only matches a map whose
`device_address` equals the iova (`compare()` returns non-zero otherwise).
So a payload address that is an offset into a large mapping can never be
found; the earlier "no mapping" is consistent with that.

In a later run the payload copy did succeed (`vii-payload 64: 00080000 ...`,
offsets up to 112) and dmesg still holds six "Setup is not done yet" lines,
and the delegate still ends with `create device status: 13`, `device: 0x0`,
`delegate rc: 1`. So both statements can be true: some payloads are copied,
the setup command's payload is not, and the device is never created.

Next: correlate the two numbers in one run (the driver already logs both the
map and the payload iova), decide whether the delegate's setup buffer is the
map base or an offset into it, and make the lookup find the containing
mapping rather than an exact address.

## U105: KCI 6 is answered 3, and the delegate's first VII is a Sync that fails (2026-11-08)

`echo 6 > /sys/kernel/debug/edgetpu/janeiro/kci_send` returns 0 and the driver
sends it, logging the firmware's answer:

```
KCI tx code 6 seq 283 ...
kci_send code 6 tpu_addr 0xffefd000 -> 3
...
kci_send code 6 tpu_addr 0xffeff000 -> 3
```

So code 6 is accepted by the driver and answered with 3, twice. After the
second send the firmware still logged `Setup is not done yet received a
command of type 0.` (10761.556335), so KCI 6 does not complete the setup.

The delegate's own log names its first failure: `INTERNAL: Sync VII command
failed: error_code=9`, then `create device status: 13`, `device: 0x0`. The
first VII command is a Sync (element type 0), which is exactly what the
firmware refuses until setup is done.

The driver does have a setup hook: `mobile-firmware.c` implements
`mobile_firmware_setup_buffer()` (line 349) and registers it as
`.setup_buffer` (line 520); `edgetpu-firmware.c:104` calls it while loading
the firmware. So the firmware-load path has a setup-buffer step, and the
question is whether the VII setup command carries that buffer's address and
who is supposed to send it (the core's `PushFirmwareSetupCmdToVII`).

Counts of "Setup is not done" in dmesg are not usable as before/after
evidence: the ring buffer drops lines (8 before one run, 6 after the next).

## U106: KCI 6 and 9 both answer INVALID_ARGUMENT, and KCI open is not the missing step (2026-11-08)

`edgetpu-kci.h:146` gives the response codes: `KCI_ERROR_INVALID_ARGUMENT = 3`.
The debugfs hook sends a zeroed 16-byte buffer as the command's DMA descriptor,
so both tests were malformed payloads, not unknown commands:

```
kci_send code 6 tpu_addr 0xffeff000 -> 3
kci_send code 9 tpu_addr 0xffd7e000 -> 3
```

The driver's real open path is present: `edgetpu-mailbox.c:1375` calls
`edgetpu_kci_open_device()` with an `edgetpu_kci_open_device_detail`
(`edgetpu-kci.c:1045`), and `KCI_CODE_OPEN_DEVICE = 9` is in the enum. So the
driver does open the device properly.

After both sends the firmware still logged `Setup is not done yet received a
command of type 0.` on the delegate's first VII (element type 0 = Sync), and
the delegate still reports `Sync VII command failed: error_code=9` then
`create device status: 13`, `device: 0x0`.

So the VII "setup" is neither KCI 6 with an empty payload nor KCI open: it is
a distinct VII step, the one the core names `PushFirmwareSetupCmdToVII`. The
next step is to recover that command's element type and payload from the
vendor core (`libdarwinn_hal.so`) or to get the core/app-service path to send
it for the client's device.

## U107: the delegate runs an unpatched HAL; U56's setup-skip patch was never re-applied (2026-11-08)

U56 measured that `SetupFirmware` in `libdarwinn_hal.so` can be neutralized
with one instruction: `tbz` at `0x14d9a5c` (`36000088`) replaced by `nop`
(`d503201f`). With it, the A14 HAL's `CreateDevice` created group and context
1073741824 and returned OK, with no `Setup is not done yet`, no `Firmware
setup failed` and no `Sync VII command failed` from the HAL.

The delegate's current log shows exactly those failures
(`Sync VII command failed: error_code=9` three times, then `create device
status: 13`), because the chroot's library was restored after the tegu
experiments (U66: "Cheetah's HAL and library are restored"). So the delegate
has been running the stock, unpatched `libdarwinn_hal.so` since.

Next: re-apply the two dev-only patches to the chroot copy (provider gate at
`0x1569ae0` -> `mov w0, #1; ret`; setup skip at `0x14d9a5c` -> `nop`), run the
delegate as the boot's first TPU user, and see whether device creation now
returns 0 and whether RegisterGraph/Invoke get past the firmware gate.

## U108: the setup-skip patch was already applied, and the delegate still fails (2026-11-08)

Before touching anything, the chroot's `libdarwinn_hal.so` sha256 was
`c04ad3249d3c389da58b6d1a7f680692036be10d244c17092a29da88f2430e5b` — the
exact "phone copy" sha U56 recorded for its patched library. Its bytes at
`0x14d9a5c` were already `1f2003d5` (the setup-skip `nop`) and at `0x1569ae0`
already `mov w0, #1; ret`. So both dev patches were still in place.

With them, the delegate run still ends the same way:

```
INTERNAL: Sync VII command failed: error_code=9   (three attempts)
create device status: 13
device: 0x0
delegate rc: 1
```

So U56's result ("CreateDevice returns OK") belongs to the A14 HAL's own
service path, not to the delegate: the delegate sends a Sync VII command
first, and the firmware refuses it with the setup error no matter what
`SetupFirmware` does. The setup has to be sent for real, as a type-1 element
carrying global scratches (U66), before any delegate command will be accepted.

The library was restored to U56's exact bytes (`c04ad3249d3c…`) so the known
state is intact; `.orig` holds the stock file (`f3064911cc7c…`).

## U109: the live lead is the gxp stub's 24-byte info ioctl (2026-11-08)

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, phone up 14808 s,
TPU held by `tpu-hold` (3905).

**The firmware code is not statically addressable.** `edgetpu-janeiro.fw`
(1,038,272 B) is 7.0-7.2 bits/byte entropy through `0xe0000` (the `0xe0000`
block alone is 5.12 with 25 % NUL: the plaintext string table). No 4-byte word
in the whole image equals `0x93efbdc`, `0x0efbdc`, `0x8fefbdc` or `0x90efbdc`,
and no word has `0xefbdc` in its low 20 bits, so the gate's log site is not
reached by a literal and the format is id-addressed. The gate therefore cannot
be read out of the image cheaply; the string table is the only plaintext part.

**`libgxp.so`'s ioctls, decoded.** `GxpCapi_CreateDevice` (0xc4800),
`GxpCapi_ReleaseDevice` (0xc48a4) and the request path call:

    create   0x40086200   (arg: 8 bytes, value 7)
    release  0x40086201   (arg: handle)
    info     0xc0184800   (_IOWR, size 0x18 = 24, type 0x48, nr 0)

The info call sites in `.text` are `0x12e288`, `0x14c0ec`/`0x14c114`,
`0x14c3f8`/`0x14c420` and `0x14d01c`/`0x14d044`; the create site is `0x12c1e8`
(`mov w1,#0x6200; movk w1,#0x4008`), the release site `0x12e3c0`. The skeleton
`drivers/gxp/gxp.c` (178 lines, commit `1d8f22a9e`) answers create/release and
returns `-EOPNOTSUPP` for info, which is exactly the call U89 left open.

**Next:** disassemble around `0x14c0a0`-`0x14c160` (and `0x12e240`-`0x12e2c0`)
to read the fields the caller consumes after the info ioctl, then fill the
24-byte struct in `gxp.c`. The phone keeps the boot it has; the next gxp.ko
needs `bin/omamobile push` and a cold boot, and the TPU is already spent for
this one.

Phone state: up, TPU held (3905), `/dev/janeiro` present, chroot HAL at its
known sha `c04ad3249d3c…` (U108).

## U110: the info struct decoded; CONFIG_GXP was never enabled (2026-11-08)

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`.

**The 24-byte info call.** `libgxp.so` builds the struct at `0x12e26c`:
`+0` a device object pointer, `+8` a u32 0, `+12` the u32 `0x00080002` (the
rodata constant at file offset `0x36978`, in the first LOAD segment where
vaddr == offset), and `+16` a u64 0; it calls `0xc0184800` (`_IOWR('H', 0,
24)`) and checks only the return value. A second 24-byte query uses
`0xc018ee04` (`0x14c0ec`). The stub answered `-EOPNOTSUPP`; `gxp.c` now logs
the six words and echoes them back, so the service's next behaviour names the
reply layout.

**Why the module never rebuilt.** `drivers/gxp/Makefile` is
`obj-$(CONFIG_GXP) += gxp.o`, and `out-tpu/.config` holds
`# CONFIG_GXP is not set`. Every `M=drivers/gxp` build therefore found nothing
to compile and exited 0 with only a MODPOST line; the 264,880-byte
`out-tpu/out-modules/gxp.ko` dated 16:26 (vermagic
`...-g052da70970d6-dirty`, correct) is a hand-made artifact from the earlier
session, not a kbuild product. `drivers/Kconfig` already sources `drivers/gxp/Kconfig` (line 2), so
`scripts/config --module GXP` plus `olddefconfig` enables it; the symbol was
simply never set in `out-tpu`.

The full `make modules` path is also unusable on the host as-is:
`/bin/sh: bc: command not found` stops `include/generated/timeconst.h`
(`prepare0`), so the module has to be built in the project container, or `bc`
installed.

**Next:** set `CONFIG_GXP=m`, build `gxp.ko` with the release file pinned to the running
kernel's string (the working recipe: write
`out-tpu/include/config/kernel.release`, `make M=$PWD/drivers/gxp`, then
restore it), `bin/omamobile push`, cold boot, and read the service's answer to
the echo.

## U111: gxp.ko builds with the info echo (2026-11-08)

`CONFIG_GXP=m` in `out-tpu/.config` plus `syncconfig` is the whole fix; the
`M=` build then compiles and links in the project image with the host toolchain
mounted:

```sh
docker run --rm -v $S:/src -v $O:/out -v ~/.cache/omamobile/toolchain:/tc:ro \
  -w /src omamobile-build:24.04 bash -c \
  'export PATH=/tc/clang-r596125/bin:$PATH
   make O=/out ARCH=arm64 LLVM=1 syncconfig
   make -j$N O=/out ARCH=arm64 LLVM=1 M=/src/drivers/gxp modules'
```

with `out-tpu/include/config/kernel.release` written to the running kernel's
string (`7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`) for the build and put
back afterwards. Log: `CC [M] gxp.o`, `LD [M] gxp.ko`; the earlier silent
no-ops were `auto.conf` still holding `# CONFIG_GXP is not set`.

## U112: the matching vermagic needs the stale release files deleted (2026-11-08)

Pinning  with
 off is not enough on its own:  and  are only regenerated when
they are missing, so the tree kept producing  while
the phone runs . Delete both, run  and the
 build, and the module reports



 and  now stay pinned in
, so later module builds match the running kernel without the
release-file swap. The built module carries the answered info ioctl
().

## U113: the gxp info echo works, the service never asks, and the core's setup sender is located (2026-11-08)

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, phone up 15 490 s,
TPU held by `tpu-hold` (3905).

**The vermagic recipe.** The pinned `CONFIG_LOCALVERSION` was already right,
but `make kernelrelease` alone leaves `include/generated/utsrelease.h` stale,
so `gxp.mod.c` kept the old `g594acaf97960` string and `insmod` refused the
module. What works, in the project container:

```sh
rm -f /out/include/config/kernel.release /out/include/generated/utsrelease.h
make O=/out ARCH=arm64 LLVM=1 modules_prepare
rm -f /src/drivers/gxp/gxp.ko /src/drivers/gxp/gxp.mod.o /src/drivers/gxp/gxp.mod.c
make -j$(nproc) O=/out ARCH=arm64 LLVM=1 M=/src/drivers/gxp modules
```

With `utsrelease.h` regenerated the module reports
`7.3.0-rc6-omamobile-push1-g052da70970d6-dirty` and installs (sha
`6eeb3b4f13b2`).

**The info echo is live.** gxp is a software-only skeleton (it maps the AUR
window and touches no register), so it was swapped on the running boot:
`rmmod gxp; insmod /root/gxp-info.ko` logged `AUR at [mem
0x25c00000-0x26ffffff]`. A Python client (`fcntl.ioctl`) sent `0xc0184800`
with `{0, 0, 0x00080002, 0}` and got the same six words back (`info rc=0`),
while `0x40086200`/`0x40086201` still round-trip (handle 1). The 24-byte
command is therefore an in/out echo, as U110 intended.

**The vendor service chain does not query it.** `NO_DELEGATE=1
/root/tpu-tachyon-run` restarted servicemanager (89888), the power HAL
(89911), the vendor service (89932), the Tachyon service (89962) and the app
service (89988). The 16 481-line log has no gxp line, and dmesg holds only
the Python test's `device info: in ...`. The only libgxp consumer in the
chroot is `libedgetpu_util.so` (`grep -rl libgxp.so` over the vendor trees),
i.e. the util/delegate path. So a Tachyon-service restart cannot reach the
info command; it needs a client that loads `libedgetpu_util.so`.

**The core's setup sender.** Pulled the real core to
`out/edgetpu-runtime/libtachyon_core.so` (1 538 440 B, sha
`d1602625abb0…`) and disassembled it. The `Sending firmware-setup VII
command. type: ` log site is `0x7fc20`; the type it prints is
`[x19+0x1c1]`, set just above (`cmp w0, #3` / `#6` + `csel`) to **11
(0xb)** or **15 (0xf)**, and `[x19+0x1c0]` gets the same value. The
`PushFirmwareSetupCmdToVII failed` string is at `0x7531c`. The log is behind
a global verbosity byte (`[*(0x172ed0)] & 1`), so its absence does not by
itself prove the send never happened; but the firmware still logs `Setup is
not done yet` and the service log names no setup at all, so the trigger is
not reached.

**Next:** find the function containing `0x7fb5c` and its `bl` callers to
identify the state that gates the call (`PENDING_FIRMWARE_SETUP`,
`Unexpected firmware setup status: `), then test the hypothesis that the
core skips setup because `tpu-hold` already woke the firmware: one cold boot
with `HOLD=0` and the delegate as the first and only TPU user, watching
`vii-payload` in dmesg for the setup element. The driver's own payload
hexdump is the capture oracle.

## U114: the setup builder and its one caller (2026-11-08)

**U113's boundary was wrong.** `0x7f7cc` is not the constructor: it is a
callback the session factory stores at `[obj+0x258]` (`0x739dc: adr x8,
0x7f7cc; str x8, [x19, #0x258]`), beside `0x7f904` at `+0x250` and `0x7f760`
at `+0x230`. The setup builder is **`0x7f9c4`**, and it has exactly one
caller: `0x73abc`, inside the factory at `0x73a48` (which allocates a
`0x3e0`-byte session object and returns it through the sret register x8).

At `0x7fbbc`-`0x7fbd8` the builder calls the helper `0xd5630` twice, compares
its result with 6 and 4, and writes two booleans: `[x19+0x1c0]` and
`[x19+0x1c1]`, the second set to **11 (0xb)** or **15 (0xf)**. The log at
`0x7fc20` prints that byte. The object fields `+0x1c0..+0x3a0` are the
session's setup-command state, so the "Sending firmware-setup VII command"
line is emitted while the session object is built, not at the later VII
submit (`PushFirmwareSetupCmdToVII failed`, `0x7531c`).

**Next:** disassemble the function containing `0x7531c` and its callers to
find the submit condition, and find what reads `[obj+0x1c0]` between the
build and the submit. The type value 15 is the one the virtual-device mode
selects; whether our session's mode picks 11 (direct) or 15 is the first
thing to read from the builder's two `0xd5630` results.

## U115: the failure log is a result handler, not the submit (2026-11-08)

`[obj+0x1c0]` and `[obj+0x1c1]` have exactly two stores in the whole core,
both in the builder (`0x7fbb8`, `0x7fbdc`); no instruction loads them by
immediate offset. The log at `0x7fc20` passes `&obj[0x1c1]` to the logger,
and the flatbuffer builder reads the type through that pointer.

The `PushFirmwareSetupCmdToVII failed` string at `0x7531c` is **not** the
submit: the block at `0x752ec`-`0x75344` formats a status into the log and
then branches on the handler's own result (`cbnz x0, 0x750a0` after
`ldp x8, x0, [x22, #0xe0]`). So the next target is that handler
(`0x750a0`) and the `bl` that produces the status it logs, not the string
site.

**Next:** read `0x750a0` and the call that returns the status; name the
condition that reaches the handler (the setup send's return path). Then one
cold boot with `HOLD=0`, delegate first, and capture `vii-payload` as before.


## U116: the failure handler's two callees (2026-11-08)

`0x750a0` is `bl 0x144084`; its result is stored at `[sp+0x40]` and a null
result jumps to the stack-check path (`0x75354`). The non-null path builds a
four-argument call at `0x750c8`-`0x750dc` (`bl 0x5a460`) using the object at
`[x21+0xc0..0xc8]`, then reaches the `PushFirmwareSetupCmdToVII failed`
formatting block at `0x7531c`. So the next two functions to read are
`0x144084` (the value tested) and `0x5a460` (what consumes it); neither is
the setup submit itself.

**Next:** read those two, then the cold boot with `HOLD=0` to capture
`vii-payload`. The type bytes remain builder-only (`0x7fbb8`/`0x7fbdc`).


## U117 (2026-11-08): the direct path works; the setup is not the element code or a scalar field

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, TPU held by
`tpu-hold` from the boot (uptime ~17500 s), so no power cycle was needed.

**`SetupCommandFmq` is not the firmware setup.** In
`libedgetpu_tachyon.google.so` at `0xb850` it allocates `0x80` bytes, writes
three 24-byte grantor descriptors and a `native_handle` of fds, stores the
result at `[session+0x18]`, and returns two ints. That is the command FMQ's
descriptor, not a VII payload; the 128-byte `CommandMessage` that pointed the
previous session at it is the same size by accident.

**The direct path is end to end.** `edgetpu-run mapped CODE 0 FILE`, run in
the vendor chroot with `LD_LIBRARY_PATH`, creates a group, maps a page, copies
the file, submits one element, and reads the response. The driver dumps the
exact bytes (`vii-payload ... copied 128`) and the firmware answers
`0xf000009` (KCI status 9, FAILED_PRECONDITION). This is the oracle the next
attempts need; no cold boot is required while `tpu-hold` lives.

**The element code is not the type.** With the 128-byte legacy payload,
element codes 1, 11, 15, 16, 18 and 21 each produced a fresh
`Setup is not done yet received a command of type 0.` line. The core's
`+0x1c0/+0x1c1` values (11/15) are not this code.

**A scalar in slots 3..31 is not the type either.** 93 payloads extended the
legacy 3-field table (`f0=0x30`, `f1=5`, `f2` to the same tail) with slots
3..31, one at a time as u32 1, 11 and 15, plus all-slots variants. Every
submission that produced a verdict answered `type 0`; no
`Could not parse Command flatbuffer` and no `No global scratches` appeared.

**Next: make the core's session constructor run.**
`TachyonCore_CreateClientSession` creates the NPU manager itself (`0x4fbbc`
allocates the object when `0x17a000+0xec8` is null), so the missing-manager
reading was wrong. The failure is after that, in the kernel-interface/session
construction (`0x4d5e4` -> `0x511ec`), which is also where the core logs
`Sending firmware-setup VII command`. Call it with the exact `0xb8`-byte
config and capture the core's stderr and the payload dump; only if that is
impossible is a gxp driver the next cost.


## U118 (2026-11-08): the 720p comparison, measured

`out/bench/mosaic12.mp4` is 1280x720, 60 frames, 12 person tiles; the SSD
MobileNet 300x300 int8 model (`detect.tflite`, threshold 0.5) finds 10.0 per
frame (max 10), so the 10+ target is met at exactly 10. Every leg decoded the
same clip and ran 60 frames. CPU is XNNPACK; GPU is LiteRT `CompiledModel`
WebGPU on the laptop's RTX 3070, not the phone's Mali.

| backend | mean ms | p50 | p95 | fps | detections |
| --- | --- | --- | --- | --- | --- |
| CPU, 1 thread | 13.33 | - | - | 75.0 | 10.0 |
| CPU, 2 threads | 7.48 | - | - | 133.7 | 10.0 |
| CPU, 4 threads | 4.28 | 4.18 | 5.04 | 233.9 | 10.0 |
| CPU, 8 threads | 3.28 | - | - | 304.9 | 10.0 |
| GPU, WebGPU (RTX 3070) | 3.00 | 2.55 | 3.34 | 333.3 | 10.0 |
| Edge TPU | blocked (U117) | - | - | - | - |

The 4-thread CPU number moved from 3.97 ms in U83 to 4.28 ms here (same
laptop, same clip), a run-to-run spread of about 8 %; report both or a range,
not a single number to 0.01 ms. The phone itself has no leg: its Python is
3.14 and no aarch64 `ai-edge-litert` wheel exists for that ABI, so there is no
TFLite runtime on the image. The comparison is therefore laptop CPU/GPU only;
the TPU row has no number and none is claimed.


## U119 (2026-11-08): the core gets past its platform check, then the zeroed session config crashes it

The core aborts at load with `Unknown platform ID on Android: 6` because the
property shim returns `mmio` to every process except the Tachyon service. A
shim built with `-DPLATFORM_VALUE='"gs201"'` (a copy under
`out/tpu-client/libpropsshim-gs201.so`, preloaded for this client only) gets
past that check, and `TachyonCore_CreateClientSession` is reached.

A direct call with a zeroed `0xb8`-byte config aborts with
`stack corruption detected (-fstack-protector)` before it returns, with or
without a preceding `TachyonCore_SetNpuManagerStatus(1)`; the
`SetNpuManagerStatus` call alone also corrupts the stack. A zeroed config is
therefore not a valid input, and the status flag is not safely settable out of
order. The next input must be a **real** session config captured from the
delegate or the Tachyon service (the AIDL `ClientSessionConfig` /
`TachyonCore_CreateClientSession` call), not a synthetic one. The client is
`tools/tpu-core-session.c`; its only useful result so far is the platform-check
fix.

## U120 (2026-11-08): the session type map, the ring baseline, and the import handle

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, phone up 5:37, TPU
held once by `tpu-hold` (3905); no cold boot. The chain is left down.

**The ring client is the baseline.** `/root/tpu-tachyon-client` (13,872 B) and
`/vendor/bin/tpu-tachyon-client.new` (15,208 B) both write the command but
never signal the queue eventfds, so the actor logs no `received command` and
`receiveResponse` is the empty-FMQ status `exception -8 service 8`. Rebuilt
from `tools/tpu-tachyon-client.c` (the source has the ring) and run as uid
1000:

```
ring fd 11 rc 8 ... ring fd 15 rc 8
receiveResponse: OK ... response size=88
[Main TPU Actor] received epoll event: 1 on fd 11
[Client Session ...] received command seq no: 1 of type : Ping
```

**The session type selects the backend.** The client's `STYPE`:

| STYPE | what happens |
| --- | --- |
| 0 | the real core: `ClientSession` UNINITIALIZED -> CREATED -> STARTED -> AUTHORIZED, and the Ping above round-trips |
| 1 | the GXP path: `Loaded GXP Tachyon Server library ... zpr_dsp_20260302`, `Could not setup the main actor`, `scoped_eventfd ... !fd.IsEmpty()`, service dies; `createSession` exception -129 DEAD_OBJECT |
| 2 | the StarShip path through `fake_libtachyon_core.so`: `Unable to find original definitions of StarShip core. Using Fake definition to create session config with privilege: 1, size:184`, then `Unable to start core for handle ...`; session created, no core |
| 3 | `createSession` exception -8 service 13 `Invalid Tachyon core` |

`fake_libtachyon_core.so` (35,824 B) is a test double from
`vendor/google_devices/zumapro/proprietary/gchips/tpu/tachyon/service/
fake_libtachyon_core.cpp`; its `TachyonStarShipCore_*` and
`TachyonDspCore_*` symbols are WEAK, and each looks up an "original
definition" through `dlsym` and logs when it is absent. The cheetah core stub
(sha `47fb5f74...`, 1,015,720 B) has only four exports and no StarShip
symbols. So neither image here ships a real `TachyonStarShipCore_*`; STYPE 0
is the real path.

**The command union numbering**: 0 NONE, 1 Ping, 2 AllocateTpu, 3
AllocateDspTpu, 4 AllocateDsp, **5 ImportMemoryFromFd**, **6 ReleaseMemory**,
7 RegisterGraph, 8 UnregisterGraph, 9 CreateExecution, ... A `TYPES=2,6`
probe therefore sent ReleaseMemory and the core answered `ReleaseMemory 1 ...
Release memory handle not found: 1`; the import is type 5.

**The import handle probe.** With the root table at 36, the union vtable at 56
and the union table at 60, the first u64 at table+8 is the **command handle**:
the core logs `[Cmd 2][ImportMemoryFromFd Handle 1] Command created`. A
second u64 at table+16 does not reach the **client-assigned fd handle**:
`TachyonComputeSession_sendFileDescriptors` returns OK for the memfd with
handle 1 or 2, yet the core still answers `INVALID_ARGUMENT: Invalid client
assigned fd handle: 0. Must be positive.` for `HANDLE=1 FDH=1` and
`HANDLE=1 FDH=2`. The fd handle is a different field, most likely a nested
memory-descriptor table (union field 1 as a uoffset) or a struct, not the
second u64.

**Next: the nested-descriptor sweep.** `tools/tpu-tachyon-client.c` now has
the `HANDLE`/`FDH` probe and the `sendFileDescriptors` call. Make union field
1 a uoffset to a table carrying a u64 at +8/+16/+24, run
`TYPES=2,5 HANDLE=1 FDH=N`, and stop when the error's number is N. Then
import `out/edgetpu-runtime/graph.bin` (4,726,868 B, the model's `DWN1`
custom_options) instead of the 4 KiB page and send RegisterGraph (type 7).

Phone state: up, TPU held by `tpu-hold` (3905), chain down, the ring client at
`$R/vendor/bin/tpu-tachyon-client.ring`; `/tmp/tpu-tachyon.log` is this
round's log and is not committed.

## U121 (2026-11-08): the Tachyon import works; RegisterGraph needs its graph descriptor

The running core in the phone's chroot is the **tegu** build (sha
`d1602625...`, 1,538,440 B, `/vendor/lib64/libtachyon_core.so`), not the
local chroot's 1,015,720-byte cheetah stub. It carries the actor engine
(`tpu_actor_engine.cc`, `tpu_actor_memory_import.cc`) and the import error
strings.

**ImportMemoryFromFd works.** Its request table is
`{handle, device_id, fd_handle, offset, size}`:

- 4 KiB system-heap dma-buf: 64-byte success response, `Memory handle 1`
  created and unmapped on release.
- 4,726,868-byte `graph.bin` (DWN1): read into the dma-buf, `sendFileDescriptors`
  OK, `memory handle: 1 resolved to fd: 20`, import RETIRED.

The dma-heap ABI in this kernel is `{len, fd, fd_flags, heap_flags}` (the
output fd first); the older order returned EINVAL. `/dev/dma_heap/system`
exists in the chroot and `CONFIG_DMABUF_HEAPS_SYSTEM=y`; the client syncs the
cached system heap with `DMA_BUF_IOCTL_SYNC` START|WRITE then END|WRITE.

**RegisterGraph is blocked on the descriptor.**

- 2-field `{handle=2, memory=1}`: `[Cmd 3][RegisterGraph Handle 2] Command
  created`, then the service's `MainTpuActor` gets SIGSEGV (audit `sig=11`),
  no response.
- 3-field `{handle=2, device=1, memory=1}`: the core answers 76 bytes
  `INVALID_ARGUMENT: Invalid command flatbuffer`. A scalar in field 2 is not a
  valid uoffset, so field 2 is a nested table: the graph descriptor.

**Kernel warnings on the register path.** `edgetpu_device_group_alloc` ->
`edgetpu_mmu_alloc_domain` calls `iommu_set_fault_handler`, but the mainline
`samsung_iommu` domain has no `set_fault_handler` op, so
`drivers/iommu/iommu.c:2061` warns. `unmap_slpt` (`samsung-iommu.c:726`) also
warns on release. These are driver gaps, not the immediate blocker.

**Next: build the graph descriptor table at field 2.** Find the stock builder
(the app service or `libedgetpu`'s `RegisterGraph`) or disassemble the tegu
core's `RegisterGraph_Init` (name string at 0xcd54). The descriptor carries
the graph's input/output tensor metadata. Then CreateExecution (9), bind
buffers (12/13) and Invoke (11), and only then the 720p comparison.

Phone: up, TPU held by `tpu-hold` (3905), chain down; `/tmp/tpu-tachyon.log`
has the graph-import/register log.

## U122 (2026-11-08): the RegisterGraph descriptor passes the verifier; the core dies after it sends the VII

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, phone up, TPU held
by `tpu-hold` (3905); no cold boot, chain down.

**The request schema.** `RegisterGraph` is `{command handle, device id,
GraphDescriptor}`. The descriptor's first three fields are
BufferDescriptor tables: the graph container (memory 1, offset 0, size
4,726,868), the firmware scratch (memory 2, offset 0, size 1 MiB), and the
intermediate buffers (one, the same memory). The client sends 236 or 288
bytes; `sendCommand` accepts both, so the 128-byte cap assumed in U121 was
the firmware setup message, not the FMQ's.

**Both pass the verifier, then the core dies.** The actor logs `received
command seq no: 4 of type : RegisterGraph` and `[Cmd 4][RegisterGraph
Handle 2] Command created`; then the service is gone (client
`DEAD_OBJECT`), with no `Check failed` line. The empty intermediate list
was not the cause: one intermediate gives the same crash, and so does a
fourth field (a 16-byte location struct, offset 0, size 4,726,868).

**The executable's header.** Root 4048 (base 8, root offset 0xfc8 at +8,
vtable 4028, 8 slots): version 12; serialized_model 4,722,688 bytes;
model_info empty; scratch_size 0; slot 4 a 3-element vector
(`0x2f6c63`, 0, `0x481000`); slot 7 = 4. The firmware scratch the core
checks is 0, so the 1 MiB scratch is ample.

**The firmware did receive a command.** dmesg shows
`edgetpu janeiro: KCI tx code 21 seq 912` and the mailbox irq around the
register, so the core built and sent the VII before it died; the crash is
after the send.

**Next:** the core's crash. Its fourth field is likely the external
parameter buffer (`external_buffer_descriptor`; the `libedgetpu_util`'s
`RegisterGraphByBufferWithExternalParameter`), and the handler may
dereference a null `graph`/`external_buffer_descriptor`. Capture the
service's stderr tail and a tombstone, disassemble the tegu core around
the `graph_container_descriptor`/`external_buffer_descriptor` strings, and
retry with the external buffer or a separate intermediate memory. Then
CreateExecution (9), bind (12/13), Invoke (11).

Phone: up, TPU held by `tpu-hold` (3905), chain down;
`/tmp/tpu-tachyon.log` is this round's service log.

## U123 (2026-11-09): the crash is the core's VII builder; the graph header parses and its scratch is not the null

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, as in U122. The
phone was rebooted at 00:54 (`reboot-to tpu-vlog`) and is up again with
`tpu-hold` running; slot B only.

**The service needed a cold boot.** After the ~20 register crashes the
chain stopped coming up: the client got `create: NOT-OK`, `BR_DEAD_REPLY`,
`service=0x0` and "Failed to connect to the Tachyon Compute Service", and
no `com.google.edge…` process existed. `/tmp/tpu-v2.log` had only preload
noise, and `tpu-hold` was still alive. A `reboot-to` brought the chain
back, so the TPU, not the harness, was wedged. A core crash that kills the
service now means a reboot before the next attempt.

**The builder's crash, from the disassembly.** `+0x5968c` is
`ldr x8,[x8]`, and `x8` came from `[[payload+0x38]]`. The builder appends
`[[payload+0x10]]` (the graph container location), then `[[payload+0x38]]`,
then walks 24-byte-element vectors at `+0x20`, `+0x40` and `+0x58`, the
last two allowed to be null by the bool at `+0x70`, and allocates 384 B,
so the payload must carry a non-null location pointer at `+0x38`.

**Layouts swept (all crash at `+0x5968c`):** descriptor orders `CILS`,
`CISL`, `CSLI`, `CSXIL`, `CSIXL`, `CIXLS`, `CSI`; the old builder; `RH=1`;
`SAME=1`; both; the stock `/root/model.tflite` DWN1; inline 24-byte
location structs (`ORDER2=csi`, `cs`, `Csi`, `cSi`); command fields 3 and 4
as a table (`HDGX`, `HDGXX`), as u64 (`HDGM`, `HDGK`), as vectors of
handles (`HDGV`, `HDGW`, `HDGVV`) and as a 24-byte inline struct (`HDGS`).
None of them fills `+0x38`.

**The graph header, parsed correctly.** The root table is at file offset
4048, and the uoffset at +8 is absolute, not relative to +8 (the earlier
`8+4048` read garbage). Slots: 0 version 12; 1 serialized_model uoffset
44; 2 36; 3 **0** (scratch size); 4 20; 5 0; 7 4. Patching slot 3 to
1 MiB (`out/edgetpu-runtime/graph-scratch.bin`, pushed as
`/vendor/etc/graph-scratch.bin`) changed nothing, so the null at `+0x38`
is not the firmware-scratch location; the core's
`GetFwScratchBufferSize() >=` check passes with the 1 MiB scratch the
descriptor already carries.

**Responses.** A 64-byte reply carries kind 2 or 3 (success); the 80-byte
reply carries kind 19 and the `Device id must be %d` text, which is how
the command layout was proved: `{handle, device_id, graph_descriptor}`.

**The vlog shim still has not loaded.** `TPU_VLOG=5` produces no
`vlog:set`, and `/tmp/tpu-v4.log` shows `ld.so: object
'/system/lib64/liblogstderr.so' from LD_PRELOAD cannot be preloaded`: the
service is started outside the chroot while the preload list uses
chroot-absolute paths. Preload the shim by the path the service's own
linker sees (`$R/system/lib64/libvlogshim.so`) and confirm `vlog:set`
before trusting any core log line.

**Reference client.** `libedgetpu_util.so` exports
`DarwinnApi2_VirtualDevice_RegisterGraph*` (`…ByBuffer`,
`…WithExternalParameter`, `…WithIntermediateBuffers`, `…WithLargeBuffers`),
and every `ByBuffer` thunk funnels into `0x6f87f4`; disassembling that
function is the shortest way to the field order the vendor client writes.

**Next:** get `vlog:set`, then either the core's own log or `0x6f87f4`
names the `+0x38` field; then CreateExecution (9), bind (12/13), Invoke
(11).

**Addendum (same day).** The vlog shim does load: copied into the chroot
with `TPU_VLOG=5`, the log shows `TachyonCore_SetVlogLevel called with
log_level: 5`, `vlog:set`, and then the service's own call lowering it to
3. (The `ld.so: object … cannot be preloaded` lines are the host `chroot`
process resolving the chroot-absolute path, not the service.) The register
log ends at `[Cmd 4][RegisterGraph Handle 2] Command created`, and the
segv shim then reports **SIGBUS at `libtachyon_core.so+0x59658`**
(`lr +0x87b94`): `ldr x8,[x21,#0x10]; ldr x8,[x8]` with
`[x21+0x10] == 0`. The descriptor object the core parsed starts
`{2, 1, 0, 0, …}`: two counts and then a null first location, which the
builder dereferences without the null check it applies to the two later
locations. So the field still missing is the descriptor's first location,
not the graph's contents or its scratch size. The 512-byte descriptor
builder already encodes the intermediate field as a one-element vector
(`I`), so that encoding is covered too.

Phone: up, `tpu-hold` running, chain down; `/tmp/tpu-w.log` is this
round's log (the scratch-patch run).

## U124 (2026-11-09): the graph descriptor is the command's field 3; only its container parses

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`. Three reboots
(`tpu-u124`, `tpu-u124b`, `tpu-u124c`), slot B only; each register crash
kills the Tachyon service, so each attempt costs one reboot.

**The descriptor is field 3, not field 2.** With `UORDER=HDXGG` (handle,
device id, X table, descriptor, descriptor) the crash moved from
`+0x59658` to `+0x5968c`, and the args object now carries a
`shared_ptr`-like pair at `+0x10`/`+0x18` (pointer plus control block)
instead of null. Every U123 sweep put the descriptor at field 2 and
always crashed at `+0x59658`. So the register args are
`{handle, device_id, <a table>, graph_descriptor, ...}`: field 2 must be a
table, which is why a scalar there failed the verifier in U121.

**The args object.** The crash dump (24 u64 from the variant payload) is
`2 1 <ptr,ctrl> 0 0 …`: handle 2, device id 1, then the container. The VII
builder reads `+0x10` (container), `+0x38` (a second single location),
24-byte-stride vectors at `+0x20`, `+0x40`, `+0x58` and a bool at `+0x70`.
The object is larger than 192 bytes and the fields past `+0x80` are not
initialized by the parse (stack garbage in the `CISSS` run), so only
`+0x10` is really filled.

**The command table, read in full** (name table at `0x172c20` ->
`0x16c2f8`, 32 entries): 0 NONE, 1 Ping, 2 AllocateTpu, 3 AllocateDspTpu,
4 AllocateDsp, 5 ImportMemoryFromFd, 6 ReleaseMemory, 7 RegisterGraph,
8 UnregisterGraph, 9 CreateExecution, 10 DeleteExecution, 11 Invoke,
12 BindInputBuffersToTensors, 13 BindOutputBuffersToTensors,
14 BindInputSyncFencesToExecution, 15 BindOutputFenceToExecution,
16 ReleaseClientAssignedFd, 17 AcquireTpuWakelock, 18 ReleaseTpuWakelock,
19-21 Internal…DelegateCompleted, 22 ImportMemoryFromHostAddr, 23-24
Internal…, 25 InternalDeallocateTpu, 26 Cancel, 27 InternalLogGraphPerf-
SummaryMetrics, 28-30 Internal…, 31 RemapModelMemory. There is no
separate graph-container command: the descriptor carries it.

**No crash-free oracle yet.** `CH`/`SH`/`IH` force an invalid memory
handle into one buffer table; an unknown handle should answer "Memory
handle not found" rather than crash. `CH=0xdeadbeef` changed nothing (same
crash, same `{2,1,0}`), so no buffer table is read on this path yet.

**Descriptor field order.** `CSI` (container, scratch, intermediate vector
of table offsets), `CJS` (container, intermediate vector of inline 24-byte
descriptors, scratch) and `CISSS` (every candidate scratch position) all
leave `+0x20` empty and crash at `+0x38`. Only descriptor field 0 — the
graph container, as a table of `{handle, offset, size}` — parses.

**No vendor caller to capture from.** `0x6f87f4`
(`RegisterGraphByBufferWithIntermediateBuffers`) copies shared_ptr vectors
and builds the litebuf in a callee, never inline. `libedgetpu_tachyon.
google.so` exports only the AIDL transport (`TachyonComputeSession_send-
Command`), and nothing in the image links `libedgetpu_util.so`, so there is
no stock binary to run under a payload-dumping preload.
`tools/android-cmd-dump.c` is that interposer (built, pushed, unused).

**Next:** descriptor field 1 vs 2 as single BufferDescriptor tables, no
vector, and read which offset moves; then the `+0x20` vector as a vector of
table offsets. The builder's `+0x38` read is the only remaining null.

Phone: up, Tachyon service dead after the `CISSS` crash, chain down; a
reboot before the next register.

## U125 (2026-11-09): the descriptor's vectors never parse; stop guessing and read the parse under gdb

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, slot B. Five
register probes (`CSSSS`, `SSISS`, `SSJSS`, `SSIISS`, plus the U124 runs)
and one re-test of the stock delegate.

**The parse stops at the first field it cannot read.** In every run the
faulting object is `{2, 1, <ptr>, <ptr>, 0, 0, ...}`: `+0x10`/`+0x18` fill
with two heap words (a `shared_ptr`-like pair, as U124 saw), and **`+0x20`,
the first vector, is always zero** — so the descriptor never reaches the
single buffer at `+0x38`. That also explains the earlier runs: with
`CISSS`, `CSI` and `CSSSS` the parser stopped before the field that would
have filled `+0x38`.

**No vector we build is accepted.** Descriptor fields 2-4 as single
tables (`CSSSS`, `SSISS`), as a vector of table offsets (`I`), and as a
vector of inline 24-byte structs (`J`) all leave `+0x20` empty. The `J`
encoding was 8-byte misaligned (data at `388`); it is fixed (length at
`388`, data at `392`) and still does not fill the vector, so alignment was
not the only problem.

**`+0x38` is a required single buffer.** The VII builder reads
`(*(desc+0x38))[0]` (the handle), then inserts the vector at `+0x20`
(24-byte elements), then the vectors at `+0x40` and `+0x58`, with a bool
at `+0x70` (`libtachyon_core.so+0x59650`-`0x59718`). Only `+0x38` is
dereferenced without a null check, which is why it is the one that kills
the service.

**The core parses the command fine.** The log reads `received command seq
no: 4 of type : RegisterGraph` and `[Cmd 4][RegisterGraph Handle 2]
Command created`, and then nothing: no flatbuffer or verifier error, no
`Sending firmware-setup`. The failure is in the VII build, after the
request parse.

**The stock delegate is still closed on this kernel.**
`TPU_VLOG=5 /root/tpu-tachyon-run` (delegate path, service alive) logs
`Sync VII command failed: error_code=9`, three `create device status: 13`
and `delegate rc: 1`, the same U103 shape: the payload mapping, not the
userspace. The Tachyon client remains the route.

**Why the sweep ends here.** Three vector encodings and five field shapes
all die at `+0x5968c`, so the remaining unknown is not a field index to
permute: it is the parser's own member layout. The next step reads it
directly instead of inferring it:

1. attach gdb to `com.google.edge` (tachyon-service) and let the client
   reach the fault; gdb stops on the SIGSEGV before the shim's handler;
2. dump `$x21` (the parsed descriptor), `*(void **)$x2` (the command) and
   the caller frame — that names the parse and its field order;
3. at the fault, point `$x8` at the container's own `BufferDescriptor`
   (`*(void **)($x21+0x10)`) and continue: if RegisterGraph completes, the
   `+0x38` buffer is the firmware scratch and only its flatbuffer slot is
   left to find;
4. kill and restart the service instead of rebooting, so one boot carries
   several probes (the firmware never sees an aborted command).

Phone: up, Tachyon service dead after the `SSIISS` register crash, chain
down; a reboot before the next attempt.

## U126 (2026-11-09): gdb reads the parsed command, and a patched `+0x38` gets RegisterGraph through

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, two boots
(`tpu-u126`, `tpu-u126b`), slot B. A gdb attach with
`handle SIGSEGV stop print nopass` catches the fault before the segv shim
and leaves the registers live.

**The parsed command object** (`$x21`, 24 u64): `2 1 <ptr> <ptr> 0 0 ...`.
`+0x10` and `+0x18` are two single `BufferDescriptor *`; the vectors at
`+0x20`, `+0x40`, `+0x58` are empty; `+0x80` holds `0xfcda000000070107`
(byte 0 = **7**, the RegisterGraph union tag), `+0x90` a pointer,
`+0x98` `0x31` and `+0xa0` `0x29`. So the request parse is complete and
correct; only the descriptor's required single buffer is never filled.

**Patching the fault unblocks the command.** At the stop,
`set $x8 = *(unsigned long *)($x21 + 0x10)` (the container's own
`BufferDescriptor`) and `continue`: the VII builder stops faulting, the
core sends the command, and the client receives a **200-byte response with
a structured error**, not a crash:

```
Dependent memory handle was not added: 252.
Maybe you forgot to call ImportMemoryByFd.
```

So `+0x38` is a real buffer the command must reference, its handle has to
be in the command's memory set, and the core's own check — not the VII
builder — is now the gate. The service still ended after that (gdb printed
no second stop; `SVC=dead`), so the next null is probably one of the
vectors, but the register path is no longer a blind wall.

**Next:** the missing buffer is imported but not "added". Test the handle
the error names: run the client with `SH=252` / `IH=252` (and the second
import's handle) so the buffer that fills `+0x38` names a handle the core
does have; if the message changes or the register succeeds, the slot is
right and only the handle was wrong. Then CreateExecution (9), bind (12/13)
and Invoke (11).

Phone: up, Tachyon service dead after the patched-register run, chain down;
a reboot before the next attempt.

## U127 (2026-11-09): the missing buffer is not command field 4 either

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, one boot
(`tpu-u127`), slot B. `UORDER=HDXGX` puts a real `BufferDescriptor` table
(the `X` table at 348) on the command's field 4, where `HDXGG` previously
put a second GraphDescriptor. The result is unchanged: same fault,
`libtachyon_core.so+0x5968c`, descriptor `+0x20`/`+0x38` still zero. So the
required single buffer is not a command-level field beside the descriptor
either.

The two parsed singles carry distinct pointers but we have always given
them handles that cannot be told apart. **Next: give every slot its own
handle** — `CH=252`, `SH=253`, `IH=254`, `X` at 255 — then stop at the
fault under gdb (U126's recipe) and dump `$x21+0x10` and `$x21+0x18`
pointers' first words. Which slot's handle lands where names the slot to
member mapping for the singles, and the next single slot is the one that
must fill `+0x38`.

Phone: up, Tachyon service dead after the `HDXGX` crash, chain down; a
reboot before the next attempt.

## U128 (2026-11-09): an empty vector at field 2 changes nothing; the sweep is done

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, one boot
(`tpu-e1`), slot B. `ORDER2=SSESS` declares field 2 as an **empty** vector
(a valid vector of any element type) and field 3 as a single. Result: the
same fault at `libtachyon_core.so+0x5968c`, the same zero members at
`+0x20`/`+0x38`. Either the core rejects an empty vector or field 2 is not
a vector at all; either way, no descriptor shape we can build fills the
required buffer, and the black-box sweep is finished.

**Next: catch the parse itself.** The parsed command object is larger than
`0xb8` bytes and is heap-allocated just before the VII build. Find the
allocation site (`mov w0, #0xb8` / `#0xc0` in `libtachyon_core.so`), break
there with gdb before the client sends RegisterGraph, and once the object
exists set a watchpoint on `*(long *)(cmd + 0x38)`. If a store exists, gdb
names the instruction and the field it comes from; if the watchpoint never
fires, `+0x38` is not a descriptor field and the parse's own field table,
read from the caller chain, is the answer.

Phone: up, Tachyon service dead after the `SSESS` crash, chain down; a
reboot before the next attempt.

## U129 (2026-11-09): the command object's allocation site is 0x4d53c

The core has exactly one `mov w0, #0xb8` (`libtachyon_core.so+0x4d53c`),
the session/kernel-interface construction U117 flagged (`0x4d5e4` ->
`0x511ec`); the `0xc0` and `0xe0` allocations are elsewhere. That is the
breakpoint the watchpoint step needs: `break *<core base>+0x4d53c`, let the
client send RegisterGraph, then `watch -l *(long *)($x21+0x38)` and
`continue`. A watched store names the flatbuffer field; no store proves the
member is not filled from the descriptor at all.

No phone run was made for this entry: it is a static read of
`/tmp/core-stock.dis`.

## U130 (2026-11-09): `0x4d53c` is a size, not the object's allocation

One boot (`tpu-w1`), slot B. gdb resolved the core base from
`/proc/PID/maps` (`0xffff88a2e000`) and broke at `base+0x4d544`, but `$x0`
there read **`0xb8`**: the size argument, not a heap pointer. The watchpoint
was therefore armed on `0xb8+0x38`, never fired, and the run went on to the
usual `+0x5968c` fault with `+0x38` still null. So `0x4d53c` is a length
passed to a copy, not `new(0xb8)`.

**Corrected next step:** at `0x4d53c` decode the following `bl` and break
at *its return address* (or `si` past it) so `$x0` is the returned value;
then `watch -l *(long *)($x0+0x38)`. If `$x0` is still not a pointer, find
the constructor that stores the RegisterGraph tag (7) at `+0x80` and break
there instead — that object is the parsed command.

**Candidate tag stores** (static, `/tmp/core-stock.dis`): `+0xe1930` and
`+0xe19b4` (`str w8`/`w24, [x21, #0x80]`, same function, the shape a
`{7, 1, 7, 0}` word would take), `+0xf025c`/`+0xf032c` (`[x22, #0x80]`), and
`+0x7fd4c` in the session/setup builder region. Break at `+0xe1930` first,
confirm `$x21` holds handle 2 and tag 7, then watch `*(long *)($x21+0x38)`
while the client sends `ORDER2=SSIISS UORDER=HDXGG`.

## U136 (2026-11-09): `+0x38` is never written, and the core's `252` is a message offset

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, five boots
(`tpu-u132` … `tpu-u135b`), slot B.

**The gdb base rule.** `/proc/PID/maps` lists `fake_libtachyon_core.so`
before the real library, and a grep for `libtachyon_core.so` matches the
fake first: the breakpoint then lands in no mapping ("Cannot insert
breakpoint 1"). Match the path end, `grep -E '/libtachyon_core\.so$'`, and
take that `r-xp` line; with file offset 0 the base is its start
(`0xffff7ec14000` in the run below).

**The client's chroot start.** `linker64 --library-path` is glibc syntax and
the Android linker rejects it (`expected absolute path`). The working form
is the runner's own environment:

    env LD_LIBRARY_PATH=$L LD_PRELOAD="$P" chroot --userspec=1000:1000 \
        "$R" /vendor/bin/tpu-tachyon-client.ring

with `L=/apex/com.android.tethering/lib64:/system_ext/lib64:/vendor/lib64:/system/lib64:/apex/com.android.runtime/lib64/bionic`.
The `ld.so: object … cannot be preloaded` lines are the host's glibc
`chroot` seeing the Android paths; they are noise. Rounds 1-3 (type 2 and
two type 5 imports) answer with 64-byte responses; round 4 (type 7,
RegisterGraph) is the one that fails.

**The fault is the dereference, not the field load.** The code at
`core+0x59680` is `ldr x8, [x21, #56]` (`+0x38`), then `add x0, sp, #0x50`,
`add x1, sp, #0x78`, and at `+0x5968c` `ldr x8, [x8]`. At the breakpoint
`x8` already holds the loaded value (`nil`), so writing `+0x38` changes
nothing; `set $x8` is the patch that gets past it (U126). With `$x8`
pointing at a u64 2, the builder completes and the client receives a
200-byte error response, `Dependent memory handle was not added: 252.` The
service survives that error.

**Nothing writes `+0x38`.** The command object is the 224-byte allocation
at `core+0x622e0` (`mov w0, #0xe0`; `bl 0x167c04`), and `x0` at
`core+0x622e8` is the object. A hardware watchpoint on
`*(long *)(obj+0x38)`, armed at that instruction and left through all four
rounds, **never fired**: the field is zero from allocation to the crash.
The constructor at `0x6384c` writes `+0x00..+0x18`, `+0x20`, `+0x28`,
`+0x40`, `+0x50..+0x60`, `+0x70`, `+0x78`, `+0x80` and `+0xa0`, but not
`+0x38`; this command path never initializes it. No `ORDER2` letter can fix
that, which ends the flatbuffer-shape sweep.

**252 is a message offset.** The parsed "buffers" at `[x21+0x10]` and
`[x21+0x18]` begin with `0xfc` (252) and `0x28`. At the stop, patching
those first words to the imported handles (graph 1, scratch 2) and setting
`$x8` to a u64 2 changes the response not at all: still 252. 252 is the
byte offset at which the client builds the graph-container table in the
512-byte message, so the core is using a flatbuffer position where a
memory handle belongs: it is not converting our Buffer table to
`{handle, offset, size}`. The defect is the **Buffer encoding the core
expects**, not a missing field index.

**Next: take Google's own bytes.** Run the stock app service
(`/system_ext/bin/hw/vendor.google.edgetpu_app_service@1.0-service`) in the
chroot and dump the command it writes (the handler at `core+0x622a4`
receives it; `x1`/`x2` carry the message), or follow the constructor
`0x6384c`'s caller to the Buffer reader and read the vtable slot it uses.
Encode that layout in the client, then CreateExecution (9), bind (12/13),
Invoke (11) and the benchmark.

Phone after the last run: up, service alive (the patched command returned a
response), chain up; the TPU power-up for this boot is spent.

## U137 (2026-11-09): inline Buffer structs change nothing; 252 is above the descriptor

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, one boot
(`tpu-u137`), slot B.

The client now has `A`/`B` descriptor letters that write a Buffer as an
inline struct, `{u64 handle, u64 offset, u64 size}`. The older `c`/`s`/`i`
inline encodings wrote two u32s at +0/+4, so their "handle" was never 1 or 2
(`s` was `0x0000000100000001`, `i` `0x0000000200000001`). With
`ORDER2=ABI` (container handle 1, scratch handle 2, intermediates vector)
the result is unchanged: the gdb breakpoint at `core+0x5968c` fires with
`+0x38` null, and after `$x8` is patched the client receives the same
200-byte response, `Dependent memory handle was not added: 252`.

**The response is invariant across every descriptor shape** — three table
fields, inline 24-byte structs, an empty vector, aligned u64 structs —
always 252. 252 is the byte position of the client's graph-container table
in the 512-byte message, but no shape moves it. So the core is not reading
our `GraphDescriptor` for that check at all: the value comes from the
command framing or a fixed field outside the descriptor. The descriptor
sweep is finished; more shapes cannot help.

**The util library's builder lookup missed.**
`DarwinnDelegate_CreateVirtualDevice3` stores a vtable at object+0
(`0x99ad20`), but that table's `+0x48` (`0x6f5140`) is a destructor/cleanup
routine, not RegisterGraph, so this is not the VirtualDevice vtable. The
exported thunks call `[x8+0x48]` on the device object; the real vtable is
installed elsewhere.

**Next: the import's own descriptor.** ImportMemory (type 5) is the one
command whose buffer descriptor the core accepts, so it is a working schema
sample. Capture its raw bytes and the parsed object (break at the
constructor `0x6384c`, `finish`, dump `$x0`), then encode RegisterGraph's
container and scratch the same way.

## U138 (2026-11-09): `0x6384c` builds the log record, not the parsed command

One boot (`tpu-u139`), slot B. With `TYPES=2,5` and a break at the
constructor's return site `core+0x6231c`, the object is `x22` (the
constructor stores it: `str x22, [x19]`), and it is a **log/event record**,
not the request: its `+0x00`/`+0x08` are string sizes (`0x39`/`0x30` for
AllocateTpu, `0x49`/`0x40` for ImportMemory) and its `+0x10` points at the
heap string `Session on … [Cmd 1] AllocateTpu` (type 2) or `… [Cmd 2]
ImportMemoryFromFd` (type 5). So `core+0x6384c` is the constructor of the
command's human-readable description; the U129-U137 watchpoint was armed on
that record's `+0x38` and could never fire.

The request object the VII builder reads is the one at `$x21` in the fault
(`{2, 1, ptr, ptr, …}`), built by a different path. Its `+0x10` pointee
begins `252 / 40 / 32` — a flatbuffer table position and sizes — which is
the value the core then reports as a memory handle. The request parser, not
the log record, is the missing piece.

## U139-U141 (2026-11-09): the handler, the tag, and the null at `+0x38`

One boot each, slot B. `core+0x59608` is the command handler, called from
`0x87b90` as `handler(msg, arg, out)`. `x1` is **not** the command type: a
conditional breakpoint on it never fires (the run reaches the SIGSEGV), so
the U140 hit was the first command, not a typed dispatch. The handler reads
`[msg]` -> `[msg+0x50]` (the descriptor), compares the **byte at
descriptor+0x10 with 7**, and only on equality takes `descriptor+0x18` as
the payload `x21`. It then resolves two values from that payload:

- `ldr x8,[x21,#0x10]` / `ldr x8,[x8]`: for our RegisterGraph this is
  **252**, the absolute position of the client's graph-container table, and
  it is passed to the dependency lookup. The lookup fails and the message
  `Dependent memory handle was not added: 252` is built at `0x74ff4` with
  this value as its only argument.
- `ldr x8,[x21,#0x38]` / `ldr x8,[x8]`: **0**, dereferenced with no null
  check. That is the SIGSEGV at `0x5968c`.

So the parsed payload carries one live buffer reference (252, read as a
handle) and one null reference. The union tag `7` is the client's own
`b[49] = 7`, and the payload layout that tag selects is not the layout the
client fills. The next run enumerates the tag and the payload fields, with
ImportMemory's accepted descriptor as the reference, aiming for a non-null
`[x21+0x38]` and a first value that is a real imported handle rather than a
table position.

## U142-U143 (2026-11-09): the parsed payload at the crash site

`0x59680` stops immediately before the null dereference, with `x21` already
the tag-7 payload. The conditional and `ignore` approaches before it missed
for two reasons: `x1` is not the command type, and the handler runs more
than once per client command. At `0x59680` the payload is:

    x21 = {+0x00: 2, +0x08: 1, +0x10: ptrA, +0x18: ptrB, ..., +0x38: 0}
    ptrA -> {+0x00: 0xfc (252), +0x08: 40, +0x10: 32, +0x18: 0}

So the core holds the **graph-container table's position and size**
(`{252, 40, 32}`) where a dependent memory handle belongs, and the second
reference (`+0x38`) is null: the scratch field never arrives. `x22` has
been reused by that point, so the message object needs its own capture. The
client's C table is intact (vtable at 240, table at 252 with `soffset` 12,
handle 1 at 260, offset 0, size at 276), so the parser is keeping a table
reference instead of the table's handle.

## U144 (2026-11-09): the cmd-dump interposer loads but sees no command

`$R/data/local/tmp/tpu-cmds.bin` is **0 bytes** and owned by uid 10000: the
delegate run loaded `libcmddump.so` (its constructor opened the file) but
`TachyonComputeSession_sendCommand` was never called. The vendor delegate
fails before sending anything (`CreateDevice` status 13), so its stock
message cannot be captured this way. The intercept point has to move into
the process that actually builds the message: the util library's own
`CreateVirtualDevice` path, or the core's command entry in the service.

## U145-U147 (2026-11-09): the union fields are memory handles

U145 stopped at `0x59620` on the tag-7 path and captured the parsed message
before the prologue reuses `x2`:

    m = {0x41, 0x3b, ptr, 0, vtable, fn, self, d, d2, seq, 4, 1}
    d = {4, 1, 7, payload}
    payload = {2, 1, ptrA, ptrB, ..., +0x38: 0}
    ptrA -> {252, 40, 32, 0}

The decisive reading: **252 and 40 are the raw uoffset values of the
client's `X` and `G` fields**, not addresses. With `UORDER=HDXGG` the
payload held `{252, 40}`; with `UORDER=HDXG` it held `{252, 40, 0}`; with
`UORDER=MDMK` (`M`/`K` write the imported handles) it held **`{1, 2}`**. So
the union table's fields are read as **memory handles** and resolved
directly. Our `G` field was a flatbuffer table offset (`144 - fld` = 40)
because the client wrote the descriptor that way; the core took 40 as a
handle.

The client also had a real vtable bug: with five union fields the vtable at
60 is 14 bytes and overlaps the table at 72, corrupting the fifth entry and
the table's soffset. Four fields (12 bytes) fit exactly; that changed the
payload from two recorded handles to a single vector `{1, 2}`.

The remaining null is **`payload+0x38`**, the second buffer the handler
resolves (the first is `+0x10`, handle 1). The four union fields fill only
the first; the handler reads `+0x38` unconditionally, so the graph command
needs a second handle there (the scratch) or the variant that fills it.

## U148-U149 (2026-11-09): device id validation, and type 8 is UnregisterGraph

`UORDER=MKMK` (union fields 1, 2, 1, 2) produced a clean 80-byte error
instead of the null-dereference crash: **`Device id must be 1`**. So union
field 1 is the device id, and the core validates it before resolving the
buffers; field 0 is the command handle. The remaining null in the type-7
payload is still `+0x38`, the second buffer.

With the new `TAG` override, type 8 turned out to be **UnregisterGraph**,
not RegisterGraphByBuffer: the core logged `received command ... of type :
UnregisterGraph` and answered `Release graph handle not found: 2`. The enum
so far: 2 AllocateTpu, 5 ImportMemoryFromFd, 7 RegisterGraph,
8 UnregisterGraph, 9 CreateExecution, 11 Invoke. The ByBuffer variant must
be another number.

**Next:** enumerate the remaining type numbers in one session (the core logs
each name before processing), then send the ByBuffer variant with the
descriptor's C/S tables and check its response.

## U150 (2026-11-09): RegisterGraph passes; the firmware setup is the wall

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, one boot (`u152`),
slot B.

**The register command passes the dependency check.** With the union's
four fields as handles (`UORDER=MDMK`: 1, 1, 1, 2) and the `+0x38` load
patched under gdb (break at `base+0x5968c`,
`set {unsigned long}($x21+8)=2`, `set $x8=$x21+8`), the first buffer is
handle 1 (not the 252 table position), the second is 2, and the command
advances:

    CREATED -> PENDING_VIRTUAL_DEVICE -> PENDING_FIRMWARE_BOOTUP
    Firmware::WakeUp / Successfully woke firmware up
    PENDING_FIRMWARE_BOOTUP -> PENDING_FIRMWARE_SETUP
    Sending firmware-setup VII command. type: 1 seq: 0

**The setup fails, and it is the same legacy message.** The core then shuts
the firmware down and the client gets a 72-byte `Virtual device failure`.
The driver's dump of the element:

    vii-elem: seq 0, code 0, dma 0xfff80000 size 0x50
    vii-payload 0:  00000014 00000000 000a0000 00080012
    vii-payload 16: 000c0007 0000000a 05000000 00000030
    vii-payload 32: 0000000c 00060000 00040008 00000006
    vii-payload 48: 00000004 00000001 ff600000 00000000
    vii-payload 64: 00100000 ...

and the firmware answers `Setup is not done yet received a command of type
0.` The payload is the same three-field legacy setup the HAL sends (U75:
fields 48, 5, 6), so the tegu core's setup is not the type-1 message
cheetah's A17 firmware wants either.

**The path is now:** a correct command -> the firmware setup gate. Next is
the setup element itself: patch its code/type to 1 and read the firmware's
answer; if it names the missing global scratches, build them from the graph
descriptor's scratch into the message.

**Type map, completed for 1-10:** 3 AllocateDspTpu, 4 AllocateDsp,
6 ReleaseMemory, 9 CreateExecution, 10 DeleteExecution; 2/5/7/8 as before.
No ByBuffer variant exists. A five-field union is rejected (`Invalid
command flatbuffer`); the vtable header is `4 + 2*nu` and a five-field
table must sit at 80, not 72 (fixed in the client).

## U151 (2026-11-09): the setup element is the legacy message; no VII setup code

Static checks after U150. The driver has no VII setup type or element code
(`drivers/edgetpu` defines only the KCI codes), so the element's `code 0`
is an ordinary command and the firmware's "type 0" is that code. The
firmware strings (`out/tpu-firmware/edgetpu-janeiro.fw` at 0xefbdc,
0xefd8c, 0xefddc, 0xefe18) name the missing piece: a setup command that
carries the global scratches. The gxp stub is loaded (`gxp 12288 0`,
`/dev/gxp` 10:258) and the core never queries it (U113). The tegu core's
setup builder (`0x7f9c4`) emits the same 80-byte legacy payload the HAL
sends, so it has no type-1 setup message for cheetah's A17 firmware.

Next: build the type-1 setup message itself (the firmware's handler wants
the cluster bitset and the global scratch list) and submit it as the setup
element, or recover the message from a userspace that has the real setup
producer. The RegisterGraph command path is otherwise correct.

## U152 (2026-11-09): the stock delegate's tachyon path hits the same setup

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, one boot (`u153`),
slot B. The chain (`NO_DELEGATE=1`) plus the stock delegate
(`edgetpu-run /vendor/etc/model.tflite`, uid 10000, the tachyon client path)
opens a session and sends the same setup **three times**: the delegate logs
`create device status: 13` and `device: 0x0`. `dmesg` shows three
`OPEN_DEVICE` lines, each followed by `Setup is not done yet received a
command of type 0.` and the same payload (root `0x14`, fields 48/5/6).

No `RegisterGraph` reached the core (gdb at `0x59620` never hit), and the
`libcmddump.so` file is 0 bytes: the delegate fails at the virtual device,
before it sends any command through the client library. So the stock
client's session config does not carry the missing scratches either; the
setup message belongs to the core, not the client.

## U153 (2026-11-09): no userspace produces the type-1 setup; the bootloader does

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, boot `u154` (A14
firmware) and `u155` (A14 HAL/util, direct path as root).

**Older firmware does not accept the legacy setup.** With
`out/tpu-firmware/edgetpu-janeiro-a14.fw` (985 344 B, sha
`145993a4e300…`) loaded through GSA (`loaded prod firmware (1.0
539775951)`), the ring client's RegisterGraph still ends in
`Setup is not done yet recieved a command of type 0.` (the A14 firmware's
spelling) with the same payload. The A14 firmware wants the type-1 setup as
much as the A17 one.

**The A14 HAL is not the producer either.** The stock A14 direct-path
libraries (`out/a14-edgetpu/libdarwinn_hal.so`, sha `d29cba6b…`, and
`libedgetpu_util.so`, sha `013fb75c…`, pushed to the chroot's
`/vendor/a14/`) create a device on `/dev/edgetpu` as root and send the same
legacy three-field payload; the delegate reports `create device status: 13`
and `device: 0x0` after three attempts. The A14 HAL's setup-failure string
is the same `commands[%d], cluster_id_bitset in hex: %x` one.

So every available userspace producer — the tegu Tachyon core, the A17
HAL, the A14 HAL, the Tachyon client — emits the legacy type-0 setup, and
both cheetah firmware generations refuse it. The stock path must therefore
be the bootloader: `janeiro-pm.c`'s own comment says stock is "image loaded
and started by the driver, unlike stock where ABL leaves the TPU running".
ABL sets the firmware up before Linux, and the host HAL's legacy message is
never the setup that matters on a stock boot.

**Next:** extract the cheetah ABL from `out/factory/cheetah-factory.zip`
and find its TPU/janeiro setup code — the global scratch descriptors and the
cluster bitset — then replicate that type-1 command from the host.

## U154 (2026-11-09): the A14 HAL's direct create resets the phone

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, boot `u157`, A17
firmware restored after the run.

**The chroot needed basic nodes.** The A14 HAL crashed in its constructors
on `/dev/urandom`; after `mknod` for `null`, `zero`, `random`, `urandom` in
the chroot, the A14 table loaded and printed its 24 entries.

**The direct create is unsafe.** With `janeiro` loaded and `/dev/edgetpu`
pointing at the real `/dev/janeiro` (char 501,0), `tpu-a14-hal vd B` opens
`/dev/edgetpu` and enters `CreateDevice`; the call blocks in the driver's
group finalize (the tool's own comment says the A14 stack is the first
client seen to send VII from create). After the first B=1 run the SSH link
dropped and the phone came back with a fresh uptime, i.e. a watchdog reset.
The tool's 8-second queue watcher and `_exit` did not prevent it. The
cluster-bitset result is therefore **inconclusive**, and this path must not
be run again on the shared phone.

**Next:** do not use the A14 HAL direct path. The remaining safe producer
candidate is the A14 cheetah `libtachyon_core.so`: the A17 chroot's core is
a 1 015 720 B stub, and a real A14 core would send the type-1 setup through
the Tachyon ring (the harness that has never hung the phone).

## U155 (2026-11-09): the A14 vendor image has no Tachyon core; the kernel is the suspect

`out/android14-ota/extracted/vendor.img` is the Android 14 factory image
(`UP1A.231005.007`, ext4, 740 487 168 B). `debugfs -R 'ls -l /lib64'` lists
the A14 HAL (49 768 952 B), the util (3 400 592 B), the app and vendor
services and the DBA — and **no `libtachyon_core.so`**. Cheetah's A14 stack
used the direct HAL, not the Tachyon service, so there is no cheetah core to
recover: the A17 chroot's 1 015 720 B core is the stub, and the 1 538 440 B
tegu core is the only real one.

That leaves the **kernel driver** as the difference. The same A14 HAL plus
A14 firmware pair that ran the TPU on stock A14 sends its legacy setup
through our mainline `drivers/edgetpu` and is refused, so the missing step
is likely in the driver's VII mailbox init, the KCI open/attach sequence,
the GSA power-up sequence (`cmd 150/50/151`, `TPU cmd 1`) or the setup
element, not in userspace. Google's stock gs201 driver (the GPL kernel
source) is the reference to diff against; the bootloader's hwmgr/tpu-image
code (segments `0x7a8000`, `0x7fac00`) is the other source.

## U156 (2026-11-09): the driver matches the stock Android 16 driver

Google's gs201 Android 16 GPL tree is on disk at
`~/omamobile-kernel/edgetpu-janeiro/drivers/edgetpu`; the port is
`~/omamobile-kernel/wt-tpu/drivers/edgetpu`. The diff is bring-up logging
only: `edgetpu-kci.c` (+31 lines: the KCI timeout parameter, queue/tx logs,
`cur_seq` reset), `edgetpu-mailbox.c` (+148: the VII payload dump),
`edgetpu-device-group.c` (+9: finalize logs), `edgetpu-firmware.c` (+1:
a 50 ms sleep before the handshake), `mobile-firmware.c` (+1 include), and
`edgetpu-pm.c` / `mobile-pm.c` are the stock files verbatim. That includes
`edgetpu_kci_open_device` (KCI code 9), the VII mailbox attach/init, the
`edgetpu_pm` wakelock and delayed power-down work, and the vendor power-up
order (ACPM state, `lpm_up`, `edgetpu_chip_init`, firmware restart).

So the missing setup is **not** a dropped driver step. The port's own
comment in `janeiro-pm.c` names the gap: "on our cold path (image loaded and
started by the driver, unlike stock where ABL leaves the TPU running)". On
stock the TPU is already running when the driver first touches it, so the
image load/start are no-ops and whatever setup the bootloader did survives;
here the first access sees GSA state 0 and starts a fresh image. The type-1
setup therefore has to come from outside the driver: the bootloader's
`hwmgr`/`tpu-image` code or the stock vendor service's device spec.

## U157 (2026-11-09): the bootloader's TPU image manager, and why the xrefs need a PC-relative pass

The ABL bundle `out/factory/cheetah-abl/cheetah-cp2a.260705.006/bootloader-cheetah-cloudripper-17.0-15199429.img`
is an `FBPK 2.0` container (`gs201`, `cloudripper-17.0-15199429`). Its
embedded ELFs are at file offsets `0x270ffe`, `0x273e00`, `0x284e00`,
`0x3d8e00`, `0x4e6b00`, `0x523580`, `0x632d00`, `0x6a8000`, `0x6b0d00`,
`0x6bd400`, `0x6c9000`, `0x6da000`, `0x6eda00`, `0x793400`, `0x79d000`,
`0x7a8000`, `0x7db800`, `0x7dd000`, `0x7e5000`, `0x7fbe00`, `0x80b800`.

* **GSA firmware**: the ELF32 ARM image at **0x7fbe00** (65 536 B, entry
  `0x13005`, stripped; `.text` `0x13000`-`0x1e8d4`, `.rodata`
  `0x10118`-`0x127f8`). Its strings are the TPU image manager:
  `sz >= sizeof(tpu_img_config)` (`0x102fb`), `TPU fw is already loaded`
  (`0x10855`), `tpu_set_dvfs_opp` (`0x10990`), `TPU is already running`
  (`0x10c02`), `TPU mmap failed` (`0x10cca`), `failed to init TPU image
  manager` (`0x10e05`), `tpu-mgr` (`0x11827`), `tpu-image.c` (`0x1182f`),
  `tpu_get_img_config` (`0x1214f`), `TPUF` (`0x12538`), and
  `req_cmd == GSA_MB_CMD_AUTH_IMG` (`0x114aa`).
* **Trusty apps**: the aarch64 `hwmgr` at **0x6bd400** carries
  `com.android.trusty.gsa.hwmgr.tpu` and `tpu-mbox`; the aarch64 app at
  **0x7db800** carries `tpu-mbox`/`tpu-mgr`.

The kernel side has no scratch list to borrow: `mobile_image_config`
(stock and port, identical) holds `mappings[23]` and `ns_iommu_mappings[5]`
but no scratches, so the global scratch/bitset setup lives in the GSA
firmware's image manager.

The string addresses are **not** absolute little-endian literals in
`.text` (a scan for `0x102fb` etc. finds none), so this ARM32 image
resolves them PC/base-relative or is relocated. The next pass disassembles
around the `.rodata` offsets with `llvm-objdump --triple=armv7` and the
`adr`/`add` PC-relative sequences, then reads `tpu_get_img_config`'s size
check and field accesses. The A14 vendor image has no `/vendor/etc/edgetpu`
and only the TPU libraries in `/lib64`, so there is no model or device spec
to borrow either.

## U158 (2026-11-09): `tpu_img_config` is the 0x100-byte mobile mapping table

The GSA firmware (ARM32, ELF at bundle offset `0x7fbe00`) loads its
`.rodata` addresses with Thumb-2 `movw`/`movt` pairs, which locates the
image manager:

* **`tpu_get_img_config`** starts at **`0x18e52`**: `cmp r1, #0xff;
  bls` the error path, so the caller's size must exceed 255; the success
  path copies **`0x100`** bytes (`mov.w r2, #0x100; bl 0x144a6`, a memcpy)
  from the image manager's buffer to the config. The error path prints
  `sz >= sizeof(tpu_img_config)` (`.rodata` `0x102fb`) with `__func__`
  (`0x1214f`) and `tpu-image.c` (`0x182f`). So
  **`sizeof(tpu_img_config)` = `0x100`**, which is exactly the kernel's
  `mobile_image_config`: 4+4+4+16+4+4+4+4+4+23×8+4+5×4 = 256 bytes.
* The image manager's mmap path at **`0x18b28`** records the TPU ranges
  base+`0x10000` and base+`0x30000`, i.e. the mapping table's virtual
  ranges. `tpu_start`/`TPU is already running` is at **`0x18eea`**; the
  AUTH_IMG check is at **`0x1a7e2`**; the image-magic helper at
  **`0x19d14`** compares `TPUF`/`AOC`/`CHRE`.

The config therefore carries the firmware's **mapping table** (the 23
`iommu_mapping` entries: TPU virtual address + physical page), not a
separate scratch array. The type-1 setup's "global scratches" are those
mapping entries — the TPU address ranges the firmware is allowed to use —
so the next step is to read the vendor image's config at `0x400 + 0x160`
(the `TPUF` header's `ImageConfig`) and turn its mapping list into the
setup element.

## U159 (2026-11-09): the firmware config's mapping table

All three janeiro firmware images carry `TPUF` at `0x400` (the
`mobile_image_header`) and the `mobile_image_config` at `0x560`. Parsed:

| | A17 (`52c1cccd…`) | A14 (`145993a4…`) | cp3a (`7ea9100f…`) |
| --- | --- | --- | --- |
| carveout | `0x93000000` | `0x93000000` | `0x93000000` |
| firmware_base | `0x93000000` | `0x93000000` | `0x93000000` |
| firmware_size | `0xfd000` | `0xf0000` | `0xfd000` |
| version | `1.0.2.3` | `1.0.2.2` | `1.0.2.3` |
| config_version | 1 | 1 | 1 |
| privilege | 1 (TZ) | 1 (TZ) | 1 (TZ) |
| remapped region | `0x93200000`-`0xe00000` | same | same |

The mapping table is the same in all three:

* `map[0]`: TPU `0x10000000` → physical `0x93000000`, 16 MiB (the
  firmware carveout).
* `map[1]`: TPU `0x11000000` → physical `0x18290000`, 64 KiB.
* `map[2]`: TPU `0x11010000` → physical `0x1cc00000`, 64 KiB (the TPU's
  SSMT/CSR window).
* one non-secure mapping: `0x12000012` (TPU `0x12000000`).

These are the firmware's address space and the type-1 setup's global
scratch ranges. The remaining unknown is the **command format**: how the
stock util/HAL and the tegu core lay these entries into the type-1 setup
element. The next iteration reads the stock util's setup builder
(`libedgetpu_util.so`/`libdarwinn_hal.so`, the plan's U51 addresses) and the
tegu core's setup at `0x7f9c4`, then builds the element and submits it
through the ring client.

## U160 (2026-11-09): the tegu core's setup producer, and why the cheetah HAL is the right builder

The tegu core (`out/edgetpu-runtime/libtachyon_core.so`, 1 538 440 B,
aarch64, stripped) does carry a firmware-setup producer:

* `PushFirmwareSetupCmdToVII failed` (`.rodata` `0x8b7e`), referenced at
  `0x7531c`, `0xa479c` and `0xd36e0`; `Multiple intermediate buffers
  provided, only using the first one for DIVE model info scratch.`
  (`0x7a2f`) at `0x89600`; `...firmware_setup_status_ ==
  VirtualDevice::FirmwareSetupStatus::NOT_STARTED` (`0x5b7d`).
* The caller at `0xa4748` walks a component list (`ldr x0, [x1]`; `ldrb
  w8, [x0, #0x30]`; `ldr w8, [x0, #0xa8]`; `cmp w8, #0x1`) and calls
  `0xab0c4` once per component, then `0xa4954`; the failure is logged at
  `0x701bc` with the `PushFirmwareSetupCmdToVII failed` string (`w3=0x20`,
  `w4=4`). So **`0xab0c4`** is the per-component setup push.

That is the **tegu's** multi-component/DIVE path, not the cheetah's
single-core one. The cheetah's userspace runtime is embedded in the A14/A17
`libdarwinn_hal.so` (49 MB / the A17 HAL in the phone's chroot), so the
cheetah's setup command type and scratch layout must be read there, not
from the tegu core.

## U161 (2026-11-09): the A17 stack is the cheetah's Tachyon stack, and the setup builder is in the HAL

The A14 image has no Tachyon core (U155), but the A17 factory image
`out/factory/fw/img/vendor.img` (`cp2a.260705.006`, ext2, 841 850 880 B)
does. The files are extracted to `out/a17-edgetpu/`:

* `libtachyon_core.so` — 1 015 720 B, sha `47fb5f74…`, cheetah's core,
  identical to the chroot's. It exports only `TachyonCore_CreateClientSession`,
  `_Start`, `_SendClientAssignedFds`, `_Shutdown` (transport, no setup
  strings).
* `libedgetpu_util.so` — 3 813 648 B, sha `90908694…`, identical to the
  chroot's. New `DarwinnApi2` API (`VirtualDevice_GetViiVersion`,
  `CreateRequestQueue`, `RegisterGraph*`, `Submit*`,
  `Request_CreateViiCommand`) plus the old `DarwinnDelegate_*` that
  `edgetpu-run` calls. Its runtime has `firmware_setup_done_`,
  `SetRegistrationInfo(options.model_info_scratch, …)`, the DIVE scratch,
  and `Only an Abrolhos/Janeiro chip of MMIO platform type is supported.`
* `libdarwinn_hal.so` — 37 089 408 B, sha `edf6abfb…`, the A17 HAL. It is
  self-contained (NEEDED only libc/libm/libdl/liblog) and carries the
  `JaneiroDriverProvider`/`AbrolhosDriverProvider` runtime, the
  `Firmware setup failed for commands[%d], cluster_id_bitset in hex: %x.`
  string (`0x4b8c71`), the `firmware_setup_done_ = false` wakelock
  callback, and the embedded `janeiro_a0_config.binarypb` /
  `janeiro_a0_config_memfile` / `janeiro_csr_layout.pb.txt`.
* `com.google.edgetpu.tachyon-service` (70 024 B) and
  `android.hardware.neuralnetworks@service-darwinn-aidl` (814 328 B): the
  stock AIDL services. The NNAPI service calls `GetDarwinnHalFunctions`
  and `EdgeTpuServiceAppConnector::Create/GetEdgeTpuFd/CompileTfLiteSubgraph`
  and checks the Power HAL (`ML_ACC is not supported by the Power HAL`).
  The vendor service is the compiler service (`libedgetpu_tflite_compiler.so`).
* `etc/earcheek_classifier.tflite` (15 120 B) is a CPU TFLite model
  (`CONVERSION_METADATA`, TFLite ops): no device spec to borrow.

The A17 HAL's `GetDarwinnHalFunctions` (`0x16946ec`) returns `0x22b79a8`
in `.data`, a table of small values, not absolute pointers; the HAL API
table layout must be read from the NNAPI service's calls. The setup-failure
string has one exact reference in `.text`: `0x14d9d40` (an earlier pass
matched a different string at `0x47ec71`). The surrounding function
(`0x14d9a80`-`0x14d9dcc`) walks `[x19+0x68]`/`[x19+0x70]` in 24-byte
entries, walks the cluster ids at `[x19+0x230]`, calls the per-command
send at `0x14d9eac` and the overall result at `0x14e3388`, sets a success
flag with `stlrb #1, [x19+0x180]`, and logs the failure at `0x14d9d40`
with the count and bitset. So the setup is built locally from the Janeiro
config, not from the delegate's default spec.

## U162 (2026-11-09): the type-1 serializer's field map, and the core Start is a stub

Static pass over the A17 HAL (`out/a17-edgetpu/libdarwinn_hal.so`, sha
`edf6abfb…`) and core (sha `47fb5f74…`). Nothing on the phone changed.

* **The core is not the producer.** `TachyonCore_Start` (`0x51590`) calls
  `0x515b4`, which only returns, and `TachyonCore_CreateClientSession`
  (`0x51078`) builds a 0x58-byte session config and takes the known
  "InternalCreateClientSession is not implemented" path at `0x51480`.
  The A17 core has no setup strings and no setup code.
* **The HAL's setup builder sends a type-1 VII command.** The per-command
  send `0x14d9eac` calls the builder/sender at `0x14de9cc`: it initializes
  a flatbuffer builder (1024 bytes, the 16-byte constant at `.rodata`
  `0x4fb760`), serializes the command through `0x14deed8`, and submits it
  through the provider's vtable at `[x20+0x170]` (method `+0x18`) with
  `w1` = the builder's size. The status check is `0x14e3388`, and the
  success flag is `stlrb #1, [x19+0x180]` (the `firmware_setup_done_`
  byte U56 saw).
* **The command's type byte selects the serializer.** `0x14deed8` reads
  the command entry's payload vector with `0x14dfe8c` (8-byte elements,
  empty → a default at `0x2371000+0xa78`), the type byte at `+0x18`, and
  dispatches through `0x14dfea8` to one of seven serializers; type 1 is
  `0x14e0380` (types 2/4/5/6/7 are `0x14e0de4`, `0x14e0c98`, `0x14e0d98`,
  `0x14e0b8c`, `0x14e0e40`).
* **The type-1 table's field map.** `0x14e0380` calls `0x14e04c8`, whose
  setters pass the FlatBuffers field offsets `4, 6, 8, 10, 20, 22, 24,
  26, 28`, i.e. field ids `0, 1, 2, 3, 8, 9, 10, 11, 12`. Fields 2 and 3
  are the two vectors (setters `0x14e0654` from `[x20+0x30]` and
  `0x14e0640` from `[x20+0x38]`); the serializer builds one vector with
  16-byte elements (`0x14e049c`, `w3=0x10`) and one with 64-byte elements
  (`w3=0x40`). Fields 0/1/10 are 4-byte (`0x14e06ac`, `0x14e069c`,
  `0x14e068c`), fields 8/9 bytes (`0x14e06d0`, `0x14e06bc`), and fields
  11/12 16-bit (`0x14e0678`, `0x14e0668`). The command object's
  `[x20+0x40]`/`[x20+0x42]` supply the 16-bit values, `[x20+0x48]` feeds
  the field-10 table, and `[x20+0x60]` the last argument.
* **The stock NN service is present but not runnable yet.** The chroot has
  `vendor/bin/hw/android.hardware.neuralnetworks@service-darwinn-aidl`
  (814 328 B, links `libdarwinn_hal.so` directly) and the A17 NNAPI AIDL
  libs, but no `libneuralnetworks.so` runtime (only
  `libneuralnetworks_packageinfo.so`). Its HAL is the exact type-1
  producer; without the runtime, the ring client is the shorter path.
* The chroot's HAL/util/core are patched copies (HAL
  `c04ad3249d3c…`, util `1985659e20e5…`, core `d1602625abb0…`), with
  `.orig` backups; the A17 originals are in `out/a17-edgetpu/`.

**Next:** add a type-1 setup table to the ring client with fields 2 and 3
as the vectors (the 16-byte scratch ranges first: the U159 mapping table
`0x10000000`+16 MiB, `0x11000000`+64 KiB, `0x11010000`+64 KiB, and an
empty resource vector), then the scalar fields, and read the firmware's
answer. If it accepts, send `TYPES=2,5,5,7 UORDER=MDMK` plus the gdb
patch and continue to RegisterGraph/CreateExecution/Invoke.

## U163 (2026-11-09): the type-1 setup command runs on the ring

Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, one boot, slot
B. `tools/tpu-tachyon-client.c` gained a `SETUP=1` path for a type-1
command: the payload table's field 2 is a vector of three 16-byte
`{address, size}` entries (TPU `0x10000000`+16 MiB, `0x11000000`+64 KiB,
`0x11010000`+64 KiB) and field 3 is an empty resource vector, with every
other field absent. Built with the pinned clang and run as uid 1000
against the stock tachyon service (its own `TYPES=1 SETUP=1`):

    create: OK
    createSession: OK
    setupCommandQueue: OK fds=12,13
    setupResponseQueue: OK fds=15,16
    round 1 sendCommand: OK
    response size=96
    18 00 00 00 00 00 00 00 00 0e 00 1c 00 10 00 07 00 08 00 ...

`dmesg` shows the first `KCI tx code 21 seq 3` of the boot, the phone
stayed up, and there is no `Setup is not done yet` line. The 96-byte
response is a flatbuffer result, not the 72-byte `Virtual device failure`
and not an ASCII error; its exact status and the hash at +0x58 are not
decoded. The client was killed by its own 40 s `timeout` (it sleeps 120 s
after the round), so the tachyon service logged the client death and
exited; the TPU did not power down and the firmware setup is global.

**Next:** in the same boot, send the full `TYPES=1,2,5,5,7 SETUP=1
UORDER=MDMK` sequence with the `core+0x5968c` gdb patch (`set
{unsigned long}($x21+8)=2; set $x8=$x21+8`), then CreateExecution,
BindInputBuffers, BindOutputBuffers and Invoke on the SSD model, and the
benchmark. A RegisterGraph that proceeds is the decoded proof the setup
was accepted; a 96-byte result without that is not.
