# TPU bring-up: next iteration (2026-11-09, after U149)

Read `device/cheetah/TPU-PLAN.md` U126-U149 and `AGENTS.md` first. Phone:
up, chain up, Tachyon service alive; the boot's one TPU power-up is spent,
so reboot before a client run (`reboot-to`, slot B, under the grant), then
`TPU_VLOG=5 NO_DELEGATE=1 /root/tpu-tachyon-run`.

**State.** Type 7 RegisterGraph parses the union table's fields as memory
handles: `UORDER=MDMK` (fields 1,1,1,2) gives payload `{1, 2}`; field 1 is
the device id and must be 1 (`UORDER=MKMK` returns a clean
`Device id must be 1`); field 0 is the command handle. The handler then
resolves `payload+0x10` (handle 1) and `payload+0x38`, which is **null** and
crashes at `0x5968c`. Type 8 is UnregisterGraph, not ByBuffer. The client's
`TAG` env now sets the root command type, and types 7 and 8 both use
`build_reg3`.

1. **Enumerate the command types.** Send the remaining numbers in one
   session (`TYPES=2,5,5,3,4,6,9,10`; eight is the client's limit) and read
   the core log: it prints `received command seq no: N of type : NAME`
   before processing, so every name is captured even if a later command
   crashes. A second session covers the rest (11, 12, 13, 14, 15). Find
   RegisterGraphByBuffer.
2. **Send ByBuffer.** With its type number, build the descriptor
   (`ORDER2=CS`, `UORDER=HDG`) so the `G` field points at the table with the
   container `C` and scratch `S`; check the response and the log for a
   registration success rather than the `+0x38` null.
3. **If the handler is shared**, stop at `core+0x59620` and confirm
   `payload+0x10`/`payload+0x38` are the two handles before letting it run.
4. **Pipeline and measure.** CreateExecution (9), bind input/output (12/13),
   Invoke (11) on the SSD 300x300 int8 model; 60 frames of
   `out/bench/mosaic12.mp4` through `tools/bench-object-detection.py`; fill
   the TPU row in U118 (CPU 4t 4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3
   fps, both 10.0 detections/frame), record U150 with the date and
   `uname -r`, replace this prompt, and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the
commit.
