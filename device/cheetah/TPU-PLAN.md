<!-- SPDX-License-Identifier: MIT -->
# TPU / NPU plan: the Edge TPU (Abrolhos / Janeiro) on cheetah (gs201)

Status (2026-11-13, rev 10): **gate K passes on the current boot; gate D is
still the wall; no inference has run and none is claimed.** Rev 10 is a
correction pass, not a reset. Three conclusions change:

1. **KCI has no setup command.** The driver's KCI set runs 0-5 then 7-19, 21
   (`drivers/edgetpu/edgetpu-kci.h`), and the debug hook's own comment says
   "The KCI command set has no setup command (the enum skips code 6)"
   (`edgetpu-fs.c`). U176/U177/U188/U266 sent code 6 through a development hook
   that writes any code into the element; the firmware's `3` is an
   unknown-command rejection, not a verdict on a setup schema. Every KCI-6
   conclusion, including rev 9's "the last named KCI shape is closed", is
   withdrawn. D0f is withdrawn with it.
2. **No experiment has ever sent a non-zero VII code.** The 48-byte element is
   `seq` (u64 @0), `code` (u16 @8), `flags` (u8 @10), `reserved` (@11..15),
   `dma.address` (@16), `dma.size` (@24). Both producers tried wrote code 0:
   the Tachyon core's setup element (`vii-elem: 00000000 00000000 ...`, U248)
   and the HAL element (`00000001 00000000 000b0000 ...`, U249 - seq 1, code 0,
   flags 0x0b). The core's log line "type: 1" is its own command class, not the
   element code. The gate prints `type %d` before it parses anything (U175), so
   its `0` cannot identify the code either.
3. **The island is reachable, but the four setup strings are not.** A
   whole-body Thumb-2 decode (402,918 instructions with `skipdata`, 7,265 data
   words, 10,426 `movw`/`movt`) finds 977 distinct string addresses in
   `0xe0000..0xfd7c0` that the code loads - so the body does address its
   rodata. None of the 977 is `0xefbdc`, `0xefd8c`, `0xefddc` or `0xefe18`: the
   four setup messages are among the strings no code loads directly. That
   *confirms* U178's index model (a log-site table resolves the format string)
   instead of refuting it, and narrows A5 to finding that index. An earlier
   pass of this revision reported "no island references at all"; that was a bug
   in the `movw`/`movt` matcher, recorded in U270. The `0xdd000` records are
   still unexplained (U271), but they are no longer a prerequisite (F1).

The definition of done is unchanged: a model runs on the TPU, its raw output
tensor matches a CPU reference (integer tensors exact unless a tolerance is
stated), the run repeats in one boot, a cold boot reproduces it with no manual
steps beyond the boot unit, and the product is packaged with `pr-check` and
package tests green (DoD-1..5).

## 0. Rules this plan runs under

- **One change per boot.** A new payload, element, firmware or module is tested
  alone; two new things that fail together tell you nothing.
- **No blind sweeps.** A new payload, code or offset needs a measured fact.
  The closed list is section 5.
- **Owner gates are unchanged.** Stock slot A, `--set-active`, any flash, any
  bootloader/radio/`devinfo`/`persist`/`efs*`/`modem*`/`vbmeta` write, and
  **every reboot** are per-step owner gates (AGENTS.md section 1). `push` and
  `reboot-to` stop the modem first; physical Fastboot entry is a human action.
- **Evidence, not narrative.** Every claim names its U-record, file line or
  command. U-numbers below 248 are in TPU-HISTORY.md.
- **The phone stays on slot B.** Software-only steps are read-only on the phone
  or use the development debugfs hooks U176/U177 already used. No step writes
  storage, slots, `devinfo` or NV.

## 1. What rev 10 corrects, and why it took three revisions

Rev 9 assumed the setup command was reachable through one of two AP-side
producers: the VII element (with a header we had wrong) or KCI code 6. Both
assumptions are now falsified by the *driver*, not by another payload.

### 1.1 KCI 6 was never a firmware command

`edgetpu-kci.h` enumerates `KCI_CODE_MAP_TRACE_BUFFER = 5` and
`KCI_CODE_SHUTDOWN = 7`; 6 is absent. `edgetpu-fs.c` (the file that adds
`kci_payload`/`kci_send`) says so in its own comment. The hook exists precisely
because userspace cannot reach KCI and the header leaves the code out, and it
writes whatever number the test passes into `cmd.code`. So U266's five payloads
tested a code with no handler; the uniform `3` is `KCI_ERROR_INVALID_ARGUMENT`
for an unknown code, and it would have answered `3` for every payload. This is
a *negative* for the route, not a schema fact. The plan of record treated it as
the strongest AP-side evidence in the book; it is withdrawn.

