# Orchestrator prompt: autonomous subagent chain (Edge TPU on cheetah)

You are the orchestrator of a long-running autonomous work loop in the
Omarchy Mobile repo at `/home/robertzas/projects/omarchy-mobile`. Your only
job is to create and manage **one subagent at a time** (via the Task tool).
Never run subagents concurrently, and never do the repo work yourself —
delegate everything.

This file is a local working file (like `prompt.md`): do not commit it unless
the human asks.

## Autonomy envelope (what may run without a per-step prompt)

- **Between hops and across sessions the chain needs no user interaction:**
  the orchestrator keeps launching the next subagent with the previous
  subagent's continuation prompt, runs laptop-side work (builds, disassembly,
  gdb reads, `tools/pr-check`, commits) unattended, and only stops at its
  own ~200k context cap. Never pause to "ask the user" whether to continue —
  that is what the continuation prompt is for.
- **Read-only phone steps always allowed:** `tools/phone-ssh`,
  `tools/phone-usb`, `tools/tpu-test`/`tpu-check`/`tpu-info`, dmesg/sysfs/
  debugfs reads, `gdb` reads of a stopped client.
- **Phone-mutating development steps run unattended** under the owner's
  standing grant of 2026-11-07 (AGENTS.md §1.1, `device/cheetah/TPU-PLAN.md`
  section 0): `systemctl poweroff` (then wait for the human to press Power —
  a physical action, not a question), `reboot-to`, `bin/omamobile push`,
  `bin/omamobile flash` of the suffixed slot-B images only, `kexec`,
  `insmod`/`rmmod` of the TPU development modules, any client run that powers
  the TPU, overlay boots. Keep the safety nets (log stream, `--watchdog`, USB
  deadman) and put a one-line notice in the plan or log before anything that
  affects the screen or the feel of the phone.
- **Anything in the permanent-brick class: ask the human first, every
  time.** This gate is non-negotiable (AGENTS.md §1/§1.1): any write to
  bootloader, radio, `devinfo`, `persist`, `efs*`, `modem*` or `vbmeta`; an
  unsuffixed `fastboot flash`; a `userdata` write outside
  `tools/install-phone`; storage-guard weakening; NV-overlay
  enable/reset/allow-list; PMU register access; reads of blocks not known
  powered; booting stock on slot A; `tools/install-phone`; boot-update
  `write|rollback`; the release/publish tools. The phone carries
  irreplaceable calibration data, slot A is the way back, and this repo is
  public.

## Orchestrator loop

1. Launch exactly one subagent using the current continuation prompt
   (initially this file; afterwards the prompt emitted by the previous
   subagent).
2. Wait for it to finish and read its result. Do not duplicate its work.
3. If it reached its context cap, it will end with a self-contained
   continuation prompt. Launch the next subagent with that prompt and let
   the old one terminate (never resume it). Repeat.
4. Keep this going until **you** approach ~200k context. Then stop: make
   sure `device/cheetah/TPU-PLAN.md` and `device/cheetah/NOTES.md` are
   current and everything is committed, and end with a short final summary
   plus a self-contained continuation prompt the user can paste into a fresh
   session to restart the orchestrator.

## Subagent contract (embed in every continuation prompt)

Each subagent is hard-capped at ~200k context and must:

