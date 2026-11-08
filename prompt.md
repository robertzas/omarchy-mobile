# Get the Pixel 7 Pro Edge TPU (Janeiro) working and benchmarked

Goal: one real inference on the Edge TPU under mainline Linux, then 720p object detection with 10+ objects per frame on the TPU, measured against CPU and GPU. Read `device/cheetah/TPU-PLAN.md` first, especially U56, U64, U65, U67 and U68; the phone is the reference `cheetah`.

Hard rules: slot B only; never touch bootloader, radio, `devinfo`, `persist`, `efs*`, `modem*`, `vbmeta`; no vendor blobs, firmware or identifiers in the repo; never load the A14 firmware; one TPU power-up per cold boot; reboot to clear a leaked IOMMU domain; no `Signed-off-by:`; commits are `TPU-PLAN: …`; never report an unrun benchmark as a result.

Current blocker (confirmed twice, on a clean boot): the pixel-libperfmgr Power HAL starts, loads its node table, then blocks forever in `AServiceManager_waitForService("android.frameworks.stats.IStats/default")`, so it never registers `android.hardware.power.IPower/default`. Nothing in the chroot serves IStats (no `statsd`; the stats service binary is a client). The Darwinn HAL then logs `Service android.hardware.power.IPower/default didn't start. Returning NULL` and `[Darwinn] Unable to connect to Power HAL`, and creates no Tachyon session. The HAL must run as uid 10000 (as root its util library opens `/dev/edgetpu` itself and oopses in `edgetpu_mmu_alloc_domain`).

Do, in order:

1. Record the clean-boot result in `TPU-PLAN.md` U68 and commit.
2. Find the IStats wait in `$R/vendor/lib64/libperfmgr.so` (use `readelf -r`/PLT and the stripped symbol table; `objdump -T` shows no `waitForService`). Back it up to `.orig` and patch the call so it returns null immediately instead of blocking, or serve a minimal `android.frameworks.stats.IStats/default` stub on `/dev/vndbinder`. Keep the patch minimal and reversible.
3. Start the Power HAL with the runner's `LD_LIBRARY_PATH` and shims, and confirm from its log that it registers `IPower/default` (it must no longer print the IStats wait). `tools/tpu-tachyon-run` is the runner; fix its `USPEC` bug so `RUN_UID=10000` really uses `chroot --userspec=10000:10000`.
4. Start the vendor service, load the driver, take the boot's single power-up (`tpu-hold`), then start the tachyon service and the HAL as uid 10000. Watch dmesg and the HAL log for `Sending firmware-setup VII command. type: 1`, then the firmware ring for the setup acceptance.
5. Run one inference on `/vendor/etc/model.tflite` in the same boot and check the output is sane.
6. Benchmark 720p object detection with 10+ objects per frame on TPU vs CPU vs GPU using `tools/bench-object-detection.py` and `mosaic720.mp4`; report ms/frame and detections/frame per backend, and only numbers you actually measured.
7. Commit the code and plan updates as you go, and keep `prompt.md` describing whatever is left.

Stop conditions: any oops, a leaked IOMMU domain, or a phone that stops answering ends the run — reboot and record it, do not retry in the same boot. If the HAL cannot be unblocked, fall back to recovering the type-1 `CommandMessageT` layout from `libtachyon_core.patched.so` (builder near `0xa4d5c`, verifier at `0xb9c48`) or to Google's `gxp` driver with `janeiro` blacklisted.
