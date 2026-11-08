# prompt.md — gxp: green module, then the create-device command

Do the suggested followups, then this prompt, then replace it and run the new
one.

## Rules

- Slot B only: `boot_b`, `init_boot_b`, `vendor_boot_b`, `vendor_kernel_boot_b`,
  `dtbo_b`, `userdata` through the tools. Never bootloader, radio, `devinfo`,
  `persist`, `efs*`, `modem*`, `vbmeta`; no unsuffixed `fastboot flash`.
- Never load the A14 firmware or A14 vendor blobs.
- One TPU power-up per cold boot (`tpu-hold` first). An oops or hang ends the
  boot.
- Register reads of a block not known powered/clocked stay the owner's call per
  step. Mapping a window is not a read.
- No `Signed-off-by`; kernel commits upstream-style; repo commits `TPU-PLAN: …`.

## Where it stands (U83-U85)

- `/gxp@25c00000` is in the tree disabled, with the A17 reg/interrupts, and
  `gxp-probe.dtso` enables it (verified `status = "okay"` after fdtoverlay).
- `drivers/gxp` maps AUR and registers `/dev/gxp`; the three libgxp commands are
  decoded: `0x40086200` create (8 bytes), `0xc0184800` info (24 bytes),
  `0x40086201` release (8 bytes).
- Module build: see TPU-PLAN U85's last line.
- Measured CPU/GPU: mosaic12 (10.0 detections) CPU 3.97 ms, GPU 3.00 ms.

## This round, in order

1. **Get `gxp.ko` green.** `modules_prepare` with the pinned clang, then
   `make M=drivers/gxp LLVM=1 modules`; the missing `asm/types.h` in U85 means
   the out tree's generated headers are incomplete, not that the source is wrong.
2. **Implement `0x40086200` and `0x40086201` honestly**: the create command gets
   the 8-byte argument libgxp passes, returns a handle, and the release frees it;
   no register access, and unknown fields return `-EOPNOTSUPP` with a `dev_dbg`
   line rather than a guess.
3. **Run `libgxp.so` against `/dev/gxp`** in the chroot with the module loaded
   (dev grant: module load on slot B), and record the first command it sends and
   the error it gets. That tells us the version check and the next struct.
4. Only then plan the first read-only register probe with the owner, one
   register per step under `--watchdog`.
