# TPU bring-up: next iteration (2026-11-09, after U136)

Read `device/cheetah/TPU-PLAN.md` U126-U136 and `AGENTS.md` first. Phone:
up, chain up, Tachyon service alive; the boot's one TPU power-up is spent,
so reboot before the next client run (`reboot-to`, slot B, covered by the
grant), then `TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** ImportMemory rounds 1-3 parse and answer. RegisterGraph (type 7)
reaches the VII builder and dies at `libtachyon_core.so+0x5968c` because
descriptor `+0x38` is never written: a hardware watchpoint on the 224-byte
command object from its allocation (`+0x622e8`) through the crash never
fired. Patching `$x8` (not `+0x38`) gets a 200-byte response,
`Dependent memory handle was not added: 252`, and 252 is the byte offset at
which the client builds the graph-container table, unchanged when the
parsed buffers' first words are patched to the imported handles 1 and 2.
So the core is reading a flatbuffer position as a handle: the Buffer
encoding, not a field index, is wrong.

1. **Capture Google's RegisterGraph bytes.** Run the stock app service in
   the chroot
   (`/system_ext/bin/hw/vendor.google.edgetpu_app_service@1.0-service`,
   the runner's existing block) and dump the command buffer at the handler
   entry `core+0x622a4` (`x1`/`x2` carry the message) or in the core's
   send path. Register one graph (a delegate `edgetpu-run` request is
   enough), then diff the first 512 bytes against the client's `msg` for
   the same ORDER2/UORDER. This is the authoritative schema.
2. **If the app service cannot get that far**, follow the constructor
   `0x6384c`'s caller to the Buffer reader and read which vtable slot it
   reads for the container; that gives the field order without guessing.
3. **Encode the real layout** in `tools/tpu-tachyon-client.c` (fixed byte
   offsets are fine for this bring-up client), re-run without gdb, then
   CreateExecution (9), bind input/output (12/13) and Invoke (11) with the
   SSD 300x300 int8 model.
4. **Measure.** 60 frames of `out/bench/mosaic12.mp4` with
   `tools/bench-object-detection.py`, fill the TPU row in U118 (CPU 4t
   4.28 ms, GPU 3.00 ms, 10.0 detections/frame), record the result as U137
   with the date and `uname -r`, then replace this prompt and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the
commit.
