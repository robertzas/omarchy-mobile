# Pixel 7 Pro (cheetah, gs201) bring-up map: M1 "first light"

Goal: mainline **v7.3-rc6** boots to an Arch initramfs, console on the bootloader framebuffer through `simple-framebuffer`,
USB gadget NCM (dwc3) so we can ssh in. UFS is a stretch goal.

Path abbreviations used for citations (`file:line`):

| Tag | Path |
|-----|------|
| `G`  | `/home/raven/android/omamobile/out-kernel/google/gs-6.1` (Google GPL 6.1 tree) |
| `GD` | `G/private/devices/google` (`gs201/dts`, `pantah/dts`, kleaf build files) |
| `GM` | `G/private/google-modules` (`soc/gs` = SoC drivers, CAL, bindings) |
| `GO` | `G/out/pantah/dist` (Google build artefacts: `boot.img`, `vendor_kernel_boot.img`, `dtb.img`, `dtbo.img`) |
| `M`  | `/home/raven/android/mainline/linux` (v7.3-rc6) |
| `P`  | `/home/raven/android/mainline/pmos-tensor` |
| `R`  | `/home/raven/android/reference/cheetah-stock-cp2a` (live stock data) |

Labels: **[V]** = checked in sources or artefacts. **[I]** = inference that has to be checked on the device.

---

## 1. Boot chain (most important section)

### 1.1 Facts

| Item | Value | Evidence |
|------|-------|----------|
| Bootloader | ABL `cloudripper-17.0-15199429`, device **unlocked** | `R/fastboot-getvar-all.txt:319,315`; `R/getprop.txt` `ro.boot.flash.locked=0` [V] |
| Partitions (A/B) | `boot`, `init_boot`, `vendor_boot`, `vendor_kernel_boot`, `dtbo`, `vbmeta*`, `pvmfw`; no `super` slotting | `R/fastboot-getvar-all.txt:28-36` [V] |
| Partition sizes | boot 64 MiB, init_boot **8 MiB**, vendor_boot 64 MiB, vendor_kernel_boot 64 MiB, dtbo 16 MiB | `R/fastboot-getvar-all.txt:146-150` [V] |
| Boot image header | **v4** (`BOOT_IMAGE_HEADER_VERSION=4`) | `GD/common/kleaf/files/build.config.common:6`; `GO/boot.img` unpacks as "boot image header version: 4" [V] |
| boot.img contents (stock GKI) | kernel only, **ramdisk size 0**, empty cmdline. The kernel is **LZ4-legacy** (magic `02 21 4c 18`) | `unpack_bootimg.py` on `GO/boot.img` [V] |
| Generic ramdisk | in `init_boot` (ABL loads it: `KL_INTB`) | `R/getprop.txt:438` boottime_extra [V] |
| Where the DTB lives | **`vendor_kernel_boot.img` → vendor-boot-v4 `dtb` section**, which is `dtb.img` = a plain concatenation of `gs201-a0.dtb`, `gs201-b0.dtb` and `gs201-b0_v2-ipop.dtb` | `GD/common/kleaf/device_build.bzl:230` ("dtbs must be in outs to be packed into vendor_kernel_boot.img"), `:402-423`; `GD/pantah/BUILD.bazel:16-23`; `G/build/kernel/build_utils.sh:601-611` (cat *.dtb > dtb.img, `--dtb`). `GO/vendor_kernel_boot.img`: VNDRBOOT v4, dtb size 886583 = 3 FDTs [V] |
| vendor_kernel_boot header | page 2048, kernel_addr 0x10008000, ramdisk_addr 0x11000000, tags 0x10000100, dtb_addr 0x11f00000 (mkbootimg **defaults**, `BASE_ADDRESS` unset) | unpacked `GO/vendor_kernel_boot.img` [V] |
| Base DTB selection | by **`/soc_id`** in each FDT. ABL builds `(product_id 0x09855000) \| major_rev` and compares it with `soc_id[0]`. a0 = `0x09855000`, b0 = `0x09855001`. b0_v2-ipop uses `/soc_compatible/B0_IPOP {product_id=0x09855; major=1; pkg_mode=1}` | `GD/gs201/dts/gs201-b0.dts:10-17` (comment states the algorithm), `gs201-a0.dts:10`, `gs201-b0_v2-ipop.dts:10-21` [V] |
| Device SoC | `ro.boot.hw.soc.rev=2`, `pkg_mode=0`, so **b0 is the expected match** (ipop needs pkg_mode=1) | `R/getprop.txt:462-463` [I: how "rev 2" maps to major 1 is unknown] |
| Board overlay selection | `dtbo.img` (mkdtimg table) keyed by `/board_id` and `/board_rev` of each overlay: `MKDTIMG_FLAGS="--page_size=4096 --id=/:board_id --rev=/:board_rev"` | `GD/common/kleaf/files/build.config.common:9` [V] |
| cheetah MP overlay | `board_id = <0x30306>`, `board_rev = <0x10000>`; fragment sets `model`/`compatible = "google,GS201 CHEETAH","google,GS201"` | `GD/pantah/dts/gs201-cheetah-mp.dts:14-22` [V] |
| Live selection | `ro.boot.cdt_hwid=0x00030306 00010000…`, **`ro.boot.dtbo_idx=12`**. Parsing `GO/dtbo.img` gives entry 12 = id 0x30306, rev 0x10000 = `gs201-cheetah-mp.dtbo` (also index 12 in `GD/pantah/constants.bzl:7-20`) | `R/getprop.txt:439,444` [V] |
| Overlay needs symbols | base DTBs are built with `-@` (`__symbols__`) because ABL applies overlays that use `&label` | `GD/gs201/dts/Makefile:6` [V] |
| **Second overlay source: DPM** | ABL also applies a "debug policy" overlay from the `dpm` partition (`ODT_DPM` in boottime). It targets `&dpm`, `&log_arrdumppanic`, `&log_preslcdump`, `&log_slcdump`, plus a `target-path="/"` `avf` fragment | `GD/gs201/dts/gs201-dpm-user.dts:1-7`, `gs201-dpm-user.dtsi:5,69-79`, `avf-dpm-user.dtsi:12-16`; `R/getprop.txt:438` (`ODT_DOARD:15, ODT_DPM:0`) [V] |
| Other ABL load steps | `KL_BOOT`, `KL_INTB` (init_boot), `KL_VDRB` (vendor_boot), `KL_VDRKB` (vendor_kernel_boot), `KL_DTBO`, `KL_PVMFW`, `DISP:249` (ABL brings up the panel) | `R/getprop.txt:438` [V] |
| bootconfig | in use: `bootconfig` appears on the cmdline 3 times, and `androidboot.*` moved to bootconfig (`ro.boot.*`). The vendor_kernel_boot bootconfig section is empty, so ABL and vendor_boot provide it | `R/cmdline.txt`; vkb unpack "vendor bootconfig size: 0" [V] |
| Stock cmdline composition | (a) `console=ttynull … kvm-arm.mode=protected bootconfig ioremap_guard` comes from the vendor_boot cmdline [I]. (b) `clocksource=arch_sys_counter root=/dev/ram0 … clk_ignore_unused … kvm-arm.protected_modules=…` comes from the **DTB `/chosen/bootargs`**, with `earlycon/console/androidboot.*` stripped (`GD/gs201/dts/gs201.dtsi:80-82`). (c) ABL appends `console=null exynos_drm.panel_name=sdc-s6e3hc4 tcpci_max77759.conf_sbu=0 ufs_pixel_fips140.* id_aa64mmfr1.vh=0 bootconfig` | `R/cmdline.txt` vs `gs201.dtsi:81` [V for (b) and (c); I for the source of (a)] |
| Memory node | **ABL injects `/memory`**: neither Google's gs201 DTS nor upstream gs101 has a memory node. 12 GiB LPDDR5 (Micron); MemTotal 11743512 kB | `grep` gives no `memory@` in `GD/gs201/dts` or `M/arch/arm64/boot/dts/exynos/google`; `R/fastboot-getvar-all.txt` `ddr-size:12GB` [V] |
| Upstream ABL quirks (gs101, same ABL family) | `/chosen/bootargs` must exist or ABL crashes. An empty `/ect` node is required | `M/arch/arm64/boot/dts/exynos/google/gs101-pixel-common.dtsi:24`; `M/Documentation/devicetree/bindings/arm/google.yaml` ("Bootloader requires empty ect node"); `M/.../gs101.dtsi:476` [V] |

