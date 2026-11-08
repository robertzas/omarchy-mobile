# prompt.md — recover the core's type-1 setup message, then the inference and the 720p benchmark

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

## Where it stands (U76-U78)

- The client never reaches VII; the HAL is the only writer (U76).
- The element the firmware gets is the HAL's normal sync: `code` 0 with a
  128-byte command flatbuffer, no scratches (U75), and it is not assembled by
  the `0x15179fc` builder (U77).
- The element lives only in the driver's coherent queue, unreachable from
  userspace (U78), so rewriting its code is closed as a path.
- The firmware wants a Tachyon type-1 setup message with global scratches; the
  only producer is `libtachyon_core.so`, whose actor needs the vendor `gxp`
  driver.

## This round, in order

1. **Recover the message.** Disassemble `libtachyon_core.so` around the push
   (`0xa4d5c`), the builder (`0xa4dec`) and the verifier (`0xb9c48`). Name every
   field it writes before the push: the union type byte, the command id, the
   cluster bitset, the scratch descriptors (iova/size pairs), and where they
   come from. Write the layout down as a C struct in a tool under `tools/`.
2. **Call the producer.** From a chroot program, `dlopen` the core, compute its
   base, and call the setup push by address with the session/group handles the
   client already obtains, or find the app service's own caller of it and run
   that path. Any push leaves a `Sending firmware-setup VII command` line and a
   `vii-` dump; read the firmware's answer literally.
3. If the core refuses without `gxp`, build the message in C from step 1 and
   hand it to the HAL: patch the HAL's setup command descriptor (its model
   config bytes) so the element it submits is the type-1 message, or inject it
   through the core's own queue API.
4. With a setup accepted, run the HAL+delegate as system and look for
   `create device` success and a real inference.
5. Then the benchmark: `tools/bench-object-detection.py` on `mosaic720.mp4`
   for TPU, CPU and GPU; only measured numbers in TPU-PLAN.

## Phone state

`7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, up, `oops: 0`, TPU powered by
`tpu-hold`. Chroot `R=/usr/lib/omamobile-vendor/edgetpu/root`. Runner
`/root/tpu-tachyon-run` (`HAL_ONLY`, `NO_DELEGATE`, `RUN_UID`, `HAL_PRELOAD`).
gdb at `/usr/bin/gdb`. `/tmp/scan2.py` is the element scanner (no hits).
`tools/phone-ssh --fresh` with `OMAMOBILE_SSH_KEY=~/.ssh/id_ed25519`.
