# Next: send the type-1 setup for real, not a skipped one

Measured (U108): the chroot HAL already carries U56's two patches, and the
delegate still gets `Sync VII command failed: error_code=9` and `create device
status: 13`. Skipping `SetupFirmware` does not satisfy the firmware; the
setup element itself must arrive.

1. From U56's dump, the element's type is the `u16` at byte 8 (0 in every
   command so far) and the core's setup path prints a type byte it sets to
   **1**. Confirm the offset by dumping the A14 HAL's setup element again with
   the driver's 48-byte dump, then patch the one instruction in
   `libdarwinn_hal.so` that stores that type so the HAL sends type 1 with its
   existing payload; run the delegate and read the firmware's answer.
2. If the answer is "No global scratches were provided", build the scratch
   list: the core's `0xd35c8` mmaps 24-byte entries from a firmware-scratch
   fd; recover its producer at `0xa4d5c` in
   `out/factory/tegu-cp21/vendor-libs/libtachyon_core.patched.so` and
   reproduce it in `tools/tpu-tachyon-client.c`.
3. On acceptance, run one inference through the delegate and measure it, then
   the 720p CPU/GPU/TPU comparison.
