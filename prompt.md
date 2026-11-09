# Next: RegisterGraph with the compiled model's graph

Measured (TPU-PLAN U99): AllocateTpu returns in 0.1 s and retires;
RegisterGraph with an empty table is received and its command is created
but never completes within 30 s. Transport and sequencing are done; the
payload is the work.

1. Parse `/vendor/etc/model.tflite`'s Edge TPU custom-op metadata (the
   `edgetpu-custom-op` section) into the graph flatbuffer RegisterGraph
   expects; recover the table fields from the core's verifier switch and
   the vendor builder in `libedgetpu_client.google.so`.
2. Send TYPES=2,7 with the graph payload and read the response; then
   ImportMemoryFromFd with a dma-buf (`/dev/dma_heap/system`), the Bind*
   commands and Invoke (union 11).
3. Measure the inference, then run the 720p CPU/GPU/TPU object-detection
   comparison.
