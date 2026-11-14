<!-- SPDX-License-Identifier: MIT -->
# Edge TPU bring-up: status and benchmark

As of 2026-11-14 (rev 22), kernel
`7.3.0-rc6-omamobile-push1-ga78d26f63e56-dirty`, slot B. The plan of record is
[TPU-PLAN.md](TPU-PLAN.md); the full experiment log and every prior revision
are in [TPU-HISTORY.md](TPU-HISTORY.md). **No model has run on the TPU and no
inference is claimed.** Gate K was re-proven on this boot
(`logs/tpu/20261113-gatek-rev10.txt`). Since rev 18, K3 is proven in its pre-G0
form, K2 is blocked by the firmware's own descriptor check, and the self-test
ships in `omamobile-tpu` 0.1.11: it reports `transport` and `setup_proven`, and
it exits 3 until a real inference writes `/var/lib/omamobile/tpu-setup-proven`.

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

## 2026-11-14 (U392: K2 cannot be injected through the door; the firmware checks first)

The door's `kci_addr` names a fixed descriptor address, and four addresses
(`0x3e8`, `0x1000`, `0x10000000`, `0x1ffff000`) were sent with code 21 and a
4092-byte buffer. Every one answered `3` with the firmware's own line
`ERR tpu_kci_handler_thread.cc:101 - DMA descriptor is invalid`; the phone stayed
up, the door kept working after the reset, and no fault or oops appeared. So the
firmware validates the descriptor against its known buffers **before** it DMAs,
and the debugfs door cannot reach the SMMU by naming a bad address. K2 stays
unproven and is now marked blocked on G0's compute path, where a client's own
mapping can be unmapped under a live command. `kci_addr` stays as an instrument,
documented as unable to fault, and it takes decimal (`0x...` is accepted).

## 2026-11-14 (U391: K3 in the form available before G0)

A second `tpu-hold` client was started while the service's holder kept the
wakelock: a door submit (KCI 11) answered `0` during it, `SIGKILL` of the client
(no orderly release) left the holder count at 1, the phone up, KCI 11 still `0`,
`K1` refusals at 0, and no oops or fault. That proves a client's teardown after a
submit leaves the transport alive, with the honest scope that the submit was the
door's kernel-side one, not a userspace command group.

## 2026-11-14 (U390: the self-test, and two wrong verdicts it caught)

`omamobile-tpu selftest` ships in 0.1.9. It proves the transport (KCI 11 answers
0 with the build id), reports 12 and 21, and exits **3** with "setup is not
proven" until `/var/lib/omamobile/tpu-setup-proven` exists, which only a real
inference writes. Two earlier versions were wrong and are recorded so they are
not repeated: 0.1.7 required KCI 21 to answer 0 (it answers 3 without the buffer
it needs), and 0.1.8 treated the *absence* of the firmware's wall line as proof
that setup was done, which it is not - the line appears only when a VII command
is attempted, and the self-test sends none.

## 2026-11-14 (U389: KCI 21 needs 4092 bytes, and says so)

GET_USAGE_V2 through the door with its 16-byte default answers `3`; the firmware
logs `usage_tracker_impl.cc:190 - Provided metric data buffer is too small for
flushing: got 16, want 4092`. With a 4092-byte payload it answers `0` and returns
`0c 00 03 00 0c 00 00 00 18 00 00 00 02 00 00 00`. So every usage query needs a
full page of descriptor, and a bare `3` from 12/21 is a size complaint, not a
refusal of the command.

## 2026-11-14 (U398: the stable rebuild is P0a, and it is a real merge)

The owner's rule is now in §14.0, and measuring it found work the plan had
understated: `wt-tpu` is not based on `kernel-2026.11.13` (the tag is not an
ancestor; the trees differ in 114 files) and carries 90 modified or added files
(the edgetpu import plus binder, gxp, iommu, gs, charger and the gs201 dtsi).
A stable-based kernel and rootfs are therefore P0a, before any G0 wipe: a new
worktree at the tag, the series applied and resolved, `out-tpu-stable` built,
and a boot verified. Until then `out-tpu` and the `-tpu3` rootfs stay
development builds and are not flashed under the rule.

