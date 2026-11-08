# Prompt: give the firmware the setup element it accepts, then benchmark

Goal: one real Edge TPU inference on `cheetah`, then object detection on
`mosaic720.mp4` (10+ objects per frame) measured against CPU, GPU and every
other working path with `tools/bench-object-detection.py`. Only numbers from
runs that happened.

Read `device/cheetah/TPU-PLAN.md` U27-U74 first.

## Where it stands (2026-11-08, U74)

- Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`; `/dev/janeiro` up,
  one power-up per boot, no oops.
- The vendor stack runs and the client reaches AUTHORIZED with both FMQs and a
  working `sendCommand`.
- The HAL's forced setup call (`0x14d9ce4: bl 0x15179fc`, 48-byte element)
  runs and the firmware answers `Sync VII command failed: error_code=9`,
  `create device status: 13`. In the runtime's gRPC-style code table 9 is
  FAILED_PRECONDITION, i.e. "setup is not done yet". The HAL then sets
  `firmware_setup_done_` anyway (`0x14d9cf8`).
- The HAL's element has `u16 11` at byte 10; the core's setup is type 1 with
  global scratches.
- No inference, no benchmark.

## Do these in order

1. Recover the core's type-1 setup element: disassemble `libtachyon_core.so`
   around the push helper `0xa4dec` and the builder/log `0xa4d5c`, and the
   verifier `0xb9c48`, and write the flatbuffer fields into the plan. Compare
   its bytes with the HAL's 48-byte element.
2. If the only difference is the type, patch the HAL's element byte 10 from 11
   to 1 in the builder and re-run the full chain as system
   (`HAL_PRELOAD=/system/lib64/libaddsvc.so RUN_UID=1000
   /root/tpu-tachyon-run`). Watch for the setup line, a response instead of
   error 9, and the delegate creating a device.
3. If the payload differs, build the core's element in
   `tools/tpu-tachyon-client.c` (its `build_cmd` is a placeholder) and push it
   through the AUTHORIZED client session, which already has a working command
   and response queue.
4. Fix `EDGETPU_NUM_PREALLOCATED_DOMAINS` (0 in `janeiro/config.h`) and push the
   module once the setup is accepted.
5. After a real inference, benchmark TPU vs CPU vs GPU on `mosaic720.mp4` and
   record measured ms/frame and detections/frame.

## Rules (unchanged)

- Slot B only; never bootloader, radio, `devinfo`, `persist`, `efs*`, `modem*`,
  `vbmeta`, unsuffixed `fastboot flash`.
- Never load A14 firmware or vendor blobs; never commit firmware, blobs,
  MAC/Bluetooth addresses, serials, IMEIs or `getprop` dumps.
- One TPU power-up per cold boot; an oops or hang ends the boot.
- Screen/sound/feel changes get a one-line notice first.
- Kernel commits upstream-style, no `Signed-off-by`; repo commits `TPU-PLAN: …`.
- Fix causes, never weaken a check to make a run look clean.