### 1.2 Conclusions for a mainline Image + DTB

1. **Load address.** ABL ignores the header load addresses. The stock images carry mkbootimg defaults (0x10008000 and so on) that point into SoC MMIO (`chipid@10000000`, `GD/gs201/dts/gs201.dtsi:75-78`), so ABL must place the kernel per the arm64 boot protocol. Ship `Image.lz4` first, because that is the format stock uses. A raw `Image` probably also works [I].
2. **DTB delivery.** The DTB **is not appended** to the kernel and **is not in boot.img** (on v4, boot.img has no dtb field). Put it in the **`dtb` section of a v4 vendor boot image flashed to `vendor_kernel_boot`**, the same as stock. Leave stock `vendor_boot` either without a dtb section or replace it [I: dump stock `vendor_boot` with `unpack_bootimg.py` from a factory image to confirm it has none].
3. **Make ABL's matcher happy.** Put `soc_id = <0x09855001 0x0>` in our DTB. As belt-and-braces, concatenate **two copies** of our DTB in the dtb section, one with `0x09855000` and one with `0x09855001`. Fallback behaviour when nothing matches is unknown. Upstream gs101 DTBs have no `soc_id` and still boot on Pixel 6, which suggests a fallback exists, but that is unverified.
4. **dtbo.** The stock cheetah-mp overlay references dozens of Google labels and will fail against a mainline DTB. **Flash a custom `dtbo.img`** with a single trivial overlay keyed `board_id=0x30306`, `board_rev=0x10000` (sketch in §4.3), built with `G/prebuilts/kernel-build-tools/linux-x86/bin/mkdtimg` or `G/build/kernel/build-tools/path/linux-x86/mkdtboimg.py` using the same flags as `build.config.common:9`.
5. **DPM overlay.** It comes from the `dpm` partition, which we will not touch. Compile our DTB with `-@` and add label stubs `dpm`, `log_arrdumppanic`, `log_preslcdump` and `log_slcdump` so the DPM overlay applies cleanly (§4.1).
6. **Ramdisk placement.** ABL concatenates the vendor_boot ramdisk, then the vendor_kernel_boot ramdisk, then the generic ramdisk (init_boot), then bootconfig. Later files overwrite earlier ones, so a stock `init_boot` would override our `/init`. Plan:
   - `vendor_kernel_boot`: our DTB(s) plus **our Arch initramfs** (64 MiB partition).
   - `init_boot`: v4 boot image with an **empty cpio**.
   - `vendor_boot`: empty ramdisk plus our vendor cmdline (drops `console=ttynull`, `kvm-arm.mode=protected`).
   - `boot`: v4 with `Image.lz4` only.
