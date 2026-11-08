# prompt.md — the gxp driver: DT node first, then libgxp's ioctl contract

Do the suggested followups, then this prompt, then replace it and run the new
one.

## Rules

- Slot B only: `boot_b`, `init_boot_b`, `vendor_boot_b`, `vendor_kernel_boot_b`,
  `dtbo_b`, `userdata` through the tools. Never bootloader, radio, `devinfo`,
  `persist`, `efs*`, `modem*`, `vbmeta`; no unsuffixed `fastboot flash`.
- Never load the A14 firmware or A14 vendor blobs. The A17 blob may be read
  locally for analysis, never committed.
- One TPU power-up per cold boot (`tpu-hold` first).
- Reads of blocks not known powered and clocked, `devmem` writes, PMU register
  access and any gxp/register probe are the owner's call per step (§1.1).
- No `Signed-off-by`; repo commits `TPU-PLAN: …`; only measured numbers.

## Where it stands (U76-U84)

- The A17 `google,gxp` node is recovered (U84): AUR 0x25c00000+0x1400000,
  mailboxes 0x18380000-0x183e0000, CMU 0x25a00000, SSMT 0x25ad0000/0x25ae0000,
  SPIs 0x4f-0x52, fw 0x98000000 and scratchpad 0x98400000, phandles to TPU and
  GSA. Extracted under `out/stock-a17/`, never committed.
- VII is closed (U80-U82). No TPU inference has run; no TPU number exists.
- Measured CPU/GPU: mosaic12 (10.0 detections) CPU 3.97 ms, GPU 3.00 ms.

## This round, in order

1. **Write the gxp DT overlay** for our tree: the node above with our labels for
   the TPU and GSA and the iommu group, `status = "disabled"` in the base and an
   overlay that enables it, per the one-change-per-boot rule. Validate with
   `dt-validate` and `make dtbs`.
2. **Map `libgxp.so`'s ioctl contract**: find the pointer table that holds
   `/dev/gxp` (vaddr 0x38a11) and the `ioctl` call sites (svc #0, x8=29), list
   the command numbers and the struct sizes they pass, and write them into
   TPU-PLAN before writing any driver code.
3. **Skeleton driver** `drivers/gxp/` with probe, the register window mapping,
   `/dev/gxp`, and the version ioctl `libgxp.so` checks first; no register
   writes until the owner approves the one read-only probe step.