U272 makes that concrete on the live device. Through the same hook, on the
held power-up, code 11 (`KCI_CODE_FIRMWARE_INFO`, implemented) with a minimal
payload answered **0**, while code 6 answered `3` - and so did code 21
(`GET_USAGE_V2`, implemented) with a payload too short for it. The hook is
live and a bare `3` carries no schema meaning at all.

U276 then corrects this section's own conclusion. With `kci_scratch` holding
a **mapped** 512 KiB range (`tpu_addr 0xfff80000`), the U262 command rebuilt
with that address answered **12** (`KCI_ERROR_UNIMPLEMENTED`) instead of `3`.
So the firmware dispatches code 6 and parses the payload; the enum gap is a
*driver* fact. On the loaded image (A14) the handler reports unimplemented, so
setup is not KCI 6 there either, but the payload shape is structurally
acceptable - which is exactly the fact the next producer attempt needs.

### 1.2 The element code was 0 in every run

The `vii-elem` dump is the 48-byte element from the VII command queue. Word 0
and 1 are the u64 sequence; word 2 packs `code` (low u16) and `flags` (byte 2).
Every recorded dump has code 0: U248's core element, U249/U250/U265's HAL
element. The stock runtime's "type: 1" string is a different enum. If the
firmware routes setup by element code, every experiment asked for code 0, which
is a command class, not a setup.That is a new, cheap, falsifiable line: sweep
   the **code** (one value per run, not a field sweep) with a payload that is
   otherwise known-good, and watch for a firmware log line other than the gate.

   **Measured, and negative (U273).** Codes 1, 2 and 3 with the U262 payload
   reached the element intact (`vii-elem: ... 000b0001/000b0002/000b0003`) and
   each logged the identical `Setup is not done yet ... type 0`. So the `%d`
   is not the element code (it is the pre-parse default, as U175 said) and the
   setup command is **not a VII command code**. The blanket gate runs before
   the code dispatch, so a setup that arrived as a VII element could never
   pass it either. Setup must reach the firmware from outside `vii_handler_layer`:
   KCI, the mailbox layer, or the GSA. That is the space A9 and A10 probe.

### 1.3 The island is reachable; the setup strings are the exception

`tools/tpu-fw.py reach` is the instrument. On the A17 image it decodes 402,918
instructions, 7,265 data words and 10,426 `movw`/`movt`, and resolves 977
distinct island addresses that the code loads - e.g. `0x100e4f0c` (22 sites),
`0x100e5198` (9), `0x100e51b4` (9). So the body is the code that uses that
rodata, and U178's plaintext Thumb-2 reading holds.

What it does *not* load is any of the four setup messages. That is the same
result U178/U267/U268 reached from the other side, and it means the log ring
resolves those messages through an index (a log-site record with a level, file
and line, and an index into the format strings) rather than through a pointer
in code. So rev 9's A5 method is right and its first two passes were looking
for the wrong half of the mechanism: the index, not the string.

The revision's earlier "zero references to the island" was a matcher bug in
the first two passes (`movw`/`movt` pairs were compared against a broken
high-half map), caught by `tpu-fw.py`'s own self-test and the corrected scan
(U270). `0xdd000` still holds 8-byte records with `0x7ffdxxxx` first words
(`{0x7ffd754c, 0x80028400}`, `{0x7ffd757c, 0x80a8b0b0}`, ...), so a second
load domain exists (U271); F1 explains it, A5 does not depend on it.

### 1.4 What still stands

- Gate K (session, both FMQs, 88-byte reply) - re-proven on this boot,
  `logs/tpu/20261113-gatek-rev10.txt`.
- The gate is before the payload parse; `type 0` is printed for every payload.
- Element `+11`/`+12` are reserved (nonzero gives `0x9 0x14140000`).
- The HAL setup payload is a 128-byte type-5 command carrying one
  `{0xffe80000, 0x80000}` allocation (U262); `tools/tpu-setup.py` reproduces it.
- The stock cheetah core is a stub (U258); the tegu core sends a legacy 80-byte
  setup (U248); the A14 compiler exits 11 off-phone (U259).
- GSA `tpu-mgr` is load/state only (U157/U178).
- Both software Fastboot reasons return to Linux (U252/U255).

## 2. Architecture and current state

