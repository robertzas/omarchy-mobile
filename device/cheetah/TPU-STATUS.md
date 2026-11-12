<!-- SPDX-License-Identifier: MIT -->
# Edge TPU bring-up: status and benchmark

As of 2026-11-11, kernel `7.3.0-rc6-omamobile-push1-g052da70970d6-dirty`.
The details and the experiment log are in [TPU-PLAN.md](TPU-PLAN.md); this
page is the summary.

## 2026-11-12 later: core 0 boot, what is verified and what is ruled out

On `7.3.0-rc6-omamobile-push1-ga78d26f63e56-dirty` the stock 6.1 port
(`/root/gxp-stock.ko`) still powers core 0 to PS0 and never gets the alive
magic. This session verified the host side is correct and ruled out
ten more candidates:

- **Pool contents are right.** The U199 dump at the failure point reads the
  core config (`magic 0`, `top_access 0`, `boot_mode 1`, `boot_status 0`),
  the VD config (`application_id 1`, `vd_is_initialized 0`), the image
  config at IOVA `0x83000` (`version 2`, `privilege 2`, core `0xfac10000`,
  VD `0xfac18000`), and a populated system config (`debug_dump_dev_addr
  0xf5000000`, telemetry `0xf6000000`/`0x10000`).
- **The firmware carveout is already mapped.** Adding `0xfa000000` to
  `gxp_dma_map_core_resources()` returns `-EADDRINUSE`: stock's
  `map_fw_image()` (`gxp-vd.c:508`) maps `fwbufs[0]` for `size *
  GXP_NUM_CORES` (4 MiB). Reverted.
- **The NS regions are not the gap (U197).** The in-tree maps five
  (`0xfa400000`, `0xfa600000`, `0xfa800000`, `0xfaa00000`, `0xfac00000`);
  explicit extra maps for the middle three changed nothing, and the skip
  guard shows the image-config parser already mapped them.
