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

## 2026-11-13 (U334: U333 withdrawn - 0x14d9df8 is only a vector reserve helper)

It computes a count over 24-byte entries and calls a reserve/insert pair; it
stores no command values. The three words come from wherever the vector is filled
earlier (`0x14d9c74` / `0x14d9eac`), which remains the open read.

## 2026-11-13 (U331-U332: type 5 confirmed on the builder side; no tracing at all)

`0x14d9e60` stamps union type 5 and wraps a 24-byte payload, so the U262 command
and the element's `+0x0a` finally agree, and the remaining values are that
payload's three words. `/sys/kernel/debug/tracing/` is absent and the config has
no tracer options, so neither dynamic debug nor ftrace can observe the group
handshake: the firmware's reply is the only oracle.

## 2026-11-13 (U330: dynamic debug is off, so the group line cannot be seen)

`/sys/kernel/debug/dynamic_debug/control` does not exist on this kernel, so the
debug-only `join group` line cannot be turned on and the handshake cannot be
confirmed from dmesg. `kci_send` is write-only (a read gets EACCES).

## 2026-11-13 (U329: the real KCI door is debugfs; the group line is debug-gated)

`/sys/kernel/debug/edgetpu/janeiro/{kci_payload,kci_scratch,kci_send}` is the only
userspace KCI path (ioctl 34 was not one). The driver's join-group line is
`etdev_dbg`, so dmesg silence about groups means dynamic debug is off rather than
no group - turn it on with `file edgetpu-device-group.c +p` before a client run.

## 2026-11-13 (U328: the element field map is complete; only the values are unknown)

`0x152989c` copies exactly eleven fields from the command object into the 48-byte
slot (`+0x00`, `+0x08`, `+0x0a`, `+0x0b`, `+0x10`, `+0x18`, `+0x1c`, `+0x28`,
`+0x2c`, `+0x2d`, `+0x2e`) and never writes `+0x20..+0x27` or `+0x2f`. The wire
format is settled; what remains is the value set from `SetupFirmware`'s builder.

## 2026-11-13 (U326-U327: the enqueue is 0x152977c and the fill is 0x152989c)

The enqueue computes `base + (tail & 0x3ff) * 0x30`, fills the slot at
`0x152989c`, issues `dmb ish` and publishes the tail - exactly U264's shape. The
address U325 named (`0x1529648`) is a validation function that writes a 9-byte
result, so it is corrected. The fill helper is the last offline artifact needed
to build a *different* element instead of re-sending the known negative.

## 2026-11-13 (rev 15: the corrected ledger, and where the HAL's element lives)

Established: the firmware answers 1.0/VII 2/KCI 3, gate K passes, and the client
creates and finalizes its group. Refuted: the options layout, our fork, the
ALooper angle, the ptrace sampler, "userspace can send KCI", the property block,
"no group context", and "the rebuilt element is the HAL's". Unknown: the vendor
HAL's own element, whose enqueue is in the 37 MB
`out/vendor-chroot-edgetpu/root/vendor/lib64/libdarwinn_hal.so` at `0x1529648`
and composes the element from a command object (U325).

## 2026-11-13 (U324: U321 retracted - the group context is already there)

`EDGETPU_CREATE_GROUP` (ioctl 6, `edgetpu_mailbox_attr`), `EDGETPU_JOIN_GROUP`
(ioctl 7) and `_IO(0xED, 8)` exist, and our client already creates and finalizes
a group (`0x4014ed06`, `0xed08`) before submitting. So the group context was never
missing, and U319's bytes are authentic only to *our* producer: the vendor HAL's
element has never been captured. The next offline stride is that capture.

## 2026-11-13 (U319-U320: the element rebuild is a known negative; the context is the gap)

The authentic 48-byte VII element and its 80-byte payload rebuild byte-exactly
from the driver's own dump (`86ce5ad9…`, `028a71ca…`), and they are the ones
already replayed on 2026-11-09 that gated: the element is not the missing piece,
so re-sending it would only spend a power-up. The U262 128-byte artifact is a
different object. Entries 3-14 of the HAL table read `x0` as the HAL object and
copy a 16-byte parameter from `x1`, with `x2`/`x3` as the callback pair on five
of them; the next target is the firmware's client context (`OPEN_DEVICE`'s
`{client_priv, vcid, flags}`).

