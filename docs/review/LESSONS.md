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

- **L-35. A changed `vbmeta` flags byte on slot A means slot A was
  written.** The flags field starts at offset 120 of the vbmeta header;
  byte 123 = 3 is what `fastboot --disable-verity --disable-verification`
  writes, and it also breaks the signature. Treat it as a CONTRIBUTING §3.1
  event: record it, correct any "no verification-state change" claim, and
  have the OTA-twice equalisation restore flags 0 on both slots, then a
  read-only check and a fresh backup. *From:* #24, round 2.
- **L-36. Evidence that a `devinfo` layout matches comes from ABL's own
  reads and writes.** The version (3.15) alone doesn't prove the slot bytes
  mean the same on another SoC. *Check:* `fastboot getvar slot-successful`,
  `slot-unbootable` and `slot-retry-count` for both slots next to
  `omamobile-bootctl dump`'s bytes 0x30-0x37 for the same state, then again
  across a change ABL makes itself (a retry spent on an unmarked boot). Ask
  for those eight bytes and the version only, never a full dump. *From:* #24,
  round 2.

- **L-47. Every tool that talks to fastboot pins the serial, ours too.**
  L-5 covered installers; `bin/omamobile flash` and `capture` didn't pin
  either (fixed in c202b6d: one phone or `FASTBOOT_SERIAL`). *Check:* every
  `fastboot` call passes `-s`, and several phones are refused. *From:* #24,
  round 4.
- **L-48. When a PMU readback surprises, ask which write path ran and
  whether the restore was masked.** Mainline writes through atomic
  set/clear aliases (offset | 0xc000 / 0x8000), Google through a
  read-modify-write SMC; only a masked restore tells hardware status bits
  from stored ones. *Check:* the probe's call, the restore's mask, and
  Google's own users of that `pmu-offset`. *From:* issue #28.

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

- **L-32. Know what Omarchy already sets before claiming a userspace
  default.** `omarchy-settings` ships `/etc/systemd/logind.conf.d` drop-ins
  (`HandlePowerKey=ignore`), and Omarchy's Hyprland config binds the
  `switch:` named "Lid Switch" to its clamshell logic. *Check:* `pacman -Ql
  omarchy omarchy-settings | grep -E 'logind|lid'`, and on the phone
  `busctl get-property org.freedesktop.login1 /org/freedesktop/login1
  org.freedesktop.login1.Manager Handle…`. *From:* #29.
- **L-37. A kernel change that needs a userspace companion merges after
  it.** A new `SW_LID`, wakeup source, or any node whose default userspace
  policy is harmful (logind suspending a folded phone) waits for the
  omarchy-mobile change that handles it, so no build ever has one without
  the other. *From:* kernel #12 with #29.

- **L-49. "Disabled" means disabled in the DTB the phone runs: the DTS plus
  its `DTB_OVERLAYS`.** Cheetah's DTS has `pmic-1` disabled, but its
  `suspend-pmic-test` overlay enables it, so a new S2MPG12 cell binds on
  the reference phone. *Check:* grep the device's `DTB_OVERLAYS` for every
  node a PR's code binds to. *From:* kernel #27 (correction C-2).
- **L-50. A new MFD cell binds wherever an overlay enables its parent;
  for cheetah, ask for a read-only boot first.** Code reading said the
  S2MPG12 regulator driver only reads; one boot with `regulator_summary`,
  dmesg and `tools/phone-smoke` proves it. *From:* kernel #27.
- **L-51. Error-propagation fixes in shared drivers change the reference
  phone's failure modes.** A UFS PHY error ignored before became fatal at
  boot, reset and resume. *Check:* list which callbacks can now fail, grep
  cheetah's logs for those errors, and boot it once. *From:* kernel #19,
  #22.

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

- **L-33. A test that greps a systemd config's keys also greps its section
  header.** Keys under a misspelt section (`[Logind]`) are ignored with only a
  log warning, and a keys-only test still passes. *Check:* rename the
  section and run the package's `test/all`. *From:* #29.

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

