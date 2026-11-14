# TPU stock oracle: capturing the setup the firmware wants

Status: **owner-gated, not run.** Every step below needs the owner present at the
phone. Nothing here runs unattended, and no step is reversible by an agent.

## Why this exists

On our A17 firmware the VII door is gated by `Setup is not done yet`, KCI 15/16
refuse host calls (U380), and no public source contains a setup producer (U367).
The only place the setup has ever run is stock Android on slot A. This runbook
captures it: the VII elements stock's HAL submits, in order, with their exact
bytes and their answers. That capture is the input the plan's G0 gate needs.

## The risk, stated before anything else

Stock Android on slot A boots with its own `userdata` expectations. Ours holds
the Arch root. Stock cannot decrypt it and **may format it**, exactly as on the
tegu precedent in AGENTS.md. Choose one before starting:

- **accept the loss** of the installed Arch root (reinstall from a release
  bundle afterwards), or
- **use a second phone**, or
- **stop here**. No step below is required for anything else in the plan.

Record the choice, with its date, in this file. An agent may not make it.

## Prerequisites (read-only, all must pass)

1. `tools/phone-smoke` on the running Arch phone: storage guard, root, session,
   USB, display, battery.
2. `tools/nv-backup` of `efs`, `efs_backup`, `modem_userdata`, `persist`,
   `modem_a/b`, then `--check` against it. Store it off-repo; it holds the IMEI.
3. A release bundle matching the installed version, so the Arch root can be
   restored without guessing.
4. `tools/phone-ssh 'cat /proc/cmdline'` and the slot (`omamobile-bootctl slot`
   or `/proc/cmdline`'s `androidboot.slot_suffix`), recorded here.

**Stop** if any prerequisite fails. There is nothing to recover with afterwards.

## Steps

### S1 (owner, risk high). Boot stock on slot A

`fastboot --set-active=a`, then a normal boot. Expect stock Android's lock
screen. **Pass:** stock boots and the TPU node exists (`/dev/janeiro` or the
vendor HAL's device) under `adb shell`. **Stop:** stock offers recovery or a
factory-reset screen; hold Volume Down + Power for fastboot, set slot B active
again, and stop the run. **Rollback:** `fastboot --set-active=b` and boot Arch.

### S2 (owner, risk medium). Capture the setup sequence

Run `tools/tpu-stock-capture` (NNAPI before/after) with the phone idle, then once
with a model actually compiled for the TPU. Expect `logcat` lines naming
`edgetpu_app_service`, `vii`, and `Setup`. **Pass:** the capture holds the setup
elements with their bytes and replies. **Stop:** if the HAL never loads, capture
`logcat -b all` for 60 s and stop; a missing HAL is a finding, not a failure to
push through.

### S3 (owner, risk medium). Return to Arch

`fastboot --set-active=b`, boot, then `tools/nv-backup --check` again (stock has
written `efs`, `persist`, `modem_userdata`; a mismatch is expected and is why a
fresh backup follows) and take a new one.

## What the capture must contain to count

- the VII element bytes for the first setup submission, and its reply;
- the order of any follow-up elements;
- the firmware build id stock loaded (differs from ours or not);
- whether the gate line `Setup is not done yet` appears at all on stock.

If the gate appears on stock too, the falsifier in TPU-PLAN §13 fires: the gate
is not about the HAL, and the whole route needs re-reading.
