# TPU bring-up: next iteration (2026-11-09, after U158)

Read `device/cheetah/TPU-PLAN.md` U150-U158 and `AGENTS.md` first. Phone:
up, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware at
`/lib/firmware/updates/google/edgetpu-janeiro.fw` (sha `52c1cccd…`).

**Do not run `tpu-a14-hal` or any direct `/dev/edgetpu` create again** (U154:
it blocks in the driver and reset the phone). Use the Tachyon ring harness.

**State.** The port's driver matches Google's stock Android 16 gs201 driver
(U156). The GSA firmware's `tpu_get_img_config` (U158) copies exactly
**0x100 bytes** — the kernel's `mobile_image_config` — from the image at
`TPUF` + `0x160`; it carries the 23-entry mapping table (TPU virtual address
+ physical page), which is the firmware's memory setup.

1. **Decode the config.** Read `out/tpu-firmware/edgetpu-janeiro.fw`
   (A17), `out/tpu-firmware/edgetpu-janeiro-a14.fw` (A14) and
   `out/factory/cp3a/janeiro-cp3a.fw` at `0x400 + 0x160 = 0x560`, parse the
   `mobile_image_config` (`carveout_base`, `firmware_base`, `firmware_size`,
   `firmware_versions`, `config_version`, `privilege_level`,
   `remapped_region_start/end`, the 23 `iommu_mapping` entries and the 5
   non-secure mappings), and compare the three images. Those mapping entries
   are the type-1 setup's global scratch list.
2. **Build and submit the type-1 setup** through the Tachyon ring client
   (`TYPES=2,5,5,7 UORDER=MDMK` plus the gdb patch at `core+0x5968c`), with
   the mapping list as the firmware setup element. If the setup completes,
   the firmware stops answering `Setup is not done yet` and RegisterGraph
   proceeds.
3. **Then the pipeline.** RegisterGraph (7), CreateExecution (9),
   BindInputBuffers (12), BindOutputBuffers (13), Invoke (11) on the SSD
   300x300 int8 model; 60 frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record the date and `uname -r`, replace this prompt,
   and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the commit.
