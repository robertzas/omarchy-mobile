<!-- SPDX-License-Identifier: MIT -->
# Edge TPU bring-up: status and benchmark

As of 2026-11-09, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`.
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
  virtual device to `PENDING_FIRMWARE_SETUP`. This needs a development gdb
  patch of the `+0x38` dereference at `core+0x5968c`; the code fix is not
  in the client yet.

## The blocker

The core wakes the firmware and sends its one-time firmware setup
(`Sending firmware-setup VII command. type: 1 seq: 0`), and the firmware
refuses it:

```
ERR vii_handler_layer.cc:247 - Setup is not done yet received a command of type 0.
vii-payload 0: 00000014 00000000 000a0000 00080012
```

The element is the same legacy three-field message the HAL sends (fields
48/5/6), not the type-1 setup cheetah's A17 firmware expects, and it
carries no global scratches. No userspace on the phone produces that
message:

- cheetah's own `libtachyon_core.so` is a stub;
- the tegu core (the only real one available) emits the same legacy
  message;
- the stock delegate, run through the Tachyon client path, fails at the
  same setup before sending any command (`create device status: 13`);
- the driver defines no separate VII setup code, and the gxp stub is never
  queried by the core.

The firmware's own strings name the missing piece: a setup command with a
cluster bitset and the global scratch list
(`Setup is not done yet…`, `No global scratches were provided in setup
command.`, `Global scratch is too small…`).

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

1. Test whether the vendor service sends the firmware setup at boot as the
   first TPU user (cold boot, chain up, no client, read `dmesg`).
2. If not, reconstruct the type-1 setup message (cluster bitset plus global
   scratch descriptors) and submit it as the setup element.
3. Once the firmware is set up, run `CreateExecution` (9),
   `BindInputBuffersToTensors` (12), `BindOutputBuffersToTensors` (13) and
   `Invoke` (11), then the 60-frame benchmark above.
