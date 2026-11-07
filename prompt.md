# Next: enable the TPU AON island, the one thing still holding the core in reset

Established (U42-U45): a compiled model exists, the runtime reaches the driver,
the device-group ioctl succeeds with the node taken from
`/sys/class/edgetpu/janeiro/dev` (major changes per boot — never hard-code it),
the TPU's mailbox interrupts arrive (`irq 163 idx 0 ... status 1`), ACPM accepts
the TPU DVFS state, and reordering `PSM0_CFG` before `PSM0_START` changed
nothing. Every failure reduces to one line:

    Set LPM0 failed: -110 (PSM0_STATUS=0x5644c13 ... AON_RESET=0xdeadfeed
      AON_CLK=0xdeadfeed AON_QUIESCE=0xdeadfeed POWER_CONTROL=0xdeadfeed GSA state=0)

The PSM registers answer; the AON registers all read `0xdeadfeed`, i.e. that
island is unclocked. So find and enable the AON clock/power in the driver:

1. `drivers/edgetpu/edgetpu-mobile-platform.c` maps only `"tpu"` and `"ssmt"`;
   check the vendor node for a third region (AON/`pmu`), a `clocks` list, and
   `power-domains`. Stock's dtbo on slot A has the real node — fetch it read-only
   (never write slot A).
2. If AON is clocked through ACPM, look at what `exynos_acpm_set_rate` is
   expected to do for `TPU_ACPM_DOMAIN` beyond DVFS (the shim only forwards
   `dvfs.set_rate`, which is enough for `power/state` but may not gate AON).
3. Test with the group ioctl only: create `/dev/janeiro` from sysfs, kill stray
   `edgetpu-run` processes, then run under `timeout 60` and read `dmesg`.

When LPM0 succeeds, `edgetpu-run` prints the graph's tensor counts, and the
benchmark can run: compiled `detect_edgetpu.tflite` over the 720p 10-object
video against CPU (3.98 ms/frame at 4 threads, 10 detections/frame at 0.4), GPU
and the other backends.

Rules: slot B only, `pkill -x`, delete `$KERNEL_OUT/images` before `push`,
`depmod -a $(uname -r)` and `modules-push` when `modinfo -F srcversion janeiro`
differs (the driver is a module, so a kernel rebuild alone ships nothing),
announce screen-off before `poweroff`, no vendor blobs or identifiers, no
`Signed-off-by`.