## 2026-11-13 (U323: the property ioctl has no consumer, so it is not the setup path)

`EDGETPU_DEV_PROP_SIZE` appears only in `edgetpu.h`; no `.c` file stores, copies or
forwards the block, and nothing handles `SET_DEVICE_PROPERTIES`. The ioctl is
declared and unimplemented here.

## 2026-11-13 (U317 real, U318 retracted: KCI is kernel-internal)

`tools/tpu-info --json` returns **firmware 1.0, VII 2, KCI 3** (DRAM 0/0), so the
AP-firmware handshake is complete. U318's "userspace can send KCI" is retracted
by U322: ioctl 34 is `EDGETPU_SET_DEVICE_PROPERTIES`, the header has no KCI
ioctl, and `tools/tpu-kci` is withdrawn. Userspace meets the firmware through
the VII mailbox path (gate K) only.

## 2026-11-13 (rev 14: the plan moves to the kernel's own KCI interface)

The plan is rev 14. R-KCI replaces the in-process HAL as the primary route: the
kernel owns KCI (codes 0-14, 19, 21), the Tachyon session already passes gate K,
and the only missing piece is the exact 48-byte VII element the HAL's enqueue
writes. Track S is retired as a route, with every finding kept.

## 2026-11-13 (U316: the TPU is alive; the HAL is a client, so the route changes)

The driver `edgetpu_platform` is bound to `1ce00000.janeiro`, `/dev/janeiro` is a
real node, and the KCI heartbeat (code 21) climbs every ~61 s with irq 152
asserting: firmware is loaded and the device talks. The HAL opens no node at all,
so it waits for a service peer, not for hardware. The in-process route is retired;
the plan now goes to a direct KCI client against `/dev/janeiro`.

## 2026-11-13 (U310-U314: the block is not a libc wait and not an I/O syscall)

The interposer is proven (`BLK sem_wait ra=0x...`), so the factory's silence on
cond_wait/sem_wait/mutex_lock/join and on read/epoll/poll/ioctl/socket/connect is
evidence: the wait is a raw futex or an in-kernel wait. `dlopen` after `fork()`
blocks and needs `NOFORK=1`; the chroot's `libandroid.so` has no
`ALooper_prepare`, so H1 stays untested. `0x12a710` registers into containers
rather than waiting (U309).

## 2026-11-13 (U308: create's body has no wait, so a helper does)

`0xf8df8`-`0xf9208` holds `strlen`, `memcpy`, a `pthread_create@plt` and virtual
calls plus helpers, but no `open`, `epoll` or `GetProperty`: the block lives in a
helper, and the two windows to read next are `0x12a710` and `0xfd3d8`.

## 2026-11-13 (U306-U307: H6 and H2 refuted; the options object is legal)

`MODE=nofork` blocks exactly like the forked run, so the wait is not a lock
inherited across `fork()`. Offline, create's implementation (`0xf8df8`) reads
`ldp w8,w9,[x0]` then a `const char *` at `+8` and copies it with
`strlen`/`memcpy`, so the 16-byte object is `{u32 bool, u32 enum 0..2, path}`
and `{1,1,"/dev/edgetpu"}` is legal. The block is after the path is copied; the
remaining window is the next offline read.

## 2026-11-13 (U304-U305: the blockers are never called; our own fork is the suspect)

The harness now interposes `pthread_cond_wait`, `pthread_cond_timedwait`,
`sem_wait`, `pthread_mutex_lock` and `pthread_join`, all exported
(`llvm-objdump -T`), and a factory run produces no `BLK` line: the wait is not
reached through those symbols. The semaphore control is inconclusive
(`watch_pid` is set after it runs), and that is recorded rather than counted.
Leading hypothesis H6: every run forks first, and the child inherits a lock
held at fork time by a thread it does not have. Next: run the factory with no
fork.

## 2026-11-13 (U302-U303: ptrace is withdrawn; the plan is rev 13)

