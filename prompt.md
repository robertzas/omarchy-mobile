# Next: exception -8 / service 8 in the Tachyon command path

State (TPU-PLAN U91): a fresh boot powers the TPU cleanly, the client creates
a session and sets up both queues, but the service never logs `received
command`; each round returns `exception -8 service 8` with zeros. The one
good Ping came on a service restart after the vendor service had been up and
had created its group.

1. Decode AStatus exception code 8 and service-specific error 8 in the NDK
   headers and in `libedgetpu_tachyon.google.so` (the client prints both).
2. Compare the vendor service's state in the two cases: its janeiro group
   create, its one-time setup command, and whether the app service published
   `IEdgeTpuAppService`. Keep the vendor service's log tail from a fresh boot.
3. Try the client on a boot where the vendor service has run for minutes
   (`HAL_ONLY=1`, wait, then run the client without restarting the Tachyon
   service).
4. One TPU power-up per boot (`tpu-hold`); never a second.