| Layer | What it must do | State | Evidence |
| --- | --- | --- | --- |
| L0 Kernel | `janeiro` binds, maps KCI/VII, powers the TPU once, attaches both SysMMUs, creates `/dev/janeiro` and `/dev/edgetpu` | **pass** at boot | `omamobile-tpu.service`, `tpu-hold`, KCI 21 heartbeat |
| L1 Transport | Tachyon session, both FMQ queues, one command round trip | **pass** (gate K) | `logs/tpu/20261113-gatek-rev10.txt` |
| L2 Firmware setup | the one-time setup command is accepted; later VII commands are parsed | **blocked** (gate D) | `Setup is not done yet ... type 0`, `0xf000009` |
| L3 Graph | a graph container the *running* core accepts is registered | **E0 pass; E1 negative before setup** | U256; verifier at `0xb9da8` accepts DGC0/DWS0 |
| L4 Execution | CreateExecution, bind input/output, Invoke writes a tensor | blocked by L2/L3 | none |
| L5 Product | `omamobile-tpu` runs a model, cold boot, acceptance | blocked by L4 | none |

Two kernel-side uncertainties matter for the product and are carried into the
program as K-items: the driver maps the image config's IOMMU ranges and the
SSMT streams while the GSA loads a TZ-privileged image, and **one power-up per
boot** is a hardware property (a second power-up wedges the PSM, U54). Nothing
in the kernel creates the VII setup state.

## 3. Evidence ledger (rev 10)

| Fact | Evidence | Consequence |
| --- | --- | --- |
| Gate K passes on this boot | `logs/tpu/20261113-gatek-rev10.txt`: session, both queues, 88-byte reply | the protocol is not the blocker |
| KCI has no setup code | `edgetpu-kci.h` enum 0-5, 7-19, 21; `edgetpu-fs.c` hook comment | D0f withdrawn; KCI-6 evidence void |
| The KCI hook is live: code 11 answers 0, code 6 answers 3, code 21 answers 3 on a short payload | **U272** on the held power-up | a bare `3` proves no schema; U266 void for a second reason |
| Code 6 + the U262 command + a **mapped** 512 KiB scratch answers `12` (UNIMPLEMENTED) | **U276**: `kci_send code 6 ... -> 12` | the firmware has a code-6 dispatch and accepts the payload shape |
| Every producer wrote VII code 0 | U248 (`00000000 00000000`), U249 (`00000001 00000000 000b0000`) | the code has never been varied |
| The gate prints `type` before parsing | U175: 256 zeros, bad root and valid table read the same | `type 0` identifies nothing |
| The element header is `seq@0, code@8, flags@10, dma@16, size@24` | U264 enqueue copy; `vii-elem` dumps | a code sweep is one knob per run |
| Element +10 is the command class: 0-11 reach the setup gate, 12-255 answer `0x37000003` | **U277**: `T10` sweep over 19 classes, one group each | the last unsampled element field is sampled; no class bypasses the gate |
| The image's only firmware-setup code is the NNAPI DBA HAL | `libdarwinn_dba_hal_runtime.so`: `Hal::CreatePredictor`, `commands[%d]`, `scratch_capacity >= min_capacity`, `firmware_setup_done_`; its submit takes `vector<u64>` scratches | the untried producer is that HAL's CreatePredictor path |
| VII codes 1, 2, 3 all gate identically | **U273**: element carries the code, log still says `type 0` | setup is not a VII code; the gate precedes dispatch |
| The body loads 977 island addresses, none of them the 4 setup strings | `tools/tpu-fw.py reach`: 402,918 insns, 10,426 movw/movt (U270) | the log-index model holds; A5 may proceed |
| `0xdd000` holds 8-byte records with `0x7ffdxxxx` pointers | `tpu-fw.py info`/`reach` raw dump | a second address domain exists |
| The HAL setup payload is type 5, one 512 KiB allocation | U262; `tools/tpu-setup.py` rebuilds it byte-exact | payload schema is known, transport is not |
| The A17 and cheetah `.fw` are identical | U260 sha256 `52c1ccc...` | no newer firmware in the A17 image |
| The A14 image is a different build | A8: 985,344 B, `0xf0000` region, old `recieved` spelling | the A14 set is a matched pair candidate |
| The stock cheetah core is a stub | U258: 1,015,720 B, `createSession` fails `-8` | no local core swap produces setup |
| GSA `tpu-mgr` is load/state only | U157/U178 | GSA is not the producer |
| Both software Fastboot reasons are ignored | U252/U255 | physical entry is required |
| Stock boot rewrites `efs`, `persist`, `modem_userdata` | AGENTS.md section 1 | a fresh NV backup is part of A3 |

## 4. Gate ladder (rev 10)

