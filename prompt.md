# TPU bring-up: next iteration (2026-11-09, after U128)

Read `device/cheetah/TPU-PLAN.md` U124-U128 and `AGENTS.md` first. The phone
is up with the Tachyon service dead; `reboot-to` first (slot B, the grant
covers it), then `TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** The request parses correctly (handle 2, device 1, tag 7 at
`+0x80`), but the VII builder dies at `libtachyon_core.so+0x5968c` on the
descriptor's required single buffer at `+0x38`. Six descriptor shapes,
three vector encodings, an empty vector, and a command-level buffer at
field 4 all leave it null. Patching it in gdb gets the command through and
the core then answers `Dependent memory handle was not added: 252` — so the
buffer is real and must reference an imported memory handle.

1. **Catch the store.** In the core, find the allocation of the parsed
   command object (`mov w0, #0xb8` or `#0xc0`). Attach gdb, break there,
   let the client send RegisterGraph, and when the object exists set
   `watch -l *(long *)($x21 + 0x38)` (or the equivalent on the returned
   pointer) and `continue`. If a store fires, gdb names the instruction and
   the flatbuffer field it reads; if it never fires, `+0x38` is not a
   descriptor field.
2. **If it never fires**, read the parse from the caller chain: disassemble
   around the caller of `0x59608` (the site at `0x87b90`), follow where
   `cmd+0x38` would be written, and read the descriptor's field table.
3. **Then the run path.** CreateExecution (9), bind input/output (12/13),
   Invoke (11), feed the SSD 300x300 int8 model, run 60 frames of
   `out/bench/mosaic12.mp4` with `tools/bench-object-detection.py`, and fill
   the TPU row in U118 (CPU 4t 4.28 ms, GPU 3.00 ms, 10.0 detections/frame).

Keep the gdb recipe from U126 (`handle SIGSEGV stop print nopass`,
`continue`, patch `$x8`, `continue`) and the client's `ORDER2`/`UORDER`
builder. Record the result as U129 with the date, `uname -r`, the store
site or its absence, then replace this prompt and continue.
