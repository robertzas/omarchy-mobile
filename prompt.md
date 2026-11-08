# Prompt: make the Edge TPU inference, then benchmark 720p detection

Goal: one real Edge TPU inference on `cheetah`, then object detection on
`mosaic720.mp4` (10+ objects per frame) measured against CPU, GPU and every
other working path with `tools/bench-object-detection.py`. Only numbers from
runs that happened.

Read `device/cheetah/TPU-PLAN.md` U27-U72 first.

## Where it stands (2026-11-08, U72)

- Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`; `/dev/janeiro` up,
  one power-up per boot (`tpu-hold`).
- Darwinn HAL: registration passes with the `int 0` shim; the HAL stays up.
- Power HAL: a runner bug (`pkill -x android.hardwar` matched it) was killing it;
  fixed. It now stays up, but `android.hardware.power.IPower/default` is still
  NULL for a root probe while the Tachyon service is FOUND. servicemanager logs
  the VINTF hit from the Power HAL's pid. The forwarder reaches the real
  `AServiceManager_addService` through `dlopen("libbinder_ndk.so")` but gets a
  NULL status (prints -999), and the library does export `AStatus_getExceptionCode`.
- The chroot has no `/vendor/lib64/libbinder_ndk.so`; the framework one links
  `libbinder.so`, so NDK and C++ share one binder device.
- Setup: never pushed. No inference, no benchmark.

## Do these in order

1. Print the status pointer and `AStatus_isOk` in
   `tools/android-addsvc-real.c` and run it on the Power HAL again. A NULL
   pointer from a function that must return an `AStatus*` means our wrapper is
   calling the wrong entry (check the disassembly of `AServiceManager_addService`
   at 0x248e0), not that servicemanager refused.
2. If the status is real, read its exception code. EX_ILLEGAL_ARGUMENT there
   plus the VINTF log means servicemanager rejected the binder itself, not the
   name; then publish through the C++ `defaultServiceManager()` from a shim
   (`libbinder.so`, same device as the HAL's lookup) and check the probe again.
3. Independently of the Power HAL, push the firmware setup: run the client path
   (`NO_DELEGATE=1` chain, then `chroot --userspec=1000:1000 $R
   /vendor/bin/tpu-tachyon-client` with `DELAY=5 ROUNDS=3`), and watch
   `/tmp/tpu-tachyon.log` for `Sending firmware-setup VII command. type: 1` and
   `get_fds`, plus `dmesg | grep -iE 'janeiro|edgetpu'` for VII activity. If the
   setup is still absent, the type-1 `CommandMessageT` layout must be recovered
   from `libtachyon_core.so` (builder 0xa4d5c, push helper 0xa4dec, verifier
   0xb9c48) and built in `tools/tpu-tachyon-client.c`; the current `build_cmd`
   is a placeholder.
4. Fix `EDGETPU_NUM_PREALLOCATED_DOMAINS` (set 0 in `janeiro/config.h`), rebuild
   and push the module, then re-run.
5. After a real inference, benchmark TPU vs CPU vs GPU on `mosaic720.mp4` and
   record measured ms/frame and detections/frame.

## Rules (unchanged)

- Slot B only; never bootloader, radio, `devinfo`, `persist`, `efs*`, `modem*`,
  `vbmeta`, unsuffixed `fastboot flash`.
- Never load A14 firmware or vendor blobs; never commit firmware, blobs,
  MAC/Bluetooth addresses, serials, IMEIs or `getprop` dumps.
- One TPU power-up per cold boot; an oops or hang ends the boot.
- Screen/sound/feel changes get a one-line notice first.
- Kernel commits upstream-style, no `Signed-off-by`; repo commits `TPU-PLAN: …`.
- Fix causes, never weaken a check to make a run look clean.
