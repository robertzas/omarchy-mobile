# Next: reach the running Tachyon service by shimming Android properties

State: the TPU powers up, loads firmware, opens the device and finalizes its
mailbox (U29). The vendor Tachyon service now runs on our Linux userspace
(`tools/tpu-tachyon-run` mounts binderfs, runs `servicemanager` from the stock
system image, and loads two shims). The delegate still cannot use it: without
`tools/edgetpu-nometrics.so` it hangs in `DarwinnDelegate_CreateVirtualDevice`
before any VII command (rc 124); with that shim it skips the service and gets
`error_code=9` from the firmware. The difference is Android's property service.

Do not re-derive:

- Kernel: `CONFIG_ANDROID_BINDER_IPC=y`, `CONFIG_ANDROID_BINDERFS=y`,
  `CONFIG_SECURITY_SELINUX` not set. binderfs is mounted per boot and `binder`
  is 507:1.
- `servicemanager` extracted from `out/cp2a-system.img` needs both
  `tools/android-log-stderr.c` and `tools/android-selinux-allow.c` preloaded;
  with them it stays up and the Tachyon service starts and stays up.
- `libedgetpu_tachyon.google.so`: `TachyonComputeService_create` calls
  `AServiceManager_isDeclared` then `AServiceManager_waitForService`;
  `TachyonComputeSession_setupCommandQueue` only calls `SetupCommandFmq` on a
  session the service hands out. So a session is only reachable through binder.
- Firmware gate: one VII setup command per firmware boot carrying the global
  scratches; the delegate never sends it, and the service is the thing that
  does on stock.

Step 1 (laptop, read-only): find what the property wait needs.
- `nm -D --undefined-only` on `libbinder.so` / `libbinder_ndk.so` and
  `libedgetpu_util.so` for `__system_property_*`, then disassemble
  `AServiceManager_isDeclared` and its `WaitForPropertyCreation` caller.
- Decide which functions to answer: likely `__system_property_find`,
  `__system_property_read_callback`, `__system_property_wait`,
  `__system_property_get`, and `__system_property_set`.

Step 2 (laptop): add `tools/android-props-stub.c` (same freestanding pattern as
the other two shims) returning a fixed `ro.build.version.sdk=34` and an empty
property set, with `wait` returning 0 immediately. Build it for
aarch64-linux-android30, no libc.

Step 3 (phone, cold boot): add it to the runner's `LD_PRELOAD` for the delegate
only (servicemanager does not need it), run, and watch:
- dmesg for `OPEN_DEVICE ret 0` and mailbox VII init;
- the delegate log: it must get past `CreateVirtualDevice`, reach the service,
  and then either a Sync with rc 0 or the firmware's setup message;
- `/tmp/tpu-tachyon.log` and `dmesg | grep -i edgetpu` for the setup.
Pass: a VII submission returns 0, or the firmware log says
`Setup is already done`.

Step 4 (fallback): if the property shim is not enough, write
`tools/tachyon-client.c` that calls `TachyonComputeService_create` and
`TachyonComputeService_createSession` directly with the shims preloaded.

Rules: slot B only; `poweroff` and `reboot-to` are pre-authorized (AGENTS
§1.1) but announce screen-off; one TPU power-up per boot, so a failed attempt
means a cold boot before the next; never `rmmod` janeiro and never insmod over
a loaded module (the runner waits for the autoload); record results in
`device/cheetah/TPU-PLAN.md` as U30+ with `uname -r`.

After the gate opens: one real inference through the delegate, compare with CPU
TFLite, then the 720p 10+-object benchmark against CPU/GPU. The harness is
ready: `tools/bench-object-detection.py` with `out/bench/detect.tflite`,
`out/bench/labelmap.txt`, `out/bench/mosaic720.mp4` (10 detections/frame,
3.98 ms/frame on 4 CPU threads).