| Gate | Claim | State | Next |
| --- | --- | --- | --- |
| K | session, both FMQs, command round trip | **pass** | A0.1 regression per boot series |
| A0 | firmware container and image config parsed | **pass** (U260) | F1 adds the segment model |
| N1 | the HAL's 48-byte element is captured offline | **pass** (U75/U264/U265) | none |
| N2 | that element + the U262 payload is accepted | **closed negative** (U265) | none |
| F1 | the log-site index that resolves the 4 un-loaded format strings is found | **open** | F1, section 6.1 |
| D0a | stock Android produces the setup | **owner-gated** (proven) | A3, section 7 |
| D0g | the stock HAL is the boot's *first* power-up in our kernel | **negative** (U274) | none; the HAL sends no setup |
| D0h | the A14 firmware + A14 HAL/core as a matched set | **open** | A8/A10, one reboot |
| D0d | the firmware's setup handler is recovered statically | **open** | A5', after F1's index |
| D0e | the A14 HAL's element + payload are captured together | **open** | A6' |
| D0c | a producer's command is accepted by the running firmware | blocked | D0a/D0g/D0h/D0d |
| E0a | mini model supported by the compiler | pass (U253) | keep |
| E0b | DGC0 container verifies | pass (12,288 B) | keep |
| E1 | RegisterGraph on the live core | **negative** (U256) | retry after D0c |
| E2 | CreateExecution/bind | blocked | after E1 |
| E3 | Invoke returns a tensor | blocked | after E2 |
| E4 | CPU parity | blocked | `tools/tpu-acceptance` |
| E5 | repeat and cold boot | blocked | after E4 |
| E6 | ten-run stability and teardown | blocked | after E5 |
| K1-K4 | kernel work for the product | open, independent | section 6.8 |
| P1-P5 | package, docs, product acceptance | blocked | after E6 |

D0d, D0e and F1 are **offline or debugfs-only**. A9, A8 and A10 need one reboot
each and an explicit go; A3 needs the owner at Fastboot.

## 5. Closed routes (do not reopen without a new artifact)

- **KCI code 6 with any payload.** It is not a firmware command (section 1.1).
  The five U266 shapes, the 128-byte blob (U188) and the vectors (U177) prove
  nothing; do not send code 6 again and do not cite the `3` as a schema result.
- **The A14/A17 HAL device path on a boot where `tpu-hold` already took the
  power-up.** It reset the phone twice (U154, U174). A9 re-tests it only as the
  *first* power-up, with nothing else holding the device.
- **Element-field sweeps (`+4`, `+8`, `+10`, `+12`, `+32..+47`, the 32-slot
  command table).** U175/U250: `+11`/`+12` are reserved; the gate runs before
  the parse.
- **The VII element code (`u16 @8`).** U273: codes 1, 2 and 3 all gate
  identically; the code is not the setup selector and the gate precedes the
  dispatch. Do not sweep it again.
- **The element's +10 command class.** U277: 0-11 answer the setup gate and
  12-255 a different class, with no value in 0..255 setting the firmware up.
  This was the one element field every harness had pinned at 11; it is sampled
  now, so do not sweep it again.
- **U274's negative does not cover the NNAPI HAL.** That boot drove
  `libdarwinn_hal.so`'s device entry. `libdarwinn_dba_hal_runtime.so` is the
  NNAPI implementation and the only component in the image with
  `firmware_setup_done_`; driving its `CreatePredictor` is open.
- **A direct reference to the four setup strings.** The body loads 977 island
  addresses and none of them is these four (U270); the index is the route.
  Repeating the address search, or reading the `0xe3790` table again (U267),
  is closed.
- **The tegu core's setup** (legacy 80 bytes, U248), **the stock cheetah
  core** (stub, U258), **the A14 compiler off-phone** (U257/U259),
  **`reboot-to bootloader|fastboot`** (U252/U255), **the GXP map as a producer**
  (U228/U229), **adopting a bootloader-started image** (GSA reads INACTIVE at
  power-up, U-2026-11-12).
- **A second power-up in one boot.** Hardware: the PSM wedges (U54).
- **The HAL alone as the setup producer.** U274: the HAL creates and finalizes
  a group with no VII command at all, as its own first power-up. Do not re-run
  `HAL_ONLY=1` expecting setup; it is a dead end on this firmware.
- **The stock A17 `janeiro.ko` as a setup sender.** U275: 500 functions, the
  usual KCI strings, no setup command or scratch string, no KCI setup code.
  The stock driver is the same shape as ours; the producer is above it.

## 6. The program to a working TPU

Ordered by cost. Track F is offline and unblocks track D; track D has three
producers, only one of which has to pass; tracks G/E/A/P follow.

### 6.1 Phase F - model the container (offline; no phone)

