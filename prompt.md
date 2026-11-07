# Next: read the two vendor-side deaths now that registration works

Transport is healthy: servicemanager survives, the vendor service and the
tachyon service both register (`registerLazySer …000`, VINTF "Found …"), and the
tachyon service stays up. Two deaths remain inside the vendor binaries:

1. `vendor.google.edgetpu_vendor_service@1.0-service` registers, prints
   `Start cache cleanup.`, then SIGABRTs. Get its abort message: it is started
   with `/system/lib64/libabortshim.so` already, so read the *unfiltered* block
   (`awk "/=== vendor edgetpu service/,/vendor pid:/" /tmp/tpu-tachyon.log`) and
   `grep -a "ABORT-MSG\|Check failed\|cache cleanup" -A3`.
2. `android.hardware.neuralnetworks@service-darwinn-aidl` exits with
   `[Darwinn] Non-ok status from HAL: 2` then SIGTRAP — it comes from its own
   `file.cc` checks, not binder. Grep its block for the file.cc line numbers and
   the lines above the trace.

Likely suspects, in order: the vendor service's cache cleanup needs
`/data/vendor/edgetpu` (does the chroot have it? `mkdir -p` and check the code's
path), and the HAL's status 2 is the vendor service answering a "device ready"
query before it has powered the TPU. `/dev/janeiro` exists (`crw------- root
502,0`) and janeiro logs `janeiro edgetpu initialized` on each boot, so the
kernel side is no longer the question; the userspace handshake is.

When the HAL stays up and publishes `com.google.edgetpu.IEdgeTpuAppService/default`,
run one inference (`RUN_UID=10000 /root/tpu-tachyon-run`), then the 720p
object-detection benchmark (CPU baseline 3.98 ms/frame at 4 threads, 10
detections/frame at 0.4) against every other backend.

Rules unchanged: slot B only, `pkill -x` never `pkill -f`, delete
`$KERNEL_OUT/images` before `push`, `depmod -a $(uname -r)` after, announce
screen-off before `poweroff`, never commit vendor blobs or identifiers, no
`Signed-off-by`.
