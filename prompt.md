# Next: the setup handler's callees, then the capture boot

U116: `0x750a0` calls `0x144084` and, when non-null, builds a four-argument
call at `0x5a460` before the `PushFirmwareSetupCmdToVII failed` block at
`0x7531c`. Neither is the submit. The type bytes `+0x1c0/+0x1c1` are still
builder-only (`0x7fbb8`/`0x7fbdc`).

1. Offline: read `0x144084` and `0x5a460` in `/tmp/core.dis`, name what they
   do, and find the call that actually queues the setup VII element (the
   session factory at `0x73a48` builds the object; the submit must be a
   separate `bl`). Record it in `TPU-PLAN.md` with `file:line` pointers.
2. Cold boot: add `HOLD=${HOLD:-1}` around the `tpu-hold` block in
   `tools/tpu-tachyon-run`, copy it to `/root/tpu-tachyon-run`,
   `systemctl poweroff` (announce the dark screen), wait for the owner's
   Power press, then run `HOLD=0 /root/tpu-tachyon-run` with the delegate as
   the first and only TPU user. Capture
   `dmesg | grep -E "vii-payload|Setup|firmware"`; the driver's hexdump is
   the setup element's bytes.
3. Replay the captured element, then RegisterGraph the DWN1 graph from
   `out/edgetpu-runtime/graph.bin`, one inference against CPU TFLite, and
   only then the 720p CPU/GPU benchmark.

Rules: cold boot, `push`, suffixed slot-B `flash` and client runs are
unattended (AGENTS.md §1.1); permanent-brick class asks first. One TPU run
per cold boot; never kill a client mid-group; keep the log stream and USB
deadman; never commit firmware, vendor blobs, `out/` or `logs/`.
