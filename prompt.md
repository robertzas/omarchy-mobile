# Next: the RegisterGraph graph descriptor

The import is solved; do not redo it. `ImportMemoryFromFd` is type 5 and its
request table is `{handle, device_id, fd_handle, offset, size}`. The client
uses a `/dev/dma_heap/system` dma-buf (`{len, fd, fd_flags, heap_flags}` is the
kernel ABI), syncs it, sends it with `sendFileDescriptors`, and the tegu core
resolves it. A 4 KiB buffer and the 4,726,868-byte `graph.bin` both import
(memory handle 1).

`RegisterGraph` (type 7) is the wall:

- `{handle=2, memory=1}` creates `[Cmd 3][RegisterGraph Handle 2]` and then
  the service `MainTpuActor` segfaults with no response.
- `{handle=2, device=1, memory=1}` is rejected: `Invalid command flatbuffer`,
  because field 2 is a nested table, not a scalar.

So field 2 is the **graph descriptor**. Find its layout and contents:

0. Find the stock builder. Look in the chroot's `/system/bin`,
   `/system_ext/bin`, `/vendor/bin` for `*tpu*`/`*edgetpu*`, and in
   `android.hardware.neuralnetworks@service-darwinn-aidl`,
   `vendor.google.edgetpu_vendor_service`, `libedgetpu*` and
   `libtachyon_core.so` for `RegisterGraph`, `GraphDescriptor`,
   `TpuCommand`, `tpu_command` and the DIVE/tensor metadata. `strings`, `nm
   -D` and `llvm-objdump` on the tegu core.
1. Disassemble the tegu core's `RegisterGraph_Init` (name string at 0xcd54)
   and any `RegisterGraph` verifier/descriptor code. The tegu core is
   `out/factory/tegu-cp21/vendor-libs/libtachyon_core.so`; the phone's chroot
   has the same sha `d1602625...`.
2. Build the descriptor: the model's Edge TPU metadata (input/output tensors,
   bit depth) and the imported memory handle. `out/edgetpu-runtime/graph.bin`
   is the DWN1 image; the stock model is
   `$R/vendor/etc/model.tflite`.
3. Send `TYPES=2,5,7` with the nested table at field 2. A valid request must
   not segfault; then CreateExecution (9), bind input/output buffers (12/13),
   Invoke (11). After an invoke returns, run the 720p object-detection
   comparison against the CPU and GPU rows.

Kernel notes, not the immediate blocker: `edgetpu_mmu_alloc_domain` calls
`iommu_set_fault_handler`, which warns at `drivers/iommu/iommu.c:2061`
because the mainline `samsung_iommu` has no `set_fault_handler`; `unmap_slpt`
also warns. Keep them in mind for the driver work.

Rules: slot B only; never weaken the storage guard; the TPU is held by
`tpu-hold` (one power-up per boot), so no cold boot. The chain is
`NO_DELEGATE=1 /root/tpu-tachyon-run`, then the ring client as uid 1000 with
the vendor `LD_LIBRARY_PATH`/`LD_PRELOAD` set. `push`, suffixed slot-B
`flash`, `reboot-to` and client runs are unattended under AGENTS.md §1.1;
anything in the permanent-brick class asks first. Announce screen/feel
changes. Never commit firmware, vendor blobs, `out/`, `logs/` or identifiers.
