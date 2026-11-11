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

U176 moved the target to KCI code 6; U177 closes that route. With the device
open, code 6 answers 3 (INVALID_ARGUMENT) for every payload tested: 8-1024
byte structs with the carveout or context scratch, the
`Vector<Offset<RequestAllocation>>` tree in three field layouts, the inline
vector from `tools/tpu-setup-payload.py`, and the firmware's own 256-byte
`mobile_image_config`. No firmware log line follows any of them. The stock
A17 `janeiro.ko` is unstripped and has no setup function or KCI-6 caller, so
the setup is not driver-side either: it is created before Linux, and the
only oracle left is a stock Android boot (attended; it rewrites
`efs`/`persist`/`modem_userdata`) or a full GSA/Trusty `tpu-mgr` reverse
pass.

U178 corrects the reverse pass: the TPU firmware body is **Thumb-2 linked at
`0x10000000`** (the ARM32 vector table at file `0x1000` is only the exception
stub), not AArch64 at `0x93000000`. The GSA's ARM32 `tpu-mgr` is a load/start
and mapping manager (`tpu_get_img_config`, `tpu_set_dvfs_opp`, state machine
at `0x19200`/`0x192c0`) with no setup or KCI-6 sender in the functions
inspected. With the right mode and link base, the setup strings still have **no code
reference** (no `movw`/`movt`, no literal, no `adr`; the nearby pointer words
address other strings), which matches U19/U57's index-table logging.

U179 moves the blocker to the real producer: the A17 `vendor_dlkm.img` has
an unstripped `gxp.ko` (687,680 B, GPL v2) whose loader requests
`gxp_fw_core0`, authenticates it with `gsa_authenticate_image`, and runs the
GXP core. The TPU setup comes from the Tachyon firmware on that core, not
from the AP. Our `drivers/gxp/gxp.c` maps the AUR but loads no firmware, so
the DSP never starts. Google publishes the driver's GPL-2.0 source
(`kernel/google-modules/gxp/gs201`, `gxp-firmware.c`), and our GSA already
has the TPU image-load path, so the next step is a source port, not more
disassembly; the stock-capture runbook is the fallback.

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

1. Port the GXP driver from the GPL source in the order in
   [TPU-PLAN.md](TPU-PLAN.md) U179: `gxp_fw_init`, the DSPF loader with
   `gsa_authenticate_image`, then `gxp_firmware_run` and the mailbox; build
   `CONFIG_GXP=m` and boot `gxp-probe`.
2. If the port stalls, run the attended stock-capture runbook (slot A,
   `tools/nv-backup --check` before and after, AGENTS §1) as the fallback
   oracle.
3. With an accepted setup, run `CreateExecution` (9),
   `BindInputBuffersToTensors` (12), `BindOutputBuffersToTensors` (13) and
   `Invoke` (11), then the 60-frame benchmark above.