- **Objective:** keep working toward a **working Edge TPU (Janeiro) on
  cheetah (gs201)** — specifically T6, one real int8 inference checked
  against CPU TFLite. Read `AGENTS.md` first, then the status line and the
  U-series of `device/cheetah/TPU-PLAN.md` (U1-U15 hold the evidence),
  the newest entries in `device/cheetah/NOTES.md`, and `prompt.md` (the
  current cycle's next steps). Do not start unrelated work packages.
- **Repo protocol (AGENTS.md):** read before you touch; one change per
  boot; new DT nodes stay `disabled` and are enabled by overlays in
  `device/cheetah/overlays/` (`tpu-test.dtso`, `tpu-enable.dtso`); build
  with an explicit worktree/output:
  `KERNEL_DIR=~/omamobile-kernel/wt-tpu KERNEL_OUT=~/omamobile-kernel/out-tpu bin/omamobile kernel`
  (branch `omamobile-tpu`), then `bin/omamobile modules`, `bin/omamobile
  images` with the overlay added to `DTB_OVERLAYS`, `tools/kernel-pr-check
  --build` / `checkpatch` / `W=1` / `dt-validate` yourself; `bin/omamobile
   push` and every reboot/flash/poweroff run unattended under the 2026-11-07
   autonomy grant (Autonomy envelope; AGENTS.md §1.1) — the permanent-brick
   class still asks first.
- **Phone protocol:** `tools/phone-ssh CMD` (root over USB,
  172.16.42.1; run `tools/phone-usb` first if another USB phone may be
  attached — it selects the Pixel by `USB_PRODUCT`). Read-only gates:
  `tools/tpu-test --expect none|sysmmu|nodes|group|device`,
  `tools/tpu-info`, and `tools/phone-ssh 'python3 -' < tools/tpu-info`.
  The experiment client is `tools/edgetpu-run.c` (modes: `raw`, `hold`,
  `probe`, `setup OFFSET WIDTH VALUE`, `payload CODE P0`, `mapped CODE P0`,
  `scratch CODE FLAGS`, `hal`, `halcall device [SECONDS]`); on-phone drivers
  are `/root/tpu-raw.sh` and `/root/tpu-hal.sh`. **One TPU run per cold
  boot**: a second device create in the same boot wedges the PSM
  (`Set LPM0 failed: -110`, `GSA state 1`), and the only cure is a full
  poweroff with the human pressing Power. `tools/phone-ssh 'systemctl
  poweroff'` runs unattended under the 2026-11-07 grant — always announce
  that the screen goes dark; waiting for the Power press is not asking. Arm the log stream (`dmesg` to `logs/` first) and the USB deadman
  (`tools/usbc-deadman`) before anything that loads the driver or pokes the
  TPU; never restart Trusty/storageproxyd — reboot instead.
- **Commits:** commit at checkpoints with the repo's area prefix
  (`TPU-PLAN: …`, `device-cheetah …: …`), a body that says why, no
  `Signed-off-by` from agents (kernel commits: upstream-style subsystem
  prefix, evidence, no sign-off). Others may have uncommitted work in the
  tree: commit only your own files with a temporary index (AGENTS.md §2).
  Update `TPU-PLAN.md` in the same commit as the change it documents; each
  result gets a dated section with the proving dmesg lines and `uname -r`.
  Before committing, grep the diff for identifiers
  (`[0-9a-f]{2}(:[0-9a-f]{2}){5}`, serials, SSIDs) — and never commit the
  firmware image, the vendor chroot, `out/factory`, `out/tpu-firmware`,
  `logs/`, or any vendor blob (all gitignored or private).
- **Context discipline:** estimate your usage as you go. At ~125k stop
  starting new investigations and finish the current one. At ~150k begin
  handoff.
- **Handoff (mandatory before hitting the cap):**
  1. Persist everything a fresh agent needs: a dated section in
     `device/cheetah/TPU-PLAN.md` (state, blocker with `file:line`
     pointers, exact next steps), a `NOTES.md` entry if it was a hardware
     finding, everything committed, `tools/pr-check` green for touched
     packages.
  2. As your **final message**, output one self-contained continuation
     prompt for the next agent: the objective; current state and blockers
     with `file:line` pointers; exact next steps and repro commands; and
     the standing rules above — the next agent gets nothing else.
- The orchestrator then launches the next agent with that prompt and
  closes this one.

## Standing constraints (every agent, every hop)

- Stay inside this repo. The phone is real shared hardware: reboots,
  poweroff, `push`, `flash` (slot-B suffixed images only) and overlay boots
  run unattended under the 2026-11-07 grant (AGENTS.md §1.1, TPU-PLAN.md
  section 0); **ask the human first for anything in the permanent-brick
  class** (Autonomy envelope), and announce anything that affects the screen
  or the feel of the phone. Only slot B and `userdata` are ours; never touch
  bootloader, radio, `devinfo`, `persist`, `efs*`, `modem*`, `vbmeta`, and
  never run an unsuffixed `fastboot flash`.
- Never weaken the storage guard; never write the modem NV partitions;
  never read/write PMU registers from userspace; read only blocks known
  powered, one register per call on a first probe.
- Never commit secrets, identifiers, Google's firmware, or vendor binaries;
  captures stay in `~/android/reference/` and `logs/` (never committed).
- Never edit `.kilo/`. Quality first — never trade correctness for token
  savings.

---

# Continuation prompt for the next worker — Omarchy Mobile cheetah Edge TPU, T6: pass the VII setup gate (2026-11-07)

**Objective:** get one real int8 inference through the phone's Edge TPU from
Linux, output checked against CPU TFLite. Repo:
`/home/robertzas/projects/omarchy-mobile`. Read `AGENTS.md`,
`device/cheetah/TPU-PLAN.md` (status line + U1-U15 first), `prompt.md`,
newest `device/cheetah/NOTES.md`.

**Current state (2026-11-06, kernel `7.3.0-rc6-omamobile-push1-g29a7a9326bf0-dirty`,
slot `_b`):** T2.2-T2.5d, T3 (ACPM shim `edgetpu-acpm.c`, domain 7 channel 0),
T4 (GSA loads signed `edgetpu-janeiro.fw`, firmware 1.0, KCI 3, VII 2) and
T5 (`/dev/janeiro` query via `tools/tpu-info --load`) all passed on the phone.
SysMMU v8 at 1cc40000 is bound as `samsung-sysmmu`; the IOMMU group exists.

**Blocker:** every VII command element is answered `0xf000009` with
`ERR vii_handler_layer.cc:247 - Setup is not done yet received a command of
type 0.` Both the stock app runtime (`libedgetpu_util.so`) and the HAL
(`libdarwinn_hal.so`, entry [3] via `edgetpu-run halcall device`) hit the
same gate; KCI has no setup command (code 6 skipped in Google's newest
`edgetpu-kci.h` too), and the driver has no setup send. The brute force over
element codes/flags (U8) is exhausted: the setup is a VII command carrying a
global-scratch list, and its producer is the runtime's Tachyon
"firmware setup" — `libedgetpu_tachyon.google.so` exports
`TachyonComputeSession::SetupCommandFmq(int*, int*)` /
`SetupResponseFmq(int*, int*)` (U15).

**Exact next steps (from `prompt.md`):**
1. Recover the exact setup message from the A17 runtime on the laptop:
   `llvm-objdump` (`~/.cache/omamobile/toolchain/clang-r596125/bin`) on
   `libedgetpu_tachyon.google.so` / `libedgetpu_util.so` around the
   cross-reference to `Firmware setup failed for commands[%d], cluster_id_bitset in hex: %x.`
   to get the message layout and opcode; do not guess the opcode from the
   public Coral `driver/` tree.
2. Send it from the driver's own group, the way `scratch_mode` does in
   `tools/edgetpu-run.c`: create group, finalize, map one page as scratch
   (`EDGETPU_MAP_BUFFER`), opcode in the element code field, `{addr,size}`
   in the DMA descriptor, ring the doorbell, print the response. Any answer
   other than `0xf000009` (e.g. `KCI_ERROR_INVALID_ARGUMENT` 3 for a setup
   without scratches) identifies the opcode. Walk candidate opcodes inside
   **one** group — the boot's one run is all we get.
3. If the firmware still reports `type 0` everywhere, vary element bytes one
   at a time with distinctive values in a single run and read which byte the
   firmware's `type %d` reports (`/sys/kernel/debug/edgetpu/janeiro`, dmesg,
   and the driver's `vii-payload` dump, which hex-dumps the element's
   descriptor target).
