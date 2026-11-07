# Next: why the delegate never connects to the Tachyon service

State (U33): every vendor client library loads in the chroot, servicemanager
and `com.google.edgetpu.tachyon-service` are both alive, and the delegate still
takes its direct path: `Sync VII command failed: error_code=9`, then
`create device status: 13`, `device: 0x0`, rc 1. It never logs a Tachyon
connection attempt, although `libedgetpu_tachyon.google.so` has the service
name `com.google.edgetpu.tachyon.IComputeService/default` and the message
`Failed to connect to the Tachyon Compute Service`.

Do not re-derive: `tools/tpu-tachyon-run` (modes `GDB=1`, `BT=1`, `PROBE=1`)
sets everything up; `tools/android-log-stderr.c` is installed as the chroot's
`liblog.so` and covers all 21 liblog symbols; `tools/android-props-stub.c`
answers `servicemanager.ready` `true`, sdk `34`, else `1`;
`tools/dlopen-check.c` proves the client libraries load. The chroot's
`/system/lib64/libc.so` points at a stale `/tmp/sysx/...`, so any inline repro
needs the runner's `LD_LIBRARY_PATH`.

Step 1: find the branch. In `libedgetpu_util.so` the client is `dlopen`ed at
`0x1bf8e0` behind a lazily initialized global at `[x22, #0x8a8]`; the object
built around it is 104 bytes and its slots are filled by `dlsym` from
`/vendor/lib64/libedgetpu_client.google.so`. Trace who calls that initializer
and what sets the "use the client" flag. `llvm-objdump -d` plus
`llvm-objdump -s -j .data` around `0x3a6000` are the tools.

Step 2: test the cheap hypothesis that the Tachyon service needs its vendor
backend. Start `com.google.edgetpu_vendor_service-V2-ndk`'s service binary and
`com.google.edgetpu_app_service-V3` alongside, then rerun the delegate and look
for a session in the service's log. Confirm the binary names under
`/vendor/bin/hw/` in the chroot.

Step 3: if the delegate keeps choosing direct, break on
`AServiceManager_getService` (and on `dlopen` of
`libedgetpu_client.google.so`) under gdb with the chroot's `libbinder_ndk.so`
added with `add-symbol-file`, then read the caller's registers to find the
flag.

Step 4: whatever makes the delegate take the Tachyon path, the goal is the VII
setup command carrying the global scratches; watch for `error_code` changing
from 9 and record the result as U34+ with `uname -r`.

Rules: slot B only; announce screen-off before `poweroff`; one TPU power-up per
cold boot; never `rmmod` janeiro and never insmod over a loaded module; keep
the runner's log cap; grep diffs for identifiers; no `Signed-off-by`.

After the gate opens: a real inference, then the 720p 10+ object benchmark
(`tools/bench-object-detection.py`, `out/bench/detect.tflite`,
`out/bench/labelmap.txt`, `out/bench/mosaic720.mp4`; CPU baseline 3.98 ms per
frame at 4 threads, 10 detections per frame).
