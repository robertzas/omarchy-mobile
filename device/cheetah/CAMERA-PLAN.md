<!-- SPDX-License-Identifier: MIT -->
# Camera plan (cheetah / gs201): raw capture first, then libcamera

Status (2026-10-12): **offline research only. Nothing is built and nothing
has run on the phone.** Every runbook step in section 7 is a stub marked
*not yet built*. No kernel branch exists yet; the plan proposes
`omandroid-camera` in `~/android/mainline/wt-camera`, output
`~/android/mainline/out-camera`, on top of `omandroid-int` (it needs the
S2MPG13 regulators from `omandroid-gnss` and the ACPM link).

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
| Ultrawide | `sensor-sandworm` | Sony IMX386 [I] | `hsi2c_3` (`0x10920000`), `0x1a` | 16/8 | gpp6-3 | `CIS_CLK0`, gpp3-0 (`sensor_mclk1`), 24 MHz |
| Tele | `sensor-kraken` | Samsung GM5 [I] | `hsi2c_4` (`0x10930000`), `0x2d` | 16/16 | gpp6-2 | `CIS_CLK2`, gpp7-0 (`sensor_mclk3`), 24 MHz |

Evidence **[V]**: `GD/pantah/dts/gs201-cheetah-camera.dtsi` (nodes "REAR
CAMERA NAGUAL", "FRONT CAMERA DOKKAEBI", "REAR ULTRA WIDE CAMERA SANDWORM",
"REAR Folded Tele Camera KRAKEN"), the same in `R/live.dts:18745-18863`.
Reset lines are active high in LWIS terms (driven 1 to run). MCLK pads have
two pinctrl states: function 1 with pull-down (`mclk_off`) and function 2
(`mclk_on`).

