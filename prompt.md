# Next: run a model through the Tachyon session

Measured: the Ping dispatches and returns its 88-byte response (TPU-PLAN
U94); the delegate's platform value does not select the Tachyon path (U95);
the session authorizes and the actor logs every command.

1. Decode the 88-byte Ping response (flatbuffer: 0x18 block, then a table
   with a status field) and use it as the template for a real command.
2. Find the Execute union type in the core's verifier: disassemble the
   `VerifyCommandMessage` call site at `tpu_actor_engine.cc:785` and map the
   union's type ids (`Ping` is 1, from the log).
3. Build the Execute message from the vendor's own compiled model
   (`/vendor/etc/model.tflite`); if it is not Edge TPU-compiled, run the
   vendor compiler in the chroot first.
4. Only after a real inference: measure it, then run the 720p CPU/GPU/TPU
   object-detection comparison.
