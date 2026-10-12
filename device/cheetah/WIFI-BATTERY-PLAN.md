<!-- SPDX-License-Identifier: MIT -->
# Wi-Fi, Bluetooth and battery plan (cheetah / gs201)

Status: W0/B0 (offline prep) done, see "G0 status". B1 done on the phone.
PCIe drivers for Wi-Fi (W0b) built offline (section 7). **W1 hung the phone
twice on 2026-10-11; the cause is found and fixed offline, and W1.3 now runs
in stages with a log capture tool: see section 8, which replaces the W1.3
step of 7.5.** Written 2026-10-11 against `omandroid` @ `0e73f9013`
(Linux 7.3-rc6), kernel branch `omandroid-wifi` in `wt-wifi`; PCIe work in
`omandroid-pcie` (`wt-pcie`).

Goal: Wi-Fi through mainline brcmfmac, Bluetooth through hci_bcm, and battery
level plus charging through the upstream MAX77759 drivers, each with Google's
own firmware files taken from the user's factory image.

Path abbreviations:

- `L/` = `/home/raven/android/mainline/wt-wifi` (our kernel, this branch)
- `G/` = `/home/raven/android/omandroid/out-kernel/google/gs-6.1/private`
- `GS/` = `G/google-modules/soc/gs`
- `W/` = `G/google-modules/wlan/bcm4389` (Google's bcmdhd for this chip)
- `R/` = `/home/raven/android/reference/cheetah-stock-cp2a-root` (stock live DT, logs)
- `R0/` = `/home/raven/android/reference/cheetah-stock-cp2a`

---

## 1. Wi-Fi: the PCIe path

### 1.1 Which controller

The BCM4389 sits on **`pcie_1` at `0x14520000`**, the 1-lane Gen2 controller
in the HSI2 block (Google calls it GEN4A_1, `ch-num = 1`). The other
controller, `pcie_0` in HSI1 (`0x11920000`), carries the Exynos 5300 modem.
Stock: "exynos-pcie-rc 11920000.pcie: wlan gpio is not defined -> don't use
wifi through pcie#0" (`R/dmesg.txt:1994`).

| Item | Value | Evidence |
|---|---|---|
| ELBI (Samsung glue) | `0x14520000` / `0x2000` | `R/live.dts:12107-12111` |
| UDBG | `0x14560000` / `0xd000` | same |
| PHY (PMA) | `0x14550000` / `0x2000` | same |
| PCS | `0x14540000` / `0x1000` | same |
| SYSREG_HSI2 | `0x14420000` (IOCC bits at +0x730) | same; `GS/drivers/pci/controller/dwc/pcie-exynos-rc.h:240-245` |
| DBI (DesignWare, iATU unrolled at +0x300000) | `0x14800000` / `0x301000` | same |
| Config space | `0x60ffe000` / `0x2000` | same |
| IA (link-training sequencer) | `0x14500000` / `0x1000` | same |
| MEM window | PCI `0x60000000` -> CPU `0x60000000`, `0xff0000` | `R/live.dts:12121` |
| IRQ | GIC SPI **428** (`0x1ac`), level. Wi-Fi uses **INTx** (`use-msi = "false"`); `interrupt-map` sends INTx to SPI 428. SPIs 429-433 are the unused MSI lines | `R/live.dts:12112-12115,12131`; `R/interrupts.txt:243` ("exynos-pcie, dhdpcie") |
| Link | 1 lane, Gen2 max | `R/live.dts:12123,12138` |
| DW IP version | `0x984500` | `R/live.dts:12122` |
| Coherency | `dma-coherent`, `use-cache-coherency` | `R/live.dts:12128,12145` |
| PHY isolation | PMU `0x18060000 + 0x3ec4` (secure: goes through SMC; our gs201 PMU regmap already does that) | `R/live.dts:12136`; `GS/.../pcie-exynos-rc.c:393-407`; `L/drivers/soc/samsung/exynos-pmu.c:105-128` |
| Supplies | vreg1 0.85 V = S2MPG13 LDO3 "L3S_PCIE1", vreg2 1.8 V = S2MPG13 LDO18 "L18S_PCIE1", both `regulator-always-on` | `R/live.dts:12143-12144`; `G/devices/google/gs201/dts/gs201-common.dtsi:345-376` |
| Clocks | none in the DT (`pcie-clk-num = <0>`, `phy-clk-num = <0>`): the CMU_HSI2 gates run on automatic gating | `R/live.dts:12125-12126`; `GS/.../pcie-exynos-rc.c:2388-2425` |
| Power domain | none: `pd_hsi2` is disabled in stock, HSI2 is never power-gated (UFS lives there) | `R/live.dts:7285-7294` |

### 1.2 Pins

All on the HSI2 pin controller **`pinctrl@14440000`** (stock `pinctrl_7`,
alias `pinctrl7`, GIC SPI 421) except the host-wake line.

| Signal | Pin | Config | Evidence |
|---|---|---|---|
| PERST# | `gph2-0` | output | `R/live.dts:3480-3497` |
| CLKREQ# | `gph2-1` | function 2 | same |
| WL_REG_ON | `gph2-4` | output, no pull; Google drives it high, then waits 200 ms | `G/devices/google/gs201/dts/gs201-cloudripper-wlan.dtsi:25-33,51`; `W/dhd_custom_google.c:515-590`; `R/dmesg.txt:5171` |
| WL_DEV_WAKE | `gph2-5` | input, pull-down | `gs201-cloudripper-wlan.dtsi:34-42,53` |
| WL_HOST_WAKE (OOB) | `gpa6-1` (FAR_ALIVE, SPI 45) | EINT, pull-down | `gs201-cloudripper-wlan.dtsi:14-23,52`; `R/interrupts.txt:333` |

`L/drivers/pinctrl/samsung/pinctrl-exynos-arm64.c:2271-2275` already has the
gs201 HSI2 banks (`gph2` 6 pins, `gph4`); only the DT node is missing.

### 1.3 Handoff state: the link is down

ABL does not train the link. Google's driver probes `pcie_1` with nothing on
the bus and powers the PHY down at the end of probe
(`exynos_pcie_rc_resumed_phydown()`, `GS/.../pcie-exynos-rc.c:5712`;
`R/dmesg.txt:2059-2126`). When bcmdhd asks for the card it raises WL_REG_ON
(3.571 s), runs the full PHY table and LTSSM, reaches L0 at 3.809 s
(`R/dmesg.txt:5171,5424-5425`), and `0001:01:00.0 [14e4:4441]` enumerates at
3.817 s. So **we need the whole PHY init ourselves**. On the plus side the
HSI2 block is powered and clocked at handoff (DBI reads work at stock probe
with no clocks enabled, and our UFS driver already runs in HSI2).

### 1.4 What mainline has, and what a gs201 port needs

- `L/drivers/pci/controller/dwc/pci-exynos.c` supports only
  `samsung,exynos5433-pcie` (line 379). Its ELBI layout differs (LTSSM enable
  at 0x02c, link-up at 0x074 bit 4; lines 27-51) from Google's (LTSSM enable
  at **0x054**, link state at **0x2c8 & 0x3f == 0x11**).
- `L/drivers/phy/samsung/phy-exynos-pcie.c` supports only
  `samsung,exynos5433-pcie-phy` (line 138).
- No FSD, ExynosAuto v9, gs101 or gs201 PCIe support anywhere in our tree or
  in pmOS (`pmos-tensor` only has the gs101 PCIe regulators,
  `gs101-pixel-common.dtsi:359-377`). gs101 has no PCIe node upstream either.