Sensor part names come from the HAL (`vendor.camera.debug.enable_gn1_*`
properties in `A/lib64/liblyric_hwl.so`) and from public teardowns; only GN1
has a string in the HAL. **The CAM2 chip-ID reads settle them** (Sony model
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
     the first thing we can talk to: one rail, no MCLK, no reset (CAM1).

Stock writes "revision AA" trim values into the SLG51002 by entering a
software test mode (`slg51002-core.c:170-190, 265-300`). We do that only if
the chip ID says revision AA, and only after reading back the current values.

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
  driver, so **on our kernel these domains should still be on** [I: CAM0/CAM3
  confirm it through the kernel's PMU regmap]. Two consequences:
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
| `hsi2c_1-4` (PERIC0 USI1-4) | driver yes | no DT nodes (we have USI5, 7, 8) | DT: USI1-4 with `samsung,sysreg = <&sysreg_peric0 0x1000..0x100c>` [I: from stock `usi-offset` 0-0xc and our USI8 at `0x101c`], SPI 674-677, pins gpp2/4/6/8 0-1, 1 MHz (buses 1, 4) and 950 kHz (2, 3) as stock |
| S2MPG13 LDO12S | — | descriptor in `s2mps11.c`; `pmic-2` disabled by default, proven by GNSS G1 | add `ldo12s` to `pmic-2` |
| S2MPG13 GPIO bank | no | no | regmap for bank `0x0c` in `sec-acpm.c` + a small gpio driver (port of GPL `s2mpg1x-gpio`) |
| SLG51002 | no (`slg51000` only) | no | port GPL `slg51002-core/regulator/pinctrl` (about 1.9k lines) as a regulator driver |
| CIS_CLK0-7 | — | in `clk-gs201.c` | DT consumers |
| DC-PHY RX | no | no | new generic PHY driver (D-PHY first) |
| CSIS link + WDMA | no | no | new V4L2 driver |
| Sensors | none of the four | — | IMX386 [I] first (or `ccs` + static data, section 5.3), then 3J1, GM5, GN1 |
| AF actuators | `ak7375`-style drivers exist | — | identify `0x0c`/`0x0f` parts by ID register |
| SysMMU v8 | no | no | bypass for now |
| PD driver | no | no | later (runtime PM) |
| V4L2 core, `VIDEOBUF2_DMA_CONTIG`, DMA-BUF heaps (system, CMA) | yes | built as modules | `CMA_SIZE_MBYTES=32` is too small: add a reserved pool |
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

### 4.2 Work items

| Item | Question | How |
|---|---|---|
| RE1 | link, PHY type, lanes, MIPI rate per camera | find the `ModuleDescriptor` values per sensor; cross-check on the phone by which link counts frames (CAM5) |
| RE2 | CSIS link control: enable, lane count, data type and virtual channel per channel, `ISP_CONFIG` fields | the code that fills `csis_cmn_ctrl`, `isp_config_ch0` (compare with `imx-mipi-csis` bit fields) |
| RE3 | CSIS WDMA: format codes for RAW10/RAW8/RAW16, packing, stride rules, address slot use, enable/abort, link routing | the code around the context-0 control and format registers and the common DMA config register |
| RE4 | ultrawide mode tables: one binned or 1080p-class mode, its PLL, line length, frame length | the sandworm sensor driver; express as CCS-standard registers where they are standard |
| RE5 | C-PHY settings (main/tele, if C-PHY) | the PHY write sequence for `use_cphy` |

---

## 5. Design

### 5.1 Kernel (`omandroid-camera`, not yet built)

1. `arm64: dts: exynos: gs201: add USI1-4 and the camera I2C buses`
   (disabled).
2. `mfd: sec: s2mpg13: add the GPIO bank` + `gpio: s2mpg13` (read-only
   until CAM2), `ldo12s` in `pmic-2`.
3. `regulator: add SLG51002` (port; binding first).
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
   `CONFIG_REGULATOR_SLG51002=m`, sensor modules.

### 5.2 Userspace (not yet built)

- libcamera: a patch adding our driver to the simple pipeline handler's
  supported-device table with the software ISP, a `CameraSensorHelper`
  for the gain model, and a sensor properties entry (unit cell size). Ship
  as a package patch until upstream; send upstream.
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
- Manufacturer-specific "global" settings that only the HAL has are
  generated on the user's machine by a new `tools/extract-camera-data`
  (like `tools/extract-vendor-firmware`) and loaded with `request_firmware()`
  from `/usr/lib/firmware/omandroid/camera/`. Check whether mainline's
  `ccs` driver with CCS *static data* (its documented firmware format for
  manufacturer-specific registers and limits) can drive the ultrawide; if
  so, the sensor needs no new driver at all.
- Upstream may object to a driver that can't stream without a vendor data
  file. That is the honest trade-off; record it in the cover letter.

---

## 6. Stages, effort and timeline

| Stage | What | Needs | Effort |
|---|---|---|---|
| CAM0 | Read-only: clocks, pins, LDO12S, libcamera, CMA (current int kernel) | nothing | 0.5 day |
| CAM1 | Read-only kernel probe: PMU status of the camera domains, then CSIS link versions, one register per boot | probe module | 2-3 days |
| CAM2 | Rails, one per boot: LDO12S → EEPROMs; S2MPG13 GPIO 0 → SLG51002 chip ID; full ultrawide sequence → sensor chip ID | buses, S2MPG13 GPIO, SLG51002 | 1.5-2 weeks |
| RE1-RE4 | Offline HAL analysis (section 4) | REA | 2-3 weeks, in parallel with CAM2 |
| CAM3 | Ultrawide streams a test pattern; DC-PHY RX up; the link counts frames, no errors | PHY driver, sensor driver, RE1, RE4 | 2 weeks |
| CAM4 | CSIS WDMA writes the test pattern, then a real image, to a file (`v4l2-ctl`) | CSIS/WDMA driver, RE2, RE3 | 2-3 weeks |
| CAM5 | libcamera `cam` photo; PipeWire app preview | libcamera patch | 1 week |
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

## 7. Runbook stubs (gated; none of this is built)

Phone in Arch over USB, from the omandroid repo. Each step: run it only when
the human says go; record the result here with the date and `uname -r`.
`ov` is the overlay helper from AUDIO-PLAN.md.

### CAM0: read-only, current int kernel (not yet run). Risk: none

```sh
**CAM0 partial result (2026-10-12, 7.3.0-rc6-omandroid-push1-00306-g60d3ca176c80),
read-only.** `clk_summary`: the CMU's sensor clocks (`mout/gout/dout_cmu_cis_clk5..7`
seen) are registered at 24.576 MHz, enable count 0, hardware enable Y, so ABL
leaves them running with no consumer. No `/dev/dma_heap` (CONFIG_DMABUF_HEAPS
and the system/CMA heaps are off in our config), CMA 124 MiB total, about
68 MiB free; no `/dev/video*` or `/dev/media*`; libcamera not installed. Not
yet done: the pin states (need the reset/MCLK pin names from the plan's
table) and LDO12S, which needs the pmic-2 regmap (bound only while the GNSS
power stack runs, as FINGERPRINT-PLAN FB2 found).

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

### CAM1: domain status, then CSIS versions (probe module; not yet built). Risk: medium

A throwaway module, `gs201-cam-probe`, under `--watchdog` with the log
stream on:

```sh
# CAM1.1 PMU status only: CSIS_STATUS (0x2404) and PDP_STATUS (0x2484) through
#        the exynos-pmu regmap; DC-PHY isolation (0x3ebc). No other register.
tools/phone-ssh 'modprobe gs201-cam-probe step=pmu; dmesg | tail -5'
#   pass: CSIS and PDP status bit 0 = 1 (on)
#   stop: either domain off -> do not run CAM1.2; the PD driver moves up
# CAM1.2 next boot: CSIS link 0 version register (0x1a440000), one read
tools/phone-ssh 'modprobe gs201-cam-probe step=link0; dmesg | tail -3'
#   pass: a plausible version word (not 0, not 0xffffffff)
#   then, one per boot: links 1-7, the CSIS DMA first page, the PHY bias block
# rollback: rmmod gs201-cam-probe (it only reads)
```

The module refuses CAM1.2 unless CAM1.1's status check passes in the same
load.

### CAM2: rails, one change per boot (not yet built). Risk: medium

Overlay `camera-buses-test` (USI1-4, `hsi2c_1-4`), `ldo12s` in `pmic-2`,
the S2MPG13 GPIO driver, the SLG51002 driver blacklisted until CAM2b.

```sh
# CAM2a LDO12S on; read the two LDO12S-only EEPROMs (ID bytes only, nothing kept in the repo)
#   expect: hsi2c_2 0x51 and hsi2c_3 0x50 ACK; i2cdetect shows nothing unexpected
#   stop: a bus error or a NACK on both -> rail or bus setup wrong; LDO12S off
# CAM2b S2MPG13 GPIO 0 high (SLG51002 CS), 10 ms; read 0x1105-0x1107 on hsi2c_8 0x75
#   expect: a 24-bit chip ID; record whether it is revision AA (0xafda01)
#   stop: haptics on the same bus misbehave -> CS low, stop
# CAM2c full ultrawide sequence (section 1.2), chip ID at 0x0016, then the full power-down
#   expect: a Sony model ID (0x0386 if it is the IMX386 [I]); all rails off afterwards
# CAM2d-f the same for front, tele, main (each its own boot)
# rollback each: the driver's power-down sequence; images without the overlay
```

### CAM3-CAM5 (outline; runbooks written when the drivers exist)

- **CAM3:** ultrawide in its test-pattern mode streaming on the link
  RE1 names; pass = link frame counter rising and INT0 errors at 0. If RE1
  is unknown, enable the PHY and link one candidate per boot.
- **CAM4:** WDMA context 0 into the reserved pool: test pattern first
  (compare against the expected bars), then a real image saved with
  `v4l2-ctl --stream-mmap --stream-count=1 --stream-to=`; pass = a
  recognisable picture after an offline debayer on the laptop.
- **CAM5:** `cam -c1 --capture=1 --file=` through the simple handler and
  the soft ISP, then GNOME Snapshot through PipeWire. Check the app on the
  phone with a screenshot before calling it done.

---

## 8. Open questions

1. Which link, PHY type and lane count does each camera use (RE1)? Is the
   ultrawide really D-PHY?
2. Does our kernel still see `pd-csis` on (CAM1.1)? If not, the gs201 PD
   driver (shared with `GPU-PLAN.md` G4c) comes first.
3. Are `sysmmu_csis0/1` in bypass and `s2mpu_csis0/1` allow-all after
   ABL, as `s2mpu_hsi0` is?
4. Does the CSIS WDMA take 32-bit physical addresses directly, or a
   shifted address (more than 4 GiB reachable)?
5. Can mainline `ccs` with static data drive the ultrawide (section 5.3)?
6. Is the SLG51002 revision AA, and is its trim already applied by ABL?
7. For the main and tele: if they are C-PHY, can the sensor run a D-PHY
   mode over the same board wiring? (Probably not; the wiring decides.)
8. Can Rockchip's vendor DC-PHY receive code be cited (licensing is GPL;
   it isn't on AGENTS.md's list)? The human decides.
