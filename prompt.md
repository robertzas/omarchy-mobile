# TPU bring-up: next iteration (2026-11-09, after U162)

Read `device/cheetah/TPU-PLAN.md` U150-U162 and `AGENTS.md` first. Phone:
up, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware at
`/lib/firmware/updates/google/edgetpu-janeiro.fw` (sha `52c1cccd…`);
`janeiro` not loaded and `/dev/edgetpu` absent.

**Do not run `tpu-a14-hal` or any direct `/dev/edgetpu` create** (U154: it
blocks in the driver and reset the phone). Use the Tachyon ring harness.

**State.** The A17 core's `TachyonCore_Start` is a stub and its
`CreateClientSession` is not implemented (U162), so the core never sends a
setup. The A17 HAL builds and sends the type-1 setup (`0x14d9a80` /
`0x14d9d40`; builder `0x14de9cc`, serializer `0x14e0380`), and its type-1
table has field ids 0, 1, 2, 3, 8, 9, 10, 11, 12: fields 2 and 3 are the
two vectors (16-byte and 64-byte elements), field 10 a 4-byte value, 8/9
bytes and 11/12 16-bit. The ring client's `TYPES=1` path currently sends an
empty union table. The chroot has the stock NN service
(`vendor/bin/hw/android.hardware.neuralnetworks@service-darwinn-aidl`) but
no `libneuralnetworks.so` runtime, so the ring client is the short path.

1. **Extend the ring client's type-1 path** (`tools/tpu-tachyon-client.c`,
   `build_cmd` when `type == 1 && getenv("SETUP")`) with a table carrying
   the setup fields from U162: a 16-byte scratch vector at field 2 (start
   with the U159 TPU ranges `0x10000000`+16 MiB, `0x11000000`+64 KiB,
   `0x11010000`+64 KiB), an empty 64-byte vector at field 3, field 10 and
   the scalar fields as zero, and the union type byte 1. Print the
   firmware's answer, and permute the vector fields only if the error
   names the missing scratch/resource.
2. **Test once per cold boot** with `tools/tpu-tachyon-run` (it loads
   `janeiro` once and creates `/dev/edgetpu`), `TYPES=1 SETUP=1` first,
   then capture `/tmp/tpu-tachyon.log` and dmesg. Success is the firmware
   no longer answering `Setup is not done yet` and the setup returning its
   own result; a clean error is the next field to change, not a failure.
3. **When the setup is accepted**, send the full `TYPES=2,5,5,7
   UORDER=MDMK` sequence plus the gdb patch at `core+0x5968c`, then
   RegisterGraph (7), CreateExecution (9), BindInputBuffers (12),
   BindOutputBuffers (13), Invoke (11) on the SSD 300x300 int8 model; 60
   frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record the date and `uname -r`, replace this prompt,
   and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the commit.
