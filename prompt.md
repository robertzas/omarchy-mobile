# TPU bring-up: next iteration (2026-11-09, after U144)

Read `device/cheetah/TPU-PLAN.md` U126-U144 and `AGENTS.md` first. Phone:
up, chain up, Tachyon service alive; the boot's one TPU power-up is spent,
so reboot before a client run (`reboot-to`, slot B, under the grant), then
`TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** The crash site is exact: at `core+0x59680` the tag-7 payload is
`x21 = {2, 1, ptrA, ptrB, …, +0x38: 0}` with `ptrA -> {252, 40, 32, 0}`.
The core resolves the graph container's **table position and size** as a
dependent memory handle, and the scratch reference at `+0x38` is null. The
vendor-delegate capture failed: `libcmddump.so` loaded (it created
`tpu-cmds.bin`) but its interposed `TachyonComputeSession_sendCommand` was
never called, so the delegate never sent a command. The working message
must be obtained from the builder that actually encodes it.

1. **Find the util library's builder.** In `libedgetpu_util.so`, locate the
   functions that reference `RegisterGraph`, `Desc]`, and the graph
   descriptor's field names (strings and their adrp/add users). Map the one
   that builds the type-7 message and its field order. If it is callable
   with the graph and imported handles, call it on the phone and capture the
   bytes; otherwise decode its stores into a standalone builder.
2. **Alternatively, decode the parser.** From `core+0x59650` and `0x59680`,
   follow the callers that fill the tag-7 payload (the parser that turns the
   flatbuffer into `{2, 1, ptrA, ptrB, …}`) and read which message offsets
   it consumes. That names the exact field layout without a working device.
3. **Encode ours the same way**, with handles 1 and 2, and verify at
   `core+0x59680` that `[x21+0x10]` and `[x21+0x38]` are the handles, not
   252 and null.
4. **Pipeline and measure.** CreateExecution (9), bind input/output (12/13),
   Invoke (11) on the SSD 300x300 int8 model; 60 frames of
   `out/bench/mosaic12.mp4` through `tools/bench-object-detection.py`; fill
   the TPU row in U118 (CPU 4t 4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3
   fps, both 10.0 detections/frame), record U145 with the date and
   `uname -r`, replace this prompt, and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the
commit.
