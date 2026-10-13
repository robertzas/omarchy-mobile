<!-- SPDX-License-Identifier: MIT -->
# Camera plan (cheetah / gs201): raw capture first, then libcamera

Status (2026-10-12): **K, CAM0 (partly), CAM1, CAM2 and CAM3a passed on the
phone (the ultrawide answers as a Sony IMX386); the CAM3b-CAM5 capture
path is built offline.** Kernel branch `omandroid-camera` in `~/android/mainline/wt-camera`
(output `~/android/mainline/out-camera`); `omandroid-int` 606b84c7a already
has its first part (up to `6cb2be364`). On top, not merged yet (head
`35295a9ab`): CIS clock rounding, the DC-PHY receiver, the CSIS link + CSIS
WDMA V4L2 driver, a Sony IMX386 sensor driver and their DT, all disabled or
blacklisted. The sensor's manufacturer settings come from
`tools/extract-camera-data`, run on the user's machine; libcamera 0.7.2 with
our simple-pipeline entry is in `packages/libcamera` (not built yet). Two
facts are still unknown and are what CAM3b/CAM4 find out on the phone:
which four-lane CSIS link the ultrawide is wired to, and the WDMA input
value for a direct link-to-WDMA route (section 4.3). Nothing streams yet.

This plan replaces section 4 of `RADIOS-CAMERA-PLAN.md`, which was the
starting survey. It corrects two of its facts (section 1.7).

**Goal.** In order:

1. a raw Bayer frame from one camera, captured to a file on the phone;
2. a photo from that camera in a Linux app (libcamera `cam`, then a
   PipeWire camera app);
3. video (a live preview and a recording);
4. the other three cameras, then focus.

Claims are marked **[V]** (checked, with a source) or **[I]** (inferred, to
be checked on the phone), as CONTRIBUTING.md asks.

Path abbreviations (as in the other plans):

