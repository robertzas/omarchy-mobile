# prompt.md — the TPU's setup element, then one inference, then the 720p benchmark

Do the suggested followups, then this prompt, then replace it and run the new
one. Keep going until the TPU runs an inference and the 720p benchmark has
measured numbers.

## Rules

- Slot B only: `boot_b`, `init_boot_b`, `vendor_boot_b`, `vendor_kernel_boot_b`,
  `dtbo_b`, `userdata` through the tools. Never bootloader, radio, `devinfo`,
  `persist`, `efs*`, `modem*`, `vbmeta`; no unsuffixed `fastboot flash`.
- Never load the A14 firmware or A14 vendor blobs. The A17 pair on the phone is
  the only firmware.
- One TPU power-up per cold boot: `tpu-hold` before anything else. An oops or a
  hang ends the boot; reboot instead of retrying on a wedged TPU.
- No `Signed-off-by`; kernel commits upstream-style; repo commits `TPU-PLAN: …`;
  only measured numbers in any report.

## Where it stands (U76)

- VII is reachable only through the HAL's group. The client's `sendCommand`
  fills the session FMQ and the core never syncs it: the client run produced no
  `vii-` line and `vii-elem` count 0.
- The HAL's `SetupFirmware` sends a normal command (`code` 0). The firmware
  refuses it with "Setup is not done yet received a command of type 0"
  (`KCI_ERROR_FAILED_PRECONDITION` = 9), then the HAL sets
  `firmware_setup_done_` anyway.
- The 128-byte payload at `0xffdff000` is a flatbuffer: root at 20, vtable at
  10 with three fields (48, 5, a uoffset to 44). The firmware's own strings name
  the missing part: `No global scratches were provided in setup command.`

## This round, in order

1. Get a type-1 element to the firmware. Run the HAL+delegate under gdb,
   break at the sync ioctl, rewrite the element's `code` (byte 8) from 0 to 1,
   continue, and read the answer in `dmesg | grep -a vii-`. Record the exact
   status. If the firmware accepts type 1, the next refusal will name the next
   missing piece; if it still refuses, dump the element and payload again and
   compare with the core's builder (`0xa4d5c`, `0xa4dec` in
   `libtachyon_core.so`) to see the fields it expects.
2. If the answer asks for scratches, add one descriptor to the message (iova
   from the HAL's mapped scratch page, size 0x1000) and repeat.
3. With a setup accepted, rerun the HAL+delegate as system and look for
   `create device` success and a real inference through the delegate.
4. `EDGETPU_NUM_PREALLOCATED_DOMAINS=0` in `janeiro/config.h`, rebuild, push —
   removes the `edgetpu_mmu_alloc_domain+0xa0` WARN that a second session hits.
5. Then the benchmark: `tools/bench-object-detection.py` on `mosaic720.mp4`
   (10+ objects per frame) for TPU, CPU and GPU, and record only measured
   numbers in TPU-PLAN.

## Phone state

`7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, up, `oops: 0`, TPU powered once
this boot. Chroot `R=/usr/lib/omamobile-vendor/edgetpu/root`. Runner
`/root/tpu-tachyon-run` with `HAL_ONLY`, `NO_DELEGATE`, `RUN_UID`, `HAL_PRELOAD`.
Client `/root/tpu-tachyon-client` (the FMQ path only; see U76). Log
`/tmp/tpu-tachyon.log`. `tools/phone-ssh --fresh` with
`OMAMOBILE_SSH_KEY=~/.ssh/id_ed25519`.
