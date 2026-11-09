# Next: find what gates the core's firmware-setup command

U113 closed the gxp info-echo question (it works; the service never asks) and
located the core's setup sender at `0x7fc20` in
`out/edgetpu-runtime/libtachyon_core.so`, type 11/15 at `[x19+0x1c1]`. The
firmware still logs `Setup is not done yet`, and the core never logs a setup
attempt, so the trigger is not reached. Work offline first; the phone keeps
its boot until step 2.

1. Find the function that contains `0x7fb5c` in `/tmp/core.dis` (scan back for
   its prologue), then every `bl` to its start. Its callers name the gate: the
   core's own strings are `PENDING_FIRMWARE_SETUP` (`strings -t x` finds
   it), `Unexpected firmware setup status: ` and
   `Sending firmware-setup VII command. type: `. Record the caller, the state
   field it tests and the branch that skips the call in `TPU-PLAN.md`.
   Also map `libedgetpu_util.so`'s `0x13befc`: its program headers differ from
   the core's, so that address is a file offset; print the headers and
   disassemble the mapped vaddr to see whether util's per-cluster setup payload
   is the same Command flatbuffer.

2. Test the "firmware already awake" hypothesis on one cold boot. The runner's
   `tpu-hold` takes the first TPU power-up before the core creates its session,
   so the core may see the firmware awake and skip setup. Add `HOLD=${HOLD:-1}`
   around the `tpu-hold` block in `tools/tpu-tachyon-run`, copy it to
   `/root/tpu-tachyon-run`, `systemctl poweroff` (announce the dark screen),
   wait for the owner's Power press, then run `HOLD=0 /root/tpu-tachyon-run`
   with the delegate as the first and only TPU user. Capture
   `dmesg | grep -E "vii-payload|Setup|firmware"` and the runner log. Pass:
   a `vii-payload` carrying the setup Command, or `Setup is already done`;
   either names the payload layout from the driver's own hexdump.

3. If the gate is a state flag rather than the power state, patch a copy of the
   core at the branch that skips `PushFirmwareSetupCmdToVII`, run the chain
   once, and capture the setup element from `vii-payload`. Do not patch the
   installed copy; keep `.orig` and record both shas.

4. With setup accepted, register the DWN1 graph from
   `out/edgetpu-runtime/graph.bin` (the `detect_edgetpu.tflite` custom op),
   run one inference and compare with CPU TFLite, then start the 720p
   benchmark. Do not claim any TPU number before step 4.

Rules: cold boot, `push`, `flash` of suffixed slot-B images and client runs are
unattended (AGENTS.md §1.1). Anything in the permanent-brick class asks first.
One TPU run per cold boot; never kill a client mid-group; keep the log stream
and USB deadman; never commit firmware, vendor blobs, `out/` or `logs/`.
