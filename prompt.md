# Next: fix the VII payload mapping in the janeiro driver

Measured (U103): the delegate reaches VII as uid 10000 and the firmware
refuses its command because the driver cannot copy the 128-byte payload
(`vii-payload iova 0xffefe000 size 128: no mapping`); the element then goes
out as type 0 and the firmware answers "Setup is not done yet".

1. Read `edgetpu-dmabuf.c`, the MAP_BUFFER ioctl in `edgetpu-fs.c` and
   `edgetpu_mapping_find_locked` in
   `~/omamobile-kernel/wt-tpu/drivers/edgetpu/`, and find why the iova the
   delegate puts in its VII command (0xffefe000) is not the key its dma-buf
   map was inserted under. Check whether the map lands in `dmabuf_mappings`
   at all, and whether `device_address` differs from the client iova.
2. Make one kernel change, build it with
   `KERNEL_DIR=~/omamobile-kernel/wt-tpu KERNEL_OUT=~/omamobile-kernel/out-tpu
   bin/omamobile kernel`, run checkpatch/W=1, then push and reboot-to
   omamobile. Expect `vii-payload ... no mapping` to disappear and the
   firmware's setup to complete; the delegate should then create its device.
3. Then run one inference, measure it, and run the 720p CPU/GPU/TPU
   object-detection comparison.
