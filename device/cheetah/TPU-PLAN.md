<!-- SPDX-License-Identifier: MIT -->
# TPU / NPU plan: the Edge TPU (Abrolhos / Janeiro) on cheetah (gs201)

Status (2026-11-13, rev 11): **gate K passes on the current boot; the vendor
DBA HAL now runs on this port for the first time; gate D is still the wall; no
inference has run and none is claimed.** Rev 11 is a re-evaluation, not a
reset. Three things change:

1. **The DBA service is not an NNAPI HAL.** Its AIDL surface is Google's own
   `com.google.edgetpu.dba.IDevice` with `createSession` → `IDeviceSession` →
   `createCompilationFromFile` → `ICompilation` (U280). There is no
   `prepareModel` in it, so the NNAPI model the earlier revision imagined
   building is not needed. The service is a *session* interface, and a session
   is cheap to ask for.
2. **That service now runs.** It used to abort with `Unknown chip_version found
   from device`; the value came from `ro.board.platform`, which our property
   shim answered `mmio` (the delegate's driver-provider value). With `gs201`
   for that one process it loads `libdarwinn_dba_hal_runtime.so` and stays up
   (U279). It is the only component in the image that carries the firmware's
   setup path (`Firmware setup failed for commands[%d], cluster_id_bitset in
   hex: %x.`, `firmware_setup_done_`).
3. **`chip_model` was necessary, not sufficient.** The attribute is live
   (`/sys/class/edgetpu/janeiro/chip_model` = `janeiro_a0`, U281) and both HALs
   look for such an attribute, but the abort that mattered was the property.
   The attribute stays for the HAL's device path; it is not the trigger.

The definition of done is unchanged: a model runs on the TPU, its raw output
tensor matches a CPU reference (integer tensors exact unless a tolerance is
stated), the run repeats in one boot, a cold boot reproduces it with no manual
steps beyond the boot unit, and the product is packaged with `pr-check` and
package tests green (DoD-1..5).

## 0. Rules this plan runs under

- **One change per boot.** A new payload, element, firmware or module is tested
  alone; two new things that fail together tell you nothing.
- **No blind sweeps.** A new payload, code or offset needs a measured fact, or
  it is a sweep with a stated hypothesis, a bounded set and an oracle. The
  closed list is section 5.
- **The firmware's own log is an oracle.** Every VII attempt is answered either
  by the gate (`Setup is not done yet ... type 0`, `0xf000009`) or by a
  different line. A different line is the signal; the reply word alone is not.
- **Owner gates are unchanged.** Stock slot A, `--set-active`, any flash, any
  bootloader/radio/`devinfo`/`persist`/`efs*`/`modem*`/`vbmeta` write, and
  **every reboot** are per-step owner gates (AGENTS.md section 1). `push` and
  `reboot-to` stop the modem first; physical Fastboot entry is a human action.
- **One power-up per boot.** The first opener powers the TPU; a second power-up
  wedges the PSM (U54). A service that opens the device is the boot's first
  power-up only when nothing held it first (`NO_HOLD=1`).
- **Evidence, not narrative.** Every claim names its U-record, file line or
  command. U-numbers below 248 are in TPU-HISTORY.md.
- **The phone stays on slot B.** Software-only steps are read-only on the phone
  or use the development debugfs hooks U176/U177 already used. No step writes
  storage, slots, `devinfo` or NV.

## 1. What rev 11 corrects, and why

### 1.1 The DBA HAL is a session API, not an NNAPI model API

`com.google.edgetpu.dba-V1-ndk.so` and the service binary carry the full
interface set (U280):

| Interface | Methods the strings name |
| --- | --- |
| `IDevice` | `createSession` (reply type `IDevice.CreateSessionReturn`), `getCapabilities` |
| `IDeviceSession` | `createCompilationFromFile`, `ImportHardwareBuffer`, `ReleaseBuffer` |
| `ICompilation` | `CreateExecutionResult`, `CreateRepeatedExecution`, `DispatchFencedExecution` |
| config types | `SessionConfig`, `CompilationConfig`, `BufferConfig`, `Request`, `MemoryRegion`, `TensorShape` |
| callbacks | `IFencedExecutionCallback`, `IRepeatedExecutionCallback` |

The service binary also names its source, `vendor/google/darwinn2/dba/service/
edgetpu_device_session.cpp`, and `EdgeTpuDeviceSession::createCompilationFromFile`.
So the shortest path to the vendor HAL's own setup is:

```
raw binder -> com.google.edgetpu.dba.IDevice/default
  createSession(SessionConfig)          -> IDeviceSession
  createCompilationFromFile(path, cfg)  -> Hal::CreatePredictor -> firmware setup
```

`createCompilationFromFile` takes a *path*, which we already have
(`/vendor/etc/model.tflite`, the mini model, `detect.tflite`). No NNAPI `Model`
parcel, no compiler harness, no model proto.

### 1.2 Setup lives inside the DBA HAL, and only there

`libdarwinn_dba_hal_runtime.so` (3,785,000 B, only export
`GetDarwinnHalFunctions@@VER_1.0` at `0xf772c`) carries:

- `Firmware setup failed for commands[%d], cluster_id_bitset in hex: %x.` - the
  A14-shaped setup submit (24-byte commands + `cluster_id_bitset`);
- `firmware_setup_done_`, and the wakelock callback that clears it;
- `Hal::CreatePredictor` (two lambdas named in RTTI).

No other component in the image has a setup builder. The Tachyon core sends a
legacy 80-byte element with code 0 and is gated (U248); the A17 HAL's device
path sends nothing at all (U274); the stock driver has no sender (U275).

### 1.3 The abort that stopped the DBA HAL was our own property

The service read `ro.board.platform` as a **chip version** and got `mmio`, the
value the delegate needs for its driver-provider lookup. Two consumers, two
meanings, one property. The cmdline-keyed shim now answers `gs201` for
`com.google.edgetpu.dba-service` as well as the Tachyon service (U279), and the
service loads its HAL:

```
[EdgeTpuDbaHal] Loaded Edgetpu DBA HAL binary with baseline cl number 532148581 ...
InitGoogle completed for LibDarwinnDbaHal at LogLevel: 1
```

### 1.4 `chip_model` is a real attribute and not the trigger

Both HALs contain `<class device>/chip_model` and the strings `janeiro`,
`janeiro_a0`, `abrolhos`, `abrolhos_b0`; the driver had no such attribute, so
it was added (read-only, `janeiro_a0`) and is live (U281). The DBA abort was
still the property (1.3). Keep the attribute for the HAL's device path; do not
re-run the sysfs experiment expecting setup.

### 1.5 What still stands from rev 10

- Gate K (session, both FMQs, 88-byte reply) - re-proven on this boot,
  `logs/tpu/20261113-gatek-rev10.txt`.
- The VII gate precedes any payload parse; `type 0` is printed for every
  payload, including codes 1-3 (U273).
- Element `+10` is the command class: 0-11 gate, 12-255 a different class
  (U277).
- The HAL setup payload is type 5, one `{0xffe80000, 0x80000}` allocation
  (U262); `tools/tpu-setup.py` reproduces it byte-exact.
- KCI has no setup code; code 6 is a dispatch that answers
  `UNIMPLEMENTED` on the loaded image (U269/U276).
- The stock cheetah core is a stub (U258); the tegu core sends the legacy
  setup (U248); the A14 compiler exits 11 off-phone (U259).
- GSA `tpu-mgr` is load/state only (U157/U178).
- Both software Fastboot reasons return to Linux (U252/U255).

## 2. Architecture and current state

| Layer | What it must do | State | Evidence |
| --- | --- | --- | --- |
| L0 Kernel | `janeiro` binds, maps KCI/VII, powers the TPU once, attaches both SysMMUs, creates `/dev/janeiro` and `/dev/edgetpu`, exposes `chip_model` | **pass** | `omamobile-tpu.service`, `tpu-hold`, KCI 21 heartbeat, `U281` |
| L1 Transport | Tachyon session, both FMQ queues, one command round trip | **pass** (gate K) | `logs/tpu/20261113-gatek-rev10.txt` |
| L2a Service | the vendor DBA service publishes `IDevice/default` and links the DBA HAL | **pass** (U279) | `dba service pid: 4855`, `InitGoogle completed for LibDarwinnDbaHal` |
| L2b Firmware setup | the one-time setup command is accepted; later VII commands are parsed | **blocked** (gate D) | `Setup is not done yet ... type 0`, `0xf000009` |
| L3 Graph | a graph container the *running* core accepts is registered | **E0 pass; E1 negative before setup** | U256; verifier at `0xb9da8` accepts DGC0/DWS0 |
| L4 Execution | CreateExecution, bind input/output, Invoke writes a tensor | blocked by L2b/L3 | none |
| L5 Product | `omamobile-tpu` runs a model, cold boot, acceptance | blocked by L4 | none |

Two kernel-side uncertainties matter for the product and are carried into the
program as K-items: the driver maps the image config's IOMMU ranges and the
SSMT streams while the GSA loads a TZ-privileged image, and **one power-up per
boot** is a hardware property (U54). Nothing in the kernel creates the VII
setup state - the producer is in userspace (L2a).

## 3. Evidence ledger (rev 11)

| Fact | Evidence | Consequence |
| --- | --- | --- |
| Gate K passes on this boot | `logs/tpu/20261113-gatek-rev10.txt`: session, both queues, 88-byte reply | the protocol is not the blocker |
| The DBA service's abort was `ro.board.platform` = `mmio` | U279: string at 0x4b77 beside the error; shim answered `mmio` | fixed with `gs201` for that process |
| The DBA service now runs and loads its HAL | U279: `dba service pid: 4855`, `InitGoogle completed for LibDarwinnDbaHal` | the only in-image setup producer is live |
| The DBA interface is session-based, not NNAPI | U280: `IDevice.createSession`, `IDeviceSession.createCompilationFromFile`, `ICompilation` | a small binder client can trigger the HAL |
| `createCompilationFromFile` takes a path | U280: service string | no NNAPI `Model` parcel is needed |
| The DBA HAL carries the setup path | `Firmware setup failed for commands[%d], cluster_id_bitset in hex: %x.`, `firmware_setup_done_`, `Hal::CreatePredictor` | setup runs inside the HAL, not in the driver |
| `chip_model` is live and solo-insufficient | U281: `/sys/class/edgetpu/janeiro/chip_model` = `janeiro_a0`; abort persisted until the property change | keep it; it is not the trigger |
| The VII gate precedes the payload parse; codes 1-3 gate | U273 | a new payload alone will not pass gate D |
| Element +10 is the command class: 0-11 gate, 12-255 another class | U277: 19 classes sampled | the element surface is sampled; stop sweeping it |
| The body loads 977 island addresses, none of the 4 setup strings | `tools/tpu-fw.py reach`: 402,918 insns, 10,426 movw/movt (U270) | the log-index model holds; A5 may proceed |
| The HAL setup payload is type 5, one 512 KiB allocation | U262; `tools/tpu-setup.py` rebuilds it byte-exact | payload schema known; transport not |
| The A17 and cheetah `.fw` are identical | U260 sha256 `52c1ccc...` | no newer firmware in the A17 image |
| The stock cheetah core is a stub | U258: `createSession` fails `-8` | no local core swap produces setup |
| GSA `tpu-mgr` is load/state only | U157/U178 | GSA is not the producer |
| Both software Fastboot reasons are ignored | U252/U255 | physical entry is required |
| Stock boot rewrites `efs`, `persist`, `modem_userdata` | AGENTS.md section 1 | a fresh NV backup is part of R3 |

## 4. Gate ladder (rev 11)

| Gate | Claim | State | Next |
| --- | --- | --- | --- |
| K | session, both FMQs, command round trip | **pass** | A0.1 regression per boot series |
| A0 | firmware container and image config parsed | **pass** (U260) | F1 adds the segment model |
| D1 | the vendor DBA service publishes `IDevice/default` and stays up | **pass** (U279) | R1 uses it |
| D2 | a raw-binder client resolves `IDevice/default` and gets an AIDL reply | **open** | R1, step 3 |
| D2b | `createSession` returns a session binder | **open** | R1, step 4 (code + config sweep) |
| D3 | `createCompilationFromFile` runs the HAL's `CreatePredictor` | **open** | R1, step 5 |
| D3b | the firmware's setup is done (gate probe answered differently) | **open** | R1, step 6 |
| N1 | the HAL's 48-byte element is captured offline | **pass** (U75/U264/U265) | none |
| N2 | that element + the U262 payload is accepted | **closed negative** (U265) | none |
| F1 | the log-site index that resolves the 4 un-loaded format strings is found | **open** | F1, section 6.1 |
| D0a | stock Android produces the setup | **owner-gated** (proven) | R3, section 7 |
| D0g | the stock HAL is the boot's *first* power-up in our kernel | **negative** (U274) | none; the HAL sends no setup |
| D0h | the A14 firmware + A14 HAL/core as a matched set | **open** | A10, one reboot |
| D0d | the firmware's setup handler is recovered statically | **open** | A5', after F1's index |
| D0c | a producer's command is accepted by the running firmware | blocked | D2b/D3b, R3, or D0d |
| E0a | mini model supported by the compiler | pass (U253) | keep |
| E0b | DGC0 container verifies | pass (12,288 B) | keep |
| E1 | RegisterGraph on the live core | **negative** (U256) | retry after D3b |
| E2 | CreateExecution/bind | blocked | after E1 |
| E3 | Invoke returns a tensor | blocked | after E2 |
| E4 | CPU parity | blocked | `tools/tpu-acceptance` |
| E5 | repeat and cold boot | blocked | after E4 |
| E6 | ten-run stability and teardown | blocked | after E5 |
| K1-K4 | kernel work for the product | open, independent | section 6.8 |
| P1-P5 | package, docs, product acceptance | blocked | after E6 |

D2/D2b/D3 run **inside the current boot**: no reboot, no firmware change, no
storage write. That is the cheapest unblock the plan has had since gate K.

## 5. Closed routes (do not reopen without a new artifact)

- **KCI code 6 with any payload.** Not a firmware command (section 1.1 of rev
  10); the U266 shapes, the 128-byte blob (U188) and the vectors (U177) prove
  nothing.
- **The A14/A17 HAL device path on a boot where `tpu-hold` already took the
  power-up.** It reset the phone twice (U154, U174); a retry is first-power-up
  only.
- **Element-field sweeps (`+4`, `+8`, `+10`, `+12`, `+32..+47`, the 32-slot
  command table).** U175/U250/U277.
- **The VII element code (`u16 @8`).** U273: codes 1, 2 and 3 gate identically.
- **The element's +10 command class.** U277: all 256 values sampled across two
  classes, none sets the firmware up.
- **The HAL alone as the setup producer.** U274: no VII command at all.
- **`HAL_ONLY=1` as a producer.** Same as above; do not re-run expecting setup.
- **The `chip_model` sysfs attribute as the DBA trigger.** U281: live, abort
  persisted until the property change.
- **`ro.board.platform` = `mmio` for the DBA service.** U279: the abort.
- **A model-parcel-based NNAPI trigger.** U280: the interface has no
  `prepareModel`; `createCompilationFromFile` takes a path.
- **A direct reference to the four setup strings.** U270: 977 loaded addresses,
  none of them these.
- **The `0xe3790` table as a dispatch table.** U267/U268.
- **The tegu core's setup** (U248), **the stock cheetah core** (U258), **the
  A14 compiler off-phone** (U257/U259), **`reboot-to bootloader|fastboot`**
  (U252/U255), **the GXP map as a producer** (U228/U229), **adopting a
  bootloader-started image** (GSA reads INACTIVE at power-up).
- **A second power-up in one boot.** U54: the PSM wedges.

## 6. The program to a working TPU

Ordered by cost. Track F is offline; track D has one cheap live producer (the
DBA session) and two expensive fallbacks; G/E/A/P follow.

### 6.1 Phase F - model the container and the interface (offline; no phone)

**F1. The log-site table and the index it resolves.** The only thing between
the plan and A5'.
1. `tools/tpu-fw.py reach out/tpu/edgetpu-janeiro.fw`; pick 3-4 referenced
   sites and disassemble around them to learn the logging convention (string
   register, level, line, any ID).
2. Compare with a site that logs a message with arguments.
3. If the sites pass `(id, args...)`, build `offset -> index` and read the gate
   site's index; search the body for it.
4. `tools/tpu-fw.py info` records the raw config words and the `0xdd000`
   records for F1's segment answer.

Pass: a named log-site record format and the setup messages' index. Stop: two
passes with no consistent convention; then D0d waits for a new artifact. Risk:
CPU only.

**F3. The DBA interface table (new).** From `com.google.edgetpu.dba-V1-ndk.so`
and the service binary, record for `IDevice`: the descriptor string, the method
order as the binary's `BnDevice::onTransact` switch has it, and the parcel
shape of `SessionConfig` (field count and widths). Method: disassemble
`BnDevice::onTransact` (`nm -D | grep BnDevice19onTransact`) and read the
`switch` cases; read `BpDevice::createSession` for the write order. This turns
the R1 code/config sweep into a lookup. Pass: codes and a field list. Risk:
CPU only.

**F4. The DBA HAL's setup builder (new, offline).** Locate
`SetupFirmware`/`CreatePredictor`'s setup submit in the DBA HAL, and record
the command vector and `cluster_id_bitset` it builds (the A14-shaped pair the
string names). This is the artifact A6' was after, now in a library we can
load without a device. Pass: the command struct sizes and the submit offset.

### 6.2 Phase D - name the producer

**R1: the DBA session (primary, no reboot).**

Hypothesis: `createCompilationFromFile` runs `Hal::CreatePredictor`, which
performs the firmware's one-time setup before it parses anything.

1. Chain up with `NO_DELEGATE=1 DBA=1` (servicemanager, vendor service, Tachyon
   service, DBA service). The DBA service holds the boot's one power-up when
   `NO_HOLD=1`; otherwise `tpu-hold` does and the service reuses it.
2. From the Arch host, run `tools/tpu-binder-client` against
   `/dev/binderfs/vndbinder` with `NAME=com.google.edgetpu.dba.IDevice/default`
   and `IFACE=com.google.edgetpu.dba.IDevice`.
3. D2: first transact `INTERFACE_TRANSACTION` (0x5f4e5446) and confirm the
   descriptor comes back. That proves the handle, the descriptor and the
   security context.
4. D2b: sweep codes 1..8 with `CFGWORDS` 0, 4, 8, 16, 32 zero words. An AIDL
   reply whose first word is status 0 is a success; anything else is
   `EX_ILLEGAL_ARGUMENT`/`EX_TRANSACTION_FAILED`. The code that answers 0 with
   a `flat_binder_object` is `createSession`.
5. D3: with the session handle, call `createCompilationFromFile` (code from F3,
   else sweep) with a path string (`/vendor/etc/model.tflite`) and a zero
   config.
6. D3b: the oracle is the firmware log. Watch `dmesg | grep -E 'Setup is
   already done|global scratches|vii-'`; a line other than the gate, or a VII
   reply other than `0xf000009` (probe with `T10=11`), is D3b passing.

Stop: three boots with the service up and no session reply; then F3 must name
the layout before another attempt. Risk: low. The service is a vendor daemon
on a vendor domain; the worst observed failure is an abort in that process.

**R2: the first-power-up variant (one reboot).** Same as R1 but with
`NO_HOLD=1` so the DBA service's open is the boot's first power-up. Needed only
if R1's session is refused because `tpu-hold` already powered the device;
U274 showed this variant does not reset the phone.

**A5' (D0d). Static recovery, gated on F1.** Once F1 names a domain, repeat the
message-index search with that base.

**A10 (D0h). The A14 set as a matched pair (one reboot, firmware swap).** The
A14 image (985,344 B) pairs with the A14 HAL/core. Stage image, HAL and core;
keep the A17 restore set in the same directory.

**R3 (D0a). The stock oracle (owner-gated, the only *proven* producer).**
Section 7. Run it whenever the human is at Fastboot.

### 6.3 Phase G - graph format (after D3b)

**G1. Match the container to the live core.** `tools/tpu-graph.py verify`
accepts DGC0/DWS0, matching the core verifier at `0xb9da8`; the 12,288-byte
mini DGC0 passes. After D3b: retry the verified DGC0 once through the DBA
session's compile path (which is the vendor's own graph parser) and through
the direct harness, and record which one accepts it.

