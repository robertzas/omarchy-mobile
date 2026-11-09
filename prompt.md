# TPU bring-up: next iteration (2026-11-09, after U156)

Read `device/cheetah/TPU-PLAN.md` U150-U156 and `AGENTS.md` first. Phone:
up, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware at
`/lib/firmware/updates/google/edgetpu-janeiro.fw` (sha `52c1cccd…`).

**Do not run `tpu-a14-hal` or any direct `/dev/edgetpu` create again** (U154:
it blocks in the driver and reset the phone). Use the Tachyon ring harness.

**State.** The port's `drivers/edgetpu` matches Google's stock Android 16
gs201 driver in the KCI open, mailbox attach, PM wakelock and power-up order
(U156); only bring-up logs differ. The port's own comment says stock's boot
leaves the TPU running ("unlike stock where ABL leaves the TPU running"),
while our first access sees GSA state 0 and starts a fresh image with no
setup. The type-1 setup is external to the driver.

1. **Recover the bootloader's setup.** Extract and disassemble the
   bootloader's `hwmgr` and `tpu-image` code (`out/factory/cheetah-abl/…`,
   segments `0x7a8000` and `0x7fac00`; also the cp3a bundle at
   `out/factory/cp3a/`). Find how the ABL/GSA image manager builds the TPU
   setup command — the global scratch list, the cluster bitset, and the
   command type — and whether the ABL leaves the TPU running before Linux.
   Replicate that command as the type-1 setup element from the ring client
   (`TYPES=2,5,5,7 UORDER=MDMK` plus the gdb patch at `core+0x5968c`).
2. **If the setup is a data blob** in the bootloader image or the GSA
   firmware, extract it and feed it as the setup element.
3. **Then the pipeline.** RegisterGraph (7), CreateExecution (9),
   BindInputBuffers (12), BindOutputBuffers (13), Invoke (11) on the SSD
   300x300 int8 model; 60 frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record the date and `uname -r`, replace this prompt,
   and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the commit.
