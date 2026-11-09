# TPU bring-up: next iteration (2026-11-09, after U160)

Read `device/cheetah/TPU-PLAN.md` U150-U160 and `AGENTS.md` first. Phone:
up, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware at
`/lib/firmware/updates/google/edgetpu-janeiro.fw` (sha `52c1cccd…`).

**Do not run `tpu-a14-hal` or any direct `/dev/edgetpu` create again** (U154:
it blocks in the driver and reset the phone). Use the Tachyon ring harness.

**State.** The port's driver matches Google's stock Android 16 gs201 driver
(U156). The GSA image manager copies the 0x100-byte `mobile_image_config`
(U158), identical in A14/A17/cp3a, with the mapping table
`0x10000000→0x93000000` (16 MiB), `0x11000000→0x18290000` (64 KiB),
`0x11010000→0x1cc00000` (64 KiB) and one NS mapping (U159). The tegu
core's setup producer is the `PushFirmwareSetupCmdToVII` path (U160), but
its per-component push (`0xab0c4`) and DIVE scratch path are tegu-specific.

1. **Read the cheetah HAL's setup builder.** The A14/A17 runtime is inside
   `libdarwinn_hal.so` (`out/a14-edgetpu/libdarwinn_hal.so`;
   `/usr/lib/omamobile-vendor/edgetpu/root/vendor/lib64/libdarwinn_hal.so`
   on the phone). Find its `PushFirmwareSetupCmdToVII`/`FirmwareSetupStatus`
   strings and disassemble the setup builder. Decode the command **type**
   (the firmware's `type 0` refusal vs the expected type 1), the VII
   version, and the scratch list (global scratch descriptors and the
   cluster bitset), using the 0x100-byte config's mapping entries.
2. **Build and submit the type-1 setup** through the Tachyon ring client
   (`TYPES=2,5,5,7 UORDER=MDMK` plus the gdb patch at `core+0x5968c`).
   Success is the firmware no longer answering `Setup is not done yet` and
   RegisterGraph proceeding.
3. **Then the pipeline.** RegisterGraph (7), CreateExecution (9),
   BindInputBuffers (12), BindOutputBuffers (13), Invoke (11) on the SSD
   300x300 int8 model; 60 frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record the date and `uname -r`, replace this prompt,
   and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the commit.
