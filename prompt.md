# TPU bring-up: next iteration (2026-11-09, after U153)

Read `device/cheetah/TPU-PLAN.md` U150-U153 and `AGENTS.md` first. Kernel on
the phone: `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`. The A17 firmware
is the live one (`/lib/firmware/updates/google/edgetpu-janeiro.fw`, sha
`52c1cccd…`); the A14 copy is at `/root/edgetpu-janeiro-a14.fw` and the A14
direct-path libs at `out/a14-edgetpu/` and the chroot's `/vendor/a14/`.

**State.** Every userspace producer sends the legacy type-0 setup and both
cheetah firmware generations (A14 `1.0 539775951` and A17 `1.0 895567958`)
refuse it with `Setup is not done yet received/recieved a command of type
0.` The A14 HAL/util direct path (uid 0, `/dev/edgetpu`) fails exactly like
the A17 HAL and the tegu Tachyon core (`create device status: 13`). The GSA
path itself works: `TPU cmd 0 → 0`, `cmd 50` loads the image, `cmd 151`,
`TPU cmd 1 → 2`, `power-up ok … GSA state=2`. The stock setup must be done
by the bootloader — `janeiro-pm.c` says stock is "unlike stock where ABL
leaves the TPU running".

1. **Find the bootloader's TPU setup.** `out/factory/cheetah-abl/…/bootloader-cheetah-cloudripper-17.0-15199429.img`
   is an FBPK container (13,508,360 B) with ELF images at
   `0x27056e`, `0x273e00`, `0x284e00`, `0x3d8e00`, `0x4e6b00`, `0x522d00`,
   `0x632d00`, `0x6a8000`, `0x6b0d00`, `0x6bd400` and more. Parse the FBPK
   table, name each image (ABL, XBL, TZ, AOP, GSA), and find the one that
   touches the TPU/janeiro (strings, then xrefs to the TPU firmware path or
   the GSA mailbox).
2. **Recover the type-1 setup.** From that image, read the global scratch
   descriptors, the cluster bitset and the VII/command framing it sends
   before Linux. If the bootloader sends it through the GSA mailbox rather
   than VII, replay it via `gsa_send_tpu_cmd`/the mailbox, or build the
   equivalent type-1 VII element for the ring client.
3. **Then the pipeline.** With the firmware set up, Run RegisterGraph
   (7), CreateExecution (9), BindInputBuffers (12), BindOutputBuffers (13),
   Invoke (11) on the SSD 300x300 int8 model, 60 frames of
   `out/bench/mosaic12.mp4` through `tools/bench-object-detection.py`, fill
   the TPU row in U118 (CPU 4t 4.28 ms/233.9 fps, GPU WebGPU 3.00 ms/333.3
   fps, both 10.0 detections/frame), record the date and `uname -r`, replace
   this prompt, and commit.

Do not add `Signed-off-by`. Scan the diff for identifiers before the commit.
