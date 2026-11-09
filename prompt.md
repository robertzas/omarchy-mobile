# TPU bring-up: next iteration (2026-11-09, after U125)

Read `device/cheetah/TPU-PLAN.md` U124 and U125, and `AGENTS.md` first. The
phone is up with the Tachyon service dead; `reboot-to` first (slot B, the
grant covers it), then `TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** RegisterGraph's graph descriptor is the command's union field 3
(`UORDER=HDXGG`, `ORDER2=...`). Its container (field 0) parses into the
faulting object at `+0x10`/`+0x18`, but the first vector (`+0x20`) never
fills for any of `S`, `I` or `J` at fields 1-4, and `+0x38` — a required
single BufferDescriptor, read as `(*(desc+0x38))[0]` — stays null, so
`libtachyon_core.so+0x5968c` dies. The core logs `Command created` and no
parse error: the request parses, the VII build fails.

One register crash kills the service, so a boot carries one blind probe.
Stop probing blind.

1. **Catch the fault with gdb.** Start the chain, `pgrep -x com.google.edge`,
   attach `gdb -p PID` with `set pagination off` and
   `handle SIGSEGV stop print nopass` (the segv preload would otherwise
   `_exit`). Run the client (`ORDER2=SSIISS UORDER=HDXGG`, `timeout 120`).
   gdb stops at `+0x5968c` with the registers live:
   `x/24gx $x21`, `x/8gx *(void **)$x2`, `bt`, `info registers x19 x20 x21
   x22`.
2. **Read the parse.** Walk one frame up and disassemble the caller
   (`x/40i $pc-0x100`); find where `$x21+0x38` is meant to be written, and
   the field-order table for the descriptor. That is the fact the sweep
   could not give: which flatbuffer slot maps to `+0x20`, `+0x38`, `+0x40`,
   `+0x58`.
3. **Patch in memory and continue.** With the process stopped at the fault:
   `set $x8 = *(unsigned long *)($x21+0x10)` (the container's
   BufferDescriptor), then `continue`. If RegisterGraph completes, `+0x38`
   is the firmware scratch and only its slot is missing from our payload;
   record the core's next log line either way (U125's oracle).
4. **Restart instead of rebooting.** `kill -9` the service and start it again
   from the chain script; the firmware never saw a VII command, so this
   should cost no reboot and let one boot carry several probes. Verify with a
   second attach before relying on it.
5. **Then the run path.** CreateExecution (9), bind input/output (12/13),
   Invoke (11), feed the SSD 300x300 int8 model, run 60 frames of
   `out/bench/mosaic12.mp4` with `tools/bench-object-detection.py`, and fill
   the TPU row in U118 (CPU 4t 4.28 ms, GPU 3.00 ms, 10.0 detections/frame).

Record the result as U126 with the date, `uname -r`, the commands and the
gdb output (registers, the disassembled store site), then replace this
prompt and continue.