- **L-52. Regulator nodes use the stock board's voltage, min = max.** A full
  selector range lets any consumer set any voltage; min = max also means
  registering writes nothing when the rail is already there. *Check:* the
  stock board dtsi's `regulator-min/max-microvolt`. *From:* kernel #27.
- **L-53. Identical driver data calls for a binding fallback, not a driver
  match.** A new SoC whose block is the same as an older one's gets
  `items: [new, old]` in the binding and no driver change; upstream expects
  it, and stock zumapro itself uses the zuma compatibles. *From:* kernel
  #29, #30, #31.
- **L-54. Diff a new SoC's stock dtsi against the file it includes.** That
  is where its overrides hide (zumapro's `phy_eusb_version` 0x701 over
  zuma's 0x700). *From:* kernel #29.
- **L-55. When a driver hands chip select to the SPI core, its own transfer
  path must stop driving it.** Otherwise it re-asserts on every transfer and
  overrides the core's `cs_off`. *From:* kernel #21.
- **L-56. Google sometimes ships more than one driver for the same chip;
  check which one the board builds** (`BUILD.bazel` under
  `kernel/devices/google/<board>`). Cheetah's and tegu's S3908 drivers
  power the supplies in opposite orders. *From:* kernel #26.
- **L-57. On arm64 a divide-by-zero guard changes nothing observable.**
  UDIV by zero returns 0 without trapping; disassemble before and after
  before calling such a patch a behaviour change or a hidden bug. *From:*
  kernel #25.
- **L-58. Google's `soc/gs` tree is one tree for every Pixel, and CMUCAL's
  `OSCCLK_* = 26 MHz` is nominal.** G4 builds from zuma sources, so a zuma
  citation for a G4 block can be right; and work out a PLL table entry
  before accepting a 26 MHz input (the real oscillator is 24.576 MHz).
  *From:* kernel #19, #23.

## The gates themselves

- **L-30. A gate failure can be the tool's own.** `tools/kernel-pr-check`
  compared device-tree warnings with their line numbers, so a PR that added
  two comment lines above an existing warning failed as if it were new
  (fixed 2026-10-22: positions are stripped). *Check:* reproduce any gate
  failure by hand before blaming the PR, and report a tool fault as a
  finding for the maintainer. *From:* kernel #11, round 2.

- **L-38. "No checks reported" is not a pass.** A pull request pushed
  before a CI workflow reached its base branch never ran it. *Check:*
  compare the push time with the workflow commit; until CI runs, call its
  checks (`dtbs_check`, the package suites) unchecked. *From:* kernel #10,
  #12.

- **L-40. Tools resolve their path arguments before they `cd`.** Our own
  `kernel-pr-check` changed into `-C` and then passed the same relative path
  on, so CI's `-C linux` looked for `linux/linux` and failed every kernel
  PR; a relative `--build` would have built, and deleted, inside the kernel
  checkout. *Check:* call a tool from another directory with relative
  arguments, as CI does, and test that once. *From:* #30, kernel #12.
- **L-41. A gate that wraps another tool must show why that tool failed.**
  Filtering a sub-tool's output to its `not ok` lines hid a `cd` error, so
  CI failed with no reason. *Check:* when a CI failure has no `not ok` line,
  reproduce it the way the workflow runs it before blaming the PR (L-30).
  *From:* #30, kernel #12.
- **L-42. A package test that fails on a PR that doesn't touch the package
  is reproduced on main first.** #24's red CI was a race in
  `omamobile-shell`'s portal test (a log read then truncated, losing a line
  written between), and a retry block that exited silently. *From:* #24,
  round 3.

- **L-59. "No checks reported" can mean CI is waiting for approval.** A
  first-time contributor's runs stop at `action_required` until the
  maintainer approves them (`gh run list --status action_required`). Approve,
  then judge (extends L-38). *From:* kernel #18-#31.
- **L-60. Mesa changes are checked through the generated packers.** Mesa has
  no package test, so CI's green says nothing about it: run `gen_pack.py` on
  each touched `vN.xml` before and after, and grep every caller of a changed
  builder. *From:* #32.

## Reviews and merging