- **The wake doorbell assertion is not it (U198).** Leaving the wake
  doorbell asserted (the in-tree's behavior) instead of clearing it after
  PS0 left the core in PS0 with `doorbell 0x1` and still no magic.
- **Store ordering is not it (U200).** A full `wmb()` before the doorbell,
  ordering the write-combining pool stores against the wake, changed
  nothing.
- **The SSMT/default-domain hypothesis is not it (U201).** Shadowing the
  whole boot window (firmware, `0x83000`, AUR CSRs `0x200000`, sync
  barrier, core/VD cfg slices) in the device's default domain changed
  nothing; the core still never executes.

- **The clock mux switch is not it (U202).** Skipping
  `gxp_pm_force_clkmux_normal()` before the wake changed nothing.
- **janeiro is not it.** The in-tree port boots core 0 with janeiro
  loaded (`core 0 alive`), so janeiro's MMU setup does not block the
  GXP's core.
- **GSA authentication was never running.** The stock port's
  `gsa_authenticate_image()` was a stub (`#define … (0)`) and
  `gxp_firmware_authenticate()` returned early in direct mode, so the
  image was never handed to the GSA. Both are fixed (U203/U204): the
  loader authenticates in direct mode and `gxp-firmware.c` calls
  `gsa_load_dsp_fw_image`. It succeeds for core 0 (`U204: GSA auth loop
  (direct 1, gsa 1)`, no failure logged) and the core still does not
  start. The in-tree's own comment records that its core boots even when
  the GSA rejects the image, so authentication is not what releases it.
- **The core never executes one instruction.** The crash-stage words the
  firmware writes at `cfg+0x80..0x94` still hold the `0x66` pool fill, so
  this is not an early firmware crash. The CSR masks read back `mask1
  0x1f5600ff`, `dedicated 0x101`, `procid 0x0`.
- **The live CSR state is identical to the working in-tree boot (U205).**
  The in-tree, on the same boot and firmware, reads `procid 0x0 reset
  0xfa000000 mask0 0x1 mask1 0x1f5600ff ded 0x101 psm 0x29490 doorbell
  0x0`; the stock reads the same values, with the PSM state 0 inside
  0x29490 and the doorbell left asserted (U198). So the core is in the
  same architectural state in both cases; only its fetch is missing.
- **The NS region is seeded.** The stock logs `NS 0xfa400000 phys
  0xb0000000 size 0x110000` and `seeded NS 0xfa400000 from gxp_fw_core0:
  0x3bbc bytes`, so the firmware's `.data` page holds the image segment.
- **Attaching the VD domain changes nothing (U206).** Setting
  `GXP_MMU_REQUIRE_ATTACH=1` produced no attach error and no change.
- **The wake doorbell must be cleared after PS0 (U207).** The in-tree
  sets the doorbell, polls for PS0 and only then clears it; its U205
  dump reads `doorbell 0x0`, so U198's "the in-tree leaves it asserted"
  was a misreading. The stock now clears after the PS0 poll and reads
  `doorbell 0x0` at the failure point. Still no alive magic.
- **The AUR block has its rate vote and its normal clock mux (U208).**
  The stock's `gxp_pm_blk_on()` discards the ACPM result, so it was
  logged: `AUR state 2: rate 178000, set 0` (accepted; the shim's
  `get_rate` readback is 0, and the in-tree never reads it back), and
  `/sys/kernel/debug/gxp/cmumux1` and `cmumux2` both read `16` =
  `AUR_CMU_MUX_NORMAL`. U202's removal was a no-op because
  `gxp_pm_force_clkmux_normal()` only acts when `curr_low_clkmux` is
  already set.
- **The firmware image is identical in both cases and is exonerated
  (U209, U211).** The image file is `[0x1000-byte header][ELF]`; the
  ELF has four `PT_LOAD` segments (`0xfa000000`, `0xfa001000`,
  `0xfa002000`, `0xfa040e24`) and `e_entry` `0xfa000000`. The bytes at
  the entry segment (`file 0x1000 + 0xc0`) are `06 2c 00 00`, so the
  stock's `fw 0x2c06 0x0` at the reset vector is **correct**, and the
  working in-tree reads the same `0x2c06 0x0` and boots.
- **The fetch address is translated (U212).** Mapping `0xfa000000 ->
  fwbuf` with the raw kernel `iommu_map()` on the device's default domain
  returns `-98` (`-EADDRINUSE`), so the range is already mapped there, and
  the wake produces no sysmmu fault.
- **The core is not held in reset (U213).** `GXP_REG_CORE_ETM_PWRCTL`
  reads `0x0` at the failure point, and reading it while the core is in
  PS3 hangs the calling thread, so the core CSR block is gated before the
  wake and the register is only safe to read at PS0.
- **The reset vector resolves to the firmware (U214).** In the device's
  default IOMMU domain, `iommu_iova_to_phys()` reads `0xfa000000 ->
  0x98000000` (the firmware carveout), `0x83000 -> 0x98410000` and
  `0xfac10000 -> 0x98400000` — all correct — and the wake logs no sysmmu
  fault. The core's fetch address reaches the image in both drivers.
- **The readable AUR block matches, and the rest is unreadable (U215).** At
  PS0 the core block reads `0x4000 0x0`, `0x4004 0x0`, `0x4008
  0xfa000000`, `0x400c 0x1`, `0x4010 0x1`, `0x4014 0x1f5600ff`, `0x4018
  0x0`, `0x401c 0x101` — the in-tree's working values — and a read of
  `0x4020` hangs the calling thread, so the rest of the AUR block cannot
  be audited from the driver. The CMU mux reads `16` at `0x100` and
  `0x610` (normal).
- **The PASID domain was the blocker (U216).** `gxp-vd.c` selects
  `vd->domain` by `#ifdef GXP_USE_DEFAULT_DOMAIN`: the device's default
  IOMMU domain, which is what the working in-tree port maps into, or a
  domain from the PASID pool. The stock was built with the PASID branch,
  so the boot window was mapped in a table the core's fetch context does
  not use. Built with `KCFLAGS=-DGXP_USE_DEFAULT_DOMAIN`, the stock
  driver logs `Core 0 is alive!` after U214 shows the window mapped in
  the default domain. This is the first time the stock 6.1 port has run
  the firmware.
- **The default domain has no gcip IOVA allocator (U217).** With U216 the
  core is alive and `TOP access from core 0 successful!`, then the client
  faults: `gxp_dma_alloc_coherent_buf()` calls `gcip_iommu_alloc_iova()`
  on the default domain, whose `ops` is not a gcip pool ops table (NULL
  dereference; the link reset and the phone rebooted). U217 gives the
  default domain the `dma_alloc_coherent()` address as `dsp_addr` (its map
  step already returns early) and skips `free_iova`. Any other
  `gcip_iommu_alloc_iova()` caller (`gcip_iommu_map()` with iova 0) still
  needs the same treatment.
- **The stock VD wakelock now succeeds end to end (U216+U217).** Built
  with `KCFLAGS=-DGXP_USE_DEFAULT_DOMAIN` plus U217, the client logs
  `allocate_vd cores 1 -> 0 (ok) vdid 1`, `acquire_wake -> 0 (ok)`,
  `tachyon running, holding 4 s`; the driver logs `Core 0 is alive!`,
  `TOP access from core 0 successful!`, then `Mailbox 0 released` and a
  clean `Core 0 powered down`. This is the first full run of the stock
  6.1 VD ABI on this port. A job/DDI execution from a client is the next
  step to a real inference.
- **The vendor runtime chroot is on the phone.** An earlier find was too
  shallow: `/usr/lib/omamobile-vendor/edgetpu/root` holds
  `vendor/lib64/libedgetpu_util.so`, `libdarwinn_hal.so`,
  `libtachyon_core.so` and the rest, built with
  `tools/extract-vendor-chroot -p edgetpu` from the factory image (now
  at `~/omamobile-kernel/downloads/cheetah-cp3a.261005.002.a1-factory-5b5b06ad.zip`).
  The phone-side runtime path is therefore open; no inference has run
  yet.
- **A hand-written stub at the reset vector does not execute either.**
  With `tpu_stub=1` the stock writes a 24-byte A64 stub to
  `0xfa000000` (`str 0x1234beef` to `0xfac10000`, then spin); the U199
  dump still reads core config word 0 `0x00000000`. So in the stock
  flow the core does not fetch from `0xfa000000` at all, while the
  in-tree flow does.

The in-tree port (`gxp-intree.ko`) still boots core 0 reliably (PSM
`0xc493` -> `0x29490`, alive, TOP handshake) on the same firmware, but it
has no VD/queue ABI: its `/dev/gxp` implements only `CREATE_DEVICE`,
`FREE_DEVICE` and `DEVICE_INFO` stubs, so the stock-ABI VD client cannot
drive it, and `tools/tpu-tachyon-client.c` speaks the DMA-heap/HAL path,
not `/dev/gxp`.

Next lead: the AUR's translation of `0xfa000000` in the stock flow. The
CSR state (U205), the image bytes (U211) and the stub test all point the
same way: the core never fetches, although its reset vector, PSM and
configuration match the working in-tree boot. The stock's
`gxp_firmware_run()` and the in-tree's `gxp_core_start()` are now the
remaining diff: dump the in-tree's core config region (the equivalent of
U199's first line) and compare it field by field with the stock's
`00000000 00000000 00000001 00000000`, then print the AUR mapping the
stock installs for `0xfa000000`. If both match, the next oracle is a
stock Android boot, where the bootloader has already started the
firmware and Linux only handshakes (owner-gated, AGENTS.md section 1).

## 2026-11-12 update: the GXP interop path is open; the setup envelope is not

The stock 6.1 GXP driver now has its TPU interop path compiled in
(`HAS_TPU_EXT`, U186). Three fixes got there: the `gxp-tpu-mbx-offset`
property is read as the 32-bit cell it is (`0xc00`, the live stock value,
not the `0xc0000` we had in our DTS), and `HAS_TPU_EXT` is no longer gated on
Android's vendor-hook config. The AUR SysMMUs probe cleanly at boot
(`gxp-iommu` is now in `DTB_OVERLAYS`), the GXP gets its IOMMU domain, and
`/dev/gxp` loads with firmware authentication and the Aurora read.

On a fresh boot the TPU firmware answers the driver's KCI 11 handshake and
the runtime finalizes a device group (`OPEN_DEVICE ret 0`). The remaining
blocker is narrower than before: the A17 HAL's setup element is now captured
(type word `0x000b0000`, 128-byte payload at IOVA `0xffdff000`, and the
element fields `+36 = 2`, `+44 = 0x100` no earlier sweep had) and the firmware
still answers `error_code=9`. Every AP-side knob is sampled now, so the setup
state is created before Linux: the oracle is a stock Android boot or the
bootloader's ARM32 `tpu-mgr`. The last AP-side combination, KCI 6 carrying
the captured HAL blob, also answers `3` (INVALID_ARGUMENT). The missing
producer was found to be the GXP's Tachyon firmware, which no Linux client
had started: a `/dev/gxp` VD client now exists (`tools/gxp-tachyon-start.c`),
and its `-EINVAL` is fixed: the stock DT's `gxp-tpu-mbx-offset` is `0xc0000`
(not `0xc00`), which puts the mailbox at `0x1cec0000`, and the base address is
read with `of_address_to_resource()`. The virtual device now allocates. The
GXP's core 0 still does not execute its firmware (it powers to PS0 with the
image verified in its carveout, but never writes the alive magic), so the
Tachyon producer has not run; a handshake bypass let the wakelock succeed but
no TPU client got further. The last AP-side suspect, the ETM core-reset bit
that `hold_core_in_reset()` sets and never clears, cannot be checked from the
AP: reading it raises a data abort (U192). U193 rules out the reset-vector value
and the wake doorbell (the register holds the IOVA `0xfa000000`, the core is in
PS0, the doorbell is cleared, the GSA authentication and CMU muxes are clean),
so the next lead is the stock path's NS-region/AUR-CSR backing. No inference or
benchmark yet.