**F1. The log-site table and the index it resolves.** Goal: read how a log
call names its format string, then get the ID or record for the four setup
messages. This is the only thing between the plan and A5.

Method, in order:
1. `tools/tpu-fw.py reach out/tpu/edgetpu-janeiro.fw`: 977 island addresses
   are loaded; pick 3-4 sites from the printed list (e.g. `0x100e4f0c` at
   `0x100060dc`) and disassemble around them. The call site shows the logging
   convention: which register gets the string, which gets a level, file or
   line, and whether a second argument is an ID.
2. Compare with a site that logs a *message with arguments*, e.g. the strings
   referenced near `0x1000f040`/`0x1000f058`. If every site passes
   `(string, args...)`, the four setup messages are special: they are logged
   through a different macro, and that macro's expansion is the index.
3. If the sites pass `(id, args...)` instead, the island is the *ID table*:
   build `offset -> index` from the loaded addresses and read the index the
   gate site uses. Search the body for that small integer.
4. `tools/tpu-fw.py info` still records the raw image-config words and the
   `0xdd000` records, so a segment/domain answer can be read off the same dump
   if the logging convention turns out to be indirect (U271).

Pass: a named log-site record format and the setup messages' index or ID.
Stop: two passes over the referenced sites with no consistent convention; then
D0d waits for a new artifact (a stock capture or a newer image). Risk: CPU
only, no phone.

**F2. Instrument the negatability.** Extend `tools/tpu-fw.py` only with checks
its self-test can build synthetically (no firmware committed). Every number the
plan quotes from the image must be reproducible by one command.

### 6.2 Phase D - name the producer

Three producers, ranked by cost. They are alternatives; only one must pass.

**A9 (D0g). The HAL-first boot (one reboot, no stock Android).**
Hypothesis: U154/U174's resets were the *second* power-up, because the chain
starts `tpu-hold` and then the HAL opens `/dev/edgetpu` and powers up again.
That is exactly the PSM wedge U54 documents, and it explains a reset with no
kernel oops.

Method:
1. Prepare a boot-time variant of `tools/tpu-tachyon-run` that starts the
   vendor service, the app service and the Darwinn HAL **without** `tpu-hold`
   and without the Tachyon service (`HAL_ONLY=1`, `NO_HOLD=1`), so the HAL's
   own open is the boot's first power-up.
2. Ask for the reboot, stop the modem first (AGENTS.md section 2), and boot.
3. Run the variant once; capture `dmesg | grep -E 'vii-elem|vii-payload|setup'`
   and the HAL's log.
4. Pass: a `vii-elem` with a non-zero code, or a firmware line other than the
   gate. Stop: a reset (the hypothesis is wrong; recover with Power held ~30 s,
   record it, and do not retry in the same boot).
Risk: one reboot; a TPU-side reset can take the phone down. No flash, slot or
NV write. The phone is a development unit; the modem is stopped first.

**Measured, and negative (U274).** On a fresh boot (PSM `0x4b27091`, GSA
state 2) with `NO_HOLD=1 HAL_ONLY=1`, the HAL opened the device first, created
a detachable group and finalized it at 34.959 s (`detachable 1 wakelock 0`,
`mailbox_attached 0`) with no `vii-elem` and no setup line. The phone did not
reset, so U154/U174's resets were not reproduced either. The HAL alone is not
a producer; the remaining offline lead is the stock A17 `janeiro.ko`, the only
driver build that might carry a setup sender.

**A9b. The VII code sweep, one code per boot (only if A9 shows a live HAL
path).** The code is the only element field never varied. Codes to try, one per
run, with the U262 payload: 1, then 2, then 3. Pass: a firmware line other than
the gate for a code. Stop: the gate line for all three; record and stop. This
is not a blind field sweep: it is the one knob the evidence says was constant.

**A8/A10 (D0h). The A14 set as a matched pair (one reboot, firmware swap).**
The A14 image (985,344 B, `0xf0000` region) pairs with the A14 HAL's setup
builder. A8 covers the image + the KCI-6 allocation (now withdrawn, so the
allocation is irrelevant). A10 extends A8 to the A14 **core** as well: the core
is the component that sends setup (U248), so a matched A14 core + A14 image is
a producer pair, not just a payload pair. Stage all three (image, HAL, core)
before the reboot and keep the A17 restore set in the same directory.

**A5' (D0d). Static recovery, gated on F1.** Once F1 names a domain, repeat the
message-index search with that base. Do not repeat the `0xe3790` table pass
(U267/U268): it is not a dispatch table.

