# TPU bring-up: next iteration (2026-11-09, after U137)

Read `device/cheetah/TPU-PLAN.md` U126-U137 and `AGENTS.md` first. Phone:
up, chain up, Tachyon service alive after the patched run; the boot's one
TPU power-up is spent, so reboot before the next client run (`reboot-to`,
slot B, covered by the grant), then
`TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** Every GraphDescriptor shape — table fields, inline 24-byte
structures, an empty vector, aligned u64 structs — produces the identical
200-byte response `Dependent memory handle was not added: 252`, and the
VII builder still reads a null `+0x38`. 252 is the byte position of the
client's container table in the 512-byte message, and no shape moves it, so
the descriptor is not what the core reads for that check; the value comes
from the command framing or a field outside the descriptor. ImportMemory
(type 5) is the only command whose buffer descriptor the core accepts, so
it is the working sample to copy.

1. **Capture the import command.** Run the client with `TYPES=2` (one
   import, `HANDLE=1`, the 4.7 MB graph) under gdb. Break at the command
   constructor `core+0x6384c`, `finish`, and dump `$x0`: `+0x10`, `+0x18`,
   `+0x38` and the pointees. Then capture the raw message bytes: preload
   `tools/android-cmd-dump.c` built as `libcmddump.so` (it interposes
   `TachyonComputeSession_sendCommand` and appends length-prefixed frames
   to `/data/local/tmp/tpu-cmds.bin` in the chroot), or add a dump env to
   the client if that is simpler.
2. **Compare and copy.** Diff the import's worked buffer encoding against
   RegisterGraph's container and scratch; rewrite the client's
   `tools/tpu-tachyon-client.c` fields to match byte for byte, including
   any command-level handle the import names.
3. **Re-run without gdb.** If `+0x38` is still null, the field is a
   command-level member: the import dump shows where its handle lives, and
   the same slot is the one RegisterGraph leaves zero.
4. **Then the run path.** CreateExecution (9), bind input/output (12/13),
   Invoke (11) with the SSD 300x300 int8 model, and 60 frames of
   `out/bench/mosaic12.mp4` through `tools/bench-object-detection.py`.
   Fill the TPU row in U118 (CPU 4t 4.28 ms, GPU 3.00 ms, 10.0 detections/
   frame), record the result as U138 with the date and `uname -r`, then
   replace this prompt and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the
commit.
