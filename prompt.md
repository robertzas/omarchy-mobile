# Next: give binder a security-context answer, then register the TPU chain

State (U35): the client side already works — `RUN_UID=10000 /root/tpu-tachyon-run`
makes the delegate ask for `com.google.edgetpu.IEdgeTpuAppService/default` — and
the blocker is now named exactly. The kernel's binder driver fails every
transaction to a node published by Android's libbinder:

    binder: N:N failed to get security context
    binder: N:N transaction call to ...:0 failed .../29201/-95 ... line 3376

because `FLAT_BINDER_FLAG_TXN_SECURITY_CTX` needs `security_secid_to_secctx()`,
and no LSM on this kernel implements it (SELinux is not built in; the LSM list is
`capability,landlock`). That -95 is the ENOTSUP the services saw through
`registerLazyService` as well.

Two routes, in order of cost:

1. **Find the last flag site in libbinder** (cheap, no reboot). `Parcel`'s
   `isRequestingSid()` branch is already neutralised at 0x505bc
   (`/system/lib64/libbinder.so`) and 0x4ffac (`/vendor/lib64/libbinder.so`,
   the copy servicemanager maps); the count did not move, so look at
   `ProcessState::becomeContextManager` (0x9cb50) and at `BpBinder`/`BBinder`
   constructors: `grep -nE "mov\tw[0-9]+, #0x1[0-9a-f]{3}"` around those
   addresses, and remember the flag can also be OR'd as `0x1100` or `0x117f`.
   A run's dmesg is the oracle: `dmesg | grep -c "failed to get security context"`.

2. **Build SELinux into the kernel** (definitive, one build + push + reboot).
   Add to `kernel/configs/omamobile.config`:
   `CONFIG_SECURITY_SELINUX=y` and
   `CONFIG_LSM="landlock,lockdown,yama,integrity,selinux,bpf"`.
   With no policy loaded, `security_sid_to_context_core()` still answers the
   initial SIDs from `initial_sid_to_string`, so the binder driver gets "kernel"
   and the transactions proceed; nothing enforces labels in this chroot. Build in
   `~/omamobile-kernel/wt-tpu` with `out-tpu`, then `push` + `reboot-to` and run
   `tools/phone-smoke` first, because an LSM in the list touches every boot path.
   If the phone does not come back, the initramfs USB watchdog is the safety net.

After the count reaches zero, expect `vendor pid`, `tachyon pid` and `hal pid` to
stay alive in `/tmp/tpu-tachyon.log` and the delegate to get a real fd from the
service instead of "Failed to open device fd". Then a real inference, then the
720p benchmark (`tools/bench-object-detection.py`; CPU baseline 3.98 ms/frame at
4 threads, 10 detections/frame).

Rules unchanged: slot B only, one TPU power-up per boot, announce screen-off
before `poweroff`, never `rmmod` janeiro, grep diffs for identifiers, no
`Signed-off-by`.