**A6' (D0e). The A14 HAL's element + payload together.** The A14
`SetupFirmware` caller is `0x14d9600`, its submit lambda `0x14d9a24`, the `blr`
at `0x14d9a4c` passes `x0 = device`, `x1 = command`, `x2/x3 = payload`. The
harness is a fake device whose `+0x18` vtable slot captures those registers;
no `/dev/edgetpu`, no power-up.

**A3 (D0a). The stock oracle (owner-gated, the only *proven* producer).**
Section 7. Run it whenever the human is at Fastboot; A5'/A6'/A9 never delay it.

### 6.3 Phase G - graph format (after D0c)

**G1. Match the container to the live core.** `tools/tpu-graph.py verify`
accepts DGC0/DWS0, matching the core verifier at `0xb9da8`; the 12,288-byte
mini DGC0 passes. The DWN1 graph in `out/bench/` does not, and U172's finding
is about the cheetah util runtime's model, not this core. After D0c: retry the
verified DGC0 once, record which core the session starts, and only then chase a
DWN1 producer.

**G2. A repeatable graph producer.** For the product we need a compile step,
not a cache extraction. Three candidates, in cost order: (a) the vendor
compiler on-device in the chroot (U253 shows its cache holds a real DGC0);
(b) the same compiler on the laptop with a bionic/glibc harness; (c) ship
precompiled models only. Pick (a) if it can be scripted without the HAL's
device path; otherwise (c) ships first and (b) is a follow-up.

### 6.4 Phase E - execution (E1-E3)

With D0c and G1: register the graph, create the execution, bind the input and
output from `/dev/dma_heap/system`, Invoke, and dump the raw output. A status 0
without a non-empty tensor is not E3. One attempt per boot; record the raw
reply and the tensor hash. If the core dies, capture the core file (CORES=1)
and the last 200 dmesg lines before retrying.

### 6.5 Phase A - acceptance (E4-E7)

`tools/tpu-acceptance compare --tpu ... --cpu out/tpu/mini-fc-u8-cpu.bin
--dtype uint8 --shape 1,1 --model ... --label mini-fc-u8`. Integer tensors are
exact. Then E5: twice in one boot, then a cold slot-B boot, then E6: ten runs,
watching for a second power-up, a leaked handle or an IOMMU fault. E7 adds
teardown: close the session, check `clients`/`mappings` are empty, unload
nothing (never `rmmod` mid-boot), and confirm the KCI heartbeat continues.

### 6.6 Phase P - product

**P1. `omamobile-tpu` runtime.** `omamobile-tpu run MODEL INPUT` with the
vendor chroot, root-only at first; output tensor plus JSON report from
`tpu-acceptance`. No vendor blob or model in git.
**P2. Boot unit.** `omamobile-tpu.service` already loads `janeiro`; add a
`--self-test` that runs gate K plus, once E4 lands, the mini model, and records
the result for `phone-smoke`.
**P3. Permissions and packaging.** The device is `root:1000 0660`; the product
path needs a documented group (`omamobile-tpu`) and a udev rule, or a daemon
that owns the device. Package it in `omamobile-device-cheetah` next to
`tpu-hold`; `tools/pr-check` and the package tests are the gate.
**P4. Docs.** `docs/DEVICES.md` gets a TPU row (what works, what does not);
TPU-STATUS keeps the honest "no inference" line until E4.
**P5. Security and trust.** The firmware is signed and TZ-loaded; models are
not. State plainly that a model is code for the TPU and that untrusted models
stay out of the product path until the graph verifier is trusted.

### 6.7 Phase T - performance (after E4)

The 720p SSD benchmark is prepared in `out/bench/` (1280x720, 60 frames,
`detect.tflite`). CPU numbers are in TPU-STATUS.md. Measure the TPU only after
a correct tensor exists, then record mean/p95, detections per frame, thermal
and battery. Do not tune before parity.

### 6.8 Phase K - kernel work the product needs (independent of gate D)

- **K1. One power-up per boot, enforced.** Today the constraint is tribal
  knowledge (U54). Document it in the driver and make `tpu-hold` the only
  first-power-up path; a second `edgetpu_pm_get` should fail loudly, not wedge.
- **K2. IOMMU fault handling.** A fault must kill the client, not the phone:
  check the domain's fault handler on a bad iova before E1 is retried.
- **K3. Teardown and recovery.** Closing a session must release the group,
  mapping and wakelock (E7 checks it). A firmware crash must be recoverable
  without a reboot if the PSM allows it; until then, record the crash and stop.
- **K4. Power and thermal.** The driver's thermal and idle paths are untested
  with a real workload; measure after E4, not before.

## 7. Stock-oracle runbook (owner-gated)

Every step is a separate go. A stock boot rewrites `efs`, `persist` and
`modem_userdata`; take a fresh read-only NV backup after it.