- `L/` = our kernel, `omandroid-int` (`~/android/mainline/wt-int`, release 7.3.0-rc6)
- `G/` = `~/android/omandroid/out-kernel/google/gs-6.1/private` (Google's GPL gs201 kernel)
- `GS/` = `G/google-modules/soc/gs`
- `GD/` = `G/devices/google` (Google's GPL device trees: `gs201/dts/gs201-isp.dtsi`, `pantah/dts/gs201-cheetah-camera.dtsi`, `pantah/dts/gs201-pantah-camera-pmic.dtsi`)
- `LW/` = `G/google-modules/lwis` (Google's GPL LWIS driver)
- `R/` = `~/android/reference/cheetah-stock-cp2a-root` (stock live DT, dmesg; private)
- `A/` = the camera HAL APEX from the user's own image, `com.google.pixel.camera.hal.apex` (private; never committed)

---

## 0. Summary and recommendation

- **Recommended path: (a), raw capture without Google's ISP.** A new V4L2
  driver for the CSIS receiver and its "CSIS WDMA" (raw Bayer straight to
  memory), a generic PHY driver for the receive side of the Samsung DC-PHY,
  one sensor driver per camera, and the camera PMIC. libcamera's *simple*
  pipeline handler with its software ISP does debayer, white balance and
  exposure. Stock itself uses this exact route (link → CSIS WDMA) for RAW
  output, so the hardware supports it without PDP, G3AA, ITP or MCSC
  (section 1.3).
- **First camera: the ultrawide** (Sony sensor, `sensor-sandworm`): standard
  Bayer, 8-bit register values (Sony layout, close to the mainline
  `imx258`/`imx319`/`imx355` drivers), believed D-PHY [I], and its EEPROM
  needs only the 1.8 V I/O rail (section 1.2).
- **What makes it hard:** the CSIS receiver and its DMA have no Linux driver
  anywhere and no GPL register description beyond interrupt bits and DT
  offsets. The rest of the register meaning (formats, DMA control bits, link
  routing) must be learned from the stock HAL with REA and written down as
  facts in our own words (section 4). Sensor mode tables come from the HAL
  too and are never committed: an extract tool generates them on the
  user's machine (section 5.3).
- **Not recommended: (b)**, porting LWIS and running the stock HAL in a
  chroot. It needs Google's gralloc, Mali kbase OpenCL (we run Panthor), the
  EdgeTPU and GXP, BTS, SLC, a SysMMU v8 driver and an Android camera client,
  and it would still need a bridge to PipeWire. LWIS is a userspace register
  pass-through that upstream will never take (section 3).
- **(c), mainline:** nothing for gs101/gs201 cameras in 7.3-rc6. The closest
  relatives are `imx-mipi-csis` (an older version of the same Samsung
  receiver: the link registers match) and `phy-rockchip-samsung-dcphy` (the
  transmit side of the same DC-PHY family). Both are useful references; no
  code can be reused as is (section 3).
- **Timeline:** about 8-12 weeks of focused work to a photo from the
  ultrawide in `cam`, about 2-3 more for video, and 4-6 months to all four
  cameras with focus (section 6). The C-PHY cameras (main and tele, if the
  survey is right) carry most of the schedule risk.

---

## 1. Hardware facts

### 1.1 The four cameras

| Camera | LWIS node | Sensor | I2C bus (base), addr | Reg width (addr/val) | Reset | MCLK (clock, pad, rate) |
|---|---|---|---|---|---|---|
| Main | `sensor-nagual` | Samsung GN1, 50 MP [I] | `hsi2c_1` (`0x10900000`), `0x3d` | 16/16 | gpp2-2 | `CIS_CLK3`, gpp9-0 (`sensor_mclk4`), 26 MHz |
| Front | `sensor-dokkaebi` | Samsung 3J1 [I] | `hsi2c_2` (`0x10910000`), `0x10` | 16/16 | gpp4-2 | `CIS_CLK1`, gpp5-0 (`sensor_mclk2`), 24 MHz |
| Ultrawide | `sensor-sandworm` | Sony IMX386 [V: model ID 0x0386 read on the phone, CAM3a] | `hsi2c_3` (`0x10920000`), `0x1a` | 16/8 | gpp6-3 | `CIS_CLK0`, gpp3-0 (`sensor_mclk1`), 24 MHz |
| Tele | `sensor-kraken` | Samsung GM5 [I] | `hsi2c_4` (`0x10930000`), `0x2d` | 16/16 | gpp6-2 | `CIS_CLK2`, gpp7-0 (`sensor_mclk3`), 24 MHz |

Evidence **[V]**: `GD/pantah/dts/gs201-cheetah-camera.dtsi` (nodes "REAR
CAMERA NAGUAL", "FRONT CAMERA DOKKAEBI", "REAR ULTRA WIDE CAMERA SANDWORM",
"REAR Folded Tele Camera KRAKEN"), the same in `R/live.dts:18745-18863`.
Reset lines are active high in LWIS terms (driven 1 to run). MCLK pads have
two pinctrl states: function 1 with pull-down (`mclk_off`) and function 2
(`mclk_on`).

Sensor part names come from the HAL (`vendor.camera.debug.enable_gn1_*`
properties in `A/lib64/liblyric_hwl.so`) and from public teardowns; only GN1
has a string in the HAL. **The CAM3a chip-ID reads settle them** (Sony model
ID at `0x0016`, Samsung at `0x0000`). The value width already splits them:
the ultrawide answers with 8-bit values (Sony style), the other three with
16-bit (Samsung style).

Each bus also carries the module's other parts **[V]** (`R/live.dts:18865-19100`):

| Bus | Parts besides the sensor |
|---|---|
| `hsi2c_1` | `eeprom-gargoyle`/`ois-gargoyle` at `0x24` (32-bit values: an OIS controller holding the module EEPROM), AF actuator `act-slenderman` at `0x0c`, the laser AF `stmvl53l1` at `0x29` |
| `hsi2c_2` | EEPROM `smaug-dokkaebi` at `0x51` (front is fixed focus: no actuator) |
| `hsi2c_3` | EEPROM `smaug-sandworm` at `0x50`, AF actuator `act-slenderman-sandworm` at `0x0f` (the ultrawide focuses, for macro) |
| `hsi2c_4` | `jotnar` at `0x34`: one controller for the tele's EEPROM, OIS and AF |

The flash (LM3644 on `hsi2c_15`, `0x63`) already works as the torch
(`HAPTICS-TORCH-PLAN.md`).

### 1.2 Power

Three layers **[V]** (`GD/pantah/dts/gs201-pantah-camera-pmic.dtsi:15-70`,
`R/live.dts:7938-8050, 14105-14113, 18709-18745`):

1. **S2MPG13 (sub-PMIC, over ACPM)**
   - `LDO12S` = `L12S_CAMIO`, 1.8 V: camera I/O for every sensor, EEPROM,
     actuator and the laser AF. Control register PM `0x37`, enable bit 7.
     Our `s2mps11.c` already describes it (`regulator_desc_s2mpg13_ldo_own(12, ...)`),
     but `pmic-2` in our DT doesn't list it yet.
   - S2MPG13 **GPIO 1** enables `PP3200_BB_CAM` (3.2 V fixed regulator,
     2 ms ramp); **GPIO 3** enables `PP1300_CAM` (1.3 V); **GPIO 0** is the
     SLG51002's chip select. The GPIOs live in the PMIC's GPIO bank (ACPM
     type `0x0c`): `GPIO_STATUS` `0x04`, `GPIO_n_SET` `0x05 + n`, with
     bit 5 = output level and bit 6 = output enable
     (`GS/include/linux/mfd/samsung/s2mpg13-register.h:380-395`,
     `GS/drivers/mfd/s2mpg1x-gpio-gs201.c`). We have no driver for this bank.
2. **SLG51002 camera PMIC** on `hsi2c_8` (`0x10970000`, the bus the
   haptics already use), address `0x75`. Eight LDOs and four GPIO switches.
   Its chip select (S2MPG13 GPIO 0) wakes it from a low-power reset; the
   datasheet time to ready is about 10 ms (Google's driver comment). Chip ID
   at `0x1105-0x1107`, 16-bit register addresses (`GS/drivers/mfd/slg51002-core.c:487-505, 570`).
   Mainline has only the different `slg51000`.

   | SLG output | Voltage | Supply | Used by |
   |---|---|---|---|
   | LDO1 | 2.85 V | PP3200_BB | main sensor |
   | LDO2 | 2.85 V | PP3200_BB | ultrawide sensor |
   | LDO3 | 2.25 V | PP3200_BB | tele sensor |
   | LDO4 | 2.9 V | PP3200_BB | main sensor, main AF, ultrawide AF |
   | LDO5 | 2.85 V | PP3200_BB | tele EEPROM/OIS/AF |
   | LDO6 | 1.1 V | PP1300 | ultrawide sensor |
   | LDO7 | 1.0 V | PP1300 | tele sensor |
   | LDO8 | 1.1 V | PP1300 | main and front sensors |
   | GPIO1 | switch | | main OIS/EEPROM, tele EEPROM/OIS/AF |
   | GPIO2 | switch | | main OIS |
   | GPIO3 | switch | | main sensor |
   | GPIO4 | switch | | front sensor |

3. **Power-up order** (stock LWIS sequences, `R/live.dts:18758-18860`):
   - Ultrawide: PP3200_BB, PP1300, LDO12S, LDO6, LDO2, 1 ms, MCLK on, 1 ms, reset high, 10 ms.
   - Front: PP3200_BB, PP1300, LDO12S, LDO8, GPIO4, 1 ms, MCLK on, 1 ms, reset high, 8 ms.
   - Tele: PP3200_BB, PP1300, LDO12S (0.3 ms), LDO7, LDO3, MCLK on, 1 ms, reset high, 10 ms.
   - Main: PP3200_BB, PP1300, LDO12S, LDO4 (1 ms), GPIO3, LDO8, LDO1 (2 ms), reset high (1 ms), MCLK on, 9 ms. The main sensor takes reset *before* MCLK.
   - Power-down is the reverse, reset low first (main: MCLK off first).
   - The two **EEPROMs `smaug-*` need only LDO12S** (1 ms). That makes them
     the first thing we can talk to: one rail, no MCLK, no reset (CAM2.3).

Stock writes "revision AA" trim values into the SLG51002 by entering a
software test mode (`slg51002-core.c:170-190, 265-300`). **Cheetah's part is
revision AB** [V]: stock's log reads `slg51002 8-0075: chip_id: 0xb13103`
(`R/dmesg.txt`), which Google's header names `REVISION_AB`, and the cheetah
DT has no `dlg,reg-init`, so stock writes nothing in test mode on this phone
(its probe only enters and leaves it). Our driver never enters test mode;
on an AA part it would register the LDOs only and say so.

### 1.3 The capture path: CSIS, its DMA and the PHYs

All **[V]** from `GD/gs201/dts/gs201-isp.dtsi` (= `R/live.dts:10858-10994`)
unless marked.

```
sensor ──MIPI──> DC-PHY slave n ──> CSIS link n ──┬──> CSIS WDMA ctx 0-3 ──> DRAM   (our path)
 (I2C ctl)       0x1a4f0000         0x1a44n000    ├──> EBUF ──> PDP/IPP ... (Google ISP, OTF)
                                                  └──> ZSL / STRP DMA ──> DRAM
                       all behind sysmmu_csis0/1 + s2mpu_csis0/1, in pd-csis
```

- **CSIS links 0-7** at `0x1a440000 + n * 0x10000` (4 KiB each). One GIC SPI
  per link, SPI 189-196, shared by four sources: INT0 (errors), INT1
  (frame start/end, line end, lost FS/FE, resolution mismatch), FS and FE
  (per virtual channel). Mask/source pairs at `0x10/0x14`, `0x18/0x1c`,
  `0x20/0x24`, `0x28/0x2c` (the `csi-event-info` nodes). The bit names are
  in `GS/include/dt-bindings/lwis/platform/gs201/csi.h` (4333 lines, GPL):
  INT0 has ERR_ID, CRC, ECC, WRONG_CONFIG, OVER, CRC_PH, MAL_CRC, then per
  lane invalid-code (12-15), SOT (16-19) and SOT-sync (20-23) errors.
- **The link is a newer version of the receiver in mainline's
  `imx-mipi-csis.c`.** Version at `0x00`, common control at `0x04`, the
  interrupt mask/source at `0x10/0x14`, and per-channel `ISP_CONFIG` at
  `0x40 + 0x10 * ch` and `ISP_RESOL` at `0x44 + 0x10 * ch` sit at the same
  offsets as in `L/drivers/media/platform/nxp/imx-mipi-csis.c:52-200`; the
  INT0 error bits line up too. The D-PHY control that lives inside the
  i.MX receiver is a separate DC-PHY block here. [V] for the offsets
  (gs201 from the DT and the HAL's register table, section 4.1); [I] that
  the bit fields inside them match.
- **CSIS DMA** at `0x1a4d0000` (64 KiB): three DMA families,
  each context with its interrupt mask/source at `+0x404/+0x408` of its
  4 KiB block:
  - ZSL WDMA contexts 0-2 at `0x1000-0x3000` (SPI 234-236);
  - STRP WDMA contexts 0-2 at `0x4000-0x6000` (SPI 217-219);
  - **CSIS WDMA contexts 0-3 at `0x7000-0xa000`** (SPI 197-200). Interrupt
    bits per context: line end, frame start and frame end for channels 0-3,
    FIFO full, last-data and last-address errors, abort done, overlap and
    frame drop per channel (`csi.h:3944-4031`).
- **EBUF** at `0x1a4c0000` (SPI 201-204): a buffer between the links and the
  ISP's on-the-fly path; it has a fake-frame generator. Not on our path [I].
- **The HAL names the route** in its log line
  "Camera ID, CSIS LINK, CSIS EBUF, WDMA INPUT, CSIS WDMA, PDP WDMA, ZSL WDMA, ..."
  and refuses a RAW output unless the usage includes "csis wdma"
  (`A/lib64/liblyric_hwl.so` strings). So stock's own RAW capture goes link →
  CSIS WDMA → memory, the route we want. [V] that the route exists; [I]
  how the link-to-WDMA routing is programmed (a common register in the DMA
  block's first page, section 4.1).
- **DC-PHY** `samsung,mipi-phy-m0s4s4s4s4s4`: no master, five 4-lane slave
  groups. Per-link PHY register windows:
  - link 0 at `0x1a4f1300` and link 1 at `0x1a4f1b00` (`0x500`: clock lane +
    four data lanes, `0x100` each): full 4-lane PHYs;
  - links 2-7 at `0x2300, 0x2600, 0x2b00, 0x2e00, 0x3300, 0x3600`
    (`0x300`: 2-lane). Pairs (2,3), (4,5), (6,7) combine into one 4-lane
    group; the odd member has its clock lane after its two data lanes
    (the HAL's register table puts the clock-lane `GNR_CON0` of PHYs 3, 5, 7 at
    `+0x200`), which is the GPL driver's "2lane, Data lane first" variant;
  - a shared bias block at `0x1a4f1000` (`M_BIAS_CON0-2`);
  - one PMU isolation bit for all of them at PMU `0x3ebc` (SMC regmap only)
    and one reset bit per PHY in `0x1a420500` (`samsung,reset-sysreg`, bits 0-7).
- **GPL D-PHY receive settings exist** for this PHY version (`0x0504`):
  `GS/drivers/phy/samsung/phy-exynos-mipi.c:516-770`, three variants (4-lane,
  2-lane, 2-lane data-first): per-lane `GNR_CON0/1`, `ANA_CON2/3/7`,
  `TIME_CON0/1` (settle count, settle clock select), `DESKEW_CON0/4`, and
  skew-delay selection by rate (1.5-6.5 Gbps). **The C-PHY branch is
  `/* TODO */`** (`:594, 680, 765`). LWIS only powers the PHY on and off
  (`LW/lwis_phy.c:120-160`); the HAL writes the lane settings itself through
  the `csis-phy` register space. So stock's values may differ from the GPL
  ones; that is a first thing to check if a link shows SOT errors.
- **Mainline relative for the PHY:** `L/drivers/phy/rockchip/phy-rockchip-samsung-dcphy.c`
  drives the *master* (transmit, D-PHY only) side of the same family: the
  same per-lane `GNR/ANA/TIME/DESKEW` layout and `0x100` lane stride, and
  "CPHY part to be implemented later". Useful to name the fields.
- **IOMMU and firewall:** `sysmmu_csis0` (`0x1a510000`, SPI 220/221) and
  `sysmmu_csis1` (`0x1a540000`, SPI 231/232) are Samsung SysMMU v8, which
  mainline's `exynos-iommu.c` doesn't support. `s2mpu_csis0/1`
  (`0x1a520000`, `0x1a550000`) are programmed by pKVM on stock; we don't run
  pKVM. Plan: SysMMU in bypass and physically contiguous buffers below
  4 GiB from a dedicated reserved pool [I: that the SysMMU is in bypass and
  the S2MPU allows all after ABL, as `s2mpu_hsi0` does (`WIFI-BATTERY-PLAN.md` 1.5)].
  `samsung,tzmp` on the CSIS node is for secure (face-unlock) buffers, not
  the normal path [I].

### 1.4 Power domains, clocks and DVFS

- **`pd-csis`** at PMU `0x18062400` (`CONFIGURATION` `+0x0`, `STATUS`
  `+0x4`), CMU_CSIS at `0x1a400000`, a DTZPC restore/save SMC with id
  `0x1a410204` around each power cycle (`R/live.dts:7343-7352`,
  `GS/drivers/soc/google/cal-if/pmucal_local.c:52-61, 122-130`,
  `GS/drivers/soc/google/cal-if/gs201/flexpmu_cal_local_gs201.h:907-934`).
  The `lwis_csi` node itself declares `pd-pdp` (`0x18062480`, no parent
  domain), while the CSIS SysMMUs and S2MPUs declare `pd-csis`
  (`GD/gs201/dts/gs201-isp.dtsi`, `gs201-sysmmu.dtsi:96,127`,
  `gs201-s2mpu.dtsi:40,47`), so stock holds both on while capturing.
- **ABL leaves every camera domain on.** Stock's `exynos-pd` reads the real
  status at probe and logs it: `pd-csis`, `pd-pdp`, `pd-g3aa`, `pd-ipp`,
  `pd-itp`, `pd-dns`, `pd-mcsc`, `pd-gdc`, `pd-tnr`, `pd-tpu` and `pd-aur`
  are all "on" at 0.30 s, and stock turns most of them off at `sync_state`
  (`R/dmesg.txt`, `GS/drivers/soc/google/exynos-pd.c:443-485`). Our DTB
  boots with `clk_ignore_unused pd_ignore_unused` and we have no gs201 PD
  driver, so **on our kernel these domains should still be on** [I: CAM1.1
  confirms it through the kernel's PMU regmap]. Two consequences:
  - CSIS registers are reachable without a power-domain driver, as long
    as nothing cycles the domain. We start there and leave the PD driver
    for later.
  - Today the phone spends power on an idle ISP. That belongs in
    `POWER-PLAN.md` once confirmed.
- **Clocks:** our `clk-gs201.c` already registers CMU_TOP's `CIS_CLK0-7`
  mux/divider/gate and `CSIS_NOC` (`L/drivers/clk/samsung/clk-gs201.c:103-117, 173-185, 258-271`).
  No CMU_CSIS driver yet; its Q-channels gate on their own.
- **DVFS:** CAM (ACPM DVFS index 10), INTCAM (8) and TNR (9) boot at their
  lowest level, 67 MHz (`ACPM-PLAN.md` section 2; stock devfreq tables
  67-664 MHz in `R/dmesg.txt`). The CSIS clock comes from these domains [I].
  A 12 MP RAW10 stream at 30 fps is about 450 MB/s; the first stages run
  binned or slow modes, and real frame rates wait for ACPM DVFS
  (`omandroid-acpm`, built, not yet run).
- **Bus QoS (BTS):** stock registers the scenario `camera_default`. Without
  it, display and camera DMA share the bus unmanaged; watch for WDMA
  `FIFO_FULL` and link `ERR_OVER` [I].

### 1.5 Firmware

- **Path (a) needs no firmware blob.** The sensors, CSIS and DMA are plain
  registers; LWIS loads nothing. What we need from the user's image is
  *data*: sensor mode register tables and, later, C-PHY settings
  (section 5.3).
- The OIS controllers (`gargoyle`, `jotnar`) may need firmware the HAL
  carries [I]; not needed for a photo.
- Only the HAL's extras use firmware: the GXP DSP (`gxp_fw_core0-3` in
  `/vendor/firmware`), the EdgeTPU. Not on our path.

### 1.6 Calibration and identifying data

- Each module EEPROM holds factory calibration (lens shading, white balance,
  PDAF, OIS) that is **unique to this phone**. We read it, never write it,
  and **never commit it**: the dumps stay in `~/android/reference/`.
- The HAL also reads per-phone camera calibration from `persist`
  (`/mnt/vendor/persist/camera/...`: multi-camera calibration, a tele module
  file, flash white balance). **Nothing writes `persist`.** If we ever use
  those files, we read them from the read-only partition backup.
- The HAL's tuning files (`A/etc/camera/*.binarypb`, the per-sensor
  `*_golden_sensor_factory_calibration_data.binarypb`) are Google's data:
  never committed, and our own tuning for libcamera starts from scratch.

### 1.7 Corrections to RADIOS-CAMERA-PLAN.md section 4

- **The `0x50` EEPROM on `hsi2c_15` is not a camera EEPROM.** It is an
  `at,24c08` next to the wireless charger (`idt,p9412` at `0x3c`) on the
  same bus (`R/live.dts:8408-8450`); the camera EEPROMs are on the sensor
  buses (section 1.1). Drop C0.2 of the old runbook: that EEPROM may
  hold identifiers.
- **The camera domains are on after ABL**, so `pd-csis` doesn't block the
  first CSIS stages (section 1.4).

---

## 2. Linux state

| Piece | Mainline 7.3-rc6 | Ours | Needed |
|---|---|---|---|
| `hsi2c_1-4` (PERIC0 USI1-4) | driver yes | `hsi2c_3` (USI3, sysreg `0x1008`, SPI 676) built, disabled; 1, 2, 4 not yet | DT: USI1-4 with `samsung,sysreg = <&sysreg_peric0 0x1000..0x100c>` [I: from stock `usi-offset` 0-0xc and our USI8 at `0x101c`], SPI 674-677, pins gpp2/4/6/8 0-1, 1 MHz (buses 1, 4) and 950 kHz (2, 3) as stock |
| S2MPG13 LDO12S | — | descriptor in `s2mps11.c`; `ldo12s` in `pmic-2`, disabled until camera-pwr-test (built) | — |
| S2MPG13 GPIO bank | no | `gpio` regmap (ACPM type `0x0c`) in `sec-acpm.c`, `gpio-s2mpg13` (built, blacklisted) | — |
| SLG51002 | no (`slg51000` only) | `slg51002-regulator` (built, blacklisted): LDO1-8 and the four switches, no test mode, no IRQ | GPIO/pinctrl part not needed |
| CIS_CLK0-7 | — | in `clk-gs201.c` | DT consumers |
| DC-PHY RX | no | no | new generic PHY driver (D-PHY first) |
| CSIS link + WDMA | no | no | new V4L2 driver |
| Sensors | none of the four | — | IMX386 [I] first (or `ccs` + static data, section 5.3), then 3J1, GM5, GN1 |
| AF actuators | `ak7375`-style drivers exist | — | identify `0x0c`/`0x0f` parts by ID register |
| SysMMU v8 | no | no | bypass for now |
| PD driver | no | no | later (runtime PM) |
| V4L2 core, `VIDEOBUF2_DMA_CONTIG`, DMA-BUF heaps (system, CMA) | yes | V4L2 modules; heaps built in (`omandroid.config`, built) | `CMA_SIZE_MBYTES=32` is too small: add a reserved pool |
| libcamera | simple + soft ISP | Arch `libcamera 0.7.2` | one entry in the simple handler's device table, a sensor helper, a tuning file |

---

## 3. The options

### (a) Raw capture, software ISP: recommended

- **Kernel:** about 3-4k lines of new code: the CSIS/WDMA V4L2 driver
  (media controller, one subdev per link, one video node per WDMA
  context), the DC-PHY RX PHY driver, the SLG51002 and S2MPG13 GPIO
  drivers, sensor drivers.
- **Userspace:** libcamera's simple pipeline handler with the software ISP
  (debayer, AWB, AGC; GPU debayer if Arch's build has it [I]), PipeWire's
  libcamera plugin for apps, the camera portal for Flatpak apps.
- **Licensing:** everything new is GPL kernel code and upstream-able in shape.
  Register *facts* learned from the HAL are written in our own words with
  our own names; sensor mode tables never enter the repository (section 5.3).
- **Limits:** no hardware 3A statistics, no PDAF, no hardware noise
  reduction or HDR+. Image quality will be "decent webcam", not Pixel. Fine
  for QR codes, video calls and snapshots.

### (b) LWIS + stock HAL in a vendor chroot: not recommended

- **LWIS** (`LW/`, about 23.8k lines GPL) is portable in principle, but it
  depends on Google's BTS, `exynos_pm_qos`, SLC partitions, the Samsung
  SysMMU driver and Google's DMA-BUF heaps (`LW/platform/busan/lwis_platform_busan.c`).
  It hands userspace raw MMIO and I2C, so it can never go upstream, and it
  would let a userspace bug write any ISP register.
- **The HAL** (`A/lib64/liblyric_hwl.so`, 20 MB, plus about 50 libraries)
  needs: Google's gralloc and AHardwareBuffer, Mali **kbase** with OpenCL
  (`A/lib64/camera/tuning_ocl.txt`; we run Panthor), the EdgeTPU and GXP
  drivers and firmware, the ISP blocks' power domains and DVFS (PDP, G3AA,
  IPP, ITP, DNS, MCSC, GDC, TNR), the SysMMU v8, binder and the camera
  provider AIDL, and an Android camera client to drive it. It reads
  `persist`; some paths look writable (`.../nagual_need_higher_gate_voltage.reg`).
- **Even working, it ends at an Android `camera2` stream**, which then needs
  a bridge to PipeWire or V4L2 loopback.
- GNSS and fingerprint work in a chroot because each is one daemon on one
  character device. The camera HAL is the opposite: dozens of kernel
  interfaces. Effort: many months, with no upstream value.

### (c) What mainline has

- `drivers/media/platform/samsung/exynos4-is/` (FIMC-IS, Exynos4 CSIS) and
  `drivers/media/platform/nxp/imx-mipi-csis.c` (CSIS v3.3/v3.6.3): older
  versions of the receiver. The link register offsets match gs201
  (section 1.3), so `imx-mipi-csis` is the model for the link half of our
  driver. Neither has the separate DC-PHY or the WDMA.
- `drivers/phy/rockchip/phy-rockchip-samsung-dcphy.c`: the transmit side of
  the same DC-PHY family, D-PHY only.
- No gs101/gs201 camera series in 7.3-rc6, nor any CSIS v5/WDMA driver.
  A Samsung FSD (Tesla) CSIS series was posted to linux-media in 2022 and
  didn't land [I: check lore before citing]. Rockchip's vendor kernel has
  DC-PHY receive and C-PHY code, but it isn't on our list of citable sources
  (AGENTS.md section 1); ask the human before using it.

---

## 4. What we must learn from the stock HAL (offline, REA)

GPL gives us addresses, interrupts, interrupt bit names, power sequences
and the D-PHY settings. It doesn't give the meaning of the CSIS link control
bits, the WDMA format/control bits, the link-to-WDMA routing, which link and
PHY each sensor uses, lane counts and rates, the C-PHY settings, or sensor
modes. Those are in `A/lib64/liblyric_hwl.so`. Rules: work only on the
user's own image; never commit decompiled code, tables or tuning; write
facts in our own words.

### 4.1 Findings so far (2026-10-12)

- **The HAL carries a named register table.** Records of 48 bytes: block
  name, register name, offset, in `.data.rel.ro`, found by searching
  for pointers to the name strings (the library uses RELR, so the pointers
  are stored in place). One table has 349 entries: 26 for the CSIS link
  and PHY windows (`csis`), 83 for the CSIS DMA (`csis_dma`), 8 for EBUF,
  232 for GTNR align. It confirms the DT offsets (CSIS WDMA context 0 at
  `0x7000`, its interrupt block at `0x7400`) and gives names for the context's
  control, format, skip, 32 per-frame address slots, resolution, stride,
  frame counter and SBWC (compression; keep it off) registers, and for a
  few common DMA registers in the first page. The dump stays off-repo.
- **Sensor modes** are built by per-sensor drivers inside the HAL
  (`.../lyric/drivers/sensors/{nagual,sandworm}/sensor_driver.cc` paths in
  its strings; "register_settings"). Sensor-to-link data lives in a
  `ModuleDescriptor` with `use_cphy`, `csis_link`, `num_lanes` and
  `mipi_rate` fields (strings in `liblyric_hwl.so` and `liblyric_base.so`).
- **The per-camera link, PHY type and lane count are not yet known.**
  RADIOS-CAMERA-PLAN's "main and tele are C-PHY" is unproven [I].

### 4.3 Findings, second pass (2026-10-12)

Offline, on the user's own HAL (`liblyric_hwl.so`); REA's Hopper provider
didn't come up on the 20 MB library, so the evidence is disassembly
addresses in the private notes (`~/android/reference/`-style, off-repo).
Facts in our own words:

- **RE1, ultrawide.** The HAL's sandworm driver expects model ID 0x0386:
  **Sony IMX386** [V]. It runs four D-PHY lanes, RAW10, at **1548 Mbps per
  lane** (link frequency 774.144 MHz) in its standard modes, and its own
  external-clock setting is 24.574 MHz: **stock feeds it the 24.576 MHz
  oscillator**, not a PLL tap. **Which CSIS link it uses is not found**:
  the link index arrives in a copied per-camera config (Cheetah-specific
  setup code not decoded). Only links 0 and 1 have four lanes, so CAM3b
  tries those two.
- **RE2, CSIS link** (version 0x05040000 on the phone, CAM1.2). Same
  layout as `imx-mipi-csis` for the enable bit, the lane-count field
  (bits 9:8), the data-type field of the channel config (7:2), its pixel
  mode field (13:12, stock uses quad) and the size register. New: a
  virtual-channel field in the channel config (20:16), a two-bit
  interleave field (11:10, stock 3), a separate shadow-update register at
  0xc (stock writes all four channels), the D-PHY common control at 0x704
  (stock 0x1f), a C-PHY bit (21), a debug option bit at 0x690 and a
  line-rate register at 0x600 left at its default. Unused channels get
  data type 0x3f. Stock writes the common control (with enable) last.
- **RE3, CSIS WDMA.** Each context has four channels at 0x100 apart (the
  stock RAW path writes channel 2). Per channel: control (bit 0 enable;
  stock writes 0xf83 to start and 0xf82 to stop), format (code 7 = RAW10
  packed as on the CSI-2 bus, 6 = 16-bit container, 0 = 8-bit; **no packed
  RAW12**), skip, 32 address slots (plain 32-bit values), width (height
  left 0), stride in bytes and a slot mask. The interrupt bits are the
  GPL ones. The common page gets four constant writes once. Stock's
  flush: data control 0, control 1, format 7, control 0.
- **Routing, in the CSIS sysreg** (`0x1a420000`): an EBUF input mux
  (0x430 + 4 x EBUF = link) and a WDMA input mux (0x414 + 4 x context =
  source); sources 8-10 are the PDP channels, and the value for an EBUF
  is **not** found ([I] 0-3 = EBUF 0-3). There is also a PDP mux stock
  sets that a RAW-only path doesn't need [I].
- **RE4, ultrawide settings.** Two init lists (139 writes without phase
  detection, 212 with), and three mode-list builders; the default one
  gives 4032x3016 at 30 fps, a 4032x2272 crop (at a different link
  rate, 794.6 MHz), and 2x2-binned 2016x1508 and 2016x1136 at 60 fps.
  Mode lists use the standard CCS registers for PLL, frame/line length,
  crop, output size and binning; the init lists are manufacturer
  registers. `tools/extract-camera-data` regenerates them (section 5.3).
- **RE5, DC-PHY.** Same registers and timing logic as Google's GPL
  settings, different analog trims (now in our PHY driver), and an HS
  settle count looked up by lane rate from a table; at 1548 Mbps it is 7
  with the fast settle clock [V], which our DT gives for links 0 and 1.

### 4.2 Work items

| Item | Question | How |
|---|---|---|
| RE1 | link, PHY type, lanes, MIPI rate per camera (ultrawide: all but the link answered, 4.3) | find the `ModuleDescriptor` values per sensor; cross-check on the phone by which link counts frames (CAM5) |
| RE2 | (answered, 4.3) CSIS link control: enable, lane count, data type and virtual channel per channel, `ISP_CONFIG` fields | the code that fills `csis_cmn_ctrl`, `isp_config_ch0` (compare with `imx-mipi-csis` bit fields) |
| RE3 | (answered except the WDMA input value, 4.3) CSIS WDMA: format codes for RAW10/RAW8/RAW16, packing, stride rules, address slot use, enable/abort, link routing | the code around the context-0 control and format registers and the common DMA config register |
| RE4 | (answered; extract tool built) ultrawide mode tables: one binned or 1080p-class mode, its PLL, line length, frame length | the sandworm sensor driver; express as CCS-standard registers where they are standard |
| RE5 | C-PHY settings (main/tele, if C-PHY; D-PHY answered, 4.3) | the PHY write sequence for `use_cphy` |

---

## 5. Design

### 5.1 Kernel (`omandroid-camera`)

Built (2026-10-12), on `omandroid-int` @ `898ab3c1e`, head @ `6cb2be364`
(release `7.3.0-rc6-omandroid-push1-00331-g6cb2be364f15`):

- `soc: google: add a read-only gs201 camera receiver probe` (CAM1,
  bring-up, `gs201-cam-probe`);
- `dt-bindings: mfd: samsung,s2mpg13-pmic: add the GPIO block`,
  `mfd: sec: s2mpg13: add the GPIO block`, `gpio: add a driver for the
  Samsung S2MPG13 PMIC GPIOs` (item 2);
- `regulator: dt-bindings: add Dialog SLG51002`, `regulator: add a driver
  for the Dialog SLG51002 camera PMIC` (item 3);
- `soc: google: add a gs201 camera module power test driver` (CAM2.3/CAM3a,
  bring-up, `gs201-cam-power`, binding `google,gs201-camera-power-test`);
- `arm64: dts: exynos: google: gs201: add USI3 and its I2C bus`, and for
  cheetah the camera power path (S2MPG13 GPIO node, `ldo12s`, the fixed
  supplies, the SLG51002) and the ultrawide test nodes, all disabled.

Checks: see the end of this section. The plan as written:

1. `arm64: dts: exynos: gs201: add USI1-4 and the camera I2C buses`
   (disabled). USI3 done; USI1, 2, 4 when their cameras come up.
2. `mfd: sec: s2mpg13: add the GPIO bank` + `gpio: s2mpg13`, `ldo12s` in
   `pmic-2`. Done.
3. `regulator: add SLG51002` (port; binding first). Done.
4. `phy: samsung: add the gs201 MIPI DC-PHY receiver` (`google,gs201-mipi-dcphy-rx`):
   D-PHY 1/2/4 lanes from the GPL `0x0504` settings, isolation through the
   PMU regmap, reset through the CSIS sysreg; C-PHY later.
5. `media: samsung: add the gs201 CSIS receiver` (`google,gs201-csis`):
   - per-link subdev (sink pad from the sensor, source pad to a WDMA);
   - per WDMA context a V4L2 video node, `vb2-dma-contig`, MMAP and DMABUF;
   - IRQ handling from the GPL bit names; frame start/end counters in debugfs;
   - formats: RAW10 packed (`V4L2_PIX_FMT_SRGGB10P`) first, RAW8 for tests.
6. Sensor driver(s) (section 5.3).
7. DT for cheetah: sensors with their supplies, `reset-gpios`, `clocks`
   (`CIS_CLKn`), `pinctrl` MCLK states, endpoints with `data-lanes` and
   `link-frequencies`; a reserved `shared-dma-pool` below 4 GiB for capture
   (two cells address, one cell size, AGENTS.md gotcha), disabled by default,
   enabled by overlays in `device/cheetah/overlays/camera-*.dtso`.
8. Config: `CONFIG_VIDEO_GS201_CSIS=m`, `CONFIG_PHY_GS201_MIPI_DCPHY=m`,
   `CONFIG_REGULATOR_SLG51002=m` (done, with `GPIO_S2MPG13`, the two
   bring-up modules, the DMA-BUF heaps and `VIDEO_CCS`), sensor modules.

**Checks (laptop, 2026-10-12):** `bin/omandroid kernel` exit 0 into
`out-camera`; `W=1` on `gs201-cam-probe.o`, `gs201-cam-power.o`,
`gpio-s2mpg13.o`, `slg51002-regulator.o`, `sec-acpm.o`, `sec-common.o`: no
warnings; the DTB builds `W=1` with only the existing simplefb
`unit_address_vs_reg` warning; checkpatch `--strict`: only the usual
no-Signed-off-by and MAINTAINERS items, plus "binding in the same patch"
on the bring-up power test driver (never sent upstream). `dt-doc-validate`
and the examples of the three new or changed bindings pass; `dt-validate`
(dtschema 2026.9) on the default DTB and on default + `camera-pwr-test`:
only the existing `soc_id` and framebuffer `post-init-providers` reports.
The overlay applies with `fdtoverlay` and turns on the nine nodes it names.
Nothing has run on the phone.

**Capture path, built 2026-10-12 on top (head `35295a9ab`, test build in
`out-camera`):**

- `clk: samsung: gs201: round the camera master clock dividers to the
  closest rate`: a 24 MHz request on the oscillator gives 24.576 MHz, as
  stock, instead of 12.288 MHz.
- `dt-bindings: phy` + `phy: samsung: add the gs201 MIPI DC-PHY receiver`
  + `use the board's analog settings` (`phy-gs201-mipi-dcphy-rx`, D-PHY,
  settle per link from DT).
- `dt-bindings: media` + `media: samsung: add the gs201 CSIS receiver and
  CSIS WDMA driver` (`gs201-csis`): one link + one WDMA context per node,
  media graph sensor -> CSIS subdev -> video node, RAW8/RAW10, frame-sync
  events. Bring-up parameters: `allow_stream` (default off),
  `link_only` (run PHY, link and sensor without the WDMA: no DMA),
  `wdma_channel` (0-3, default 0). Debugfs `stats` and `regs` (registers
  only while streaming).
- `media: i2c: add a Sony IMX386 driver` (`imx386`): standard controls
  (exposure, analogue/digital gain, vblank, hblank, pixel rate, link
  frequency, test pattern, orientation), modes and init from the data file
  `omandroid/camera/imx386-uw.bin`; power-up in stock's order.
- DT: `sysreg_csis`, `csis_dcphy`, `csis0`/`csis1` (links 0/1, WDMA
  contexts 0/1), the IMX386 with an endpoint to each link, a 64 MiB
  capture pool below 4 GiB. Overlays `camera-stream-link0` and
  `camera-stream-link1` enable one link each (never together with
  `camera-pwr-test`).

Checks: `bin/omandroid kernel` exit 0; `W=1` clean on the new objects;
checkpatch `--strict` clean apart from the usual trailer items;
`dt-doc-validate` and examples pass for the new bindings; `dt-validate` on
the default DTB and default + each of the three camera overlays: only the
existing `soc_id` and framebuffer reports.

### 5.2 Userspace

- libcamera: Arch Linux ARM ships 0.7.2-4 (= upstream's latest release)
  with the simple pipeline and the software ISP already built, but the
  simple handler matches only media devices whose driver name is in a
  fixed table, and a configuration file can't add one. So
  `packages/libcamera` (built 2026-10-12, not yet built for the phone) is
  Arch's PKGBUILD with one patch adding `gs201-csis` with the software ISP
  on, simple and uvcvideo pipelines only, the GPU debayer enabled (it
  falls back to the CPU; `LIBCAMERA_SOFTISP_MODE=cpu` forces it), pkgrel
  4.1. No IMX386 `CameraSensorHelper` or sensor-properties entry: without
  them libcamera treats the gain code as linear and has no unit cell size,
  which is enough for a first picture; the gain formula and pixel size
  have no citable public source yet.
- What libcamera needs from the kernel (checked against 0.7.2's simple
  handler): media driver name `gs201-csis`; a `CAM_SENSOR` entity with one
  source pad; a path sensor -> CSIS -> video node; the CSIS keeps the
  sink format on its source pad unchanged (so it must not align widths);
  a video node with `IO_MC`, `ENUM_FMT` by media bus code,
  `ENUM_FRAMESIZES`, exact `S_FMT`, MMAP/DMABUF/EXPBUF; a DMA-BUF heap
  (present since K); and on the sensor `ANALOGUE_GAIN`, `EXPOSURE`,
  `HBLANK`, `VBLANK`, `PIXEL_RATE`. Frame-sync events on the CSIS subdev
  keep the soft ISP's exposure updates in step. Our drivers do all of
  this; sensor crop selections and flips are left for later.
- `omandroid-camera` package: modprobe policy (modules blacklisted until
  the start unit loads them, the AoC pattern), a minimal tuning file, udev
  rules for `/dev/video*` and `/dev/media*`.
- Apps: `cam` for tests, then a PipeWire camera app (GNOME Snapshot) and
  the browser through the camera portal.

### 5.3 Sensor register data without committing it

- Prefer CCS-standard registers (mode select `0x0100`, PLL `0x0300-0x030f`,
  frame and line length `0x0340/0x0342`, output size `0x034c/0x034e`,
  binning `0x0900`, test pattern `0x0600`) and mainline drivers of the
  same family (`imx258`, `imx319`, `imx355` for Sony; `s5k3m5`, `s5kjn1`
  for Samsung).
- **Built: `tools/extract-camera-data`.** It finds the IMX386 functions in
  the user's own `liblyric_hwl.so` by a byte pattern (the model-ID
  function and the mode dispatcher next to it) and by the shape of the
  init-list builders, runs them in the unicorn AArch64 emulator (PLT calls
  and imported data stubbed), reads back the register lists they build,
  computes each mode's size, frame and line length, pixel rate and link
  frequency from the standard registers in it, and writes our own data
  format (documented in `imx386.c`), which the driver loads with
  `request_firmware()` from `/usr/lib/firmware/omandroid/camera/`.
  Checked on this laptop with the user's HAL: 139 init writes, four modes
  of 73 writes each, frame rates 30/60 as the HAL names them. The pixel
  rate assumes four pixels per video-timing clock [I]; the analogue gain
  range 0-480 and the exposure margin of 10 lines are [I] too. The output
  is per-phone and never committed; it needs `pip install unicorn
  pyelftools` in a virtual environment.
- Mainline `ccs` with CCS static data was the other candidate. It needs
  the sensor's limit registers or a full set of limits in the static data,
  neither of which we have for the IMX386; a small driver with the
  extracted lists is the more certain route. `ccs` stays worth a try once
  the sensor streams (an identify + limits read is harmless).
- Upstream may object to a driver that can't stream without a vendor data
  file. That is the honest trade-off; record it in the cover letter.

---

## 6. Stages, effort and timeline

| Stage | What | Needs | Effort |
|---|---|---|---|
| CAM0 | Read-only: clocks, pins, LDO12S, libcamera, CMA (current int kernel) | nothing | 0.5 day |
| CAM1 | Read-only kernel probe: PMU status of the camera domains, then CSIS link versions, one register per boot | probe module | 2-3 days |
| CAM2 | Rails, one per boot: S2MPG13 GPIOs and the fixed supplies; GPIO 0 → SLG51002 chip ID; LDO12S → ultrawide EEPROM answers | buses, S2MPG13 GPIO, SLG51002 (built) | 1 week |
| CAM3a | Full ultrawide sequence → sensor chip ID, read-only; then front, tele, main | `gs201-cam-power` (built) | 0.5-1 week |
| RE1-RE4 | Offline HAL analysis (section 4) | REA | 2-3 weeks, in parallel with CAM2 |
| CAM3b | Ultrawide streams a test pattern; DC-PHY RX up; find the link (0 or 1) whose frame counter runs, no errors; no DMA | built: PHY, CSIS (`link_only`), IMX386, data file | 2-4 boots |
| CAM4 | CSIS WDMA writes the test pattern, then a real image, to a file (`v4l2-ctl`); find the WDMA input value and channel | built: CSIS/WDMA | 3-6 boots |
| CAM5 | libcamera `cam` photo; PipeWire app preview | built: `packages/libcamera` | 1 week |
| CAM6 | Video: 1080p30 preview, recording (software encode), ACPM CAM DVFS | ACPM merged | 2-3 weeks |
| CAM7 | Front camera (fixed focus) | CAM5 | 1-2 weeks |
| CAM8 | Main and tele (C-PHY if RE1 says so; GN1/GM5 binned modes) | RE5, C-PHY PHY code | 4-8 weeks |
| CAM9 | Focus (VCM drivers, libcamera AF), OIS, flash sync | CAM5 | 2-4 weeks |
| CAM10 | Runtime PM: gs201 PD driver for `pd-csis` (SMC, DTZPC), SysMMU v8 | PD work shared with GPU | 2-3 weeks |

**Realistic timeline** (one agent writing, the human running gated steps):
first raw frame from the ultrawide in **6-9 weeks**, a photo in `cam` and a
PipeWire app in **8-12 weeks**, video **2-3 weeks** later, all four cameras
with focus in **4-6 months**. The biggest unknowns are RE2/RE3 (if the WDMA
needs more than its register table shows, CAM4 doubles) and RE5 (if the
C-PHY settings can't be recovered, main and tele wait, and Omandroid ships
with the ultrawide and front cameras).

### 6.1 Risks

- **Bus aborts.** Reading CSIS, CMU_CSIS or PHY registers with `pd-csis`
  off, or a PHY register while isolated, can abort the SoC. CAM1 reads the
  domain status through the kernel's PMU regmap before touching anything, and
  reads one register per boot on the first probe. Never read PMU registers
  from userspace.
- **The PMIC and the rails.** The camera rails share PP3200_BB_CAM with the
  laser AF supply. Only the documented stock voltages are used; no voltage
  writes on S2MPG13 (its regulators are switched only, as for GNSS); the
  SLG51002 test-mode trim is skipped unless the chip is revision AA, and
  read back first. Every stage that switches a rail also switches it off.
- **Shared pins.** gpp8 carries the tele bus (gpp8-0/1), the torch HWEN
  (gpp8-2) and the laser AF supply enable (gpp8-3): the pinctrl groups must
  not overlap.
- **The S2MPU after a domain cycle.** Nothing in CAM0-CAM9 cycles
  `pd-csis`. CAM10 must restore the DTZPC through the SMC and check that the
  S2MPU is allow-all before any DMA (it resets with the domain [I]).
- **DMA to the wrong place.** With the SysMMU in bypass, a wrong address in
  a WDMA slot writes anywhere in the first 4 GiB. The driver programs only
  addresses inside its own reserved pool and checks every slot it fills;
  first DMA tests use a test pattern into a pool far from other users, with
  `--watchdog` and the log stream on.
- **Calibration and persist.** Module EEPROMs and `persist` are read-only
  for us and never committed (section 1.6).
- **Proprietary data.** Nothing derived from the HAL enters the repo except
  facts in our own words; the extract tool generates data on the user's
  machine.

---

## 7. Runbooks (gated)

Phone in Arch over USB, from the omandroid repo. Run each step only when the
human says go; record the result here with the date and `uname -r`. `ov` is
the overlay helper from AUDIO-PLAN.md, with `KERNEL_DIR`/`KERNEL_OUT`
pointing at the kernel being pushed. The staged steps run through
`tools/camera-stage`, which streams `/dev/kmsg` to `logs/` before it touches
anything, marks each action in the kernel log, and with `--watchdog` arms the
hardware watchdog with a feeder, so a hang resets the phone and pstore keeps
the console (`tools/camera-stage --pstore` afterwards).

Built (2026-10-12): see section 5.1 for the branch. CAM0 is partly done;
CAM1, CAM2 and CAM3a are built and waiting for the phone.

### CAM0: read-only, current int kernel (partly run). Risk: none

```sh
# CAM0.1 clocks as ABL left them (software state only)
tools/phone-ssh 'grep -iE "cis_clk|csis" /sys/kernel/debug/clk/clk_summary'
#   expect: CIS_CLK0-3 and CSIS_NOC listed; record enable count and rate
# CAM0.2 sensor resets, MCLK pads, camera I2C pads
tools/phone-ssh 'grep -hE "\((gpp2-[0-2]|gpp4-[0-2]|gpp6-[0-3]|gpp8-[0-3]|gpp3-0|gpp5-0|gpp7-0|gpp9-0)\)" /sys/kernel/debug/pinctrl/*10840000*/pins'
#   expect: resets low or input (sensors off); MCLK pads not in function 2
# CAM0.3 LDO12S as ABL left it (needs gnss-pmic-test and sec_acpm, as GNSS G1)
tools/phone-ssh 'grep -E "^37:" /sys/kernel/debug/regmap/*pmic-2*pmic*/registers'
#   expect: bit 7 = enable; record the selector (stock 1.8 V)
# CAM0.4 userspace and memory
tools/phone-ssh 'pacman -Q libcamera libcamera-tools 2>&1; ls /dev/dma_heap/ /dev/video* /dev/media* 2>&1; grep -i cma /proc/meminfo'
#   expect: no camera nodes; record CmaTotal/CmaFree
```

Stop if any read hangs or errors in an unexpected way. Rollback: none (all
reads). Do **not** dump the `0x50` EEPROM on `hsi2c_15` (section 1.7).

**CAM0 partial result (2026-10-12, 7.3.0-rc6-omandroid-push1-00306-g60d3ca176c80),
read-only.** `clk_summary`: the CMU's sensor clocks (`mout/gout/dout_cmu_cis_clk5..7`
seen) are registered at 24.576 MHz, enable count 0, hardware enable Y, so ABL
leaves them running with no consumer. No `/dev/dma_heap` (CONFIG_DMABUF_HEAPS
and the system/CMA heaps are off in our config), CMA 124 MiB total, about
68 MiB free; no `/dev/video*` or `/dev/media*`; libcamera not installed. Not
yet done: the pin states (CAM0.2, now folded into CAM2.0) and LDO12S, which
needs the pmic-2 regmap (bound only while the GNSS power stack runs, as
FINGERPRINT-PLAN FB2 found; CAM2.0 reads it on the camera-pwr-test boot).

**CAM0.3 result (2026-10-12, 7.3.0-rc6-omandroid-push1-00345-g606b84c7a9fd,
GNSS running so `pmic-2`'s regmap was bound): LDO12S control (PM 0x37) reads
0x2c: bit 7 clear, so L12S_CAMIO is off as ABL left it.** The selector is in
bits 5:0 and LDO12S is in Google's voltage group 6 (0.7 V base, 25 mV
steps; `s2mpg13-regulator.c` `REG_DESC("LDO12S", ..., 6, ...)`, our
`regulator_desc_s2mpg13_ldo_own(12, 6, ...)`): 0.7 V + 44 x 25 mV =
**1.8 V**, stock's camera I/O voltage. (Group 7, 1.8 V base, would make
0x2c read 2.9 V; LDO12S isn't in it.) The GNSS rails read as the same
formulas predict: 0x34 (LDO9S, group 5, 0.725 V + 12.5 mV steps) 0xa6 = on,
1.2 V; 0x35/0x36 (LDO10S/LDO11S, group 6) 0xac = on, 1.8 V. So describing
`ldo12s` with stock's fixed 1.8 V in `camera-pwr-test` finds the selector
already at 1.8 V and writes no voltage; the regulator core only switches
bit 7 when a consumer enables it. CAM2.0 confirms the value again on that
boot.

**Note on the MCLK rate.** CIS_CLK0's divider parent is the 24.576 MHz
oscillator, and the divider rounds down, so asking for stock's 24 MHz would
give 12.288 MHz. The bring-up driver never sets the rate; it logs what it
gets. A sensor's ID registers don't depend on the exact MCLK; streaming will
(CAM3b), and needs a parent that gives 24 MHz (a `dout_cmu_shared*` PLL tap).

### K: the camera kernel and the blacklist. Risk: low (K3 flashes)

Everything in `omandroid-camera` is disabled or blacklisted until a step
enables it, so K3 should boot exactly like the int kernel it is based on,
plus `/dev/dma_heap`.

```sh
# K0 (laptop) build: the branch, or omandroid-int after the human merges it
export KERNEL_DIR=$HOME/android/mainline/wt-camera KERNEL_OUT=$HOME/android/mainline/out-camera
bin/omandroid kernel && bin/omandroid modules && bin/omandroid initramfs
# K1 (phone, one file) the camera blacklist, as a bring-up copy until
#    omandroid-device-cheetah ships modprobe.d/omandroid-camera.conf
tools/phone-ssh 'cat > /etc/modprobe.d/omandroid-camera-bringup.conf' \
  < packages/omandroid-device-cheetah/vendor/modprobe.d/omandroid-camera.conf
tools/phone-ssh 'cat /etc/modprobe.d/omandroid-camera-bringup.conf | grep -c ^blacklist'
#   expect: 4
# K2 (laptop) images with the overlays the phone boots today, no camera overlay yet
ov <the overlays the phone runs now>          # as in AUDIO-PLAN.md / MODEM-PLAN.md
# K3 flash slot B and reboot (ASK FIRST)
bin/omandroid push
# K4 read-only check
tools/camera-stage k
```

- **Expect/Pass (K4):** `uname -r` is the new release; the four modules are
  listed with paths; `blacklist` lines for all four; `/dev/dma_heap/`
  lists `system` and the default CMA heap; the camera-pwr-test overlay is
  not in the DTB. Display, touch, Wi-Fi, audio and GNSS behave as before.
- **Stop:** a regression anywhere (boot, USB, display), or a camera module
  missing.
- **Rollback:** push the previous int images (`$D.default` of the int build)
  or let the boot fall back to slot A.

**K result (2026-10-12, 7.3.0-rc6-omandroid-push1-00345-g606b84c7a9fd: int
606b84c7a with omandroid-camera 6cb2be364 merged, overlays as before, no
camera-pwr-test, device-cheetah 0.1.25): passed.** All four camera modules
are present; the package's blacklist is active (`gpio_s2mpg13`,
`slg51002_regulator`, `gs201_cam_power`, `gs201_cam_probe`), so the
bring-up copy of K1 isn't needed. `/dev/dma_heap` lists
`default_cma_region`, `display-pool`, `reserved` and `system`. Two
`camera-stage` bugs found and fixed since: `k` printed "no camera
blacklist" after listing it (a glob that didn't match made grep fail), and
the tool never exited (killing the log-stream subshell left its ssh
running); the stream now runs in its own process group and is stopped,
with the watchdog feeder, from an exit trap.

### CAM1: domain status, then CSIS registers (gs201-cam-probe). Risk: medium

The module only reads. CAM1.1 reads three PMU registers through the
kernel's PMU regmap (the same plain read stock's power-domain code uses
for these offsets; never from userspace, AGENTS.md); CAM1.2 adds exactly one
register of the camera block, and only if both domains read on. One CAM1.2
read per boot on the first runs: an abort kills the session.

```sh
# CAM1.1 (camera kernel, no overlay needed)
tools/camera-stage --watchdog p1
#   kernel log: "PMU 0x2404 CSIS_STATUS = ...", "0x2484 PDP_STATUS",
#   "0x3ebc PHY_CTRL_MIPI_DCPHY_S4S4S4S4", then "pd-csis on, pd-pdp on, DC-PHY ..."
# CAM1.2, next boot each: link0 first, then link1..link7, wdma, phybias
tools/camera-stage --watchdog --reg link0 p2
#   kernel log: "reading 0x1a440000 (CSIS link 0 version)", then its value
```

- **Pass (1.1):** CSIS_STATUS and PDP_STATUS bit 0 = 1. Record all three
  words; DC-PHY bit 0 is expected 0 (isolated) while nothing streams [I].
- **Stop (1.1):** either domain reads off: don't run CAM1.2; the gs201 PD
  driver (CAM10, shared with GPU-PLAN G4c) moves up. A read error: record
  it, stop.
- **Pass (1.2):** a plausible version word (not 0, not 0xffffffff) for
  link 0, the same for each other link; `wdma` a mask value (0 or a bit
  pattern); `phybias` only once a later stage has released the isolation
  (the module refuses it while bit 0 of 0x3ebc is 0).
- **Stop (1.2):** a hang (the watchdog resets the phone): the read was not
  safe; save pstore and don't retry that block until we know why.
  0xffffffff or 0 from a link: stop, compare with the HAL register table
  (section 4.1).
- **Rollback:** none needed (the module only reads; camera-stage unloads it).

**CAM1 result (2026-10-12, same kernel): passed.** CAM1.1
(`step=pmu`): CSIS_STATUS 0x1, PDP_STATUS 0x1, PHY_CTRL_MIPI_DCPHY_S4S4S4S4
0x0, "pd-csis on, pd-pdp on, DC-PHY isolated": ABL leaves both camera
domains on and our kernel doesn't turn them off, and the PHYs stay
isolated until a driver releases them. `rmmod` clean. CAM1.2
(`step=link0`): CSIS link 0 version **0x05040000**, a plausible version
word; it matches the DC-PHY version 0x0504 that Google's GPL PHY settings
are written for. The phone was fine afterwards. Still to read, one per
boot, when convenient: links 1-7, `wdma`; `phybias` only once the PHY
driver has released the isolation (CAM3b).

### CAM2: the camera power path, one change per boot. Risk: low to medium

Before CAM2: **the PMIC backup check (AGENTS.md).** Steps g1-e1 write the
S2MPG13's GPIO block and the SLG51002, so first confirm the off-repo backup
still matches:

```sh
# CAM2-B (read-only, ~430 MB of reads) against the 20261012-radio backup
tools/phone-ssh 'for p in efs efs_backup modem_userdata persist modem_a modem_b; do
  d=$(grep -l "^PARTNAME=$p\$" /sys/class/block/*/uevent | head -1 | cut -d/ -f5)
  printf "%s  %s.img\n" "$(sha256sum < /dev/$d | cut -d" " -f1)" "$p"; done' > logs/cam2-partitions.sha256
grep -E ' (efs|efs_backup|modem_userdata|persist|modem_a|modem_b)\.img$' \
  ~/android/reference/cheetah-partition-backup-20261012-radio/SHA256SUMS | sort -k2 |
  diff - <(sort -k2 logs/cam2-partitions.sha256) && echo BACKUP-MATCH
```

Stop if it doesn't print `BACKUP-MATCH`: find out why (a slot A boot since
then? MODEM-PLAN M0.1) and take a fresh backup before going on.

Then boot the overlay. `camera-pwr-test` enables `pmic-2` with `ldo12s`
described (stock's fixed 1.8 V), the S2MPG13 GPIO node, the two fixed camera
supplies, the SLG51002 on bus 8, USI3/`hsi2c_3` (950 kHz, as stock) and the
two `gs201-cam-power` nodes (ultrawide sensor 0x1a, its EEPROM 0x50). With
the blacklist in place nothing new binds except the bus: the fixed supplies
and the camera PMIC wait for the GPIO driver, the test nodes for their
supplies.

```sh
# CAM2-K overlay boot (ASK FIRST: flashes and reboots)
ov <the overlays the phone runs now> camera-pwr-test && bin/omandroid push
# CAM2.0 read-only: S2MPG13 GPIO block and LDO12S over ACPM, camera pins
tools/camera-stage r0
```

- **Expect (2.0):** the GPIO regmap dump (registers 02-14). In each pin's
  control register (05 = GPIO0 ... 0c = GPIO7) bit 6 is output enable and
  bit 5 the level; record pins 0 (SLG51002 CS), 1 (PP3200_BB_CAM enable)
  and 3 (PP1300_CAM enable). LDO12S (`37:`) reads 0x2c (off, 1.8 V) or
  0xac (on). gpp3-0 (MCLK) and gpp6-3 (reset) as ABL left them; gpp6-0/1
  in function 3 (I2C).
- **Stop (2.0):** no `-gpio` regmap (pmic-2 didn't bind: check `sec_pmic_acpm`
  in dmesg); bits 1:0 (pin mode) of pin 0, 1 or 3 not 0: something other
  than the output register may own the pin [I]; don't run g1 until that is
  understood. LDO12S's selector not 0x2c: the regulator core will rewrite
  it to 1.8 V when LDO12S registers, so check stock's value first.
- **Rollback:** `ov <the overlays the phone runs now> && bin/omandroid push`.

```sh
# CAM2.1 (this boot) the S2MPG13 GPIO driver. Changes: PP3200_BB_CAM and
#        PP1300_CAM enables become outputs, driven low (supplies off)
tools/camera-stage --watchdog g1
```

- **Expect (2.1):** `gpio-s2mpg13` registers 8 lines; the two fixed
  regulators probe (`PP3200_BB_CAM`, `PP1300_CAM` in the regulator summary,
  disabled); registers 06 and 08 show bit 6 set, bit 5 clear; nothing else
  in the dump changed from 2.0.
- **Pass:** as expected, phone otherwise unchanged (GNSS still powers if it
  runs).
- **Stop:** any other pin register changed; an ACPM error; a regulator
  enabled.
- **Rollback:** reboot (the module is blacklisted, so the pins go back to
  ABL's state only through a full reset; they stay "off" otherwise, which
  is safe).

```sh
# CAM2.2 (next boot) the SLG51002. Changes: GPIO0 high (CS), 10 ms; the LDO
#        voltage selectors set to the stock voltages; every output stays off
tools/camera-stage --watchdog s1
```

- **Expect (2.2):** "pattern ID 0xb13103 (revision AB)" (stock's dmesg
  shows `chip_id: 0xb13103`); 8 LDOs and 4 switches registered, all
  disabled, with the voltages from the DT (2.85, 2.85, 2.25, 2.9, 2.85, 1.1,
  1.0, 1.1 V); register 05 (GPIO0) bit 5 set.
- **Stop:** an I2C error on bus 8 or the haptics stop working (check with
  `tools/phone-ssh python3 - < tools/ff-rumble`, announce the buzz first):
  `rmmod slg51002_regulator` (drives CS low) and reboot. Revision AA or an
  unknown ID: stop; the driver refuses unknown IDs and skips the switches
  on AA.
- **Rollback:** `rmmod slg51002_regulator` (CS low), then reboot.

```sh
# CAM2.3 (next boot) the ultrawide module EEPROM: LDO12S only, one current-
#        address byte read (no address written: the EEPROM is never written)
tools/camera-stage --watchdog e1
```

- **Expect (2.3):** `gs201-cam-power` binds both nodes ("not powered");
  "dovdd on", "eeprom: ack", "dovdd off"; LDO12S back to off (`37:` bit 7
  clear). The byte itself is not printed and not kept: it is calibration
  data.
- **Stop:** "no answer": the rail, the bus pull-ups or the address is wrong.
  Power is already off; record the bus error, don't power anything else.
  Stock pulls the bus lines up only while it transfers; we keep them pulled
  up while bus 3 is enabled, so if the module ever misbehaves, try the
  stock idle state (function 0, no pull) first.
- **Rollback:** `echo 0 > /sys/kernel/debug/gs201-cam-power/*-0050/power`
  (camera-stage does it), reboot.

**CAM2 results (2026-10-12, unattended with the human's permission;
kernels 7.3.0-rc6-omandroid-push1-00345-g606b84c7a9fd for 2.0/2.1 and
-00349-g781b9c3d8523 (int + omandroid-modem 781b9c3d8) for 2.2/2.3;
overlays as before plus camera-pwr-test, suspend-pmic-test,
modem-cpif-test). All passed.** `sec_acpm` is blacklisted by the GNSS
bring-up file (`/etc/modprobe.d/omandroid-g1.conf`) and was loaded by hand
before each run so that `pmic-2` binds; `camera-stage` now does that itself
(and its exit was hardened again: the coordinator still saw it hang after
a step; the stream group is now killed with TERM then KILL and never
waited on unbounded).

- **CAM2-B:** the partition checksums match the 20261012-radio backup.
- **CAM2.0 (r0):** S2MPG13 GPIO block: interrupt masks (02/03) 0xff,
  status (04) 0x00, every pin control register (05-0c) 0x40 = output,
  driven low, mode bits 0, so all eight pins are plain outputs held low by
  ABL (the camera supplies and the SLG51002 are off); monitor selects
  (0d-14) 0. LDO12S `37:` 0x2c (off, 1.8 V). Pins: gpp3-0 (MCLK) input,
  pull-down; gpp6-0/1 function 3 (I2C), pull-up; gpp6-2 and gpp6-3 (reset)
  inputs, pull-down.
- **CAM2.1 (g1):** `gpio-s2mpg13` registered 8 lines; the fixed supplies
  took GPIO1 and GPIO3 as outputs, low; `PP3200_BB_CAM` and `PP1300_CAM`
  probed, use count 0; no register changed (they were already outputs,
  low).
- **CAM2.2 (s1):** `slg51002-regulator 1-0075: pattern ID 0xb13103
  (revision AB)`, as stock; the eight LDOs registered at the DT voltages
  (2.85, 2.85, 2.25, 2.9, 2.85, 1.1, 1.0, 1.1 V) and the four switches, all
  unused and off; no I2C errors on bus 8. The haptics buzz check was
  skipped (nobody at the phone); do it next time someone is.
- **CAM2.3 (e1):** both power-test nodes bound on `i2c-0` (bus 3 is
  adapter 0 on our kernel): `0-001a: 5 supplies, 8 readable registers,
  mclk, reset; not powered`, `0-0050: 1 supplies ... not powered`. LDO12S
  on, **"eeprom: ack"**, LDO12S off; `37:` 0x2c again afterwards.

**CAM3a result (same boot as CAM2.3): passed.** The full stock sequence
ran (PP3200_BB and PP1300 use 2 while powered, gpp3-0 switched to its MCLK
function, gpp6-3 an output driven high = reset released). Register
**0x0016 = 0x03, 0x0017 = 0x86: model 0x0386, the Sony IMX386**, as the
HAL said (section 4.3) and as `imx386.c` checks. Power-down in reverse
(avdd, dvdd, dovdd, PP1300, PP3200, "powered down"), every rail back to use
count 0. The ultrawide's rails, clock and reset are proven; next is CAM3b.

### CAM3a: the ultrawide sensor's chip ID, read-only. Risk: medium

Stock's full sequence for the ultrawide (section 1.2), driven by
`gs201-cam-power` from the DT: reset held asserted (gpp6-3 low) from the
start; PP3200_BB_CAM (2 ms ramp), PP1300_CAM (2 ms), LDO12S, LDO6 (1.1 V),
LDO2 (2.85 V), 1 ms; MCLK pad to function 2 and CIS_CLK0 on, 1 ms; reset
released, 10 ms. Then one register per command from the DT allowlist
(Sony model ID `0x0016`/`0x0017`, the CCS identification block
`0x0000-0x0005`); nothing is written to the sensor. Power-down is stock's
reverse: reset, 1 ms, MCLK off and pad back to output pulled down, 1 ms,
LDO2, LDO6, LDO12S (1 ms), PP1300, PP3200. Nothing streams.

```sh
# CAM3a.1 (next boot; or the same boot as a passed CAM2.3)
tools/camera-stage --watchdog u1
# optional, a later run: the CCS identification block, one register each
tools/camera-stage --watchdog --regs "0x0000 0x0001 0x0002 0x0003" u1
```

- **Expect:** the supplies come on in order ("pp3200 on" ... "avdd on"),
  "mclk on at 24576000 Hz", "powered up"; the regulator summary shows
  `vdda_uw` and `vddd_uw` enabled; gpp6-3 an output, high; gpp3-0 in
  function 2. `0x0016` and `0x0017` each answer; record the pair (the
  plan's guess is 0x03, 0x86 for an IMX386 [I]). Then "powered down" and
  every camera supply disabled.
- **Pass:** both reads answer with the same values on a second run, and the
  rails go off.
- **Stop:** an I2C error or timeout: the stage still powers down; check
  that 2.3 passed, that `vdda_uw`/`vddd_uw` report status `on`
  (`/sys/class/regulator/*/status`, from the SLG51002's own VOUT_OK flag),
  and stop. A supply fails to enable: everything already on is turned off
  in reverse; record which one. Any SLG51002 over-current status: stop.
- **Rollback:** `tools/camera-stage off`, reboot; images without
  camera-pwr-test.
- **Afterwards:** record the model ID in section 1.1 (settles the
  ultrawide's part), then the same for the front, tele and main cameras
  (new test nodes on buses 2, 4, 1 with their own stock sequences), each
  its own boot.

### CAM3b: the ultrawide streams to the CSIS link, no DMA. Risk: medium

Needs CAM2 and CAM3a passed (chip ID 0x0386 read with the bring-up
driver). From here on the bring-up nodes of `camera-pwr-test` are replaced
by the real sensor node: never apply `camera-pwr-test` and a
`camera-stream-*` overlay together. Same PMIC backup check as CAM2 first.

```sh
# CAM3b.0 (laptop, once) the sensor data file, from your own image's
#   camera HAL APEX (vendor partition, apex/com.google.pixel.camera.hal.apex;
#   tools/extract-vendor-firmware unpacks the vendor image)
python3 -m venv ~/.cache/omandroid-venv && ~/.cache/omandroid-venv/bin/pip install unicorn pyelftools
~/.cache/omandroid-venv/bin/python tools/extract-camera-data --apex <path>/com.google.pixel.camera.hal.apex -o ~/android/reference/imx386-uw.bin
#   expect: init 139 writes; modes 4032x3016 (30 fps), 4032x2272, 2016x1508,
#   2016x1136 (60 fps); never commit the file
tools/phone-ssh 'mkdir -p /usr/lib/firmware/omandroid/camera && cat > /usr/lib/firmware/omandroid/camera/imx386-uw.bin' < ~/android/reference/imx386-uw.bin
# CAM3b.K kernel with the capture drivers (head 35295a9ab or int after the
#   merge) and the blacklist for the three new modules until
#   omandroid-device-cheetah ships them (ASK FIRST: flashes and reboots)
printf 'blacklist imx386\nblacklist phy_gs201_mipi_dcphy_rx\nblacklist gs201_csis\n' |
  tools/phone-ssh 'cat > /etc/modprobe.d/omandroid-camera-capture-bringup.conf'
ov <the overlays the phone runs now> camera-stream-link1 && bin/omandroid push
# CAM3b.1 (this boot) the sensor driver: powers the module in stock's order,
#   reads the ID, powers off again
tools/phone-ssh 'modprobe gpio_s2mpg13; modprobe slg51002_regulator; sleep 1; modprobe imx386; sleep 2; dmesg | grep -iE "imx386|slg51002" | tail'
#   expect: no error; /sys/bus/i2c/drivers/imx386/*-001a bound;
#   the camera supplies off again in the regulator summary
# CAM3b.2 (next boot) PHY and CSIS drivers bound, nothing started
tools/phone-ssh 'for m in gpio_s2mpg13 slg51002_regulator imx386 phy_gs201_mipi_dcphy_rx gs201_csis; do modprobe $m; sleep 1; done; dmesg | grep -iE "gs201-csis|dcphy" | tail; media-ctl -d /dev/media0 -p'
#   expect: "link 1 -> WDMA context 1, 4 data lanes"; graph imx386 0-001a ->
#   gs201-csis link 1 -> gs201-csis-wdma1; PMU 0x3ebc still 0 (gs201_cam_probe step=pmu)
# CAM3b.3 (next boot) colour bars on the link, no DMA, under the stage
#   tool's kmsg stream and watchdog (tools/camera-stage --watchdog x --cmd '...')
tools/camera-stage --watchdog x --cmd 'for m in gpio_s2mpg13 slg51002_regulator imx386 phy_gs201_mipi_dcphy_rx; do modprobe $m; done; modprobe gs201_csis allow_stream=1 link_only=1; sleep 1
  N=$(media-ctl -d /dev/media0 -p | grep -o "imx386 [0-9]*-001a" | head -1)
  media-ctl -d /dev/media0 -V "\"$N\":0[fmt:SRGGB10_1X10/2016x1508]" -V "\"gs201-csis link 1\":0[fmt:SRGGB10_1X10/2016x1508]"
  S=$(media-ctl -d /dev/media0 -e "$N"); v4l2-ctl -d $S --set-ctrl test_pattern=2
  V=$(media-ctl -d /dev/media0 -e gs201-csis-wdma1); v4l2-ctl -d $V --set-fmt-video=width=2016,height=1508,pixelformat=pRAA
  timeout 5 v4l2-ctl -d $V --stream-mmap --stream-count=1; cat /sys/kernel/debug/*.csis/stats'
```

- **Pass (3b.3):** `frame_start` and `frame_end` rising by about 60 per
  second (300 in the 5 s), `link_errors` 0, `wdma_done` 0 (no DMA). The
  `stopped:` line in dmesg gives the same counters.
- **Not this link:** counters stay 0 with no errors: next boot, the same
  with `camera-stream-link0` (`csis0`, `gs201-csis link 0`,
  `gs201-csis-wdma0`). If neither counts, check the sensor started
  (`0x0100` read back through `i2ctransfer` is out of scope while the
  driver owns it; instead re-run with dyndbg on imx386) and stop.
- **Stop:** link errors (SOT, CRC, ECC in `last_link_err`): the PHY
  settings or settle are wrong for this link: stop, don't try DMA. Any
  hang: the watchdog resets; save pstore.
- **Rollback:** `rmmod gs201_csis imx386` (powers the module down), reboot;
  images without the overlay.

### CAM4: the CSIS WDMA writes frames. Risk: high (first DMA)

The WDMA writes to the buffer address it is given, with its SysMMU in
bypass: a wrong route or a misread address field writes memory we don't
own. So: the test pattern first, at the smallest mode, into the camera
pool only (the driver refuses buffers above 4 GiB), with the watchdog and
the log stream on, and nothing else running that matters.

```sh
# CAM4.1 (next boot) one frame of colour bars, WDMA channel 0, EBUF = context
tools/camera-stage --watchdog x --cmd '...as CAM3b.3 but: modprobe gs201_csis allow_stream=1 wdma_channel=0
  timeout 5 v4l2-ctl -d $V --stream-mmap --stream-count=4 --stream-to=/tmp/bars.raw
  cat /sys/kernel/debug/*.csis/stats; cat /sys/kernel/debug/*.csis/regs'
tools/phone-ssh 'cat /tmp/bars.raw' > logs/cam4-bars.raw
# CAM4.2-4 (one per boot, only while 4.1 fails without errors):
#   wdma_channel=2 (stock's RAW channel); then google,ebuf variations through
#   a DT property change (the WDMA input value is the open question)
# CAM4.5 a real picture: test_pattern=0, then 4032x3016
```

- **Pass (4.1):** `wdma_done` = 4, `wdma_errors` 0, `bars.raw` is 4 x
  2016 x 1508 x 10 / 8 bytes per line rounded to 16 (2528 bytes per line);
  unpacked on the laptop it shows eight vertical colour bars (a small
  python unpacker into a PNG; no debayer needed for bars).
- **Not routed:** `wdma_done` 0, no WDMA errors, link counters running:
  the input mux value is wrong; try the next variant on the next boot.
- **Stop:** `LASTADDR`/`LASTDATA`/`FIFO_FULL` errors, a picture shifted or
  torn, or anything else misbehaving after the run (a write landed
  elsewhere): stop and reboot at once, don't retry before the address
  format is understood. A hang: watchdog, pstore.
- **Rollback:** reboot (DMA stops with the module); images without the
  overlay.

### CAM5: libcamera. Risk: low (userspace)

```sh
# CAM5.0 (laptop) build packages/libcamera on the phone
tools/phone-install-package packages/libcamera
# CAM5.1 the camera is listed
tools/phone-ssh 'cam -l'
#   expect: one camera, "imx386 0-001a" (bus 3 is i2c-0 on our kernel, CAM2.3);
#   soft ISP created (log: SoftwareIsp)
# CAM5.2 one picture
tools/phone-ssh 'cam -c1 --capture=3 --file=/tmp/frame#.ppm --stream pixelformat=RGB888,width=2016,height=1508'
# CAM5.3 GNOME Snapshot through PipeWire; check with a screenshot
```

- **Pass:** a recognisable image (colours off is fine: no tuning yet).
- **Stop:** `cam -l` empty: check `media-ctl -p` and the libcamera log
  (`LIBCAMERA_LOG_LEVELS=SimplePipeline:0`).
- **Rollback:** `pacman -S libcamera` (Arch Linux ARM's build).

---

## 8. Open questions

1. Which link does each camera use? The ultrawide is D-PHY, four lanes,
   1548 Mbps (4.3); its link is 0 or 1 (CAM3b finds out). The other
   three are still open.
2. Does our kernel still see `pd-csis` on (CAM1.1)? If not, the gs201 PD
   driver (shared with `GPU-PLAN.md` G4c) comes first.
3. Are `sysmmu_csis0/1` in bypass and `s2mpu_csis0/1` allow-all after
   ABL, as `s2mpu_hsi0` is?
4. Does the CSIS WDMA take 32-bit byte addresses (stock loads plain
   32-bit values, IOVAs there)? And which WDMA input value selects an
   EBUF, and which channel does a plain capture use (CAM4)?
5. Can mainline `ccs` with static data drive the ultrawide (section 5.3)?
   Not needed now; the IMX386 driver uses the extracted lists.
9. The IMX386's analogue gain formula, black level and pixel size, for a
   libcamera sensor helper and properties entry (no citable source yet).
6. ~~Is the SLG51002 revision AA?~~ No: revision AB (`0xb13103`, stock
   dmesg), no trim needed (section 1.2). CAM2.2 confirms it on our kernel.
7. For the main and tele: if they are C-PHY, can the sensor run a D-PHY
   mode over the same board wiring? (Probably not; the wiring decides.)
8. Can Rockchip's vendor DC-PHY receive code be cited (licensing is GPL;
   it isn't on AGENTS.md's list)? The human decides.
