# TPU bring-up: next iteration (2026-11-09, after U123)

Read `device/cheetah/TPU-PLAN.md` U120-U123 and `AGENTS.md` first. The
phone is up with `tpu-hold` running; slot B only, no cold boot unless a
core crash killed the tachyon service.

**State.** The ring client reaches the real tegu core, imports are
accepted (responses kind 2 and 3), and `RegisterGraph` is `{handle,
device_id, GraphDescriptor}`. The core passes its device-id check and then
dies at `libtachyon_core.so+0x5968c` dereferencing a null
`[[payload+0x38]]` while building the VII command, for every descriptor
layout tried (U121-U123). Patching the graph's scratch size did not help.

1. **Get the core's own log.** Copy `libvlogshim.so` into the chroot
   (`$R/system/lib64/libvlogshim.so`), preload it by that path in
   `/root/tpu-tachyon-run` (the service runs outside the chroot, so a
   `/system/...` path fails), and confirm `vlog:set` appears in the service
   log before running anything else. Then send one register and read the
   verbose lines for the import/register path.
2. **If the log does not name the field**, read the reference:
   `libedgetpu_util.so` exports `DarwinnApi2_VirtualDevice_RegisterGraph*`
   and every `ByBuffer` thunk funnels into `0x6f87f4`; disassemble that
   function (`out/factory/tegu-cp21/vendor-libs/`) and write the exact
   field order into `tools/tpu-tachyon-client.c`. Check the core's
   `.dynsym` first for a client-side builder
   (`readelf -sW libtachyon_core.so | grep -i register`).
3. **After register succeeds:** CreateExecution (9), bind input/output
   (12/13), Invoke (11), feed the SSD 300x300 int8 input, run 60 frames of
   `out/bench/mosaic12.mp4` with `tools/bench-object-detection.py`, and add
   the TPU row next to CPU (4 threads 4.28 ms) and GPU (3.00 ms). Only then
   is the 720p comparison complete.
4. **Chain discipline:** a core crash that kills the tachyon service needs
   `reboot-to` before the next attempt; never `pkill -f` a pattern that
   appears in the SSH command; always filter `libperfmgr`; the client's
   `DEAD_OBJECT` after `round 4` is the crash, not a transport fault.

Record the result in `TPU-PLAN.md` as U124 with the date, `uname -r`, the
exact commands and the log lines, then replace this prompt with the next
one and continue.
