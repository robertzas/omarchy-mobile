# TPU bring-up: next iteration (2026-11-09, after U143)

Read `device/cheetah/TPU-PLAN.md` U126-U143 and `AGENTS.md` first. Phone:
up, chain up, Tachyon service alive; the boot's one TPU power-up is spent,
so reboot before a client run (`reboot-to`, slot B, under the grant), then
`TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** The crash site is now exact: at `core+0x59680` the tag-7 payload
is `x21 = {2, 1, ptrA, ptrB, …, +0x38: 0}` and `ptrA -> {252, 40, 32, 0}`.
The core is resolving the **graph-container table's position and size**
(252/40/32) as a dependent memory handle, and the scratch reference at
`+0x38` is null. Our hand-built flatbuffer is therefore wrong in a way the
parser does not reject: a table reference where an inline buffer struct
belongs, and a missing second buffer. `x1` at the handler is not the type;
`ignore` counts are wrong because the handler runs more than once per
command.

1. **Capture a real message.** Build `tools/android-cmd-dump.c` with the
   Android clang as `libcmddump.so`, push it into the vendor chroot, and run
   the vendor path (`NO_DELEGATE=0`, the util library's
   `CreateVirtualDevice`/RegisterGraph) with
   `LD_PRELOAD=/system/lib64/libcmddump.so`. It sends commands before the
   VII rejects them; read `/data/local/tmp/tpu-cmds.bin`. If it never
   reaches RegisterGraph, capture the frames of the same client the app
   service uses.
2. **Decode the real GraphDescriptor.** The frames are length-prefixed.
   Locate the type-7 message, dump the descriptor table's vtable and field
   offsets, and compare byte-for-byte with `build_reg3` (table at 144,
   C/S/X/I at 252/300/348/384). The real bytes name the inline struct and
   the second buffer's field.
3. **Encode ours the same way**, with the imported handles 1 and 2, then
   re-run and check at `core+0x59680` that both `[x21+0x10]` and
   `[x21+0x38]` are the handles, not 252 and null.
4. **Pipeline and measure.** CreateExecution (9), bind input/output (12/13),
   Invoke (11) on the SSD 300x300 int8 model; 60 frames of
   `out/bench/mosaic12.mp4` through `tools/bench-object-detection.py`; fill
   the TPU row in U118 (CPU 4t 4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3
   fps, both 10.0 detections/frame), record U144 with the date and
   `uname -r`, replace this prompt, and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the
commit.
