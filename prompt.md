# TPU bring-up: next iteration (2026-11-09, after U138)

Read `device/cheetah/TPU-PLAN.md` U126-U138 and `AGENTS.md` first. Phone:
up, chain up, Tachyon service alive; the boot's one TPU power-up is spent,
so reboot before the next client run (`reboot-to`, slot B, covered by the
grant), then `TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** `core+0x6384c` is the constructor of the command's log record,
not the parsed request: its object begins with two string sizes and a
pointer to `Session on … [Cmd N] <name>`. Every watchpoint from U129-U137
was armed on that record, which is why `+0x38` never fired. The request
object is the `$x21` in the VII builder (`{2, 1, ptr, ptr, …}`); its
`+0x10` pointee begins with a flatbuffer table position (252), which the
core reports as a memory handle. Every GraphDescriptor shape gives the
same 252, so the request's own parse is the gate.

1. **Find the request parser.** Run RegisterGraph under gdb and break at
   the VII-builder entry `core+0x59608`. Dump `$x21` and `$x30`, then
   disassemble the caller around the call to the builder; walk up until a
   frame in the command handler that allocates the request. Identify the
   allocation (the `$x21` object) and the code that fills `+0x10`/`+0x38`.
2. **Watch the real object.** Break at that allocation before the client
   sends RegisterGraph, set `watch -l *(long *)($obj+0x10)` and
   `watch -l *(long *)($obj+0x38)`, then `continue`. A fired watch names
   the store and the flatbuffer field; no fire proves the request's
   `+0x38` is not parser-filled.
3. **Encode and run.** Put the named field in
   `tools/tpu-tachyon-client.c`, re-run without gdb, then CreateExecution
   (9), bind input/output (12/13), Invoke (11) with the SSD 300x300 int8
   model.
4. **Measure.** 60 frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`, fill the TPU row in U118 (CPU 4t
   4.28 ms, GPU 3.00 ms, 10.0 detections/frame), record the result as U139
   with the date and `uname -r`, then replace this prompt and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the
commit.