**G2. A repeatable graph producer.** (a) the vendor compiler on-device in the
chroot (U253's cache holds a real DGC0); (b) the same compiler on the laptop
with a bionic harness; (c) precompiled models only. Ship (c) first if (a) needs
the HAL's device path.

### 6.4 Phase E - execution (E1-E3)

With D3b and G1: register the graph, create the execution, bind the input and
output from `/dev/dma_heap/system`, Invoke, and dump the raw output. A status 0
without a non-empty tensor is not E3. One attempt per boot; record the raw
reply and the tensor hash. If the core dies, capture the core file (`CORES=1`)
and the last 200 dmesg lines before retrying.

**E1a (new option).** If the DBA session accepts a compilation, do E1-E3
through `IDeviceSession`/`ICompilation` rather than the hand-built VII
commands: the vendor HAL builds the commands, which removes the whole
FlatBuffer-layout risk that stopped `RegisterGraph` (U256).

### 6.5 Phase A - acceptance (E4-E7)

`tools/tpu-acceptance compare --tpu ... --cpu out/tpu/mini-fc-u8-cpu.bin
--dtype uint8 --shape 1,1 --model ... --label mini-fc-u8`. Integer tensors are
exact. E5: twice in one boot, then a cold slot-B boot. E6: ten runs, watching
for a second power-up, a leaked handle or an IOMMU fault. E7: close the
session, check `clients`/`mappings` are empty, confirm the KCI heartbeat
continues, and never `rmmod` mid-boot.

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
not. A model is code for the TPU; untrusted models stay out of the product
path until the graph verifier is trusted.

### 6.7 Phase T - performance (after E4)

The 720p SSD benchmark is prepared in `out/bench/` (1280x720, 60 frames,
`detect.tflite`). CPU numbers are in TPU-STATUS.md. Measure the TPU only after
a correct tensor exists, then record mean/p95, detections per frame, thermal
and battery. Do not tune before parity.

### 6.8 Phase K - kernel work the product needs (independent of gate D)

- **K1. One power-up per boot, enforced.** Document it in the driver and make
  `tpu-hold` the only first-power-up path; a second `edgetpu_pm_get` should
  fail loudly, not wedge.
- **K2. IOMMU fault handling.** A fault must kill the client, not the phone:
  check the domain's fault handler on a bad iova before E1 is retried.
- **K3. Teardown and recovery.** Closing a session must release the group,
  mapping and wakelock (E7 checks it). A firmware crash must be recoverable
  without a reboot if the PSM allows it.
- **K4. Power and thermal.** The driver's thermal and idle paths are untested
  with a real workload; measure after E4.

## 7. Stock-oracle runbook (owner-gated)

Every step is a separate go. A stock boot rewrites `efs`, `persist` and
`modem_userdata`; take a fresh read-only NV backup after it.

1. **Preflight (read-only).** `tools/tpu-stock-capture check`; confirm
   `out/cheetah/nv-2026-11-12-pre-stock` and the saved slot-B image set
   (`out/cheetah/slot-b-2026-11-13`, five images, `SHA256SUMS`). Stop if either
   is missing or a checksum differs.
2. **Physical Fastboot.** Volume Down + Power, about 20 s; confirm
   `fastboot devices`. Send nothing else first.
3. **Slot flags (read-only).** `current-slot`, `slot-successful:a`,
   `slot-successful:b`. Expect `b`/`yes`. Stop otherwise.
4. **Ask explicitly for `fastboot --set-active=a`.** Record the flags again.
5. **Boot stock and capture (read-only).** `tools/tpu-stock-capture capture
   PRIVATE_DIR`: dmesg from boot, `getprop`, `ps`, the first
   `vii-elem`/`vii-payload`, the services that open `/dev/edgetpu`, the
   firmware hash, and the DBA service's own log. Never install, root or flash
   to get a log.
6. **Rollback.** `fastboot --set-active=b`, confirm, boot the saved set, verify
   SSH and `omamobile-boot-success`, then a fresh `tools/nv-backup`. On the
   stock recovery screen choose neither "Try again" nor "Factory data reset":
   Volume Down + Power for Fastboot.
7. **Record.** Flags before/after, boot times, the private capture path (never
   its contents), the next action.

## 8. Software-only runbooks

### R1 (phone, no reboot): the DBA session

1. `NO_DELEGATE=1 DBA=1 NO_HAL=1 sh /usr/lib/omamobile-vendor/edgetpu/root/root/tpu-tachyon-run`;
   confirm `dba service pid:` in the log and `dmesg | grep -c 'Unknown
   chip_version'` stays 0.
2. Probe D2: `IFACE=com.google.edgetpu.dba.IDevice NAME=.../default
   tools/tpu-binder-client /dev/binderfs/vndbinder 0x5f4e5446`; expect the
   descriptor string in the reply.
3. Sweep D2b: codes 1..8 x `CFGWORDS` 0/4/8/16/32; record the first reply
   whose word 0 is 0; that code is `createSession` (confirm the reply holds a
   binder object).
4. D3: call `createCompilationFromFile` on the session handle with a string
   path and a zero config; sweep the code if F3 has not named it.
5. D3b: `dmesg | grep -E 'Setup|scratch|vii-'` and the `T10=11` probe. Pass:
   any firmware line other than the gate, or a VII reply other than
   `0xf000009`.
6. Stop after three boots without a session reply; do not retry a code that
   reset the phone.

### R1b (phone, one reboot): the first-power-up variant

As R1 with `NO_HOLD=1`, only if R1's session is refused because `tpu-hold`
already took the power-up. Reboot is owner-gated; stop the modem first.

### F1 / F3 / F4 (laptop, no phone)

1. `tools/tpu-fw.py info out/tpu/edgetpu-janeiro.fw`; record config words and
   the entropy boundary.
2. `tools/tpu-fw.py reach out/tpu/edgetpu-janeiro.fw`; expect 977 referenced
   island addresses and `want 0xefbdc: NOT referenced`.
3. Disassemble around three referenced sites; write the logging convention.
4. Build `offset -> index`; read the gate site's index; search the body.
5. F3: `nm -D | grep BnDevice19onTransact`; read the switch and the
   `BpDevice::createSession` write order; write the field list down.
6. F4: locate the DBA HAL's setup submit and record the command vector and
   `cluster_id_bitset`.

## 9. State, risks and recovery

- **State at rev 11.** Phone on slot B, kernel
  `7.3.0-rc6-omamobile-push1-ga78d26f63e56-dirty`; `janeiro` loaded with the
  `chip_model` attribute; `tpu-hold` pid 869 holds the one power-up; the DBA
  service runs (`pid 4855`) when the chain starts it; gate K proven; gate D
  blocked; no model output.
- **Risk register.** DBA session: a vendor daemon abort (observed, recoverable
  by restarting the service in the same boot; it holds no storage). HAL device
  path: phone reset (closed except first-power-up). Second power-up: PSM
  wedge. Stock boot: NV rewrite (owner-gated, fresh backup). Binder chain:
  stale nodes (mount binderfs, U236).
- **Recovery.** R1 is undone by killing the service; a graph/execution by
  closing the session; a package by the previous rootfs; stock by
  `--set-active=b` plus the saved slot-B set and a fresh NV backup. No step is
  retried before its result is recorded.

## 10. Decision tree

```
gate K fails? -> stop: driver/session regression, not setup.
gate K passes
  -> R1 D2 (descriptor reply)?
       |--yes--> D2b createSession reply 0?
       |            |--yes--> D3 createCompilationFromFile -> D3b setup? -> E1
       |            |--no---> F3 names the code/parcel -> R1 again
       |--no---> F3 (offline) -> R1 again
  -> D3b fails -> F1/A5' (static) or A10 (A14 set, one reboot)
  -> R3 stock oracle whenever the human is at Fastboot
  -> D3b passes -> G1 DGC0 (DBA compile or direct harness) -> E1 register
     -> E2 bind -> E3 invoke -> E4 parity -> E5 repeat/cold boot
     -> E6 ten runs -> E7 teardown -> P1-P5 product -> T performance.
```

## 11. Immediate actions (ordered)

1. **R1 D2/D2b (phone, no reboot, next):** start the chain with the DBA
   service and run the raw-binder client against `IDevice/default`. The
   descriptor reply is the first fact; the `createSession` code is the second.
2. **F3 (offline, parallel):** the `BnDevice::onTransact` switch and the
   `SessionConfig` field list, so R1's sweep becomes a lookup.
3. **R1 D3/D3b:** `createCompilationFromFile` with a model path, then the
   firmware-log oracle and the `T10=11` probe.
4. **F1/A5':** the log-site index (unchanged; the static route is still the
   fallback).
