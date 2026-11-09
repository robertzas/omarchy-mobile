# TPU bring-up: next iteration (2026-11-09, after U124)

Read `device/cheetah/TPU-PLAN.md` U124 and `AGENTS.md` first. The phone is
up with the Tachyon service dead; `reboot-to` first (slot B, the grant
covers it), then `TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** RegisterGraph's args are `{handle, device_id, <table>,
graph_descriptor, ...}`; the descriptor at field 3 fills the builder's
`+0x10` (graph container) and the crash moves to `+0x38` (the second
single location, read with `ldr x8,[x8]` at `libtachyon_core.so+0x5968c`).
Only descriptor field 0 parses. `tools/tpu-tachyon-client.c` already has
`ORDER2` letters: `C`/`S`/`I`/`X`/`T` tables, `c`/`s`/`i` inline
24-byte locations, `J` a vector of inline descriptors, `L` an inline
location struct; `UORDER=HDXGG` is the working command shape, and `CH`,
`SH`, `IH` override one buffer table's memory handle.

One register per boot: a failure kills the service.

1. **Field 1 alone.** `ORDER2=CS` (container, scratch) with
   `UORDER=HDXGG`. If the crash stays at `+0x38`, the scratch is not
   descriptor field 1; if it moves, it is. Then `ORDER2=CX` with `X` a
   second BufferDescriptor table (the `X` table at 348) to see whether any
   table in field 1 parses.
2. **Field 2 alone.** `ORDER2=CIS` (container, the `I` vector, scratch)
   and `ORDER2=CXS`, reading whether `+0x20` becomes non-empty; a vector of
   table offsets and a vector of inline structs are the two encodings, and
   `J` gives the second.
3. **The container's own shape.** The parsed container's pointee starts
   `0x002028fc …` (a vtable-like word), so a BufferDescriptor may carry a
   tagged union, not three u64s. If fields 1 and 2 never parse, dump the
   container table the core builds at `+0x10` and match its layout.
4. **Then** CreateExecution (9), bind input/output (12/13), Invoke (11),
   feed SSD 300x300 int8, run 60 frames of `out/bench/mosaic12.mp4` with
   `tools/bench-object-detection.py`, and replace the blocked TPU row in
   U118 (CPU 4t 4.28 ms, GPU 3.00 ms, 10.0 detections/frame).

Record the result as U125 with date, `uname -r`, commands and the crash
dump line (`obj…`), then replace this prompt and continue.