## 2026-11-14 (U397: rev 49's comprehensive program, the stable-build rule, and the suite)

TPU-PLAN rev 49 adds §14, the forward program with its phases, commands, exits
and rollbacks, and §14.0 makes the owner's rule explicit: every build and flash
starts from the latest stable release (2026-11-14: kernel-2026.11.13,
omamobile-device-cheetah 0.1.54, Omarchy 4.5), with the TPU bring-up series on
top in its own worktree. The re-evaluation keeps the wall where it is (the VII
setup has no Linux producer), records G0 attempt 1 and the verified reinstall,
and orders the remaining work P0-P5.

The full suite found two merge regressions, both fixed: `tools/phone-usb` piped
into `grep -q` under pipefail, and the lynx/raven bootctl copies had lost the
`OMAMOBILE_DEVINFO_EXTRA_MINOR` hook that cheetah's copy carries. `tests/all`
now reaches `tests/owl`, which cannot run on this host because its `node` is
Bun 1.4.4 (the suite is written for Node's preload); that is environmental, not
a code failure, and the test is not weakened.

## 2026-11-14 (U396: G0 attempt 1 — stock wants a factory reset, not a capture)

S1 ran: the flags read `b`/`yes`, `--set-active=a` and a reboot, and stock did
not reach Android. With our Arch root on `userdata` it boots stock recovery and
offers "Try again" / "Factory data reset" — the risk TPU-STOCK-ORACLE records,
now measured. No capture ran. The phone returned with `--set-active=b` and
booted Arch on slot B (the TPU self-test still `transport ok`, `setup
unproven`).

The next attempt therefore includes the wipe: choose "Factory data reset" on
that screen, let stock boot and enable USB debugging, capture, then reinstall
Arch from `out/cheetah/omamobile-rootfs-cheetah-2026.11.13-tpu3-aarch64.img.zst`
with `~/omamobile-kernel/out-tpu/images` before slot B boots again. A read-only
`tools/install-phone --verify-only` on both passed: checksum matches, kernel
`7.3.0-rc6-omamobile-push1-ga78d26f63e56-dirty` with its modules in the image.
`tools/tpu-g0` now stops on adb `recovery` with that instruction instead of
waiting for a `device` stock cannot offer.

## 2026-11-14 (U395: the G0 recovery artifact, checked)

The stock runbook's third prerequisite is the Arch root's recovery artifact.
Checked read-only: `out/cheetah/omamobile-rootfs-cheetah-2026.11.13-tpu3-aarch64.img.zst`
exists at 3,017,687,274 bytes and its sha256 starts `4b0542e1`; it was built from
the current pins with the current `out-tpu` modules. No signed bundle is built
(`out/repo` holds no packages), so a *release* reinstall would need
`tools/release` first; the image is what this run's recovery would use.
Recorded because the runbook says stop when there is nothing to recover with.

## 2026-11-14 (U394: the guided capture, and the self-test at boot)

`tools/tpu-g0` wraps S1-S3 with the runbook's guards: no fastboot device means no
write (this ABL has no buttonless path), the slot flags are recorded and must
read `b`/`yes` before `--set-active=a`, stock's adb gets ten minutes with the USB
debugging instruction if it never appears, and the return goes through
`fastboot --set-active=b`, Arch, a fresh `tools/nv-backup` and `--check`. Its
`status`, `plan` and refusal paths were tested here; the write path waits for the
buttons. `omamobile-tpu-selftest.service` (0.1.12) runs the JSON self-test at
boot with `SuccessExitStatus=3` and `RemainAfterExit=yes`, so the journal carries
`{"transport":"ok",...,"setup":"unproven","rc":3}` every boot.

## 2026-11-14 (U388: A4 is answered, and the answer is nothing)

The whole firmware-info reply is 52 bytes, not the 16 the reporter printed:
`f149d469 00000000` (build time), `03000000` (flavor), `56486135` (changelist,
ASCII `VHa5`), then **ten spare words, all zero**. So `fw_info.spare[]` is not a
state word on this build and A4 is closed as a negative: what setup waits for
cannot be read from the firmware's own info. The plan's rev 44 records the three
results that leave exactly one open route (G0 via the stock oracle) and one owner
action (the buttons into fastboot).

## 2026-11-14 (U387: the boot gate, and K1 as a reviewable patch)

`omamobile-tpu` 0.1.6 adds `--gate`: exit 3 with a named line when the boot's
power-up is spent or the firmware will not answer, exit 0 with the build id when
it can do TPU work. `omamobile-tpu-gate.service` runs it, so `systemctl --failed`
names a boot that cannot do TPU work instead of a product run discovering it
halfway. The package test proves both verdicts against a fake door, with no
phone; it caught a real bug first (the `gate` flag was overwritten by the log
count, so the gate always passed).

The K1 change now has a reviewable artifact, `device/cheetah/tpu-k1.patch`
(K1, the widened door and `kci_last`), which reverse-applies cleanly to the
worktree with `patch -R --dry-run -p1`. It is a patch rather than a kernel
commit because the kernel tree tracks only three files under `drivers/edgetpu/`,
and its door is itself uncommitted; committing either would misattribute a
whole bring-up import to K1. The installed module records its provenance in
`/var/lib/omamobile/tpu-module.sha256` (sha256 `11430d20…`).

## 2026-11-14 (U386: the KCI door reaches 16 KiB, and code 16 refuses at every size)

The door's one-page cap is gone: `kci_payload` holds 16 pages and the iremap
allocation rounds up to the payload (`PAGE_SIZE * DIV_ROUND_UP(len, PAGE_SIZE)`),
so a descriptor may name up to 16 KiB. A new `kci_last` (0444) returns the last
send's code, so a sweep reads 4 bytes instead of tailing dmesg.

Built `W=1` (no new warnings), module sha256 `11430d20…`, 4,013,512 B; booted and
the gate read `fw_info f149d469…`, `spent:false`, power-up at 4.87 s. Then code 16
with a zero payload at **4097..8192 dense, plus 12288 and 16384**: every answer
`3`, no assertion, no crash, `spent:false` after. So code 16's refusal is not a
buffer-size check, and the 64-byte `vii_scheduler.cc:864` assertion of code 15 is
a later validator, not a size gate. The size hypothesis for KCI 15/16 is closed.

## 2026-11-14 (U381: K1 landed and proven - the TPU cannot power up twice in a boot)

K1 is in the driver (`edgetpu-pm.c`, reached through `janeiro-pm.c` ->
`mobile-pm.c` -> `edgetpu-pm.c`), built with `W=1` (no new warnings), installed
and proven on the phone after a reboot with the modem stopped first:

    boot: kci_send code 11 ... -> 0     K1 lines: 0
    stop tpu-hold, wait 4 s, start it again:
    edgetpu janeiro: K1: power-up 2 refused; the TPU cannot come back in this boot
    edgetpu janeiro: edgetpu_ioctl_acquire_wakelock: pm_get failed (-16)

Without the patch the same second attempt logged
`power-up failed: PSM0_STATUS=0x5644c13 ... AON_RESET=0xdeadfeed
POWER_CONTROL=0xdeadfeed GSA state=2` and `pm_get failed (-110)` after the
timeout. So the hardware fact behind K1 is confirmed: **one power-up per boot**;
after a power-down the GSA/AON island stays unclocked and the next power-up
cannot succeed. K1 now refuses it at once (-EBUSY) and says so, instead of
stalling the client for the full timeout. `power_up_total` counts real power-ups
and, unlike the refcount, is never reset.

## 2026-11-14 (U385: no buttonless fastboot on this ABL; the buttons are the way)

`bin/omamobile fastboot` cannot get cheetah into fastboot. Its first path,
`reboot-to bootloader`, was ignored by ABL (four attempts, phone still in Arch);
its fallback, `echo c > /proc/sysrq-trigger`, panicked and the phone rebooted
**into slot B again**, not slot A. `fastboot devices` and `adb devices` stayed
empty throughout. So S1 of the stock-oracle runbook needs the buttons: Volume
Down, then Power, held about 20 s. The panic path is recorded as a negative so no
later pass spends a boot on it.

## 2026-11-14 (U384: a spent boot can come up dark; check `power-up ok`)

After K1 refused a second power-up and the last holder was killed, the next boot
logged no `power-up` line at all and KCI 11 timed out three times (`-110`,
`status 1`, empty queues) with `fw_info` all zeros; the following clean reboot
logged `power-up ok` at 4.8 s, `fw_info f149d469...` and `spent:false`. So a
spent boot is recovered by a reboot, but not every reboot: one can come up with
the TPU dark. Every run must read `power-up ok` (or `spent:false` from
`omamobile-tpu`) before trusting anything, and a dark boot is a reboot, not a
diagnosis. The last holder is not a `tpu-hold.service` (`is-enabled` says
not-found): `[UNIT]`. Stopping it spends the boot (U381), so the product service
must own the wakelock for its lifetime.

## 2026-11-14 (U383: A2 is blocked on a vendor debug artifact, not on tooling)

The firmware's log site ids are not resolvable from the image. Three source
paths pin any single-base offset table - `vii_scheduler.cc` at `0xeff78`,
`log_embedded.cc` at `0xf4d3c`, `tpu_kci_handler_thread.cc` at `0xe7220` - and
searching **every 32-bit value** in the image for a base that satisfies all
three gives **zero candidates**. There is also no `0x360` immediate anywhere, and
the vendor chroot ships stripped HALs with no `.sym`, `.dbg`, `.dwp` or `.map`.
So the line-864 condition needs a vendor debug artifact this device does not
carry. A2 is closed as **blocked**, not open, and the plan no longer lists it as
work that will land.

## 2026-11-14 (U382: never rmmod/insmod janeiro)

Reloading the module to test an edit left the TPU unpowerable for the rest of
that boot: after `rmmod janeiro; insmod janeiro`, every `pm_get` failed with the
same `AON_RESET=0xdeadfeed ... GSA state=2` and `-110`, and only a reboot
recovered it. The module's probe must see the island in its boot state; a reload
does not. Test module changes by replacing the file and rebooting, never by
reloading.

## 2026-11-14 (U380: the assertion is not a payload validator)

Eight payloads now, four structural classes: all zeros, sixteen self-pointers,
class byte 0x01/0x02/0x0b, a single self-pointer at +0x00/+0x04/+0x08, and a
kernel-shaped `edgetpu_command_element` (seq 1, code 0, dma{self, 64, 0}) with 40
zero bytes. Every non-zero payload produces the *identical* `vii_scheduler.cc:864
ASSERTION FAILED` and the same five leading frames; all zeros crashes. Nothing
we can vary inside the 64 bytes changes the verdict, and A14 does not have the
command at all (U379). The parsimonious reading is that A17 added a stub whose
CHECK fires unconditionally for host-originated calls, not a validator that
inspects the buffer. So the KCI gap route is exhausted as a setup producer: it
remains a plausible transport once an element producer exists, but it cannot
teach us the element.

## 2026-11-14 (U379: code 15 exists only on A17)

With the *real* A14 image loaded (U378), `fw_info` reads build `0x6487a25e`,
flavor 3, changelist `0x202c53cf`, code 6 answers **12** (the A14 signature the
plan recorded in U276), and **code 15 at 64 bytes answers 12 - UNIMPLEMENTED**,
with no assertion and no crash. The same call on A17 answers `-110` and trips
`vii_scheduler.cc:864`. So 15/16 were added in the A17 firmware, and A17's
handler rejects every payload we can build as a non-element. That makes code 15
the most likely channel the A17 vendor HAL's setup uses - and confirms the
payload must be a real VII element, not a byte pattern.

## 2026-11-14 (U378: `updates/` shadows the base firmware path)

Replacing `/usr/lib/firmware/edgetpu-janeiro.fw` with the A14 image changed
nothing: the boot still reported A17's `fw_info` and code 6 -> 14. The kernel
loads `/usr/lib/firmware/updates/google/edgetpu-janeiro.fw`, which shadows it.
Replacing *that* file produced the real A14 (build `0x6487a25e`, code 6 -> 12).
Every future firmware swap must target the `updates/google/` copy, and any
earlier "A14" result taken through the base path is suspect.

## 2026-11-14 (U377: the door's cap is a kernel constant, not the firmware)

`edgetpu-fs.c:1077` declares the payload buffer as `static u8
edgetpu_kci_payload[PAGE_SIZE]` and `:1128` refuses `len > sizeof(...)` with
`-E2BIG`, which is exactly the 8 KiB failure. So code 16 above 4096 bytes is a
two-line kernel change plus a build and push, not a firmware question; it stays
queued behind higher-value work.

## 2026-11-14 (U376: the assertion is structural, and code 15 eats VII elements)

Three fresh boots, payload = 64 zero bytes with a **single** self-pointer at
`+0x00`, `+0x04` and `+0x08`: all three give the same `vii_scheduler.cc:864
ASSERTION FAILED` and the same frames, and code 11 answers 0 after each. Together
with U375 (class byte irrelevant) this rules out every field-level reading of the
payload: the check fires on *whether the buffer is a valid VII element at all*,
not on a particular value. All-zero bytes crash (`null` element); any non-element
bytes fail the validator. So code 15 is not a side door around the VII wall - it
is the wall's kernel face, and a legal payload is a legal VII element. The next
step is therefore to build the element with the driver's own VII command format
(`edgetpu-fs.c` submits map-buffer elements) instead of guessing bytes.

## 2026-11-14 (U375: the class byte is not the selector)

Three fresh boots, one code 15 send each, payload = sixteen self-pointers with
byte `+0x0a` set to `0x01`, `0x02` and `0x0b`: all three produce the *same*
`vii_scheduler.cc:864 - ASSERTION FAILED` and the same five leading frames
(`0x100D3B66 0x100D3C26 0x100B647E ...`), and code 11 answers 0 afterwards in
every case. So `+0x0a` does not select the failing branch; the check fires on
something invariant in the self-pointer shape itself - the element count, the
first word, or a field that must be null. The next differential varies the
*shape* (pointer at one offset, zeros elsewhere), not the class byte.

## 2026-11-14 (U374: code 15 is a VII-scheduler command, and its payload is a pointer)

The door logs the buffer's firmware address on every send (`kci_send code N
tpu_addr 0x1015c000 size 64 len 64`) and the address is stable per boot. With
that known, a 64-byte payload of sixteen copies of `0x1015c000` - a self-pointer
the firmware can legally read and write - no longer faults silently. It reaches
the firmware's **VII scheduler** and trips its own assertion:

    ERR vii_scheduler.cc:864 - ASSERTION FAILED
    ERR log_embedded.cc:78 - --- Backtrace for CHECK Failure ---
    0x100D3B66 0x100D3C26 0x100B647E 0x1001B922 0x1001C156 0x100D2020
    0x100D20C8 0x100D1446        (then kci_send code 15 ... -> -110)

So code 15 is not a mystery family: it feeds `vii_scheduler`, i.e. it is the
kernel-side entry to the same VII path whose userspace door is gated. The
payload is parsed as VII input, and the assertion - not a fault - is the next
oracle. The all-zero payload faulted because its first pointer was null; the
self-pointer faults the assertion instead, which is strictly more information.
Code 11 still answers 0 with len 64 afterwards.

## 2026-11-14 (U373: query codes are narrower than assumed)

Code 8 (debug dump, 4096-byte descriptor) answers `-> 12`, UNIMPLEMENTED. So
the firmware's dump path is not available as a state oracle either. `kci_dma`
and `kci_scratch` are write-only from debugfs (read gives EACCES), and `kci_result`
holds the last reply buffer.

## 2026-11-14 (U372: the driver publishes the payload's firmware address)

`edgetpu-fs.c`'s door logs `tpu_addr` alongside size and length for every send;
it is `0x1015c000` on a boot and does not change between sends, so a payload can
name the door's own buffer. That single number is what makes an A3 payload
testable at all: before it, every nonzero pointer in a payload was a guess.

## 2026-11-14 (U371: the crash PC is an event loop, the second address a log site)

Offline decode of the two firmware addresses from U370. `0x100D20C8` is a
Thumb-2 function prologue that polls a word with `lda`/`stl` and calls through
`ldrd r3, r0, [r5, #4]; blx r3` inside a retry loop - the shape of an
event/poll loop, not of a 64-byte payload parser, so it is the faulting context
rather than the field reader. `0x100D1446` is inside a log call (`movs r0,
#0x8c` = line 140) whose literal is "Expected chip type %d in executable, got
%d.", so the second address is a logging site. A2 therefore still needs the
per-code record that carries 64; the crash report alone does not hand over the
struct.

## 2026-11-14 (U370: code 15 takes 64 bytes, and its handler faults)

Code 15's DMA descriptor size is **64**. Through the debugfs door, 63 and 65 are
refused by name (`Invalid KCI DMA descriptor size N`) and 64 is accepted, then
answers nothing: the write returns `-110` (`Connection timed out`), three times,
on two boots, with 63/65 as controls. A zeroed 64-byte payload is enough to make
the firmware fault: `ERR log_embedded.cc:83 - 0x100D20C8` and `0x100D1446`,
then `firmware unrecoverable crash` - the first firmware code addresses this
path has ever produced. KCI 11 still answers 0 right afterwards, so the firmware
survives and only that handler falls over. `fw_info` reads
`{build_time 0x69d449f1, flavor 3, changelist 'VHa5', spare[0..9] = 0}`, so A4
finds no state word. This is the first KCI command whose payload gate has been
satisfied; the 64-byte struct's first field is a pointer the zeroed payload
gives as null. No inference.

## 2026-11-14 (U369: this firmware logs only errors)

`fw_tracing/request` 15 (no default-vote bit) reports `active 1`, and the
control send produces no new firmware line beyond
`ERR vii_handler_layer.cc:247 - Setup is not done yet received a command of type
0`. So the build exposes error level only: there is no debug oracle to raise.

## 2026-11-14 (U368: the chroot has no setup blob)

`/vendor/firmware` in the vendor chroot holds only the three
`gxp_callisto_fw_core*` images, and `/vendor/etc` holds graph containers
(`graph-dgc0.bin`, `graph-dwn1.bin`, `graph-scratch.bin`, ...) plus the VINTF
fragments. Nothing there is a firmware-setup artifact, so the missing producer
is not a file we simply never pushed.

## 2026-11-14 (U367: no public Google source has the producer)

Google's public gs101 vendor module (`kernel/google-modules/edgetpu`, branch
`android13-gs-raviole-5.15`) has the same KCI enum with the 15..18 gap and the
same `setup_buffer` that only loads the image; the open-source Coral runtime
(`google-coral/libedgetpu`) has no firmware-setup producer at all. So the
producer exists only in the vendor userspace HAL/service, and R5 is closed by
source rather than by another experiment.

## 2026-11-14 (U366: the dense size sweep, and the one size that is not refused)

Code 15 was swept over **every** size 1..4096 in chunks of 384 so the kernel
ring retained every line (`logs/tpu/20261114-kci-dense.txt`): all answered `-> 3`
except **size 64**, which answered `-> -110`. 63 and 65 answer `3` in isolation,
so 64 is the handler's constant, not a flood artifact. The first pass's
`firmware unrecoverable crash` was the same handler faulting. Code 16's dense
1..1024 sweep is all `-> 3`; its constant is still unknown.

## 2026-11-14 (U365: the kernel's setup handler is image loading)

`mobile_firmware_setup_buffer` (`mobile-firmware.c:382`) runs once per firmware
load: GSA authentication, the image config's version words, and the TPU's IOMMU
and carveout mappings. It sends nothing. U275 stands with the code read end to
end, and that name is not the missing setup.

## 2026-11-14 (U364: code 15/16's size check, swept to its edge)

The firmware names the check: `ERR tpu_kci_handler_thread.cc:298 - Invalid KCI
DMA descriptor size N.` Through the debugfs door, every size 1, 2, 4, 8, 12 ...
4096 and 8192 ... 524288 answered `-> 3` with that line. The check is neither a
small struct nor a page or pool size, so the codes stay unnamed and the axis is
exhausted like P1's. The string at `0x100e7554` has no literal and no
`movw`/`movt` pair in the decoded body: the static route needs the log-site
index (U178), not an address scan.

## 2026-11-14 (U363: the harness drove the client shim)

Both libraries export `GetDarwinnHalFunctions`: the 3,785,000-byte
`libdarwinn_dba_hal_runtime.so` at `0xf772c`, and the 37,089,408-byte
`libdarwinn_hal.so` at `0x83130c`. The harness's own string loads the runtime,
so every in-process create on record ran the *client* shim. The 37 MB library
is the one with `SetupFirmware`; its A17 device path has reset the phone before
(A9), so the next attempt is one attended boot with `tpu-hold` alive and a
reset as the stop condition.

## 2026-11-14 (U362: the wake that never comes)

A 20 s futex trace of `MODE=create NOFORK=1` (attached before the wait) shows
the main thread on `WAIT_BITSET|CLOCK_REALTIME` at `0xffff8a821180` val 0 with
frames `runtime+0x33003c 0x30f760 0x332f20 0x332f5c 0x333088 0x1202a4`, and the
three workers on `0xffff8aa1db90` val `0x4002`. **No `FUTEX_WAKE` touches
either word in the whole run**; the only five wakes are the main thread's own
thread-start handshakes before 0.11 s. The runtime has no event source at all -
it is the client half of a pair whose peer is absent, not a waiter for a slow
poster. No inference.

## 2026-11-13 (U361: the wait is a bionic condvar)

`strace` is absent, gdb 16 is present; `catch syscall futex` on the blocked
create shows `x1 = 0x89` (FUTEX_PRIVATE_FLAG | FUTEX_WAIT_BITSET) and
`x2 = 0x4002`. So the runtime waits in bionic's condition-variable
implementation with the worker word as its expected value, reaching it through
bionic's internal entry rather than the public `pthread_cond_wait` - which is
why the interposer was bypassed. No inference.

## 2026-11-13 (U358-U360: WaitForEvent, and a callback that never rings)

The wait's code is read: `0x333054` is a `WaitForEvent` wrapper over `0x332e88`
(with `0x333098` its infinite-timeout twin), inside the runtime's Google
`thread`/EventManager2 executor. The event loop dispatches through the event's
own thunk (`ldr x9,[x8,#0x20]; str xzr,[x8,#0x20]; blr x8`). The harness's
callback now logs its calls, and a 3 s create produced none: the host contract
is not what blocks. Nothing posts the event the manager waits for, so the next
instrument is a futex syscall tracer. No inference.

## 2026-11-13 (U354-U357: the blocked create, named from outside)

A standalone sampler (gcc 16 on the phone, static) attaches to a target's
threads, reads registers with PTRACE_GETREGSET and scans the stack with
process_vm_readv. Against `MODE=create NOFORK=1` it shows three runtime threads
on one futex (word 0x4002) and the main thread on another (word 0), every frame
inside `libdarwinn_dba_hal_runtime.so` - whose only export is
`GetDarwinnHalFunctions` - and no device fd at all. So the wait is the
runtime's own raw futex, which is also why the pthread_cond_wait interposer
never fired. P3 is corrected: `0x14d9eac` never saves x1, so the 40-byte record
is dead there and the type-5 serializer is a different function. No inference.

## 2026-11-13 (U349-U352: the read channel, and code 6 is not setup)

`kci_result` hands back the last KCI command's DMA buffer, and `GET_USAGE_V1`
writes a real v1 report (17 metrics of 20 bytes; first counters 225488, 967000,
712000, 1250000, 1066000), so the firmware now talks in data. The firmware's
debug and verbose log entries reach dmesg too, and with them code 6 explains
itself: `ERR power_manager_interface.h:99 - Mitigation is not configurable by
the firmware` - the enum's gap is a power-mitigation request, not setup, and
that route is closed. Codes 15/16 stay unnamed; their size rule is not solvable
with a 512 KiB pool cap. No inference yet.

## 2026-11-13 (U346-U348: the KCI DMA window, and the firmware answers)

The debugfs KCI door allocated its descriptor at `0xfffxxxxx`, outside the only
window the firmware accepts; KCI's own buffers come from the iremap pool
(`0x101xxxxx`). With the hook on `edgetpu_iremap_alloc(..., EDGETPU_CONTEXT_KCI)`
the firmware answers for real: `GET_USAGE_V1` (12) and `V2` (21) return **0** with
a 4096-byte descriptor, code 6 returns **14 UNAVAILABLE** instead of
`INVALID_ARGUMENT`, and codes 15/16 are implemented and check the descriptor's
address, then its size. No inference yet. The driver change runs on the phone
(`janeiro.ko`, backup `janeiro.ko.before-kci-dma`), two clean reboots with the
modem down.

## 2026-11-13 (U345: P1's premise corrected)

`tpu-hold` must not be stopped for an element send: it holds the boot's one
power-up, and stopping it releases the wakelock, so the next open is the second
power-up that wedges the PSM (U54). Every element send on record ran with it
alive (U273), and P1 now says so.

## 2026-11-13 (U344: P3's first two windows excluded)

`0x14d9eac` hands the 40-byte record to `0x14de9cc` without reading it, and that
function builds a limits block instead of parsing. Neither window is the field map;
the cheap filter for the next one is to count `[x1]` accesses first.

## 2026-11-13 (rev 17: re-evaluation - the plan's two wrong claims are out)

Rev 17 withdraws "no observation channel" (the firmware's log reaches dmesg, 1.13)
and "24-byte commands" (`0xcc7c24` is `vector::push_back`; the records are 40 bytes,
1.15). The usage queries fail on the descriptor's `flags`, not its size (U341), and
the action list is replaced by a program with an oracle at each step.

## 2026-11-13 (U339-U340: the builder route is closed, the addresses audited)

The setup values are built at run time from HAL objects, so no more disassembly can
recover them (U339); the cmdq element and the firmware-log oracle now meet, and
every load-bearing address has a checklist row saying whether its window was read
end to end (U340).

## 2026-11-13 (U335-U338: the firmware's own log is the oracle)

The driver decodes the firmware telemetry ring into dmesg, so every KCI command
returns a verdict in the firmware's own words. `kci_send` answers deterministically
(11 -> 0, 12 -> 3 "DMA descriptor is invalid", 21 -> 3, 8 -> 12 UNIMPLEMENTED), and
`fw_tracing/request` is a second round trip (255 -> active 1, 0 -> 0). KCI has no
setup code at all: the setup element is a Tachyon command. `tools/tpu-oracle` is
the door.

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
