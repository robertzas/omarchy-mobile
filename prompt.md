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

**Next (highest value):**
1. **Patch the core's identifier check.** The error string "Invalid
   flatbuffer file identifier %s" is at `out/edgetpu-runtime/libtachyon_core.so`
   rodata offset 0x142ee. Find the comparison that checks bytes 4-7 against
   an expected value, and modify it to accept the graph buffer's identifier.
   Or: NOP out the check entirely. This is the highest-probability path to
   getting RegisterGraph to pass.
2. **If patching the core:** re-run the chain with the modified core, verify
   RegisterGraph passes, then proceed to CreateExecution (9), BindInputBuffers,
   BindOutputBuffers and Invoke for `detect.tflite`, then 60 frames of
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
