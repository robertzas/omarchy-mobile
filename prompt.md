# prompt.md — the gxp kernel driver is the only remaining route to the TPU

Do the suggested followups, then this prompt, then replace it and run the new
one.

## Rules

- Slot B only: `boot_b`, `init_boot_b`, `vendor_boot_b`, `vendor_kernel_boot_b`,
  `dtbo_b`, `userdata` through the tools. Never bootloader, radio, `devinfo`,
  `persist`, `efs*`, `modem*`, `vbmeta`; no unsuffixed `fastboot flash`.
- Never load the A14 firmware or A14 vendor blobs; the A17 image is the target.
  Its blob may be read locally for analysis, never committed.
- One TPU power-up per cold boot (`tpu-hold` first). An oops or hang ends the
  boot; reboot instead of retrying on a wedged TPU.
- No `Signed-off-by`; kernel commits upstream-style; repo commits `TPU-PLAN: …`;
  only measured numbers in any report.

## Where it stands (U76-U82)

- VII: the HAL and the delegate's runtime both send the obsolete pre-Tachyon
  message; no A17 producer exists (`libtachyon_dsp_core.so` needs `/dev/gxp`).
- The A17 firmware's code section is compressed/encrypted, so its setup parser
  cannot be read to build the message by hand.
- Measured CPU baseline (laptop, detect.tflite, mosaic720.mp4): 60 frames,
  3.86 ms mean, 259 fps, 9.0 detections/frame.

## Decision this round

Pick one and record the reasoning in TPU-PLAN before writing code:

1. **Write a minimal gxp driver** for the GXP IP on gs201 (device open, virtual
   device create, buffer pool, command/response queues) so `libgxp.so` can create
   a device and `libtachyon_dsp_core.so` can bring up the DSP core. Scope it
   against the vendor `libgxp.so`'s ioctl expectations and the A17 DT nodes; a
   read-only probe of the GXP register block comes first, one register per call,
   with the storage guard and watchdog in place.
2. **Stop the TPU bring-up here** and write the evidence-backed conclusion into
   the plan and docs (the TPU is gated on gxp and the vendor firmware container),
   then finish the CPU/GPU benchmark legs and the 10+ object clip so the
   comparison is complete for the parts that run.

Do not restart the VII/HAL patching: U80-U82 closed it.

## Phone state

`7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, up, `oops: 0`, TPU powered by
`tpu-hold`; HAL `0x14d9a48` restored to `mov x21, x2`. Chroot
`R=/usr/lib/omamobile-vendor/edgetpu/root`; runner `/root/tpu-tachyon-run`.
`tools/phone-ssh --fresh` with `OMAMOBILE_SSH_KEY=~/.ssh/id_ed25519`.
