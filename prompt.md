# TPU bring-up: next iteration (2026-11-09, after U164)

Read `device/cheetah/TPU-PLAN.md` U150-U164 and `AGENTS.md` first. Phone:
up, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware
sha `52c1cccd…`, `janeiro` loaded, `/dev/janeiro` present. Do not run
`tpu-a14-hal` or any direct `/dev/edgetpu` create (U154).

**State.** The ring path reaches RegisterGraph: the type-1 setup answers
96 bytes, the graph imports as handle 1/fd 1 and the scratch as handle
2/fd 2 (64 bytes each), and the `core+0x5968c` gdb patch applies. But the
core sends **its own** legacy setup first (`Sending firmware-setup VII
command. type: 1 seq: 0`), the firmware rejects it, VD 1 goes `IN_ERROR`
and RegisterGraph answers a 72-byte `Virtual device failure`. The client's
correct type-1 table never reaches the VD setup.

1. **Use the A17 HAL's own setup.** Start the chain with the HAL:
   `HAL_ONLY=1 sh -s < tools/tpu-tachyon-run` (the runner starts the HAL
   at its line 277 and skips the delegate; check the env name in the
   runner first). The chroot has the stock NN service
   (`vendor/bin/hw/android.hardware.neuralnetworks@service-darwinn-aidl`)
   but no `libneuralnetworks.so`, so call the service's
   `IDevice::prepareModel` through `libbinder_ndk` with the SSD 300x300
   int8 model, or call the HAL's C++ `prepareModel` directly. The HAL's
   setup should be the A17 type-1 shape (U162); watch its log for
   `Sending firmware-setup VII command`.
2. **If the HAL's setup is accepted**, use the HAL's own execution path:
   prepareModel, allocate buffers, invoke on 60 frames of
   `out/bench/mosaic12.mp4`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record the date and `uname -r`, replace this prompt,
   and commit.
3. **If the HAL cannot be driven yet**, gdb the core's setup send at
   `tpu_actor_virtual_device.cc:604`: replace its payload with the
   client's `build_setup` table (U163) or skip it and mark the VD
   initialized, then rerun the `TYPES=1,2,5,5,7` sequence and RegisterGraph.

Do not add `Signed-off-by`. Scan the diff for identifiers before the commit.
