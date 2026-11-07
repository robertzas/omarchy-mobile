# Next: get one Edge TPU service to register on /dev/vndbinder

State (U34): the client side works. `RUN_UID=10000 /root/tpu-tachyon-run` makes
the delegate take the Tachyon path and ask for
`com.google.edgetpu.IEdgeTpuAppService/default`; it fails only because no
service is registered. The three vendor services abort on registration, and
`tools/android-lazysvc-shim.c` already redirects their
`AServiceManager_registerLazyService*` to `AServiceManager_addService`
(marker `LAZYSVC-SHIM` proves the interposition). The open question is why
`addService` itself comes back non-OK.

Step 1: name the status. The shim now calls `AStatus_getExceptionCode` and
prints `LAZYSVC-SHIM exception 0x…`; run the chain and read that line. If it is
absent, the shim died before printing (the previous raw-field read faulted, so
check `LAZYSVC-SHIM exception null` too). A missing marker entirely means the
preload did not load — check the block for a linker error.

Step 2: if the code is EX_UNSUPPORTED_OPERATION (throws `0x3`/`0x4` family),
the servicemanager in the chroot is not the one stock runs for the vendor
domain. Look for `vndservicemanager` in the phone's own `/vendor` (on the
device, not the extraction: `ls /vendor/bin | grep -i vnd`), pull it with the
same extraction tooling, and run it instead of
`servicemanager /dev/vndbinder`. Stock starts exactly that one for the vendor
context, and the Edge TPU chain is vendor-only.

Step 3: if `addService` reports OK but the registrar still aborts, the failure
is the second transaction (`registerClientCallback`), and the shim needs that
one too: interpose `AServiceManager_registerClientCallback`? Check
`llvm-nm -D libbinder_ndk.so | grep -i register` for the exact name.

Step 4: with a registered service, the expected next output from the delegate
is a real fd and `OPEN_DEVICE ret 0` through the service instead of the direct
ioctl path, then the VII setup no longer comes from us (U27). Record whatever
happens as U35+ with `uname -r`.

Rules unchanged: slot B only; announce screen-off before `poweroff`; one TPU
power-up per cold boot; never `rmmod` janeiro; grep diffs for identifiers; no
`Signed-off-by`. Keep `RUN_UID=10000` for anything that should use the service
path — root can never reach it (`0x1bf4f4`).

After the gate opens: a real inference, then the 720p 10+ object benchmark
(`tools/bench-object-detection.py`, `out/bench/{detect.tflite,labelmap.txt,mosaic720.mp4}`;
CPU baseline 3.98 ms/frame at 4 threads, 10 detections/frame).
