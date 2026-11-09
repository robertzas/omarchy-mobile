# Next: build the command tables and reach Invoke

Measured (TPU-PLAN U96): the union map is known, the actor answers every
command type, and each command must be sent once per session. Ping returns
OK; the empty tables return structured errors ("Virtual device failure",
"Invalid client assigned fd handle: 0").

1. Recover the request table layout for AllocateTpu: disassemble the
   verifier switch at `tpu_actor_engine.cc:785` in the core and the vendor
   builder in `libedgetpu_client.google.so` / `libedgetpu_util.so`.
2. Send AllocateTpu with the fields the verifier requires, then
   ImportMemoryFromFd with a real dma-buf fd handle, RegisterGraph with the
   compiled model's graph, CreateExecution, the Bind* commands and Invoke.
3. Keep one session for the whole sequence; the actor kills it on an
   invalid command.
4. Then measure the inference and run the 720p CPU/GPU/TPU
   object-detection comparison.
