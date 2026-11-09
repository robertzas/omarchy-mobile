# TPU bring-up: next iteration (2026-11-09, after U150)

Read `device/cheetah/TPU-PLAN.md` U139-U150 and `AGENTS.md` first. Phone:
up, Tachyon service dead; the boot's one TPU power-up is spent, so reboot
before a client run (`reboot-to`, slot B, under the grant), then
`TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** RegisterGraph now passes the core's dependency check:
`UORDER=MDMK` (union fields as handles 1,1,1,2) plus a gdb patch at
`core+0x5968c` (`set {unsigned long}($x21+8)=2; set $x8=$x21+8`) advances
the command to `PENDING_FIRMWARE_SETUP`. The core wakes the firmware and
sends `Sending firmware-setup VII command. type: 1 seq: 0`, then the setup
fails: the element is `code 0`, payload fields 48/5/6 (the same legacy
message the HAL sends, U75), and the firmware answers `Setup is not done
yet received a command of type 0.` The core shuts the firmware down; the
client gets `Virtual device failure`.

1. **Patch the setup element's code/type.** Find where the core writes the
   element's `code` (0) for the setup submit (the driver's dump shows it;
   the core's setup builder is at `0x7f9c4`, the submit handler around
   `0x750a0`). Patch it to 1, or interpose the element in the mapped queue
   before the doorbell. Re-run and read `dmesg`'s `vii-elem` /
   `vii-payload` and the firmware's answer.
2. **If the firmware names the global scratches**, build the setup payload
   with the graph descriptor's scratch (the model's slot 3) and the
   cluster bitset, then re-run. If it accepts, the firmware setup is done.
3. **Then the pipeline.** CreateExecution (9), BindInputBuffers (12),
   BindOutputBuffers (13), Invoke (11) on the SSD 300x300 int8 model;
   run 60 frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record the result with the date and `uname -r`,
   replace this prompt, and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the
commit.