7. **bootconfig.** Enable `CONFIG_BOOT_CONFIG=y`. ABL appends a bootconfig trailer to the initrd. With BOOT_CONFIG off the kernel will not strip it, and initramfs unpacking can choke on the trailing data [I].
8. **cmdline.** Put what we need in `/chosen/bootargs`, because ABL keeps DTB bootargs (that is how stock gets `clk_ignore_unused`). ABL appends `console=null`. That console name has no driver and should be ignored, but check that `/dev/console` lands on `tty0`. `id_aa64mmfr1.vh=0` (forced nVHE) is appended by ABL and is harmless.
9. **AVB.** The device is unlocked, so modified images boot with the orange-state warning. If ABL refuses, use `fastboot --disable-verity --disable-verification flash vbmeta …`.
10. **Safety.** Flash everything to **slot b** and use `fastboot set_active b`, keeping slot a stock. First check that slot b's bootloader images match slot a (`version-bootloader`), and flash the factory bootloader to b if they do not.

---

## 2. Memory map

DRAM: injected by ABL (see §1.1). Capture the real ranges on first boot from `/sys/firmware/fdt` (`/memory`, `/chosen`, `/reserved-memory`).

Reserved regions that firmware or co-processors own (Google `GD/gs201/dts/gs201-rmem.dtsi`, line numbers in that file):

| Node | Base | Size | Flags | Line |
|------|------|------|-------|------|
| ect_binary | 0x90000000 | 0x3A000 | (map) | 25-27 |
| gsa | 0x90200000 | 0x400000 | no-map | 29-31 |
| tpu_ctx | 0x91E00000 | 0x1200000 | no-map | 34-36 |
| tpu_fw | 0x93000000 | 0x1000000 | no-map | 39-41 |
| aoc | 0x94000000 | 0x3000000 | no-map | 44-46 |
| xhci_dma (Google USB offload pool) | 0x97000000 | 0x400000 | no-map | `gs101-dma-heap.dtsi:162-166` |
| gxp_fw / scratchpad | 0x98000000 / 0x98400000 | 0x400000 / 0x100000 | no-map | 49-56 |
| seclog | 0xC3000000 | per `exynos-seclog.h:19-21` | | 157-160 |
| DSS (debug-snapshot) | 0xD8100000 | ~0x5F20000 total (hdr 64K, kevents 7M, s2d 24M, arrayreset 10M, arraypanic 10M, slcdump 17M, preslcdump 17M, bcm 4M, itmon 64K, s2d-extract 6M) | no-map | 96-160; `GM/soc/gs/include/dt-bindings/soc/google/debug-snapshot-def.h:16-36` |
| cp_rmem_1 / cp_rmem / cp_msi | 0xE8000000 / 0xEA400000 / 0xF6200000 | 0x2000000 / 0x800000 / 0x1000 | | 72-88 |
| **abl** | 0xF8800000 | 0x2000000 | no-map | 59-61 |
| **framebuffer (bootloader splash)** | **0xFAC00000** [I] | 1440·3120·4 = **0x1123000** | no-map | see below |
| dss_log / debug_kinfo / ramoops | 0xFD3F0000 / 0xFD3FE000 / 0xFD3FF000 | 0xE000 / 0x1000 / 0x400000 | no-map / ramoops | 64-83 |
| bldr_log | 0xFD800000 | 0x100000 | no-map | 86-89 |
| suspend_diag | 0xFD90C000 | 0x1000 | no-map | 74-76 |

**Display framebuffer.** Google's DTS has **no** splash node. `drmdecon0@1C240000` (`GD/gs201/dts/gs201-drm-dpu.dtsi:263`) has no `memory-region`, but the DPU driver hands over a bootloader FB through `memory-region` (`GM/display/samsung/exynos_drm_fb.c:550-573`). So **ABL injects the FB carve-out at boot**.

- Best evidence for the address: upstream Pixel 6 Pro (gs101, the same ABL family and the same 1440x3120 panel class) uses `splash@fac00000`, size `1440*3120*4`, `stride 1440*4`, `format "a8r8g8b8"` (`M/arch/arm64/boot/dts/exynos/google/gs101-raven.dts:36-48`, `gs101-pixel-common.dtsi:28-35,98-104`).
- gs201 keeps the identical `abl@f8800000` placement, so 0xFAC00000 sits right after it.
- Panel: ABL reports `exynos_drm.panel_name=sdc-s6e3hc4` (`R/cmdline.txt`). Native mode is 1440x3120 (`R/dumpsys-display.txt`, `mStableDisplaySize=Point(1440, 3120)`).
- **[I] Verify on device:** on first boot read the ABL-injected node from `/sys/firmware/fdt`. Also check whether ABL leaves 1440x3120 or 1080x2340 at handoff (wrong stride shows as a sheared image).

---

## 3. Per-block map (gs201 facts → upstream gs101 → reuse verdict)

GIC SPI numbers come from `GM/soc/gs/include/dt-bindings/interrupt-controller/gs201.h`. **They differ from gs101**, so never copy gs101 IRQ numbers.

