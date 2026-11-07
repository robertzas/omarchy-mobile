# Next: make the TPU answer — the driver side of the finalize timeout

Everything above the driver now works. `/vendor/bin/edgetpu-run` in the vendor
chroot opens `/dev/edgetpu` (`/dev/janeiro`), maps its buffer pools, and issues
the device-group finalize; the TPU never responds:

    E0000 file.cc:163] INTERNAL: Could not finalize device group: master_fd=3 (Connection timed out)

So work in the kernel, on `~/omamobile-kernel/wt-tpu`:

1. Boot and capture the janeiro probe splat verbatim (`dmesg | grep -B12 -A12
   janeiro`). `edgetpu_device_add` -> `edgetpu_register_irq` warns today, and
   `edgetpu_platform_setup_irq()` logs `failed to request irq %d: %d` when a DT
   irq is wrong — either would explain completions that never arrive.
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
