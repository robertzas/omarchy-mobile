# Prompt: give the firmware the setup message it accepts, then benchmark

Goal: one real Edge TPU inference on `cheetah`, then object detection on
`mosaic720.mp4` (10+ objects per frame) measured against CPU, GPU and every
other working path with `tools/bench-object-detection.py`. Only numbers from
runs that happened.

Read `device/cheetah/TPU-PLAN.md` U27-U75 first.

## Where it stands (2026-11-08, U75)

- Kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`; `/dev/janeiro` up,
  one power-up per boot, no oops.
- The vendor stack runs; the client reaches AUTHORIZED with both FMQs and a
  working `sendCommand`/`receiveResponse` pair.
- The HAL's forced setup call submits a 128-byte payload; the firmware answers
  `KCI_ERROR_FAILED_PRECONDITION` (9). The driver's `edgetpu_vii_payload_dump`
  shows the payload in `dmesg` (U75), and its first `u32` is 0x14.
- The element is `u64 seq; u16 code; u16 reserved[3]; dma{iova@16,size@24}`;
  byte 10 is reserved, not a type.
- No inference, no benchmark.

## Do these in order

1. Parse the 128-byte payload from U75 as a flatbuffer (root offset 0x14) and
   name its tables/fields; if it does not parse, compare it byte for byte with
   the core's builder at `libtachyon_core.so` `0xa4d5c`/`0xa4dec` and the
   verifier `0xb9c48`.
2. Rebuild the setup message as the core does (type-1 union, global scratches,
   cluster bitset) in `tools/tpu-tachyon-client.c` and push it through the
   AUTHORIZED session. The client already has a working command queue and the
   driver prints both the element and the payload, so each attempt is readable.
3. Re-run the full chain as system and look for a response without error 9,
   then run the delegate for a real inference.
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