## 2026-11-11 update: the GXP core boots

The GXP firmware now starts on core 0: it writes the alive magic and
completes the TOP access handshake (`TPU-PLAN.md` U184). Three fixes got it
there: the sync barrier at IOVA `0x100000` is backed by DMA32 memory instead
of the AUR barrier registers, the AUR core CSR blocks are mapped at IOVA
`0x200000` because the firmware addresses the AUR from a zero base, and the
`0x83000` config page plus the GSA authentication are in place. The phone
stays up and `firmware_start` reads 1.

The blocker has moved: the core idles after the handshake because the host
mailbox and queue interface is not implemented yet. The port target is the
stock driver's `gxp-common-platform.c` ioctl surface with the
`GXP_IOVA_MAILBOX(i)`, `GXP_IOVA_EXT_TPU_MBX` and `GXP_IOVA_TPU_MBX_BUFFER(core)`
mappings.

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

U180 starts that port. The GXP module now parses the firmware and scratchpad
reserved-memory regions, acquires the ACPM AUR domain and exposes a
`bringup` sysfs attribute; probe maps AUR/CMU and registers `/dev/gxp`
without touching a register. It builds as `CONFIG_GXP=m`, matches the
phone's vermagic, and loaded there cleanly. The attribute reads `0`; the
actual BLK_AUR revision/processor-ID read is the next owner-gated step
([TPU-PLAN.md](TPU-PLAN.md) T6.1), because the block's power state at Linux
boot is still unknown. There is no TPU inference or benchmark yet.

