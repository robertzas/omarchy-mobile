<!-- SPDX-License-Identifier: MIT -->
# Edge TPU bring-up: status and benchmark

As of 2026-11-11, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`.
The details and the experiment log are in [TPU-PLAN.md](TPU-PLAN.md); this
page is the summary.

## What works

- The vendor Tachyon stack runs on the Linux userspace: servicemanager on
  the vendor binder domain, the Power HAL, the vendor service, the Tachyon
  service with the real tegu core, and the app service.
- A ring client creates a session, sets up the command and response queues,
  imports memory (handles 1 and 2), sends Ping, `AllocateTpu`,
  `ImportMemoryFromFd` (twice), and `RegisterGraph` (type 7) with the
  command union's fields as memory handles (`UORDER=MDMK`).
- `RegisterGraph` passes the core's dependency check and advances the
  virtual device through `PENDING_FIRMWARE_BOOTUP`, `PENDING_FIRMWARE_SETUP`
  and `PENDING_IMPORT_MEMORY` (U171-U173).

## The blocker

The firmware refuses every command until its one-time setup has run, and the
only producer of the setup it accepts is the A17 HAL:

- the Tachyon core sends a legacy setup the firmware parses as **type 0**;
- the cheetah util runtime (`libedgetpu_util.so`) never sends a setup at all
  (`Sync VII command failed: error_code=9`, the pre-setup answer);
- the ring client's hand-built type-1 setup is suppressed by the core once the
  core's own setup has been forced to success, and a direct submission of the
  same payload through the driver still answers `received a command of type 0`;
- the A17 HAL's device path, which is where the type-1 builder lives, **resets
  the phone** (U174; the same reset U154 saw with the A14 HAL).

On top of that, the tegu core's `RegisterGraph` now reaches its VII builder and
dereferences a graph object field the client has never supplied (`+0x8a2a4`,
after the documented `+0x88484` fix), so the register command itself is still
incomplete.

The gate itself reads no payload (U175): 256 zero bytes, an invalid root and a
valid table with a broken union all answer the same `type 0` line and
`0xf000009`. The element's `+11`/`+12` bytes select a different command class
(the line disappears, the response becomes `0x9 0x14140000`) but `+12 = 1` is
not the setup type: a plain element submitted after it in the same group still
hits the gate. So the missing piece is the element envelope the A17 HAL's
`ViiCommandQueue` writes (litebuf vs legacy, and the type it carries), not the
Command flatbuffer's root layout.

U176 moves the target: the firmware's setup is not a VII element. With the
device open, KCI code 6 (the value the in-tree enum skips between 5 and 7)
answers 3 (INVALID_ARGUMENT) for the hook's zeroed 16-byte descriptor, while
codes 0/2/5/20 answer 0 and 40/255 answer 12. Code 6 is the setup command, it
carries the global scratches in its DMA payload, and the driver must send it;
no VII element can set the firmware up.

## Benchmark: 720p object detection

`out/bench/mosaic12.mp4` is 1280x720, 60 frames, 12 person tiles. The model
is SSD MobileNet 300x300 int8 (`detect.tflite`, threshold 0.5), which finds
10.0 objects per frame (max 10), so the 10+ target is met exactly. Every
leg decoded the same clip and ran 60 frames.

| backend | mean ms | p50 | p95 | fps | detections/frame |
| --- | --- | --- | --- | --- | --- |
| CPU, 1 thread | 13.33 | - | - | 75.0 | 10.0 |
| CPU, 2 threads | 7.48 | - | - | 133.7 | 10.0 |
| CPU, 4 threads | 4.28 | - | - | 233.9 | 10.0 |
| CPU, 8 threads | 3.28 | - | - | 304.9 | 10.0 |
| GPU, WebGPU (laptop RTX 3070) | 3.00 | - | - | 333.3 | 10.0 |
| Edge TPU | - | - | - | - | blocked |

The CPU rows are XNNPACK on the laptop; the GPU row is LiteRT
`CompiledModel` WebGPU on the laptop's RTX 3070, not the phone's Mali. The
TPU row is deliberately empty: there is no inference until the firmware
setup succeeds, and no TPU number is claimed.

## Next steps

1. Give the debugfs `kci_send` hook a payload (`kci_payload`, up to
   `PAGE_SIZE`, `cmd.dma.size` = the write length), build the module and send
   code 6 with the captured HAL setup blob and with our flatbuffer; a response
   of 0 (or the firmware's scratch messages) is the setup landing.
2. Read the A17 HAL's `ViiCommandQueue`/`ViiCommandBuffer` enqueue path: the
   element envelope (litebuf flag and the type it carries) is the remaining
   unknown, and `+11`/`+12` are the bytes that change the class.
2. Capture the core's own setup element through a working chain (create
   `/dev/binderfs` first) and compare its 48 bytes with ours byte for byte.
3. Feed the accepted payload through `tools/tpu-setup-payload.py`'s harness
   (`tools/tpu-fwsetup.sh` + `edgetpu-run mapped <code> <p0> <file> <type12>`);
   the firmware's own log line is the oracle, and the `+12` element byte is
   now settable.
4. Once set up, run `CreateExecution` (9), `BindInputBuffersToTensors` (12),
   `BindOutputBuffersToTensors` (13) and `Invoke` (11), then the 60-frame
   benchmark above.