1. **Preflight (read-only).** `tools/tpu-stock-capture check`; confirm
   `out/cheetah/nv-2026-11-12-pre-stock` and the saved slot-B image set
   (`out/cheetah/slot-b-2026-11-13`, five images, `SHA256SUMS`). Stop if either
   is missing or a checksum differs.
2. **Physical Fastboot.** The human holds Volume Down, then Power, about 20 s.
   Confirm `fastboot devices`. Send nothing else first.
3. **Slot flags (read-only).** `fastboot getvar current-slot`,
   `slot-successful:a`, `slot-successful:b`. Expect `b`/`yes`. Stop otherwise.
4. **Ask explicitly for `fastboot --set-active=a`.** Record the flags again.
5. **Boot stock and capture (read-only).** `tools/tpu-stock-capture capture
   PRIVATE_DIR`: dmesg from boot, `getprop`, `ps`, the first
   `vii-elem`/`vii-payload`, the services that open `/dev/edgetpu`, the
   firmware hash. Never install, root or flash to get a log.
6. **Rollback.** `fastboot --set-active=b`, confirm, boot the saved set, verify
   SSH and `omamobile-boot-success`, then a fresh `tools/nv-backup`. On the
   stock recovery screen choose neither "Try again" nor "Factory data reset":
   hold Volume Down + Power for Fastboot.
7. **Record.** Flags before/after, boot times, the private capture path (never
   its contents), the next action.

## 8. Software-only runbooks

### F1 / A5' (laptop, no phone)

1. `tools/tpu-fw.py info out/tpu/edgetpu-janeiro.fw`; record the config words
   and the entropy boundary.
2. `tools/tpu-fw.py reach out/tpu/edgetpu-janeiro.fw`; expect 977 referenced
   island addresses and `want 0xefbdc: NOT referenced` for the gate message.
3. Disassemble around three referenced sites; write down the logging
   convention (string register, level, line, any ID).
4. Build `offset -> index` for the referenced strings and read the gate site's
   index; search the body for it.
5. Stop at a named index; write U272.

### A6' (laptop, no phone)

1. Build the fake-vtable harness after `tools/tpu-darwinn-probe.c`; link only
   `libdl`, `liblog`, `libm`, `libc`; run under `qemu-aarch64-static` if needed.
2. Fake the 24 KiB command queue and buffer; call only the setup submit.
3. Dump `x1` (command), `x2/x3` (payload) and the element; compare with U262.

### A9 (phone, one reboot, owner's go)

1. Stage the `NO_HOLD=1 HAL_ONLY=1` variant; verify by `sh -n` and a `--dry-run`
   mode that prints the commands without starting anything.
2. Stop the modem; ask for the reboot; boot.
3. Run once; capture dmesg and the HAL log. Stop on a reset.

## 9. State, risks and recovery

- **State at rev 10.** Phone on slot B, kernel
  `7.3.0-rc6-omamobile-push1-ga78d26f63e56-dirty`, uptime ~3 h;
  `omamobile-tpu.service` loaded `janeiro`; `tpu-hold` holds the one power-up;
  gate K re-proven at 2026-11-13 12:4x UTC; gate D blocked. No model output.
