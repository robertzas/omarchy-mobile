<!-- SPDX-License-Identifier: MIT -->
# TPU / NPU plan: the Edge TPU (Abrolhos / Janeiro) on cheetah (gs201)

Status (2026-11-14, rev 22): **the wall has a number. KCI code 15's DMA
descriptor size is 64**: 63 and 65 are refused by name (`Invalid KCI DMA
descriptor size N`), 64 is accepted and then the handler stops answering
(`-> -110`, three times, with 63/65 as controls; U366). A zeroed 64-byte payload
also logged `firmware unrecoverable crash` during a flood, while KCI 11 kept
answering 0 afterwards, so the firmware survives but that handler faults. This
is the first KCI command whose payload gate has been satisfied, and it is the
strongest lead since gate K. In the same pass: the dense size sweep closes every
other size (1..4096 chunked so no line is lost), Google's public gs101 vendor
driver and the open-source Coral runtime contain **no** setup producer (U367),
the chroot has no setup blob (U368), and this firmware exposes only error-level
logging (U369). The setup itself is still not done and no inference is claimed.

## 0. Rules this plan runs under

- **One change per boot.** A new payload, element, firmware or module is tested
  alone; two new things that fail together tell you nothing.
- **No blind sweeps.** A new payload, code or offset needs a measured fact, or
  it is a sweep with a stated hypothesis, a bounded set and an oracle.
- **The firmware's own log is an oracle.** Every VII attempt is answered either
  by the gate (`Setup is not done yet ... type 0`, `0xf000009`) or by a
  different line. A different line is the signal.
- **Owner gates are unchanged.** Stock slot A, `--set-active`, any flash, any
  bootloader/radio/`devinfo`/`persist`/`efs*`/`modem*`/`vbmeta` write, and
  **every reboot** are per-step owner gates (AGENTS.md section 1).
- **One power-up per boot.** The first opener powers the TPU; a second power-up
  wedges the PSM (U54). Anything that opens `/dev/edgetpu` must therefore be
  the boot's first opener, or reuse an already-open device.
- **Containment.** Every new userspace experiment runs inside the vendor chroot
  as its own process, so a crash costs that process and not the phone. A 3 s
  alarm bounds every call that could hang.
- **Evidence, not narrative.** Every claim names its U-record, file line or
  command.

## 1. What rev 12 corrects

### 1.1 Binder is stalled *below* the HAL, and a serving thread does not fix it

Rev 11 made the DBA service register and receive `createSession`. Rev 12's
first experiment gave the process a serving thread on purpose
(`tools/android-dba-serve.c`, preloaded): it joins the pool, the process grows
to two threads in `binder_ioctl_write_read`, and **the queued transaction is
still not claimed** (U285). Decisive detail: `INTERFACE_TRANSACTION`
(`0x5f4e5446`), which `BBinder` answers without entering `onTransact`, also gets
no reply, while the kernel reports `tr 1` pending on the service's node. The
parcel, the interface token, the session config and the HAL are therefore all
exonerated. The service holds exactly one binder fd,
`/dev/binderfs/vndbinder`.

Rev 12 parks binder. It stays as runbook R1 with two named hypotheses — the
service's `ProcessState` is not the one our thread joins, or the lazy-service
registration path returns a handle whose node is not the service's. Neither is
worth a boot until the in-process route below is exhausted, because that route
does not need servicemanager, AIDL, a thread pool or a parcel at all.

### 1.2 The DBA HAL's entire C API is a versioned table, and it is reachable

`libdarwinn_dba_hal_runtime.so` exports one symbol,
`GetDarwinnHalFunctions@@VER_1.0`. It returns a table (U286):

```
word +0     = 2                    (API version; the service refuses <= 0)
word +8     entry 0   0xf7738      logging/init: logs the 16-byte "LibDarwinnDbaHal"
word +16    entry 1   0xf7764      forwards (x0, x1, x2, x3) through a functor
word +24    entry 2   0xf78dc
...
word +112   entry 13  0xf87a4
```

This was read inside the vendor chroot by a preloaded probe
(`tools/tpu-dba-hal-probe.c`), with no binder and no service. The library is
3,785,000 bytes, and `.text` after the table region is the Darwinn core.

### 1.3 Entry +16 is the factory, and the service's own call site proves it

The DBA service binary (`/vendor/bin/hw/com.google.edgetpu.dba-service`,
86,120 B) is the reference client. At `0x84a0` it calls
`GetDarwinnHalFunctions`, at `0x84c8` it **checks the version word > 0**, at
`0x84e8` it calls entry `+8` with no arguments (the logging init), and at
`0x8580`-`0x859c` it calls entry `+16`:

```
x0 = sp+0x40            a 16-byte struct copied from the caller on the stack
x1 = x29-0x30           the out handle
x2 = 0x8d10             a function pointer
x3 = x19                a newly allocated object
x8 = [table + 0x10]     entry +16
blr x8
```

`0x85a0` tests `w0` (a status), logs the source line on failure, and then
`0x85bc` calls `ABinderProcess_setThreadPoolMaxThreadCount(4)` and `0x861c`
`ABinderProcess_joinThreadPool`. Entry `+16`'s own body confirms the shape: it
saves `x1` in `x19`, builds a `{vtable, x2, x3}` functor on the stack, calls
the implementation, and stores the result through `x19`. So:

```
DarwinnHal_Create(const DarwinnHalOptions *options,  /* x0, 16 bytes seen */
                  DarwinnHal **out,                  /* x1 */
                  callback,                          /* x2 */
                  callback_context)                  /* x3 */
                  -> status in w0
```

The options object the service passes is **16 bytes**; its fields are not yet
named. Args 3 and 4 are required: `x2` is a thunk (`0x8d10` -> `0x9360`) and
`x3` a fresh 0x80-byte object (`+0x10 = 1`, `+0x7c = 2000`). A call with both
zero dies `SIGSEGV` at `0x0` (U290), so S1 needs a callback and a context of
that shape, and init is one-shot per process (U288). A valid callback and
context are still not enough: the call faults at `0x0` with the options zeroed
(U291), so some field of the 16-byte struct is a pointer the HAL dereferences.
`0x11660` in the service is the options builder: it builds two SSO strings and
calls `android::base::GetProperty`, then copies the result into the factory's
options slot (U292), so S2 reads the property name at `0x4b77` and the string
layout rather than guessing a pointer table.

**S1 result (U293-U297).** With the builder's output synthesized
(`{1, 1, "/dev/edgetpu"}`) the factory no longer faults: it allocates, starts an
eventpoll/eventfd/timerfd trio and three threads, and then blocks in a futex
**without ever opening `/dev/edgetpu`** (the fd list has no device node, and
`dmesg` shows no KCI traffic from it). So create waits on a userspace callback
contract, not on firmware. The service's fourth argument is a
`__shared_ptr_pointer` control block built at `0x9200`, and the third is a code
thunk at `0x8d10`; S2 is now "satisfy that callback contract", and the
`exe_base` shortcut is retired (U293). Do not use `backtrace()` in the alarm
handler: it deadlocks (U296, U299); it is now a plain `_exit(3)`.
The wait is independent of the callback and context (U298: all three
combinations block identically), and `+0x10` is confirmed as the factory from
the caller's own register use (U300). S2's next instrument is a ptrace sampler
that reads the blocked thread's user stack and subtracts the HAL's mapping base
from `/proc/<pid>/maps`; `backtrace()` cannot be used. A first sampler is in the harness (`MODE=bt`):
attach and `PTRACE_GETREGSET` work and the PC lands in libc's futex path, but
`PTRACE_PEEKDATA` returns -1 for the frames (U301), so print `x29`/`errno` or
switch to `process_vm_readv` before drawing conclusions from it. The service fills it before the call at `0x850c`-`0x8524`; reading that
fill and the library's `DarwinnHalOptions` uses is stride S2.

### 1.4 The RTTI names are next to the table, not in it

`DarwinnHal_Create(const DarwinnHalOptions*, DarwinnHal**)` and
`DarwinnHal_CreateRepeatedExecution(...)` appear as demangled RTTI strings at
`0x70348`/`0x703dd`/`0x7046e`/`0x70553` (U287). They are typeinfo names in
`.data.rel.ro`, referenced from data, not code, so they do not mark a table
slot — rev 11's note that the last slot "is" create was a window artefact. They
still confirm that a factory with exactly this signature exists in the binary.

### 1.6 Rev 13: the wait is inside the factory's own startup

Four facts now bound what create does before it touches firmware:

1. With the builder's exact options it **allocates**, starts an
   eventpoll/eventfd/timerfd trio and **three threads**, then blocks.
