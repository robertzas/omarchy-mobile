# Next: give the janeiro node its clocks and power domains

The blocker is now structural and small (U46): our `janeiro@1ce00000` has **no
`clocks` and no `power-domains`** properties, which is exactly why every AON
register reads `0xdeadfeed` and `PSM0_STATUS` never reports 0x80. DVFS works
(ACPM accepts and reports the state), the mailbox works (irq 163 fires), the
device node is right (from sysfs) — the island is simply unclocked.

1. Read the stock node from the phone: `dd if=/dev/sda14 bs=4096 count=64 | dtc
   -I dtb -O dts` (dtbo_a, read-only; never write slot A). Copy its
   `clocks`, `clock-names`, `power-domains`, `power-domain-names`, extra `reg`
   entries and `samsung,acpm-ipc` into `gs201.dtsi`'s janeiro node (or a
   bring-up overlay), keeping the mainline names for anything the mainline clock
   and PM-domain drivers already provide.
2. If the vendor names a clock the mainline CMU driver does not expose yet, that
   clock is the work: add it to the gs201 clock driver (a read-only gate is not
   enough here; the TPU AON clock must be enable-able).
3. Apply, rebuild, `modules-push` if only the module changed, and test with the
   sysfs node and no stray clients: `timeout 60 chroot $R /vendor/bin/edgetpu-run
   /vendor/detect_edgetpu.tflite`, then `dmesg | grep janeiro`.

Success is `Set LPM0` gone and the tool printing the graph's tensor counts. Then
the benchmark: `detect_edgetpu.tflite` over the 720p 10-object video against CPU
(3.98 ms/frame at 4 threads, 10 detections/frame at 0.4), GPU and the rest.

Rules unchanged: slot B only, `pkill -x`, `depmod` + `modules-push` after a module
change, announce screen-off before `poweroff`, no vendor blobs or identifiers, no
`Signed-off-by`.
