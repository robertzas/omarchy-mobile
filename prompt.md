# prompt.md — fix the HAL's setup command, then the inference and the 720p benchmark

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

## Where it stands (U76-U79)

- The client never reaches VII; the HAL is the only writer (U76).
- The element the firmware gets is the HAL's setup: `code` 0 and a 128-byte
  payload, and its last field pair is the flatbuffer at `0xffdff000` (U75/U78).
- The HAL's own runtime is the setup producer: both setup strings live in
  `libdarwinn_hal.so`/`libedgetpu_util.so`, none in `libtachyon_core.so` (U79).
- The HAL logs `Firmware setup failed for commands[0], cluster_id_bitset in hex:
  0` while its payload's first field is `0x30`. The firmware still says
  FAILED_PRECONDITION, "Setup is not done yet received a command of type 0".

## This round, in order

1. **Read the HAL's setup walk.** Find the xref of the `Firmware setup failed`
   string (`0x4b8c71` in `libdarwinn_hal.so`) and disassemble that function:
   where `commands[]` comes from, the field it prints as the bitset, the command
   type it assigns, and whether the list is built from a static descriptor or a
   proto. Record the offsets.
2. **Patch the two numbers the firmware judges.** Set `commands[0]`'s
   `cluster_id_bitset` (currently 0) to the device's mask used elsewhere
   (`0x21` from U67 or `0x30` from the payload) and, if the walk shows it, the
   command type. One number per run, HAL+delegate as system, then read
   `dmesg | grep -a 'vii-'` and the HAL's next log line.
3. If the firmware accepts the setup, the delegate path should reach
   `create device`; then run a real inference.
4. If the HAL's command cannot be made to satisfy it, fall back to the core
   path only with a real producer found (U79 closed the assumed one).
5. Then the benchmark: `tools/bench-object-detection.py` on `mosaic720.mp4`
   for TPU, CPU and GPU; only measured numbers in TPU-PLAN.

## Phone state

`7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, up, `oops: 0`, TPU powered by
`tpu-hold`. Chroot `R=/usr/lib/omamobile-vendor/edgetpu/root`, HAL
`vendor/lib64/libdarwinn_hal.so` (patched at `0x14d9a48` to `mov w21,#0x21`;
`.orig` and `.provider` copies beside it). Runner `/root/tpu-tachyon-run`
(`HAL_ONLY`, `NO_DELEGATE`, `RUN_UID`, `HAL_PRELOAD`). `tools/phone-ssh
--fresh` with `OMAMOBILE_SSH_KEY=~/.ssh/id_ed25519`.
