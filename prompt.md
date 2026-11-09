# TPU bring-up: next iteration (2026-11-09, after U154)

Read `device/cheetah/TPU-PLAN.md` U150-U154 and `AGENTS.md` first. Phone:
up, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware at
`/lib/firmware/updates/google/edgetpu-janeiro.fw` (sha `52c1cccd…`).

**Do not run `tpu-a14-hal` or any direct `/dev/edgetpu` create again.** The
A14 HAL's `CreateDevice` blocks in the driver's group finalize and reset the
phone (U154). The Tachyon ring harness is the safe one.

**State.** Every userspace producer tried so far emits the legacy type-0
firmware setup, and both cheetah firmware generations (A14 `1.0 539775951`,
A17 `1.0 895567958`) refuse it: the tegu core, the A17 HAL, the A14 HAL, and
the ring client all end at `Setup is not done yet received/recieved a
command of type 0.` The GSA path is healthy (`cmd 50` loads, `TPU cmd 1`
starts, state 2). The A17 chroot core is a 1 015 720 B stub.

1. **Find the A14 cheetah core.** A real A14/A16 `libtachyon_core.so` would
   build the type-1 setup and send it through the ring, the harness that has
   never hung the phone. Check `out/factory/dl.log`, `~/android/reference`
   and any extracted A14/A16 vendor image for the file; compare it with the
   A17 stub (1 015 720 B) and the tegu core (1 538 440 B). If found, copy it
   into the chroot's `/vendor/lib64/`, start the chain
   (`NO_DELEGATE=1 TPU_VLOG=5 /root/tpu-tachyon-run`), and run the ring
   client with `TYPES=2,5,5,7 UORDER=MDMK` plus the gdb patch at
   `core+0x5968c`. A setup that succeeds is visible as `Setup is already
   done` or the RegisterGraph completing.
2. **If no real core exists,** build the type-1 setup from the bootloader's
   hwmgr/tpu-image code (`out/factory/cheetah-abl/…`, segments at `0x7a8000`
   and `0x7fac00`) or from the A17 firmware's handler, then submit it as the
   setup element through the ring client.
3. **Then the pipeline.** RegisterGraph (7), CreateExecution (9),
   BindInputBuffers (12), BindOutputBuffers (13), Invoke (11) on the SSD
   300x300 int8 model; 60 frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record the date and `uname -r`, replace this prompt,
   and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the commit.
