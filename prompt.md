# Next: recover the VII setup command from the vendor core

Measured (U106): KCI 6 and KCI 9 both answer 3 (`INVALID_ARGUMENT`) with the
hook's zeroed buffer; the driver's real `OPEN_DEVICE` path exists and runs;
the firmware still refuses the delegate's Sync with "Setup is not done yet
received a command of type 0" (error_code=9, create status 13).

1. In `out/edgetpu-runtime/stock/libdarwinn_hal.so`, locate the code that logs
   `PushFirmwareSetupCmdToVII` and the VII element it builds: the element
   type constant, the payload size and whether it carries a buffer address.
   `nm -C` may be stripped; use the string's xrefs and disassemble around
   them.
2. If the element type and an empty/small payload suffice, add a userspace
   helper that sends that one VII element over `/dev/janeiro` before the
   delegate's Sync. That completes the firmware setup without the core.
3. If the payload needs an address, check `edgetpu-dmabuf.c`'s map ioctl and
   reuse the mapping the setup buffer already has.
4. Re-run the delegate: expect no "Setup is not done", the Sync to answer, and
   `create device status: 0`. Then one inference, then the 720p comparison.
