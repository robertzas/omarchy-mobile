<!-- SPDX-License-Identifier: MIT -->
# Video codec plan: the MFC (and ffmpeg) on cheetah (gs201)

Status (2026-11-09): **facts only, nothing built.** Written against the phone
on `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty` and Google's
`android-gs-pantah-6.1-android16` `soc/gs` tree.

Goal: hardware H.264/HEVC/VP9 decode and encode from ffmpeg (`*_v4l2m2m`)
through a V4L2 mem2mem driver for gs201's Samsung MFC, without touching the
radio, calibration data or Trusty.

## 1. What the phone has today

- ffmpeg n9.0.2 (Arch Linux ARM) with hwaccels `vdpau vaapi drm opencl
  vulkan amf`, every `*_v4l2m2m` decoder and encoder wrapper, and 18
  Vulkan filters. There is no V4L2 codec device: `/dev/video0-3` are the
  camera's CSIS nodes.
- Vulkan works on the Mali-G710 MC7 through Mesa's `vulkan-panfrost`
  (panvk) ICD: `ffmpeg -init_hw_device vulkan` selects it (rc 0). So
  Vulkan compute filters (`scale_vulkan` and friends) are usable now. The
  `h264_vulkan`/`hevc_vulkan`/`av1_vulkan` decoders need the Vulkan video
  extensions, which panvk does not expose and the GPU has no hardware
  for; they are not a path to hardware decode here.
- Our DT has no MFC node. The live DT shows only the TPU's
  `sysmmu@1cc40000` among the 1cxxxxxx blocks we enabled.

## 2. The stock parts (Google's GPL tree)

- Driver: `drivers/media/platform/exynos/mfc/` (79 files) and `smfc/`
  (the JPEG codec) in `kernel/google-modules/soc/gs`, built into the
  `gs201_soc` module set as `exynos_mfc.ko` (`gs201-device/BUILD.bazel`).
  The laptop clone `~/omamobile-kernel/soc-gs` is sparse and does not
  check them out yet (`git sparse-checkout add drivers/media/platform/exynos`).
- DT: `gs201-device/dts/gs201-mfc.dtsi`: `compatible = "samsung,exynos-mfc"`,
  `iommus = <&sysmmu_mfc0>, <&sysmmu_mfc1>`, an iommu group with a reserved
  map, `samsung,tzmp` (secure/TrustZone media path), NAL-Q, SBWC and the
  encoder parameter tables. The `reg`, interrupt, clocks, power domain and
  `ip_ver` come from the SoC dtsi (`gs201-*.dts`), still to be read.
  `gs201-bigo.dtsi` is the separate "bigocean" AV1 decoder at
  `0x1cb00000` (`google,bigocean`, `pd_bo`, `sysmmu_bo`).
- Firmware: the MFC loads a signed `mfc_fw.bin` (`device/google/gs201`
  ships `firmware/mfc/`); it has to come from the owner's own factory image
  (`tools/extract-vendor-firmware`), never from the repository.

## 3. Shape of the work

1. Read-only: the MFC node's `reg`/irq/clocks/power-domain from the SoC
   dtsi and stock `/proc/iomem`; find `mfc_fw.bin` in the vendor image.
2. Offline: port `exynos_mfc` to our tree as an out-of-tree module
   (`CONFIG_VIDEO_EXYNOS_MFC=m`), with its two SysMMU v8 instances on the
   `samsung_iommu` driver the TPU already uses, DT node `disabled` plus an
   overlay in `device/cheetah/overlays/`.
3. One change per boot: SysMMUs first, then the MFC probe without firmware,
   then the firmware load, then one `ffmpeg -c:v h264_v4l2m2m` decode of
   `out/bench/mosaic12.mp4` to `-f null`, then encode.

Risks: the TZMP path may require a secure-world handshake we cannot make
(the AoC and TPU firmware loads both went through the GSA); the driver is
large and tied to Google's dma-buf heaps and `samsung_dma_heap`.
