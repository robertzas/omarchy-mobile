# TPU bring-up: next iteration (2026-11-09, after U167b)

Read `device/cheetah/TPU-PLAN.md` U150-U167b and `AGENTS.md` first. Phone:
up (reachable via `tools/phone-ssh`), kernel
`7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware sha
`52c1cccd…`, `janeiro` loaded, `tpu-hold` holding the device since boot.
Do not run `tpu-a14-hal` or any direct `/dev/edgetpu` create (U154).

**State.** Both core patches are in the phone chroot
(`libtachyon_core.so`: setup answer forced OK at `0xab754`, `+0x38` null
load replaced by `mov w8, #2` at `0x5968c`; backups `.setupok-orig`,
`.regnull-orig`). Header-less graph is at `$R/vendor/etc/graph-fb.bin`
(4,726,860 B, `c8 0f 00 00 44 57 4e 31`). Chain runs with
`NO_DELEGATE=1 sh -s < tools/tpu-tachyon-run`; test with
`tools/phone-ssh --fresh 'GFILE=<path> sh /tmp/run_graph_test.sh <path>'`.

**U167b findings (RegisterGraph, type 7, round 5):** Core reads bytes 4-7 of
the graph buffer as flatbuffer file identifier. Identifier byte 4 == 0x00 →
immediate reject with empty `%s`. Non-zero identifiers: `DWN1` (correct per
upstream `executable.fbs`) was rejected as `Invalid flatbuffer file identifier
DWN1` in early runs (parser/structure mismatch after identifier read), but
later runs printed empty `%s` for the same and other buffers (variance across
chain restarts, cause unclear). Patched identifiers (TCHN/DIVE/EXEC/DGC0/etc.),
zeroed identifier, 0x482000-length slice, and `out/bench/graph-dgc0-fb.bin`
all failed. RegisterGraph never passes.

**CRITICAL: Identifier check needs binary patch.** The core at
`out/edgetpu-runtime/libtachyon_core.so` rodata 0x142ee has string
"Invalid flatbuffer file identifier %s". The code reads bytes 4-7 from the
graph buffer and:
- If zero → immediate reject, empty `%s`
- If non-zero (e.g., DWN1) → print identifier, then flatparser fails

The two existing patches (at `0xab754` and `0x5968c`, both `48 00 80 52` /
`mov w8, #2`) handle setup and null-dereference but do NOT fix the identifier
check. An additional patch is needed.

**Next (highest value):**
1. **Patch the core's identifier check on the phone.** The code that checks
   bytes 4-7 of the graph buffer needs to be modified to accept the graph's
   identifier. Based on patterns from the existing patches:
   - Existing patches at `0xab754` and `0x5968c` both use binary `48 00 80 52`
   - The identifier check is likely at a similar offset in the .text section
   - Patch candidate: search for the zero-comparison pattern and NOP it out,
     or apply `48 00 80 52` at the identified offset
   - After patching: re-run the chain with `GFILE=/vendor/etc/graph-fb.bin`;
   RegisterGraph should pass, then proceed to CreateExecution (9), bind,
   Invoke and the 720p benchmark.

2. **If patching the core:** re-run the chain, verify RegisterGraph passes,
   then proceed to CreateExecution (9), BindInputBuffers, BindOutputBuffers
   and Invoke for `detect.tflite`, then 60 frames of
   `out/bench/mosaic12.mp4` for the TPU row of U118 (CPU 4t 4.28 ms, GPU
   3.00 ms, 10.0 detections/frame). Record the date and `uname -r`.

3. **If blocked:** document findings in `device/cheetah/TPU-PLAN.md` (new
   U168+), update this prompt with concrete next steps, and commit plan +
   prompt + any client/script changes. No `Signed-off-by`; grep diff for
   identifiers.

**Test helper on phone (`/tmp/run_graph_test.sh`):**
```sh
#!/bin/sh
GFILE=${1:?}
R=/usr/lib/omamobile-vendor/edgetpu/root
L=/apex/com.android.tethering/lib64:/system_ext/lib64:/vendor/lib64:/system/lib64:/apex/com.android.runtime/lib64/bionic
P="/system/lib64/libnosid.so /system/lib64/liblogstderr.so /system/lib64/libselinuxshim.so /system/lib64/libpropsshim.so"
pgrep -x com.google.edge >/dev/null || { echo "NO SERVICE"; exit 1; }
LOGSTART=$(wc -l < /tmp/tpu-tachyon.log)
env LD_LIBRARY_PATH="$L" LD_PRELOAD="$P" HANDLE=1 FDH=1 TYPES=1,2,5,5,7 SETUP=1 UORDER=MDMK \
  GFILE="$GFILE" DELAY=1 timeout 100 chroot --userspec=1000:1000 "$R" /vendor/bin/tpu-tachyon-client.setup \
  >/tmp/client-test.log 2>&1
echo "client rc $?"; grep -av 'ld.so: object' /tmp/client-test.log | grep -n "round 5" -A 12 | head -20
tail -n +"$LOGSTART" /tmp/tpu-tachyon.log | grep -a -v '^\[native\]' | grep -aE "RegisterGraph|INVALID|file identifier|error|Error" | tail -20
```

Side track, not started: hardware video codec for ffmpeg, see
`device/cheetah/VIDEO-PLAN.md`.
