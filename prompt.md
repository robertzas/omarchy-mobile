# Next: satisfy the Darwinn HAL's driver provider, and name the vendor abort

Two named conditions are all that separate the chain from a published
`com.google.edgetpu.IEdgeTpuAppService/default`:

1. **HAL** (`android.hardware.neuralnetworks@service-darwinn-aidl`):
   `INVALID_ARGUMENT: Incorrect driver provider is used for the current device`
   (`file.cc:397`, status 4), after the socket-bind problem was fixed by creating
   `/data/vendor/hal_neuralnetworks_darwinn` in the chroot. Find what it reads to
   choose a provider: `strings vendor/bin/hw/android.hardware.neuralnetworks@service-darwinn-aidl
   | grep -iE "provider|pcie|platform|ro\.|vendor\."`; the provider name is
   probably a property or an `--provider` argument. Set it and rerun.
2. **Vendor service**: registers, prints `Start cache cleanup.`, then SIGABRT
   with **no** `ABORT-MSG`, so the abort is a libc++ verbose abort or a direct
   `abort()`, not libbase. Run that one binary under gdb inside the chroot with
   `catch signal SIGABRT` and `bt`, or interpose `abort`/`__libcpp_verbose_abort`
   the way `tools/android-abort-msg.c` interposes `android_set_abort_message`.

The chain runner is `/root/tpu-tachyon-run` and everything logs to
`/tmp/tpu-tachyon.log`; kill with `pkill -x` on 15-character names only, and keep
`device/cheetah/tpu-vintf-manifest.xml` installed as
`vendor/etc/vintf/manifest.xml` (package-scoped `<name>`, not the interface).

When the HAL stays up: one inference (`RUN_UID=10000 /root/tpu-tachyon-run`),
then object detection on the 720p 10-object video against CPU (3.98 ms/frame at
4 threads), GPU and the other backends.