2. It **never opens `/dev/edgetpu`** (the fd list has no device node) and sends
   no KCI traffic (`dmesg` is silent; the 61 s KCI 21 heartbeat is the driver's).
3. The wait does **not depend on the callback or the context**: both, callback
   only, context only and neither all block identically (U298).
4. The call target is right: the service's own `x19` is the table and
   `[x29-0x28]` carries it into `ldr x8,[x8,0x10]` (U300).

So create spawns its own machinery and waits for one of its own threads or for a
task it posted. That is a *contract* between the factory and its caller that the
service satisfies somewhere else, and the plan's job is to name it.

**Instruments that failed, so do not repeat them.** `backtrace()` in the alarm
handler deadlocks (U296/U299). A frame-pointer walk cannot work: the blocked
thread's `x29` is `0xffffffff`, so there is no chain (U302). Ptrace from inside
a preloaded `.so` is **not trustworthy** here: `PTRACE_ATTACH` and
`PTRACE_GETREGSET` report success, yet `sp` reads `0x3d3d3d3d3d3d3d3d` and
`process_vm_readv` returns -1 (U302). Any future sampler must be a **standalone
aarch64 binary**, not an interposer inside `edgetpu-run`.

**The instrument to use next (S2b).** Interpose the blocking primitives
(`pthread_cond_wait`, `pthread_cond_timedwait`, `sem_wait`, `pthread_join`,
`futex`) inside the same process and print `__builtin_return_address(0)`
subtracted from `hal_base`. No ptrace, no unwinder, and the return address is by
construction inside the HAL function that waits.

### 1.6.1 The wall as five hypotheses, each with a test and a cost

| # | Hypothesis | Test | Cost |
| --- | --- | --- | --- |
| H1 | Create posts a task to its executor and waits for it; the executor needs an **ALooper** the process has not prepared | link a tiny bionic binary that calls `ALooper_prepare(0)` before the factory call, or call it from the harness ctor | offline + one run |
| H2 | ~~The 16-byte options are not `{flags, flags, path}`~~ **refuted (U307)**: `ldp w8,w9,[x0]` then `[x0+8]` is a `const char *` copied with `strlen`/`memcpy`, so it is `{u32 bool, u32 enum 0..2, const char *}` and our bytes are legal | done | - |
| H3 | Create waits on a **peer thread that is itself blocked**: our `eventfd`/`timerfd` never fires because no one armed it | S2b names the waiter; then the peer thread's state from `/proc/<pid>/task/*/stack` | one run |
| H4 | Create registers a **client** with a layer that only the service's binder side serves, even in-process | S2b: if the waiter is a callback the service installs at `0x8d10`, read that thunk's body | offline + one run |
| H5 | The HAL wants more **properties** than `ro.board.platform` (e.g. a hardware name) and waits while a property lookup retries | S2: read every `GetProperty` call in the create path for its key | offline only |
| H6 | ~~The wait is an artefact of our own `fork()`~~ **refuted (U306)**: `MODE=nofork` blocks identically, with no device fd and no VII line | done | - |


H1 and H2 are cheaper than another phone run, so they come first. H3/H4 need
S2b, and S2b is the only instrument that has not failed.

### 1.6.2 Create's prologue, now decoded

`0xf7764` wraps `0xf8df8`; the options stay in `x0`. The implementation reads:

```
0xf8e30  ldp  w8, w9, [x0]     two 32-bit words: a bool and an enum
0xf8e3c  cmp  w9, #1 ...       enum 0 -> mode 3, 1 -> mode 4, 2 -> mode 5
0xf8e54  ldr  x26, [x20, #8]   the device path
0xf8e74  bl   strlen@plt
0xf8ecc  bl   memcpy@plt       into a std::string at sp+0x30
```

So the 16-byte object is `{u32 bool, u32 enum 0|1|2, const char *path}` and the
harness's `{1, 1, "/dev/edgetpu"}` is legal (U307). **The block is after the
path is copied**, so neither the options layout nor the pointer is the wall.

What remains between the copy and the wait is what S4 must read next: the call
at `0xf8f50`-ish that follows the string, and the `0x112e24` call before it.
Until that is read, H1 (a Looper the process lacks), H3 (a peer thread blocked)
and H5 (more properties) are the open hypotheses, and H1 is the cheapest.

### 1.6.3 Create's own body does not block

The implementation spans `0xf8df8`-`0xf9208` (it ends with
`__stack_chk_fail@plt`). Its only direct libc calls are `strlen`, `memcpy` and
`pthread_create@plt` at `0xf9008`; everything else is a virtual call or one of
the helpers `0x112e24`, `0xfd3d8`, `0x30dca8`, `0x30e374`, `0x330bd0`,
`0x32671c`, `0x329cf0`, `0x12a710`. There is **no** `open`, `epoll`, `eventfd`
or `GetProperty` in the body (U308). The wait is therefore inside a helper, and
the two windows already captured are `0x12a710` and `0xfd3d8` (quote in U308):
the next offline read starts there, not at the options.

### 1.6.4 What the block is not

The factory process is alive while it waits: its own threads keep `mmap`-ing
(0x40000 = 256 KiB each, the shape of repeated `pthread_create`) and
interleaving output. No interposed symbol was called: not
`pthread_cond_wait`, `pthread_cond_timedwait`, `sem_wait`,
`pthread_mutex_lock` or `pthread_join`, not `read`, `epoll_wait`, `poll`,
`ioctl`, `socket` or `connect`, and not `openat`, `access` or `nanosleep`
(U311, U315). **Caveat:** the self-test proves interposition for calls made from
the harness's own PLT, not for calls made by `libdarwinn` (U315 correction), so
this is "no interposed call was observed", not "the factory cannot make one". So the wait is not a libc condition variable, not a
semaphore, not a join and not a poll on a descriptor: it is a raw futex or an
in-kernel wait reached without a PLT symbol.

### 1.6.6 The route change (U316)

The TPU is **alive**: `1ce00000.janeiro` is bound to `edgetpu_platform`,
`/dev/janeiro` is a real character node, and the kernel logs the TPU's own KCI
heartbeat (code 21) with the sequence counter climbing every ~61 s and irq 152
asserting. Gate D's premise, that the firmware has never been loaded, is
therefore wrong and Gate D is re-scoped to "drive the device", not "start it".

What the HAL does not do is open any node. It builds a worker pool and waits, so
it is a **client of a service**, not a driver of the hardware. That retires the
in-process route for good: `create` cannot succeed in a process with no peer.

Two routes remain, in order of cost:

1. **Direct KCI client (cheap, no Android).** The kernel driver already owns the
   mailbox and the heartbeats. Write a small userspace client against
   `/dev/janeiro` that sends the KCI commands the HAL would have sent, and read
   the responses the driver already logs. This is the shortest path to a first
   inference and needs no binder, no servicemanager and no chroot.
2. **The service route (expensive).** Mount binderfs inside the chroot, run
   `servicemanager` and `dba-service`, then `create` has the peer it waits for.
   This is the parked route and stays parked until route 1 is shown to lack a
   command the service alone implements.

### 1.6.5 Two environment facts for in-process experiments

- **`dlopen` blocks after `fork()` in this chroot** and completes with
  `NOFORK=1` (U312). Any preload test that needs a library loaded at runtime
  must run `NOFORK=1`.
- **The chroot's `libandroid.so` exports no `ALooper_prepare`** (U313), so H1
  is not testable through it as written.

### 1.8 Rev 14: the route decision, and the protocol it runs on

**The fact that ended rev 13's route.** The TPU is alive on this boot. The
kernel logs its own KCI heartbeat while our harness sits blocked:

    edgetpu janeiro: KCI tx code 21 seq 129 tail 129 head 129
    edgetpu janeiro: irq 152 idx 0 mailbox ffff00080a3a7c40 status 1

`1ce00000.janeiro` is bound to `edgetpu_platform` and `/dev/janeiro` is a real
character node (505:0). Meanwhile the vendor HAL opened **no** node at all: not
`/dev/edgetpu`, not `/dev/janeiro`, not `/dev/binder` by any symbol we could
interpose. A HAL that opens nothing and waits is a client, not a driver. So
`DarwinnHal_Create` cannot return in a process with no peer, and rev 13's
Track S is retired as a *route* even though its findings stand (U293-U316).

**What the kernel already implements.** The driver in
`~/omamobile-kernel/edgetpu-janeiro/drivers/edgetpu/` owns the protocol the HAL
would have spoken:

| KCI code | Name | Sent by the driver |
| --- | --- | --- |
| 0 | `ACK` | yes |
| 1 | `UNMAP_BUFFER` | yes |
| 2 | `MAP_LOG_BUFFER` | yes |
| 3 | `JOIN_GROUP` | yes |
| 4 | `LEAVE_GROUP` | yes |
| 5 | `MAP_TRACE_BUFFER` | yes |
| 7 | `SHUTDOWN` | yes (`edgetpu_kci_shutdown`) |
| 8 | `GET_DEBUG_DUMP` | yes |
| 9 | `OPEN_DEVICE` | yes, with `{client_priv, vcid, flags = (mailbox_map << 1) | first_open}` |
| 10 | `CLOSE_DEVICE` | yes |
| 11 | `FIRMWARE_INFO` | yes, into an iremap buffer, returns `edgetpu_fw_info` |
| 12 | `GET_USAGE_V1` | yes |
| 13 | `NOTIFY_THROTTLING` | yes |
| 14 | `BLOCK_BUS_SPEED_CONTROL` | yes |
| 19 | `FIRMWARE_TRACING_LEVEL` | yes |
| 21 | (heartbeat) | firmware → AP, once a minute |

The enum has **no setup command** (U269), which is why the VII gate is where
setup lives: `KCI_CODE_OPEN_DEVICE` and `FIRMWARE_INFO` are the *handshake* the
driver completes at power-up, not the firmware's scratch setup. The setup
remains the VII type-5 command whose only proven producer is the DBA HAL's
`SetupFirmware`.

**Three routes, ordered by cost.**

- **R-KCI (primary).** Drive the device from userspace through the kernel's own
  interface. Note (U322): KCI is kernel-internal, so the usable userspace
  surface is the VII mailbox path (gate K) plus the read-only queries; there is
  no KCI send ioctl. The gap is not transport; it is the exact VII
  element the HAL's enqueue writes (`base + (tail & 0x3ff) * 0x30`, 48 bytes,
  fields `0..7`, `8..9`, `10`, `11..15`, `16..23`, `24..27`, `28..31`,
  `40..43`, `44`; U264). Every producer so far wrote the wrong combination of
  those fields, which is why the firmware answers the gate before parsing.
  R-KCI's job is to make one element byte-identical to the HAL's, then send the
  U262 type-5 payload inside it.
- **R-SERVICE (parked, but no longer a mystery).** Mount binderfs inside the
  chroot, run `servicemanager` and the vendor DBA service, and `create` gets the
  peer it waits for. Rev 12's stall (U285) says the queue does not move even
  with a serving thread, so this route needs a *driver/lazy-service* answer
  before it is worth a boot.
- **R-STOCK (owner-gated oracle).** A stock boot captures the real producer at
  the VII boundary. Unchanged from rev 12, and still the only route proven to
  make the firmware's setup happen.

**What rev 14 therefore withdraws.** Track S as the primary route, the
`ALooper`/property hypotheses (they explain a wait that no longer matters), and
any further instrument aimed at naming `create`'s waiter. The instruments stay
in the tree as diagnostics.

### 1.9 The VII element, as the target of R-KCI

The HAL's enqueue (U264) is the reference. A VII command element is 48 bytes in
a 1024-entry ring, published with a `dmb ish` after the body and before the
tail. Fields 0..7 are the header (the first eight bytes are the sequence),
`8..9` is the code, `10` the command class, `11..15` reserved, `16..23` and
`24..27` are the DMA descriptor pair `{address, size}`, `28..31` the flags, and
`40..43`/`44` are the extension the U265 replay set to `2` and `0x100`.

