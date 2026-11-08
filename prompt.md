# prompt.md — decide T6 on evidence: a gxp driver, or close the TPU bring-up

Do the suggested followups, then this prompt, then replace it and run the new
one.

## Rules

- Slot B only: `boot_b`, `init_boot_b`, `vendor_boot_b`, `vendor_kernel_boot_b`,
  `dtbo_b`, `userdata` through the tools. Never bootloader, radio, `devinfo`,
  `persist`, `efs*`, `modem*`, `vbmeta`; no unsuffixed `fastboot flash`.
- Never load the A14 firmware or A14 vendor blobs. The A17 blob may be read
  locally for analysis, never committed.
- One TPU power-up per cold boot (`tpu-hold` first).
- Reads of blocks not known powered and clocked, `devmem` writes, PMU register
  access and any gxp/register probe are the owner's call per step (§1.1 grant).
- No `Signed-off-by`; repo commits `TPU-PLAN: …`; only measured numbers.

## Where it stands (U76-U83)

- VII is closed on evidence: both A17 runtimes send the pre-Tachyon setup the
  firmware rejects (error 9); the only Tachyon producer needs `/dev/gxp`; the
  firmware's code section is compressed/encrypted; our DT has no gxp node.
- Measured, same clips, SSD 300x300, threshold 0.5, 60 frames:
  mosaic12 (10.0 detections/frame) CPU 3.97 ms / 252 fps, GPU 3.00 ms / 333 fps;
  mosaic720 (9.0) CPU 3.86 ms / 259 fps, GPU 2.79 ms / 358 fps.
- No TPU inference has ever run; no TPU number exists.

## This round, in order

1. **Ask the owner for the one decision**: fund a gxp driver (DT description from
   stock's A17 DT, then a read-only register probe, then the minimal driver), or
   close T6 on the evidence above. Record the answer in TPU-PLAN with the date.
2. **If the driver is approved**, start with the DT description and one read-only
   register read per step under `--watchdog`, and record every reply.
3. **If T6 is closed**, make the docs and TPU-PLAN say so in one final
   `TPU-PLAN:` commit, leave the benchmark numbers as the measured comparison,
   and do not reopen the VII/HAL patching.

## Phone state

`7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, up, `oops: 0`, TPU powered by
`tpu-hold`; HAL `0x14d9a48` restored to `mov x21, x2`. Chroot
`R=/usr/lib/omamobile-vendor/edgetpu/root`; runner `/root/tpu-tachyon-run`.
`tools/phone-ssh --fresh` with `OMAMOBILE_SSH_KEY=~/.ssh/id_ed25519`.
