# Next: run the delegate on the setup-skipping HAL, then the model

Measured (U107): the delegate still fails `Sync VII command failed:
error_code=9` and `create device status: 13` because the chroot's
`libdarwinn_hal.so` is the stock copy. U56 showed that patching `tbz` at
`0x14d9a5c` (`36000088` -> `d503201f`) makes `SetupFirmware` a no-op and the
HAL's `CreateDevice` return OK with group and context created.

1. On a cold boot (one TPU power-up per boot; `tpu-hold` first), copy the
   chroot's `libdarwinn_hal.so` aside, apply the provider patch (`0x1569ae0`
   -> `mov w0,#1; ret`) and the setup skip (`0x14d9a5c` -> `nop`), and record
   both sha256s. Dev-only, chroot copy, never the repo.
2. Run the delegate as the boot's first TPU user
   (`DELEGATE_UID=10000 /root/tpu-tachyon-run`). Pass: `create device
   status: 0`, `device: 0x...`, no "Setup is not done".
3. If it creates the device, run `/vendor/etc/model.tflite` through the
   delegate and capture the inference output; if a later command is refused
   with the setup error, dump that command's element and payload from dmesg.
4. Restore the stock library afterwards (keep the `.orig` backup).
