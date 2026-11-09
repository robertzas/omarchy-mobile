# TPU bring-up: next iteration (2026-11-09, after U155)

Read `device/cheetah/TPU-PLAN.md` U150-U155 and `AGENTS.md` first. Phone:
up, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware at
`/lib/firmware/updates/google/edgetpu-janeiro.fw` (sha `52c1cccd…`).

**Do not run `tpu-a14-hal` or any direct `/dev/edgetpu` create again** (U154:
the A14 HAL's CreateDevice blocks and reset the phone). Use the Tachyon ring
harness only.

**State.** Both cheetah firmware generations (A14 `1.0 539775951`, A17 `1.0
895567958`) refuse every userspace producer's legacy type-0 setup. The A14
vendor image has no Tachyon core, so the A14/A17 HAL direct path is the
stock path; the same pair worked on stock A14. The GSA power-up works
(`cmd 50` loads, `TPU cmd 1` starts, state 2).

1. **Diff the mainline driver against the stock gs201 driver.** The same A14
   HAL + A14 firmware succeeded on stock, so the difference is in
   `drivers/edgetpu`: the VII mailbox init and attach, the KCI
   open/attach sequence, the GSA power-up commands (`cmd 150/50/151`, `TPU
   cmd 1`), and the setup element. Take Google's GPL gs201 kernel source as
   the reference and find the missing setup step.
2. **If the driver matches,** recover the type-1 setup from the bootloader's
   hwmgr/tpu-image code (`out/factory/cheetah-abl/…`, segments `0x7a8000`
   and `0x7fac00`) and submit it through the ring client.
3. **Then the pipeline.** RegisterGraph (7), CreateExecution (9),
   BindInputBuffers (12), BindOutputBuffers (13), Invoke (11) on the SSD
   300x300 int8 model; 60 frames of `out/bench/mosaic12.mp4` through
   `tools/bench-object-detection.py`; fill the TPU row in U118 (CPU 4t
   4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3 fps, both 10.0
   detections/frame), record the date and `uname -r`, replace this prompt,
   and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the commit.
