# Next: read the Ping response, then send a real command

Measured (TPU-PLAN U94): the Ping dispatches once the client rings the
queue's eventfd (`received command seq no: 1 of type : Ping`), and
`receiveResponse` returns OK. All four setup fds are eventfds; the lib
never rings them itself.

1. Dump the Ping response: `receiveResponse`'s `TachyonMessage` size and the
   88 bytes; decode the header (seq no, status, payload) against the core's
   `MakeErrorStatus`/`TachyonStatus` strings.
2. Identify the command union member that executes a model: grep the core
   for `Execute`/`ReadFile`/`CreateVirtualDevice` and match the flatbuffer
   verifier's table layout, then extend `build_cmd` for it.
3. Keep the response queue drained between commands
   (`beginResponseQueueRead`/`commitResponseQueueRead`, or
   `receiveResponse`).
4. Once Execute is accepted, feed it `detect_edgetpu.tflite`'s compiled
   model and measure; the 720p CPU/GPU/TPU comparison comes after.
