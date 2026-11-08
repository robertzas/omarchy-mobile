# Next: make the Tachyon session reach STARTED before its first command

State at 2026-11-08, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`.
Detail: `device/cheetah/TPU-PLAN.md` U61-U64.

## Phone and host access

- The phone is the Pixel on `enp0s20f0u4`, reached as `172.16.42.3` ->
  `172.16.42.1`. The OnePlus 8T (`enp0s20f0u5`) re-enumerates and
  NetworkManager re-manages it, taking `172.16.42.1` with a /24 route; pin the
  Pixel before every batch:
  `nmcli device set enp0s20f0u5 managed no; ip addr flush dev enp0s20f0u5;
   DEVICE=cheetah tools/phone-usb`.
- **Never put the runner's `pkill -f` patterns in an SSH command line**
  (`vendor.google.edgetpu_app_service`, a `grep -rl -E TachyonCore` string):
  the remote shell's own cmdline matches and the runner kills the session.
  That cost two runs with no output.
- SSH: `ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes
  root@172.16.42.1`. The key is unencrypted (comment `omamobile`).
- The TPU is powered once this boot (`tpu-hold`, pid 5147). Restarting the
  chain reuses it; a second power-up wedges the PSM.

## What works

- `tools/tpu-tachyon-run` starts the Power HAL, the vendor service, the
  Tachyon service and the app service, then (unless `NO_DELEGATE=1`) the
  delegate. `CORES=1` leaves a core for a crashing service; it sets
  `core_pattern` to `/core.%e.%p` and does not restore it (the old value is
  in `/tmp/tpu-core-pattern.old`).
- The client gets `create: OK` -> `createSession: OK` -> command and response
  queues (fds 11,12 and 14,15) -> `sendCommand: OK`.
- `receiveResponse: exception -8 service 8` is only "the response FMQ holds
  fewer than 128 bytes": the lib builds that status itself
  (`ReceiveResponseMessage` at `0xf2c0`). A 100 × 100 ms poll never changes
  it.
- The Tachyon service does **not** crash. It exits when its last client
  leaves (`AidlLazyServiceRegistrar`), which is normal.

## Blocker

The session never reaches STARTED or AUTHORIZED, so the core holds the
command: `ClientSessionFmqCommandReady received event but it is not in
STARTED or AUTHORIZED state. Hold.` The core's threads are `MainTpuActor`
in `do_epoll_wait` plus three `*PriWorker` threads in `futex_wait`; the
service holds no `/dev/janeiro` fd (the app service owns the device and the
group). The firmware setup the TPU wants is pushed by the core only from a
started session, and it is the message that carries the global scratches.

## Order of work

1. Disassemble, on the laptop, in
   `out/factory/tegu-cp21/vendor-libs/libedgetpu_tachyon.google.patched.so`:
   `TachyonComputeSession_sendFileDescriptors`,
   `TachyonComputeSession_beginCommandQueueWrite` /
   `commitCommandQueueWrite`, and the config setters `setSessionType` /
   `setClientVersion` (find the enum values in the V6 ndk lib or the AIDL).
   In `libtachyon_core.patched.so`, find `ClientSessionStart` (xref the
   string) and what sets the state to STARTED.
2. Give the probe the config the stock client uses: session type and client
   version first, then assign fds with `sendFileDescriptors` before
   `sendCommand`. Watch the client for `get_fds` lines (the callback is
   never called today) and for a first response.
3. When a response arrives, watch for the firmware setup: the delegate run
   should stop answering `Sync VII command failed: error_code=9`, and dmesg
   should show the VII element the driver logs.
4. Then one int8 inference on `detect_edgetpu.tflite` against CPU TFLite,
   recording `uname -r` and latency in TPU-PLAN.md.
5. Then the 720p 10+-object benchmark against XNNPACK CPU and Mesa/panthor
   GPU (`tools/bench-object-detection.py`).

## Hard rules

- Slot B only; one TPU power-up per cold boot; never load the A14 firmware.
- No vendor blobs or identifiers in the repo; never weaken the storage,
  IOMMU or S2MPU guards. Commit only our own files with a temporary index;
  area-prefixed messages; grep the diff for identifiers first.
- Announce anything that affects the screen or the feel of the phone.
