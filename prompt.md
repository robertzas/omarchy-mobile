# TPU bring-up: final iteration (2026-11-09)

Read `device/cheetah/TPU-PLAN.md` U150-U168 and `AGENTS.md` first. Phone:
up (reachable via `tools/phone-ssh`), kernel
`7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware sha
`52c1cccd…`, `janeiro` loaded, `tpu-hold` holding the device since boot.
Do not run `tpu-a14-hal` or any direct `/dev/edgetpu` create (U154).

**Final State:** Both core patches are in the phone chroot
(`libtachyon_core.so`: setup answer forced OK at `0xab754`, `+0x38` null
load replaced by `mov w8, #2` at `0x5968c`; backups `.setupok-orig`,
`.regnull-orig`). Header-less graph at `$R/vendor/etc/graph-fb.bin`
(4,726,860 B, `c8 0f 00 00 44 57 4e 31`). Chain runs with
`NO_DELEGATE=1 sh -s < tools/tpu-tachyon-run`; test with
`tools/phone-ssh --fresh 'GFILE=/vendor/etc/graph-fb.bin sh /tmp/run_graph_test.sh /vendor/etc/graph-fb.bin'`.

**CRITICAL: Identifier check patch needed.** The core at
`out/edgetpu-runtime/libtachyon_core.so` rodata 0x142ee has string
"Invalid flatbuffer file identifier %s". The code reads bytes 4-7 from byte 0
of the imported graph buffer and:
- If byte 4 == 0x00 → immediate reject, `%s` printed empty
- If bytes 4-7 == DWN1 (0x44574e31) → `%s` printed as "DWN1", then flatparser
  fails (structure mismatch)
- If bytes 4-7 == any other 4-byte value → immediate reject, `%s` printed empty

The two existing patches (at `0xab754` and `0x5968c`, both `48 00 80 52` /
`mov w8, #2`) handle setup and null-dereference but **do NOT fix the identifier
check**. An additional binary patch is needed to the core's identifier check
function.

**How to patch on the phone** (you, with direct device access):

1. **Search the .text section** of `out/edgetpu-runtime/libtachyon_core.so`
   (VA 0x4d0e0, size 0x117e5c) for code that loads bytes 4-7 from the graph
   buffer and compares them. Look for `adrp`/`add` sequences targeting the
   string at 0x142ee ("Invalid flatbuffer file identifier %s").

2. **Apply the patch** one of two ways:
   - **Option A**: Find the comparison instruction that checks if bytes 4-7 == 0,
     and NOP it out (replace with `e1a0 0000` or equivalent NOP).
   - **Option B**: Find the comparison that checks bytes 4-7 == DWN1, and change
     the comparison value to always accept (e.g., change DWN1 to a different value,
     or change the branch condition).

   Based on patterns from the existing patches (both used `48 00 80 52` /
   `mov w8, #2`), try applying `48 00 80 52` at likely offsets in .text:
   - Start with 0x1062dc (previously had zero value)
   - Then try 0x160c44, 0x4d150, 0x4d200, 0x5adb8, 0x5adc4
   - After patching: `NO_DELEGATE=1 sh -s < tools/tpu-tachyon-run`
   - Then: `GFILE=/vendor/etc/graph-fb.bin sh /tmp/run_graph_test.sh /vendor/etc/graph-fb.bin`

3. **If RegisterGraph passes** (no "Invalid flatbuffer file identifier" in output):
   - **Proceed to inference**: `CreateExecution` (9), `BindInputBuffers`,
     `BindOutputBuffers` and `Invoke` for `detect.tflite`, then 60 frames of
     `out/bench/mosaic12.mp4` for the TPU row of U118
     (CPU 4t 4.28 ms, GPU 3.00 ms, 10.0 detections/frame).
   - **Record** the date and `uname -r`.

4. **If blocked**: document findings in `device/cheetah/TPU-PLAN.md` (new
   U169+), update this prompt with concrete next steps, and commit plan +
   prompt + any client/script changes. No `Signed-off-by`; grep diff for
   identifiers.

**Test helper on phone** (`/tmp/run_graph_test.sh`):
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