U181 builds the rest of the first start offline. The stock A17 `gxp.ko`'s
config-resource function confirms the image-config v2 layout: core config
`0xfac10000` + `0x8000`, VD `0xfac18000` + `0x1000`, system `0xfac20000` +
`0x2000`, with the per-core 8 KiB slices in the 1 MiB scratchpad. The image
is privilege 2 (non-secure), so the host maps every region and no GSA
authentication is needed. `drivers/gxp/gxp.c` now loads `gxp_fw_core0`, maps
the firmware, AUR and config regions, and starts core 0 under a
`firmware_start` sysfs gate; it refuses before touching AUR when no IOMMU
domain is attached. The firmware files are in the phone's `/lib/firmware`,
and `/root/gxp-loader.ko` is staged. The register-free probe module loaded on
the phone and `firmware_start` returned `ENODEV` on the old DT before any
power or register access. The AUR SysMMU overlay is built and test-only; no
firmware start, AUR read or TPU work ran.

U182 (2026-11-11) ran T6.1 with the owner at the phone. The read passed:
Aurora `0x00010104`, cores 0-3 with IDs `0x0-0x3`. The ACPM power-off that
followed reset the phone (channel 0/9 timeouts and thermal -62); it came back
on slot B in about a minute. The loader was changed to leave BLK_AUR powered,
and a second read on the fixed module stayed up with `bringup=1` and
`firmware_start=0`. There is still no firmware start or inference.

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

