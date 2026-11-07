# Next: name the function whose stack was smashed

State: the TPU powers up, loads firmware, opens the device and finalizes its
mailbox. servicemanager and the Tachyon service run. The delegate passes the
`servicemanager.ready` wait (answer `true`), then aborts in about 0.1 s with
`stack corruption detected (-fstack-protector)` right after `OPEN_DEVICE ret 0`
(delegate rc 134, U31). It also logs a failed binder `isDeclared` for
`android.frameworks.stats.IStats/default` (`FAILED_TRANSACTION`). No VII element
is sent.

gdb follows the chroot exec but cannot load bionic symbols, so its SIGABRT
backtrace is only `#0 libc` and a garbage frame. The next tool is a shim.

Do not re-derive:

- The stack: `tools/tpu-tachyon-run` (binderfs, servicemanager from the stock
  system image, Tachyon service, three shims). `GDB=1` runs the delegate under
  gdb; `BT=1` starts it and attaches after 6 s.
- `tools/android-props-stub.c` answers `servicemanager.ready` with `true`,
  `ro.build.version.sdk` with `34`, everything else `1`, and echoes the
  requested name from `find` to `read_callback`.
- The delegate is unstripped, so `llvm-addr2line -e
  out/vendor-chroot-edgetpu/root/vendor/bin/edgetpu-run <offset>` works once
  the offset is known.

Step 1 (laptop): add `tools/android-stackchk.c`, a freestanding `LD_PRELOAD`
shim that overrides `__stack_chk_fail` and `__stack_chk_fail_local`:
- write `"STACKCHK lr=0x%lx\n"` with `__builtin_return_address(0)` to fd 2,
  then `_exit(134)`;
- it must not call libc; use raw `svc` writes like the other shims.
Build it for `aarch64-linux-android30`, deploy with the runner.

Step 2 (phone, cold boot): run the delegate with the stackchk shim in
`LD_PRELOAD`, read `/proc/<pid>/maps` while it is alive (or log the base from a
`dl_iterate_phdr` helper) so the address can be turned into a file offset.
Then `llvm-addr2line` (or `llvm-objdump -d` around the offset) names the
function and its caller.

Step 3: fix what it names.
- If the frame is in libbinder's `isDeclared` fallback, the fake `prop_info`
  pointer is the suspect: return a real-shaped 96-byte struct and fill name
  and value, or give libbinder the real empty property area plus a `wait`
  that succeeds.
- If it is the delegate's stats/perfetto path, lossen that path so it never
  queries `IStats`.
- If it is in the shim's `__system_property_get`, bound the copy to the
  caller's buffer like Android does.

Step 4: after the abort is gone the delegate either reaches the Tachyon service
(watch for a session and the setup command) or goes direct and answers
`error_code=9`; record it in `device/cheetah/TPU-PLAN.md` as U32+ with
`uname -r`.

Rules: slot B only; announce screen-off before `poweroff`; one TPU power-up per
cold boot; never `rmmod` janeiro and never insmod over a loaded module; the
runner caps its log (`ulimit -f 51200`) because a binder loop once wrote 500 MB;
grep diffs for identifiers.

After the gate opens: a real inference, CPU comparison, then the 720p 10+
object benchmark (`tools/bench-object-detection.py`,
`out/bench/detect.tflite`, `out/bench/labelmap.txt`,
`out/bench/mosaic720.mp4`; CPU baseline 3.98 ms/frame at 4 threads,
10 detections/frame).