Every producer that failed wrote a *VII code 0* element (U248/U249/U273), so
changing only the class byte was never going to be the producer. Rev 14's
R-KCI-2 did the rebuild (U319) and got a negative that saves a boot: the
48-byte element (`seq=0 code=0 class=0 addr=0xfff80000 size=0x50 flags=0
+32=0 +36=2 +40=0 +44=0x100`) and its 80-byte payload are **byte-identical to
the element already replayed on 2026-11-09**, which the firmware gated (U265).
The U262 128-byte artifact is a different object. So the element is not the
missing piece, and R-KCI-3 must not spend a power-up repeating a known negative.

**What the capture does not contain (corrected, U324):** not the client
context. `EDGETPU_CREATE_GROUP` (ioctl 6), `EDGETPU_JOIN_GROUP` (ioctl 7) and
`_IO(0xED, 8)` exist, and our own client already creates and finalizes a group
before it submits (`0x4014ed06`, `0xed08`). What has never been captured is the
**vendor HAL's own element**: `out/bench/chain-dwn1.log` is a dump of *our*
producer's element, so the rebuild in U319 is authentic only to our
construction. The next offline stride is therefore to derive the HAL's element
fields from its own struct fill (`0x1529648`, copy at `0x152989c`), not to
re-send ours.

### 1.7 What rev 13 withdraws

- **The ptrace sampler** (`MODE=bt`) as evidence. Keep the code for the record,
  but its register block is garbage and its stack scan is meaningless (U302).
- **The frame-pointer walk** as a route: `x29` is not a chain in this thread.
- **"The factory needs a callback"** as a statement about the *wait*: the
  callback is required (a zeroed pair faults), but it is not what create waits
  on (U298). Both are true and must not be conflated again.

### 1.5 What stands from rev 11

- Gate K passes (session, both FMQs, 88-byte reply), re-proven on this boot.
- The DBA service registers and loads its HAL once the cmdline-keyed property
  shim answers `gs201` (U279) and the VINTF fragment exists (U283).
- The DBA interface is session-based: `createSession` →
  `IDeviceSession.createCompilationFromFile` → `ICompilation` (U280).
- `chip_model` = `janeiro_a0` is live and was not the abort trigger (U281).
- The VII gate precedes every payload parse; element `+10` is the command class
  and its whole range has been sampled (U273/U277).
- The HAL setup payload is type 5, one 512 KiB allocation, reproducible
  byte-exact by `tools/tpu-setup.py` (U262).
- KCI code 6 is dispatched and answers `UNIMPLEMENTED`; the stock cheetah core
  is a stub; the tegu core sends the legacy setup; the A14 compiler exits 11
  off-phone (U258/U248/U259).

## 2. Architecture and current state

| Layer | What it must do | State | Evidence |
| --- | --- | --- | --- |
| L0 Kernel | `janeiro` binds, maps KCI/VII, powers the TPU once, attaches both SysMMUs, exposes `/dev/edgetpu` and `chip_model` | **pass** | `tpu-hold`, KCI 21 heartbeat, U281 |
| L1 Transport | Tachyon session, both FMQ queues, one command round trip | **pass** (gate K) | `logs/tpu/20261113-gatek-rev10.txt` |
| L2a Service | the DBA service publishes `IDevice/default` and links its HAL | **pass** (U279/U283) | `dba service pid`, `InitGoogle completed for LibDarwinnDbaHal` |
| L2b HAL access | the HAL's table is readable and its factory callable with no binder | **table pass; factory call open** | U286, service call site §1.3 |
| L2c Firmware setup | the one-time setup command is accepted; later VII commands parse | **blocked** (gate D) | `Setup is not done yet ... type 0`, `0xf000009` |
| L3 Graph | a graph container the running core accepts is registered | **E0 pass; E1 negative before setup** | U256 |
| L4 Execution | CreateExecution, bind input/output, Invoke writes a tensor | blocked by L2c/L3 | none |
| L5 Product | `omamobile-tpu` runs a model, cold boot, acceptance | blocked by L4 | none |

## 3. Evidence ledger (rev 12 additions)

| Fact | Evidence | Consequence |
| --- | --- | --- |
| A serving thread joins the pool and the call stays unclaimed | U285: two threads in `binder_ioctl_write_read`; `INTERFACE_TRANSACTION` unanswered; `tr 1` pending | binder is stalled below the HAL; park it |
| The HAL's API is a 14-entry table, version 2 | U286: probe output, offsets `+8`..`+112` | the API is a C struct, not AIDL |
| The service checks version > 0, calls entry `+8`, then `+16` | §1.3, service `0x84c8`/`0x84e8`/`0x859c` | entry `+8` is init, `+16` is create |
| Entry `+16` writes its result through `x1` and wraps `x2`/`x3` | `0xf77c-0xf79c`: `mov x19,x1`, `stp` functor, `str` through `x19` | ABI: `(options*, hal**, cb, ctx)` |
| The options object is 16 bytes | service `0x8524`: one `q0` copy into `sp+0x40` | a zeroed 16-byte options is the first safe call |
| The factory's RTTI names are data, not code | U287; xref search finds no code reference | do not read the table as symbol pointers |
| The DBA setup builder is at `0x1610cc`, submit at `0x161744` | U277 note; direct `bl` parents only inside the core | setup is reachable only through HAL objects/vtables |
| The service uses entries `+0x50`, `+0x58`, `+0x60` for its session work | service `0x9b54`-`0x9d10` | the table also carries session/execution calls; map after create |

## 4. Gate ladder (rev 12)

| Gate | Claim | State | Next |
| --- | --- | --- | --- |
| K | session, both FMQs, command round trip | **pass** | regression per boot series |
| A0 | firmware container and image config parsed | **pass** (U260) | F1 |
| D1 | the vendor DBA service publishes `IDevice/default` and stays up | **pass** (U279) | R1 only |
| D2 | a raw-binder client gets an AIDL reply | **blocked** (U285) | R1, parked |
| D2c | `GetDarwinnHalFunctions` returns a table with version 2 | **pass** (U286) | none |
| D2d | the table's factory returns a HAL object | **retired** (U316): the HAL is a service client and opens nothing | R-KCI |
| D0g | userspace sends a KCI command | **withdrawn** (U322): KCI is kernel-internal; ioctl 34 is `SET_DEVICE_PROPERTIES` | none |
| D0i | the KCI door's DMA buffer is one the firmware accepts | **pass** (U346): iremap pool; 12/21 answer 0 at 4096 B | none |
| D0j | the firmware dispatches the enum's missing code 6 | **partial** (U347): answers 14 UNAVAILABLE, not unknown-code 3 | P2b |
| D0h | the firmware reports its own version and protocol numbers | **pass** (U317): 1.0, VII 2, KCI 3 | none |
| D2e | the HAL object's setup path builds and submits the setup command | **open** | R0, stride S3 |
| D3b | the firmware's setup is done (gate probe answers differently) | **open** | R0 oracle |
| D3 | `createCompilationFromFile` (or its HAL equivalent) runs `CreatePredictor` | **open** | after D2d |
| E0a/E0b | mini model supported; DGC0 container verifies | **pass** (U253) | keep |
| E1 | RegisterGraph on the live core | **negative** (U256) | after D3b |
| E2-E3 | execution, bind, Invoke | blocked | after E1 |
| E4-E6 | CPU parity, repeat, cold boot, ten runs | blocked | acceptance |
| K1-K4 | kernel work for the product | open, independent | §8.8 |
| P1-P5 | package, docs, product | blocked | after E6 |

## 5. Closed routes (do not reopen without a new artifact)

Everything rev 11 closed, plus:

- **A serving thread as the fix for the DBA service.** U285: the pool grows and
  the queue still does not move. Do not re-run `android-dba-serve.c` expecting a
  reply; it is a diagnostic, not a fix.
- **`INTERFACE_TRANSACTION` as proof of the parcel.** It never enters
  `onTransact` and still gets no reply, so it only proves the queue.
- **The RTTI names as table indices.** U287: data-only references.
- **Entry `+112` as create.** It is a getter (calls `0xfd9bc` with a stack
  record, logs line 233, never touches `x1`).

## 6. The program

### 1.10 Rev 15: the corrected ledger

**Established.** The driver `edgetpu_platform` is bound to `1ce00000.janeiro`
and the firmware answers: `EDGETPU_FIRMWARE_VERSION` reports **1.0, VII 2,
KCI 3** (U317). Gate K passes: session, both FMQs and a command round trip. The
client API includes `CREATE_GROUP`/`JOIN_GROUP`/`FINALIZE_GROUP` and our client
uses them (U324). The vendor HAL opens **no** device node and waits (U316), so
it is a service client, not a driver.

**Refuted or withdrawn, with the record.** H2 (options layout, U307), H6 (our
fork, U306), H1 (no `ALooper_prepare` in the chroot's libandroid, U313), the
ptrace sampler (U302), "userspace can send KCI" (U322: ioctl 34 is
`SET_DEVICE_PROPERTIES`), "the property block is the setup path" (U323: no
consumer), "our client has no group" (U324), and "the rebuilt element is the
HAL's" (U324: it is our own producer's).

**Unknown, and the only thing worth a boot.** The **values** the vendor HAL
puts in that element, not its shape: the shape is now known exactly (U328:
eleven copied fields, `+0x20..+0x27` and `+0x2f` never written). The values come
from `SetupFirmware`'s command object, so the next offline step is that builder,
not another wire-format guess.

### 6.1 Track S — the in-process HAL (retired by U316; findings stand)

**S1 (R0, done): call the factory.** `tools/tpu-hal-harness.c`, built as a
preloaded `.so`, calls `table[0]` (init), then `table[2]` = entry `+16`, in a
child process under a 3 s alarm. With zeroed options the call dies `SIGSEGV` at
`0x0`; with the builder's exact output it allocates and blocks (U293-U297).
**Pass for the next run: a status in `w0` and a non-null `hal`**, which is
exactly what S2b has to make possible.

