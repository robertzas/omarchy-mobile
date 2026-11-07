# Next: make PSM0 acknowledge — the TPU core start sequence

Facts established (U42-U44): the userspace runtime works, a compiled model exists
(`detect_edgetpu.tflite`, 63/64 ops on TPU), `edgetpu-run` reaches the driver, and
ACPM sets the TPU DVFS state correctly (`state=226000 core=226000 ctl=226000`
through `/sys/kernel/debug/edgetpu/power/state`). What fails is the core start:
`PSM0_STATUS=0x5644c13` never gets bit 0x80, the AON registers read `0xdeadfeed`,
and both `janeiro_lpm_up()` and the firmware handshake time out (-110).

Work in `~/omamobile-kernel/wt-tpu`, one change per boot:

1. Compare the write order in `drivers/edgetpu/janeiro-pm.c` with the vendor
   driver: mainline writes `PSM0_CFG=0` only *after* LPM0 succeeds; check whether
   the vendor writes a configuration (and `PSM0_DEBUGCFG`) *before* `PSM0_START`.
   `EDGETPU_PSM0_RECOVER_VAL` (125888) shows the register set is known.
2. Check the AON clock: which clock feeds the AON registers (`AON_CLK=0xdeadfeed`
   means that island is unclocked), and whether ACPM's TPU domain is supposed to
   gate it. `power/min_state` and `policy` (1066000) are readable; a write of
   `policy`/`min_state` is the driver's own supported interface.
3. If the vendor DT is needed, get it from the device: the stock vendor_boot /
   dtbo on slot A contains the `janeiro@1ce00000` node with its real `reg`,
   `power-domains`, `clocks` and `samsung,acpm-ipc` properties. A read-only
   `fastboot` fetch of slot A's dtbo is the safe way; never write slot A.

When finalize succeeds, `edgetpu-run` prints the graph's tensor counts — then run
`detect_edgetpu.tflite` over the 720p 10-object video and benchmark against CPU
(3.98 ms/frame at 4 threads), GPU and the other backends.

Build/run rules unchanged: slot B only, delete `$KERNEL_OUT/images` before
`push`, `depmod -a $(uname -r)`, announce screen-off before `poweroff`, no vendor
blobs or identifiers in commits, no `Signed-off-by`.