| Block | gs201 (Google DTS) | Upstream gs101 node / driver | Verdict |
|-------|--------------------|------------------------------|---------|
| **CPUs** | 4x A55 (0xd05) @0x000-0x300, 2x **A78** (0xd41) @0x400/0x500, 2x X1 (0xd44) @0x600/0x700; one DSU cluster; capacity 250/927/1024. Google uses `#address-cells=<2>` (`GD/gs201/dts/gs201-cpu.dtsi:13-121`, `R/cpuinfo.txt`) | `M/.../gs101.dtsi:77-170` (A55/A76/X1) | Write fresh. Mid cores are A78, not A76 |
| **PSCI / idle** | `arm,psci-1.0`, smc; idle param 0x0010000 (`gs201-cpu.dtsi:125-163`) | same | Reuse as is |
| **GIC** | GICv3, GICD 0x10400000/0x10000, GICR 0x10440000/0x100000, PPI 9 (`gs201.dtsi:91-98`) | identical (`gs101.dtsi:658-680`) | Reuse |
| **Arch timer** | PPI 13/14/11/10 low; `clock-frequency=24576000` (`gs201.dtsi:100-107`) | same, no clock-frequency | Reuse. Add `clock-frequency` only if CNTFRQ is unset |
| **MCT** | 0x10050000, SPI 785-796 (`gs201.dtsi:144-170`) | `google,gs101-mct` (`gs101.dtsi:603-621`) | Reuse driver. Needs a cmu_misc clock, so leave it out of M1 (arch timer is enough) |
| **CMU** | Google uses **one** CAL-based provider `samsung,gs201-clock` @0x1e080000 (`gs201.dtsi:524-529`) with IDs like `GATE_USB31DRD_SLV_LINK`, `MUX_HSI0_USB20_REF` (`GM/soc/gs/include/dt-bindings/clock/gs201.h:105,113,148,151,252`). Real CMU bases: TOP 0x1e080000, HSI0 0x11000000, HSI2 0x14400000, PERIC0 0x10800000, PERIC1 0x10c00000, MISC 0x10010000, **APM 0x18000000** (`GM/soc/gs/drivers/soc/google/cal-if/gs201/cmucal-sfr.c:12-48`) | per-CMU `M/drivers/clk/samsung/clk-gs101.c` (4757 lines; compatibles at :4723-4738); APM at 0x17400000 | **New `clk-gs201.c` plus `dt-bindings/clock/google,gs201.h`.** Register maps diverge: shared/total SFR rows TOP 62/418, HSI0 20/121, HSI2 7/120, PERIC0 38/153, MISC 3/153. Example: USB REF_CLK_40 gate 0x2098 vs gs101 0x2078; UFS ACLK 0x20e8 vs 0x20d0 (`cmucal-sfr.c:1829,1948` vs `gs101/cmucal-sfr.c:1268,1373`). Source data: `cal-if/gs201/cmucal-{sfr,node,vclk}.c`, `GM/soc/gs/drivers/clk/gs/clk-gs201.c`. **M1 shortcut:** no CMU nodes, fixed-clock placeholders, `clk_ignore_unused` (stock uses it too, `gs201.dtsi:81`) |
| **Pinctrl** | 9 controllers: ALIVE **0x180d0000**, FAR_ALIVE **0x180e0000**, GSACORE 0x17a80000, GSACTRL 0x17940000, PERIC0 0x10840000 (SPI 664), PERIC1 0x10c40000 (SPI 683), HSI1 0x11840000 (SPI 387), HSI2 0x14440000 (SPI 421), **HSI2UFS 0x14460000** (SPI 422) (`gs201.dtsi:212-375`). Banks: `GM/soc/gs/drivers/pinctrl/gs/pinctrl-gs201.c:73-155` | `google,gs101-pinctrl` (`M/drivers/pinctrl/samsung/pinctrl-exynos-arm64.c:2094-2233`, match `pinctrl-samsung.c:1489`); ALIVE at 0x174d0000 | **New `gs201_pin_ctrl` data plus compatible** (bank differences: gpa2 has 4 pins vs 5, other fltcon offsets, extra HSI2UFS controller). Same driver code |
| **USI/UART** | `serial_0` 0x10A00000, SPI **673**, pins `gpp1-2/3` (`gs201.dtsi:195-208`, `gs201-pinctrl.dtsi:484-486`). Retail cheetah exposes it only on the USB-C SBU debug path (`tcpci_max77759.conf_sbu=0` in `R/cmdline.txt`) | `google,gs101-uart` in `usi_uart` (`gs101.dtsi:1179-1205`, SPI 634) | Reuse driver with the gs201 IRQ. **Not needed for M1** (no cable). Maybe use `earlycon` later |
| **PMU / syscon** | 0x18060000 (`gs201.dtsi:496-499`, compat `samsung,gs101-pmu`); intr-gen **0x18070000** (`GM/.../cal-if/gs201/flexpmu_cal_cpu_gs201.h:20`). PHY-isolation offsets USB 0x3EB0/0x3EB4, UFS 0x3EC8 (`gs201.dtsi` phy node, `gs201-ufs.dtsi:87-90`) | `google,gs101-pmu` 0x17460000 (`gs101.dtsi:1804-1833`, `M/drivers/soc/samsung/gs101-pmu.c:325`); same offsets (`M/include/linux/soc/samsung/exynos-regs-pmu.h:1003-1009`) | Reuse gs101 PMU data (SMC regmap) with a new compatible. CPU on/off offsets match (`flexpmu_cal_cpu_gs201.h` vs gs101) |
| **Reboot / poweroff** | `google,pixel-reboot`, reboot reason → PMU `SYSIP_DAT0` 0x810 via SMC (`GM/power/reset/pixel-gs201-reboot.c:24,50-55,165-167`; `gs201.dtsi:507-512`); PS_HOLD at PMU+0x3e9c (`gs201-debug.dtsi:74`) | `google,gs101-reboot` (SWRESET @0x3a00) plus `syscon-reboot-mode` @0x810 plus `syscon-poweroff` 0x3e9c bit 8 (`gs101.dtsi:1809-1832`; `M/drivers/power/reset/syscon-reboot.c:125-148`) | Reuse the same nodes under the gs201 PMU. PSCI `SYSTEM_RESET` works with no node at all |
| **Watchdog** | cl0 0x10060000 SPI 797, cl1 0x10070000 SPI 798, src OSCCLK plus `GATE_WDT_CL0/1` (`gs201.dtsi:1672-1693`). Google driver data for gs201 is byte-for-byte the gs101 data (`GM/soc/gs/drivers/watchdog/s3c2410_wdt.c:317-354,416-423`) | `google,gs101-wdt` (`M/drivers/watchdog/s3c2410_wdt.c:321-375`) | Reuse with `"google,gs201-wdt","google,gs101-wdt"`. Needs the cmu_misc gate, so post-M1 |
| **ACPM / PMIC** | ACPM: AP2APM mailbox **0x18210000**, APM SRAM **0x18500000/0x48000**, initdata 0xA000, SPI 78 (`gs201.dtsi:556-575`). PMICs: **S2MPG12** (main) / **S2MPG13** (sub), ACPM channel 2 (`gs201-pmic.dtsi:39-44,707-720`) | `google,gs101-acpm-ipc` (`M/drivers/firmware/samsung/exynos-acpm.c:42,879-887`, initdata 0xa000), mailbox `google,gs101-mbox` (`M/drivers/mailbox/exynos-mailbox.c:75,132`); gs101 used 0x17610000/0x2039000 (`GD/gs101/dts/gs101.dtsi:505-507`). MFD supports s2mpg10/11 only (`M/drivers/mfd/sec-acpm.c:15-16`) | ACPM and mailbox: likely reuse with a new compatible. **S2MPG12/13: new MFD and regulator data.** **Not needed for M1**: regulators stay on from the bootloader, so use `regulator-fixed` placeholders |
| **USB DRD (dwc3)** | Link **0x11210000**/0x10000, SPI **379**; Google glue `samsung,exynos9-dwusb`, `dr_mode="peripheral"` on pantah (`gs201.dtsi:722-764`, `gs201-common.dtsi` `&udc`). Clocks `GATE_USB31DRD_SLV_LINK`, `MUX_HSI0_USB20_REF`; PD `pd_hsi0` | `google,gs101-dwusb3` @0x11110000 (`gs101.dtsi:1685-1712`; `M/drivers/usb/dwc3/dwc3-exynos.c:184-220`), dwc3 SPI 463 | Reuse. For M1, use a bare `snps,dwc3` node (core clocks are optional) or glue with placeholder clocks |
| **USB PHY** | `usbdrd_phy0`: ctrl **0x11200000**/0x200, PMA **0x110F0000**/0x2800, PCS **0x11100000**/0x800 (reg order ctrl/pma/pcs/link per `GM/soc/gs/drivers/phy/samsung/phy-exynos-usbdrd.c:2215,2360-2383`); `phy_version 0x301`, `sub_phy_version 0x404`, PMU 0x3EB0/0x3EB4, **`phy_ref_clock = 19200000`**; SPI 376/374 (`gs201.dtsi:766-830`) | `google,gs101-usb31drd-phy` (`M/drivers/phy/samsung/phy-exynos5-usbdrd.c:1692-1770,2700-2881`). Google gs101 node: same versions 0x301/0x404 and PMU offsets, but bases 0x11100000/0x110E0000/0x110F0000 and **26 MHz** ref (`GD/gs101/dts/gs101.dtsi:671-705`) | **Reuse the driver with a new compatible.** The IP is the same and every block sits +0x100000. Differences: ref clock 19.2 vs 26 MHz (check the FSEL switch for 19.2) and maybe tuning. Without an `orientation-switch` property the driver forces VBUSVALID/BVALID (`phy-exynos5-usbdrd.c:1563-1571`), which is what gadget-only M1 needs. Use HS only (`maximum-speed="high-speed"`) to skip the USBDP SS lanes and orientation |
| **UFS** | HCI 0x14700000/0x200, VS 0x14701100, UniPro 0x14780000/0xa000, UFSP 0x14600000, PHY 0x14704000/0x3000, SPI **453**; sysreg HSI2 0x14420000; iso 0x3EC8; pins `gph3-0/1` on the HSI2UFS ctrl; VCC = gpio `gpp0-1` fixed regulator; **refclk 38.4 MHz** (`GD/gs201/dts/gs201-ufs.dtsi:12-117`, `gs201-pinctrl.dtsi:1183-1196`, `GM/soc/gs/drivers/ufs/gs201/ufs-cal.h:77`) | `google,gs101-ufs` / `google,gs101-ufs-phy` (`gs101.dtsi:1750-1787`; `M/drivers/ufs/host/ufs-exynos.c:2278-2314`; `M/drivers/phy/samsung/phy-gs101-ufs.c`), SPI 532 | Host: reuse with a new compatible. PHY: gs201 `init_cfg_evt1` = the 89 gs101 rows plus 4 extra (`GM/soc/gs/drivers/ufs/gs201/ufs-cal-if.c:200-323`), so add a small `tensor_gs201` table. **Needs cmu_hsi2 clocks**, so it waits for `clk-gs201.c` (stretch goal) |
| **chipid/OTP** | 0x10000000 (`gs201.dtsi:75-78`); product id 0x09855 | `google,gs101-otp`, table `{ "GS101", 0x9845000 }` (`M/drivers/soc/samsung/exynos-chipid.c:76,234-243`) | Add `"GS201", 0x9855000`. Cosmetic, post-M1 |

