# Next: make one command reach the actor (Ping first)

Measured state (TPU-PLAN U93): the session reaches AUTHORIZED, the actor
registers the queue fds, but a Ping produces no actor epoll event and no
`received command`; the first event is the client's death. The cheetah
lib's `setupCommandQueue` hands the caller the raw fds (the session's own
copies become -1), and `sendCommand` writes to the session's own queue
object.

1. Instrument the send: in the client, after `sendCommand`, call
   `TachyonComputeSession_beginCommandQueueWrite(session, 128, &buf, &a,
   &b, &c)` and `commitCommandQueueWrite(session)` and print the status of
   each. If begin/commit succeeds where sendCommand did not, use them for
   the Ping and for the response read.
2. Read the queue's write index before and after the send on both sides
   (`/proc/<pid>/fdinfo` and the mapped ring) to prove whether the write is
   visible to the service.
3. If the queue is dead after setup, build the FMQ client from the two raw
   fds: 128-byte slots, 12 KiB command queue, and ring the eventfd after
   the write.
4. Keep the delegate's util path in view: as uid 10000 it never creates a
   Tachyon session, so find what the util library checks before it asks the
   app service (the app service itself publishes and is reachable).