5. **R2 (only if R1 is refused for the power-up):** the `NO_HOLD=1` variant,
   one reboot.
6. **A10 (one reboot):** the A14 image + HAL + core as a matched set.
7. **R3 (owner):** the stock oracle, section 7.
8. **K1/K2 (offline kernel work):** the one-power-up rule and the IOMMU fault
   check.
9. **A0.1 sentinel:** the two-Ping gate-K regression once per boot series.

## Appendix A - signed firmware container (U260)

`out/tpu/edgetpu-janeiro.fw`, 1,038,272 B, sha256
`52c1cccdf0e243d12fbc9f3b3911fe9c780a11d9a5bfda61744c7c3fdaded7c3`.

| Field | Value |
| --- | --- |
| Magic at `0x400` | `TPUF` (`0x46555054`), generation 1 |
| Length at `0x40c` | 1,034,176 (file 1,038,272) |
| Image config at `0x560` | carveout `0x93000000`, firmware `0x93000000`, size `0xfd000` |
| Remapped region | `0x93200000`, size `0xe00000` (14 MiB) |
| Body entropy | 7.0-7.2 bits/byte over `0x0..0xdc000`; island `0xe0000..0xfd7c0` plaintext |
| Island | 1,199 strings; code loads 977 addresses, none of the 4 setup messages (U270) |
| Second domain | `0xdd000`: 8-byte records, first words `0x7ffdxxxx` (F1) |

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

