# prompt.md — the Tachyon setup message, by hand, or the gxp driver

Do the suggested followups, then this prompt, then replace it and run the new
one. Keep going until the TPU runs an inference and the 720p benchmark has
measured numbers for TPU, CPU and GPU.

## Rules

- Slot B only: `boot_b`, `init_boot_b`, `vendor_boot_b`, `vendor_kernel_boot_b`,
  `dtbo_b`, `userdata` through the tools. Never bootloader, radio, `devinfo`,
  `persist`, `efs*`, `modem*`, `vbmeta`; no unsuffixed `fastboot flash`.
- Never load the A14 firmware or A14 vendor blobs; the A17 image is the target.
- One TPU power-up per cold boot (`tpu-hold` first). An oops or hang ends the
  boot; reboot instead of retrying on a wedged TPU.
- No `Signed-off-by`; kernel commits upstream-style; repo commits `TPU-PLAN: …`;
  only measured numbers in any report.

## Where it stands (U76-U81)

- The HAL's setup is the same pre-Tachyon `RequestAllocation` element as the
  delegate's runtime; U67's patch had been skipping it, not forcing it.
- No A17 binary produces the Tachyon setup: `libtachyon_dsp_core.so` is the GXP
  server and needs `/dev/gxp`, which mainline does not have.
- CPU baseline measured on the laptop: 60 frames, 3.86 ms mean, 259 fps, 9.0
  detections/frame.

## This round, in order

1. **Build the Tachyon setup message by hand.** Take the firmware's own error
   text as the spec (`No global scratches were provided in setup command`) and
   the HAL payload as the carrier: root 20, fields at 48 and 5, a uoffset at 12
   to offset 44. Write a small builder (Python or C) that emits the type-1
   message with a global scratch list, send it through the HAL's group with the
   same 128-byte element, and read the firmware's answer in `dmesg`.
2. **Iterate on the firmware's replies, one change per attempt.** A different
   error is progress even without acceptance; record each in TPU-PLAN.
3. **Get the phone CPU and GPU legs** with a runtime that exists on the image
   (no PyPI): the A17 TFLite runner (`edgetpu-run` wrapper) and the vendor GPU
   path if present; if neither can run a plain TFLite model, say so in the plan
   and use the laptop numbers as the CPU reference.
4. **Re-shoot or re-cut the clip** so frames carry 10+ simultaneous objects at
   the model's input size, and re-run all legs on the same clip.

## Phone state

`7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, up, `oops: 0`, TPU powered by
`tpu-hold`; HAL `0x14d9a48` restored to `mov x21, x2`. Chroot
`R=/usr/lib/omamobile-vendor/edgetpu/root`; runner `/root/tpu-tachyon-run`.
`tools/phone-ssh --fresh` with `OMAMOBILE_SSH_KEY=~/.ssh/id_ed25519`.