**S2 (offline, done for the options): the builder's output.** `0x11660` reads
`ro.board.platform` and its success path writes `{u32 1, u32 1, "/dev/edgetpu"}`
at `0x11a00`-`0x11a14`; feeding those bytes to the factory replaced the fault
with the wait (U292/U293). The remaining offline part is H2 and H5: every load
from `[x0]` in create's prologue, and every `GetProperty` key on that path.

**S2b (R0, done): the interposer runs, and the HAL never calls it.**
`pthread_cond_wait`, `pthread_cond_timedwait`, `sem_wait`, `pthread_mutex_lock`
and `pthread_join` are defined in the harness and exported (`llvm-objdump -T`);
the mutex one prints only on real contention (trylock first). A factory run
(`MODE=cw`) produces no `BLK` line (U304). So the wait is not reached through
those PLT symbols. Before using a silent run as evidence again, set `watch_pid`
**before** the semaphore self-test: today it is set later, so the control is
inconclusive.

**S2c (R0, next): remove our own `fork()` from the experiment.** Every factory
run so far forks first, and a child inherits locks held at fork time by threads
that do not exist in it, the classic fork-in-a-threaded-process deadlock. H6
fits every fact. Run the factory in the original process (alarm still on, the
call contained by the chroot process) or fork before the HAL is initialised. If
the factory then opens `/dev/edgetpu`, the wall was ours, not the HAL's.