---

## 4. Proposed minimal DTS (M1)

This was written from scratch from the facts above. It assumes:

- new compatibles `google,gs201-pmu` and `google,gs201-usb31drd-phy`, added to the gs101 drivers;
- no clock driver yet: fixed-clock placeholders plus `clk_ignore_unused pd_ignore_unused`;
- build with `DTC_FLAGS += -@`.

### 4.1 `arch/arm64/boot/dts/exynos/google/gs201.dtsi`

```dts
// SPDX-License-Identifier: GPL-2.0-only
/*
 * Google GS201 (Tensor G2) SoC - minimal description for early bring-up.
 */

#include <dt-bindings/gpio/gpio.h>
#include <dt-bindings/interrupt-controller/arm-gic.h>

/ {
	compatible = "google,gs201";
	#address-cells = <2>;
	#size-cells = <1>;
	interrupt-parent = <&gic>;

	/* Required by the Pixel bootloader (ABL). */
	ect { };

	/* Target of the ABL-applied debug-policy (dpm partition) overlay. */
	dpm: dpm { };

	cpus {
		#address-cells = <1>;
		#size-cells = <0>;

		cpu-map {
			cluster0 {
				core0 { cpu = <&cpu0>; };
				core1 { cpu = <&cpu1>; };
				core2 { cpu = <&cpu2>; };
				core3 { cpu = <&cpu3>; };
				core4 { cpu = <&cpu4>; };
				core5 { cpu = <&cpu5>; };
				core6 { cpu = <&cpu6>; };
				core7 { cpu = <&cpu7>; };
			};
		};

		cpu0: cpu@0 {
			device_type = "cpu";
			compatible = "arm,cortex-a55";
			reg = <0x000>;
			enable-method = "psci";
			capacity-dmips-mhz = <250>;
		};
		cpu1: cpu@100 {
			device_type = "cpu";
			compatible = "arm,cortex-a55";
			reg = <0x100>;
			enable-method = "psci";
			capacity-dmips-mhz = <250>;
		};
		cpu2: cpu@200 {
			device_type = "cpu";
			compatible = "arm,cortex-a55";
			reg = <0x200>;
			enable-method = "psci";
			capacity-dmips-mhz = <250>;
		};
		cpu3: cpu@300 {
			device_type = "cpu";
			compatible = "arm,cortex-a55";
			reg = <0x300>;
			enable-method = "psci";
			capacity-dmips-mhz = <250>;
		};
		cpu4: cpu@400 {
			device_type = "cpu";
			compatible = "arm,cortex-a78";
			reg = <0x400>;
			enable-method = "psci";
			capacity-dmips-mhz = <927>;
		};
		cpu5: cpu@500 {
			device_type = "cpu";
			compatible = "arm,cortex-a78";
			reg = <0x500>;
			enable-method = "psci";
			capacity-dmips-mhz = <927>;
		};
		cpu6: cpu@600 {
			device_type = "cpu";
			compatible = "arm,cortex-x1";
			reg = <0x600>;
			enable-method = "psci";
			capacity-dmips-mhz = <1024>;
		};
		cpu7: cpu@700 {
			device_type = "cpu";
			compatible = "arm,cortex-x1";
			reg = <0x700>;
			enable-method = "psci";
			capacity-dmips-mhz = <1024>;
		};
	};

	psci {
		compatible = "arm,psci-1.0";
		method = "smc";
	};

	timer {
		compatible = "arm,armv8-timer";
		interrupts = <GIC_PPI 13 (GIC_CPU_MASK_SIMPLE(8) | IRQ_TYPE_LEVEL_LOW)>,
			     <GIC_PPI 14 (GIC_CPU_MASK_SIMPLE(8) | IRQ_TYPE_LEVEL_LOW)>,
			     <GIC_PPI 11 (GIC_CPU_MASK_SIMPLE(8) | IRQ_TYPE_LEVEL_LOW)>,
			     <GIC_PPI 10 (GIC_CPU_MASK_SIMPLE(8) | IRQ_TYPE_LEVEL_LOW)>;
	};

	oscclk: clock-oscclk {
		compatible = "fixed-clock";
		#clock-cells = <0>;
		clock-frequency = <24576000>;
		clock-output-names = "oscclk";
	};

	/*
	 * Bring-up placeholder: HSI0 clocks are left running by ABL (it does
	 * USB fastboot). Replace with cmu_hsi0 once clk-gs201 exists.
	 */
	usb_ref_clk: clock-usb-ref {
		compatible = "fixed-clock";
		#clock-cells = <0>;
		clock-frequency = <19200000>;	/* Google: phy_ref_clock */
		clock-output-names = "usb20-ref";
	};

	reserved-memory {
		#address-cells = <2>;
		#size-cells = <1>;
		ranges;

		gsa@90200000 { reg = <0x0 0x90200000 0x400000>; no-map; };
		tpu-ctx@91e00000 { reg = <0x0 0x91e00000 0x1200000>; no-map; };
		tpu-fw@93000000 { reg = <0x0 0x93000000 0x1000000>; no-map; };
		aoc@94000000 { reg = <0x0 0x94000000 0x3000000>; no-map; };
		gxp@98000000 { reg = <0x0 0x98000000 0x500000>; no-map; };
		dss@d8100000 { reg = <0x0 0xd8100000 0x5f20000>; no-map; };
		abl@f8800000 { reg = <0x0 0xf8800000 0x2000000>; no-map; };
		debug@fd3f0000 { reg = <0x0 0xfd3f0000 0x10000>; no-map; };
		bldr-log@fd800000 { reg = <0x0 0xfd800000 0x100000>; no-map; };
		suspend-diag@fd90c000 { reg = <0x0 0xfd90c000 0x1000>; no-map; };
	};

	/* Label stubs so the ABL "dpm" overlay applies (it only sets status). */
	dpm-stubs {
		log_arrdumppanic: log-arrdumppanic { status = "disabled"; };
		log_preslcdump: log-preslcdump { status = "disabled"; };
		log_slcdump: log-slcdump { status = "disabled"; };
	};

	soc: soc@0 {
		compatible = "simple-bus";
		#address-cells = <1>;
		#size-cells = <1>;
		ranges = <0x0 0x0 0x0 0x40000000>;

		gic: interrupt-controller@10400000 {
			compatible = "arm,gic-v3";
			#interrupt-cells = <3>;
			#address-cells = <0>;
			interrupt-controller;
			reg = <0x10400000 0x10000>,	/* GICD */
			      <0x10440000 0x100000>;	/* GICR x8 */
			interrupts = <GIC_PPI 9 IRQ_TYPE_LEVEL_HIGH>;
		};

		usbdrd31_phy: phy@11200000 {
			compatible = "google,gs201-usb31drd-phy";
			reg = <0x11200000 0x200>,
			      <0x11100000 0x800>,
			      <0x110f0000 0x2800>;
			reg-names = "phy", "pcs", "pma";
			/* placeholders until cmu_hsi0 exists */
			clocks = <&usb_ref_clk>, <&usb_ref_clk>, <&usb_ref_clk>,
				 <&usb_ref_clk>, <&usb_ref_clk>;
			clock-names = "phy", "ref", "ctrl_aclk", "ctrl_pclk",
				      "scl_pclk";
			samsung,pmu-syscon = <&pmu_system_controller>;
			#phy-cells = <1>;
			status = "disabled";
		};

		usb_dwc3: usb@11210000 {
			compatible = "snps,dwc3";
			reg = <0x11210000 0x10000>;
			interrupts = <GIC_SPI 379 IRQ_TYPE_LEVEL_HIGH>;
			phys = <&usbdrd31_phy 0>;
			phy-names = "usb2-phy";
			dr_mode = "peripheral";
			maximum-speed = "high-speed";
			snps,dis_u2_susphy_quirk;
			snps,dis_u3_susphy_quirk;
			snps,has-lpm-erratum;
			status = "disabled";
		};

		pmu_system_controller: system-controller@18060000 {
			compatible = "google,gs201-pmu", "syscon";
			reg = <0x18060000 0x10000>;
			google,pmu-intr-gen-syscon = <&pmu_intr_gen>;

			syscon-poweroff {
				compatible = "syscon-poweroff";
				offset = <0x3e9c>;	/* PAD_CTRL_PWR_HOLD */
				mask = <0x100>;
				value = <0x0>;
			};

			reboot-mode {
				compatible = "syscon-reboot-mode";
				offset = <0x0810>;	/* SYSIP_DAT0 */
				mode-bootloader = <0xfc>;
				mode-fastboot = <0xfa>;
				mode-recovery = <0xff>;
			};
		};

		pmu_intr_gen: syscon@18070000 {
			compatible = "google,gs201-pmu-intr-gen", "syscon";
			reg = <0x18070000 0x10000>;
		};
	};
};
```

