# Next: make the gxp stub answer the interface-version query

Measured (U109): `libgxp.so` asks `/dev/gxp` for `0xc0184800` (24 bytes,
`_IOWR(0x48, 0, 24)`), and `drivers/gxp/gxp.c` answers `-EOPNOTSUPP`, which is
where the Tachyon service stopped in U89. The TPU itself is held on this boot,
so this step is laptop + one `push` + one cold boot.

1. Disassemble `libgxp.so` at `0x14c0a0`-`0x14c160` and `0x12e240`-`0x12e2c0`:
   the instructions after each `0xc0184800` call read the returned struct, so
   they name its fields (interface major/minor, feature flags, queue limits).
2. Fill that struct in `gxp.c` from the published `gxp.h` ABI where the values
   are safe (major 1, minor 3) and zero elsewhere, keeping the log of the raw
   24 bytes so a mismatch is visible.
3. Build `gxp.ko` with `KERNEL_DIR=~/omamobile-kernel/wt-tpu
   KERNEL_OUT=~/omamobile-kernel/out-tpu`, `bin/omamobile push` it, cold boot,
   then `DELEGATE_UID=10000 /root/tpu-tachyon-run` and grep dmesg for the
   firmware's setup line. Pass: the service gets past the version query; the
   next refusal names the next ioctl.
