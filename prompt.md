# Next: get the VII setup from the Tachyon service, not the direct path

State (U32, `uname -r` 7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty): the
TPU powers up, loads firmware, opens the device, finalizes its mailbox.
servicemanager and `com.google.edgetpu.tachyon-service` run, and the delegate
no longer aborts — with the shim installed as the chroot's `liblog.so` it runs
to its own end and returns rc 1 with
`INTERNAL: Sync VII command failed: error_code=9`.

So the stack smash was stock liblog's hidden-alias path (U32), not the
delegate. What remains is U27's wall: the firmware's VII gate needs the setup
command carrying the global scratches, and stock Android sends the host half
from the Tachyon service. The delegate is still choosing its direct path.

Do not re-derive:

- `tools/tpu-tachyon-run` sets up binderfs, mounts proc/sys/dev into the
  chroot, starts servicemanager, starts the Tachyon service, then runs
  `edgetpu-run`. Modes: `GDB=1`, `BT=1`.
- `tools/android-props-stub.c` answers `servicemanager.ready` with `true`,
  sdk `34`, else `1`. `tools/android-log-stderr.c` is now a full liblog
  replacement (21 symbols) and is installed as the chroot's `liblog.so`; the
  stock one has no backup, so re-extract the chroot before needing it.
- The delegate's ioctl trail: `0x4014ed06`, `0x4008ed05`, `0xed08`, heap
  alloc, `0xc028ed11`, `0xed1a`, `0x8010ed1b`, then the sync that returns 9.
- `libedgetpu_util.so` logs from `0x13c2bc`; `TachyonComputeService_create`,
  `createSession(service, &config, &ret)` and
  `setupCommandQueue(session, &fd, &size)` are the client-side entry points.

Step 1 (read-only, laptop): find how the delegate decides between the Tachyon
service and the direct firmware path. Disassemble
`libedgetpu_util.so` around the session-create path and look for a property
read, an environment variable, or a service-presence check that gates it.
`llvm-objdump -d` plus `llvm-objdump -s -j .rodata` for the nearby strings.
Candidate knobs to test, one per boot: `ro.build.type`, `ro.debuggable`,
`persist.edgetpu.*`, `EDGETPU_*` environment variables.

Step 2 (phone, cold boot): if the gate is a property, answer it from
`tools/android-props-stub.c` and re-run `tools/tpu-tachyon-run`; if it is an
environment variable, pass it in the runner's delegate invocation.

Step 3: watch for a session on the Tachyon side (`tachyon` log lines, a new
`createSession` result) and for the VII sync changing from 9 to something
else. Record as U33+ with `uname -r`.

Rules: slot B only; announce screen-off before `poweroff`; one TPU power-up
per cold boot; never `rmmod` janeiro and never insmod over a loaded module; the
runner caps its log at 50 MB; grep diffs for identifiers; no `Signed-off-by`.

After the gate opens: a real inference, then the 720p 10+ object benchmark
(`tools/bench-object-detection.py`, `out/bench/detect.tflite`,
`out/bench/labelmap.txt`, `out/bench/mosaic720.mp4`; CPU baseline 3.98 ms per
frame at 4 threads, 10 detections per frame).
