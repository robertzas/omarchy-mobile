# Next: keep servicemanager alive, then let the vendor service register

State (U36): the binder transaction failure is fixed in the kernel — a node that
asks for a security context now gets its transaction even when no LSM can
translate a secid (`security_secid_to_secctx()` returns `-EOPNOTSUPP`), and dmesg
counts 0 "failed to get security context" where it used to count 14. With that,
`com.google.edgetpu.tachyon-service` stays alive, `/dev/janeiro` exists, and
janeiro reports `janeiro edgetpu initialized. Build: 052da7097-dirty`.

Still failing:

- `servicemanager` aborts: `Fatal signal 6 (SIGABRT) ... tid (servicemanager)`.
  Read its own stderr (`/tmp/tpu-tachyon.log`, the `=== servicemanager` block) for
  the CHECK. It runs against `/dev/vndbinder` and links libbinder (C++), so an
  empty security context on a client node is the first suspect: the chroot's
  libbinder was byte-patched (0x505bc / 0x4ffac) to drop
  `FLAT_BINDER_FLAG_TXN_SECURITY_CTX`, and the kernel fix makes that patch
  unnecessary. The originals are `libbinder.so.orig` in both `vendor/lib64` and
  `system/lib64`; restoring them is the first experiment, and it lets
  servicemanager see the same node flags stock does.
- `vendor.google.edgetpu_vendor_service@1.0-service` dies with
  `SIGSEGV ... fault addr 0xffffff7f`. That is `-129` (`EX_TRANSACTION_FAILED`)
  read as an `AStatus*`: `tools/android-lazysvc-shim.c` must not call
  `AStatus_getExceptionCode()` on a value that is not a pointer. Print the
  pointer/return value instead, and treat a small negative value as the status
  code it is.
- janeiro's probe logs a backtrace through `__setup_irq` / `edgetpu_register_irq`
  (dmesg ~27 s). The device appears anyway, so this is a warning to identify
  later, not the current blocker.

After the vendor service stays up, the chain is: it owns `/dev/edgetpu`, tachyon
fronts it, and `android.hardware.neuralnetworks@service-darwinn-aidl` publishes
`IEdgeTpuAppService/default` for the delegate (`RUN_UID=10000`). Then a real
inference, then the 720p benchmark (`tools/bench-object-detection.py`; CPU
baseline 3.98 ms/frame at 4 threads).

Build/run rules learned: delete `$KERNEL_OUT/images` after a kernel build or
`push` ships the old images; `bin/omamobile initramfs` needs a writable `$WORK`;
run `depmod -a $(uname -r)` on the phone after a module push. Slot B only, one
TPU power-up per boot, never `rmmod` janeiro, announce screen-off before
`poweroff`, grep diffs for identifiers, no `Signed-off-by`.