- **L-31. Our review requests must agree with CONTRIBUTING.** Round one of
  kernel #11 asked for a squash that §6.2's "disabled, then a separate
  enabling commit" rule contradicted. Since 2026-10-22 §6.2 allows a board
  node already proven on a same-SoC phone to be added enabled in one
  commit; otherwise, when a request and a rule disagree, fix one of them.
  *From:* kernel #11.
- **L-34. Before a second round, check the head moved.** Compare the PR's
  head with the `commit_id` of our last review and read the timeline:
  comments and cross-references also change the "updated" time. Answers
  given only in comments must still land in the files. *From:* #24,
  round 2.
- **L-39. A rebase or squash merge gives new commit ids, so a stacked PR
  must be rebased before it merges.** After #11 was rebase-merged, #12 still
  carried #11's old commit underneath and couldn't merge as it stood. *Check:*
  when merging a PR another one is stacked on, ask the second one's author to
  rebase onto the branch, and merge in order. *From:* kernel #11 and #12.

- **L-43. Parallel reviewers use unique ref names.** They share the kernel
  clone, and one deleted another's `review/pr12` mid-review. *Check:* name
  refs `review/prN-<round>` and pass commit ids to the gates. *From:* kernel
  #12, round 3.
- **L-44. A staged descriptor's refusal depends on the tooling PRs in
  flight.** Tegu added `SOC_COMPATIBLE` while #27 was about to make either
  key acceptable, so merging both would have made tegu installable without
  the AVB footers its bootloader needs. *Check:* test a staged descriptor
  against the heads of open PRs that touch `bin/omamobile` or
  `tools/install-phone`. *From:* #24 with #27.

## Claims and evidence

- **L-28. "Works" needs merged notes and the phone it ran on.** A matrix row
  claiming works/testing from a private kernel, or from an install of a
  different branch, should say WIP or testing and link the notes.
  *From:* #24, #25.
- **L-29. PR bodies written with an AI over-claim.** "checkpatch clean",
  "dtbs_check clean", "tested" were each untrue at least once this week.
  Re-run the claim; never quote it. *From:* kernel #10-#12, #27.

- **L-45. A rebased companion's evidence still counts if the tested commit
  and the new head don't differ.** *Check:* `git diff <tested> <head> --
  <files the test exercised>`; empty means the test stands, otherwise ask
  for a re-test. *From:* #29, round 2 (994dd90 against d773f62: identical).
- **L-46. A phone's settings reflect that phone's image, not the one we
  build.** A contributor's `busctl` value (`HandlePowerKey=suspend`) came from
  a local drop-in, while our image's `omarchy-settings` sets `ignore`.
  *Check:* compare reported values with what `rootfs/packages.base`
  installs before accepting or correcting a note about a default (with
  L-32). *From:* #29, round 2.

- **L-61. "Private kernel" evidence isn't evidence.** Ask for the public
  source (Google's GPL tree, the stock DT lines, upstream) behind each value.
  *From:* kernel #28-#31.
- **L-62. Check a claimed upstream backport against that commit's own
  `.patch`,** and list the file's later commits to find where any extra
  lines came from; authorship and trailers must survive. *From:* #32
  (0005 was two upstream commits with no `From:` line).

## Corrections (where a review was wrong)

- **C-1 (2026-10-22). We blamed the 30 s unused-regulator cleanup for the
  felix cover touch's dead rails (issue #3).** We have no S2MPG12 regulator
  driver at all (cheetah's `s2mpg12-pmic` node is RTC and interrupt masks
  only, and disabled), so nothing in Linux can turn those LDOs off: the rails
  are off as ABL left them. *Lesson:* before blaming a kernel mechanism,
  check the driver for it is actually bound on that device
  (`/sys/kernel/debug/regulator/regulator_summary`, the DT node's status).
- **C-2 (2026-10-23). C-1 said cheetah's `s2mpg12-pmic` node is disabled;
  that is true of the DTS, but the `suspend-pmic-test` overlay in cheetah's
  `DTB_OVERLAYS` enables it.** C-1's conclusion (no regulator driver, so no
  Linux cleanup of those LDOs) still stood then. *Lesson:* L-49. *From:*
  kernel #27.
