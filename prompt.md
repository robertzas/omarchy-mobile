# TPU bring-up: next iteration (2026-11-09, after U163)

Read `device/cheetah/TPU-PLAN.md` U150-U163 and `AGENTS.md` first. Phone:
up, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware
sha `52c1cccd…`, `janeiro` loaded, `/dev/janeiro` present and the TPU
powered by U163's setup probe.

**Do not run `tpu-a14-hal` or any direct `/dev/edgetpu` create** (U154).

**State.** U163 sent the A17 HAL's type-1 setup from the ring client
(`SETUP=1`: field 2 = three 16-byte scratch ranges at the U159 TPU
addresses, field 3 = an empty resource vector). The session and both
queues came up, `sendCommand` returned OK, the firmware answered 96 bytes
with `KCI tx code 21` and no `Setup is not done yet`, and the phone
stayed up. The 96-byte result is not decoded; the setup is global and the
TPU is still powered.

1. **Full run in the same boot.** Restart the chain with
   `NO_DELEGATE=1` (the TPU module is already loaded), then run the client
   with `TYPES=1,2,5,5,7 SETUP=1 UORDER=MDMK` under the
   `core+0x5968c` gdb patch (`set {unsigned long}($x21+8)=2; set
   $x8=$x21+8`). Round 1 is the setup, rounds 2-3 the imports, round 4 the
   RegisterGraph. Success is RegisterGraph proceeding and a non-error
   response, not just a 96-byte reply.
2. **If RegisterGraph proceeds**, send CreateExecution (9),
   BindInputBuffers (12), BindOutputBuffers (13) and Invoke (11) on the
   SSD 300x300 int8 model; 60 frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record the date and `uname -r`, replace this prompt,
   and commit.
3. **If it does not**, record the exact response and the core's log, then
   return to the A17 HAL's own producer: the chroot has the stock NN
   service but not `libneuralnetworks.so`, so extracting the A17 NNAPI
   runtime and triggering one `prepareModel` is the next host-half path.

Do not add `Signed-off-by`. Scan the diff for identifiers before the commit.
