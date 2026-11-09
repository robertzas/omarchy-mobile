# Next: build and run the gxp info-echo module

Measured (U110): `out-tpu/.config` has `# CONFIG_GXP is not set`, and
`drivers/Kconfig` never sources `drivers/gxp/Kconfig`, so every module build
was a no-op. `bc` is missing on the host, so the full `make modules` path stops
in `prepare0`.

1. Add `source "drivers/gxp/Kconfig"` to `drivers/Kconfig`, set `CONFIG_GXP=m`
   in `out-tpu/.config`, and run `olddefconfig`; check that
   `include/config/auto.conf` keeps `CONFIG_GXP_MODULE=y`.
2. Build in the project container (it has `bc`):
   `KERNEL_DIR=~/omamobile-kernel/wt-tpu KERNEL_OUT=~/omamobile-kernel/out-tpu
   bin/omamobile kernel`, or run `make M=$PWD/drivers/gxp modules` with the
   release file pinned to `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`.
3. `bin/omamobile push`, cold boot, `DELEGATE_UID=10000 /root/tpu-tachyon-run`,
   then `dmesg | grep "device info: in"` plus the service's log. Pass: the
   service gets past the version query, and the next refusal names the next
   ioctl.
