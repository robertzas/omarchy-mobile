# TPU bring-up: next iteration (2026-11-09, after U129)

Read `device/cheetah/TPU-PLAN.md` U124-U129 and `AGENTS.md` first. The phone
is up with the Tachyon service dead; `reboot-to` first (slot B, the grant
covers it), then `TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** The request parses correctly (handle 2, device 1, tag 7 at
`+0x80`); the VII builder dies at `libtachyon_core.so+0x5968c` because the
descriptor's required single buffer at `+0x38` is null. Patching it in gdb
lets the command through, and the core then answers `Dependent memory
handle was not added: 252`. Every descriptor shape, vector encoding and the
command-level buffer at field 4 have been tried; the descriptor sweep is
finished. The command object allocates at `libtachyon_core.so+0x4d53c`.

1. **Catch the store.** Attach gdb with the recipe below, break at
   `base+0x4d53c`, let the client send RegisterGraph, then watch
   `*(long *)(cmd+0x38)` (or the same field on `$x21` at the VII stop) and
   continue. A fired watchpoint names the field and store instruction; none
   proves `+0x38` is not a descriptor field.

   ```
   gdb -batch -q -p $PID \
     -ex 'set pagination off' \
     -ex 'handle SIGSEGV stop print nopass' \
     -ex 'handle SIGBUS stop print nopass' \
     -ex 'python import gdb; m=[l for l in open("/proc/%d/maps"%gdb.selected_inferior().pid) if "libtachyon_core.so" in l and "r-xp" in l][0]; b=int(m.split("-")[0],16)+0x4d53c; gdb.Breakpoint("*0x%x"%b); print("BP 0x%x"%b)' \
     -ex continue
   ```

   The client (`ORDER2=SSIISS UORDER=HDXGG`, `timeout 70`) runs in parallel;
   after the breakpoint, `finish` gives the new object in `$x0`.
2. **If no store exists**, disassemble the caller of `0x59608` at `0x87b90`
   and read the descriptor's field table directly, then declare that field.
3. **Then the run path.** CreateExecution (9), bind input/output (12/13),
   Invoke (11), feed the SSD 300x300 int8 model, run 60 frames of
   `out/bench/mosaic12.mp4` with `tools/bench-object-detection.py`, and fill
   the TPU row in U118 (CPU 4t 4.28 ms, GPU 3.00 ms, 10.0 detections/frame).

Record the result as U130 with the date, `uname -r`, the store site or its
absence, then replace this prompt and continue.