- Clocks: `clk-gs201.c` has CMU_HSI2 with every PCIe gate (IDs 3, 9-10,
  13-18, 27-39, 44-47, 55, 57-64 in `L/include/dt-bindings/clock/google,gs201.h`;
  driver `hsi2_cmu_info` at `clk-gs201.c:3104`). CMU_HSI1 (the modem's PCIe)
  has no driver, which we don't need.

Port, in order:

1. **PHY driver** (`phy-exynos-pcie.c` variant `google,gs201-pcie-phy`):
   the ~200-write table of `GS/drivers/pci/controller/dwc/pcie-exynos-gs201-rc-cal.c:99-339`
   ("CAL ver 210802": PHY reset through ELBI 0x1400/0x1404/0x1408, common PMA,
   38.4 MHz refclk block, per-lane tables at +0x800 stride, PCS 0x004/0x150/
   0x154/0x170/0x190, reset release, XO config at 0x5d0), plus the
   power-down helpers at `:36-88` and the PMU isolation bit at 0x3ec4.
   gs101's table differs only in the 38.4 MHz block, some RX tuning and the
   power-down details, so one driver can cover both.
2. **Controller glue** (new `pcie-google.c` or a variant table in
   `pci-exynos.c`, ~300-400 lines): PERST GPIO, LTSSM at ELBI 0x054, link
   poll at 0x2c8, INTx demux from ELBI IRQ0/IRQ2 (0x0/0x8, enables
   0x10/0x18), SYSREG IOCC bits, UDBG 0x421 at +0xc800 for ch1, DBI 0x890
   "EQ off" write; follow `exynos_pcie_rc_establish_link`
   (`GS/.../pcie-exynos-rc.c:3551-3680`). The IA CDR-lock sequencer
   (`:2966-3068`), L1SS and the vendor SysMMU can wait.
3. **DT:** HSI2 pinctrl node, `pcie_1` + PHY nodes, a `wifi@0,0` child with
   `compatible = "pci14e4,4441"` and `brcm,board-type`, WL_REG_ON as a fixed
   regulator (`vpcie3v3`-style) or via `pwrseq`, and the two S2MPG13 LDOs as
   fixed always-on regulators until there is an S2MPG13 driver (stock keeps
   them always on, `R/live.dts:13494-13519,14013-14182`).

The sketch for step 3 is in section 1.7. It is deliberately **not** in the
kernel branch: without a binding and a driver, the compatible strings and
`reg-names` would be guesses that churn.

### 1.5 The DMA firewall (S2MPU) and what it means

Each gs201 bus has an S2MPU (stage-2 memory protection unit) in front of its
DMA masters. The HSI2 one covers the Wi-Fi chip (and UFS):

| Node | Address | IRQ | Notes |
|---|---|---|---|
| `s2mpu_hsi2` | `0x145e0000` | SPI 448 | `always-on`, programmed by pKVM | 
| `sysmmu_hsi2` (`samsung,pcie-sysmmu`, "PCIe_CH1") | `0x145c0000` | SPI 446 | Samsung PCIe IOMMU, Google's own driver |

Evidence: `R/live.dts:9638-9644,12157-12169`; `R/iomem.txt:48`.

- **Stock programs the S2MPU from the hypervisor, not EL3.** The bootargs
  carry `kvm-arm.mode=protected kvm-arm.protected_modules=exynos-pd,pkvm_s2mpu`
  (`R/dmesg.txt:111`), and "pkvm-s2mpu 145e0000.s2mpu_hsi2: registered with
  hypervisor" (`R/dmesg.txt:461`). The EL2 code
  (`GS/drivers/soc/google/pkvm-s2mpu/common/hyp/s2mpu.c:448-472`) installs the
  host's memory map on resume and blocks everything on suspend. Google's EL1
  driver notes "Most S2MPUs are in an allow-all state at boot"
  (`GS/drivers/soc/google/pkvm-s2mpu/common/pkvm_s2mpu.c:360`).
- **On our boot it is off.** We don't run pKVM. `S2MPU_HSI0` reads `CTRL0 = 0`
  (disabled) on our kernel (NOTES.md, "lost USB"). UFS DMA, which goes through
  `s2mpu_hsi2`, already works under mainline, so HSI2 is not blocking either.
  To confirm at W1, read `0x145e0000` (`REG_NS_CTRL0`, bit 0 = enable;
  `GS/drivers/soc/google/pkvm-s2mpu/common/kvm_s2mpu.h:224,252`). That is a
  plain MMIO read in HSI2, not a PMU register. Do it with `tools/devmem`
  **only while UFS is up**, which it always is on our boot.
- **Stock also puts the Wi-Fi chip behind `sysmmu_hsi2`** ("PCIe SysMMU is
  ENABLED", `R/dmesg.txt:2075`), but only as a 1:1 identity map of each DMA
  buffer (`GS/.../pcie-exynos-rc.c:273-283,333-340,3924-3927`). The driver
  (`GS/drivers/iommu/exynos-pcie-iommu-whi.c`) is not upstream, and
  upstream `exynos-iommu.c` (SysMMU v1-v7) is a different block.
- **Security implication.** With no S2MPU and no IOMMU, the BCM4389 can DMA
  to **all of RAM**. Its firmware parses untrusted radio frames, and
  Broadcom Wi-Fi firmware has had remote code execution bugs before
  (Broadpwn, CVE-2017-9417; Project Zero's 2017 BCM4358 chain). A firmware
  compromise would then mean full kernel compromise, with no Android-style
  containment. That is acceptable for bring-up and for a developer phone. It is
  **not acceptable for a default-on Wi-Fi in an image we ship**. Before
  Wi-Fi is on by default, one of these must be done:
  1. Program `s2mpu_hsi2` from EL1 (no pKVM): give the Wi-Fi VID access only
     to a dedicated `restricted-dma-pool` (swiotlb) region that brcmfmac
     bounces through. This is the smallest change. The register layout is in
     `kvm_s2mpu.h`; Google's EL1 driver `GS/drivers/soc/google/s2mpu/s2mpu-core.c`
     shows how to program it without the hypervisor. Watch out: UFS shares
     this S2MPU, so the map needs UFS's buffers too (or per-VID maps).
  2. Port `sysmmu_hsi2` as a real IOMMU driver.
  3. Run pKVM with Google's S2MPU hyp module (large; not upstream).

  Option 1 with a restricted DMA pool on the `wifi@0,0` node is the
  recommended path (W4).

### 1.6 BCM4389 in brcmfmac

**Not supported upstream** before this branch: no 4389 chip or PCI ID in
`L/drivers/net/wireless/broadcom/brcm80211/` (only up to 4387, Apple's).
Our commit `wifi: brcmfmac: add BCM4389 PCIe support` adds it. Facts:

| Item | Value | Evidence |
|---|---|---|
| PCI ID | `14e4:4441` | `R/dmesg.txt:5461`; `W/include/bcmdevs.h:138` |
| Chip ID | `0x4389` | `W/include/bcmdevs.h:193`; `R/dmesg.txt:5466` |
| CPU | ARM Cortex-A7 in SYSMEM, RAM base **0x200000**, 2752512 bytes (21 x 128 KiB banks) | `W/dhd_pcie.c:2336-2349`; `W/include/sbchipc.h:4245`; `R/dmesg.txt:5467-5490` |
| PCIe core rev | 72 (brcmfmac's rev >= 64 register map, same as BCM4387) | `R/dmesg.txt:6988` ("buscorerev=72") |
| Random seed | 0xfeedc0de TLV before NVRAM (stock writes 128 bytes; brcmfmac writes 256 with the length in the footer) | `R/dmesg.txt:6987`; `W/include/bcmrand.h:50,63` |
| Signed firmware | no: `FW_SIGNATURE` is not set in Google's build | `W/Kbuild` (no match); `W/dhd_pcie.c:10192` |
| Firmware | `4389c1-roml/config_pcie_release2 Version=20.101.90`, FWID 01-3f632e0d | `strings fw_bcmdhd.bin`; `R/dmesg.txt:7138` |
| CLM | "Google.C10sub6" | `R/dmesg.txt:7171` |
| NVRAM | text, "bcm94389c1GGmodG2 C10", board-revision suffixes picked by `ro.revision` (MP1.0 has none, so plain `bcmdhd.cal`) | `bcmdhd.cal` header; `W/dhd_custom_google.c:255-330,440-510` |
| MAC address | from ABL: `/chosen/config/wlan_mac1` (and `bt_addr`); bcmdhd reads it there | `W/dhd_custom_google.c:140-141,182-235`; `R/live.dts:12664-12665` |

brcmfmac requests (board type = first root compatible, `/` replaced by `-`;
`L/.../brcmfmac/of.c:99-114`, `firmware.c:621-675`):

```
brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.bin       (then brcmfmac4389c1-pcie.bin)
brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.txt       (NVRAM, optional)
brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.clm_blob  (optional)
brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.txcap_blob (optional; Google has none)
```

Risks, to be settled at W2:

- **IPC version.** brcmfmac accepts shared-ring versions 5-7
  (`pcie.c:217-218`); Google's driver knows up to 9 (`W/include/bcmpcie.h:45-49`).
  If the firmware reports 8 or 9, probe fails with "Unsupported PCIE version".
  Then check what changed in 8/9 in `W/dhd_msgbuf.c` before widening the check.
- **D2H sync.** Stock logs "D2H sync mechanism is XORCSUM": the firmware
  checksums completions. brcmfmac doesn't verify them. That is harmless unless
  it reads a completion before the DMA finishes. Watch for corrupted messages.
- **Inband device wake** ("FW supports Inband dw ? Y", "ENABLING DW:2"): the host
  opts in, and brcmfmac doesn't. Expect no deep sleep, so more power use.
- **MAC address.** brcmfmac takes `local-mac-address` only from its own DT
  node, and ABL's `/chosen/config/wlan_mac1` isn't wired. Without it the
  firmware uses the OTP or NVRAM MAC, or a random one. Fix in userspace first: a
  udev/systemd-networkd `.link` from `/proc/device-tree/chosen/config/wlan_mac1`.
  Don't commit or print the value; it's a device identifier.
- **Chip revision.** The firmware entry matches all revisions as "4389c1". Read
  the real revision from brcmfmac's "chip BCM4389/N" line at W2 and narrow the
  mask.

### 1.7 DT (built, see section 7)

The sketch that was here is now real: `gs201.dtsi` has `pinctrl_hsi2`,
`pcie_1` and `pcie_1_phy`, and `gs201-cheetah.dts` wires WL_REG_ON, the
host-wake and dev-wake pins and the `wifi@0,0` node (section 7.2). Two
corrections to the sketch: the controller clocks are the x2 controller's
(`PCIE_003`), not `PCIE_004` (7.3), and WL_REG_ON hangs off a root port
node, where the PCI pwrctrl core finds it.

---
## 2. Firmware: where it is and how we get it

### 2.1 Files on the vendor partition

`/vendor/firmware` (`R/vendor-firmware.txt`; LineageOS lists them in
`device/google/pantah/cheetah/proprietary-files-vendor.txt:500-508`):

| Vendor file | Size | What | Mainline name we install |
|---|---|---|---|
| `fw_bcmdhd.bin` | 1764091 | Wi-Fi firmware, `4389c1-roml/config_pcie_release2`, 20.101.90 | `brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.bin` |
| `bcmdhd.cal` | 27237 | Wi-Fi NVRAM (text), board bcm94389c1GGmodG2 C10 | `brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.txt` |
| `bcmdhd_clm.blob` | 18348 | Regulatory (CLM) "Google.C10sub6" | `brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.clm_blob` |
| `brcm/BCM.hcd` | 478867 | Bluetooth patch "BCM4389C1 ES1PX_GG_C10" (selected by `persist.bluetooth.firmware.selection=BCM.hcd`, `device/google/pantah/cheetah/product.prop:14`) | `brcm/BCM.google,gs201-cheetah.hcd` |
| `bcmdhd.cal_{EVT,PROTO}*`, `brcm/BTFW_{B,D}.hcd`, `fw_bcmdhd.map` | | Pre-production boards, alternative BT builds, symbol map | not needed (our phone is `ro.revision=MP1.0`, `R0/getprop.txt`) |

Files go under `/usr/lib/firmware/updates/brcm/`. The firmware loader looks
there before linux-firmware's own files, and no package owns that directory.
Both drivers try the board-specific name first (`brcm_alt_fw_path()`,
`L/.../brcmfmac/firmware.c:621-675`; `btbcm_initialize()`,
`L/drivers/bluetooth/btbcm.c:651-667`), so a generic file from some
future linux-firmware can't shadow ours.

### 2.2 Extraction (done, offline): `tools/extract-vendor-firmware`

Pixel factory zips carry `vendor.img` directly. It is **not** inside a
`super.img`; the zip only has `super_empty.img`. In `cp2a.260705.006` it is a
**raw ext4** image (magic `0xef53` at 0x438, 841 MB), so `debugfs` reads it
without mounting or root. The script:

- takes the outer factory zip, the inner `image-cheetah-*.zip`, or a raw or
  sparse `vendor.img`;
- falls back to `lpunpack` for super-only images and to `fsck.erofs --extract`
  for EROFS vendors, so it keeps working if Google changes format;
- checks `android-info.txt` (`require board=...|cheetah|...`) and the vendor
  partition's own `ro.product.vendor.device=cheetah`;
- copies the four files under their mainline names, sanity-checks them
  (`4389c1-roml` tag, `BCM4389C1` patch, `NVRAMRev=` text NVRAM), and writes a
  sha256 list.

Verified on `image-cheetah-cp2a.260705.006.zip` (4.4 s), on the raw
`vendor.img`, and on an `img2simg` sparse copy. All three give identical
output:

```
c42039b351c9254a475a9eab8f090a2564901dd0aaca44c7412908ecd6929ff4  BCM.google,gs201-cheetah.hcd
8a52ffe1d71d29f3729247a31be912ff9e9b9959effa36fe94f2e3f5cccf916b  brcmfmac4389c1-pcie.google,gs201-cheetah.bin
adb2b2a28469c25fa196cffe0be4fb0ce29c250ec85b2ef3d4e9fa2db99771f8  brcmfmac4389c1-pcie.google,gs201-cheetah.clm_blob
a08c7df9e2ebc1522029825bd94e340d6cbed8ecdf002c02e1f6f808f60746a2  brcmfmac4389c1-pcie.google,gs201-cheetah.txt
```

Usage:

```sh
tools/extract-vendor-firmware -o out/vendor-firmware \
  ~/android/factory/cheetah-cp2a.260705.006/image-cheetah-cp2a.260705.006.zip
tar -C out/vendor-firmware -cf - usr | tools/phone-ssh 'tar -C / -xf -'
```

### 2.3 Licensing and redistribution

- These files are Broadcom/Google proprietary firmware. Google's factory images
  are offered for restoring Pixel devices, under Google's terms. They carry no
  redistribution licence like linux-firmware's `LICENCE.broadcom_bcm43xx`, and
  the NVRAM header even says `<<Broadcom-WL-IPTag/Proprietary:Vendor1007>>`.
- **So Omandroid never ships them:** not in git, not in a package, not in an
  image we publish. `*.img` and `*.zip` are already gitignored, and the script
  writes under `out/`, which is ignored too. The user extracts them on their own
  machine from the factory image of their own phone, as LineageOS's
  `extract-files.sh` does (it pulls the same paths from a device or image).
- An Arch package can depend on the *script* and run it at install time
  against a user-supplied zip (like `extract-files`). It must not contain the
  blobs.
- Never commit the MAC addresses ABL puts in `/chosen/config` (`wlan_mac1`,
  `bt_addr`): they identify the device.

---

## 3. Bluetooth

| Item | Value | Evidence |
|---|---|---|
| UART | **APM USI1 UART** = `serial_18` at **`0x181b0000`**, `/dev/ttySAC18`, GIC SPI **69**, FIFO 256, 32-bit registers | `R/live.dts:9369-9389`; vendor `etc/bluetooth/bt_vendor_overlay.conf` (`UartPort = /dev/ttySAC18`) |
| Clocks | CMU_APM (`0x18000000`): `DOUT_CLK_APM_USI1_UART` (div 0x1814), gates IPCLK 0x20ac, PCLK 0x20b0 | `GS/drivers/soc/google/cal-if/gs201/cmucal-sfr.c:188,644,1104-1111` |
| USI mode | sysreg_apm `0x18020000`, SW_CONF at +0x4e0, USI offset 4 (so `samsung,sysreg = <&sysreg_apm 0x4e4>`, to verify) | `R/live.dts:7669`; `G/devices/google/gs201/dts/gs201-usi.dtsi:78,1079-1103` |
| UART pins | `gpa3-0..3` (ALIVE), function 2 | `R/live.dts:2887-2912` |
| BT_REG_ON | `gpp16-2` (PERIC0 `pinctrl@10840000`), active high | `R/live.dts:4218,12683` |
| BT_DEV_WAKE | `gpp16-3`, active high | `R/live.dts:4228,12685` |
| HOST_WAKE | `gpa6-6` (FAR_ALIVE, SPI 50), both edges, active high | `R/live.dts:3119,12684`; `R/interrupts.txt` "bt_host_wake" |
| Stock driver | `goog,nitrous` child of the UART (LPM / power only); the HAL opens the tty itself | `R/live.dts:12679-12688` |

Mainline:

- `hci_bcm` + `btbcm` are the right drivers, and the GPIO names
  (`shutdown`, `device-wakeup`, `host-wakeup`) match. Our commit adds the
  `brcm,bcm4389-bt` compatible. With no LMP subversion entry, `btbcm` loads
  `brcm/BCM.google,gs201-cheetah.hcd` (`btbcm.c:661-667`). Add a subversion
  entry once the controller reports it (W-BT2 prints it).
- `hci_bcm` takes the host-wake polarity from the interrupt's trigger type
  (`L/drivers/bluetooth/hci_bcm.c:1233`), so the child node needs
  `interrupts-extended = <&gpa6 6 IRQ_TYPE_EDGE_RISING>` (active high, as
  nitrous). The operating speed comes from `max-speed`; the HAL's rate is not
  in our captures. Start at 115200 for the firmware download, then try
  3000000, the usual rate for this family.
- `samsung_tty` knows `google,gs101-uart` only (`samsung_tty.c:2646`).
  gs201 needs a compatible, but the IP is the same.
- **Missing:**
  - a CMU_APM clock driver (no APM IDs in `google,gs201.h`). This is the real
    blocker: the UART needs its baud clock rate;
  - a `sysreg_apm` node;
  - a PERIC0 pinctrl node (`pinctrl@10840000`, alias `pinctrl4`, SPI 664;
    the bank data exists at `pinctrl-exynos-arm64.c:2248-2269`);
  - the USI/UART node.

  Whether the APM UART has the `+0xc0` USI_CON wrapper like the PERIC USIs is
  unconfirmed: Google uses the older `usi-phandle`/`usi-offset` scheme for it.
- Shortcut for a first test: if ABL leaves the APM UART clock running, a
  `fixed-clock` with the stock rate would do. Read the rate first; it is not
  in our captures. The OS can't read CMU_APM without its own driver or devmem,
  and CMU_APM is an APM-owned block, so treat it like the PMU (no blind devmem).

---

## 4. Battery and charging: MAX77759

### 4.1 Wiring (cheetah)

All on **PERIC1 USI13 / HSI2C13** at `0x10d60000`, GIC SPI **695**, 400 kHz,
pins `gpp25-0/1` function 2 (`R/live.dts:4510-4517,8185-8205`;
`G/devices/google/gs201/dts/gs201-usi.dtsi:368-386`). Clocks are already in
`clk-gs201.c` (`CLK_GOUT_PERIC1_USI13_USI_{IPCLK,PCLK}`,
`L/include/dt-bindings/clock/google,gs201.h:598-599`).

| Addr | Function | IRQ | Evidence |
|---|---|---|---|
| 0x66 | MAX77759 core (+ MAXQ, same address) | `gpa9-4`, low | `R/live.dts:8273-8292,2995-3001` |
| 0x69 | charger (MFD cell, no DT node upstream) | shares `gpa9-4` | `R/live.dts:8354-8380`; `R/interrupts.txt` "max777x9_pmic, max77759_charger" |
| 0x36 | fuel gauge, the MAX77759's own "M5" gauge (no NVM, so no 0x0b) | `gpa9-3`, low | `R/live.dts:8295`; `R/dmesg.txt:1225-1230` |
| 0x25 | TCPCI | `gpa9-7`, low | `R/live.dts:8207-8215,2943-2949` |
| 0x57 | PCA9468 direct charger (separate chip, not needed) | `gpa9-0` | `G/devices/google/gs201/dts/gs201-cloudripper-battery.dtsi` |

`gpa9` is on ALIVE (`pinctrl@180d0000`). The ALIVE pinctrl node comes from
the buttons branch (`a3e96fceb`, cherry-picked here; it drops out on rebase).

Battery: 4926 mAh (`google,chg-battery-capacity`,
`G/devices/google/pantah/dts/gs201-cheetah-battery.dtsi:10`). Rsense 5 mΩ
(`maxim,rsense-default = <500>`). Stock float voltage is 4400 mV
(`R/live.dts:8354-8380`). Stock at capture time: 87 %, 4404 mV, 29.4 °C,
charging over USB at up to 3 A (`R0/dumpsys-battery.txt`).

### 4.2 Upstream drivers (all present in 7.3)

| Function | Driver | Binds by |
|---|---|---|
| core | `drivers/mfd/max77759.c` | `maxim,max77759` (checks PMIC_ID 0x3b; stock reports 0x3b rev 2) |
| GPIO | `drivers/gpio/gpio-max77759.c` | `gpio` subnode |
| NVMEM | `drivers/nvmem/max77759-nvmem.c` | `nvmem-0` subnode (left out: no reboot-mode use yet) |
| charger | `drivers/power/supply/max77759_charger.c` | MFD cell |
| fuel gauge | `drivers/power/supply/max17042_battery.c:1666` | `maxim,max77759-fg` |
| TCPCI | `drivers/usb/typec/tcpm/tcpci_maxim_core.c:588` | `maxim,max77759-tcpci` |

The upstream gs101 board (`L/arch/arm64/boot/dts/exynos/google/gs101-pixel-common.dtsi:645-850`)
is the template. We use the same nodes on hsi2c_13 with gs201's pins.

### 4.3 Gotchas found in the drivers

- **The charger turns charging off at probe.** `max77759_charger_init()`
  sets mode OFF and only turns it back on when a power supply named
  `tcpm-source` reports online (`max77759_charger.c:540-553,663`). Without
  TCPM, loading it **stops charging**. It also programs float voltage and
  fast-charge current from `monitored-battery`, or the defaults 4300 mV /
  2.27 A (`:27-28`). Those are conservative next to stock's 4400 mV, so safe.
  The MFD binding has no `monitored-battery` yet
  (`maxim,max77759.yaml`, `unevaluatedProperties: false`).
- **TCPCI owns the USB-C port.** Loading `tcpci_maxim` makes TCPM drive
  CC/VBUS. Today the USB PHY forces VBUS valid (NOTES.md, "USB doesn't
  reconnect"), and USB is our only link. So TCPCI comes last, with the
  role-switch/orientation wiring, and only with a recovery path ready.
- **The fuel gauge re-initialises only after a POR.** `max17042_probe()` runs
  the init worker only if STATUS bit 1 (POR) is set
  (`max17042_battery.c:1551`). Stock's driver ran first and cleared it, so
  probe should only read. Check that bit before loading anyway.
- **Capacity units.** Google's model has DesignCap 0x09c5 (2501) for a
  4926 mAh pack (`gs201-cheetah-battery-data.dtsi:63-83`), i.e. about 2 mAh/LSB.
  Upstream max17042 assumes 5 µVh/Rsense = 1 mAh/LSB at 5 mΩ. Expect
  `charge_full` to read about half the real value until this is understood.
  Compare with `R0/dumpsys-battery.txt` (charge counter 3982000 µAh at 87 %).
  **Resolved in B1b:** the model's TaskPeriod 0x2d00 doubles the LSB to 2 mAh,
  and upstream already scales by TaskPeriod.

---

## 5. Bring-up sequence with gates

Rules: everything new is a module, blacklisted from autoload where probing
changes hardware state (`device/cheetah/rootfs/etc/modprobe.d/omandroid-max77759.conf`).
It is loaded by hand over SSH while a second session runs `dmesg -w`.
`panic=10` and ABL's A/B fallback are the recovery path (NOTES.md).

### Gate B0 / W0: offline prep (done; see "G0 status")

### Gate B1: I2C and fuel gauge (low risk)

1. Boot the new DTB. **Pass:** USB/SSH, UFS and touch unchanged;
   `/sys/bus/i2c/devices/i2c-*/name` shows `10d60000.i2c`; the clients
   `*-0036` and `*-0066` exist but are unbound (blacklisted).
2. `i2cget -y <bus> 0x66 0x00` must return 0x3b (PMIC_ID). `i2cget -y <bus>
   0x36 0x00 w` reads STATUS; **stop if bit 1 (POR) is set**. Note the value.
3. `modprobe max17042_battery`. **Pass:** `/sys/class/power_supply/max77759-fg*`
   with sensible `capacity`, `voltage_now` (about 3.6-4.4 V) and `temp`.
   `current_now` changes sign when the cable is pulled.

### Gate B2: MFD core and GPIO (low risk)

`modprobe max77759` (the charger cell then tries to autoload, but is
blacklisted). **Pass:** `max77759` binds, `gpiochip` with 2 lines, and the
interrupt on gpa9-4 does not storm (`grep gpa9 /proc/interrupts` twice).

### Gate B3: charger (medium risk: charging stops)

Only with the battery above 50 %. Before loading, record the charger mode:
`i2cget -y <bus> 0x69 0xb9` (CHG_CNFG_00, mode in bits 3:0;
`L/include/linux/mfd/max77759.h:91-92`). Then `modprobe max77759_charger`.
**Expected:** `power_supply/max77759-charger` appears and **charging stops**
(no `tcpm-source`). This proves register access. After `rmmod`, the mode
register keeps OFF; write the recorded value back with `i2cset` (the mode
field is not write-protected, unlike the registers `unlock_prot_regs()`
guards), or boot stock, whose driver sets it again. Real charging needs B4.

### Gate B4: Type-C (high risk: USB link)

Needs the dwc3 role switch and USB PHY orientation wiring first (USB-C row of
the main plan), and a second way in (Wi-Fi, W3). Then enable
`usb-typec@25`, load `tcpci_maxim`, and check that `tcpm-source` goes
online and the charger switches to charge mode.

### Gate W1: PCIe controller (medium-high risk)

Runbook: section 8.4 (staged; 7.5 for W1.0-W1.2). **Pass:** "PCIe Gen.2 x1 link up" and
`lspci -nn` shows `01:00.0 Network controller [0280]: Broadcom ... [14e4:4441]`.
(0x4441 is the PCI device ID; 0x4389 is the chip ID that brcmfmac prints at
W2.) Never touch PMU 0x3ec4 from userspace (see the PMU warnings in
NOTES.md and GPU-PLAN.md); the PHY driver does it through the PMU regmap.

### Gate W2: brcmfmac (medium risk)

Runbook: section 7.6. **Expected:** "brcmfmac: brcmf_fw_alloc_request: using
brcm/brcmfmac4389c1-pcie for chip BCM4389/N", then the firmware version line
with 20.101.90 and the CLM version, `wlan0` in `iw dev`, and a scan that
lists networks. Note the chip rev N. **Failures:** "Unsupported PCIE
version" (see 1.6), FW-up timeout (seed/NVRAM placement), or a missing CLM
file (check the names).

### Gate W3: Wi-Fi works (low risk)

`iw dev`, set the MAC from `/proc/device-tree/chosen/config/wlan_mac1`,
NetworkManager scan and connect, then `iperf3`. Watch for
"XORCSUM"/sequence errors and firmware traps.

### Gate W4: DMA protection before default-on (required)

Program `s2mpu_hsi2` for the Wi-Fi VID to a restricted DMA pool (1.5). The
pool is already in the DT, disabled (`wifi_dma_pool`, 16 MiB); 7.7 shows how
to test brcmfmac through it before the S2MPU work. **Until W4 is done, Wi-Fi
must not ship enabled:** `pcie_1` stays `disabled` in the default DTB, and
`pcie_gs201` and `brcmfmac` stay blacklisted in `omandroid-device-cheetah`.

### Gates BT1-BT3

BT1: CMU_APM (gates + the UART divider), `sysreg_apm`, PERIC0 pinctrl, and
the APM UART node, with the UART alone and no BT child. Loopback test
first. BT2: add the `bluetooth` child, load `hci_uart`, and check that the
`BCM.*.hcd` download finishes and the subversion prints. BT3: `bluetoothctl`
scan/pair; LPM through `device-wakeup`/`host-wakeup`.

---

## 6. Effort and risks

| Step | Estimate | Risk |
|---|---|---|
| B1-B2 fuel gauge + MFD | 0.5 day | low |
| B3-B4 charging through TCPM | 2-4 days (needs the dwc3 role switch + PHY orientation) | high (USB link) |
| W1 PCIe PHY + controller drivers | 4-7 days | medium-high (SError if a register block is unclocked) |
| W2-W3 brcmfmac on BCM4389 | 1-3 days | medium (IPC version, sync mode) |
| W4 S2MPU restricted DMA | 2-4 days | medium (UFS shares the S2MPU) |
| BT1-BT3 CMU_APM + UART + hci_bcm | 3-5 days | medium (APM-owned CMU) |

Top risks:

1. **The PHY table has to be right first time.** If the link doesn't train,
   all we get is a timeout. Compare register dumps with Google's CAL step by
   step. HSI2 is powered, so reads are safe.
2. **brcmfmac vs. firmware IPC differences** (version 8/9, XORCSUM, inband
   DW). Fallback: port the specific pieces from Google's `dhd_msgbuf.c`.
3. **DMA from the Wi-Fi chip** is unrestricted until W4.
4. **Charging regressions:** the charger stops charging at probe (4.3).
   Never autoload it before B4.
5. **CMU_APM** belongs to the APM/ACPM firmware domain. Writing its gates
   from Linux may race with ACPM. Read-only first.

---

## G0 status (2026-10-11, offline; nothing was run on the phone)

### Kernel: `omandroid-wifi` in `wt-wifi`, on `omandroid` @ `0e73f9013`

| Commit | What | State |
|---|---|---|
| `6efec864b` wifi: brcmfmac: add BCM4389 PCIe support | chip/PCI IDs, CA7 RAM base 0x200000, firmware name `brcmfmac4389c1-pcie`, random seed | built; idle until W1 (no PCIe host) |
| `6b1fe828d` dt-bindings: net: wireless: brcm,bcm4329-fmac: add BCM4389 PCI ID | `pci14e4,4441` | `dt-doc-validate` ok |
| `aed2733f5` arm64: dts: exynos: google: gs201: add ALIVE pinctrl | **cherry-pick of `a3e96fceb` from `omandroid-buttons`**, needed for gpa9; it drops out when both land | as in buttons |
| `93dd7f5c2` dt-bindings: i2c: exynos5: add Google gs201 compatible | `google,gs201-hsi2c` | `dt-doc-validate` ok |
| `dab016aab` arm64: dts: exynos: google: gs201: add USI13 with its HSI2C | `usi13` + `hsi2c_13` (disabled in the SoC dtsi), `hsi2c13_bus` pins | |
| `f14275eb2` arm64: dts: exynos: google: gs201-cheetah: add the MAX77759 | USI13 in I2C mode, **okay**; `pmic@66` + `gpio`, `fuel-gauge@36` **okay**; `usb-typec@25` **disabled**; gpa9 IRQ pin configs | modules blacklisted (below) |
| `284a464ac` dt-bindings: net: bluetooth: brcm: add BCM4389 | `brcm,bcm4389-bt` | `dt-doc-validate` ok |
| `a79ca362f` Bluetooth: hci_bcm: add BCM4389 compatible | OF match only | built; idle until BT1 |

- Build: `logs/kernel-wifi.log`, `modules-wifi.log` and `images-wifi.log`
  all exit 0. Release `7.3.0-rc6-omandroid-push1-00041-ga79ca362f84d`;
  1680 modules; images in `~/android/mainline/out-wifi/images`.
- `dt-validate` (dtschema 2026.9) of `gs201-cheetah.dtb` against this tree's
  bindings reports only the existing `soc_id` property.
- The modules are there and carry the right aliases: `brcmfmac.ko` has
  `pci:v000014E4d00004441…` and the `brcmfmac4389c1-pcie` firmware names;
  `hci_uart.ko` has `of:…brcm,bcm4389-bt`; `max77759.ko`,
  `max77759_charger.ko`, `max17042_battery.ko`, `tcpci_maxim.ko` and
  `gpio-max77759.ko` exist.
- **Not in the branch, on purpose:** the PCIe controller, the PHY and the
  `pcie_1` node (no binding or driver yet; sketch in 1.7), and anything for the
  APM UART (no CMU_APM).

### omandroid repo

- `kernel/configs/omandroid.config`: `BRCMFMAC_PCIE=y`, `BRCMFMAC=m`,
  `BT_HCIUART(_BCM)`, `MFD_MAX77759`, `CHARGER_MAX77759`, `BATTERY_MAX17042`
  (the MAX77759 gauge driver; not MAX1720X).
- `device/cheetah/rootfs/etc/modprobe.d/omandroid-max77759.conf`: blacklists
  `max77759`, `max77759_charger`, `tcpci_maxim`, `max17042_battery`,
  `gpio_max77759` and `nvmem_max77759`.
- `tools/extract-vendor-firmware`: section 2.2.

### B1 runbook (phone in Arch over USB; run from the omandroid repo)

```sh
export KERNEL_OUT=$HOME/android/mainline/out-wifi
# 0. firmware for later (harmless now) and i2c-tools
tools/extract-vendor-firmware -o out/vendor-firmware \
  ~/android/factory/cheetah-cp2a.260705.006/image-cheetah-cp2a.260705.006.zip
tar -C out/vendor-firmware -cf - usr | tools/phone-ssh 'tar -C / -xf -'
tools/phone-ssh 'pacman -S --needed --noconfirm i2c-tools'
# 1. blacklist FIRST, so the new DTB cannot autoload the charger
tools/phone-ssh 'mkdir -p /etc/modprobe.d && cat > /etc/modprobe.d/omandroid-max77759.conf' \
  < device/cheetah/rootfs/etc/modprobe.d/omandroid-max77759.conf
# 2. modules, then the images into slot B, and reboot
bin/omandroid modules-push
bin/omandroid push
# 3. B0 pass check: unchanged USB/UFS/touch, the bus and unbound clients
tools/phone-ssh 'uname -r; lsmod | grep -cE "max77759|max17042|tcpci"; \
  ls -l /sys/bus/i2c/devices/ | grep 10d60000'   # i2c-BUS, BUS-0036, BUS-0066 (0x25 is disabled)
# 4. B1: read-only probes (BUS = the i2c number of 10d60000.i2c)
tools/phone-ssh 'i2cget -y BUS 0x66 0x00'        # expect 0x3b
tools/phone-ssh 'i2cget -y BUS 0x36 0x00 w'      # STATUS: stop if bit 1 (POR) is set
tools/phone-ssh 'i2cget -y BUS 0x69 0xb9'        # charger mode: write it down
# 5. fuel gauge (second terminal: tools/phone-ssh dmesg -w)
tools/phone-ssh modprobe max17042_battery
tools/phone-ssh 'grep . /sys/class/power_supply/*/{capacity,voltage_now,current_now,temp,charge_full}'
# 6. B2: core + GPIO; the charger cell stays unloaded (blacklisted)
tools/phone-ssh 'modprobe max77759 && modprobe gpio_max77759; grep gpa9 /proc/interrupts'
```

B3 (charger) and B4 (Type-C) follow section 5 and are **not** part of this
runbook.

### Open questions

- Does `hsi2c_13` work with our USI13 clocks as they are? The bus is clocked
  at handoff, since stock talks to it all the time, but this is the first
  HSI2C on gs201 under mainline. If step 3 shows timeouts, check
  `clk_summary` for `USI13`.
- The fuel gauge's capacity scale (4.3).
- The real BCM4389 chip revision and IPC version (W2).
- The APM UART clock rate and USI wrapper (BT1).
- Whether `s2mpu_hsi2` `CTRL0` reads 0 (W1, step 1).

## B1 result (2026-10-11, on the phone)

- Kernel `7.3.0-rc6-...-ga3061be71070` (`omandroid-wifi`, now merged into `omandroid`). USB, UFS, touch and the GPU unchanged.
- `10d60000.i2c` is `i2c-0`: the first gs201 HSI2C on mainline works with the clocks as they are. Clients `0-0036` and `0-0066` enumerate.
- `i2cget 0x66 0x00` = **0x3b** (PMIC_ID). Charger mode `0x69/0xb9` = 0x05.
- **Fuel gauge STATUS = 0x0082: the POR bit is set**, and DesignCap reads 3000 (the chip default; Google's model has 0x09c5). The gauge has lost Google's model and runs its own default EZ model. Read-only register dump: RepSOC 98 %, VCell 4.327 V, current about 0, Temp exactly 22.0 °C (probably a default; no thermistor configuration).
- Because our DT has no `monitored-battery`, `max17042_init_worker` writes nothing on POR (`max17042_battery.c:1187`: `enable_por_init` is only set by `max17042_apply_battery_properties`). So the driver was loaded: `max170xx_battery` reports capacity 97 %, 4.32 V, -7.8 mA, charge_full 2898 mAh of design 3000. Its interrupt (gpa9-3) stayed at 0, no storm. The fuel gauge now autoloads (removed from the blacklist); UPower and the status bar show the battery.
- Follow-ups: load Google's M5 model (`gs201-cheetah-battery-data.dtsi`) so capacity (4926 mAh) and temperature are right; check what Android's driver does when it next sees the gauge (it may reload its model on its own POR check); charger (B3) waits for Type-C (B4).


## B1b battery model (2026-10-11, offline; nothing was run on the phone)

Goal: right capacity and temperature from the MAX77759 gauge, by loading the
same ModelGauge m5 model that stock loads. Kernel branch `omandroid-battery`
in `/home/raven/android/mainline/wt-battery`, on `omandroid` @ `43918aeb7`;
build in `/home/raven/android/mainline/out-battery`.

### Why the B1 readings are wrong

- **Capacity.** After the POR the gauge runs its built-in EZ model:
  DesignCap 3000 and TaskPeriod 0x1680. Stock's model writes
  **TaskPeriod 0x2d00** (`G/devices/google/pantah/dts/gs201-cheetah-battery-data.dtsi:102`,
  the last fg-params word of the 1 kΩ model). This doubles the time base, so one capacity LSB is
  2 × 5 µVh / 5 mΩ = **2 mAh** (Google: `max_m5_period2caplsb()`, `cap_lsb=2` in
  `R/dmesg.txt:3295`). DesignCap 0x09c5 = 2501 LSB = **5002 mAh**. Google's
  model is rounded up a bit; their 4926 mAh is `google,chg-battery-capacity`.
  Upstream `max17042_battery.c` already scales every capacity by
  `TaskPeriod / 5760`, but it reads TaskPeriod only once, at probe. That
  settles the "2 mAh/LSB" question in 4.3.
- **Temperature.** At POR, Config has TEx set: the Temp register (0x08)
  holds a host-written value, 22.0 °C by default. Stock's Config 0x4217 clears
  TEx and sets TEn + ETHRM (external thermistor); TGain 0xed51, TOff 0x1eba
  and Curve 0x0014 convert AIN to °C (`max_m5_reg.h:396-411` for the Config
  bits). B1's exact 22.0 °C (0x1600) fits a TEx-mode register nobody writes.
- **`monitored-battery` alone would not help.** Upstream's POR init only
  applies `simple-battery` data for the MAX17055
  (`max17042_apply_battery_properties()` returns early for every other chip),
  and its legacy full-init path is the MAX17042 sequence, not the m5 one.

### The fix (kernel)

| Commit | What |
|---|---|
| `b83a53075` dt-bindings: power: supply: max17042: add MAX77759 battery model | `maxim,fg-model` (48 × u16, registers 0x80-0xaf) and `maxim,fg-params` (27 or 28 × u16, fixed order, Google's format); only for `maxim,max77759-fg`; each requires the other |
| `b26147fe2` power: supply: max17042_battery: load the MAX77759 battery model on POR | Only when the gauge reports POR and the DT has a model. Google's `max_m5_load_gauge_model()` order: wait FStat.DNR, refuse if Config2.LdMdl is set, unlock, write and verify the table, lock and verify (a locked table reads 0xffff), 500 ms, write the parameters (RepCap 0, RelaxCfg, extra-config unlock, VFSOC0, LearnCfg ... MiscCfg, AtRate, CV_MixCap = 75 % FullCapNom, CV_HalfTime 0x600, ConvgCfg, relock), Curve, FilterCfg, CGain, set Config2.LdMdl, poll until it clears and RepCap ≠ 0, check FullCapRep against FullCapNom (3 tries), re-read TaskPeriod, clear POR. On failure POR stays set (the next probe retries) and the driver keeps reporting from the default model |
| `50c4b244a` arm64: dts: exynos: google: gs201-cheetah: add the battery and its gauge model | `simple-battery` node (4926 mAh, 4.45 V max, 3.3 V min) as `monitored-battery`; the gauge model |

Model choice: stock reads a **1 kΩ battery ID** on this phone
(`R/dmesg.txt:3279`), so `maxim,cos-a1-1k` (model version 1), word for word as
in `R/live.dts:8337-8338`. Two words differ, on purpose: RelaxCfg 0x143b
(stock overwrites 0x0839 at every boot from `maxim,r_regval_1720x`) and
FilterCfg 0xc613 (stock switches to this above 10 °C, `filtercfg-default`).
We do **not** write the model version byte (TAlrtTh[15:8]); see the dual-boot
note. A different pack (ID 3, `lsn-a1-3k`) needs that model instead; Linux can't read the ID yet (stock gets it
through `gbms_storage` tag BRID, `max1720x_read_batt_id()`; the pack EEPROM
is `google,bee-name = "8-00500"` in `gs201-cheetah-battery.dtsi`).

Build: `logs/kernel-battery.log`, `modules-battery.log`, `images-battery.log`,
all exit 0. Release `7.3.0-rc6-omandroid-push1-00057-g50c4b244a706`, 1682 modules, images in `~/android/mainline/out-battery/images` (initramfs rebuilt there: `logs/initramfs-battery.log`). W=1 build of `max17042_battery.o` has no
warnings; `dt-validate` of `gs201-cheetah.dtb` (dtschema 2026.9) reports only the existing
`soc_id` and framebuffer `post-init-providers`; `dt-doc-validate` of the binding is clean.

### Expected registers after the load

Read with `i2cget -f -y 0 0x36 <reg> w` (the driver owns the address, so
`-f`; reads are harmless) or `cat /sys/kernel/debug/regmap/0-0036/registers`.

| Reg | Name | Before (B1) | Right after the load | Notes |
|---|---|---|---|---|
| 0x00 | Status | 0x0082 | bit 1 (POR) clear | other bits are alerts |
| 0x18 | DesignCap | 0x0bb8 (3000) | **0x09c5** | fixed |
| 0x3c | TaskPeriod | 0x1680 | **0x2d00** | fixed; doubles the LSB |
| 0x23 | FullCapNom | ? | 0x09c5 | learns afterwards |
| 0x35 | FullCapRep | ? | 0x09c5 ± 25 | learns; stock had 0x08f1 (4578 mAh) |
| 0x10 | FullCap | ~0x0b52 (2898) | about 0x09c5 | what `charge_full` reads |
| 0x1d | Config | ? | **0x4217** | TEx (bit 8) clear |
| 0xbb | Config2 | ? | 0x0090 | LdMdl (bit 5) clear |
| 0x2c / 0x2d | TGain / TOff | ? | **0xed51 / 0x1eba** | fixed |
| 0xb9 | Curve | ? | 0x0014 | fixed |
| 0x28 | LearnCfg | ? | 0x260e | the gauge changes the learn stage; stock read 0x247e |
| 0x2a / 0x29 | RelaxCfg / FilterCfg | ? | 0x143b / 0xc613 | fixed |
| 0x38 / 0x39 | RComp0 / TempCo | ? | 0x0770 / 0x2202 | learn; stock read 0x0965 / 0x2602 |
| 0x02 | TAlrtTh | ? | unchanged (0x7f80 after POR) | we don't write a version |
| 0x08 | Temp | 0x1600 (22.0 °C) | room/body temperature, moving | LSB 1/256 °C |

There is no ModelCfg (0xdb) on the m5 gauge; Config2.LdMdl is its
counterpart.

### Runbook (phone in Arch over USB; each step has its rollback)

```sh
export KERNEL_OUT=$HOME/android/mainline/out-battery
# B1b.0  read-only dump, current kernel. Keep the output.
tools/phone-ssh 'for r in 00 18 3c 23 35 10 1d bb 2c 2d b9 28 2a 29 38 39 02 08 27 17 3d; do
  printf "%s=%s\n" $r $(i2cget -f -y 0 0x36 0x$r w); done'
tools/phone-ssh 'grep . /sys/class/power_supply/max170xx_battery/{capacity,charge_full,charge_full_design,temp,voltage_now,current_now}'
#   gate: 0x00 has bit 1 set (POR). If it does NOT (Android ran since B1 and
#   loaded its own model), check 0x18=0x09c5 and 0x3c=0x2d00: then the gauge
#   already has the right model and the new kernel will leave it alone. Skip to B1b.3.
# B1b.1  new kernel + DTB (slot B), modules first
bin/omandroid modules-push
bin/omandroid push          # reboots into slot B
# B1b.2  the load happens at probe (max17042_battery autoloads). Watch for:
tools/phone-ssh 'dmesg | grep -i -E "max17042|max170xx|battery model"'
#   pass: "battery model loaded (DesignCap 0x9c5, TaskPeriod 0x2d00)", no
#         "model load failed", no "FullCapRep differs"
# B1b.3  the register dump again (same command as B1b.0): compare with the table above
# B1b.4  sysfs
tools/phone-ssh 'grep . /sys/class/power_supply/max170xx_battery/{capacity,charge_full,charge_full_design,temp,voltage_now,current_now,cycle_count}'
#   pass: charge_full_design 5002000; charge_full about 5000000 (it learns down
#         over full cycles; stock had learned 4578 mAh); temp 200-400 (deci-°C)
#         and it moves (hold the phone, run a CPU load: it rises within minutes);
#         capacity close to before (it may jump a few %, re-estimated from voltage);
#         current_now sign still flips with the cable.
# B1b.5  persistence: reboot into Linux again and repeat B1b.0
#   expect POR clear and the same model registers (no reload). If POR is set
#   on every boot, something resets the gauge between boots: write it down,
#   the loader then simply runs each boot (~1 s).
```

Forcing a reload (only if needed, e.g. to test the loader again): the gauge
reloads only after a POR. `i2cset -f -y 0 0x36 0x60 0x000f w` is the m5
hardware reset (Google's `max1720x_full_reset()`, `MAX_M5_COMMAND_HARDWARE_RESET`),
then `modprobe -r max17042_battery; modprobe max17042_battery`. It throws away
everything the gauge has learned (Cycles, FullCapNom, RComp0).

**Rollback.** The gauge has no NVM, so nothing we write survives a power
loss, and every change can be undone in software:

1. Bad readings after the load: `i2cset -f -y 0 0x36 0x60 0x000f w`
   (hardware reset: back to the default EZ model, POR set), then boot the
   previous kernel/DTB (`bin/omandroid push` from `out-wifi`, or let ABL fall
   back to slot A). With the old DTB, the driver writes nothing again.
2. Or boot stock Android in slot A: it reloads its own model (below).
3. A loader failure is already safe: POR stays set and the driver reports
   from the default model, as in B1.

### Dual boot: what stock Android does with our gauge

Google's driver checks the gauge at every probe (`max1720x_init_max_m5()`,
`G/google-modules/bms/max1720x_battery.c:5462-5530`): if the model version in
TAlrtTh[15:8] differs from the DT's (`max_m5_fg_model_check_version()`), it
issues a hardware reset and reloads its model (`"FG Version Changed, Reset,
Will Reload"`). It also reloads whenever it sees POR (`max1720x_check_por()`,
`:2525`). Our loader leaves TAlrtTh at its POR value (version 0x7f, not 1), so
**Android always replaces our load with its own**, then handles its saved
learned state (GMSR) as it does after any reset. The other way round, Android's load clears POR and sets
TaskPeriod 0x2d00, so the next Linux boot reads it correctly and does not
reload. Not writing the version is deliberate: on this gauge TAlrtTh[15:8] is
also the over-temperature alert threshold (1 °C for version 1), and upstream
enables the alert pin.

### Not in this step

- Battery ID and the ID-3 model: needs the battery ID in Linux.
- Charging (B3/B4). Stock's top CV limit is 4.45 V (`google,fv-max-uv`,
  `R/live.dts:18205`); upstream's charger programs 4.3 V unless its own power
  supply has battery info. Read the float voltage ABL leaves before B3.
- **USB data switch (separate gate, B4-adjacent).** Google's TCPC driver
  closes the MAX77759's USB2 data switch on attach and opens it on detach
  (`enable_data_path_locked()`, `GS/drivers/usb/typec/tcpm/google/tcpci_max77759.c:1117-1215`).
  Nothing in our Linux closes it again, a likely cause of our "USB doesn't
  reconnect after unplugging" note. The switch is
  TCPC (0x25) vendor register **0x93 `USBSW_CTRL`**, 0x09 = connected
  (Google `tcpci_max77759_vendor_reg.h:94-95`). Upstream `tcpci_maxim_core.c:24-26,302`
  already writes it from TCPM, so B4 should fix it for good. Gated test, only
  with a non-USB console (Wi-Fi SSH or the on-screen terminal), since USB is
  the link that breaks: read `i2cget -y 0 0x25 0x93` while connected (write it
  down), unplug and replug, read again (0x00 would confirm the report), then
  `i2cset -y 0 0x25 0x93 0x09` and check the host enumerates the gadget.
  Rollback: replug or reboot.

---

## 7. PCIe for Wi-Fi: W0b status (2026-10-11, offline; nothing was run on the phone)

Kernel branch `omandroid-pcie` in `/home/raven/android/mainline/wt-pcie`
(on top of the BCM4389 and MAX77759 commits), built into
`~/android/mainline/out-pcie`. Path abbreviations as at the top, plus
`P/` = `wt-pcie` and `GD/` = `GS/drivers/pci/controller/dwc`.

### 7.1 What was built

| Commit | What |
|---|---|
| `c66efda39` dt-bindings: phy: add Google gs201 PCIe PHY | `google,gs201-pcie-phy.yaml` |
| `cda2eddb1` phy: samsung: add Google gs201 PCIe PHY driver | `P/drivers/phy/samsung/phy-gs201-pcie.c`, `CONFIG_PHY_GS201_PCIE` (m) |
| `f6e5443d8` dt-bindings: PCI: add Google gs201 PCIe host controller | `google,gs201-pcie.yaml` |
| `65eb5647f` PCI: dwc: add Google gs201 PCIe host controller driver | `P/drivers/pci/controller/dwc/pcie-gs201.c`, `CONFIG_PCIE_GS201` (m) |
| `f08655559` dt-bindings: net: wireless: brcm,bcm4329-fmac: allow a restricted DMA pool | `memory-region` on the Wi-Fi node |
| `3f6c342fe` arm64: dts: exynos: google: gs201: add HSI2 pinctrl and PCIe GEN4A_1 | `pinctrl_hsi2` (enabled), `pcie_1` + `pcie_1_phy` (**disabled**) |
| `c2b4f9d3d` arm64: dts: exynos: google: gs201-cheetah: wire up the BCM4389 Wi-Fi | WL_REG_ON regulator, root port + `wifi@0,0`, pins, `wifi_dma_pool` (**disabled**) |

omandroid repo: `kernel/configs/omandroid.config` (`PCIE_GS201=m`,
`PHY_GS201_PCIE=m`, `PCI_PWRCTRL_GENERIC=y` (built in anyway: the arm64
defconfig's `PCIE_QCOM` selects it), `DMA_RESTRICTED_POOL=y`),
`device/cheetah/overlays/wifi-pcie-test.dtso` and `wifi-dma-pool-test.dtso`
(the explicit enable steps), and `packages/omandroid-device-cheetah/vendor/modprobe.d/omandroid-wifi.conf`
(blacklists `pcie_gs201` and `brcmfmac`).

Checks: `bin/omandroid kernel`, `modules` and `images` exit 0
(`logs/kernel-pcie.log`, `modules-pcie.log`, `images-pcie.log`). Both new
drivers build with `W=1` and no warnings, as does the DTB (the only dtc
warning is the existing `/chosen/framebuffer`). `dt_binding_check` and
yamllint pass for the three bindings. `dt-validate` (dtschema 2026.9) of the
default DTB **and** of the DTB with both test overlays applied (`pcie_1`,
the PHY and the pool all enabled) reports only the existing `soc_id`.

### 7.2 Hardware description (and what changed from the 1.7 sketch)

- **`pinctrl_hsi2`** `pinctrl@14440000`, alias `pinctrl7` (the 8th entry of
  `gs201_pin_ctrl[]`, `P/drivers/pinctrl/samsung/pinctrl-exynos-arm64.c`),
  GIC SPI 421, banks `gph2`/`gph4`. Enabled by default: it only registers two
  gpiochips. The UFS pins are on the separate HSI2UFS controller and are not
  touched.
- **`pcie_1`** `pcie@14520000`: ELBI `0x14520000/0x1400`, DBI
  `0x14800000/0x301000` (the DWC core finds the unrolled iATU at +0x300000 by
  itself), config `0x60ffe000/0x2000`, I/A `0x14500000/0x1000`; MEM window
  `0x60000000/0xff0000`; SPI 428; `num-lanes = 1`, `max-link-speed = 2`;
  `dma-coherent` with `samsung,sysreg = <&sysreg_hsi2 0x730>`. INTx goes
  through a `legacy-interrupt-controller` child. `soc@0` now maps up to
  `0x80000000` so the window is reachable.
- **`pcie_1_phy`** `phy@14550000`: PMA `0x14550000/0x2000`, PCS
  `0x14540000/0x1000`, `rst` = ELBI `+0x1400/0x10` (the three PHY reset
  registers; the controller's ELBI mapping stops at 0x1400 so the two don't
  overlap), UDBG `0x14560000/0xd000`, `samsung,pmu-syscon =
  <&pmu_system_controller 0x3ec4>`.
- **cheetah**: `wlan_pwr` = `regulator-fixed` on `gph2-4` (WL_REG_ON),
  `startup-delay-us = 200000`; root port `pcie@0,0` (`pciclass,0604`) with
  `vpcie3v3-supply = <&wlan_pwr>`; `wifi@0,0` = `pci14e4,4441`,
  `brcm,board-type = "google,gs201-cheetah"`, host-wake `gpa6-1` level-high
  (`interrupts-extended`), `memory-region = <&wifi_dma_pool>`; pinctrl for
  CLKREQ#, PERST#, dev-wake (`gph2-5`, input pull-down) and host-wake
  (EINT, pull-down) as in `G/devices/google/gs201/dts/gs201-cloudripper-wlan.dtsi:13-55`.
- **`wifi_dma_pool`**: `restricted-dma-pool`, 16 MiB, 2 MiB aligned, dynamic
  placement, `status = "disabled"`. Disabled reserved-memory nodes are not
  reserved at all, and `of_dma_set_restricted_buffer()` skips an unavailable
  pool (`P/drivers/of/device.c:51-58`), so it costs nothing until enabled.

### 7.3 Design choices, with evidence

> **Corrected 2026-10-11 (section 8.3).** This section was written against
> Google's `dwc/` driver, which is the Zuma (Pixel 8) one. The driver Google
> builds for gs201 is `dwc-whi/`. The PMU bit 10, UDBG 0xc800 and PMA 0x32c
> writes below are gone; the soft resets, RC device type and the newer CAL
> details were added; and the PHY now leaves isolation before any ELBI access.

- **PHY sequence = Google's CAL, verbatim.** Order in `phy_power_on()`:
  power-down clear (`GD/pcie-exynos-gs201-rc-cal.c:62-88`), then the
  config (`:99-339`): input clock 0xd8, PCS mux glitch fix, the reset pulse
  on ELBI 0x1400/0x1404/0x1408 with 0x1404 released first (`:123-133`),
  common PMA, 38.4 MHz block, per-lane table (`:176-276`), both-lane clock
  block (`:279-288`), PCS RC/L2 settings (`:293-325`), CMN/PORT release
  (`:328-329`), XO select at 0x5d0 (`:333-336`). Then Google's link-up
  extras: PMU 0x3ec4 bit 10, UDBG 0xc800 = 0x421, PMA 0x32c = 0
  (`GD/pcie-exynos-rc.c:3567-3578`). `phy_power_off()` is the all-power-down
  (`cal.c:36-59`). Tables are in `P/drivers/phy/samsung/phy-gs201-pcie.c:75-160`.
  Note Google's per-lane loop adds `i * 0x800` cumulatively (`cal.c:177`);
  that is only equal to a lane stride for one or two lanes, which is all
  this PHY has.
- **PHY isolation:** `phy_init()` sets PMU 0x3ec4 bit 0 (bypass), as
  `exynos_pcie_phy_isolation(PCIE_PHY_BYPASS)` does (`GD/pcie-exynos-rc.c:393-407`;
  values `GD/pcie-exynos-common.h:52-53`). It goes through the exynos-pmu
  regmap, which uses the secure SMC path; 0x3ec4 (`GS101_PHY_CTRL_PCIE_GEN4_1`)
  is in its writable table (`P/drivers/soc/samsung/gs101-pmu.c`, range ending
  at `GS101_PHY_CTRL_UFS`). Stock never isolates ch1 at runtime
  (`use-phy-isol-en` unset, `GD/pcie-exynos-rc.c:2263-2278`); we isolate
  only in `phy_exit()`.
- **Controller link-up = `exynos_pcie_rc_establish_link()`
  (`GD/pcie-exynos-rc.c:3551-3800`)**, split over the DWC host hooks in
  `P/drivers/pci/controller/dwc/pcie-gs201.c`:
  `host_init` (`:427`): PERST# low, pwrctrl power-on (WL_REG_ON + 200 ms),
  PHY init/power-on, I/A, DBI setup (`:242`: vendor/device 144d:eced,
  GEN3_RELATED_OFF = 0x12000 "EQ off" `rc.c:3581`, aux clock 26 MHz
  `rc.c:3191`, L1 exit latency and completion timeout as `rc.c:3160-3230`),
  ELBI setup (`:217`: 0x3bc exit-L1/NAK, 0x3a0 manual link-down reset,
  0x74 xfer pending, 0x3a8 Q-channel no gating for IP >= 0x889500, 0x474
  NAK, 0x1078 DBI L1 exit disable, history buffer; `rc.c:3594-3660`), IOCC
  (`:201`: DBI 0x8e8 = 0x10101010 and sysreg 0x730 = 3, `rc.c:1974-2028`,
  `rc.h:240-245`), PERST# high and 20 ms (`perst_delay_us` default,
  `rc.c:2083-2085`). `start_link` (`:356`): ELBI 0x54 = 1, poll
  0x2c8 & 0x3f for L0 for 48 ms (`MAX_TIMEOUT` 4800 x 10 us,
  `common.h:20`), up to 3 tries with PERST# low and a PHY redo in between
  (stock does 10, `rc.c:3686-3720`), then clear xfer-pending and enable the
  link-down and completion-timeout interrupts (`rc.c:3780-3798`).
  `link_up` uses stock's window RCVRY_LOCK..L1_IDLE (`rc.c:1775-1788`).
- **I/A sequencer kept, default on**, because the stock cheetah DT turns
  it on (`use-ia = "true"`, `R/live.dts:12134`; "PCIe I/A is ENABLED",
  `R/dmesg.txt:2076`) and Google runs it on every link-up right after the
  PHY config (`rc.c:3071-3086`). The microcode is `rc.c:2945-3068`, in
  `pcie-gs201.c:151`. It needs the ELBI, PMA and I/A physical addresses; the
  PMA one is read from the PHY node. `modprobe pcie_gs201 use_ia=0` skips it
  (an on-phone experiment, 7.5).
- **INTx only, as on stock** (`use-msi = "false"`, `R/live.dts:12131`). On
  stock the GIC line is shared between `exynos-pcie` and `dhdpcie`
  (`R/interrupts.txt:243`) and only the controller acks the ELBI status
  (`rc.c:3290-3305`). Here a chained handler (`pcie-gs201.c:554`) acks
  IRQ0-2 (write-one-to-clear) and dispatches IRQ0 bits 14/16/18/20
  (`rc.h:19-23`) to a 4-line INTx domain; the child chip masks through
  IRQ0_EN (`rc.h:31-35`). A no-op `msi_init` (`:501`) keeps the DWC core
  from chaining its iMSI-RX handler onto the same line; brcmfmac's
  `pci_enable_msi()` fails and it uses INTx.
- **WL_REG_ON through PCI pwrctrl.** 7.3 has `pci_pwrctrl_create_devices()`
  / `power_on_devices()` for DWC glue drivers (used by `pcie-qcom.c`); the
  generic driver binds `pciclass,0604` nodes with a `*-supply`. That gives
  the right order (power, then PERST#) and powers the chip off on unbind.
  The 200 ms is `WIFI_TURNON_DELAY` (`W/dhd.h:3138`; stock: REG_ON at 3.571 s,
  L0 at 3.809 s, `R/dmesg.txt:5171,5424`).
- **Clocks: the x2 controller (`PCIE_003`), not `PCIE_004`.** pcie_1 is
  GEN4A_1 (I/A `PCIE_IA_GEN4A_1` at 0x14500000, `QE_PCIE_GEN4A`,
  `UASC_PCIE_GEN4A_DBI_1`), and Google's base DT gives it `num-lanes = <2>`
  (`G/devices/google/gs201/dts/gs201-pcie.dtsi`), so it is the x2
  controller; cheetah only wires one lane. Stock manages no clocks at all
  (`pcie-clk-num = <0>`), and CMU_HSI2 runs automatic gating
  (`auto_clock_gate`), so enabling these gates is belt and braces. We boot
  with `clk_ignore_unused`, so a wrong pick cannot break W1; it matters only
  once that goes (7.8).
- **Not ported, on purpose:** L1 substates (`rc.c:4264-4590`), the
  suspend/L2 path (`rc.c:3979-4118`), the "ch2" PHY power-down of the unused
  third PHY at 0x131b0000 (`rc.c:3088-3131`, PMU 0x3ecc is outside the PMU
  regmap's writable table), the SysMMU/S2MPU DMA ops (`rc.c:232-360`), and
  `exynos_soc_write(0x15, 0x4000)` (`rc.c:3874`). The last writes a "soc"
  region that the stock DT does not have, so in the source we have it
  cannot run as written; it is an experiment if detection fails (7.5).

### 7.4 Security (unchanged rule, now enforced in three places)

Until gate W4, the BCM4389 can DMA to all of RAM (1.5). Therefore:
`pcie_1`, `pcie_1_phy` and `wifi_dma_pool` are `disabled` in the default
DTB; `pcie_gs201` and `brcmfmac` are blacklisted in
`omandroid-device-cheetah`; enabling is the explicit overlay step below.
**Wi-Fi must not ship enabled until W4** (a restricted-dma-pool that the
HSI2 S2MPU confines the chip to, or S2MPU programming by other means). Run
W1-W3 on a network you trust. Never commit the firmware (2.3) or the MAC
from `/chosen/config`.

### 7.5 W1 runbook: link up (on the phone; each step has its rollback)

From the omandroid repo, phone in Arch over USB, a second terminal running
`tools/phone-ssh dmesg -w`. `devmem` is `tools/devmem.c` (in the initramfs
at `/usr/local/bin/devmem`; copy it to the root if needed).

```sh
export KERNEL_DIR=$HOME/android/mainline/wt-pcie KERNEL_OUT=$HOME/android/mainline/out-pcie
O=$KERNEL_OUT D=$O/arch/arm64/boot/dts/exynos/google/gs201-cheetah.dtb

# W1.0  the blacklist must be on the phone BEFORE any DTB with pcie_1 on
tools/phone-ssh 'grep -H . /usr/lib/modprobe.d/omandroid-wifi.conf'   # pcie_gs201, brcmfmac
#       if missing: reinstall omandroid-device-cheetah (or stream the file to /etc/modprobe.d/)

# W1.1  new kernel, default DTB (pcie_1 off). Only change: HSI2 pinctrl + an idle regulator
bin/omandroid modules-push && bin/omandroid push          # slot B, reboots
tools/phone-ssh 'uname -r; grep -E "gph2|gph4" /sys/kernel/debug/gpio | head -3;
  grep wlan /sys/kernel/debug/regulator/regulator_summary; lsmod | grep -c gs201'
#       pass: USB/SSH, UFS, touch, GPU as before; gph2/gph4 chips; wlan-reg-on 0 users; 0 modules
tools/phone-ssh 'devmem 0x145e0000'    # S2MPU_HSI2 CTRL0: expect 0 (off). UFS shares HSI2, so safe
#       rollback: power-cycle; ABL falls back to slot A after the retries, or push the previous out dir

# W1.2  explicit enable: overlay pcie_1 + PHY into the DTB, then images
cp "$D" "$D.default"
$O/scripts/dtc/dtc -q -I dts -O dtb -o out/wifi-pcie-test.dtbo device/cheetah/overlays/wifi-pcie-test.dtso
$O/scripts/dtc/fdtoverlay -i "$D.default" -o "$D" out/wifi-pcie-test.dtbo
bin/omandroid images && bin/omandroid push
tools/phone-ssh 'ls /sys/bus/platform/devices | grep -E "14520000|14550000"; lsmod | grep gs201'
#       pass: both devices exist; phy_gs201_pcie may be loaded (it only maps registers), pcie_gs201 not
# DO NOT read the controller's registers here (e.g. devmem 0x145202c8): ABL
# leaves the PHY isolated in the PMU, and while it is isolated any ELBI access
# hangs the SoC (no panic, so no auto-reboot; recover by holding Power ~30 s).
# This happened on 2026-10-11 (section 8.1). Never devmem PCIe registers at all;
# the driver logs what is needed.
#       rollback: cp "$D.default" "$D"; bin/omandroid images && bin/omandroid push
#       (bin/omandroid kernel also rebuilds the DTB without the overlay)

# W1.3  SUPERSEDED by section 8 (staged, with tools/wifi-w1-capture). Kept for the record:
tools/phone-ssh 'modprobe phy_gs201_pcie &&
  echo "module pcie_gs201 +p; module phy_gs201_pcie +p" > /sys/kernel/debug/dynamic_debug/control &&
  modprobe pcie_gs201 && sleep 1 && lspci -nn'
#       (the pwrctrl "slot" driver that switches WL_REG_ON is built in: arm64 defconfig)
#       pass: "PCIe Gen.2 x1 link up" (Gen.1 is acceptable for W1, note it),
#             0000:00:00.0 [144d:eced] bridge, 0000:01:00.0 [14e4:4441] network,
#             BAR0 64K and BAR2 4M assigned (stock: R/dmesg.txt:5461-5470)
tools/phone-ssh 'devmem 0x145202c8; grep -i gs201 /proc/interrupts'   # 0x11 = L0; no storm
#       rollback: tools/phone-ssh modprobe -r pcie_gs201   (PERST# low, PHY off, WL_REG_ON low)
#       if the phone hangs: panic=10 reboots on a panic; a bus hang needs Power held ~30 s;
#       then boot the default DTB (W1.2 rollback)
```

**If W1.3 fails**, the driver prints "link training failed (try n), LTSSM
0x.." and, after the last try, the controller's 32-entry LTSSM history.
Read it this way:

| Last LTSSM | Meaning | Next experiment |
|---|---|---|
| 0x00-0x01 Detect | no receiver: the chip is unpowered or held in reset | `grep gph2 /sys/kernel/debug/gpio`: gph2-4 (WL_REG_ON) and gph2-0 (PERST#) must be high during training; regulator_summary shows `wlan-reg-on` enabled. If both are right, suspect the S2MPG13 PCIe rails (LDO3 0.85 V, LDO18 1.8 V; always-on in stock, but we cannot read them without an S2MPG13 driver): boot stock, then warm-reboot into slot B so the rails were last set by Android, and retry |
| 0x02-0x06 Polling/Detect-wait | receiver seen, no bit lock: PHY, refclk or CLKREQ# | `modprobe -r pcie_gs201; modprobe pcie_gs201 use_ia=0`; compare the dyndbg line "PMA 0x3f0 .. 0xfc0 .. PCS 0x188" across tries; check `gph2-1` is in function 2 (CLKREQ#) |
| 0x07-0x10 Config/Recovery | trains but drops | try `max-link-speed = <1>` via a one-line overlay (Gen1) |
| L0 but no 01:00.0 | config TLPs fail | `lspci -vv -s 00:00.0` bus numbers; dmesg for "completion timeout"; iATU lines from the DWC core |

### 7.6 W2 runbook: brcmfmac, firmware, interface, scan

**Superseded by 9.4** for W2.2-W2.3 (the first W2 run failed; section 9 has
the cause and the fixed runbook). W2.1 (firmware to the phone) still applies.

The firmware comes from the user's own factory image, extracted on the
laptop by `tools/extract-vendor-firmware` (2.2), into `out/` (gitignored).
It is never committed or packaged.

```sh
# W2.1  firmware (laptop -> phone)
tools/extract-vendor-firmware -o out/vendor-firmware \
  ~/android/factory/cheetah-cp2a.260705.006/image-cheetah-cp2a.260705.006.zip
tar -C out/vendor-firmware -cf - usr | tools/phone-ssh 'tar -C / -xf -'
tools/phone-ssh 'ls -l /usr/lib/firmware/updates/brcm/ | grep cheetah'   # .bin .txt .clm_blob (+ BT .hcd)
#       rollback: tools/phone-ssh 'rm /usr/lib/firmware/updates/brcm/*google,gs201-cheetah*'

# W2.2  driver (the blacklist only stops autoload; an explicit modprobe works). Link from W1.3 is up.
tools/phone-ssh 'modprobe brcmfmac && sleep 5 && dmesg | grep -i brcmf | tail -20 && iw dev'
#       pass: "using brcm/brcmfmac4389c1-pcie for chip BCM4389/N", firmware 20.101.90,
#             CLM "Google.C10sub6" loaded, wlan0 listed. Write down N.
#       rollback: tools/phone-ssh 'modprobe -r brcmfmac'   (chip keeps its firmware until
#                 'modprobe -r pcie_gs201' drops WL_REG_ON)

# W2.3  scan (no association yet; the MAC is whatever the chip reports, see 1.6)
tools/phone-ssh 'ip link set wlan0 up && iw dev wlan0 scan | grep -E "^BSS|SSID:|signal:" | head -30'
#       pass: nearby networks with sane signal levels; no "brcmf_.*error" or firmware trap in dmesg
#       rollback: 'ip link set wlan0 down; modprobe -r brcmfmac; modprobe -r pcie_gs201'
```

W2 failure signatures and what to change are in 1.6 (IPC version 8/9,
FW-up timeout, CLM name). Interrupt problems show as "brcmf_pcie_..."
timeouts with `grep gs201-pcie-intx /proc/interrupts` not counting: then
INTx is not reaching brcmfmac (check that IRQ0 bit 14 is set in `devmem
0x14520000` while the chip is up).

### 7.7 Before W4: brcmfmac through the restricted pool (optional, safe)

Apply `wifi-dma-pool-test.dtso` on top of `wifi-pcie-test.dtso` (same as
W1.2, second `fdtoverlay` pass) and reboot. **Expect** "Reserved memory:
created restricted DMA pool at 0x..., size 16 MiB" early in dmesg, and W2
working unchanged. This proves brcmfmac runs with all its DMA bounced
through one region, which is the precondition for W4. It does **not**
protect anything yet: the S2MPU still allows everything. Rollback: the
W1.2 DTB.

### 7.8 Open risks and how each gets answered

- **The PHY table is untested.** It is Google's verbatim, but our order
  differs in two small ways: the PMU bit 10 goes before, not after, the I/A
  programming, and the controller's DBI/ELBI setup is done once, not
  repeated on every retry. The history dump in 7.5 tells which stage fails.
- **PCIe rails.** S2MPG13 LDO3/LDO18 are `regulator-always-on` in stock; we
  assume ABL leaves them on. A Detect-only failure with WL_REG_ON and PERST#
  high points here (7.5 table).
- **I/A on or off.** Stock runs it; if it misbehaves without L1.2 it can be
  dropped with `use_ia=0`.
- **Gates 003 vs 004.** Once `clk_ignore_unused` goes, check that the link
  still trains and that `clk_summary` shows the 003 gates enabled.
- **INTx semantics.** The ELBI INTA bit is an assert event, not a level;
  brcmfmac masks the chip's interrupt in its hard IRQ handler and unmasks it
  after the thread, which produces a fresh assert. Same contract as stock,
  but watch for stalls under load at W3.
- **No link-down recovery.** A link-down or completion-timeout is logged
  only. Recovery is `modprobe -r brcmfmac pcie_gs201` and load again.
- **Suspend.** No L2/PME path yet; keep suspend off (it already is).
- **Domain number.** We have one host bridge, so the Wi-Fi chip is
  `0000:01:00.0`, not stock's `0001:01:00.0`.

---

## 8. W1 on the phone: two hangs, the cause, and the staged W1.3 (2026-10-11)

Path abbreviations as above, plus `GW/` =
`GS/drivers/pci/controller/dwc-whi`.

### 8.1 What happened

1. **W1.2** booted fine with `wifi-pcie-test.dtso`: `14520000.pcie` and
   `14550000.phy` were present and `phy_gs201_pcie` autoloaded (its probe only
   maps registers). Then `devmem 0x145202c8` (ELBI LTSSM) **hung the whole
   phone**: no panic, no auto-reboot, recovered with a 30 s Power hold.
2. **W1.3, try 1:** `modprobe pcie_gs201` failed cleanly with -EBUSY ("can't
   request region for resource [mem 0x14520000-0x145213ff]"). The DWC core
   requested "elbi" a second time. Fixed by handing the mapping over
   (`pci->elbi_base = gp->elbi`), folded into the driver commit.
3. **W1.3, try 2:** `modprobe phy_gs201_pcie; modprobe pcie_gs201` **hung the
   whole phone within seconds**. The network went, and there was no panic.
   Nothing reached the disk (the nohup log and the journal were empty), and
   pstore was empty after the Power-hold reset.

Why nothing was logged:

- **The disk could not help.** The root file system is UFS, in the same HSI2
  block. With one CPU stuck in a load that never completes, IPIs and RCU stall
  the rest within seconds.
- **pstore could not help either:**
  - the bootargs carry `quiet`, so the pstore console only got warnings and
    worse;
  - a 30 s Power hold is a cold PMIC reset, so DRAM, and with it ramoops, is
    lost.

### 8.2 Cause, ranked, with evidence

1. **ELBI accessed while the PHY was still isolated (almost certain).**
   - ABL leaves the channel-1 PHY isolated in the PMU (`0x18063ec4` bit 0 =
     0). While it is isolated, even a read of the controller's ELBI registers
     hangs the SoC. Isolation must be released first, through the secure SMC
     path. Copying Google's probe order verbatim hits this.
   - **W1.2:** `devmem 0x145202c8` was an ELBI read with the PHY still
     isolated, which explains hang 1 exactly.
   - **W1.3:** our old probe did the following, all before `phy_init()` (the
     only place that released isolation):
     - wrote ELBI `0x10/0x14/0x18` in `gs201_pcie_init_irq()`;
     - installed the chained IRQ handler, which reads ELBI;
     - wrote ELBI `0x54` (LTSSM off) at the top of `host_init`.

     The first access hung. That explains hang 2.
   - **Google's code agrees:**
     - its gs201 config accessor refuses DBI reads while `phy_control ==
       PCIE_PHY_ISOLATION` (`GW/pcie-exynos-rc.c:1269-1290`);
     - it never isolates ch1 again after probe (`use-phy-isol-con` is not set
       in the stock DT).
2. **We ported the wrong Google driver (certain; a link-training risk, and
   one unknown register write).**
   - Section 7 used `GS/drivers/pci/controller/dwc/`, which is the Zuma
     (Pixel 8) driver. Its `get_resource()` requires a "soc" region that the
     stock cheetah DT does not have.
   - The gs201 build compiles `GS/drivers/pci/controller/dwc-whi/`. That is
     the path of the built `pcie-exynos-gs.ko` under
     `out/bazel/.../gs201_soc/.../dwc-whi/`.
   - **What `dwc-whi` does differently:**
     - **No** PMU `0x3ec4` bit 10 write, **no** UDBG `0xc800 = 0x421` and no
       PMA `0x32c` write. All three are Zuma's. On gs201, UDBG 0xc800 is an
       undocumented register, so writing it was a hang candidate of its own.
     - A soft power reset (ELBI `0x3a4` bit 1), **DEVICE_TYPE = 4 (root
       complex) at ELBI `0x80`**, and a non-sticky reset (bit 3) before the
       DBI setup (`GW/pcie-exynos-rc.c:3142-3173`). Without them the core may
       not even be in RC mode.
     - CAL changes (`GW/pcie-exynos-gs201-rc-cal.c`):
       - PMA `0x404` in power-down and its clear;
       - PMA `0x400` bit 7 (PMA off) at power-down;
       - PCS `0x184` rate switching;
       - ERIO gating bits 4 and 5, not only 4;
       - AFC calibration restart (`0xbf4 = 4`);
       - a reset-value self-check.

       The big PMA tables are identical (checked line by line).
     - PLL, CDR and offset-calibration polls after the config, each bounded
       at 10 ms (`:908-935`, `:3122-3160`).
     - No `XFER_PENDING` writes in the link path.
3. **CMU_HSI2 global automatic clock gating (unproven; kept as an opt-in
   experiment).**
   - Our clk-gs201 writes `CMU_HSI2 CONTROLLER_OPTION` (`0x14400800`) =
     `0xf1000000` at boot (bit 28 = global HWACG, `clk-exynos-arm64.c:104-112`).
   - Google's gs201 probe clears bit 28 for ch1 ("Disable automatic clock
     gating on OSCCLK", `GW/pcie-exynos-rc.c:2673-2716`), and the controller's
     Q-channel by default allows APB/AXI gating in Detect.Quiet (`QCH_SEL`
     bits, `GW/pcie-exynos-rc.h:64-85`).
   - UFS shares this CMU. So it stays off unless stage 2 or 3 still hangs
     (`cmu_acg_off=1`).
4. **Lower-ranked, checked:**
   - The DWC core only issues config cycles to bus 1 when `link_up` is true
     (`dw_pcie_other_conf_map_bus()`).
   - The PMU write goes through the SMC (`tensor_sec_update_bits`). A refusal
     returns an error, not a hang.
   - There are no unbounded polls in our code.
   - The clock "enables" are no-ops on CMU_HSI2's auto gates
     (`samsung_auto_clk_gate_en()` returns 0), so they cannot be the
     difference.

### 8.3 What changed (all offline)

Kernel `omandroid-pcie` in `wt-pcie`, fixups squashed into the existing
commits. The new heads:

| Commit | What |
|---|---|
| `cda2eddb1` | phy: samsung: add Google gs201 PCIe PHY driver |
| `f6e5443d8` | dt-bindings: PCI: add Google gs201 PCIe host controller |
| `65eb5647f` | PCI: dwc: add Google gs201 PCIe host controller driver |
| `3f6c342fe` | arm64: dts: exynos: google: gs201: add HSI2 pinctrl and PCIe GEN4A_1 |

The other commits are unchanged in content.

**PHY driver:**
- `phy_init()` releases the isolation through the PMU regmap (SMC), then
  powers the PHY down. This is Google's probe step, and the first PMA/PCS
  access happens here.
- `phy_power_on()` runs the `dwc-whi` CAL and the lock polls.
- `phy_calibrate()` reports OC after the soft reset.
- `phy_exit()` **no longer re-isolates**, as stock.

**Controller driver:**
- The new order follows `GW/`, with the isolation release moved first:
  1. isolation off and PHY power-down;
  2. the first ELBI access (interrupt enables off, LTSSM off);
  3. the chained IRQ handler;
  4. WL_REG_ON and 200 ms;
  5. PHY config and I/A;
  6. soft power reset, RC device type, non-sticky reset;
  7. PERST# and 20 ms;
  8. ELBI setup, DBI setup and IOCC;
  9. DWC root-port setup, then LTSSM.
- A failed try redoes the PHY, controller and `dw_pcie_setup_rc()`, as stock.
- The DT has a new optional `samsung,cmu = <&cmu_hsi2>` (binding updated). It
  is used only for the CMU option read, the dump and `cmu_acg_off`.

**Bring-up aids (module parameters):**

| Module | Parameter | Meaning |
|---|---|---|
| `pcie_gs201` | `stop_after=N` (0444) | end probe after stage N, undo, do not bind (returns -ENODEV, silent) |
| both | `trace=1` (0644) | log each hardware step *before* doing it: "about to read PMA 0x400", "enable clk ...", ... |
| both | `trace_delay_ms=20` (0644) | sleep after each trace line, so `/dev/kmsg` readers get it before a possible hang |
| `pcie_gs201` | `use_ia=0` | skip the I/A sequencer |
| `pcie_gs201` | `cmu_acg_off=1` | clear CMU_HSI2 global automatic clock gating in stage 1 (Google's step) |
| `phy_gs201_pcie` | `check_tcxo=1` | read PMU `0x3c10` (TCXO_BUF_CTRL; stock reads it raw on every boot) and set bits 2/3/10 via SMC if missing |

Stages:

| N | Stage | Hardware touched |
|---|---|---|
| 0 | resources | none (mappings, GPIO PERST# held low) |
| 1 | clocks | clock refs (no-ops on HSI2); with `samsung,cmu`: one CMU_HSI2 read (option), with trace a dump of the HSI2 gate and PCIe Q-channel registers; `cmu_acg_off=1` writes the option |
| 2 | PHY isolation off, first register access | PMU 0x3ec4 bit 0 via SMC; PHY power-down (first PMA/PCS writes and reads); ELBI `0x10-0x18`, `0x54` writes; ELBI `0x3a8/0x3a4/0x80` reads |
| 3 | PHY configuration | power-down clear, PMA reset self-check, CAL tables, ELBI `+0x1400` PHY resets, lock polls; I/A program and start |
| 4 | controller setup | soft resets, DEVICE_TYPE, first DBI reads (ID, `0x8f8` version), DBI and ELBI setup, IOCC; ELBI `0x2e8/0x2c8` read (the register that hung W1.2) |
| 5 | link (default) | WL_REG_ON, PERST#, DWC iATU/root port, LTSSM, enumeration |

With `stop_after < 5` WL_REG_ON is never raised, PERST# stays low and no host
bridge is registered. Each staged run ends with the PHY powered down (not
isolated) and the clock refs dropped, so stages can be re-run on the same
boot.

**`tools/wifi-w1-capture`** (MIT), run from the laptop:
1. Checks the phone: both devices present, the blacklist, and whether
   `pcie_gs201` is loaded (if so, unloads it).
2. Sets `dmesg -n 8`, so the pstore console keeps info lines too.
3. Sets the PHY module's parameters through sysfs.
4. Starts `cat /dev/kmsg` over a first SSH connection into
   `logs/wifi-w1-<time>-s<N>.log`, with the laptop's receive time on each
   line.
5. Writes a start marker to `/dev/kmsg`.
6. Optionally (`--watchdog`) arms `/dev/watchdog0` with a 2 s feeder on the
   phone. A full hang then becomes a warm watchdog reset in about 15 s, with
   DRAM and ramoops kept, instead of a cold Power hold.
7. Runs `modprobe pcie_gs201 trace=1 stop_after=N ...` over a second
   connection.
8. Waits for an end marker. If the phone still answers, it stops the watchdog,
   checks that UFS still reads, and unloads (stage < 5) or runs `lspci`
   (stage 5). If the phone is gone, it prints the last lines that arrived.
9. `tools/wifi-w1-capture --pstore` saves `/sys/fs/pstore/*` after a watchdog
   reset.

Builds: `bin/omandroid kernel`, `modules` and `images` with
`KERNEL_DIR=wt-pcie KERNEL_OUT=out-pcie` exit 0 (`logs/kernel-pcie.log`,
`modules-pcie.log`, `images-pcie.log`). Both drivers are clean with `W=1`.
`out-pcie`'s DTB **has the test overlay applied** (`pcie_1` and the PHY
okay, `samsung,cmu` present); the plain one is
`gs201-cheetah.dtb.default`. `dt_binding_check` was not re-run (dtschema is
not installed in the container or on the host); the YAML parses.

### 8.4 W1.3 runbook (staged)

Prerequisites:
- The W1.0 blacklist is on the phone.
- The phone boots the `out-pcie` kernel with the test DTB:
  `bin/omandroid modules-push && bin/omandroid push` with
  `KERNEL_DIR=$HOME/android/mainline/wt-pcie
  KERNEL_OUT=$HOME/android/mainline/out-pcie`. The new modules must be on the
  phone, because the old `pcie_gs201.ko` is the one that hangs.
- **Never use devmem on any PCIe, PHY or PMU register.**

Run each stage once, in order, on the same boot. Stop at the first stage that
does not pass.

```sh
tools/wifi-w1-capture 0              # driver loads, parses DT, no hardware: "stopped after stage 0"
tools/wifi-w1-capture 1              # clocks + CMU_HSI2 option read (+ gate dump)
tools/wifi-w1-capture --watchdog 2   # THE decisive step: isolation release, first PHY and ELBI access
tools/wifi-w1-capture --watchdog 3   # PHY config: look at "PLL lock 1"
tools/wifi-w1-capture --watchdog 4   # soft resets, RC mode, first DBI access
tools/wifi-w1-capture --watchdog 5   # WL_REG_ON, PERST#, training, lspci
```

What each pass looks like (lines from the summary, `14520000.pcie:` /
`14550000.phy:` prefixes omitted):

- **0:** `stage 0/5: resources (stop_after=0, trace=1, use_ia=1,
  cmu_acg_off=0)`, then `stopped after stage 0 as asked`.
- **1:**
  - `enable clk gout_hsi2_pcie_gen4_1_pcie_003_...` lines;
  - `CMU_HSI2 option 0x........ (automatic gating on|off)`, plus 8 + 2 dump
    lines. Write down the option value and the dump: they record ABL's gate
    state, which we never had;
  - `stage 1 done`.
- **2:**
  - `trace: about to set PMU 0x3ec4 bit 0 (PHY isolation off, SMC)`;
  - `about to read PMA 0x400 (first PMA read)`, then `about to read PCS 0x184`;
  - `PHY out of isolation and powered down`;
  - `about to write ELBI 0x010-0x018 (first ELBI access ...)`;
  - `ELBI QCH_SEL 0x... SOFT_RESET 0x... DEVICE_TYPE 0x...`;
  - `stage 2 done`.

  The UFS check prints a `dd` line.
- **3:**
  - `PLL lock 1, CDR lock 0|1, OC done 1 (...)`. CDR may be 0: there is no
    partner, WL_REG_ON is off below stage 5;
  - possibly `PMA 0x.. after reset: ... (expected ...)` lines (Google's
    self-check; note them, not fatal);
  - `about to program the I/A sequencer`, then `stage 3 done`.
- **4:**
  - `DBI ID 0x........`: a Samsung or Synopsys ID, **not 0xffffffff**;
  - `DWC version 0x........`;
  - possibly `OC not done after soft power reset: ...`;
  - `D-state 0, LTSSM 0x0`, then `stage 4 done`.
- **5:**
  - `about to power the endpoint (WL_REG_ON, gph2-4, 200 ms)`;
  - `link try 1: ...`, then `link up on try 1`;
  - the DWC core's `PCIe Gen.2 x1 link up` line;
  - `lspci -nn` shows `00:00.0 [144d:eced]` and `01:00.0 [14e4:4441]`.

  Then continue with W2 (7.6).

**Reading a hang.**
- The log's last `trace: about to ...` line names the access that never
  completed. Lines are ordered and carry the laptop's receive time, so a gap
  of more than about 1 s before the end means the phone died during that
  step.
- With `--watchdog` the phone resets itself in about 15 s. Then run
  `tools/wifi-w1-capture --pstore`; the `console-ramoops-0` file should end
  at the same line.
- What to do next, by the last line:

| Last line | Meaning | Next try (one more reset at most) |
|---|---|---|
| `about to set PMU 0x3ec4 bit 0` (stage 2) | the SMC itself stalled, which is unexpected | report; check the SMC path with a known register (reboot-mode's 0x810 works) |
| `PMU write failed: -22` (stage 2, no hang) | EL3 refused the atomic set-bits form | add a TENSOR_PMUREG_RMW path for this register (Google uses `rmw_priv_reg`), no phone risk |
| `about to read PMA 0x400` or `PCS 0x184` (stage 2) | PHY APB clock gated | rerun stage 2 with `--cmu-acg-off` |
| `about to write/read ELBI ...` (stage 2) | isolation release did not take, or the APB clock is gated | `--cmu-acg-off`; if it still hangs, compare the gate dump from stage 1 with stock |
| `about to poll PMA ...` (stage 3) | should not hang (pure reads after successful ones) | `--ia 0`, `--tcxo` |
| `about to program the I/A sequencer` (stage 3) | I/A misbehaves | `--ia 0` |
| `about to read DBI 0x000 ...` (stage 4) | the DWC core is not clocked (no pipe/core clock) | `--cmu-acg-off`; check `PLL lock 1` in stage 3 |
| `link try N ...` (stage 5) | hang during training (should be impossible) | `--ia 0` |

**Rollback:**
- A hang: a Power hold of about 30 s (or the watchdog). ABL then boots
  slot B again, or slot A after its retries.
- To return to the main kernel: unset `KERNEL_DIR`/`KERNEL_OUT`, then run
  `bin/omandroid modules-push && bin/omandroid push`. That pushes
  `~/android/mainline/out`, which has no PCIe at all.
- To keep `out-pcie` but turn PCIe off: `cp "$D.default" "$D"`, then
  `bin/omandroid images && bin/omandroid push`.

### 8.5 Still open

- **L1.2 teardown.** A link torn down while in L1.2 can make the next
  bring-up hang in training: leave L1, send PME_Turn_Off and reach L2 before
  PERST#. We have no L1 substates yet, so this cannot bite at W1. It
  matters before ASPM/L1SS or runtime suspend.
- **brcmfmac for this chip likely needs more than 1.6 lists**, on top of the
  Pixel 6 work:
  - H2D sequence numbers (otherwise an "h2d livelock" trap);
  - ring indices in host memory;
  - XOR-checksum D2H sync;
  - the v1 join parameters;
  - the host builds the 802.3/LLC header;
  - packet ID 0 never used;
  - reused ring slots cleared;
  - **all four save/restore power domains requested through ChipCommon
    `powerctl` after every reset** (otherwise the backplane faults from a
    cold boot).

  Our firmware is 20.101.90. Plan W2 with this list. **Done for W2 in
  section 9** (sequence numbers, packet ID 0, slot clearing, power domains;
  host-memory indices were already in brcmfmac); the rest is for W3.
- **S2MPU (W4).** Reportedly, touching any
  S2MPU register other than CTRL0 reset the SoC, and S2MPUs come back with
  CTRL0 = 1 after a power-domain cycle. Reading CTRL0 (W1.1) stays fine.
  Revisit W4 (EL1 S2MPU programming) with this in mind.
- **pstore and `quiet`.** The capture tool raises the console level at run
  time. To keep boot-time messages in pstore as well, `quiet` would have to
  leave the DT bootargs. Not done, because it is a user-visible boot change.

---

## 9. W2 on the phone: "Invalid shared RAM address 0xffffffff", the cause and the fixes (2026-10-12)

`L` = upstream brcmfmac as of `4487813cb` (before the fixes),
`W` = Google's `private/google-modules/wlan/bcm4389/`, `R` = the stock
captures. Log: `logs/w2-brcmfmac-20261012-0016.log` (W1 link log:
`logs/wifi-w1-20261012-001501-s5.log`).

### 9.1 What happened

W1 passed: Gen.2 x1 on try 1, `01:00.0 [14e4:4441]` rev 03, BAR0 64K,
BAR2 4M, and brcmfmac took the restricted DMA pool. Then `modprobe
brcmfmac`:

```
brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac4389c1-pcie for chip BCM4389/3
brcmfmac 0000:01:00.0: brcmf_pcie_download_fw_nvram: Invalid shared RAM address 0xffffffff
brcmfmac 0000:01:00.0: brcmf_pcie_setup: Dongle setup failed
ieee80211 phy0: brcmf_fw_crashed: Firmware has halted or crashed
WARNING: kernel/workqueue.c:4409 at __flush_work+0x27c/0x2a4
 ... brcmf_bus_cancel_reset_work <- brcmf_pcie_remove <- brcmf_pcie_setup
```

The failure line came 390 ms after the firmware request, download
included, so on one of the first 50 ms polls: the word at what brcmfmac
took for the top of RAM changed to 0xffffffff once the ARM ran. The phone rebooted about
5 minutes later; the log stream (still running) ends with `sd ...:
Synchronizing SCSI cache`, an orderly kernel restart, not a watchdog bite
(a bite prints nothing). The capture tool's disarm was fragile anyway and
its log stream leaked; both are fixed (9.3).

### 9.2 Cause: brcmfmac sized the RAM at 256 KiB instead of 2688 KiB

| | brcmfmac (`L`) | Broadcom/Google (`W`, `R`) |
|---|---|---|
| SYSMEM coreinfo decode | SOCRAM layout: banks = bits 7:4 (`L/.../chip.c:158-160,669`), banks counted from index 0 (`chip.c:672`) | RAM banks = bits 4:0, ROM banks = bits 9:5 (bits 23:16 / 31:24 from core rev 12), RAM banks start after the ROM banks (`W/siutils.c:7045-7057`, `W/include/sbsysmem.h:115-123`) |
| BCM4389 coreinfo 0x115 | 1 bank, and it is ROM bank 0 | 8 ROM + 21 RAM banks of 128 KiB (`R/dmesg.txt:5468-5490`) |
| RAM | 0x200000 + **0x40000** | 0x200000 + **0x2a0000** = 2752512 (`R/dmesg.txt:5490`; base `W/dhd_pcie.c:2336-2349`, `W/include/sbchipc.h:4245`) |

Evidence from our own failure: the WARNING's register dump (callee-saved
registers left by the inlined download code) holds `x24 = 0xe8b4174b`, the
NVRAM length token (stock prints the same token, `R/dmesg.txt:6986`), and
`x26 = 0x23a2d0` = 0x240000 - 23856, the NVRAM address for a 256 KiB RAM.
So brcmfmac wrote the NVRAM, the random seed and the "top of RAM"
handshake word (`L/.../pcie.c:1722-1744`) at 0x23a1c8-0x23ffff, inside the
1.7 MB firmware image it had just copied to 0x200000 (code and data run to
0x3ae944, `_end` in `fw_bcmdhd.map`). The firmware started on corrupted code and died, and the
read of 0x23fffc returned 0xffffffff (`L/.../pcie.c:1779`). Nothing in the
PCIe link or the DMA pool was at fault.

Two more defects sit right behind it, and would have failed the next try:

- **The RAM does not fit the BAR.** With the right size, RAM ends at
  0x49ffff, but brcmfmac maps BAR2 (4 MiB) 1:1 from backplane address 0
  (`L/.../pcie.c:568-578,1818`), so the NVRAM, the seed and the handshake
  word would land past its ioremap(). bcmdhd moves the BAR1 window (PCI
  config 0x84) for every access (`W/dhd_pcie.c:6143-6260,2458`,
  `W/include/pcicfg.h:489`) and resets it to 0 before the download
  (`W/dhd_pcie.c:10105`); stock writes the seed at 0x49a248
  (`R/dmesg.txt:6987`).
- **Power domains.** bcmdhd treats the 4389 as a multi-backplane chip
  (`W/include/siutils.h:963-969`): it requests all four save/restore
  domains (PCIe, ARM/backplane, MAC aux, MAC main) in the PCIe core's
  `powerctl` (BAR0 + 0x2000 + 0x1e8, request bits 11:8, status 19:16)
  before a reset (`W/dhd_pcie.c:832-857,2778`, PCIe core rev 72 is in
  `W/dhd_pcie.h:153-155`, `R/dmesg.txt:6988`), and asserts the ARM domain
  in the DAR copy (0xa0c) because "ARM fails to boot" from cold without it
  (`W/dhd_pcie.c:735-748,2505-2513`). It also sets the CA7's BAR
  coherent-access bits, config 0x88 bits 9:8 (`W/dhd_pcie.c:2219-2223`).
  brcmfmac does none of this. A warm chip can hide it.

And three protocol details, needed once the firmware runs:

- **H2D sequence numbers.** bcmdhd puts `seqnum % 253` (seqnum from 254) in
  the `epoch` byte of every message on the control and rxpost submit rings
  (`W/include/bcmmsgbuf.h:38-39`, `W/dhd_msgbuf.c:1816-1824,5900,10883`);
  brcmfmac leaves it 0. The 20.101.90 image contains the trap string
  "h2d livelock error".
- **Packet ID 0** is "invalid" to bcmdhd and never used
  (`W/dhd_msgbuf.c:2278,2760,2901`); brcmfmac hands it out after a wrap.
- **Stale slot bytes.** brcmfmac fills ioctl and flow-ring create/delete
  messages field by field on reused slots; with the epoch byte now
  meaningful, the slots are cleared first (buffer posts already were).

The WARNING is a plain brcmfmac bug: `drvr->bus_reset` is only
`INIT_WORK`ed in `brcmf_bus_started()` (`L/.../core.c:1303`), but the
remove path that the failed setup triggers cancels it unconditionally
(`core.c:1190`).

### 9.3 What changed (all offline)

Kernel, branch `omandroid-pcie` in `wt-pcie`, one upstream-style commit each:

| Commit | Change |
|---|---|
| `eaa318f86` wifi: brcmfmac: chip: size the BCM4389 SYSMEM from its RAM banks | bcmdhd's coreinfo decode for the 4389 (both layouts), ROM banks skipped; logs `SYSMEM rev N coreinfo 0x...: R ROM, N RAM banks` at debug INFO. Other SYSMEM chips unchanged |
| `f43633f62` wifi: brcmfmac: pcie: move the BAR1 window for RAM beyond the BAR | every TCM access goes through one helper; when RAM ends beyond the BAR the window (config 0x84) moves under a spinlock; block copies split at window edges and into 4 KiB pieces; window reset before download and after reset. No change for chips whose RAM fits |
| `dc88c3c73` wifi: brcmfmac: pcie: request the BCM4389 power domains after reset | for 14e4:4441 only: request all four domains (+ DAR ARM domain) once the BARs are mapped, before and after the watchdog reset; set the BAR coherent bits. The requests stay on while bound (idle power, to release later) |
| `a8d467176` wifi: brcmfmac: msgbuf: put sequence numbers in H2D control messages | epoch on control + rxpost submit messages, set when a message is final; ioctl and flow-ring create/delete slots cleared first |
| `2766d0ecf` wifi: brcmfmac: msgbuf: never use packet ID 0 | |
| `2733238b7` wifi: brcmfmac: don't cancel the bus reset work before it exists | the WARNING |

All build clean with `W=1`. Config: `CONFIG_BRCMDBG=y` (brcmfmac's debug
messages, off unless `debug=` is set). Builds: `logs/kernel-w2fix.log`,
`modules-w2fix.log`, `images-w2fix.log` (out-pcie, both overlays re-applied,
plain DTB in `.default`).

`tools/wifi-w1-capture`:

- the watchdog feeder runs in its own session (`setsid`), writes the magic
  'V' and closes `/dev/watchdog0` on TERM/INT/HUP at once (no waiting for
  `sleep`), and disarms itself after `--wait` + 120 s at the latest;
- the end of the run, Ctrl-C, or any exit disarms: stop the feeder, wait
  until it is gone, then `printf V > /dev/watchdog0` (open + magic close),
  and check dmesg for "watchdog did not stop". `--disarm` does only that;
- the log stream's ssh is now killed with the rest of the pipeline (it used
  to outlive the run);
- `--brcmfmac` (stage 5 only): load brcmfmac with `debug=0x80004` (PCIe +
  INFO) on the fresh link, under the same watchdog and capture, and wait for
  `Firmware: BCM4389` or a failure line.

Not done here (W3 or later): D2H XOR-checksum verification (the firmware
uses it, `R/dmesg.txt:7120`; brcmfmac relies on PCIe write ordering, fine
with DMA'd indices), the v1 join parameters and the host-built 802.3/LLC TX
header (association and data, not scan), in-band device wake, releasing
the power requests once the firmware runs, and the ABL MAC address (1.6).

### 9.4 W2 runbook (on the phone; each step has its rollback)

From the omandroid repo, phone in Arch over USB.

```sh
export KERNEL_DIR=$HOME/android/mainline/wt-pcie KERNEL_OUT=$HOME/android/mainline/out-pcie

# W2.0  new kernel + modules (out-pcie, DTB already has both test overlays)
bin/omandroid modules-push && bin/omandroid push          # slot B, reboots
tools/phone-ssh 'uname -r; ls /usr/lib/firmware/updates/brcm/ | grep 4389c1;
  grep -H . /usr/lib/modprobe.d/omandroid-wifi.conf; dmesg | grep "restricted DMA pool"'
#   pass: release 7.3.0-rc6-omandroid-push1-00068-g2733238b74d0; .bin .txt .clm_blob present;
#         blacklist lists pcie_gs201 and brcmfmac; "created restricted DMA pool ... 16 MiB"
#   rollback: unset KERNEL_DIR KERNEL_OUT; bin/omandroid modules-push && bin/omandroid push

# W2.1  link + brcmfmac in one run, watchdog armed, every line on the laptop
tools/wifi-w1-capture --watchdog --wait 40 --brcmfmac 5
#   (the summary prints the brcmf lines; the full log is logs/wifi-w1-<time>-s5.log)
#   rollback: tools/phone-ssh 'modprobe -r brcmfmac; modprobe -r pcie_gs201'
#   if the phone hangs: the watchdog resets it in ~15 s; then tools/wifi-w1-capture --pstore
#   if the run is interrupted: tools/wifi-w1-capture --disarm
```

W2.1 lines, in order (`brcmfmac: ` prefix and `0000:01:00.0` omitted):

| Line | Pass | If not |
|---|---|---|
| W1 lines up to `link up on try 1`, `PCIe Gen.2 x1 link up` | as W1 | W1 regressed: stop, compare with `logs/wifi-w1-20261012-001501-s5.log` |
| `assigned reserved memory node wifi-dma-pool` | present | DTB lost the overlay (9.5 rollback, re-apply) |
| `brcmf_pcie_srpwr_request power domains up, powerctl 0x...` | `value & 0x000f0f00 == 0x000f0f00` (request and status bits for all four; the top nibble is the domain ID) | `power domains not up, powerctl 0x...`: note the value; continue, it may still load. `power control reads 0xffffffff`: the chip is not answering on BAR0: stop |
| `brcmf_chip_sysmem_ramsize SYSMEM rev N coreinfo 0x00000115: 8 ROM, 21 RAM banks` | exactly 8 and 21 | other coreinfo: write it down, stop (decode is wrong for this rev) |
| `brcmf_chip_get_raminfo RAM: base=0x200000 size=2752512 (0x2a0000)` | 2752512 | anything else: stop |
| `brcmf_pcie_tcm_win_setup RAM 0x200000-0x49ffff does not fit the 4096 KiB BAR, moving its window` | present | missing: the window code is off, the NVRAM goes past the BAR: stop |
| `using brcm/brcmfmac4389c1-pcie for chip BCM4389/3` | rev 3 | |
| `Download FW brcm/brcmfmac4389c1-pcie.google,gs201-cheetah.bin`, `Download NVRAM ...txt`, `Download random seed`, `Bring ARM in running state`, `Wait for FW init` | all | no NVRAM line: the .txt is missing |
| `Shared RAM addr: 0x003eabf0` | about 0.6 s after "Wait for FW init"; stock had 0x3eabf0 (`R/dmesg.txt:7100`) | `FW failed to initialize` (5 s): the firmware never came up, look at the console lines (`brcmf_pcie_bus_console_read`) just before; `Invalid shared RAM address 0x...`: write the value down |
| `PCIe protocol version 7` | 5-7 | `Unsupported PCIE version 8/9`: see 1.6 |
| `Using host memory indices`, `max rx buf post ...` | present | "Using TCM indices" also works, just slower |
| `brcmf_c_preinit_dcmds: Firmware: BCM4389/3 wl0: ... version 20.101.90 (wlan=r1098710 c1 release2) FWID 01-3f632e0d` | present | a trap or `h2d livelock error` in the console: the epoch fix is not enough, keep the log |
| `CLM version = Google.C10sub6` | present | `no clm_blob available`: the .clm_blob name is wrong (1.6) |
| no `WARNING`, no `Firmware has halted` | | |

```sh
# W2.2  the interface
tools/phone-ssh 'iw dev; ip link show wlan0; cat /sys/kernel/debug/ieee80211/phy*/revinfo 2>/dev/null'
#   pass: "Interface wlan0", "type managed", a MAC addr; revinfo: "chip: BCM4389/3 (...)",
#         "clmver: Google.C10sub6"
#   rollback: tools/phone-ssh 'modprobe -r brcmfmac'

# W2.3  scan (no association; the MAC is whatever the chip reports, 1.6)
tools/phone-ssh 'ip link set wlan0 up && iw dev wlan0 scan | grep -E "^BSS|SSID:|signal:|freq:" | head -40'
tools/phone-ssh 'dmesg | grep -iE "brcmf.*(error|fail|trap|timeout)|livelock|halted" | tail'
#   pass: nearby networks on 2.4 and 5 GHz (6 GHz may appear), signal -30..-90 dBm;
#         the dmesg grep is empty. Run the scan twice: the second must work too.
#   rollback: tools/phone-ssh 'ip link set wlan0 down; modprobe -r brcmfmac; modprobe -r pcie_gs201'

# W2.4  unload/reload (the remove path and the power requests after reset)
tools/phone-ssh 'modprobe -r brcmfmac && sleep 1 && dmesg | tail -5 | grep -c WARNING;
  modprobe brcmfmac debug=0x80004 && sleep 8 && iw dev | grep -c wlan0'
#   pass: 0 WARNINGs, then 1 (wlan0 back on a warm chip)
#   rollback: as W2.3
```

If W2.1 hangs the phone (no reset after the watchdog either), recover with
a 30 s Power hold, then boot the default DTB (9.5).

### 9.5 Rollback

- **brcmfmac only:** `tools/phone-ssh 'modprobe -r brcmfmac'`. The chip keeps
  running until `modprobe -r pcie_gs201` drops WL_REG_ON.
- **PCIe off, same kernel:** `D=$KERNEL_OUT/arch/arm64/boot/dts/exynos/google/gs201-cheetah.dtb;
  cp "$D.default" "$D"; bin/omandroid images && bin/omandroid push`.
- **Back to the main kernel:** unset `KERNEL_DIR`/`KERNEL_OUT`, then
  `bin/omandroid modules-push && bin/omandroid push` (`~/android/mainline/out`,
  no PCIe).
- **A leftover watchdog:** `tools/wifi-w1-capture --disarm`.
- Nothing is written to the chip's OTP or to any phone partition other than
  the boot images; the firmware files stay in `/usr/lib/firmware/updates/brcm/`
  (remove with the 7.6 W2.1 rollback).