`tools/tpu-setup.py build` reproduces these bytes exactly.

## Appendix C - VII element layout and what was sent

48-byte element from the command queue (`edgetpu-mailbox.c` dumps 12 words):

| Offset | Field | Sent in every run |
| --- | --- | --- |
| 0 | `seq` (u64) | 0 or 1 |
| 8 | `code` (u16) | 0, 1, 2, 3 (all gate) |
| 10 | `flags`/class (u8) | 0x0b; swept 0-255, two classes, none passes |
| 11..15 | reserved | nonzero gives `0x9 0x14140000` |
| 16 | `dma.address` (u64) | payload iova |
| 24 | `dma.size` (u32) | payload length |
| 28..47 | payload/other | per-run |

The payloads tried with code 0: the 128-byte type-5 command, the 80-byte legacy
message, allocation vectors and zero pages. All answered the gate
(`0xf000009`).

## Appendix D - the DBA AIDL surface (U280)

| Item | Value |
| --- | --- |
| Service name | `com.google.edgetpu.dba.IDevice/default` |
| Descriptor | `com.google.edgetpu.dba.IDevice` |
| Session | `IDeviceSession` (`createCompilationFromFile`, `ImportHardwareBuffer`, `ReleaseBuffer`) |
| Compilation | `ICompilation` (`CreateExecutionResult`, `CreateRepeatedExecution`, `DispatchFencedExecution`) |
| Config types | `SessionConfig`, `CompilationConfig`, `BufferConfig`, `Request`, `MemoryRegion`, `TensorShape` |
| Callbacks | `IFencedExecutionCallback`, `IRepeatedExecutionCallback` |
| Library | `com.google.edgetpu.dba-V1-ndk.so` (119,632 B) |
| HAL | `libdarwinn_dba_hal_runtime.so` (3,785,000 B, `GetDarwinnHalFunctions@@VER_1.0` at `0xf772c`) |
| Service binary | `/vendor/bin/hw/com.google.edgetpu.dba-service` |
| Service source | `vendor/google/darwinn2/dba/service/edgetpu_device_session.cpp` |
| Client | `tools/tpu-binder-client` with `NAME=...IDevice/default` and `IFACE=...IDevice` |

## Appendix E - where the evidence lives

- [TPU-HISTORY.md](TPU-HISTORY.md): every prior revision and the U-log
  (U279-U281 are this revision's).
- [TPU-STATUS.md](TPU-STATUS.md): the one-page status.
- `logs/tpu/`: gate-K and run logs (gitignored; check for identifiers).
- `out/tpu/`: the model, graph, payloads, firmware and disassembly (gitignored).
- Tools: `tools/tpu-fw.py`, `tools/tpu-setup.py`, `tools/tpu-graph.py`,
  `tools/tpu-acceptance`, `tools/tpu-compile.c`, `tools/tpu-mini-model.py`,
  `tools/tpu-stock-capture`, `tools/tpu-exec.py`, `tools/tpu-tachyon-run`,
  `tools/tpu-tachyon-client.c`, `tools/tpu-binder-client.c`,
  `tools/android-props-stub.c`, `tools/tpu-setup-payload.py`.
