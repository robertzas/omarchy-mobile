# TPU bring-up: next iteration (2026-11-09, after U159)

Read `device/cheetah/TPU-PLAN.md` U150-U159 and `AGENTS.md` first. Phone:
up, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware at
`/lib/firmware/updates/google/edgetpu-janeiro.fw` (sha `52c1cccd…`).

**Do not run `tpu-a14-hal` or any direct `/dev/edgetpu` create again** (U154:
it blocks in the driver and reset the phone). Use the Tachyon ring harness.

**State.** The port's driver matches Google's stock Android 16 gs201 driver
(U156). The GSA image manager's `tpu_get_img_config` copies the 0x100-byte
`mobile_image_config` (U158), which is identical in the A14, A17 and cp3a
firmware: carveout `0x93000000`, firmware `0x93000000` + `0xfd000`, and the
mapping table `0x10000000→0x93000000` (16 MiB), `0x11000000→0x18290000`
(64 KiB), `0x11010000→0x1cc00000` (64 KiB), plus one NS mapping
`0x12000012` (U159). Those are the type-1 setup's global scratch ranges.

1. **Find the setup element's format.** Disassemble the stock util's setup
   builder and the tegu core's builder at `core+0x7f9c4` (the plan's U51)
   and compare how they lay out the 0x100-byte config's mapping entries.
   The A17 util is in `/usr/lib/omamobile-vendor/edgetpu/root/vendor/lib64/libedgetpu_util.so`
   (and `out/a14-edgetpu/libedgetpu_util.so`); the tegu core is
   `out/edgetpu-runtime/libtachyon_core.so`.
2. **Build and submit the type-1 setup** through the Tachyon ring client
   (`TYPES=2,5,5,7 UORDER=MDMK` plus the gdb patch at `core+0x5968c`), with
   the mapping table as the global scratch list. Success is visible as the
   firmware no longer answering `Setup is not done yet` and RegisterGraph
   proceeding.
3. **Then the pipeline.** RegisterGraph (7), CreateExecution (9),
   BindInputBuffers (12), BindOutputBuffers (13), Invoke (11) on the SSD
   300x300 int8 model; 60 frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record the date and `uname -r`, replace this prompt,
   and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the commit.
