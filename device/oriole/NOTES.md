<!-- SPDX-License-Identifier: MIT -->
# Pixel 6 (oriole) bring-up notes

Findings for the Pixel 6 port, newest first. The port is a community effort tracked in [issue #2](https://github.com/derekross/omarchy-mobile/issues/2); the 6 Pro (raven) and 6a (bluejay) share it. Facts are marked [V] (checked, with the source) or [I] (an inference to check on a phone). Nothing here has run on a phone yet.

Sources:

- `F/`: Google's public factory image `oriole-cp3a.261005.002.a1` ([developers.google.com/android/images](https://developers.google.com/android/images#oriole)), read with HTTP range requests; facts only, no files kept in the repository.
- `U/`: upstream Linux v7.0, `arch/arm64/boot/dts/exynos/google/gs101*.dts(i)`.
- `P/`: postmarketOS pmaports [`device/testing/device-google-oriole`](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/tree/main/device/testing/device-google-oriole), [`soc-google-gs101`](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/tree/main/device/testing/soc-google-gs101) and [`linux-postmarketos-gs101`](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/tree/main/device/testing/linux-postmarketos-gs101) (7.0.6), which builds [gs101-mainline/linux @ d28cfa42](https://github.com/gs101-mainline/linux/tree/d28cfa4275b95e93f4b7a1e743de31b723bd21b8).

## 2026-10-14: stage 0, part 1: facts from the factory image (no phone)

### Boot images and partitions

- **No `init_boot` and no `vendor_kernel_boot`** [V] (F/ image zip): the image ships `boot`, `vendor_boot`, `dtbo`, `pvmfw`, the vbmetas and the dynamic partitions, and `fastboot-info.txt` flashes `boot`, `dtbo`, `pvmfw` and `vendor_boot`. So `BOOT_IMAGES="boot vendor_boot dtbo"`: the DTB and our initramfs go in `vendor_boot`, and the generic (empty) ramdisk and the OS version in `boot`. `bin/omamobile images`, `flash` and `push` handle that layout, and `tests/images-layout` checks it. `fastboot getvar all` still has to confirm the partition table [I].
- **Header v4 for `boot` and `vendor_boot`** [V] (F/): `vendor_boot` page size 0x800, two vendor ramdisks and a bootconfig section. Stock's `boot` header leaves `os_version` at 0 (GKI; the AVB footer carries it), so `OS_VERSION`/`OS_PATCH_LEVEL` in `device.conf` are the factory build's (17.0.0, 2026-10) [I].
- **One image for four boards** [V] (F/ `android-info.txt`): `board=slider|whitefin|oriole|raven`.

### Base DTB

- **Two base DTBs, by `soc_id`** [V] (F/ `vendor_boot`): `<0x9845000 0x00>` and `<0x9845001 0x00>`, both with root compatible `google,gs101`. They are gs101's counterparts of cheetah's `0x9855000`/`0x9855001`. Which is A0 and which is B0, and which one a retail phone has, are [I].
- **Upstream's gs101 DTs carry no `/soc_id`** [V] (U/), while `bin/omamobile images` requires the DTB to be built with the first `SOC_IDS` value. Our oriole board DTS (or a kernel commit) has to add it. postmarketOS boots the upstream DTB without one (P/), so ABL may fall back to the first DTB when nothing matches [I].
- **`/ect` and `/chosen/bootargs`** [V]: stock has both, and upstream `gs101.dtsi`/`gs101-pixel-common.dtsi` keep both ("required to be present by bootloader", "otherwise it crashes").
- **Root `#address-cells = <2>`, `#size-cells = <1>`** [V] (F/), as on gs201: each `reg` entry is 12 bytes (AGENTS.md, reserved memory).
- **Console UART at `0x10A00000`** [V] (F/ stock bootargs: `earlycon=exynos4210,mmio32,0x10A00000`), the same address as gs201's.

### Board dtbo

[V] (F/ `dtbo.img`: 18 entries, page size 4096), read from each entry's strings:

| board_id | board_rev | Panel | Touch | Board |
| --- | --- | --- | --- | --- |
| 0x20302, 0x20303, 0x20304 | 0x10000, 0x10100 (0x20303 also 0x10002) | S6E3FC3 | ST FTS | oriole |
| 0x20202, 0x20203, 0x20204 | 0x10000, 0x10100 (0x20203 also 0x10001) | S6E3HC3 | Samsung `sec_ts` | raven |
| 0x201, 0x20001 | several | S6E3HC2 | both | development boards [I] |

- **Oriole's panel is the Samsung S6E3FC3; its touch controller is an ST FTS on SPI** [V] (F/, and P/'s oriole DT: `"st,spi"` on SPI11, an out-of-tree driver). "goodix" in every entry is the under-display fingerprint sensor [I].
- **Retail board_id/board_rev** [I]: probably the newest, `0x20304`/`0x10000` (cheetah's is `0x30306`/`0x10000`). `getprop ro.boot.dtbo_idx` on the phone settles it; `device.conf` and `oriole-m1-overlay.dts` use 0x20304/0x10000 until then.

### Display trigger

- **postmarketOS writes `0x3061` to DECON at `0x1c300030` at boot** "to enable framebuffer refreshing" (P/ `soc-google-gs101/00-enable-fb.sh`). That is gs101's counterpart of cheetah's `TRIG_CON` write at `0x1c240030` [I]. Read it first, on a booted phone, before any write, and never use cheetah's address on oriole. It belongs in `device.conf` as `SIMPLEFB_TRIG_CON="0xADDR 0xVALUE"` (the key from #3 and #4), not in code; oriole gets no `SIMPLEFB_TRIG_CON` until that read has been done.

### GPU

- **The Mali-G78 is a Valhall Job Manager GPU, so the kernel driver is Panfrost, not Panthor** [V] (P/: `arm,mali-valhall-jm`, `DRM_PANFROST=y`). Our Mesa package already builds the `panfrost` Gallium driver, which serves both. The GPU node and its supplies are in the gs101-mainline fork, not upstream v7.0 [V] (U/, P/).

### Still needs a phone

- `ro.boot.dtbo_idx` and the `soc_id` the phone reports;
- `fastboot getvar all` (partition table and sizes, slot state);
- with root: the live DT (`/sys/firmware/fdt`) and `/proc/iomem`, to check every stock `reserved-memory` region.

`bin/omamobile capture` collects these into a private folder (`~/android/reference`); post facts, never the files.

And before oriole's first boot, in the tree:

- **An initramfs.** `INITRAMFS_INIT` names a file that doesn't exist yet, so `DEVICE=oriole bin/omamobile initramfs` fails. Once #4 lands, oriole uses the shared `initramfs/init`.
- **The storage guard's allowlist packed from the descriptor.** The shared init still hard-codes cheetah's six-name `UFS_RW`, and the build requires an exact match with the descriptor, so oriole's `boot_b vendor_boot_b dtbo_b userdata` is refused. That fails closed, as it should; the init has to take the allowlist from `device.conf` first.
- **`/soc_id` in the board DTS** (see Base DTB).