### 4.2 `arch/arm64/boot/dts/exynos/google/gs201-cheetah.dts`

```dts
// SPDX-License-Identifier: GPL-2.0-only
/*
 * Google Pixel 7 Pro (cheetah) - M1 bring-up board file.
 */

/dts-v1/;

#include "gs201.dtsi"

/ {
	model = "Google Pixel 7 Pro";
	compatible = "google,gs201-cheetah", "google,gs201";

	/*
	 * ABL base-DTB match: (product id 0x09855000 | major rev). B0 = 1.
	 * Ship a second copy with 0x09855000 in the dtb section to be safe.
	 */
	soc_id = <0x09855001 0x0>;

	chosen {
		/* ABL requires bootargs to exist; it appends its own after these. */
		bootargs = "console=tty0 clk_ignore_unused pd_ignore_unused rdinit=/init";
		#address-cells = <2>;
		#size-cells = <1>;
		ranges;

		framebuffer0: framebuffer@fac00000 {
			compatible = "simple-framebuffer";
			memory-region = <&cont_splash_mem>;
			width = <1440>;
			height = <3120>;
			stride = <(1440 * 4)>;
			format = "a8r8g8b8";
		};
	};

	reserved-memory {
		#address-cells = <2>;
		#size-cells = <1>;
		ranges;

		/* [I] verify against the ABL-injected node in /sys/firmware/fdt */
		cont_splash_mem: splash@fac00000 {
			reg = <0x0 0xfac00000 (1440 * 3120 * 4)>;
			no-map;
		};
	};
};

&usbdrd31_phy {
	status = "okay";
};

&usb_dwc3 {
	status = "okay";
};
```

