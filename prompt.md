# Prompt: get the Edge TPU to its first inference, then benchmark 720p detection

Goal: one real Edge TPU inference on `cheetah` under mainline Linux, then
object detection on a 720p video (10+ objects per frame) measured against CPU,
GPU and every other path that works, with `tools/bench-object-detection.py` and
`mosaic720.mp4`. Numbers only from runs that happened; never report an unrun
benchmark.

Read first: `device/cheetah/TPU-PLAN.md` (U27-U70), `prompt.md`'s rules below,
then the newest `device/cheetah/NOTES.md` entries.

## Where the chain stands (2026-11-08, U70)

- Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`; `/dev/janeiro` comes
  up, one power-up per cold boot via `tpu-hold`.
- The stock Darwinn NNAPI HAL now passes its registration:
  `tools/android-addservice-shim.c` must return `0` (not an `AStatus*`) from
  `AServiceManager_addServiceWithFlags`, because the HAL tests a 32-bit status.
  It is interposed into the HAL only (`HAL_PRELOAD` in `tools/tpu-tachyon-run`).
  The HAL reaches its thread pool and stays up.
- The `edgetpu_mmu_alloc_domain+0xa0` trace is a WARN, not an oops
  (`panic_on_warn=0`): `iommu_set_fault_handler()` refuses a pooled domain
  whose `cookie_type` is already set. Group create/finalize works; the stale
  `handler_token` is a latent UAF. Fix: `EDGETPU_NUM_PREALLOCATED_DOMAINS` = 0
  in `janeiro/config.h` so each group gets a fresh paging domain.
- The Tachyon client reaches `STARTED -> AUTHORIZED`; no firmware setup has
  ever been pushed. The core's DSP actor needs `/dev/gxp`, which this kernel
  does not have (U65), so the setup must come from `SetupFirmware` or from a
  type-1 `CommandMessage` the client builds itself.
- The Power HAL starts but publishes no
  `android.hardware.power.IPower/default`: stock servicemanager answers
  `registerLazyService*` with ENOTSUP, and a uid-10000 eager `addService` is
  refused. The HAL and the core therefore log
  `Unable to connect to Power HAL`.

## Do these in order

1. Publish `IPower` for real, then re-run
   `HAL_PRELOAD=/system/lib64/libaddsvc.so HAL_ONLY=1 RUN_UID=10000 /root/tpu-tachyon-run`
   and confirm `Unable to connect to Power HAL` is gone from both the HAL and
   the core. Options: make the Power HAL call the real eager
   `AServiceManager_addService` (uid 1000 accepted by servicemanager; the
   Tachyon service's lazy call is) through a shim that calls the next symbol,
   or patch the servicemanager's lazy path to accept it.
2. Watch for `Sending firmware-setup VII command. type: 1` and `get_fds` in
   `/tmp/tpu-tachyon.log`, and KCI/VII lines in `dmesg`. The HAL's
   `SetupFirmware` is already forced by the U67 bitset patch
   (`libdarwinn_hal.so.bitset-orig` is the backup).
3. If the setup still does not run, recover the type-1 `CommandMessageT` layout
   from `libtachyon_core.patched.so` (builder and log at `0xa4d5c`, push helper
   at `0xa4dec`, verifier `0xb9c48`) and build it in
   `tools/tpu-tachyon-client.c` instead of the placeholder `build_cmd`; push it
   through `sendCommand`. The firmware names what it wants
   (`No global scratches were provided in setup command.`).
4. After a real inference, run `tools/bench-object-detection.py` on
   `mosaic720.mp4` for TPU, CPU and GPU (and any other working backend), and
   record measured ms/frame and detections/frame in the plan before writing
   any result.

## Rules (unchanged, non-negotiable)

- Slot B only. Never touch bootloader, radio, `devinfo`, `persist`, `efs*`,
  `modem*`, `vbmeta`; never an unsuffixed `fastboot flash`.
- Never load A14 firmware or vendor blobs from anywhere but the user's own
  factory image; never commit firmware, blobs, MAC/Bluetooth addresses,
  serials, IMEIs or `getprop` dumps.
- One TPU power-up per cold boot. A leaked IOMMU domain, an oops or a hang
  ends the boot: reboot, record it in the plan, do not retry in that boot.
- Screen-, sound- or feel-affecting actions get a one-line notice before they
  run.
- Kernel commits are upstream-style, no `Signed-off-by:`; this repository's
  commits use the `TPU-PLAN: …` prefix.
- Fix causes, not checks: never weaken a guard or an assertion to make a run
  look clean.
