# TPU bring-up: next iteration (2026-11-09, after U126)

Read `device/cheetah/TPU-PLAN.md` U124-U126 and `AGENTS.md` first. The phone
is up with the Tachyon service dead; `reboot-to` first (slot B, the grant
covers it), then `TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** The request parse is correct: the command object carries handle
2, device 1, two single buffer pointers and the RegisterGraph tag (7) at
`+0x80`. The VII builder dies at `libtachyon_core.so+0x5968c` because the
descriptor's required single buffer (`+0x38`) is null. Under gdb, patching
`$x8 = *(unsigned long *)($x21 + 0x10)` and continuing makes the core send
the command and answer with a *structured* error:

```
Dependent memory handle was not added: 252.
Maybe you forgot to call ImportMemoryByFd.
```

So the last blocker is a buffer reference the command's memory set lacks —
not a parse failure.

1. **Name the handle.** Run the client with `CH=252`, `SH=252` and
   `IH=252` (the three buffer tables), one per run. A changed message or a
   successful register says the slot and the handle are right. The response
   is 200 bytes with the error text, so the outcome is readable without
   gdb.
2. **If the message persists, read the core's memory set under gdb.**
   Attach as in U126, break at the fault, and walk the command's handle
   table: the parsed object at `$x21`, its `+0x10`/`+0x18` descriptors and
   the map the builder consults (`ImportMemoryFromFd`'s entries). The error
   names 252, so the map must contain 252 for the container — check what the
   two imports actually returned and which handle the client then used.
3. **Then the run path.** CreateExecution (9), bind input/output (12/13),
   Invoke (11), feed the SSD 300x300 int8 model, run 60 frames of
   `out/bench/mosaic12.mp4` with `tools/bench-object-detection.py`, and fill
   the TPU row in U118 (CPU 4t 4.28 ms, GPU 3.00 ms, 10.0 detections/frame).

Keep the gdb attach recipe from U126: `-ex 'handle SIGSEGV stop print
nopass' -ex continue`, then patch `$x8` and continue. Record the result as
U127 with the date, `uname -r`, the client's response bytes and the exact
error text, then replace this prompt and continue.
