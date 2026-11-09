# Next: make the VII payload lookup find an offset inside a mapping

Measured (U104): the group's dma-buf map is at `iova=0xfff00000, 256 pages`,
while the failed VII payload was at `0xffefe000`; `compare()` only matches an
exact `device_address`, so an offset into the mapping is never found. A later
run copied some payloads but the firmware still logged six "Setup is not done
yet" and the delegate still ended at `device: 0x0`.

1. In one delegate run, collect the driver's `mappings` dump and every
   `vii-payload` line together, and decide which buffer the setup command
   uses (map base, base minus a header, or a separate host mapping).
2. Fix `edgetpu_mapping_find_locked()`/`compare()` to find the mapping that
   *contains* the iova (range check on map_size), not only an exact match.
   Build with `KERNEL_DIR=~/omamobile-kernel/wt-tpu
   KERNEL_OUT=~/omamobile-kernel/out-tpu bin/omamobile kernel`, checkpatch and
   W=1 clean, then push and reboot-to omamobile.
3. Expect the setup command to arrive whole, the firmware to leave "Setup is
   not done", and the delegate to create its device. Then run one inference,
   measure it, and run the 720p CPU/GPU/TPU object-detection comparison.
