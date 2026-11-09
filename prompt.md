# Next: load the info-echo gxp module on a cold boot

U110-U112: the info query is decoded and  now builds with the running
kernel's vermagic. The TPU on the current boot is spent, so the test needs one
cold boot.

1. Copy the module:  and
   compare e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  - on both sides.
2. , wait for the owner's Power press. On the new boot,
   before the first TPU power-up: , then
   , then .
3.  names what libgxp asks for. Pass: the
   service gets past the version query and the next refusal names the next
   ioctl. Rollback:  and insmod the installed copy from
   .
