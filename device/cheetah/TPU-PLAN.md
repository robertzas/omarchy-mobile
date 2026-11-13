<!-- SPDX-License-Identifier: MIT -->
# TPU / NPU plan: the Edge TPU (Abrolhos / Janeiro) on cheetah (gs201)

Status (2026-11-13, rev 15): **the TPU is alive and addressable; the VII
transport, the firmware handshake and the client group all work; the in-process
HAL and three of our own conclusions are retired; no inference is claimed.**
Rev 15 exists because rev 14 recorded claims that the driver's own header and
binary then refuted. It keeps the corrections and states the ledger as three
lists - established, refuted, unknown - so the next session does not rebuild on
a wrong premise. The one unknown left is the vendor HAL's own VII element, and
the image that contains it is now identified (U325).

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

**Unknown, and the only thing worth a boot.** What the vendor HAL's VII element
actually contains. Its enqueue is in
`out/vendor-chroot-edgetpu/root/vendor/lib64/libdarwinn_hal.so` at `0x1529648`
and composes the element from a command object (U325).

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

## 11. Immediate actions (ordered, rev 15)

1. **R-KCI-4 (offline, next):** finish reading the HAL's enqueue in
   `out/vendor-chroot-edgetpu/root/vendor/lib64/libdarwinn_hal.so` at
   `0x1529648`-`0x1529960`. It reads a command object at `x2` (`+0`, `+8`,
   `+0x10`, `+0x18`) and writes the 48-byte element at `x19` (U325). Recover
   every field, then build our element from those fields.
2. **R-KCI-5 (offline):** diff that element against ours (U319). Only a
   difference earns a send; an identical element is the known negative.
3. **R-KCI-6 (phone, one attempt):** send the different element through the
   Tachyon session, which already creates and finalizes a device group
   (`0x4014ed06`, `0xed08`, U324). Oracle: the firmware's setup line, or
   `T10=11` answering anything but `0xf000009`.
4. **R-SERVICE (parked):** binderfs plus servicemanager and the vendor DBA
   service; needs an answer to U285's unclaimed queue first.
5. **R-STOCK (owner):** section 7, the only route proven to make the firmware's
   setup happen.

## Appendix A - the HAL's function table (U286)

| Word | Offset | Entry | Role |
| --- | --- | --- | --- |
| 0 | +0 | - | version, `2` |
| 1 | +8 | `0xf7738` | logging/init: logs `LibDarwinnDbaHal`, returns 0 |
| 2 | +16 | `0xf7764` | **create**: `(options*, hal**, cb, ctx)` |
| 3 | +24 | `0xf78dc` | small wrapper, calls `0xf920c` |
| 4 | +32 | `0xf7900` | wrapper, calls `0xf9794` |
| 5 | +40 | `0xf7a4c` | wrapper, calls `0xfa4e4` |
| 6 | +48 | `0xf7b98` | wrapper, calls `0xfb22c` |
| 7 | +56 | `0xf7c70` | larger, calls `0xfcb04` then a virtual |
| 8 | +64 | `0xf7f5c` | wrapper, calls `0xfd054` |
| 9 | +72 | `0xf8094` | wrapper, calls `0xfd11c` |
| 10 | +80 | `0xf816c` | larger, virtual dispatch |
| 11 | +88 | `0xf8448` | wrapper, calls `0xfbd6c` |
| 12 | +96 | `0xf8520` | wrapper, calls `0xfd88c` |
| 13 | +104 | `0xf8664` | wrapper, calls `0xfd924` |
| 14 | +112 | `0xf87a4` | getter: `0xfd9bc`, logs line 233 |

The service additionally reads `+0x50`, `+0x58`, `+0x60` (its session path).

## Appendix B - the service's call sequence (reference client)

| Address | Action |
| --- | --- |
| `0x84a0` | `GetDarwinnHalFunctions` |
| `0x84c8` | version word `> 0` check |
| `0x84e8` | entry `+8` (init) |
| `0x850c`-`0x8524` | build the 16-byte options |
| `0x859c` | entry `+16` create (status in `w0`) |
| `0x85bc` | `ABinderProcess_setThreadPoolMaxThreadCount(4)` |
| `0x85f4` | `AServiceManager_registerLazyService` |
| `0x861c` | `ABinderProcess_joinThreadPool` |

## Appendix C - signed firmware container (U260)

`out/tpu/edgetpu-janeiro.fw`, 1,038,272 B, sha256
`52c1cccdf0e243d12fbc9f3b3911fe9c780a11d9a5bfda61744c7c3fdaded7c3`.
Magic `TPUF` at `0x400`; image config at `0x560`; remapped region `0x93200000`
(`0xe00000`); body high-entropy to `0xdc000`; island `0xe0000..0xfd7c0`.

## Appendix D - the captured HAL setup command (U262)

128 bytes, `out/tpu/setup-hal-128.bin`: root table 20, vtable 10, table size 18,
field 1 union type 5, one `{0xffe80000, 0x80000}` allocation.
`tools/tpu-setup.py build` reproduces it exactly.

## Appendix E - where the evidence lives

- [TPU-HISTORY.md](TPU-HISTORY.md): the U-log (U285-U287 are this revision's).
- [TPU-STATUS.md](TPU-STATUS.md): the one-page status.
- `logs/tpu/`, `out/tpu/`, `out/tpu-client/`: gitignored sandboxes.
- Tools: `tools/tpu-dba-hal-probe.c`, `tools/tpu-hal-harness.c`,
  `tools/android-dba-serve.c`, `tools/tpu-binder-client.c`,
  `tools/tpu-tachyon-run`, `tools/tpu-fw.py`, `tools/tpu-setup.py`,
  `tools/tpu-graph.py`, `tools/tpu-acceptance`, `tools/tpu-stock-capture`.
