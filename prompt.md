# Next: make the TPU answer — the driver side of the finalize timeout

Everything above the driver now works. `/vendor/bin/edgetpu-run` in the vendor
chroot opens `/dev/edgetpu` (`/dev/janeiro`), maps its buffer pools, and issues
the device-group finalize; the TPU never responds:

    E0000 file.cc:163] INTERNAL: Could not finalize device group: master_fd=3 (Connection timed out)

So work in the kernel, on `~/omamobile-kernel/wt-tpu`:

1. The power-up is the blocker and dmesg names it (U43):
   `Set LPM0 failed: -110 (... AON_RESET=0xdeadfeed AON_CLK=0xdeadfeed
   AON_QUIESCE=0xdeadfeed POWER_CONTROL=0xdeadfeed GSA state=0)`, then
   `firmware handshake failed: -110`. The PSM registers answer, the AON half of
   the block does not. Compare the vendor DT's edgetpu node with
   `gs201.dtsi`'s `janeiro@1ce00000` (reg regions, `gsa-device`, power
   domains) and read `janeiro_lpm_up()`/`mobile-pm.c`: find out whether the AON
   domain must be started through GSA (`GSA_TPU_START`) before its registers
   answer, instead of after LPM0.
2. Check what `tpu-enable.dtso` declares: the irq lines, the `ssmt` register
   base (`edgetpu_platform_parse_ssmt`), `memory-region`, and the power domains.
   Compare with the vendor DT for the same node (stock capture).
3. Read the power-up path: janeiro prints `Powering down` right after
   `janeiro edgetpu initialized`, i.e. the block may never leave reset. The
   finalize timeout would follow from that alone.
4. One change per boot, with the irq/power question first, since every other
   failure (HAL provider, vendor service abort) is downstream of a TPU that
   answers.

When the finalize succeeds, `edgetpu-run` prints the graph's input/output tensor
counts — that is the "TPU works" milestone. Then run the compiled
`detect_edgetpu.tflite` over the 720p 10-object video and benchmark it against
CPU (3.98 ms/frame at 4 threads, 10 detections/frame at 0.4), GPU and the rest.

Build rules unchanged: export `KERNEL_DIR`/`KERNEL_OUT`, delete
`$KERNEL_OUT/images` before `push`, `depmod -a $(uname -r)` after, slot B only,
announce screen-off before `poweroff`, no vendor blobs or identifiers in commits,
no `Signed-off-by`.
