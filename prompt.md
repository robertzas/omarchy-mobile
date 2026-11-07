# Next: unpack vendor_boot_a's DTB section and read the real janeiro node

The TPU blocker is a device-tree gap (U46): `janeiro@1ce00000` has no `clocks`
and no `power-domains`, so its AON registers read `0xdeadfeed` and `PSM0_STATUS`
never acknowledges. Stock's node is not in `dtbo_a` (U47, no janeiro fragment)
and not a plain FDT in `boot_a` or the first 24 MB of `vendor_boot_a` (U48), so:

1. The whole 64 MB `vendor_boot_a` contains **no** FDT magic, so unpack it
   properly on the laptop: read the `ANDROID!` boot-image header (page size,
   kernel/ramdisk sizes, header v4's `dtb_size`/`dtb_addr`), decompress the
   payload if needed, and find the DTB section. Use `unpack_bootimg`-style
   parsing in the project container rather than magic scans on the phone.
2. Dump that node's `clocks`, `clock-names`, `power-domains`,
   `power-domain-names`, `reg`, `samsung,acpm-ipc` and `gsa-device`.
3. Add the missing properties to `gs201.dtsi`'s janeiro node, using mainline
   names where the mainline clock/power-domain drivers already expose the same
   hardware; if the AON clock is not exposed, add it to the gs201 clock driver.
4. Rebuild (modules too - `janeiro` is a module), `modules-push`, recreate
   `/dev/janeiro` from `/sys/class/edgetpu/janeiro/dev`, kill stray clients, and
   run `timeout 60 chroot $R /vendor/bin/edgetpu-run /vendor/detect_edgetpu.tflite`.

Success: no `Set LPM0 failed`, and the tool prints the graph's tensor counts. Then
benchmark `detect_edgetpu.tflite` on the 720p 10-object video against CPU (3.98
ms/frame at 4 threads, 10 detections/frame at 0.4), GPU and the other backends.

Rules: slot B only, read-only on slot A, `pkill -x`, `depmod` + `modules-push`
after module changes, announce screen-off before `poweroff`, no vendor blobs or
identifiers in commits, no `Signed-off-by`.
