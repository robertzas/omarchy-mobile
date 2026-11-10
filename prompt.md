# TPU bring-up: next iteration (2026-11-09, after U165)

Read `device/cheetah/TPU-PLAN.md` U150-U165 and `AGENTS.md` first. Phone:
up, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware
sha `52c1cccd…`, `janeiro` loaded. Do not run `tpu-a14-hal` or any direct
`/dev/edgetpu` create (U154).

**State.** The VD survives: the core's own setup response is forced to 0
at core file offset `0xab754` (`08 00 80 52`; backup
`libtachyon_core.so.setupok-orig` in the chroot), so the VD reaches
`INITIALIZED`. With `HANDLE=1 FDH=1 TYPES=1,2,5,5 SETUP=1 UORDER=MDMK`
the rounds answer 96/96/64/64 bytes and both imports retire (handles 1
and 2 resolved to fds 20 and 21). RegisterGraph (type 7) is next; in
U164 it needed the `core+0x5968c` patch
(`set {unsigned long}($x21+8)=2; set $x8=$x21+8`) because the core
dereferenced a null at `+0x38`.

1. Restart the chain (`NO_DELEGATE=1 sh -s < tools/tpu-tachyon-run`).
2. Run the client with `TYPES=1,2,5,5,7 SETUP=1 UORDER=MDMK
   HANDLE=1 FDH=1`, with the `core+0x5968c` patch applied. Prefer a
   binary patch of the core over a gdb attach if the disassembly at
   `0x5968c` allows it: an attach has killed the service before (U62).
   Read the type-7 response and the core log.
3. If RegisterGraph succeeds, send CreateExecution, BindInputBuffers,
   BindOutputBuffers and Invoke for `detect.tflite`, then run 60 frames
   of `out/bench/mosaic12.mp4` and fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame). Record the date and `uname -r`.
4. Replace this prompt with the next state and commit the plan, prompt
   and client changes. Do not add `Signed-off-by`; scan the diff for
   identifiers first.
