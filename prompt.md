# Next: get servicemanager past its access check, then register the TPU chain

State (U37): the kernel-side blocker is gone (`secctx` failures 14 -> 0), the TPU
device tree nodes are in the images, `/dev/janeiro` exists, and
`com.google.edgetpu.tachyon-service` stays alive. Every remaining failure traces
to one process: **servicemanager aborts**, and its CHECK is now readable because
`tools/android-abort-msg.c` interposes `android_set_abort_message()`:

    Check failed: nullptr == IPCThreadState::self()->getServingStackPointer() ...
      Did not get context from PID N. We should always get contexts from other processes.

That is servicemanager's own startup path calling its access check with no
serving transaction (`getCallingPid()` is 0). The SELinux shim now genuinely
binds — `tools/android-selinux-allow.map` gives its symbols the `LIBSELINUX_R`
version that the vendor libselinux exports, which was why the unversioned
preload never took effect — so the next step is one of:

1. Find the invocation that skips access checks: `strings system/bin/servicemanager
   | grep -iE "usage|no-selinux|access|check"` and try the flag it names
   (`servicemanager -h` inside the chroot). Stock runs it bare, but stock also
   has selinuxfs.
2. Patch that CHECK in the chroot's `system/bin/servicemanager` (private chroot,
   never committed): the abort comes from `Access`/`checkServiceAccess`; changing
   the fatal to a return of "allow" is the same shape as the two byte patches
   already documented (libbinder 0x505bc / 0x4ffac, libselinux `selinux_status_open`).
3. Look for the vendor image's own `vndservicemanager`; it may not check access
   at all, and the chain is vendor-only anyway.

Once servicemanager survives `addService`, the vendor service should print
`registerLazyService took N ms` without the `Check failed: status == STATUS_OK`,
the Darwinn HAL should publish `IEdgeTpuAppService/default`, and the delegate
(`RUN_UID=10000`) should get a real device fd. Then a real inference, then the
720p benchmark (`tools/bench-object-detection.py`; CPU baseline 3.98 ms/frame at
4 threads).

Build/run rules: delete `$KERNEL_OUT/images` after a kernel build or `push` ships
stale images; `bin/omamobile initramfs` needs a writable `$WORK`; run
`depmod -a $(uname -r)` on the phone after a module push. Slot B only, one TPU
power-up per boot, never `rmmod` janeiro, announce screen-off before `poweroff`,
grep diffs for identifiers, no `Signed-off-by`.
