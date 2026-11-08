# Prompt: make the Edge TPU's firmware setup be accepted, then benchmark

Goal: one real Edge TPU inference on `cheetah`, then object detection on
`mosaic720.mp4` (10+ objects per frame) measured against CPU, GPU and every
other working path with `tools/bench-object-detection.py`. Only numbers from
runs that happened.

Read `device/cheetah/TPU-PLAN.md` U27-U73 first.

## Where it stands (2026-11-08, U73)

- Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`; `/dev/janeiro` up,
  one power-up per boot (`tpu-hold`), no oops.
- The vendor stack runs: servicemanager, Power HAL, vendor service, Tachyon
  service; the client reaches `AUTHORIZED` and both FMQs, and `sendCommand`
  succeeds (no response yet). `libdarwinn_hal.so` has the U67 forced bitset
  (`0x14d9a48` = `35 04 80 52`).
- The setup is now attempted and **refused by the firmware**:
  `INTERNAL: Sync VII command failed: error_code=9` (`file.cc:1506`),
  `create device status: 13`, with `KCI tx code 10 seq 65` in dmesg. The
  delegate exits 1.
- No inference, no benchmark.

## Do these in order

1. Decode `error_code=9`: find the enum or string table in the vendor libs
   (`libdarwinn_hal.so`, `libedgetpu_tachyon.google.so`) around `file.cc:1506`
   and the VII response element for `seq 65` (the driver's 48-byte dump). Map
   9 to the firmware's status name and read what the response bytes say.
2. Compare the element the HAL wrote with what the firmware wants. U67 has the
   recorded element (`00000000 00000000 000b0000 00000000 ffeff000 00000000
   00000080` then zeros: `u16 11` at byte 10, payload at byte 16) and the note
   that the firmware accepts a **type-1** setup with `global scratches`. If the
   type/payload is the mismatch, patch the HAL's setup element (the call site
   is near `0x14d9cc0`) or build the type-1 message in
   `tools/tpu-tachyon-client.c` (`build_cmd` is a placeholder) and push it
   through the client session.
3. Re-run the full chain as system (`HAL_PRELOAD=… RUN_UID=1000
   /root/tpu-tachyon-run`) and look for a response instead of error 9; then run
   the delegate for a real inference.
4. Fix `EDGETPU_NUM_PREALLOCATED_DOMAINS` (0 in `janeiro/config.h`) and push the
   module once the setup is accepted.
5. After a real inference, benchmark TPU vs CPU vs GPU on `mosaic720.mp4` and
   record measured ms/frame and detections/frame.

## Rules (unchanged)

- Slot B only; never bootloader, radio, `devinfo`, `persist`, `efs*`, `modem*`,
  `vbmeta`, unsuffixed `fastboot flash`.
- Never load A14 firmware or vendor blobs; never commit firmware, blobs,
  MAC/Bluetooth addresses, serials, IMEIs or `getprop` dumps.
- One TPU power-up per cold boot; an oops or hang ends the boot.
- Screen/sound/feel changes get a one-line notice first.
- Kernel commits upstream-style, no `Signed-off-by`; repo commits `TPU-PLAN: …`.
- Fix causes, never weaken a check to make a run look clean.
