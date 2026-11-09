# Next: give RegisterGraph the DWN1 graph

Measured (TPU-PLAN U99-U100): the transport, session and command
sequencing work (AllocateTpu retires in 0.1 s; RegisterGraph is received
and its command is created), but an empty graph table never completes.
The model's `edgetpu-custom-op` custom_options is a 4,726,868-byte **DWN1**
container (`out/edgetpu-runtime/graph.bin`, head `31 00 34 00 … 44 57 4e
31`), not a flatbuffer.

1. Recover the RegisterGraph request table from the core: the union type
   table at `.data.rel.ro` 0x16c2f8 (entry 7), and the vendor builder in
   `libedgetpu_client.google.so`; find the field that carries the graph
   bytes and its type (vector of u8 or a nested table).
2. Encode the DWN1 blob into that field, send TYPES=2,7 and read the
   response. If the verifier rejects it, read the core's error log
   (VLOG 3) and match it to the verifier branch.
3. Then ImportMemoryFromFd (`/dev/dma_heap/system`), CreateExecution (9),
   BindInput/Output (12/13), Invoke (11); measure; then the 720p
   CPU/GPU/TPU object-detection comparison.
