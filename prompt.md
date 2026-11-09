# TPU bring-up: next iteration (2026-11-09, after U161)

Read `device/cheetah/TPU-PLAN.md` U150-U161 and `AGENTS.md` first. Phone:
up, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware at
`/lib/firmware/updates/google/edgetpu-janeiro.fw` (sha `52c1cccd…`).

**Do not run `tpu-a14-hal` or any direct `/dev/edgetpu` create** (U154: it
blocks in the driver and reset the phone). Use the Tachyon ring harness.

**State.** The A17 vendor stack is the cheetah's real Tachyon stack
(U161): `out/a17-edgetpu/` has the A17 core, util, HAL and stock AIDL
services; the chroot's core and util already match. The A17 HAL is
self-contained and carries the `Janeiro` runtime, the
`Firmware setup failed for commands[%d], cluster_id_bitset in hex: %x.`
string at `.rodata` 0x4b8c71 with its one exact code reference at
`0x14d9d40`, and the embedded `janeiro_a0_config.binarypb` /
`janeiro_csr_layout.pb.txt`. The setup is built locally from the
`Janeiro` config, not from the delegate's default spec; the
`commands`/`cluster_id_bitset` loop is at `0x14d9a80`-`0x14d9d60`
(24-byte entries, cluster ids at `[x19+0x230]`), the per-command send at
`0x14d9eac`, the overall result at `0x14e3388`, and the failure logger at
`0x14da1f4`.

1. **Decode the setup builder.** Disassemble `0x14d9500`-`0x14da260` and
   `0x14e3300`-`0x14e3500` in `out/a17-edgetpu/libdarwinn_hal.so`; recover
   the 24-byte command entry layout, the `cluster_id_bitset` argument,
   the `Janeiro` config fields (`janeiro_a0_config.binarypb` /
   `janeiro_csr_layout.pb.txt`) and the setup flatbuffer fields. Check
   whether `[x19+0x180]` is `firmware_setup_done_`.
2. **Build and submit the type-1 setup** through the Tachyon ring client
   (`TYPES=2,5,5,7 UORDER=MDMK` plus the gdb patch at `core+0x5968c`).
   Success is the firmware no longer answering `Setup is not done yet`
   and RegisterGraph proceeding.
3. **Then the pipeline.** RegisterGraph (7), CreateExecution (9),
   BindInputBuffers (12), BindOutputBuffers (13), Invoke (11) on the SSD
   300x300 int8 model; 60 frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record the date and `uname -r`, replace this prompt,
   and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the commit.
