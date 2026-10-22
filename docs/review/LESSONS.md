<!-- SPDX-License-Identifier: MIT -->
# Review lessons

What reviewing pull requests on Omarchy Mobile has taught us, one lesson
per entry: the rule, why it matters, how to check it, and the review it came
from. The reviewer agent (`.claude/agents/omamobile-reviewer.md`) reads this
file before every review, and a human reviewer can use it as a checklist.

**How it grows.** Each review ends with candidate lessons: a pattern that
caught a real problem, or a mistake the review made. The maintainer confirms
or corrects them, and confirmed ones are added here in the same commit as
the change that prompted them (`docs/review: …`). A lesson that turns out
wrong is corrected in place, with the date and why, never silently deleted:
the corrections are lessons too. Keep entries short; link the evidence.

Entries are grouped by area, newest first within a group. `L-<n>` numbers
never change, so reviews can cite them.

## Safety model (AGENTS.md section 1)

- **L-1. Shared boot code runs under busybox, not util-linux.** The Pixel
  initramfs has busybox only: `blkid -s LABEL -o value` prints the whole
  `LABEL=… UUID=…` line there, so a label check that works on a device whose
  initramfs adds util-linux fails on every Pixel. *Check:* any new command or
  option in `initramfs/init`, against busybox 1.37's applets; prefer tools
  `init` already uses (`dumpe2fs -h`). A test that stubs the command
  (a shell function named `blkid`) proves nothing about it. *From:* #25.
- **L-2. Writes past the storage guard are a policy decision, not a code
  review.** Raw SCSI WRITE through `SG_IO` on a read-only partition fd, an
  unsuffixed `fastboot flash userdata`, a `devinfo` write: each needs the
  maintainer's explicit go and a named exception, however well guarded.
  *Check:* `grep -nE 'SG_IO|0x2285|fastboot( -s [^ ]+)? (flash|erase) [a-z_]+( |$)|devinfo'`
  in the diff, and every `flash`/`erase` target ends in `_b` or is
  `userdata` through the guarded path. *From:* #17, #24.
- **L-3. Mismatched slot firmware is stop-and-ask (CONTRIBUTING §3.1).**
  A kernel workaround that's needed only on a phone with different
  bootloaders on its two slots (HCRX_EL2 with KVM off) is most likely the
  old firmware, not the SoC. Ask for both slots' bootloader versions, both
  slots on one build, and a re-test without the workaround before any of it
  reaches the kernel. *From:* #24.
- **L-4. A display-register write in a descriptor must be the device's own
  address, behind the COMPATIBLE gate.** `SIMPLEFB_TRIG_CON` is the one
  register write the initramfs makes. *Check:* the address is that SoC's
  DECON base (from the device's own live DT or Google's GPL CAL for that SoC)
  plus the `TRIG_CON` offset, not cheetah's `0x1c240030`; the value is the
  same bit change cheetah's pair makes (DISPLAY-PLAN); `COMPATIBLE` is
  unique to the board, so `board_matches()` in `initramfs/init` means
  something. *From:* #23 (correct: husky's `0x19470030 0x3061`).
- **L-5. Tools that talk to fastboot pin the serial.** With two phones in
  fastboot (the maintainer's Pixel on the desk), checks and writes without
  `-s <serial>` can reach different devices. *Check:* every `fastboot` call in
  an installer passes `-s`. *From:* #25.
- **L-6. A device whose buttons don't reset it under our kernel needs a way
  out of a hang.** Once a watchdog driver stops ABL's watchdogs, a hang that
  never panics lasts until the battery is flat. *Check:* panic-on-lockup
  arguments (`softlockup_panic`, `hung_task_panic`, `panic=`) in the shipped
  bootargs, or the watchdog left armed and fed. *From:* #23.
- **L-7. Contributors' builds stay out of the maintainer's keys and
  outputs.** A port that reuses `keys/gnupg`, rebuilds `omamobile-keyring`
  into `out/repo`, or names its root images `out/omamobile-rootfs-*` mixes
  into what `tools/repo-push` publishes and what `install-phone` picks by
  default. *Check:* new build scripts write under `out/<device>/` and
  `keys/<device>/`. *From:* #25.

## Shared code and the reference device

- **L-8. "Nothing changes for cheetah" is checked by building it.** For any
  change to `bin/omamobile`, `initramfs/`, `rootfs/`, `tools/` or a shared
  package: build cheetah's images with main's tool and the PR's, in separate
  scratch output directories, and compare sha256s. *From:* #27 (all six
  images and every DTB identical).
- **L-9. A test whose baseline is `origin/main` stops testing once it
  merges.** Pin the baseline (a commit, or recorded checksums). *From:* #27.
- **L-10. Parsers of decompiled DTBs must allow labels.** Our DTBs are built
  with `-@`, so dtc restores labels (`x: node {`) from `__symbols__`; a
  regex for `^\t\tNAME {` misses a labelled child and passes a DTB with an
  extra one. *Check:* feed the parser a labelled node and an extra child.
  *From:* #27.
- **L-11. Shared root-image changes need their own commit and a Pixel
  rationale.** Masking `systemd-firstboot`, a coredump drop-in, a
  `clock-epoch` file or `Wants=time-set.target` in `rootfs/build-inside`
  changes every device's image. (systemd.special(7): order after
  `time-set.target`, never pull it in.) *From:* #25.
- **L-12. Package versions can collide with main.** A PR bumping a package
  to a version main already shipped (with different contents), plus a
  dependency `>=` that version, installs without the PR's change. *Check:*
  `git show origin/main:packages/<p>/version` against the PR's. *From:* #17.
