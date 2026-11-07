# Next: make GSA's TPU_START succeed (it returns 2 today)

The device tree is not the problem: Google's own `gs201-tpu.dtsi` has the same
properties as ours and likewise no `clocks`/`power-domains` (U49). The TPU is
started by the GSA, and our kernel's own log says the start fails:

    google-gsa 17c90000.gsa: loading TPU image: header 0x82e63000 body 0x93000000
    google-gsa 17c90000.gsa: TPU cmd 1 (Trusty): 2

Then `Set LPM0 failed: -110`, `firmware handshake failed: -110`, `Powering down`.
So the work is in `drivers/soc/google/gsa.c` and its Trusty interface:

1. Read `gsa_send_tpu_cmd()` and the TPU image load/unload helpers: where does
   the "loading TPU image" come from, what does the return code 2 mean (map it
   against the Trusty service's error space), and is the command id the one the
   gs201 GSA firmware expects (GSA_TPU_START is 1 in our header).
2. Check that Trusty actually exposes the gsa/tpu service: `dmesg | grep -i
   trusty`, `/dev/trusty-ipc-dev*` and the tpu-related Trusty service name in the
   vendor image. Our binder/AoC work already showed Trusty running for other
   services, so a missing service is plausible and testable.
3. If the image itself is wrong, compare the header/body addresses and sizes the
   driver computes against the `tpu_fw_reserved` region in `gs201.dtsi` (the
   reserved-memory entries use `#address-cells = <2>`, `#size-cells = <1>` on
   gs201 - a 16-byte `reg` is silently ignored, a mistake this project already
   made once).

Success: `TPU cmd 1` returns 0, `Set LPM0` disappears, and `edgetpu-run` prints
the graph's tensor counts. Then the benchmark: `detect_edgetpu.tflite` on the
720p 10-object video against CPU (3.98 ms/frame at 4 threads), GPU and the rest.

Rules: slot B only, `pkill -x`, `modules-push` after module changes, announce
screen-off before `poweroff`, no vendor blobs or identifiers, no `Signed-off-by`.
