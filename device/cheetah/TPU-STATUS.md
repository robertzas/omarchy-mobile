<!-- SPDX-License-Identifier: MIT -->
# Edge TPU bring-up: status and benchmark

As of 2026-11-13 (rev 10), kernel
`7.3.0-rc6-omamobile-push1-ga78d26f63e56-dirty`, slot B. The plan of record is
[TPU-PLAN.md](TPU-PLAN.md); the full experiment log and every prior revision
are in [TPU-HISTORY.md](TPU-HISTORY.md). **No model has run on the TPU and no
inference is claimed.** Gate K was re-proven on this boot
(`logs/tpu/20261113-gatek-rev10.txt`).

Rev 10 first withdrew the KCI-6 route (the driver's enum has no code 6, U269),
then U276 corrected the reason: with a **mapped** 512 KiB scratch, code 6 with
the U262 command answers `12` (`UNIMPLEMENTED`), not `3`. The firmware does
dispatch code 6 and accepts the payload shape; the handler is a stub on both
images tried, so KCI 6 is still not the producer, but the payload is no longer
suspect. It also records that every producer so far wrote **VII code 0**
into the 48-byte element (U248, U249). The decoded body loads 977 island
addresses but none of the four setup messages (U270), so the log-ring index is
where the static route continues (F1/A5'). U277 sampled the last element field: the u8 at +10 is the command class, 0-11
reaches the setup gate and 12-255 a different class, so no class sets the
firmware up. The stock oracle remains the only *proven* producer; the image's
only firmware-setup code is the NNAPI DBA HAL (`libdarwinn_dba_hal_runtime.so`,
`Hal::CreatePredictor`, whose submit takes the global scratches the firmware
asks for), which this port has never driven.

## Where it stands

- **Gate K passes.** A Tachyon session, both FMQ queues and a command round
  trip work; the reply is an 88-byte FlatBuffer, not a setup ack.
- **Gate D (the firmware's one-time setup) is blocked.** Every VII command is
  refused with `Setup is not done yet ... type 0` (`0xf000009`) before its
  payload is parsed, and VII codes 1-3 gate identically (U273), so setup is not
  a VII code. KCI code 6 *is* dispatched but answers `UNIMPLEMENTED` on both
  images with a mapped allocation (U276). The HAL alone sends nothing (U274),
  and the stock driver carries no sender (U275). The Tachyon core sends a legacy 80-byte setup. The A17 HAL's device
  path resets the phone, except that A9 re-tests it as the boot's first
  power-up instead of the second.
- **A2 is closed negative (U265).** The captured 48-byte envelope, including
  `+36 = 2` and `+44 = 0x100`, was replayed with the U262 payload; the
  firmware still logs `Setup is not done yet ... type 0` and answers
  `0xf000009`. KCI 6 rejected the exact 128-byte blob too (U188), so the
  named AP-side artifacts are exhausted.
- **The firmware is plaintext Thumb-2.** U178 decoded the image as ARM32
  vectors at `0x1000`, Thumb-2 code linked at `0x10000000`, strings at
  `0xefbdc` and a function-pointer table at `0xe3790`. Rev 8 closed static
  analysis on a high-entropy measurement (U261); rev 9 reopens a bounded pass
  (A5) to find the setup handler and its scratch schema.
- **The setup command carries global scratches.** The firmware's own strings
  say `No global scratches were provided in setup command`, `Global scratch is
  too small to for fallback array allocator` and `Setup is already done, yet
  received another setup command`; its RTTI names
  `flatbuffers::Vector<Offset<platforms::darwinn::vii::RequestAllocation>>`.
  The 128-byte type-5 payload is a one-entry `{address, size}` vector, i.e. a
  global-scratch list. The missing piece is the transport/header, not the
  allocation schema.
- **The A17 envelope and the A14 payload were mixed.** The A14 HAL has
  `SetupFirmware` and its submit walks 24-byte `commands` plus a
  `cluster_id_bitset`; the A17 build has no such string. A1 read the A17
  queue, A2 sent the A14 payload. A6 captures the A14 pair together, CPU-only.
- **The only proven producer is stock Android on slot A.** It needs physical
  Fastboot Mode (Volume Down + Power) and the owner's per-step go; both
  software reboot reasons return to Linux (U252, U255).
- **E0 passes for a compiler-produced tegu DGC0** (12,288 B), and the core
  verifier at `0xb9da8` accepts DGC0/DWS0 (`tools/tpu-graph.py verify`). E1 is
  still negative: RegisterGraph killed the Tachyon core before setup (U256).
  U172's DWN1 finding is about the cheetah util runtime's model and the stock
  cheetah core, which is a stub (U258); the A14 compiler cannot produce a
  DWN1 graph (U257, reproduced off-phone in U259).

## 2026-11-13 (U275: the stock A17 driver carries no setup sender)

`out/stock-a17/janeiro.ko` (434,224 B, 500 function symbols): the usual KCI
surface (`KCI cmd %u response status %u`, `Unrecognized KCI request`,
`edgetpu_kci_fw_info`, `firmware handshake failed`) and
`mobile_firmware_setup_buffer` (a DMA buffer, not the VII setup), but no setup
command, no global-scratch string and no KCI setup code. The stock driver has
the same shape as our copy, so the producer is above it.

## 2026-11-13 (U274: the HAL alone sends no setup - A9 negative)

Fresh boot (PSM `0x4b27091`, GSA state 2), `NO_HOLD=1 HAL_ONLY=1`: the HAL was
the boot's first client power-up, created a detachable group and finalized it
at 34.959 s (`detachable 1 wakelock 0`, `mailbox_attached 0`) with no
`vii-elem` and no setup line. The phone did not reset. A9 is closed.

## 2026-11-13 (U271: gate K re-proven; the firmware has a second address domain)

Gate K was re-run on this boot with the chain up (`NO_DELEGATE=1`) and the
client in the chroot: `createSession: OK`, `setupCommandQueue: OK` (fds 12,13),
`setupResponseQueue: OK` (fds 15,16), `sendCommand: OK`, and an 88-byte
response. Full transcript: `logs/tpu/20261113-gatek-rev10.txt`. The TPU stayed
on its one held power-up; the KCI 21 heartbeat continued every 61 s.

While modeling the container, `0xdd000..0xe0000` turned out to hold aligned
8-byte records whose first words are `0x7ffd754c`, `0x7ffd757c`, `0x7ffd75ac`,
`0x7ffd7650`, `0x7ffd7680`, `0x7ffd7ab0`, `0x7ffd7b50`, `0x7ffd7c0c` - a pointer
domain that is neither a file offset nor the `0x10000000` link base. Thesecond word of each record is `0x80028400`, `0x80a8b0b0`, `0x8003aab0`, ... So
one part of the image carries pointers in a domain that is not the link base.
F1 records it; the setup handler search does not depend on it (U270). No phone
change was made.

## 2026-11-13 (U270: the body loads 977 island addresses, none of the setup strings)

`tools/tpu-fw.py reach out/tpu/edgetpu-janeiro.fw` decodes `0x1000..0xfd000`
at link base `0x10000000` with capstone in `skipdata` mode: 402,918
instructions, 7,265 data words and 10,426 `movw`/`movt`. It resolves **977**
distinct string addresses in `0xe0000..0xfd7c0` that the code loads (for
example `0x100e4f0c` at 22 sites), so the body is the code that uses that
rodata, as U178 read it.

None of the 977 is `0xefbdc`, `0xefd8c`, `0xefddc` or `0xefe18`: the four
setup messages are among the strings no code loads directly. That confirms
U178's index model (the log ring resolves the format string through a
log-site record) and narrows A5 to finding that index. This revision's earlier
"zero references" was a `movw`/`movt` matcher bug, caught by the tool's
self-test and the corrected scan; the corrected result is U270.

## 2026-11-13 (U269: the KCI command set has no setup code, so U266 is void)

`drivers/edgetpu/edgetpu-kci.h` enumerates `KCI_CODE_MAP_TRACE_BUFFER = 5`, then
`KCI_CODE_SHUTDOWN = 7`; there is no code 6. The debug hook that sends an
arbitrary code (`edgetpu-fs.c`, `kci_payload`/`kci_send`) says so in its own
comment: "The KCI command set has no setup command (the enum skips code 6) and
userspace cannot reach KCI at all, so this is the only way to test the one code
the header leaves out." The hook writes the test's number straight into
`cmd.code`, so the firmware received code 6 with each payload.

The uniform response `3` (`KCI_ERROR_INVALID_ARGUMENT`) is therefore an
unknown-code rejection, not a verdict on any setup schema; it would have
answered `3` for every payload. U176/U177/U188/U266 are withdrawn as evidence,
and gate D0f ("KCI 6 accepts a named schema") is removed from the ladder. The
setup command is a VII command, which is why the element code matters (U271).

## 2026-11-13 (U266: KCI 6 with the HAL's exact allocation also fails - WITHDRAWN)

The last untried KCI-6 shape was the HAL's own 512 KiB allocation
`{0xffe80000, 0x80000}`. Five payloads were sent through
`/sys/kernel/debug/edgetpu/janeiro/{kci_payload,kci_send}` with `tpu-hold`
active, in this order:

```
{addr, size}            16 B -> 3
{size, addr}            16 B -> 3
{count, pad, addr, size} 24 B -> 3
{count, addr, size}     20 B -> 3
two-entry vector        32 B -> 3
```

Every send answered `3` (`INVALID_ARGUMENT`) with no firmware log line. The
KCI-6 route is therefore closed for every artifact we can name: the exact
128-byte blob (U188), the carveout/context/mapping vectors (U177), and now the
HAL's own allocation. A new KCI-6 attempt needs a payload derived from the
firmware's handler (A5/A7), not another length or address sweep. No reboot,
slot, flash or NV write was made; the phone stayed on slot B.

## 2026-11-13 (U265: the captured element envelope also gates; the AP side is exhausted)

The first A2 pass was invalid: the phone's `/root/tpu-exec.py` dropped the new
`E36`/`E44` knobs. After copying the patched runner, the harness wrote the HAL's
exact extension fields (`+36 = 2`, `+44 = 0x100`) and the driver's `vii-elem`
dump showed them. The firmware still answered:

```
ERR vii_handler_layer.cc:247 - Setup is not done yet received a command of type 0.
mapped: rsp 0x1 0x0 0xf000009 0x100164f5
```

The Nov 9 replay in `out/bench/chain-dwn1.log` already had the authentic
80-byte form (`+36 = 2`, `+44 = 0x100`, iova `0xfff80000`, size `0x50`) and
gated the same way. The U262 128-byte payload and the 48-byte envelope are
therefore not the missing piece. A4 is also negative: the extracted GSA
`tpu-mgr` and `trusty-hwmgr.elf` expose only image-config, state and wakelock
calls, no setup sender. The stock oracle is the only remaining proven
producer; its preflight sees no fastboot or adb device until the owner enters
Fastboot Mode.

## 2026-11-13 (U264: the HAL's enqueue is a 48-byte struct copy)

The stripped A17 HAL locates `ViiCommandQueue` by its strings: the state check
is `0x1529370` (xref `0x152939c`), the litebuf CHECK is `0x14e366c`, and the
enqueue is `0x1529648`/`0x152977c`. The enqueue computes the 48-byte slot
`base + (tail & 0x3ff) * 0x30`, copies a 48-byte source struct at `0x152989c`
(fields `0..7`, `8..9`, `10`, `11..15`, `16..23`, `24..27`, `28..31`,
`40..43`, `44`), then `dmb ish` and publishes the tail. The size and copy
order are settled; the source values (especially `11..15` and `44`) are not the
A14 setup envelope. The A14 HAL keeps the `SetupFirmware` builder U162 mapped
at `0x14d9a24` and logs `Firmware setup failed for commands[%d],
cluster_id_bitset in hex: %x.` No phone changes, no power-up.

## 2026-11-13 (U263: the live stock services are not setup producers)

The stock `vendor.google.edgetpu_vendor_service` and
`vendor.google.edgetpu_app_service` are running, but their only open fd is the
vendor binder node; neither holds `/dev/edgetpu`. They do not create the setup
by themselves. The Tachyon service is not running in that state.

## 2026-11-13 (U262: the HAL's setup command is type 5, one 512 KiB allocation)

The captured 128-byte command from the HAL's `SetupFirmware` decodes as a
3-field root: a zero-length seq vector, union type **5**, and a one-field
union table holding a vector of one `{address, size}` entry:
`{0xffe80000, 0x80000}`. The earlier U162 13-slot table is a different object
(the serializer's type-1 path). `tools/tpu-setup.py decode` reads it and
`build` reproduces the bytes exactly (sha256 `c60188e5…`). The payload itself
was already replayed (U249) and is not the missing piece; the envelope and the
transport still are.

## 2026-11-13 (U261: the firmware code is not statically recoverable)

The signed body is high-entropy (7.0-7.2 bits/byte from `0x0` to `0xdc000`);
the string/table island (`0xe0000`-`0xfd7c0`) is plaintext and has no direct
code reference to the setup strings. There is no ELF header and no known
compression magic. Rev 9 corrects the conclusion: U178 already decoded the
body as plaintext Thumb-2 linked at `0x10000000`, so the entropy is compiled
code, not encryption. The static pass is viable but must follow the log index,
not the string address (A5).

## 2026-11-13 (U260: the `TPUF` container and image config are parsed)

`out/tpu/edgetpu-janeiro.fw` (1,038,272 B, sha256 `52c1ccc…`, identical to the
A17 copy) has its `TPUF` header at `0x400` and its image config at `0x560`:
carveout `0x93000000`, firmware `0x93000000`+`0xfd000`, privilege 1 (TZ),
three IOMMU mappings (`0x10000000` -> `0x93000000` 16 MiB, `0x11000000` ->
`0x18290000` 64 KiB, `0x11010000` -> `0x1cc00000` 64 KiB), and a 14 MiB
remapped pool at `0x93200000` (TPU VA `0x10200000`). The GSA's `tpu-mgr` only
loads, locks and manages power; it has no setup sender.

## 2026-11-13 (U267: the first static pass names the submit, not the handler)

A5 disassembled the firmware's Thumb-2 body with capstone. The setup strings
have no direct 32-bit reference and no 16-bit offset in `0xe0000..0xf0000`, so
the log-ring index (U178) is the route; the 136-entry pointer table at
`0xe3790` is not the setup dispatch. The A17/A14 HAL's setup submit is the
indirect call through the device vtable (A17 `0x14d9c20`, A14 `0x14d9a4c`);
A6's fake-vtable harness is the next offline step. The handler is not named
yet, so A5 stays open.

## What is next

1. **A5 (offline):** the second pass is a negative (U268): the `0xfbdc`
   literal is not a message index and the `0xe3790` table is not a function
   list. Continue from the fwlog record format or a real function boundary.
2. **A6 (offline):** the A14 caller is `0x14d9600`, the lambda `0x14d9a24`,
   the `blr` at `0x14d9a4c` (`x0 = device`, `x1 = command`, `x2/x3 =
   payload`). Build the fake-vtable harness and dump those registers with no
   `/dev/edgetpu`.
3. **A8 (phone, one reboot):** the signed A14 image (985,344 B, `0xf0000`
   region) with the A14 HAL's exact KCI-6 allocation. The file is staged on
   slot B; the reboot and one KCI-6 send are next. Restore the A17 file on a
   refusal.
4. **A7 (one debugfs run, only if A5 names a payload):** send it once, then
   stop on a `3` with no log line.
5. **A3 (owner; the only proven route):** run the stock oracle with the phone
   in physical Fastboot Mode; read the slot flags first, ask again before
   `--set-active=a`, then capture read-only, roll back to B and take a fresh
   NV backup. Preflight is ready: `out/cheetah/nv-2026-11-12-pre-stock` and
   `out/cheetah/slot-b-2026-11-13` (five images, checksums verified) exist,
   and `tools/tpu-stock-capture check` reports only "no fastboot or adb
   device" until the phone is in Fastboot Mode.
6. **Keep the sentinel:** the two-Ping gate-K regression once per boot series.

## Benchmark: 720p object detection

`out/bench/mosaic12.mp4`: 1280x720, 60 frames, 12 person tiles, SSD
MobileNet 300x300 int8 (`detect.tflite`, threshold 0.5), 10.0 detections per
frame. Every leg decoded the same clip and ran 60 frames.

| backend | mean ms | p50 | p95 | fps | detections/frame |
| --- | --- | --- | --- | --- | --- |
| CPU, 1 thread | 13.33 | - | - | 75.0 | 10.0 |
| CPU, 2 threads | 7.48 | - | - | 133.7 | 10.0 |
| CPU, 4 threads | 4.28 | - | - | 233.9 | 10.0 |
| CPU, 8 threads | 3.28 | - | - | 304.9 | 10.0 |
| GPU, WebGPU (laptop RTX 3070) | 3.00 | - | - | 333.3 | 10.0 |
| Edge TPU | - | - | - | - | blocked |
