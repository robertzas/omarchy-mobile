# Next: find who sends the VII setup, and why the core's does not arrive

Measured (U105): KCI code 6 is accepted and answered `3`, and the firmware
still logs "Setup is not done yet"; the delegate's first VII is a Sync that
fails with `error_code=9`, then `create device status: 13`. The driver has
`mobile_firmware_setup_buffer` registered as `.setup_buffer` and called at
firmware load.

1. Read `mobile_firmware_setup_buffer()` and `edgetpu-firmware.c` around line
   104: what does the buffer hold, and is its TPU address handed to the VII
   layer? The core string `PushFirmwareSetupCmdToVII` says the Tachyon core
   sends the setup as a VII command, so the address must reach it.
2. Run the tachyon service alone with maximum logging and check whether it
   sends that setup (and gets error 9), or whether it never gets a device at
   all. Compare with the vendor HAL's device-open order.
3. If the address is missing, add the setup command to the core path (or to
   device open) in the driver and rebuild with
   `KERNEL_DIR=~/omamobile-kernel/wt-tpu KERNEL_OUT=~/omamobile-kernel/out-tpu
   bin/omamobile kernel`, checkpatch and W=1 clean, then push and reboot-to
   omamobile. Expect Sync to succeed and `create device status: 0`.
