# Next: load the info-echo gxp module on a cold boot

U110/U111: the 24-byte info query is decoded (`+12` = `0x00080002`, return
value only) and the module builds with `CONFIG_GXP=m`. The TPU on the current
boot is spent, so the test needs one cold boot.

1. Copy `gxp.ko` to the phone (`tools/phone-ssh 'cat > /root/gxp-new.ko' < K`,
   then `sha256sum` on both sides), `systemctl poweroff`, and wait for the
   owner's Power press.
2. On the new boot: `rmmod gxp; insmod /root/gxp-new.ko` before the first TPU
   power-up, then `tpu-hold`, then `DELEGATE_UID=10000 /root/tpu-tachyon-run`.
3. Read `dmesg | grep "device info: in"`; the six words name what libgxp
   asks for. Pass: the service gets past the version query, and the next
   refusal names the next ioctl. Rollback: `rmmod` and insmod the installed
   copy under `/usr/lib/modules/<release>/`.
