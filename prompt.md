# Next: capture a real RegisterGraph, then replay it

Measured (U101): the DIVE blob is a DWN1 container whose field order is older
than the published `executable.fbs` (version 12, 8-slot vtable), so the core
must parse it itself. The private piece is the Tachyon RegisterGraph request.

1. Write an LD_PRELOAD hook over `TachyonComputeSession_sendCommand` and
   `TachyonComputeSession_sendFileDescriptors` that hexdumps every buffer and
   fd set. Run it in the vendor HAL (app uid) and drive the HAL's NNAPI
   device with the smallest possible client, so it prepares the model and
   builds RegisterGraph for it.
2. If the HAL sends nothing, sweep the union table layout with the core's log
   as the oracle: "Register graph Litebuf command buffer info: vii_cmd
   size=..., dive_cmd size=..." appears only for a request the core accepts.
3. With the graph registered, send ImportMemoryFromFd (a `/dev/dma_heap/system`
   dma-buf holding the executable), CreateExecution (9), BindInput- and
   OutputBuffersToTensors (12/13) and Invoke (11). Measure it, then run the
   720p CPU/GPU/TPU object-detection comparison.
