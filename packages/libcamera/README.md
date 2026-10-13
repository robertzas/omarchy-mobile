<!-- SPDX-License-Identifier: MIT -->
# libcamera (Omandroid build)

This is Arch Linux's libcamera 0.7.2-4, rebuilt for the Pixel 7 Pro. The main
change: the simple pipeline handler learns the `gs201-csis` camera receiver,
with the software ISP on. The other patches add the phone's sensors, contrast
autofocus through the cameras' AK7375 lenses, low-light digital gain and
tuning for the software ISP. libcamera matches the simple pipeline handler only
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
| `0004-libcamera-Add-the-Samsung-S5KGN1-sensor.patch` | The S5KGN1 (main camera) sensor helper, properties and tuning stub |
| `0005-libcamera-software_isp-add-contrast-autofocus.patch` | Contrast autofocus in the simple IPA, and the lens plumbing in the simple pipeline (Robin Snyders) |
| `0006-software_isp-Focus-on-the-frame-centre-with-statisti.patch` | Sharpness over the frame centre, statistics every frame on cameras with a lens, lens writes only while Af runs and on a change, scan steps from tuning |
| `0007-software_isp-Steadier-contrast-autofocus.patch` | Lens settling, peak fit, a continuous mode that doesn't hunt, scans on settled exposure (cube oakley) |
| `0008-software_isp-Keep-exposure-white-balance-and-focus-a.patch` | AGC, AWB and focus survive a reconfiguration of the same mode (cube oakley) |
| `0009-software_isp-Take-contrast-and-saturation-defaults-f.patch` | Contrast and saturation defaults from the tuning file (cube oakley) |
| `0010-software_isp-Gather-GPU-statistics-over-the-visible-.patch` | GPU debayer: 3A statistics over the whole visible frame, not its top-left corner (cube oakley) |
| `0011-ipa-simple-agc-Add-digital-gain-past-the-sensor-s-li.patch` | Up to 4x digital gain once exposure and analogue gain are at their limits |
| `0012-ipa-simple-Tune-the-Pixel-7-Pro-s-ultrawide-and-main.patch` | Af on both cameras, a stand-in colour matrix for the IMX386, contrast and saturation defaults |
| `libcamera-fix-python3.14-macro-redefinition.patch` | Arch's patch, unchanged (sha512 `8b54cbdf…`) |
| `.SRCINFO` | `makepkg --printsrcinfo` output |

## What differs from Arch Linux ARM's `libcamera` 0.7.2-4

- The patches above.
- `arch=(aarch64)`.
- Only the `simple` and `uvcvideo` pipelines (the second is for USB cameras
  on the USB-C port), and only the `simple` IPA. The other aarch64 pipelines
  (`rkisp1`, `rpi/*`, `imx8-isi`, `mali-c55`) can't match on this phone.
- `softisp-gpu=enabled`, so the build fails if EGL is missing instead of
  quietly leaving out the GPU debayer. At runtime libcamera tries the GPU
  first and falls back to the CPU.
- No documentation and no test suite. There is no `libcamera-docs` split;
  ALARM's `libcamera-docs` 0.7.2-4 can stay installed.
- `pkgrel=4.5`, so it sorts above ALARM's 0.7.2-4.

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

## Autofocus, low light and colour (0004-0012)

The simple IPA gets contrast autofocus. The simple pipeline finds a lens
through the sensor's media ancillary link (the DT `lens-focus` property; the
`ak7375` driver gives `V4L2_CID_FOCUS_ABSOLUTE` 0-4095) and passes its
controls to the IPA, which runs a coarse scan over the range, a fine scan
around the sharpest coarse sample and a parabola fit of the peak, and then
watches the sharpness in continuous mode. The sharpness is the squared
difference of neighbouring green samples over the centre half of the frame,
divided by their sum. It needs a lens and an `Af` entry in the tuning file:
without either, nothing writes to a lens and no autofocus metadata is
reported. `coarseSteps`, `fineSteps` and `range: [ min, max ]` in the `Af`
entry set the scan; restricting `range` to the lens's useful travel, once it
is measured, makes scans shorter. On a camera with a lens, statistics run
every frame instead of every fourth: more CPU time per frame for the
statistics, and AGC steps as often as the sensor's two-frame delay allows.
Applications set `AfMode` (`Manual`, `Auto` with `AfTrigger`, `Continuous`,
the default) and, in manual mode, `LensPosition` as 0.0-1.0 of the range
(not dioptres: the lens isn't calibrated).

Once the exposure and the analogue gain are at their limits, AGC adds up to
4x digital gain, applied with the white balance gains; it is reported as
`DigitalGain`.

`imx386.yaml` uses the IMX519 colour matrices from libcamera's Raspberry Pi
tuning (`src/ipa/rpi/vc4/data/imx519.json`, BSD-2-Clause) as a stand-in until
the IMX386 is calibrated: without a matrix the software ISP shows the sensor's
own, desaturated colours. `s5kgn1.yaml` has the identity. Both set a contrast
default of 1.2 (Snapshot and most apps don't set it); the S5KGN1 adds
saturation 1.1.

What the software ISP still lacks: denoising, lens shading correction,
sharpening and a calibrated colour pipeline. White balance is grey-world.
Pictures stay noisier and softer at the corners than with Google's ISP.

## Status

0.7.2-4.4 (0001-0003) runs on the phone: the ultrawide captures end to end.
0.7.2-4.5 (0004-0012) is checked off the phone only (2026-10-13):

- All patches apply in PKGBUILD order to a clean `v0.7.2` checkout with
  `patch -Np1`.
- An x86_64 build of the patched tree with the PKGBUILD's options
  (`simple,uvcvideo`, `softisp-gpu=enabled`, `v4l2`, cam, qcam and the
  GStreamer plugin; no Python bindings on the build host) compiles without
  warnings.
- libcamera's YAML parser reads both tuning files, the S5KGN1 helper gives
  1x and 16x at codes 0x20 and 0x200, and the autofocus algorithm, run on a
  synthetic sharpness curve with a two-frame lens delay, settles within one
  fine step of the peak (about 3 s at 30 fps on the main camera's settings,
  2 s on the ultrawide's).
- `makepkg --printsrcinfo` runs.

To check on the phone, after the AK7375 nodes and the `lens-focus` links are
in the kernel:

```sh
media-ctl -p -d /dev/media0 | grep -B2 -A6 ak7375     # lens entity, ancillary link to the sensor
LIBCAMERA_LOG_LEVELS=IPASoftAf:0,IPASoftExposure:1,SoftwareIsp:1 \
  cam -c1 --capture=150 --file=/tmp/af-#.ppm 2>&1 | grep -E 'Focus range|focus sample|Autofocus completed'
```

Expect "Focus range 0-4095", coarse then fine samples, and "Autofocus
completed at N" within about 100 frames; the frames before and after it should
go from soft to sharp. Without a lens the log says "No focus lens control
available" once and nothing else changes. In a dim room, `IPASoftExposure:0`
shows `dgain` rising above 1 only once `again` is at 16.

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
