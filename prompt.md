# TPU bring-up: next iteration (2026-11-09, after U166)

Read `device/cheetah/TPU-PLAN.md` U150-U166 and `AGENTS.md` first. Phone:
up, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`, A17 firmware
sha `52c1cccd…`, `janeiro` loaded, `tpu-hold` holding the device since
boot. Do not run `tpu-a14-hal` or any direct `/dev/edgetpu` create (U154).

**State.** Both core patches are on disk in the chroot
(`libtachyon_core.so`: setup answer forced OK at `0xab754`, the `+0x38`
null load replaced by `mov w8, #2` at `0x5968c`; backups
`.setupok-orig`, `.regnull-orig`). With `HANDLE=1 FDH=1 TYPES=1,2,5,5,7
SETUP=1 UORDER=MDMK GFILE=/vendor/etc/graph.bin` the five rounds all
answer; RegisterGraph returns `INVALID_ARGUMENT: Invalid flatbuffer file
identifier ` with an empty identifier, because `graph.bin` carries an
8-byte header before the `DWN1` flatbuffer and the core verifies from
byte 0 (U166).

1. Make a header-less graph in the chroot: `tail -c +9
   $R/vendor/etc/graph.bin > $R/vendor/etc/graph-fb.bin` (4,726,860 B;
   check `xxd -l 8` shows `c8 0f 00 00 44 57 4e 31`).
2. Restart the chain (`NO_DELEGATE=1 sh -s < tools/tpu-tachyon-run`),
   stream `dmesg -w` to `logs/tpu/`, and run `logs/exp166.sh` with
   `GFILE=/vendor/etc/graph-fb.bin`. Read the round-5 text and the core
   log lines that follow it.
3. If RegisterGraph passes, send CreateExecution, BindInputBuffers,
   BindOutputBuffers and Invoke for `detect.tflite`, then 60 frames of
   `out/bench/mosaic12.mp4` for the TPU row of U118 (CPU 4t 4.28 ms,
   GPU 3.00 ms, 10.0 detections/frame). Record the date and `uname -r`.
4. Replace this prompt with the next state and commit the plan, prompt
   and client changes. No `Signed-off-by`; grep the diff for identifiers.

Side track, not started: hardware video codec for ffmpeg, see
`device/cheetah/VIDEO-PLAN.md`.
