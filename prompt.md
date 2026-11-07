# Next: catch the delegate's SIGABRT and name the stack smash

State: the TPU powers up, loads firmware, opens the device and finalizes its
mailbox; servicemanager and the Tachyon service run. With the
`servicemanager.ready` property answered as `true`, the delegate's 500 MB
busy loop is gone and it now aborts in about 0.1 s with
`stack corruption detected (-fstack-protector)` right after
`OPEN_DEVICE ret 0` (delegate rc 134, U31). It also logs a failed binder
`isDeclared` for `android.frameworks.stats.IStats/default`
(`FAILED_TRANSACTION`). No VII element is sent.

Do not re-derive:

- The stack: `tools/tpu-tachyon-run` (binderfs, servicemanager from the stock
  system image, Tachyon service, three shims). `BT=1` starts the delegate in
  the background and attaches gdb; that is how `wchan 0` was read.
- The property shim `tools/android-props-stub.c` answers `servicemanager.ready`
  with `true`, `ro.build.version.sdk` with `34`, everything else `1`, and
  echoes the requested name from `find` to `read_callback`.
- gdb on the phone can follow the chroot exec when run as
  `gdb -batch -ex "set sysroot $R" -ex "set follow-exec-mode same"
  -ex "set environment LD_LIBRARY_PATH=..." -ex "file /usr/bin/chroot"
  -ex "set args $R /system/bin/linker64 <program>" -ex run -ex "bt 20"`.
  That worked for servicemanager; the delegate is unstripped, so its frames
  should resolve.

Step 1 (phone, cold boot): stop at the abort.
- Change the runner's delegate line to run under the gdb command above with
  the delegate's `LD_PRELOAD` and `/vendor/bin/edgetpu-run /vendor/etc/model.tflite`.
- Cold boot, run, and save the backtrace: the frame that calls
  `__stack_chk_fail` names the function whose local buffer was smashed.

Step 2: fix what the frame names.
- If the frame is in `libbinder`'s `isDeclared` path, the fake `prop_info`
  pointer is the suspect: return a pointer to a real-shaped 96-byte struct and
  make `read_callback` fill name and value, or drop the C++ property shim and
  give libbinder the real (empty) property area plus a `wait` that succeeds.
- If the frame is in the delegate's own stats/perfetto path, disable that path
  (env or `LD_PRELOAD` stub) so it never queries `IStats`.
- If the frame is in the shim's `__system_property_get`, lower the copy bound
  and return lengths like Android does.

Step 3: after the abort is gone, the delegate either reaches the Tachyon
service (then watch for a session/setup) or goes direct and answers
`error_code=9`; either way record it in `device/cheetah/TPU-PLAN.md` as U32+
with `uname -r`.

Rules: slot B only; announce screen-off before `poweroff`; one TPU power-up
per cold boot (a failed attempt needs a cold boot before the next); never
`rmmod` janeiro and never insmod over a loaded module; the runner caps its log
(`ulimit -f 51200`) because a binder loop once wrote 500 MB in seconds; grep
diffs for identifiers.

After the gate opens: a real inference, CPU comparison, then the 720p 10+
object benchmark (`tools/bench-object-detection.py`,
`out/bench/detect.tflite`, `out/bench/labelmap.txt`,
`out/bench/mosaic720.mp4`; CPU baseline 3.98 ms/frame at 4 threads,
10 detections/frame).
