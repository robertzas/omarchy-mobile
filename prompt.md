# Next: put the client-assigned fd handle where the core reads it

U120 in `device/cheetah/TPU-PLAN.md`: the real path is `STYPE=0` (unset) with
the rebuilt ring client. `STYPE=1` starts the GXP actor and dies; `STYPE=2`
selects a fake StarShip test double with no real backend; `STYPE=3` is
invalid. Do not spend runs on 1 or 2.

The working baseline:

```sh
export OMAMOBILE_SSH_KEY=~/.ssh/id_ed25519
R=/usr/lib/omamobile-vendor/edgetpu/root
L=/apex/com.android.tethering/lib64:/system_ext/lib64:/vendor/lib64:/system/lib64:/apex/com.android.runtime/lib64/bionic
P="/system/lib64/libnosid.so /system/lib64/liblogstderr.so /system/lib64/libselinuxshim.so /system/lib64/libpropsshim.so"
: > /tmp/tpu-tachyon.log
NO_DELEGATE=1 /root/tpu-tachyon-run >/dev/null 2>&1
sleep 10
TYPES=2,5 HANDLE=1 FDH=1 DELAY=1 timeout 40 \
  env LD_LIBRARY_PATH=$L LD_PRELOAD="$P" \
  chroot --userspec=1000:1000 $R /vendor/bin/tpu-tachyon-client.ring
```

The client is rebuilt from `tools/tpu-tachyon-client.c`; the build line is at
the top of that file (add `-Wl,--export-dynamic` and `-ldl`). The Ping is
88 bytes, AllocateTpu retires and `[VD 1]` reaches INITIALIZED. Import is
type 5; type 6 is ReleaseMemory.

0. The union table's first u64 is the command handle (the core logs
   `ImportMemoryFromFd Handle 1`). A second u64 at table+16 is not the
   `client assigned fd handle`, which still reads 0 even with
   `sendFileDescriptors` returning OK. The fd handle is probably a nested
   memory-descriptor table.

1. Make union field 1 a uoffset to a table carrying one u64: the union table
   at 72 with its vtable at 64 (field 0 at 80, field 1 at 88), nested vtable
   at 96 (`{6,16,8}`), nested table at 104 (soffset 8, u64 at 112), total 120.
   Sweep the u64 across the nested table's +8/+16/+24 slots; the core's error
   names the number it read. Stop when it is the `FDH` you sent with
   `sendFileDescriptors`.

2. With the fd handle accepted, send the real graph instead of the 4 KiB
   memfd: push `out/edgetpu-runtime/graph.bin` (4,726,868 B, the model's
   `DWN1` custom_options) and give the memfd its bytes. If the import then
   asks for a size, add the size/offset fields the error names.

3. Once the graph is imported, send RegisterGraph (type 7) with the imported
   handle. The core parses the DIVE image itself; `CreateExecution`,
   `BindInputBuffersToTensors`, `BindOutputBuffersToTensors` and `Invoke`
   follow. The vendor model is `/vendor/etc/model.tflite` (SSD).

4. If the import cannot be made to accept the fd after the nested-table sweep,
   the only other setup producer is the GXP actor, which needs a real
   `/dev/gxp`; that is the larger path, not this one.

Rules: slot B only; never weaken the storage guard; no cold boot while
`tpu-hold` lives (one power-up per boot). `push`, suffixed slot-B `flash`,
`reboot-to` and client runs are unattended under AGENTS.md §1.1; anything
permanent-brick class asks first. Announce screen/feel changes first. Never
commit firmware, vendor blobs, `out/`, `logs/` or adapter addresses.
