<!-- SPDX-License-Identifier: MIT -->
# libcamera (Omandroid build)

This is Arch Linux's libcamera 0.7.2-4, rebuilt for the Pixel 7 Pro with one
change: the simple pipeline handler learns the `gs201-csis` camera receiver,
with the software ISP on. libcamera matches the simple pipeline handler only
against a fixed table of media-device driver names. So without the entry,
stock libcamera ignores our receiver, even though the soft ISP is already
built into Arch Linux ARM's package. A `configuration.yaml` can't add a
driver in 0.7.2: it can only switch the soft ISP for a driver that is already
in the table. See `device/cheetah/CAMERA-PLAN.md`, section 5.2.

| File | What it is |
| --- | --- |
| `PKGBUILD` | Arch's `libcamera` PKGBUILD at tag `0.7.2-4`, trimmed for this phone (see its header) |
| `0001-pipeline-simple-Add-the-Google-gs201-CSIS-receiver.patch` | The libcamera change, in `git format-patch` form; it also applies to upstream master |
| `0002-libcamera-Add-the-Sony-IMX386-sensor.patch` | The IMX386 sensor helper, properties and tuning stub |
| `0003-ipa-simple-agc-Step-faster-when-far-from-the-target-.patch` | Faster AGC steps far from the target |
| `libcamera-fix-python3.14-macro-redefinition.patch` | Arch's patch, unchanged (sha512 `8b54cbdf…`) |
| `.SRCINFO` | `makepkg --printsrcinfo` output |

## What differs from Arch Linux ARM's `libcamera` 0.7.2-4

- The patch above.
- `arch=(aarch64)`.
- Only the `simple` and `uvcvideo` pipelines (the second is for USB cameras
  on the USB-C port), and only the `simple` IPA. The other aarch64 pipelines
  (`rkisp1`, `rpi/*`, `imx8-isi`, `mali-c55`) can't match on this phone.
- `softisp-gpu=enabled`, so the build fails if EGL is missing instead of
  quietly leaving out the GPU debayer. At runtime libcamera tries the GPU
  first and falls back to the CPU.
- No documentation and no test suite. There is no `libcamera-docs` split;
  ALARM's `libcamera-docs` 0.7.2-4 can stay installed.
- `pkgrel=4.1`, so it sorts above ALARM's 0.7.2-4.

## What the kernel side must provide

The full checklist, with `file:line` references into libcamera 0.7.2,
belongs in CAMERA-PLAN section 5.2. In short:

- The media device's driver name is `gs201-csis`.
- The sensor entity is `MEDIA_ENT_F_CAM_SENSOR`.
- The CSIS subdev passes the sink format through to its source pad, for both
  TRY and ACTIVE formats.
- The video node has `V4L2_CAP_IO_MC`, `ENUM_FMT` filtered by mbus code, and
  `ENUM_FRAMESIZES`. Its buffers are vb2 MMAP and DMABUF, with EXPBUF.
- The sensor has the `ANALOGUE_GAIN`, `EXPOSURE`, `HBLANK`, `VBLANK` and
  `PIXEL_RATE` controls.
- The kernel has a dma-buf heap (`/dev/dma_heap/*` or `/dev/udmabuf`), or
  the soft ISP isn't created.

Both debayers take CSI-2 packed RAW10 and RAW12 and 8-bit RAW. The GPU path
doesn't take unpacked 12-bit.

`0002-libcamera-Add-the-Sony-IMX386-sensor.patch` adds the IMX386's
`CameraSensorHelper` (black level 64 at 10 bits, measured on the phone in
CAM4.3; the analogue gain model of the IMX258, code 0-480 for 1x-16x,
confirmed by the CAM4.3c gain sweep), its sensor properties (1.25 um
unit cell, the driver's CCS test pattern numbers, two-frame delays) and
`imx386.yaml`, an uncalibrated tuning file for the simple IPA. The sweep
showed the register is 9 bits wide (codes from 512 wrap), so 480 stays the
top.

`0003-ipa-simple-agc-Step-faster-when-far-from-the-target-.patch` makes the
simple IPA's AGC take larger steps (proportional gain 0.1, still at most 15%)
while the exposure error is above 1.0; near the target it keeps upstream's
0.04. Indoors the first frames otherwise stayed black for seconds.

## Status

The package has **not been built yet**. It will be built natively on the
phone. What has been checked:

- Both patches apply to the `v0.7.2` tag (`patch -Np1 --dry-run`). Ours also
  passes `git apply --check`, on the tag and on master.
- Every meson option and value used exists in 0.7.2's `meson_options.txt`.
- `makepkg --printsrcinfo` runs.

## Building on the phone

```sh
tools/phone-install-package packages/libcamera
```

The tool's `pacman -U` glob (`libcamera-*`) installs `libcamera`,
`libcamera-ipa` and `libcamera-tools`. `gst-plugin-libcamera` and
`python-libcamera` are built too; install them by hand if needed.

Then try `cam -l` and `cam -c1 --capture=1 --file=frame.ppm`, after the
camera kernel stages in CAMERA-PLAN. Without Panthor rendering, the GPU
debayer runs on llvmpipe. To compare it with the CPU path, set
`LIBCAMERA_SOFTISP_MODE=cpu`.

Rebase on each new ALARM libcamera release, and drop the patch once
upstream ships the entry. Send it upstream together with the kernel driver;
the human adds `Signed-off-by:`.
