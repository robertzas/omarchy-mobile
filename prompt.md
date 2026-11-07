# Next: declare the TPU interfaces in a VINTF manifest, then light the chain

The binder transaction now carries `u:object_r:system:s0`, servicemanager
survives registration, and the vendor service's `registerLazyService` returns
`0xfffffffd` (`-3`) because servicemanager cannot find
`com.google.edgetpu.IEdgeTpuVendorService/default` in a VINTF manifest
(`NULL VINTF MANIFEST!: device` / `framework`). Make that manifest exist:

1. `bin/omamobile push` the build from `out-tpu` (delete `$KERNEL_OUT/images`
   first - `push` reuses stale images otherwise), `reboot-to omamobile`, then
   `depmod -a $(uname -r)` and confirm `uname -r` names the new release.
2. Run the chain in the right order and kill leftovers first **by exact name**
   (`pkill -x com.google.edge`, `pkill -x android.hardwa`,
   `pkill -x vendor.google.e`, `pkill -x vndservicemanag`); never `pkill -f`
   with a pattern that matches the ssh command line itself.
3. Watch for: servicemanager surviving the vendor service's `addService`
   (`registerLazyService took N ms` with no `Check failed: status == STATUS_OK`),
   the Darwinn HAL publishing `IEdgeTpuAppService/default`, and the delegate
   opening `/dev/janeiro`.
4. If the CHECK persists, it is time to patch that CHECK out of
   `system/bin/servicemanager` (private chroot, never committed) rather than
   keep guessing at the transaction shape: the message string and its
   `LOG(FATAL)` call site are both in the binary, and the abort shim already
   proves which path runs.

Then: one real int8 inference (`RUN_UID=10000 /root/tpu-tachyon-run`), and once
that works, the 720p object-detection benchmark against CPU (baseline 3.98
ms/frame at 4 threads, 10 detections/frame at 0.4) and the other backends.