**S3 (R0): drive the setup.** With a HAL object in hand, call the table entries
that take it (the service's own session path uses `+0x50`, `+0x58`, `+0x60`)
until one reaches the setup builder at `0x1610cc`; the oracle is the firmware
log. One attempt per boot, and the first TPU-touching call is the boot's one
power-up.

**S4 (offline): map the remaining entries.** For each of the 14, record the
callee (`0xf8df8`, `0xf920c`, `0xf9794`, `0xfa4e4`, `0xfb22c`, `0xfbd6c`,
`0xfcb04`, `0xfd054`, `0xfd11c`, `0xfd88c`, `0xfd924`, `0xfd9bc`), the argument
count and the object it dispatches on. This turns S3 from a search into a
lookup.

**S5 (R0): the session interface without binder.** Once create works, the
compilation path can be driven through the same table (the entries the service
uses around `0x9b54`), giving `createCompilationFromFile`'s effect without a
parcel. If the table has no path-based entry, G2's precompiled DGC0 goes
straight to E1.

**S6 (R1, parked): binder.** Two hypotheses only — our thread's `ProcessState`
differs from the service's, or the lazy registration returns a handle to a node
that is not the service's. Each needs one boot and a `/sys/kernel/debug/binder`
dump before and after.

### 6.2 Track F — offline facts that unblock D3b independently

**F1. The log-site index.** `tools/tpu-fw.py reach`; learn the logging
convention from 3-4 referenced sites; build `offset -> index`; read the gate
site's index and search the body. Pass: a named record format and the setup
messages' index.

**F3. The DBA AIDL table (still useful for R1).** `BnDevice::onTransact`'s
switch and `BpDevice::createSession`'s write order; turns R1's code sweep into a
lookup. Offline.

**F4. The HAL's setup builder.** `0x1610cc`-`0x161744`: record the command
vector and `cluster_id_bitset` it builds, and the object it dispatches on. This
is the artifact that says what S3 must reach.

### 6.3 Track G — graph format (after D3b)

**G1.** Retry the verified 12,288-byte DGC0 through the vendor path and the
direct harness; record which accepts it.
**G2.** A repeatable graph producer: the vendor compiler on-device in the
chroot, the same compiler on the laptop, or precompiled models only (ship this
first if the others need the device path).

### 6.4 Track E — execution

With D3b and G1: register the graph, create the execution, bind input/output
from `/dev/dma_heap/system`, Invoke, dump the raw output. A status 0 without a
non-empty tensor is not E3. One attempt per boot; record the raw reply and the
tensor hash; `CORES=1` if the core dies.

### 6.5 Track A — acceptance

`tools/tpu-acceptance compare` against the CPU reference; integer tensors
exact. E5: twice in one boot, then a cold slot-B boot. E6: ten runs, watching
for a second power-up, a leaked handle or an IOMMU fault. E7: close the session,
confirm `clients`/`mappings` empty and the KCI heartbeat alive; never `rmmod`
mid-boot.

### 6.6 Track P — product

**P1.** `omamobile-tpu run MODEL INPUT`, root-only first, JSON report from
`tpu-acceptance`. **P2.** `omamobile-tpu.service` gains `--self-test` (gate K
plus the mini model once E4 lands). **P3.** A `omamobile-tpu` group and udev
rule, or a daemon that owns the device; package it with `tpu-hold` and keep
`pr-check` and package tests green. **P4.** `docs/DEVICES.md` row and the
honest status line until E4. **P5.** Untrusted models are code for the TPU and
stay out of the product path until the graph verifier is trusted.

### 6.7 Track T — performance (after E4)

The 720p SSD benchmark is staged in `out/bench/`. Measure only after parity:
mean/p95, detections per frame, thermal and battery.

### 6.8 Track K — kernel work the product needs

K1 one power-up per boot enforced and loud; K2 IOMMU faults kill the client,
not the phone; K3 teardown and recovery; K4 power and thermal under a real
workload.

## 7. Stock-oracle runbook (owner-gated)

1. **Preflight (read-only).** `tools/tpu-stock-capture check`; the NV backup and
   the saved slot-B image set must both verify.
2. **Physical Fastboot.** Volume Down + Power, about 20 s; `fastboot devices`.
3. **Slot flags (read-only).** Expect `b`/`yes`; stop otherwise.
4. **Ask explicitly for `fastboot --set-active=a`**; record the flags again.
5. **Boot stock and capture (read-only).** `tools/tpu-stock-capture capture
   PRIVATE_DIR`: dmesg, `getprop`, the first `vii-elem`/`vii-payload`, who opens
   `/dev/edgetpu`, the firmware hash, the DBA service's log.
   The capture must answer three questions: does stock's dmesg print a firmware
   setup line (stock's driver decodes the telemetry ring too)? does the DBA
   service log `SetupFirmware` or `Firmware setup failed`? and what is the
   firmware build (`sha256sum /vendor/firmware/edgetpu-janeiro.fw`)? Do not
   expect the VII element itself unless stock's driver logs it. `capture`
   writes `dmesg-setup.txt`, `logcat-setup.txt`, `fw-sha256.txt`, `fw-ls.txt`
   and `tpu-service.txt` for exactly those; nothing else on stock is needed.
6. **Rollback.** `fastboot --set-active=b`, boot the saved set, verify SSH and
   `omamobile-boot-success`, then a fresh `tools/nv-backup`. On the recovery
   screen choose neither "Try again" nor "Factory data reset".
7. **Record.** Flags, boot times, the private path (never its contents).

## 8. Software-only runbooks

### R0 (phone, no reboot): the in-process HAL

1. Build and push: `out/tpu-client/libhalharness.so`, then run inside the
   chroot with `LD_PRELOAD` under the standard bionic library path.
2. `MODE=census`: print the table, the version word, and call entry `+8` (init).
   This touches no device.
3. `MODE=create`: fork, alarm 3 s, call entry `+16` with `options` zeroed and
   `&hal`; print the status and the handle. Stop on a signal: record which
   entry and which argument.
4. If `hal` is non-null: `MODE=session` calls the next entries the service uses
   (`+0x50`, `+0x58`, `+0x60`) in increasing order, one per run.
5. Oracle after every create attempt: `dmesg | grep -E 'Setup|scratch|vii-'`
   and a `T10=11` probe. Pass: any line other than the gate, or a VII reply
   other than `0xf000009`.
6. Stop after three boots without a factory status; then S2/S4 must name the
   options and the entries before another attempt.

### R0b (phone, no reboot): sample the blocked create

1. `tools/phone-ssh 'cat > /root/tpu-sampler.c' < tools/tpu-sampler.c`, then
   `gcc -O2 -static -o /root/tpu-sampler /root/tpu-sampler.c` on the phone.
2. Start the factory with the builder's options and no fork:
   `MODE=create NOFORK=1 tpu-exec.py daemon create /vendor/bin/edgetpu-run`
   (the phone's `tpu-exec.py` passes `MODE` and `NOFORK` through).
3. `/root/tpu-sampler PID --wait 5 --stack 16384`: every futex thread's comm,
   uaddr, word, pc/lr/sp and each stack word that lands in a mapping.
4. **Pass:** the blocked thread's stack resolves to module+offset, and its
   futex word is readable. **Stop:** if no thread is in futex after 5 s, the
   wait moved and the run needs a fresh `MODE` before another sample.
5. Kill the target; nothing here touches the device or the power-up.

6. `MODE=create` with the callback-logging harness prints `CB event=… arg=…`
   for every host callback; zero lines in 3 s means the wait is not the host's
   contract (1.20).

### R1 (phone, no reboot): the binder session (parked)

Start the chain (`NO_DELEGATE=1 DBA=1`), confirm the service pid and its HAL
line, then `tools/tpu-binder-client` with
`NAME=com.google.edgetpu.dba.IDevice/default`. Do not retry a code that reset
the phone. Before any retry, dump `/sys/kernel/debug/binder/proc/<pid>` for the
service and compare it with the client's own entry.

### R2 (one reboot): the first-power-up variant

As R1 with `NO_HOLD=1`, only if a session is refused because `tpu-hold` already
took the power-up. Reboot is owner-gated; stop the modem first.

### F1 / F3 / F4 (laptop, no phone)

As rev 11, unchanged, with F4 now pointed at `0x1610cc`.

## 9. State, risks and recovery

- **State at rev 12.** Slot B, kernel
  `7.3.0-rc6-omamobile-push1-ga78d26f63e56-dirty`; `janeiro` loaded with
  `chip_model`; `tpu-hold` holds the boot's one power-up; gate K proven; the
  DBA service runs when the chain starts it; the HAL table is mapped; the
  factory call is the next step; no model output.
- **Risk register.** Factory call with wrong options: a crash in the chroot
  process (contained) or, if it reaches the device, a PSM wedge that costs a
  reboot (owner-gated). Second power-up: wedge. Stock boot: NV rewrite.
  Binder: stale nodes. Graph: a core reset.
- **Recovery.** Kill the harness process; a wedged TPU needs a reboot, which is
  the owner's call; a package by the previous rootfs; stock by
  `--set-active=b` plus the saved set and a fresh NV backup.

## 10. Decision tree

```
gate K fails? -> stop: driver/session regression.
  -> R0 D2c table? (yes, U286)
     -> R0 S1 factory status 0 and hal != null?
          |--yes--> S2 name options -> S3 drive setup -> D3b?
          |           |--yes--> G1 DGC0 -> E1 -> E2 -> E3 -> E4..E7
          |           |--no---> F4/S4 name the setup entry -> S3 again
          |--no---> S2 (options layout) -> S1 again
                      after 3 boots -> R1 binder, or R3 stock oracle
  -> D3b fails either way -> F1/A5' static, or A10 matched A14 set
  -> R3 stock oracle whenever the human is at Fastboot.
```

### 1.12 Rev 16: the builder's conversion, and no observation channel

`SetupFirmware` walks a vector of 24-byte commands and converts each with
`0x14d9e60`, which stamps the object's type byte with **5** and stores a pointer
to a freshly allocated **24-byte payload** (U331). That is the same type 5 the
element carries at `+0x0a` (U328), so the builder side and the wire side finally
agree: the unknown values are the payload's three words.

There is no observation channel on this kernel: no dynamic debug (U330) and no
ftrace or kprobes (U332) - `/sys/kernel/debug/tracing/` is absent and the config
has no tracer options. So every step must be judged by the firmware's own reply
or by `dmesg` lines the driver prints at normal level, and no step may promise
"we will see it in the trace".

**Correction (rev 17, U335):** that holds for *kernel* tracing only. The
firmware's own log reaches dmesg through the driver's telemetry decode, which is
a real observation channel; see 1.13.

### 1.13 The firmware log is the oracle (U335)

The kernel cannot trace (U332), but the firmware can talk. The driver decodes the
firmware's telemetry ring (`edgetpu_fw_log()`, `edgetpu-telemetry.c:126`) into
kernel lines, dropping only verbose and debug entries, so every KCI command now
returns a verdict and a refusal explains itself in the firmware's own words:

    kci_send code 12 tpu_addr 0xffff9000 len 0 -> 3
    ERR tpu_kci_handler_thread.cc:101 - DMA descriptor is invalid

`-> 3` is `KCI_ERROR_INVALID_ARGUMENT`, `-> 0` is OK, `-> 12` is UNIMPLEMENTED.
The door is `tools/tpu-oracle`:

    CODES="11 12 21 8" tools/phone-ssh 'bash -s' < tools/tpu-oracle

`fw_tracing/request` is a second, independent round trip: a level without bit 8
(`EDGETPU_FW_TRACING_DEFAULT_VOTE`) makes `active` report the firmware's own answer
(255 -> 1, 0 -> 0), while any level with bit 8 reads back masked as 256.

What this does not give us: KCI has no setup code. The enum (`edgetpu-kci.h:103`)
has ACK, the two buffer maps, join/leave group, shutdown, debug dump,
open/close device, firmware info, usage v1/v2, throttling, bus-speed control and
tracing level - nothing that carries firmware setup. The setup element is a
Tachyon-queue command, so it goes through the cmdq, which is the path U326 mapped.

### 1.14 The address checklist (U340)

Every address this plan leans on, and what makes it trustworthy:

| Address | Claim | Basis |
| --- | --- | --- |
| `0x152977c` | enqueue = base + (tail & 0x3ff) * 0x30 | instructions read |
| `0x152989c` | fill copies exactly 11 fields | instructions read |
| `0x1529648` | a validator, not a filler (U326) | instructions read |
| `0x14d9e60` | converter stamps union type 5 + 24-byte payload | instructions read |
| `0x14d9df8` | vector reserve/insert, stores nothing (U334) | instructions read |
| `0x14d9b54` | entry address = data + i * 24 | instructions read |
| `0x14d9b64` | entry filled from `{x22, w0}` at run time | instructions read |
| `0x14d9c74`, `0x14d9eac` | the per-entry fill path | **not read end to end** |
| `0xcc7c24` | entry constructor from a 3-word tuple | **not read** |

A row marked "instructions read" may be cited as fact; a row marked "not read" may
only be cited as a hypothesis, and any claim used in a runbook has to add its row
first. Three of the plan's last four "the source is X" statements were refuted by
the next window (U333, U334 and the vector filler), which is what the rule is for.

A third conclusion belongs to rev 18: the DMA **address** was the wall, not the
command. `edgetpu_iremap_alloc(..., EDGETPU_CONTEXT_KCI)` is the only allocator
on record whose addresses the firmware accepts for a descriptor (1.16); a
`0xfffxxxxx` page is refused before any handler runs.

Two conclusions close out the builder route:

1. **The values cannot be recovered statically** (U339). The entries are built at
   run time from HAL object state (`0x14d9b1c` virtual call -> x22 ->
   `0x14d9b64`), so no further disassembly yields them.
2. **They are not needed for a send.** The cmdq path (U326/U328) accepts the element
   we build; the open question is the firmware's verdict, and that is now readable
   (U335). The element route and the oracle route meet here.

### 1.15 The builder's real shape: 40-byte records, 16-byte values (U342/U343)

Rev 16 read `SetupFirmware`'s loop as a vector of 24-byte commands. It is not.
Two helpers disambiguate it, and both were already captured:

| Function | Divides by | Object |
| --- | --- | --- |
| `0x14d9df8` | 24 | an array of `std::vector` (begin, end, cap) |
| `0x14d9e2c` | 40 | the builder's own record |

`0xcc7c24`, called in the middle of the loop, is `std::vector::push_back` for a
**16-byte** element: `ldp x8,x9,[x0,#8]`, and `ldr q0,[x1]; str q0,[x8],#0x10`,
with a grow path that computes `(end-begin)/16 + 1` (U342). The fill loop walks
the records with `x26 += 0x28` and indexes a parallel byte array
(`ldrb w3,[x8,x23]`), calling `0x14d9eac` per record (U343).

So the pipeline is: **a 40-byte record per compiled command, converted to a
type-5 payload, and pushed as a 16-byte value into a per-index vector**. That is
why the payload in the element (`+0x0a` type 5, `+0x0b` five bytes) never matched
a "command": the command is the 40-byte record, and the 16-byte pushes are the
per-command lists.

What this changes for the plan: the remaining unknown is not "the three words of a
24-byte command" (that object does not exist) but **the fields of a 40-byte
record**, which `0x14d9eac` converts. That is the next offline read, and it is the
only one that can produce a setup element with a chance of passing the gate.

### 1.16 The DMA window: why every buffer-touching command failed (U346)

The debugfs hook allocated its page with
`edgetpu_alloc_coherent(..., EDGETPU_CONTEXT_DOMAIN_TOKEN)`, which lands in the
driver's context domain at `0xfffxxxxx`. KCI's own buffers - the queues, the
usage buffer, the firmware-info buffer - go through
`edgetpu_iremap_alloc(..., EDGETPU_CONTEXT_KCI)` and land at `0x101xxxxx`
(`mappings` reads `cmdq 0x10150000`, `rspq 0x10158000`). Only the second is
inside the firmware's address window, so every command that actually touched
the descriptor was refused before its handler ran:

| code | before (`0xfffxxxxx`) | after (`0x101xxxxx`) |
| --- | --- | --- |
| 11 FIRMWARE_INFO | 0 | 0 |
| 12 GET_USAGE_V1, 16 B | 3 "DMA descriptor is invalid" | 3 "buffer too small: got 128, want 4092" |
| 12 GET_USAGE_V1, 4096 B | 3 | **0** |
| 21 GET_USAGE_V2, 4096 B | 3 | **0** |
| 1 UNMAP_BUFFER | 0 | 0 |
| 15 (unnamed) | 3 "Invalid ... descriptor address" | 3 "Invalid ... descriptor size N" |
| 16 (unnamed) | 3 "Invalid ... descriptor address" | 3 "Invalid ... descriptor size N" |
| 6 (the enum's gap) | 3 (12 on the A14 image, U276) | **14 UNAVAILABLE** |

Four consequences:

1. **U341's flags hypothesis is withdrawn.** The descriptor was never
   malformed; it was outside the window. The usage queries work, and the
   oracle now has a real DMA channel: `GET_USAGE` at 4096 bytes answers 0.
2. **The window is a rule for every future hook.** A buffer the firmware reads
   or writes must come from the iremap pool. `kci_scratch` now does, and
   `kci_dma` sends with the whole scratch as the descriptor for the commands
   that validate its size.
3. **Codes 15/16 are implemented on this firmware.** They check the address
   first and then the size; the address is now accepted, and 16, 128, 512,
   1024, 2048, 4096 and 524288 are all refused as sizes. The iremap pool caps a
   scratch at 512 KiB, so a larger exact size cannot be tested through the
   door, and code 15/16's name is still unknown (U347).

4. **The door reads back (U349).** `kci_result` returns the last command's DMA
   buffer, so `GET_USAGE_V1`'s 4096 bytes are readable: a v1 header
   (`num_metrics` 17, `metric_size` 20 - `EDGETPU_USAGE_METRIC_SIZE_V1`) and
   real counters (225488, 967000, 712000, 1250000, 1066000). The firmware is
   now talking in data, not only verdicts.

Code 6's `UNAVAILABLE` is constant across a page and the scratch, 128- and
4096-byte payloads, and with a client open (`tpu-hold`); 1.18 now names what it
is: a mitigation request, not setup.

### 1.17 The read channel (U349)

`kci_result` (0444) hands back the last KCI command's DMA buffer, copied after
the send returns; `kci_send` also logs the descriptor's `size`. With 4096 zero
bytes in `kci_payload` and code 12, the firmware writes a v1 usage report:

    offset 0x00: u32 num_metrics = 17
    offset 0x04: u32 metric_size = 20      (EDGETPU_USAGE_METRIC_SIZE_V1)
    metrics from 0x08, 20 bytes each; the first five counters are
    225488 967000 712000 1250000 1066000

The driver's `edgetpu-usage-stats.h` names the fields and the counter types. The
same patch passes the firmware's **debug and verbose** log entries to dmesg at
info level, because this kernel has no dynamic debug and `etdev_dbg` drops them;
that is where a refused command explains itself (U350).

### 1.18 Code 6 is a mitigation request, not setup (U350)

The driver's enum skips 6, and the plan treated that gap as the last possible
KCI setup command. It is not. With the debug entries visible, a code-6 send
answers 14 `UNAVAILABLE` and says why:

    ERR power_manager_interface.h:99 - Mitigation is not configurable by the firmware.

That is a power/thermal mitigation request, not firmware setup. The gap is power
management; the branch is closed on this firmware (on the A14 image it answered
12, U276). Do not send 6 again expecting setup.

### 1.19 The wait, named from outside (U354-U356)

`tools/tpu-sampler.c` is a standalone aarch64 binary (gcc 16 on the phone,
static). It attaches to every thread of a target, reads registers with
`PTRACE_GETREGSET`, prints `pc`/`lr`/`sp` as module+file-offset from
`/proc/<pid>/maps`, and scans the user stack with `process_vm_readv` for words
that point into executable mappings. The in-process hook could not do this
(1.6); a separate process can.

Against `MODE=create NOFORK=1` with the builder's options, in one boot:

    tid 7258 (edgetpu-run) futex uaddr 0xffff9092c180 word 0
      runtime+0x1202a4 +0x1253a0 +0x1254d4 +0x125aa8 +0x12292c +0x123c8c
      +0x11d18c +0x11d1ac +0x11d32c +0x113d34 +0x11c900 +0x113c84
      +0xf8b04 +0xff55c +0xfd4c8 +0xf908c +0xf77a4, edgetpu-run+0x2c64
    tid 7259-7261 futex uaddr 0xffff91bdeb90 word 0x4002 (all three)
      runtime+0x125664 +0x125578 +0x126460 +0x125518 +0x21432c +0x12afbc

Three facts follow. **The wait is inside the runtime**, not bionic: every frame
between libc's futex path and the harness is
`libdarwinn_dba_hal_runtime.so`, and that library exports exactly one symbol
(`GetDarwinnHalFunctions`), so the plan can only name offsets. **Three workers
share one futex word** while the main thread waits on another whose word is 0:
an idle pool and a caller waiting for a notification nothing sets. **No device
fd exists at the wait** (only `/tmp/tpu-mode`), which reconfirms U293 from
outside the process.

That also explains S2b's empty log: the runtime reaches `futex` from its own
code, so interposing `pthread_cond_wait`, `sem_wait` or `pthread_join` cannot
see it. The next instrument is not another interposer but reading the object
around the main thread's uaddr and the worker word (0x4002), and finding the
runtime function that stores the value the main thread waits for.

Runbook (phone, no reboot): `gcc -O2 -static -o /root/tpu-sampler
/root/tpu-sampler.c`, start `MODE=create NOFORK=1` through `tpu-exec.py`
(`MODE` and `NOFORK` must be in its pass-through list; the phone's copy now
is), then `/root/tpu-sampler PID --wait 5 --stack 16384`.

### 1.20 The event manager, and the callback that never rings (U358-U360)

The wait's own code is now read. `0x333054` is a `WaitForEvent` wrapper: it
converts the timeout through `0x334f88`, calls `0x332e88` with the deadline and
returns `w0 & 1`; `0x333098` is the infinite-timeout twin (`x2 = -1`). Around
it, the runtime's strings name the machinery: `event_waiter_->WaitForEvent()
.status() is OK`, `WaitForEvent failed for unknown reason`, `thread/executor.cc`,
`base/scheduling/scheduler.cc`, `eventmanager2`, `threadpool`, `default_executor`
and `Unable to apply performance option to the DBA event_manager thread.` So
`Create` starts Google's `thread` executor and waits in its event manager.

The event loop dispatches through the event's own thunk: at `0x332f20` it loads
`x9 = [event+0x20]`, clears `[event+0x20]`, and `blr x8`. An event therefore
carries its callback; a posted event runs, an unposted one leaves the manager
asleep.

**The host callback is never called.** The harness's callback now logs every
invocation (`CB event=… arg=…`, `tools/tpu-hal-harness.c`), and a 3 s
`MODE=create` run produced **zero** `CB` lines before the alarm. So the wait is
not the HAL asking its caller to do something - the harness's peer is never
invoked. The runtime is waiting for an event its own machinery should post, and
nothing does. The memory 32 bytes either side of both futex words is eight zero
words, so the object state is not beside the word.

Next instrument: a **futex syscall tracer** (a standalone aarch64 binary driving
`PTRACE_SYSCALL` over `pidfd_getfd`/`PTRACE_SEIZE`, logging `FUTEX_WAIT` and
`FUTEX_WAKE` with `uaddr`, `val` and the timeout). That records whether anything
ever wakes the main thread's uaddr and what it writes, which the sampler cannot
see because it only reads state between calls.

**The wait is bionic's condition variable (U361).** `strace` is not installed on
the phone, but gdb 16 is, and `catch syscall futex` works. One catch on the
blocked create:

    Catchpoint 1 (syscall 'futex' [98])
    FUT x0=0xffff94788b90 x1=0x89 x2=0x4002

`x1 = 0x89 = FUTEX_PRIVATE_FLAG | FUTEX_WAIT_BITSET`, `x2 = 0x4002`: the
runtime waits in **bionic's condition-variable implementation** with the worker
word as its expected value, private and clock-relative. That refines U356: it
is not a hand-rolled futex, it is a condvar whose entry point the runtime
reaches through bionic's internal symbol rather than the public
`pthread_cond_wait`, so a `LD_PRELOAD` interposer of the public name is bypassed
by construction. The gdb script is the tracer for now: `catch syscall futex`,
print `$x0..$x2`, continue. It must attach **before** the wait to capture the
main thread's own wait.

### 1.21 The wake that never comes (U362)

The tracer ran for 20 s from before the wait, so the question "is a poster slow
or absent" is answered by accounting, not by a sample. The two blocked words
and every wake in the run:

    0.102 tid 17802 WAIT_BITSET uaddr 0xffff8aa1db90 val 0x4002     (worker)
    0.107 tid 17803 same word, frames runtime+0x21432c +0x12afbc +0x11139c
                                       +0xff5b8 +0xff55c          (worker)
    0.109 tid 17801 WAIT_BITSET|CLOCK_REALTIME uaddr 0xffff8a821180 val 0
          frames runtime+0x33003c +0x30f760 +0x332f20 +0x332f5c
                 +0x333088 +0x1202a4                              (main)
    20.0 killed; 0xffff8a821180 waits 1 wakes 0 woken 0;
                  0xffff8aa1db90 waits 3 wakes 0 woken 0

Five wakes do appear, all before 0.11 s, all on per-thread condvar words
(`0xfffc...`), all issued by the main thread as it creates the pool, and each
wakes exactly one task. **Nothing ever calls `FUTEX_WAKE` on the two words the
create and the pool wait on.** So the runtime is not waiting for a slow poster;
it has no event source at all. The 3.8 MB library is the *client* half of a
pair whose peer is absent, which also explains the empty queue check at
`0x332fe4` (`waitp.thread->waitp != nullptr`, `mutex.cc`). R3 stops being "our
fork's bug" and becomes "we drive the wrong component".

### 1.22 Two Hal libraries, and the one the harness drove (U363)

Both libraries export `GetDarwinnHalFunctions`: the 3,785,000-byte
`libdarwinn_dba_hal_runtime.so` at `0xf772c` and the 37,089,408-byte
`libdarwinn_hal.so` at `0x83130c`. The harness's own string loads
`/vendor/lib64/libdarwinn_dba_hal_runtime.so`, so every in-process create this
plan recorded ran the **client** shim - the one that now has no peer. The 37 MB
library is the one that carries `SetupFirmware` and the type-5 stamp (1.15,
U262, U331); `tools/edgetpu-run` loads it only in its `hal`/`halcall` modes, and
its A17 device path has reset the phone before (A9). So the next in-process
attempt is that library, not the shim: one attended boot, `tpu-hold` alive, and
a reset is the stop condition.

### 1.23 Code 15/16's descriptor size is a named gate (U364)

The firmware names its own check: `ERR tpu_kci_handler_thread.cc:298 - Invalid
KCI DMA descriptor size N.` Through the debugfs door `cmd.dma.size` is the
payload length (16 when empty), or the whole `kci_scratch` allocation with
`kci_dma`. A sweep of 1, 2, 4, 8, 12 ... 4096 and 8192 ... 524288 answered
`-> 3` **for every value**, with that line quoting the same number. So the check
is neither a small struct size nor a page or pool size, the codes stay unnamed,
and this axis is exhausted the way P1's was: a new attempt needs the handler's
constant, not another length. The static route is blocked the same way: the
string at `0x100e7554` has no 32-bit literal and no `movw`/`movt` pair anywhere
in the decoded body, so it is reached through the log-site index (U178), not by
an address reference.

### 1.24 The kernel's setup handler is firmware image loading (U365)

`mobile_firmware_setup_buffer` (`mobile-firmware.c:382`) is called by
`edgetpu_firmware_load_locked` for each run. It GSA-authenticates the image,
copies the version words out of its image config, checks the image against the
carveout, and builds or clears the TPU's IOMMU mappings. It sends no command. So
U275 stands with its code read end to end: the driver carries no producer for
the firmware's VII setup, and the name `mobile_firmware_setup_buffer` is not the
missing piece.

### 1.11 The KCI door, corrected (U329)

Userspace reaches KCI through **debugfs**, not an ioctl:
`/sys/kernel/debug/edgetpu/janeiro/{kci_payload,kci_scratch,kci_send}`. It is the
path U266's code-6 sends used and, since U335, the working oracle. The protocol,
read from the handler (`edgetpu-fs.c:1116` and `1142`):

1. write the DMA payload bytes (up to one page) to `kci_payload` - this only
   stores them and the length;
2. write the **decimal command code** to `kci_send`; the driver allocates a page,
   copies the payload in, sets `dma.size = len` (16 when the payload is empty),
   sends, and logs `kci_send code N tpu_addr A len L -> R`.

`R` is the firmware's KCI error and, when it refuses, the firmware's own `ERR`
line follows it in dmesg (1.13). The handler's `dma.flags` was the suspect for
the usage queries (U341); it was not the problem. The descriptor's **address**
was, and it is fixed (1.16). The hook now allocates from the iremap pool, logs
the descriptor's size, and `kci_dma` (write 1) makes it send with the whole
`kci_scratch` allocation instead of its page.

The driver's join-group log is `etdev_dbg`, and **dynamic debug is not compiled
into this kernel** (`/sys/kernel/debug/dynamic_debug/control` is absent, U330),
so that line cannot be turned on. Do not plan to confirm the group handshake
from `dmesg`; use the firmware's own reply, or a kprobe on
`edgetpu_kci_join_group` if function tracing is configured.

## 11. The program to a working TPU (rev 40)

Rev 23 adds U372-U374: code 15 reaches the VII scheduler, and its payload
is a self-describing VII input. Rev 22 supersedes the route table of rev 19-21; its new fact is U366: KCI code
15 has a **64-byte** payload, not an unguessable one. The old §11 rows stay in
the history; this section is the live program.

### 11.1 The wall, in one sentence

The firmware's one-time VII setup has no producer reachable from Linux, and the
KCI command family that might carry it has just given up its descriptor size:
**64 bytes for code 15**.

### 11.2 What is proven, and what it rules out

| # | Fact | Evidence | Consequence |
| --- | --- | --- | --- |
| 1 | the TPU is alive; KCI works; the VII door reads and writes | `tpu-hold`, KCI 21, gate K | transport is not the wall |
| 2 | every VII command before setup is gated, whatever its code or class | U249, U273, U277 | guessing VII fields is closed |
| 3 | the gate's `type 0` is a placeholder, not our byte | U175 | stop reading the type as a selector |
| 4 | KCI's enum has no setup; 6 is power mitigation; 15/16 are implemented | U269, U350, U346 | only 15/16 can hide a setup family |
| 5 | **code 15's descriptor size is 64** | U366: 63/65 refused by name, 64 accepted, reproducible | the size gate is satisfied |
| 6 | a zeroed 64-byte payload never answers (`-110`) and once logged `firmware unrecoverable crash` | U366 | the handler dereferences the payload |
| 7 | the firmware logs only at error level (`request 15` -> `active 1`, no new lines) | U369 | no debug oracle on this build |
| 8 | no public Google source has the producer (gs101 vendor driver: same enum; Coral runtime: none) | U367 | R5 is closed by source, not opinion |
| 9 | the vendor HAL is a service client (no device fd, no poster) and its direct path reset the phone | U362, U154/U174 | in-process HAL routes are parked |

### 11.3 Route census (live)

| Route | What it needs | Verdict | Next |
| --- | --- | --- | --- |
| R1 KCI gap codes | a payload that is not rejected | **closed as a producer** (U380: eight payloads, one CHECK; A14 lacks the command) | transport only |
| R2 VII element | a producer's exact values | closed (U249/U273/U277) | do not resend |
| R3 DBA HAL shim | a peer that posts events | closed (U362: no wake at all) | - |
| R4 37 MB HAL direct | a device path that does not reset | parked (U154/U174; payload already captured) | only with a new field |
| R5 public-source port | a public producer | closed (U367) | - |
| R6 stock oracle | owner, physical fastboot, **and acceptance that stock may format the Arch userdata** | owner-gated | §7, §11.5, runbook `TPU-STOCK-ORACLE.md` |
| R7 firmware static: code 15's handler | the per-code table and the 64-byte struct | **open, primary offline** | A2 |
| R8 firmware self-description | logging/state queries | tracing closed (U369); `fw_info.spare[]` still unread | A4 |
| R9 kernel/product work | independent of setup | open | §6.8 stays |

### 11.4 The live program

**A1 (phone, no reboot, one send per boot). Re-prove code 15 at 64.**
`head -c 64 /dev/zero > kci_payload; echo 15 > kci_send`, then read the log.
**Pass:** `-110` with no reply, and KCI 11 still answering 0 after it.
**Stop:** if 64 now answers 3, the door's state changed (dma override, scratch)
and the sequence must be re-established before anything else. **Never** send 64
in the same boot twice: the handler faults.

**A2 (laptop, no phone). Find code 15's handler and the 64-byte struct.**
The firmware checks `desc.size` against a per-code constant at
`tpu_kci_handler_thread.cc:298`, so a per-code record exists that carries `64`
for code 15. Search the image (`out/tpu/edgetpu-janeiro.fw`, island
`0xe0000..0xfd7c0`) for a table whose entry at index 15 holds 64 next to a Thumb
pointer, then disassemble that handler and map its `[x0+off]` reads.
**Pass:** a field map for all 64 bytes. **Stop:** if the table is not found in
one pass, the fallback is A3's differential oracle.

**A3 (phone, one payload per boot). Turn the fault into an error.**
With the struct's first fields unknown, the cheapest differential is: all zeros
(known `-110`), then `{valid iremap addr, 64, 0, ...}`, then four `{addr,size}`
pairs. A `3` means the layout was parsed and validated; `0` means accepted;
`-110` means the handler still dereferences a zero. Record which byte offsets
change the verdict, one per boot, and never two payloads in a boot.
**Pass:** any verdict other than `-110`.

**A4 (phone, free). Read `fw_info.spare[10]`.**
Code 11 answers 0 with `{build_time, flavor, changelist, spare[10]}`; the spares
have never been printed. If one is a state word, it names what setup waits for.

**A5 (owner-gated). The stock oracle**, unchanged in method (§7) but with an
added, explicit risk: stock Android on slot A sees an Arch `userdata` it cannot
decrypt and may format it (the 9a precedent in AGENTS.md). So this route needs
the owner's acceptance of losing the install, or a second device.

**A3b result (2026-11-14, rev 24).** Class bytes 0x01, 0x02 and 0x0b at payload
`+0x0a` give the identical `vii_scheduler.cc:864` assertion and backtrace, so the
byte is not the selector (U375). A3c is therefore a shape differential, not a
value differential: self-pointer at one offset with zeros elsewhere, one shape
per boot, three shapes queued (`+0x00`, `+0x04`, `+0x08`); a shape that stops
asserting names the field the scheduler requires.

**A3 result (2026-11-14, rev 23).** A3 is no longer a blind differential. The
door publishes the payload's firmware address (`tpu_addr`, U372), so a 64-byte
payload can point at itself. Sixteen copies of that address reach the firmware's
**VII scheduler** and trip `vii_scheduler.cc:864 ASSERTION FAILED` with an
eight-frame backtrace (U374), where the zero payload had only crashed. So code
15 is the KCI face of the VII scheduler: the gate's userspace path and this
command meet in the same component. The new program step is **A3b**: decode the
assertion at `0x100D3B66`/`vii_scheduler.cc:864` for the condition it checks
(element class, type or count), then set that byte, not the pointer, one value
per boot. A3's older payload ladder stays as the fallback. Code 8 is
UNIMPLEMENTED (U373), so there is no dump oracle.

### 11.4a Rev 25: what four boots taught, and the corrected program

U375 (class byte) and U376 (pointer at three different offsets) are one result:
**no field-level value changes code 15's verdict.** All-zero bytes crash,
anything else trips `vii_scheduler.cc:864`. The check is therefore about whether
the buffer is a well-formed VII element, and code 15 is the kernel-facing entry
to the same wall the userspace door meets - not a way around it.

That changes the program rather than ending it:

- **A3d (next, phone).** Build the 64-byte payload as a VII element using the
  layout the kernel itself submits (`edgetpu-fs.c` builds map-buffer elements):
  set the element's class/type to the map-buffer command with a valid self
  address and a length, one element per boot.
- **A3e (laptop).** Recover the element layout from the driver's own encoder
  rather than from guesses; that is the only in-tree definition of a VII element
  we can cite.
- **A5 (owner).** The stock oracle climbs from "useful" to "the only proven
  producer", but keeps its new risk: stock may format the Arch `userdata`.
- **A2 (laptop, unfinished).** The per-code table hunt did not land (unaligned
  sweep noise, capstone stopping at undecodable bytes); a real disassembler over
  the extracted code region is owed before it is called closed.

### 11.4b Rev 26: the gap commands are A17-only, and the payload is an element

Two results change the program's direction:

1. **The firmware path matters.** `updates/google/edgetpu-janeiro.fw` shadows
   the base copy, so the first A14 swap was a no-op (U378). Every firmware test
   must target the `updates/` file and confirm the boot's `fw_info` matches the
   image's expected build before trusting a result.
2. **Code 15 exists only on A17.** On the real A14 (build `0x6487a25e`) code 6
   answers 12 and code 15 answers 12 UNIMPLEMENTED with no assertion (U379).
   On A17 (build `0x69d449f1`) code 15 passes the 64-byte size gate and then
   asserts in `vii_scheduler` for every payload we can build. So the command was
   added with A17, and its handler validates a VII element.

That makes **A3f** the next live step: build the 64 bytes as one or two
`edgetpu_command_element`-shaped records (seq, code, reserved, dma{address,size,
flags}) with the self address, and read the assertion as the validator's answer.
It also promotes the hypothesis in R4: the A17 vendor HAL's setup most likely
uses exactly this command, which is why the A17 HAL knows a payload shape no
public source contains. A5 (stock oracle) remains the externally proven route
and keeps the userdata risk.

### 11.4c Rev 27: the gap route is exhausted, and the plan turns outward

Eight payloads across four structural classes all reach the same CHECK, and the
command does not exist on A14. That is not a validator failing to recognise an
element; it is a stub that refuses host calls. Consequences, stated plainly:

- **R1 is closed as a producer.** Code 15 stays interesting as the A17 HAL's
  probable transport, but it can no longer be expected to reveal the element.
- **R6 (stock oracle) is now the only externally proven producer.** Its risk is
  unchanged and must be accepted by the owner in writing: stock Android on slot
  A sees an encrypted Arch `userdata` and may format it.
- **R9 proceeds now, not after setup.** The kernel and product work does not
  depend on the firmware being set up, and it is what makes the eventual setup
  usable: K1 (one power-up per boot, loud), K2 (an IOMMU fault kills the client,
  not the phone), K3 (teardown that leaves the heartbeat alive), K4 (power and
  thermal), plus the `omamobile-tpu` skeleton speaking `/dev/janeiro` ioctls and
  a self-test whose report names this wall honestly instead of failing silently.

**G0 is the single gate.** G1-G5 (register, bind, invoke, parity, repeat) are
written and blocked on G0 alone; nothing else in the ladder is blocked. A
failure to reproduce stock's capture on A17 is the falsifier that would close
the firmware itself, and that is the next decision the plan asks for.

**R9 task list (rev 28, no dependency on G0).** Each item is a proof, not a
patch list: K1 one power-up per boot, enforced in the driver and loud in dmesg
when a second is attempted; K2 an IOMMU fault tears down the client and leaves
the phone alive (fault injection in a test build); K3 teardown after a submit
leaves KCI 21 answering, proven by `tools/tpu-status` before and after; K4 power
and thermal, measured with `tools/power-ab` on an idle TPU. The product skeleton
is `tools/tpu-status` today - a read-only report that names the wall - and grows
into `omamobile-tpu run` only once G0 holds, so the product path never depends on
a debugfs bring-up hook.

**K1 patch plan (rev 29, gated).** The count belongs where the driver powers the
TPU on, once per boot, kept in `struct edgetpu_dev`; a second attempt logs one
`etdev_err` line naming the caller and returns `-EBUSY` instead of powering up.
Proof, in this order: build with `W=1`; boot and read `tools/tpu-status`; run the
existing `tpu-hold` start twice and confirm exactly one power-up line and one
`-EBUSY`; reboot and confirm the count resets. Nothing here touches setup, which
is why it can proceed while G0 is blocked.

**Product skeleton landed (rev 30).** `packages/omamobile-tpu` carries the first
shippable piece: `omamobile-tpu [--json]` reports kernel, device, firmware build
id and the gate by name, and `omamobile-tpu-status.service` journals it once per
boot. It touches no debugfs write path beyond the read-only KCI 11 query and is
not enabled by default, so it cannot change the phone's behaviour while setup is
missing. R9 K1 stays a patch plan: the driver tree search for the power-up path
did not land in this pass, so it is not claimed.

**Rev 31 state of play.** Everything that can be built without firmware setup
is now either shipped or written down: the reporter package, the stock runbook
with its decision line, the R9 proofs, and the K1 patch plan. The plan's whole
forward motion is therefore one of two things - the owner's G0 decision, or a
producer we have not found. The recheck below names what is honestly left:

| Left | Why it is not closed | Cost |
| --- | --- | --- |
| G0 firmware setup | no producer outside stock (U367, U380) | owner decision |
| K1-K4 | proofs written, driver patch not made | one build + one boot each |
| A2 code-15 static decode | **blocked**: the log site id needs a vendor debug artifact (U383) | not scheduled |
| door cap (code 16 > 4096) | PAGE_SIZE buffer in edgetpu-fs.c | kernel change + push |

Nothing else in the plan is unaccounted for. A result from any row above changes
the plan; until one arrives, no further payload guessing is planned (eight
tried, one CHECK - U380).

**K1 is closer than the plan said (rev 32).** `edgetpu-pm.c` already carries
`int power_up_count` in the power-management struct and increments it on every
power-up (`etpm->p->power_up_count++`), so the count K1 wanted exists. What is
missing is policy: a second power-up in a boot is allowed and silent. The change
is therefore small and local - refuse with `-EBUSY` and one `etdev_err` at the
second increment - and its proof is the one already written in rev 29.

**Rev 33: K1's first half is in the worktree, and the reporter has a boot record.**
`edgetpu-pm.c` now logs `K1: power-up N in this boot` at the second power-up,
without changing behaviour (the count and the put balance are untouched), so the
proof run can distinguish "two power-ups happened" from "one" before any policy
policy is enforced. The reporter unit, enabled on the phone, journals its JSON at
boot; the record is the evidence G1 will compare against.

**Rev 34: what this pass actually achieved.** K1's edit exists in the driver
worktree and is now visible to `git diff` (intent-to-add), but no kernel build
has run, so it stays unproven; the two-start proof is unchanged. The code-15
static decode was attempted again with the string-pool approach rather than a
sweep, and it does not yield the assertion's condition, so A2 remains open with
its method named (`llvm-objdump` over the extracted code region) instead of
being claimed. The stock oracle cannot be scheduled by an agent: the decision
record is the owner's line to fill, and that is the only thing standing between
the plan and G0.

**A2's toolchain now works (rev 35).** The raw image disassembles with
`llvm-objcopy -I binary -O elf32-littlearm --rename-section
.data=.text,alloc,load,readonly,code,contents` and then `llvm-objdump -d
--triple=thumbv7 --start-address=0x1000 --stop-address=0xdc000`, giving 334,066
instructions with file offsets (link = offset + 0x10000000). That removes the
capstone early-stop that made the earlier sweeps noisy; the remaining work is the
search itself (the assertion's line 864 is passed to a log call, so the site has
to be found by its caller chain, not by a raw immediate grep).

**A2's caller-chain pass (rev 36).** With the working listing, the assertion's
line is not a plain immediate: no `movw rX, #0x360` exists in the code region,
and `vii_scheduler.cc` itself lives only in the string island (`0x100effa4`),
referenced from data rather than from code. So the log macro passes a site id
(or a packed file/line), and the next method is to resolve the site id to that
string through the metadata table, then find the code that passes the id - not to
grep for 864. That is a bounded, offline job; A2 stays open until it is done.

**Rev 37: the logger's file table.** The `vii_scheduler.cc` path sits at file `0xeff78`, and searching for its address under every plausible base encoding gives no hits at all. So the firmware does not store a pointer to the path under either absolute or island-relative encoding; the logger's id table uses a different scheme (index, hash or a per-site struct), which is the next offline job. A2 remains open with its tooling solved.

**Rev 38: the offset encodings do not resolve the logger's id.** Absolute and
island-relative 32-bit pointers to the `vii_scheduler.cc` path (`0xeff78`) do not
exist anywhere in the image. A 16-bit search for the island-relative value
(`0xff78`) returns four scattered code addresses (`0x1b45a`, `0x258ba`, `0x48d0e`,
`0x6536e`) that do not form a contiguous table, so none of them is a site table.
With those three encodings exhausted, the id behind `vii_scheduler.cc:864` is
resolved by a scheme this image does not ship in readable form (a hash or a
build-time index), and A2 is blocked on that mapping rather than on tooling.
Recorded so no future pass repeats these three searches.

### 11.4d Rev 39: K1 is done, and it changed the product

K1 shipped as a real driver change and was proven on the phone: the first
power-up in a boot succeeds, and the second is refused at once with `-EBUSY` and
a named line instead of stalling a client for the timeout. The measurement
behind it is the more valuable result: **the TPU gets exactly one power-up per
boot.** After power-down the GSA/AON island reads `0xdeadfeed` and `power_up`
cannot succeed (U381).

That has three consequences the plan now carries:

- **§12 item 5 is revised**: repeatability is proven across two boots, not two
  runs in one boot. Any acceptance run that requires two invocations must hold
  the wakelock for the whole run, which is what the product service must do.
- **A module reload is not a recovery.** `rmmod`/`insmod` leaves the TPU
  unpowerable until reboot (U382); module tests replace the file and reboot.
- **K2's shape changes**: a client that drops the last wakelock takes the TPU
  with it for the boot, so the product's self-test must warn before releasing
  and must own the wakelock for its lifetime.

**Rev 40: A2 is closed as blocked.** The disassembly works, but the firmware's
log site ids are not encoded as an offset table over its own paths: three known
paths and every 32-bit value in the image produce zero candidate bases, and the
vendor chroot ships no symbols. Nothing in the plan waits on A2 any more; it
would need a debug artifact from the vendor, not another pass.

### 11.5 After setup (unchanged, ordered)

G1 register the verified 12,288-byte DGC0 -> E1 create execution -> E2 bind
from `/dev/dma_heap/system` -> E3 Invoke with a non-empty tensor -> E4 CPU
parity with `tools/tpu-acceptance` -> E5 twice in one boot and a cold boot ->
A1-A3 acceptance (ten runs, no second power-up, no leak, no IOMMU fault) ->
P1-P5 product.

### 11.6 Product architecture (the reason this is worth doing)

The product path must not depend on Google's userspace: `omamobile-tpu` speaks
the kernel's own `/dev/janeiro` ioctls (groups, submit, dmabuf), the debugfs KCI
door stays a bring-up instrument and is removed before release, and the kernel
work (K1 one power-up per boot enforced and loud, K2 an IOMMU fault kills the
client and not the phone, K3 teardown that leaves the heartbeat alive, K4 power
and thermal) is part of the package, not an afterthought.

## 12. What "a fully working TPU" means

Unchanged from rev 19, and each item still needs its artifact:

1. **Firmware set up.** The gate stops answering `Setup is not done yet` on a
   cold boot, in the firmware's own log.
2. **A graph registered.** The verified DGC0 (12,288 B) registers with status 0.
3. **One inference.** Invoke writes a non-empty tensor; the bytes are hashed.
4. **Parity.** `tools/tpu-acceptance compare` matches the CPU reference exactly.
5. **One power-up per boot, repeated across a cold boot.** The TPU cannot be
   powered twice in one boot (U381: after power-down the GSA/AON island stays
   unclocked), so the repeatability proof is two boots, not two runs in one.
6. **Ten runs.** No second power-up, no leaked handle, no IOMMU fault, KCI 21
   alive throughout.
7. **The product.** `omamobile-tpu run MODEL INPUT` emits the JSON report; the
   service self-test covers gate K and the mini model; DEVICES.md is honest.
8. **The honest line.** The benchmark row is filled only when 4-6 hold, with
   `uname -r`, the date and the firmware version.

## 13. Falsifiers and stop conditions

- **Size 64 is the handler's constant.** Falsified if A1 answers `3` on a clean
  boot; then the `-110` was the flood, and the dense sweep's other sizes stand.
- **The 64-byte payload is a structure the handler reads.** Falsified if A3's
  first crafted payload returns `3` (then the handler only validates the
  descriptor, and the command needs no fields).
- **The gate is firmware-side only.** Falsified if stock's capture shows the
  gate line on a boot where stock never ran the HAL (then setup is a kernel or
  bootloader act).
- **This firmware can be set up at all.** Falsified if every 64-byte payload
  either faults or returns 3, and stock's own capture shows the same firmware
  build with the same gate, i.e. the setup needs a signed artifact we lack.