- **L-13. Device-specific tool stages must refuse other devices.** A raven-only
  AoC stage (`cycle`, `tzpc`, `pd`, `s2mpu`) accepted on cheetah power-cycles
  the reference phone's AoC; a stage the PR's own notes say aborts the SoC
  unless another ran first must enforce that order (a per-boot marker).
  *From:* #22.

## Shell and scripts

- **L-14. `$(ls … | tail)` at the top level under `set -euo pipefail`
  exits the script** silently (status 2) when nothing matches, before any
  argument is parsed. *Check:* glob-and-pick at the top level of any script
  run by others; compute it inside the branch that needs it, tolerating no
  match. *From:* #22 (it broke `phone-provision` for every cheetah user).
- **L-15. `grep -q` under `pipefail` SIGPIPEs the writer** (AGENTS.md
  Userspace); use `grep -c … >/dev/null`. *From:* #22.
- **L-16. `read` with `IFS=$'\t'` collapses empty fields** (tab is IFS
  whitespace), shifting the next field into the empty one. Use a
  non-whitespace separator (`$'\x1f'`). *From:* our own `tools/phone-smoke`.
- **L-17. Unchecked files written to the boot path.** A splash or blob copied
  into the initramfs and written to `/dev/fb0` needs a build-time check
  (`gzip -t`, exact size W×H×4) and a logged sha256, so the image can be
  reproduced. *From:* #21.

## Kernel (linux-omarchy-mobile)

- **L-18. Check every commit for a human `Signed-off-by:`.** Three PRs at
  once came without one, while their bodies said "checkpatch clean": it was
  run on a diff, where the sign-off check can't fire. `tools/kernel-pr-check`
  checks it now. *From:* kernel #10, #11, #12.
- **L-19. Clock fixes belong in the clock driver's field description, not
  in a DT override.** `assigned-clock-parents` on a mux the driver describes
  at the wrong bit writes a reserved bit. *Check:* the mux's shift and width
  in `clk-gs101.c`/`clk-gs201.c` against Google's CMUCAL `cmucal-sfr.c`
  (`SFR_ACCESS(..._SELECT, shift, width, ...)`) for that SoC; CMU_APM is the
  ACPM firmware's own clock block, so prefer read-only there. *From:*
  kernel #6 (gs101 APM_FUNC: driver bit 4, Google bits [1:0]).
- **L-20. Kconfig `depends on` must cover every bus the driver registers
  on.** A driver that calls `spi_register_driver()` unconditionally with
  `depends on I2C` fails to link with `CONFIG_SPI=n`; our config has SPI on,
  so we'd never see it. *From:* kernel #8.
- **L-21. No wildcard compatibles** (`samsung,s6sy79x`): name the real part.
  *From:* kernel #8.
- **L-22. Power domains: follow the upstream series, and leave live
  co-processors alone.** A `google,gs101-pd` that differs from André
  Draszik's pending upstream series (domains as PMU children,
  `domain-supply`, the EL3 DTZPC call around every power change) will
  conflict; without the DTZPC call a domain powered back on comes up with
  its TrustZone settings reset. Powering off the AoC's domain while the AoC
  runs, with no handshake, belongs to the AoC series. *From:* kernel #9.
- **L-23. Thermal: the hardware trip is the last line of defence.** A driver
  that sends ACPM's TMU init must show the firmware's hardware thermal trip
  survives it; blocks with only a 110 °C critical trip need a reason.
  *From:* kernel #7.
- **L-24. Alive pin banks have no power-down configuration.**
  `samsung,pin-con-pdn`/`pin-pud-pdn` on an alive bank (gpa*) return -EINVAL,
  which `samsung_pinconf_group_set()` ignores, so the DT describes a sleep
  state that's never applied. *From:* kernel #12.
- **L-25. A regmap without a read table exposes the whole block through
  debugfs.** On gs201 one PMU read crashed the phone; a PMU regmap should
  list the offsets it uses (`rd_table`/`wr_table`). *From:* kernel #15.
- **L-26. A hall sensor reported as `SW_LID` makes logind treat a folded
  phone as a closed lid** (suspend by default). Fine in the kernel; the
  device's userspace must handle it. *From:* kernel #12.
- **L-27. gs101 and gs201 numbers differ.** Interrupts, sysreg offsets and
  EINT numbering (gs201 skips EINT19) must come from that SoC's stock DT or
  Google's tree for it, never from the other SoC. *Check:* compare against
  stock's node (USI6 on gs201: GIC SPI 679, `0x1014`). *From:* kernel #10
  (correct).

## Claims and evidence

- **L-28. "Works" needs merged notes and the phone it ran on.** A matrix row
  claiming works/testing from a private kernel, or from an install of a
  different branch, should say WIP or testing and link the notes.
  *From:* #24, #25.
- **L-29. PR bodies written with an AI over-claim.** "checkpatch clean",
  "dtbs_check clean", "tested" were each untrue at least once this week.
  Re-run the claim; never quote it. *From:* kernel #10-#12, #27.

## Corrections (where a review was wrong)

- **C-1 (2026-10-22). We blamed the 30 s unused-regulator cleanup for the
  felix cover touch's dead rails (issue #3).** We have no S2MPG12 regulator
  driver at all (cheetah's `s2mpg12-pmic` node is RTC and interrupt masks
  only, and disabled), so nothing in Linux can turn those LDOs off: the rails
  are off as ABL left them. *Lesson:* before blaming a kernel mechanism,
  check the driver for it is actually bound on that device
  (`/sys/kernel/debug/regulator/regulator_summary`, the DT node's status).
