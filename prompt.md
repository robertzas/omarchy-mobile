# prompt.md — make the firmware see a type-1 element, then the inference and the 720p benchmark

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

## Where it stands (U76, U77)

- VII is reachable only through the HAL's group; the client's `sendCommand`
  never reaches the firmware (`vii-elem` count 0 over its window).
- The element the firmware gets has `code` 0, and the firmware answers
  FAILED_PRECONDITION: "Setup is not done yet received a command of type 0".
- The element is **not** built by `0x15179fc` in `libdarwinn_hal.so`: a gdb
  breakpoint there missed in all 26 processes that map the library, while the
  element was still submitted. The runtime writes it into the mapped queue.

## This round, in order

1. **Find and rewrite the element in userspace (no reboot).** Start the chain
   (`NO_DELEGATE=1`), attach gdb to the process that owns the group, catch
   `ioctl` with request `0x4018ed10` (EDGETPU_SYNC_BUFFER), and on the first
   hit search the process's mappings for the element's known 16-byte prefix
   (`00000000 00000000 000b0000 00000000`). Rewrite byte 8 to 1, detach, and
   read `dmesg | grep -a 'vii-elem'` plus the firmware's reply. A `code` that
   reads 1 in the dump proves the rewrite landed before the doorbell.
2. **If userspace is not writable in time**, build the dev-only kernel rewrite:
   in `edgetpu-mailbox.c`'s VII receive path, set the first element's `code` to
   1 before the firmware sees it; rebuild `janeiro.ko`, push, reboot, `tpu-hold`,
   rerun the HAL+delegate, and read the firmware's answer.
3. If the firmware accepts type 1, take its next error literally (scratches,
   bitset, or a field) and iterate. If it still refuses, recover the core's
   type-1 message from `libtachyon_core.so` (`0xa4d5c`, `0xa4dec`) and build it.
4. With a setup accepted, run the HAL+delegate as system and look for
   `create device` success and a real inference.
5. Then the benchmark: `tools/bench-object-detection.py` on `mosaic720.mp4`
   for TPU, CPU and GPU; only measured numbers in TPU-PLAN.

## Phone state

`7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, up, `oops: 0`, TPU powered by
`tpu-hold`. Chroot `R=/usr/lib/omamobile-vendor/edgetpu/root`. Runner
`/root/tpu-tachyon-run` (`HAL_ONLY`, `NO_DELEGATE`, `RUN_UID`, `HAL_PRELOAD`).
gdb on the phone at `/usr/bin/gdb`. Logs `/tmp/run*.txt`, `/tmp/del*.out`,
`/tmp/gdb*.out`. `tools/phone-ssh --fresh` with
`OMAMOBILE_SSH_KEY=~/.ssh/id_ed25519`.
