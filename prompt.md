# Next: RegisterGraph with the compiled model

Measured (TPU-PLAN U98): AllocateTpu succeeds and retires, and the virtual
device stays INITIALIZED for the session. RegisterGraph is sent with seq 2
but its answer arrives after the client's poll window or not at all.

1. Read the actor log after the AllocateTpu RETIRED lines for
   "received command seq no: 2 of type : RegisterGraph". If it is absent,
   the second ring is not waking the actor (ring the command eventfd again
   after commit or re-open the queue's fd ordering as in round 1).
2. Build the RegisterGraph table: the compiled model's Edge TPU custom-op
   metadata is the graph; recover the table fields from the core's verifier
   and the vendor builder in `libedgetpu_client.google.so`.
3. Then ImportMemoryFromFd with a real dma-buf (`/dev/dma_heap/system`),
   the Bind* commands and Invoke (union 11).
4. Measure the inference, then run the 720p CPU/GPU/TPU object-detection
   comparison.
