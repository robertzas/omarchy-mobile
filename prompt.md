# prompt.md — the Tachyon setup producer, then the inference and the 720p benchmark

Do the suggested followups, then this prompt, then replace it and run the new
one. Keep going until the TPU runs an inference and the 720p benchmark has
measured numbers.

## Rules

- Slot B only: `boot_b`, `init_boot_b`, `vendor_boot_b`, `vendor_kernel_boot_b`,
  `dtbo_b`, `userdata` through the tools. Never bootloader, radio, `devinfo`,
  `persist`, `efs*`, `modem*`, `vbmeta`; no unsuffixed `fastboot flash`.
- Never load the A14 firmware or A14 vendor blobs.
- One TPU power-up per cold boot: `tpu-hold` first. An oops or hang ends the
  boot; reboot instead of retrying on a wedged TPU.
- No `Signed-off-by`; kernel commits upstream-style; repo commits `TPU-PLAN: …`;
  only measured numbers in any report.

## Where it stands (U76-U80)

- The HAL's setup does run (restored `0x14d9a48`), and it sends the same
  pre-Tachyon `RequestAllocation` element as the delegate's own runtime: code 0,
  payload root 20, three times, `create device status: 13`.
- U67's `mov w21,#0x21` was actually clearing bit 32, so it skipped the
  builder; that is why no gdb breakpoint ever hit.
- The firmware wants the Tachyon setup (type 1 with global scratches). Only the
  core implements it, and the core's actor needs the vendor `gxp` driver.
- No producer of that message exists in the A17 image without `gxp`.

## This round, in order

1. **Hunt the producer elsewhere in the A17 image.** Search every binary in the
   chroot for the Tachyon setup's distinctive pieces (the scratch descriptor
   schema, the `global scratch` wording, a type-1 union builder) rather than the
   obsolete `Firmware setup failed` string. Check the app-service APK/native
   side, `libedgetpu_client.google.so` and any `com.google.edgetpu` APEX.
2. **If no producer exists, hand-build the message** from the firmware's parser:
   the fields the HAL's payload already carries (root 20, fields 48 and 5, a
   uoffset at 12) plus the scratch list the firmware names, delivered through
   the HAL's group as a type-1 element.
3. **Run the CPU/GPU baseline** of the 720p benchmark meanwhile, so the
   comparison has measured numbers: `tools/bench-object-detection.py` on
   `mosaic720.mp4`, CPU and GPU backends, numbers into TPU-PLAN.
4. With a setup accepted, the delegate reaches `create device`, then a real
   inference, then the TPU leg of the benchmark.

## Phone state

`7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, up, `oops: 0`, TPU powered by
`tpu-hold`. Chroot `R=/usr/lib/omamobile-vendor/edgetpu/root`; the HAL's
`0x14d9a48` is back to `mov x21, x2`. The runner is `/root/tpu-tachyon-run`
(`HAL_ONLY`, `NO_DELEGATE`, `RUN_UID`, `HAL_PRELOAD`). `tools/phone-ssh
--fresh` with `OMAMOBILE_SSH_KEY=~/.ssh/id_ed25519`.
