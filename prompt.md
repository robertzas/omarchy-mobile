# Next: the Tachyon service's setup gate and the first inference command

State (TPU-PLAN U90): `tpu-tachyon-client` round-trips a Ping (88-byte
response, the service logs the command) when the service runs in the state
the boot-time vendor service left it; a freshly restarted service never logs
`received command` and the rounds fail with `exception -8 service 8`.

1. On a fresh boot run `/root/tpu-tachyon-run` with `HAL_ONLY=1`, keep
   `/tmp/tpu-tachyon.log`, and diff the vendor service's one-time setup from a
   run where the Ping works. Find what the setup changed (queues, a kernel
   node, /dev/gxp state) and make a service restart reproduce it.
2. Find the inference command: `tpu-tachyon-client` only sends Ping. Look for
   the Execute/executable opcodes in `libedgetpu_tachyon.google.so` and its
   NDK headers, and for a vendor binary that runs a model through
   `IComputeService`.
3. Keep one TPU power-up per boot (`tpu-hold`); never a second.
4. The IOMMU fixes on `omamobile-tpu` are built but not pushed; push and
   re-test the teardown warnings when the next boot happens.
