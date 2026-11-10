# TPU bring-up final iteration (2026-11-10) - phone access available

## State

- **Phone up**, reachable via `tools/phone-ssh`. Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware sha `52c1cccd…`, `janeiro` loaded. Uptime ~23h+.
- **TPU hardware wedged**: PSM0_STATUS=0x5644c13, AON registers 0xdeadfeed, power-up fails with -110 (ETIMEDOUT), KCI timeout, firmware handshake failed. `tpu-hold` acquires wakelock but pm_get fails (-110). This is the "second power-up of the boot wedges the PSM" state (TPU-PLAN U54). **Requires cold reboot to recover.** Do NOT run `tpu-a14-hal` or direct `/dev/edgetpu` create (U154).
- **Core patches applied** in phone chroot `libtachyon_core.so` (`/usr/lib/omamobile-vendor/edgetpu/root/vendor/lib64/libtachyon_core.so`): setup answer forced OK at `0xab754` (`08 00 80 52`), `+0x38` null load replaced by `mov w8, #2` at `0x5968c` (`48 00 80 52`). Backups: `.setupok-orig`, `.regnull-orig`.
- **Graphs on phone**: `$R/vendor/graph.bin` (original, 8-byte header `31 00 34 00 00 20 48 00` + DWN1 payload), `$R/vendor/etc/graph-fb.bin` (header-stripped, 4,726,860 B, starts with `c8 0f 00 00 44 57 4e 31`), plus `graph-dwn1.bin`, `graph-dgc0.bin`, `graph-dgd0.bin`, `graph-scratch.bin` in `$R/vendor/etc/`.
- **Chain runner**: `tools/tpu-tachyon-run` (run with `NO_DELEGATE=1`). Test helper: `/tmp/run_graph_test.sh` on phone. Client: `tools/tpu-tachyon-client.c`.

## Blocking issue: RegisterGraph identifier/validation

RegisterGraph (type 7, round 5) consistently fails with:
- `INVALID_ARGUMENT: Invalid flatbuffer file identifier DWN1` when bytes 4-7 of graph buffer are `0x44574e31` (DWN1 printed, flatbuffer parser rejects structure after identifier read)
- `INVALID_ARGUMENT: Invalid flatbuffer file identifier` (empty `%s`) when bytes 4-7 are `0x00000000` or other non-matching values (immediate reject)

Error string: rodata `0x142ee` in `libtachyon_core.so` (`"Invalid flatbuffer file identifier %s"`). .text: VA `0x4d0e0`, size `0x117e5c`.

**Exhaustive experiments (25+ chain runs, all failed):**
- Header-stripped graph (graph-fb.bin, DWN1 at bytes 4-7): parser fails after identifier recognized
- Original graph.bin with 8-byte container header: same rejection
- Zeroed identifier: immediate reject (empty %s)
- DGC0/DGD0/TCHN/DIVE/EXEC/TGPH/RNGP/GRAP/MODE identifiers: immediate reject
- 0x482000-length slice: immediate reject
- TAG=6-15 overrides: TAG=8→UnregisterGraph, others→invalid command
- Binary patches at `0x1062dc, 0x160c44, 0x4d150, 0x5adb8, 0x5adc4, 0xab754, 0x5968c` with `48 00 80 52` and NOP: 0 passed
- 286K+ instruction-boundary offsets sampled across .text: 0 passed
- Rounds 1-4 always pass (setup type 1, import graph memory type 5 x2, import scratch type 5)

## Next steps (in priority order)

1. **Recover TPU hardware** (requires cold reboot):
   - After reboot: `janeiro` autoloads, `tpu-hold` holds device since boot (start as `/root/tpu-hold >/dev/null 2>&1 &` to avoid SSH hang), start chain with `NO_DELEGATE=1 sh -s < tools/tpu-tachyon-run`.
   - Do NOT run `tpu-a14-hal` or direct `/dev/edgetpu` create. Avoid second power-up wedge.

2. **Fix RegisterGraph validation** (core patch / graph format):
   - **Disassemble/analyze on phone or locally**: trace xrefs/callers of error string at `0x142ee` in `libtachyon_core.so`. Find the function that reads bytes 4-7 from the graph buffer, validates identifier (DWN1/0), and runs flatbuffer verification. Patch the failing check to accept/skip validation (prefer minimal patch: force success return or bypass bad branch). Pattern from existing patches: `48 00 80 52` (`mov w8, #2`).
   - **Try alternative graph formats on recovered TPU**: test `graph-dwn1.bin`, `graph-dgc0.bin`, `graph-dgd0.bin`, `graph-scratch.bin`, original `graph.bin` with and without header strip. The DWN1 flatbuffer structure may be valid but rejected by a schema/version check specific to this core (cheetah/A17, libtachyon_core sha/build in chroot).
   - **Check compiled model compatibility**: `detect.tflite` / `model.tflite` in chroot may need recompilation for this Edge TPU version/runtime. Look for edgetpu_compiler outputs or compatible compiled models.

3. **If RegisterGraph passes**: proceed to `CreateExecution` (9), `BindInputBuffers`, `BindOutputBuffers`, `Invoke` for `detect.tflite`, then run 60 frames of `out/bench/mosaic12.mp4` for U118 TPU row (CPU 4t 4.28 ms, GPU 3.00 ms, 10.0 det/frame, LiteRT). Record date and `uname -r`.

4. **CPU/GPU comparison**: document 11.31-11.36 ms/frame CPU baseline (LiteRT+XNNPACK, 60 frames, 720p mosaic12.mp4, ~10 det/frame); compare against GPU (RTX 3070 + Intel iGPU) and TPU when available.

5. **Update docs and commit**: `device/cheetah/TPU-PLAN.md`, `prompt.md` with results; no `Signed-off-by`; grep diff for identifiers before commit.

## Notes

- When starting background processes on phone via SSH, redirect stdout/stderr (`>/dev/null 2>&1 &`) or SSH session will hang.
- `tpu-hold` wakelock returns -110 when TPU is wedged; do not interpret as success.
- Service chain must be up (`com.google.edge` running) before graph tests; use `NO_DELEGATE=1 sh -s < tools/tpu-tachyon-run` and wait for services.
