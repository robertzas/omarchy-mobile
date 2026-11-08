# Get the Pixel 7 Pro Edge TPU (Janeiro) working and benchmarked

Goal: one real inference on the Edge TPU under mainline Linux, then 720p object
detection with 10+ objects per frame on the TPU, measured against CPU and GPU.
Read `device/cheetah/TPU-PLAN.md` first, especially U64 to U69; the phone is the
reference `cheetah`.

Hard rules: slot B only; never touch bootloader, radio, `devinfo`, `persist`,
`efs*`, `modem*`, `vbmeta`; no vendor blobs, firmware or identifiers in the repo;
never load the A14 firmware; one TPU power-up per cold boot; reboot to clear a
leaked IOMMU domain; no `Signed-off-by:`; commits are `TPU-PLAN: …`; never
report an unrun benchmark as a result.

Done this round (U69):

- The Power HAL no longer blocks. The IStats wait is in the Power HAL binary, not
  `libperfmgr.so`: patch file offset `0x1f584` from `bl AServiceManager_waitForService`
  to `mov x0, xzr`. It now starts ("Pixel Power HAL AIDL Service with Extension is
  started.") and logs "Cannot get IStats binder!" instead of waiting.
- `tools/tpu-tachyon-run` passes `$USPEC` to the Power HAL too, so `RUN_UID=10000`
  really runs every service as uid 10000.
- The Darwinn HAL now reaches the TPU (creates and finalizes group/context
  1073741824) but dies at `Could not register NNAPI IDevice service.`, because a
  uid-10000 caller may not register with servicemanager. As uid 1000 it gets past
  registration but reports `Non-ok status from HAL: 2` / `Unable to connect to
  Power HAL`.
- The Tachyon client reaches a fully AUTHORIZED session (create, createSession,
  both FMQs, sendCommand), yet the core pushes no firmware setup and `get_fds` is
  never called.

Left, in order:

1. Start the Darwinn HAL as system (uid 1000) inside the runner's window while
   the Power HAL is alive, and watch its log for `Sending firmware-setup VII
   command. type: 1`. If it still says `Non-ok status from HAL: 2`, find that
   status site (it is the HAL's own init, after the Tachyon Hal interface line)
   and compare with the uid-10000 run.
2. If the HAL path stays closed, take the fallback: recover the type-1
   `CommandMessageT` layout from `libtachyon_core.patched.so` (builder near
   `0xa4d5c`, verifier at `0xb9c48`) and build the setup in
   `tools/tpu-tachyon-client.c`, or port Google's `gxp` driver with `janeiro`
   blacklisted.
3. After a real inference on `/vendor/etc/model.tflite` in the same boot:
   benchmark 720p object detection with 10+ objects per frame on TPU, CPU and GPU
   with `tools/bench-object-detection.py` and `mosaic720.mp4`; report ms/frame and
   detections/frame per backend, and only measured numbers.
4. Keep committing code and plan updates as you go, and keep this file describing
   what is left.

Stop conditions: any oops, a leaked IOMMU domain, or a phone that stops answering
ends the run — reboot and record it, do not retry in the same boot.
