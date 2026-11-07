# Next: backtrace the delegate hang, then call Tachyon directly

State: the TPU powers up, loads firmware, opens the device and finalizes its
mailbox (`OPEN_DEVICE ret 0`, `kci_finalized ret 0`). servicemanager and the
vendor Tachyon service both run (`tools/tpu-tachyon-run`), with three shims
preloaded. The delegate still hangs: `timeout` 124 after `model bytes: 4749998`
and its mmaps, with no VII element sent and no error. A property stub that
answers every `__system_property_get` with `1` did not change that, so the spin
is not a property wait (U30).

Do not re-derive:

- binderfs works (`mount -t binder binder /dev/binderfs`, `binder` 507:1);
  servicemanager is from `out/cp2a-system.img`; shims are
  `tools/android-log-stderr.c`, `tools/android-selinux-allow.c`,
  `tools/android-props-stub.c`.
- `SessionConfig` is 0x28 bytes: bool at 0, int32 at 4, 8, 0xc,
  `shared_ptr<IGetFdsResponseCallback>` at 0x10, int32 at 0x20 and 0x24.
  `TachyonComputeService_createSession(service, &config, &ret)` fills a
  `CreateSessionReturn`; `TachyonComputeSession_setupCommandQueue(session,
  &fd, &size)` yields the queue fd.
- Run `TachyonComputeService_create` is a binder client
  (`AServiceManager_isDeclared` + `waitForService`), so the service must be up.
- Firmware gate: one VII setup command per firmware boot carrying global
  scratches; the delegate never sends it.

Step 1 (phone, no reboot needed while it is up): find the exact spin.
- Start the stack with `tools/tpu-tachyon-run` but replace the delegate line
  with a background `chroot $R /vendor/bin/edgetpu-run ...` and, after 5 s,
  `gdb -p <pid> -batch -ex "thread apply all bt 15"` (the delegate is
  unstripped; capture the frame in `CreateVirtualDevice`).
- Record the function and call it names in `device/cheetah/TPU-PLAN.md` U31.

Step 2: act on that frame.
- If it waits on a file descriptor, read `/proc/<pid>/fd` and the fd's peer;
  the Tachyon service's queue fds and the driver's eventfds are the candidates.
- If it waits on a mutex/condition in `libedgetpu_util`, the direct client in
  Step 3 is the way around it.

Step 3: `tools/tachyon-client.c` (aarch64 bionic, no libc++):
- `TachyonComputeService_create(&service, name)` against the running service;
- build a zeroed 0x28-byte `SessionConfig`, set the bool at 0 to 1 (privileged)
  and any int32 the AIDL `createSession` requires;
- `TachyonComputeService_createSession(service, &config, &ret)`;
- `TachyonComputeSession_setupCommandQueue` and
  `..._setupResponseQueue`, then `..._sendCommand` with the model's first
  command, and watch dmesg for a VII submission that does not answer 9.

Rules: slot B only; announce screen-off before `poweroff`; one TPU power-up
per cold boot (a failed attempt needs a cold boot before the next); never
`rmmod` janeiro and never insmod over a loaded module; record results in
`device/cheetah/TPU-PLAN.md` as U31+ with `uname -r`; grep diffs for
identifiers.

After the gate opens: a real inference, CPU comparison, then the 720p 10+
object benchmark (`tools/bench-object-detection.py`,
`out/bench/detect.tflite`, `out/bench/labelmap.txt`,
`out/bench/mosaic720.mp4`; CPU baseline 3.98 ms/frame at 4 threads,
10 detections/frame).