### 4.3 Minimal dtbo for ABL (`cheetah-m1-overlay.dts`)

```dts
// SPDX-License-Identifier: GPL-2.0-only
/dts-v1/;
/plugin/;

/ {
	board_id = <0x30306>;
	board_rev = <0x10000>;

	fragment@0 {
		target-path = "/";
		__overlay__ {
		};
	};
};
```

`mkdtimg create dtbo.img --page_size=4096 --id=/:board_id --rev=/:board_rev cheetah-m1-overlay.dtbo`

Images (`G/tools/mkbootimg/mkbootimg.py`):

- `boot.img`: `--header_version 4 --kernel Image.lz4`
- `vendor_kernel_boot.img`: `--header_version 4 --vendor_boot vkb.img --dtb dtb.img --vendor_ramdisk arch-initramfs.cpio.lz4` (`dtb.img` = `gs201-cheetah.dtb` with soc_id …00 concatenated with the copy with soc_id …01)
- `init_boot.img`: v4 with an empty cpio
- `vendor_boot.img`: empty vendor ramdisk plus `--vendor_cmdline ""`

Initramfs config: `CONFIG_USB_CONFIGFS_NCM`, `CONFIG_USB_DWC3_GADGET`, `CONFIG_FB_SIMPLE` / `CONFIG_DRM_SIMPLEDRM`, `CONFIG_BOOT_CONFIG`, `CONFIG_FRAMEBUFFER_CONSOLE`; dropbear and a configfs NCM gadget script in the initramfs.

