# TPU bring-up: next iteration (2026-11-09, after U130)

Read `device/cheetah/TPU-PLAN.md` U124-U130 and `AGENTS.md` first. The phone
is up with the Tachyon service dead; `reboot-to` first (slot B, the grant
covers it), then `TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** The request parses correctly (handle 2, device 1, tag 7 at
`+0x80`); the VII builder dies at `libtachyon_core.so+0x5968c` because the
descriptor's required single buffer at `+0x38` is null. Patching it in gdb
gets the command through and the core answers `Dependent memory handle was
not added: 252`. Every descriptor shape, vector encoding, an empty vector
and the command-level buffer at field 4 have all failed to fill it. The
`0xb8` at `core+0x4d53c` is a size argument, not the object allocation
(U130).

1. **Find the object by its tag store.** The parsed command has byte 7 at
   `+0x80`. In `libtachyon_core.so`, find the store of that tag (the
   RegisterGraph union tag) and break at the constructor that owns it; then
   `watch -l *(long *)($x21+0x38)` (or `$x0+0x38` after the constructor) and
   `continue` while the client sends `ORDER2=SSIISS UORDER=HDXGG`.
   - A fired watchpoint names the flatbuffer field and the store
     instruction; that field is what the client must declare.
   - No fire proves `+0x38` is not a descriptor field and the caller's field
     table at `0x87b90` is the answer.
   Resolve the base as in U130
   (`/proc/%d/maps`, `libtachyon_core.so`, `r-xp`).
2. **If the watchpoint names a field**, declare it in the client
   (`tools/tpu-tachyon-client.c`, `ORDER2` letters) and re-run without gdb.
3. **Then the run path.** CreateExecution (9), bind input/output (12/13),
   Invoke (11), feed the SSD 300x300 int8 model, run 60 frames of
   `out/bench/mosaic12.mp4` with `tools/bench-object-detection.py`, and fill
   the TPU row in U118 (CPU 4t 4.28 ms, GPU 3.00 ms, 10.0 detections/frame).

Keep the gdb recipe from U126 (`handle SIGSEGV stop print nopass`,
`continue`, patch `$x8`, `continue`). Record the result as U131 with the
date, `uname -r`, the store site or its absence, then replace this prompt
and continue.
