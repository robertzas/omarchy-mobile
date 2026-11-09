# TPU bring-up: next iteration (2026-11-09, after U157)

Read `device/cheetah/TPU-PLAN.md` U150-U157 and `AGENTS.md` first. Phone:
up, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware at
`/lib/firmware/updates/google/edgetpu-janeiro.fw` (sha `52c1cccd…`).

**Do not run `tpu-a14-hal` or any direct `/dev/edgetpu` create again** (U154:
it blocks in the driver and reset the phone). Use the Tachyon ring harness.

**State.** The port's `drivers/edgetpu` matches Google's stock Android 16
gs201 driver (U156); the missing setup is external to the driver. The
bootloader's GSA firmware at `out/factory/cheetah-abl/…` offset `0x7fbe00`
is the TPU image manager (`tpu-image.c`, `tpu_get_img_config`, `TPUF`,
`tpu_start`, `GSA_MB_CMD_AUTH_IMG`); its strings are at known `.rodata`
offsets but the code resolves them pc/base-relative (U157).

1. **Finish the GSA firmware analysis.** Disassemble the ELF32 ARM image at
   `0x7fbe00` with `llvm-objdump --triple=armv7`, resolve the `adr`/`add`
   references to the `.rodata` strings listed in U157, and read
   `tpu_get_img_config` (the `sizeof(tpu_img_config)` check and every field
   it reads) and `tpu_start`/the `AUTH_IMG` path. That gives the image
   manager's config layout, including the global scratch list and the
   cluster bitset if it carries them.
2. **Cross-check the Trusty apps**: the aarch64 `hwmgr` at `0x6bd400`
   (`hwmgr.tpu`, `tpu-mbox`) and the app at `0x7db800` (`tpu-mbox`,
   `tpu-mgr`) — the bootloader's other TPU path.
3. **Then the pipeline.** RegisterGraph (7), CreateExecution (9),
   BindInputBuffers (12), BindOutputBuffers (13), Invoke (11) on the SSD
   300x300 int8 model; 60 frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record the date and `uname -r`, replace this prompt,
   and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the commit.
