# TPU bring-up: next iteration (2026-11-09, after U141)

Read `device/cheetah/TPU-PLAN.md` U126-U141 and `AGENTS.md` first. Phone:
up, chain up, Tachyon service alive; the boot's one TPU power-up is spent,
so reboot before the client run (`reboot-to`, slot B, under the grant), then
`TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** The command handler is `core+0x59608` (caller return `0x87b94`).
It reads the descriptor at `[msg]+0x50`, checks the byte at `+0x10` against
**7**, and uses `[descriptor+0x18]` as the payload only when equal. It
resolves `[payload+0x10]` and `[payload+0x38]` as dependent memory handles;
ours are **252** (the container table's absolute position, so the lookup
fails) and **NULL** (the SIGSEGV at `0x5968c`). `b[49] = 7` in
`build_reg3` is our own guess, and the payload behind it is not the layout
the client fills. `x1` at the handler is not the command type.

1. **Enumerate the tag and payload.** In `tools/tpu-tachyon-client.c` add a
   client letter that sets `b[49]` from an env var (0-12) and a second that
   lays the payload out as the same struct ImportMemory uses for its
   accepted descriptor. Run one command per tag, log the handler's two
   values (a small `LD_PRELOAD` or the existing gdb breakpoint at
   `core+0x59650`, printing `[x21+0x10]`, `[x21+0x38]` after the loads), and
   keep the tag where both are non-null and resolve.
2. **Fix the handle.** The first value should be the imported memory handle
   (1 for the graph, 2 for scratch), not a table position. Encode it in the
   field the tag selects, re-run without gdb, and confirm the response is a
   RegisterGraph success, not `Dependent memory handle was not added`.
3. **Then the pipeline.** CreateExecution (9), bind input/output (12/13),
   Invoke (11) with the SSD 300x300 int8 model on the 1280x720 frame.
4. **Measure.** 60 frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record U142 with the date and `uname -r`, replace
   this prompt, and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the
commit.