4. With setup accepted: run `halcall device`, then `graph.bin` through the
   runtime, compare with a CPU TFLite run; record latency, temperature,
   `uname -r` in the plan.

**Phone procedure for the one run (pre-authorized unattended by the
2026-11-07 grant, AGENTS.md §1.1; the only human action is pressing Power
after a poweroff):**
1. `tools/phone-ssh 'systemctl poweroff'`; announce the dark screen, wait
   for the owner to press Power; poll `tools/phone-ssh 'cat /proc/uptime'`.
2. `tools/phone-ssh 'insmod /root/janeiro-new.ko'` (rebuild first with
   `KERNEL_DIR=~/omamobile-kernel/wt-tpu KERNEL_OUT=~/omamobile-kernel/out-tpu bin/omamobile kernel`
   when the driver changes), `ln -sfn janeiro /dev/edgetpu`, bind `/dev`
   into the chroot (`mount --bind /dev $R/dev`).
3. Run the single client (`/root/tpu-raw.sh` / `/root/tpu-hal.sh` or
   `tools/phone-ssh ... < tools/edgetpu-run.c`), print everything, let it
   exit cleanly; keep it under `timeout` only as a last resort — a kill
   mid-group costs the boot's run.
4. Record the dmesg lines (`Set LPM0`, `GSA state`, `loading TPU image`,
   `OPEN_DEVICE`, `firmware handshake`, `vii-payload`) in TPU-PLAN.md with
   date and `uname -r`.

**Firmware (never commit):** `out/tpu-firmware/edgetpu-janeiro.fw`,
1 038 272 bytes, sha256
`52c1cccdf0e243d12fbc9f3b3911fe9c780a11d9a5bfda61744c7c3fdaded7c3`,
extracted read-only from the owner's factory `vendor.img`; installed on the
phone at `/usr/lib/firmware/updates/google/edgetpu-janeiro.fw`. Header:
`TPUF` at 0x400, ImageConfig 0x560, `firmware_base` 0x93000000, size 0xfd000,
body A32 at 0x1000; setup strings at 0xefbdc/0xefddc/0xefe18/0xe7b90.

**Standing rules:** you are allowed to reboot/poweroff/push/flash unattended
(2026-11-07 grant, AGENTS.md §1.1); anything permanent-brick-class still asks
the human first. One TPU run per cold boot, and a wedged PSM needs a real power cycle —
never restart Trusty/storageproxyd, never kill a client mid-group; keep the
IOMMU attached, never weaken the S2MPU/storage guard; commit only your own
files (temporary index if others have uncommitted work), area-prefix
messages, grep the diff for identifiers first, never commit firmware/vendor
blobs/`out/`/`logs/`; `tools/pr-check` before pushing; context discipline:
~125k stop starting new investigations, ~150k mandatory handoff (dated
TPU-PLAN.md section with the proving log lines, commit, final message =
one self-contained continuation prompt).
