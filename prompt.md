# Next: make the core dispatch a command (Ping first)

State (TPU-PLAN U92): with the Power HAL up, the real `libtachyon_core.so`
and a prior delegate run, the client's session goes
CREATED -> STARTED -> AUTHORIZED in 1 ms, but no round is dispatched: the
service never logs `received command`, and receiveResponse returns
`exception -8 service 8`. The one good Ping (U90) happened on a service
restart after a boot where the delegate had run.

1. Reproduce a good Ping and keep its log: boot with the runner (delegate
   enabled), copy `/tmp/tpu-tachyon.log` aside before restarting anything,
   then restart only the Tachyon service and run the client. On success,
   diff the core's lines against today's.
2. Find which binary logs `received command` (strings of the core, the
   service and the app service) and what starts that actor
   (`TachyonCore_Start` caller, its argument, thread creation).
3. Check the command FMQ's direction and notification: the client's
   `setGetFdsResponseCallback` may hand back the response queue's fds;
   compare the fds it maps for the command and response queues.
4. Once a Ping dispatches, find the Execute opcode and its message layout in
   `libedgetpu_tachyon.google.so` (`TachyonCommand_*` strings), then run
   `detect_edgetpu.tflite`.