`PC` was `regs[30]` (the link register), now `regs[32]`; it lands in libc's
futex path. The blocked thread's `x29` is `0xffffffff`, so no frame chain
exists, and the register block itself is unreliable (`sp` read `0x3d3d...`,
`process_vm_readv` returned -1 although attach and getregset succeeded). The
next instrument is an interposer on the blocking primitives that prints
`__builtin_return_address(0)` minus `hal_base`: in-process, no ptrace, no
unwinder. TPU-PLAN.md is rev 13: five hypotheses with tests and costs, and the
strides renumbered to what is actually done.

## 2026-11-13 (U301: the ptrace sampler reaches the futex but not the frames)

`MODE=bt` attaches to the blocked child and reads its registers: the PC is in
libc's futex path, as the kernel wchan said. The frame walk is not usable yet
(`PTRACE_PEEKDATA` returns -1), so the waiting HAL function is still unnamed.

## 2026-11-13 (U298-U300: the wait is inside the factory, and the callback is irrelevant)

All three callback/context combinations (both, callback only, context only)
block identically, so the handshake is inside create. The alarm handler is now
a plain `_exit(3)`; its `backtrace()` was what made a run take 300 s (U296,
U299). The call target is confirmed: `x19` is the table at the caller's site and
`[x29-0x28]` carries it into `ldr x8,[x8,#0x10]` (U300). Next instrument: a
ptrace sampler for the blocked thread's user stack.

## 2026-11-13 (U293-U297: the factory allocates, then waits without opening the device)

Handing the factory the builder's exact output (`{1, 1, "/dev/edgetpu"}`)
replaces the crash with a wait: the HAL allocates, starts an
eventpoll/eventfd/timerfd trio and three threads, and blocks in `futex_wait`
with **no `/dev/edgetpu` fd open** and no KCI traffic from it. The wait is a
userspace callback contract (arg 3 is a code thunk, arg 4 a shared_ptr control
block), not firmware. `backtrace()` in an alarm handler deadlocks this process;
use the fd and thread listing instead.

## 2026-11-13 (U288-U290: the HAL runs in-process; the factory needs a callback)

`tools/tpu-hal-harness.c` loads the DBA HAL inside the chroot, reads
`version=2`, and calls the table's init (word 1) to `rc=0`. The factory (word
2, entry `+16`) faults at address 0 with a zeroed options object: the service
passes a callback thunk (`0x8d10`) and a 0x80-byte context as arguments 3 and
4, so both must be supplied. Init is one-shot (`init_google.cc:641`), and the
harness reads its mode from `$R/tmp/tpu-mode` because a preloaded constructor
cannot see the environment.

## 2026-11-13 (U285-U286: binder stalls below the HAL; the HAL's 14-entry table is reachable)

A preloaded serving thread (`tools/android-dba-serve.c`) does join the DBA
service's binder pool - the process then shows two threads in
`binder_ioctl_write_read` - and the queued call is still not claimed: even
`INTERFACE_TRANSACTION`, which never enters `onTransact`, gets no reply, with
`tr 1` pending on the node. That route is stalled below the HAL. In exchange,
the HAL is now reachable with no binder at all: `GetDarwinnHalFunctions`
returns a table whose first word is API version 2 and whose 14 pointers
(`+8`..`+112`, `0xf7738`..`0xf87a4`) are the HAL's own entry points
(`tools/tpu-dba-hal-probe.c`). Naming them and calling the create entry with
`/dev/edgetpu` is the next step.

## 2026-11-13 (U280-U284: the DBA service registers; a queued call has no thread)

The vendor DBA service was aborting at registration, not at its HAL: Android
14's servicemanager refuses `registerLazyService` for an instance the VINTF
manifest does not declare. With a `com.google.edgetpu.dba` / `IDevice/default`
fragment (now written by `tools/tpu-tachyon-run`) it registers and
`com.google.edgetpu.dba.IDevice/default` resolves to a real handle. Its
interface is `createSession` -> `IDeviceSession.createCompilationFromFile` ->
`ICompilation` (no NNAPI `prepareModel`). The client's `createSession` is
delivered but never served: the kernel shows `tr 1` pending on the service's
node while its threads sit in epoll, and the service's own
`Thread Pool max thread count is 0` line explains it. That thread pool is the
next thing to fix; the in-process `GetDarwinnHalFunctions` harness is the
alternative.

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