- **U218 (2026-11-12): the runtime works; the hang is the VII gate.** The
  vendor chroot at `/usr/lib/omamobile-vendor/edgetpu/root` is complete,
  and `/vendor/bin/edgetpu-run` parses the model, gets the runtime's own
  spec (`/dev/edgetpu`, 5 cores, 1 path), and — once the chroot's
  `/dev/janeiro` is a real cdev node rather than the stale regular file
  an earlier tachyon run left behind (a regular file answers `ENOTTY` to
  every ioctl) — gets `CREATE_GROUP` 0, `SET_EVENTFD` 0,
  `FINALIZE_GROUP` 0 and its CSR/queue mmaps, then waits for a VII
  response until killed. That is U29's VII setup gate, not a driver UAPI
  problem. `tpu-core-session` still aborts earlier in
  `edgetpu_android_property_util.cc:284`, "Unknown platform ID on
  Android: 6", before touching a device.
- **The installed `/root/tpu-tachyon-run` (Nov 9) leaks `LD_PRELOAD`.**
  Its host `sleep`, `pkill` and `chroot` children load the bionic shims
  and segfault, so no service starts; the repo's `tools/tpu-exec.py`
  pattern (chroot in-process, clean env) does not have this fault.
- **`modprobe janeiro` before `insmod gxp-stock.ko`.** gxp imports
  `edgetpu_ext_driver_cmd`, which the janeiro module exports: without it
  the insmod fails with "Unknown symbol in module" (seen at uptime 52 s
  and again at 142 s with only `gsa` loaded). `modprobe janeiro`, wait
  for `/dev/janeiro`, then load gxp; that is the sequence that boots core
  0.

- **U219 (2026-11-12): a gxp VD client can reset the phone.** Running
  `/root/gxp-tachyon-start 1 4` after the probe's secure-data warning reset
  the phone: SSH dropped mid-run, no client output, no pstore entry, and
  it came back on the next boot. The warning itself is not fatal: the
  driver logs it with `dev_warn` and continues (the region is for the
  debugfs resource-access test), so the reset's cause is unproven. Treat a
  gxp client run as reset-capable: fresh boot, log streamed, and no second
  run in the same boot. U217's core start remains the last known-good run.
- **U220 (2026-11-12): the vendor chain sends the VII setup.** On a fresh
  boot with the repo's runner (the installed copy was the old leaky
  version), servicemanager, the power HAL, the vendor service, the tachyon
  service, the app service and the Darwinn HAL all started; the HAL's path
  sent the first real VII setup element — a 128-byte payload at
  `0xffdff000`, `0x0b` in the element, the driver's `vii-elem` and
  `vii-payload` dumps — and got the mailbox IRQ and KCI responses (codes
  10 and 21). The delegate still returns status 13, but the setup itself
  now reaches the firmware.
## Next steps

1. Follow U220: the service chain now sends the VII setup. Run a direct
   client after it (or a second delegate) to register a graph, and check
   whether the firmware's setup state persists for that group. No
   inference has run.
2. Or continue the repo's own DDI path: get past the firmware's VII setup
   gate, then `CreateExecution` (9), `BindInputBuffersToTensors` (12),
   `BindOutputBuffersToTensors` (13) and `Invoke` (11), then the 60-frame
   benchmark above.
3. The attended stock capture on slot A stays the gated oracle (AGENTS §1;
   it rewrites `efs`/`persist`/`modem_userdata`).