---

## 5. M1 task list (in order)

1. **Capture ground truth first.** Use root on stock (Magisk or `adb root` on userdebug) or a throwaway boot to dump `/sys/firmware/fdt` and `/proc/iomem`. Look for the FB carve-out (address, size), `/memory`, and the ABL `chosen` fixups. Extract stock `vendor_boot` and `init_boot` from the factory image and run `unpack_bootimg` to check for a dtb section and the vendor cmdline.
2. Set up slot b: matching bootloader, then flash the M1 images to b and `set_active b`. Slot a stays stock as the recovery path.
3. Kernel patches (small):
   - `google,gs201-pmu` (+ intr-gen) → `gs101_pmu_data`
   - `google,gs201-usb31drd-phy` → gs101 PHY data, then check the 19.2 MHz refclk FSEL
   - add `"GS201", 0x9855000` to chipid
   - DT binding stubs for `google,gs201*`
4. DTS from §4 plus the dtbo from §4.3. Build `dtb.img` with both soc_id variants.
5. First boot target: **simplefb console** (proves ABL accepted the DTB, the memory map and the FB address). If the screen stays black, try a `ramoops`/`pstore` region at 0xfd3ff000 to read logs after a warm reset.
6. USB gadget NCM at high speed with dwc3 peripheral, then `ssh` over NCM.
7. Post-M1 / stretch:
   - `clk-gs201.c` (TOP, HSI0, HSI2, PERIC0, MISC) and the `google,gs201.h` clock bindings
   - gs201 pinctrl data
   - UFS host and PHY tables (refclk 38.4 MHz)
   - watchdog
   - ACPM and S2MPG12/13

## 6. Top risks

| Risk | Why | Mitigation |
|------|-----|------------|
| ABL DTB selection rejects our DTB | Matching on `soc_id` (`gs201-b0.dts:12-17`); fallback behaviour unknown | Include `soc_id`, ship both 0x…00 and 0x…01 copies. Keep `/ect` and `/chosen/bootargs` |
| ABL overlay application fails (dtbo or dpm) | Stock cheetah-mp.dtbo and the dpm overlay reference Google labels | Custom trivial dtbo (§4.3). Label stubs for dpm and `-@` symbols. Unknown whether ABL hard-fails or warns |
| Wrong FB address, size or stride | No node in Google's DTS; ABL injects it at runtime | Verify from `/sys/firmware/fdt` (task 1). The gs101-raven layout (0xfac00000, 1440x3120x4) is the prior |
| ABL turns HSI0/USB off before handoff | Then the fixed-clock or `clk_ignore_unused` shortcut fails (no gating driver to turn it back on) | Fallback: write a minimal `clk-gs201` HSI0 + TOP early. HSI0 PD control lives in the PMU, so the `exynos-pd` equivalent may also be needed |
| USB PHY init differences | gs201 ref 19.2 MHz vs gs101 26 MHz; tuning differs; SS combo PHY orientation | HS-only gadget, no `orientation-switch`, so VBUS is forced valid (`phy-exynos5-usbdrd.c:1563-1571`) |
| Missing PHY regulators | gs101 driver wants 6 supplies (`phy-exynos5-usbdrd.c:2858-2861`) that come from S2MPG12/13 (no driver) | Dummy regulators. ABL leaves the rails on |
| Initramfs override or bootconfig trailer | The init_boot ramdisk overrides ours; the bootconfig trailer is appended | Empty init_boot; `CONFIG_BOOT_CONFIG=y` |
| Watchdog left armed by ABL | Stock kernel drives the CL0/CL1 WDT (30 s) | If resets come at ~30 s intervals, port the gs101 wdt early (needs a cmu_misc gate) |
| pKVM / `kvm-arm.mode=protected` | Comes from the stock vendor_boot cmdline; ABL appends `id_aa64mmfr1.vh=0` | Our own vendor_boot cmdline (empty) |
