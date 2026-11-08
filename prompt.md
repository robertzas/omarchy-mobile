# Next cycle: unblock the Power HAL so the Tachyon session is created

Phone state at U68: up; `tpu-hold` holds the boot's power-up; the chroot's HAL
is the bitset-patched cheetah HAL; the Power HAL is blocked on
`android.frameworks.stats.IStats/default`; a group alloc oopsed (leaked IOMMU
domain), so a reboot is required before the next group.

## What is established
- `android.hardware.power-service.pixel-libperfmgr` never publishes
  `android.hardware.power.IPower/default`: it blocks in
  `AServiceManager_waitForService("android.frameworks.stats.IStats/default")`,
  which nothing in the chroot serves. The Tachyon core then caches a failed
  lookup and dispatches no command.
- The runner starts the HAL as root, but it must run as the app uid
  (`RUN_UID=10000`) or its util library opens `/dev/edgetpu` directly and leaks
  an IOMMU domain (U65).
- Manual vendor services need the runner's `LD_LIBRARY_PATH` (including
  `/apex/com.android.runtime/lib64/bionic`), or the loader cannot find libc.

## Steps
1. Reboot (`reboot-to`), wait for a fresh SSH login, then make the Power HAL
   independent of IStats:
   - A: patch `libperfmgr.so` so the `waitForService` for IStats returns null
     without blocking (keep `<lib>.orig`); or
   - B: serve a minimal `android.frameworks.stats.IStats/default` on
     `/dev/vndbinder` from a stub.
2. Start the chain with the Power HAL fully initialized before the tachyon
   service, and run the HAL as uid 10000 (`RUN_UID=10000`).
3. Pass: the HAL log stops at no `Unable to connect to Power HAL`, and
   `SetupFirmware` logs `Sending firmware-setup VII command. type: 1`; check
   dmesg for the VII tx and the firmware ring for `Setup is already done`.
4. Then one inference on `/vendor/etc/model.tflite` in the same boot, and after
   it the 720p 10+ object benchmark against CPU and GPU with
   `tools/bench-object-detection.py`.

## Guards
- Slot B only; one TPU power-up per boot; no A14 firmware; no vendor blobs or
  identifiers committed; never weaken the storage or IOMMU guards.
- Never restart the HAL after it has created a group: reboot instead (U65).
- The chroot root must stay mode 755 (`chmod 755 /usr/lib/omamobile-vendor/edgetpu/root`).
