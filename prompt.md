# TPU bring-up: next iteration (2026-11-09, after U127)

Read `device/cheetah/TPU-PLAN.md` U124-U127 and `AGENTS.md` first. The phone
is up with the Tachyon service dead; `reboot-to` first (slot B, the grant
covers it), then `TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** The request parse is correct (handle 2, device 1, RegisterGraph
tag 7 at `+0x80`). The VII builder dies at `libtachyon_core.so+0x5968c`
because the descriptor's required single buffer (`+0x38`) is null. Under
gdb, patching `$x8 = *(unsigned long *)($x21 + 0x10)` gets the command
through and the core answers `Dependent memory handle was not added: 252.
Maybe you forgot to call ImportMemoryByFd.` Neither six descriptor fields,
three vector encodings, nor a command-level buffer at field 4 fill `+0x38`.

1. **Map slot to member with distinct handles.** Run
   `ORDER2=SSIS UORDER=HDXGG` with `CH=252 SH=253 IH=254` (each table a
   different handle). Attach gdb as in U126, stop at the fault, and dump
   `x/3gx *(void **)($x21+0x10)` and `x/3gx *(void **)($x21+0x18)`: the
   first word of each is its handle, so the numbers 252/253/254 name the
   slot feeding that member. Then the *next* single slot is the one that
   must fill `+0x38` — declare it and re-run without gdb.
2. **If no field fills it, read the parse.** With the handle mapping known,
   walk one frame up at the fault and disassemble the caller around the
   store site; the descriptor's member layout is then readable directly.
3. **Then the run path.** CreateExecution (9), bind input/output (12/13),
   Invoke (11), feed the SSD 300x300 int8 model, run 60 frames of
   `out/bench/mosaic12.mp4` with `tools/bench-object-detection.py`, and fill
   the TPU row in U118 (CPU 4t 4.28 ms, GPU 3.00 ms, 10.0 detections/frame).

Keep the gdb recipe from U126 (`handle SIGSEGV stop print nopass`,
`continue`, patch `$x8`, `continue`). Record the result as U128 with the
date, `uname -r`, the handle mapping and the client's response bytes, then
replace this prompt and continue.
