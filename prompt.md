# Prompt: get the Edge TPU to its first inference, then benchmark 720p detection

Goal: one real Edge TPU inference on `cheetah` under mainline Linux, then object
detection on a 720p video (10+ objects per frame) measured against CPU, GPU and
every other working path with `tools/bench-object-detection.py` and
`mosaic720.mp4`. Numbers only from runs that happened.

Read `device/cheetah/TPU-PLAN.md` (U27-U71) first.

## Where it stands (2026-11-08, U71)

- Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`; `/dev/janeiro` up,
  one power-up per cold boot (`tpu-hold`).
- Darwinn HAL: registration passes with `tools/android-addservice-shim.c`
  returning `0` from `AServiceManager_addServiceWithFlags`; HAL stays up.
- `edgetpu_mmu_alloc_domain+0xa0` is a WARN (`panic_on_warn=0`) from
  `iommu_set_fault_handler` on a reused pooled domain, not an oops. Fix:
  `EDGETPU_NUM_PREALLOCATED_DOMAINS` = 0 in `janeiro/config.h`.
- Power HAL: was refused by the VINTF manifest, now declared in
  `device/cheetah/tpu-vintf-manifest.xml` (`IPower/default`, `IPowerExt/default`)
  and installed in the chroot; servicemanager answers "Found … in device VINTF
  manifest", the HAL logs "is started" and stays up as uid 1000 and as root.
  **But the Darwinn HAL's lookup still fails**: "Waiting for service
  'android.hardware.power.IPower/default' on '/dev/vndbinder'" → "didn't start.
  Returning NULL", after the Power HAL logs "Thread Pool max thread count is 0.
  Cannot cache binder".
- Setup: still never pushed; the client reaches AUTHORIZED, `get_fds` never
  called. The core's DSP actor needs `/dev/gxp` (U65), so the setup must come
  from the HAL's `SetupFirmware` (U67 bitset patch) or a type-1
  `CommandMessage` built by the client.

## Do these in order

1. Explain the lost registration with a tiny root probe in the chroot: call
   `ABinderProcess_startThreadPool()`, then `AServiceManager_addService()` of a
   test name and `AServiceManager_getService()` of it in the same process, print
   both `AStatus` codes. If the lookup fails there too, servicemanager drops the
   add after the VINTF check; if it succeeds, the Power HAL's binder or instance
   name differs. `tools/android-addsvc-real.c` shows `dlsym(RTLD_NEXT, …)` is
   NULL here; use `dlopen("/system/lib64/libbinder_ndk.so")` + `dlsym`.
2. Re-run `HAL_ONLY=1 RUN_UID=10000` and confirm `Unable to connect to Power
   HAL` is gone, then watch for `Sending firmware-setup VII command. type: 1`
   and `get_fds` in `/tmp/tpu-tachyon.log` and VII/KCI lines in `dmesg`.
3. If the setup still does not run, recover the type-1 `CommandMessageT` layout
   from `libtachyon_core.so` (builder/log at `0xa4d5c`, push helper at
   `0xa4dec`, verifier `0xb9c48`; the core prints "Sending firmware-setup VII
   command. type: ", "PushFirmwareSetupCmdToVII failed", "Failed to push
   firmware setup command due to VII command queue is full") and build it in
   `tools/tpu-tachyon-client.c` instead of the placeholder `build_cmd`.
4. After a real inference, benchmark `mosaic720.mp4` for TPU, CPU and GPU and
   record measured ms/frame and detections/frame in the plan.

## Rules (unchanged)

- Slot B only; never bootloader, radio, `devinfo`, `persist`, `efs*`, `modem*`,
  `vbmeta`, unsuffixed `fastboot flash`.
- Never load A14 firmware or vendor blobs; never commit firmware, blobs,
  MAC/Bluetooth addresses, serials, IMEIs or `getprop` dumps.
- One TPU power-up per cold boot; an oops or hang ends the boot (reboot,
  record, do not retry).
- Screen/sound/feel changes get a one-line notice first.
- Kernel commits upstream-style, no `Signed-off-by`; repo commits use
  `TPU-PLAN: …`.
- Fix causes, never weaken a check to make a run look clean.