- **Risk register.** Stock boot: NV rewrite (owner-gated, fresh backup). HAL
  path: phone reset (closed except A9's first-power-up variant). Second
  power-up: PSM wedge. Binder chain: stale nodes (mount binderfs, U236).
  Offline work: none on the phone.
- **Recovery.** A9/A7 are undone by a reboot; a graph/execution by closing the
  session; a package by the previous rootfs; stock by `--set-active=b` plus the
  saved slot-B set and a fresh NV backup. No step is retried before its result
  is recorded.

## 10. Decision tree

```
gate K fails? -> stop: driver/session regression, not setup.
gate K passes
  -> F1 names the log index?
       |--yes--> A5' names the handler --> A7' payload --> D0c
       |--no---> A9 HAL-first boot --pass--> D0c
       |                 |--reset--> A10 (A14 set) --pass--> D0c
       |                                   |--no--> A3 stock oracle (owner)
  -> D0c passes -> G1 verify DGC0 -> G2 graph producer -> E1 register
     -> E2 bind -> E3 invoke -> E4 parity -> E5 repeat/cold boot
     -> E6 ten runs -> E7 teardown -> P1-P5 product -> T performance.
```

The stock oracle is never blocked by the offline tracks; run it whenever the
human is at Fastboot. A9 is the cheapest producer that needs no stock Android.

## 11. Immediate actions (ordered)

1. **F1/A5' (offline, next session):** `tools/tpu-fw.py` exists and reproduces
   U270 (977 loaded addresses, 0 of the 4 setup strings); disassemble three
   referenced log sites, write the convention down, and read the gate site's
   index. Write U272.
2. **A9 (phone, owner's go):** stage the `NO_HOLD=1 HAL_ONLY=1` variant and its
   dry run; one reboot tests the hypothesis that the HAL's resets were the
   second power-up.
3. **A9b (only after A9):** the VII code sweep, one code per run, 1/2/3.
4. **A10/A8 (phone, owner's go):** stage the A14 image, HAL and core together;
   one reboot tests the matched set.
5. **A3 (owner; the only proven route):** the stock oracle, section 7.
6. **K1/K2 (offline kernel work):** document the one-power-up rule and add the
   IOMMU fault check; no phone needed.
7. **A0.1 sentinel:** the two-Ping gate-K regression once per boot series. Done
   for this boot: `logs/tpu/20261113-gatek-rev10.txt`.

## Appendix A - signed firmware container (U260)

`out/tpu/edgetpu-janeiro.fw`, 1,038,272 B, sha256
`52c1cccdf0e243d12fbc9f3b3911fe9c780a11d9a5bfda61744c7c3fdaded7c3`.

| Field | Value |
| --- | --- |
| Magic at `0x400` | `TPUF` (`0x46555054`), generation 1 |
| Length at `0x40c` | 1,034,176 (file 1,038,272) |
| Image config at `0x560` | carveout `0x93000000`, firmware `0x93000000`, size `0xfd000` |
| Remapped region | `0x93200000`, size `0xe00000` (14 MiB), per the dumped words |
| Body entropy | 7.0-7.2 bits/byte over `0x0..0xdc000`; island `0xe0000..0xfd7c0` plaintext |
| Island | 1,199 strings; code loads 977 addresses, none of the 4 setup messages (U270) |
| Second domain | `0xdd000`: 8-byte records, first words `0x7ffdxxxx` (F1) |

`mobile_firmware.h` gives the struct (`mobile_image_header`,
`mobile_image_config`); the first three config words match the rev-9 parse, and
`tpu-fw.py info` prints the rest raw rather than assuming offsets.

## Appendix B - the captured HAL setup command (U262)

128 bytes, `out/tpu/setup-hal-128.bin`, sha256
`c60188e5c31bfed2925ef1c298f1c88b530b94377d1eaf01634c5e2aba74d1fa`.

```
root table 20, vtable 10, vtable size 10, table size 18
  field 0: offset 8 @ 28 -> zero-length vector at 76 (seq)
  field 1: offset 7 @ 27 = union type 5
  field 2: offset 12 @ 32 -> table 44 (vtable 38, 1 field)
      field 0 -> vector at 52: length 1
        entry 0: address 0xffe80000 size 0x80000
```

`tools/tpu-setup.py build` reproduces these bytes exactly. The allocation is
exact; the transport (VII code vs envelope) is unknown, and KCI is not a
transport for it (section 1.1).

## Appendix C - VII element layout and what was sent

48-byte element from the command queue (`edgetpu-mailbox.c` dumps 12 words):

| Offset | Field | Sent in every run |
| --- | --- | --- |
| 0 | `seq` (u64) | 0 or 1 |
| 8 | `code` (u16) | **0** (never varied) |
| 10 | `flags` (u8) | 0 or 0x0b |
| 11..15 | reserved | nonzero gives `0x9 0x14140000` |
| 16 | `dma.address` (u64) | payload iova |
| 24 | `dma.size` (u32) | payload length |
| 28..47 | payload/other | per-run |

The payloads tried with code 0: the 128-byte type-5 command, the 80-byte legacy
message, allocation vectors and zero pages. All answered the gate
(`0xf000009`). Appendix C of rev 9 (KCI-6 payloads) is withdrawn.

## Appendix D - where the evidence lives

- [TPU-HISTORY.md](TPU-HISTORY.md): every prior revision and the U-log.
- `device/cheetah/TPU-STATUS.md`: the one-page status.
- `logs/tpu/`: gate-K and run logs (gitignored; check for identifiers).
- `out/tpu/`: the model, graph, payloads, firmware and disassembly (gitignored).
- Tools: `tools/tpu-fw.py`, `tools/tpu-setup.py`, `tools/tpu-graph.py`,
  `tools/tpu-acceptance`, `tools/tpu-compile.c`, `tools/tpu-mini-model.py`,
  `tools/tpu-stock-capture`, `tools/tpu-exec.py`, `tools/tpu-tachyon-run`,
  `tools/tpu-tachyon-client.c`, `tools/tpu-setup-payload.py`.
