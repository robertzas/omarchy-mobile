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
- **L-81. A request that cycles USB comes with its own way back.** The
  gadget is the phone's only link, so "unbind and rebind dwc3" ends the
  session that would rebind it. *Check:* any requested step that touches
  dwc3, the USB PHY or the gadget gives one detached job (`systemd-run
  --unit=…`), a dead-man reboot armed first, the configfs `UDC` re-attach, a
  fresh SSH login to confirm, and a stop condition (AGENTS.md section 1).
  *From:* kernel #33, round 2 (correcting round 1's bare request).
- **L-82. A runbook that avoids `bin/omamobile flash|push` needs a reason we
  can trace to the code.** #34's plan had the operator write slot B by hand,
  blaming `push` for a slot A fallback that comes from the initramfs USB-host
  safety net (no host in 45 s, crash, ABL falls back), whatever wrote the
  images. *Check:* grep plans for "do not use … flash/push" and hand-written
  `dd` or `fastboot flash` steps; if the tool really is wrong, fix the tool.
  *From:* #34, round 2.
- **L-88. A dead-man for a driver-cycle test must not go through the path
  under test.** `reboot-to` runs `device_shutdown`, which husky's DWC3 cycle
  hung. *Check:* the runbook arms an independent `echo b >
  /proc/sysrq-trigger` job (it skips driver shutdown), is run attended, and
  has a view that isn't USB (`printk` at 8 on the panel). Extends L-81.
  *From:* kernel #33, husky test 23. (See C-3: the cycle froze the SoC; it
  didn't hang shutdown.)
- **L-89. A guarded tool that contributors can't use gets bypassed.** With
  an SSH key that needs a tap per connection, `push` asked for about 25
  taps, so the felix contributor wrote slot B by hand. *Check:* when a
  runbook avoids a tool, find the friction and fix the tool, not only the
  rule. Extends L-82. *From:* #34, round 3.
- **L-90. A touch controller's firmware update can erase its calibration.**
  FTM5's `flash_burn` erases the on-chip flash that also holds CX (whether it
  survives depends on `keep_cx`). *Check:* a plan for such a part says that
  nothing writes or erases that flash without the maintainer's go, and asks
  its firmware questions read-only. *From:* #35.
- **L-91. A button finding names the exact combination, and the recovery
  docs follow it.** On husky Power alone does nothing; Power + Volume Up for
  15-30 s resets it, so CONTRIBUTING's "hold Power" fails there. *Check:* a
  new device's recovery keys reach CONTRIBUTING §3.4 and AGENTS.md. *From:*
  #23.
- **L-108. A touch controller can rewrite its own calibration without a
  firmware flash.** ST FTM5 built with `COMPUTE_INIT_METHOD` (felix's
  `fts.h`) runs a full panel init when the AFE versions differ or the MP flag
  isn't a factory value, saving new CX and the MP flag to the chip's flash.
  *Check:* a "no flash writes" rule for such a part also forbids panel init,
  CX tuning or save commands and MP flag writes; read the init-method
  `#define` in the vendor header. Extends L-90. *From:* #35, round 10.
- **L-109. Phone results posted ahead of the plan are recorded, and their
  code published, before the next boot.** #35's plan said "no phone step"
  while its comments reported reads from a kernel in no repository. *Check:*
  the boot goes into Results with `uname -r`, the tree and how slot B was
  written, and the code is pushed (branch or draft PR) with a runbook before
  it boots again. Extends L-34. *From:* #35, round 10.

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
- **L-67. A rail a PR touches on another phone may feed something on
  cheetah.** felix's cover-touch LDO25M/LDO26M are cheetah's main touch
  rails (and LDO27M/LDO28M its display rails). *Check:* look the rail up in
  NOTES and the plans, and name those peripherals in the read-only cheetah
  boot's Expect line. *From:* kernel #27, round 3.
- **L-87. A new installer refusal fed by bootloader variables is checked
  against the reference phone's real `getvar all` capture,** line endings
  included, before it can refuse cheetah. *From:* #27, round 3 (cheetah's ABL
  lists `partition-size` for all five `_b` partitions, so the refusal holds).
- **L-110. A shared-driver change confined to one static function is
  proven cheetah-neutral by comparing the object function by function.**
  Build the `.o` at base and head with the same config and diff the
  disassembly per function: for #42 only `exynos2200_usbdrd_phy_exit`
  changed. Extends L-8. *From:* kernel #42.
- **L-111. When a shared driver moves constants into per-SoC match data,
  prove "unchanged on cheetah" with a table and a boot, not an object diff.**
  Loads through `dc->soc` change the object anyway. *Check:* each new field's
  gs201 value next to the constant it replaced, each new branch's gs201
  condition, then one boot with before/after reads of the driver's own
  counters. *From:* kernel #46.
- **L-112. A core change that makes a reserved value valid updates the
  binding that reserved it, and names the boards that change.** reboot-mode
  has skipped a zero magic since 2016 and its binding says "non-zero".
  *Check:* `git log -S` on the binding for the rule's origin, `git grep` for
  the value across all DTs (`da850-lego-ev3`'s zero `mode-normal`, written `<0x00000000>`), and both
  in the commit message. *From:* kernel #45.

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
- **L-63. logind ranks drop-ins by file name, not by directory.** Every
  `logind.conf.d/*.conf` in `/usr/lib`, `/run` and `/etc` is sorted by name
  and the last one wins; `/etc` only replaces a file of the same name. So a
  local `/etc` file "outranks" a package's only if its name sorts later.
  *Check:* `systemd-analyze cat-config systemd/logind.conf`, or compare the
  names. *From:* #33.

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
- **L-68. Narrowing a regulator to min = max writes nothing if the rail is
  already there.** `of_regulator` sets `apply_uV` for any range, but the
  core only moves a rail that is out of range, so a test made with the wider
  range still stands. *Check:* the measured voltage is an exact selector
  (min + n × step, n < n_voltages). *From:* kernel #27, round 3.
- **L-72. A chip id the vendor driver checks belongs in the compatible's
  match data, not in a DT property.** Google keeps `st,dchip_id` because one
  `st,fts` compatible serves two parts (`36 40` SALIXP, `36 48` ALIX).
  *Check:* grep the vendor header for every value the property takes; name
  the part (L-21). *From:* kernel #32.
- **L-74. A Tensor PMU binding without `syscon` is a safety property.**
  With `syscon`, a consumer that probes before the PMU driver gets a plain
  MMIO regmap, where PMU writes are silently ignored (AGENTS.md section 1);
  without it, the lookup defers until the SMC-backed regmap exists. *Check:*
  new Tensor PMU bindings and board nodes leave `syscon` out, even though
  stock DTs have it. *From:* kernel #31, round 2 (for #22).
- **L-75. Map every property of a cited vendor block to its upstream
  equivalent.** Stock tegu's touch `controller-data` also has
  `cs-clock-delay = <2>`, a 2 µs CS-to-clock wait, which upstream spells
  `spi-cs-setup-delay-ns`. *Check:* read the whole block, not only the
  property the PR cites, and say why each one is or isn't needed. *From:*
  kernel #21, round 2.
- **L-77. A vendor CAL's version switch is narrower than the function it
  sits in.** Google's eUSB2 init gates only the charge-pump bias clear on
  the revision; the rest runs for every version, so "0x701's sequence"
  overstated it. *Check:* list which writes are actually inside the version
  test before accepting a per-revision claim. *From:* kernel #33.
- **L-78. Balancing a shared PHY child's init count turns a once-per-boot
  init into one that runs every cycle.** *Check:* list every board that
  binds the wrapper, open DT PRs included, and ask for one boot with an
  unbind/bind on one of them (L-51). *From:* kernel #33 (Pixel 8 Pro).
- **L-79. Check linux-next for the same function before accepting a fix to
  a shared driver.** It showed #33's coming conflict, and an upstream change
  to cheetah's PIPE3 path that our next base move will bring (an L-51
  event). *From:* kernel #33.
- **L-83. A `Fixes:` id that CI calls `UNKNOWN_COMMIT_ID` may still be
  right.** CI's clone holds only our squashed base; a clone with the upstream
  remote resolves it. *Check:* `git log -1 <id>` there (or git.kernel.org),
  and confirm it introduced the code being fixed (extends L-30). *From:*
  kernel #33, round 2.
- **L-84. For a rebased series, compare the preimages as well as the
  results.** Identical blobs at both heads *and* both bases mean earlier
  object comparisons (L-8) still hold without a rebuild; matching results on
  a moved base mean they must be redone (extends L-69). *From:* kernel #33,
  round 2.
- **L-92. On Exynos CMUs the gate enable bit (CG_VAL, bit 21) means "on"
  only in manual mode.** MANUAL is bit 20, auto-gating bit 28, and the CMU's
  controller option has a global auto bit. *Check:* a read-only gate follows
  the mode, as Google's `ra_get_gate()` does, or the PR shows the handoff
  values; a vendor `HWACG_VCLK`/`_QCH` clock is a hint it's automatic.
  *From:* kernel #34 (a wrong read would leave the watchdogs unowned).
- **L-93. The unused-regulator cleanup acts only on regulators the DT
  describes without `regulator-always-on`.** Undescribed outputs are never
  switched off; a described one with no consumer is, about 30 s in.
  *Check:* "keeps it out of the cleanup" claims against `of_regulator.c` and
  `regulator_late_cleanup()`; inherited rails a board describes carry
  always-on until a consumer owns them. Extends C-1. *From:* kernel #35.
- **L-94. Find a vendor rail's consumer in the board dtsi's `&node {
  …-supply }` overrides, not from its schematic name.** G4's `L8M_USB` rails
  belong to Google's HSI0 power-domain helper, not the PHY. *From:* kernel
  #35.
- **L-95. A regulator node without voltage limits can't change state.** So
  "no other rail changed" on a new PMIC regulator driver comes down to which
  DT nodes have constraints. *From:* kernel #32, round 5.
- **L-96. A binding describes the hardware, not Linux's power policy.** No
  `power-domains: false` for a block stock gives a domain; match the sibling
  SoC's rule and put "no domain because firmware leaves it on" as a comment
  on the board node. *From:* kernel #40.
- **L-97. dtschema's core schema rejects a string property named
  `description`.** *Check:* when a binding types a vendor node, validate the
  vendor's exact node against the base's schemas and the head's, and ask
  whether the firmware needs what the schema makes the board drop. *From:*
  kernel #37, kernel #13.
- **L-98. A binding that requires a clock is usable only once the clock
  provider exports it.** *Check:* grep the SoC's clock header and the open
  clock PRs; name the missing provider as the next step. *From:* kernel #39.
- **L-99. Read the vendor driver's read path, not only its register map.**
  Google reports a fixed 22 °C on MAX77779 gauge firmware below 1.15, so the
  Temp register isn't trusted there. *From:* kernel #38.
- **L-100. Check a per-board scale value in three public places:** the board
  node or the vendor default, the battery model's name, and a design value
  it implies (`nDesignCap` × LSB = the rated mAh). *From:* kernel #38 (the
  2 mΩ shunt).
- **L-101. A Kconfig `default` tied to another symbol doesn't follow it
  under fragment merging,** because defconfig has already written "is not
  set". *Check:* the merged `.config`, made the way `bin/omamobile kernel`
  makes it. *From:* #23 (`DETECT_HUNG_TASK`).
- **L-113. Before accepting "Google's driver for <SoC> does X", find the
  driver that SoC's defconfig builds.** soc/gs has two USB PHY drivers
  matching `samsung,exynos-usbdrd-phy`; #42 cited `phy-exynos-usb3p1.c`, but
  zuma builds `CONFIG_PHY_EXYNOS_USBDRD_EUSB`, and the cited function only
  acts on USBCON v3.0 (zuma is 0x600). *Check:* the defconfig and module
  list, the module's files in `Kbuild`, then any version test in the cited
  function against the stock DT. Extends L-56 and L-77. *From:* kernel #42.
- **L-114. Reserve a stock address only if Google's dtsi gives the region
  a `reg`.** A `size` + `alloc-ranges` pool (`tui`, `mfc_fw`, `famodel`) has
  an address only because stock allocated it there on that boot. *From:*
  kernel #43.
- **L-115. When a PHY driver picks its settings from `clk_get_rate()`, the
  board's nominal fixed clocks become PHY configuration.**
  `phy-snps-eusb2.c` takes FSEL and the PLL divider from an exact-rate table,
  so a CAL nominal rate or a mux reading the other way decides whether the
  PHY initialises. *Check:* trace the clock to its root and ask for the mux
  selections and the `clk_summary` rate at handoff. Extends L-58. *From:*
  kernel #40.
- **L-116. A fix in a PHY's exit path also covers resume.** dwc3 calls
  `phy_exit()` on device-mode suspend and touches the core in
  `dwc3_phy_setup()` before `phy_init()`. *Check:* list the consumer's
  `phy_exit` callers and the first register access after each, and name the
  untested paths in the review. *From:* #23 tests 24-29, kernel #42.
- **L-117. A comment that says "all variants" is checked against every
  variant's vendor driver.** tegu ships three panels (`panel-gs-tg4a/b/c`);
  TG4A's porches and size differ. *Check:* the device's `BUILD.bazel` for the
  list, then each file. Extends L-56. *From:* kernel #46.
- **L-118. On Tensor, SYSIP_DAT0 0x00 means "normal" in Google's reboot
  driver** (`pixel-gs201-reboot.c`, `pixel-zuma-reboot.c` in
  kernel/google-modules/power/reset). Check reboot-mode claims against that
  file, not a contributor's harness. *From:* kernel #45.
- **L-119. A blank line before `Signed-off-by:` takes `Link:` out of the
  trailer block.** checkpatch doesn't flag it. *Check:* `git log -1
  --format=%B <c> | git interpret-trailers --parse` lists every intended
  trailer. *From:* kernel #35, round 10.

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
- **L-64. A package file `cmp`-tested against cheetah's copy can carry
  checks the original lacks.** felix's test caught `HandlePowerKey=poweroff`;
  cheetah's own test passed with it. *Check:* mutation-test the original too,
  and give both packages the content checks. *From:* #33.
- **L-69. Compare a renumbered or reworded patch series by the source it
  produces.** Apply the old and the new series to two fresh copies of the
  release and `diff -r` the trees: empty means the earlier review (and any
  test of the earlier build) still applies (L-45 for package patches).
  *From:* #32, round 2.
- **L-70. A gate's "N device trees" can leave out a new overlay.** Neither
  `kernel-pr-check` nor CI built `.dtso` files until kernel #32. *Check:*
  compile every touched overlay with `-@`, apply it to its base with
  `fdtoverlay`, and `dt-validate` the result (`kernel-pr-check --build` now
  does this). *From:* kernel #32.
- **L-73. Gate a PR on its merge, not only on its head, when another PR
  landed in the same files after it branched.** CI checks out the PR head,
  so #20 was never built with #27's S2MPG12 changes. *Check:* `git
  merge-tree --write-tree`, `git commit-tree`, then `kernel-pr-check
  --build` on that commit; after a batch of merges, gate the whole new
  range once. *From:* kernel #20, round 2.
- **L-80. checkpatch reported every compatible a PR documents itself as
  undocumented, and showed warnings only as a count.** It read bindings
  from the clone's checked-out tree, not the commit under test. Fixed:
  `kernel-pr-check` now gives checkpatch each commit's own bindings and
  MAINTAINERS, and prints the warnings (extends L-30). *From:* kernel #21,
  #28, #33, rounds 1 and 2.
- **L-102. Feed a gate a known failure.** The device-tree comparison kept
  only lines saying "warning" or "error"; dt-validate's say neither, so
  every "dtbs_check, no new warnings" (ours and CI's) was blind until
  476901b. A reused `--build` OUT also kept an earlier tree's processed
  schema. Extends L-30. *From:* kernel #13 (found by its author).
- **L-103. A passing gate log can hide a skipped check.** The project
  container has no dtschema, so its runs print "# no dt-validate … skipped"
  and still pass. *Check:* grep the log for `SKIP` and `skipped` before
  quoting "dtbs_check passes"; run it where dtschema is installed. *From:*
  round 9.
- **L-120. For a new board, `kernel-pr-check` counts every message the
  board inherits as new.** The base has no such DTB, so gs201.dtsi's four
  undocumented compatibles failed lynx. *Check:* `dt-validate -m` a sibling
  board on the same dtsi at the base and subtract its messages before calling
  one new (the tool could do this itself). Extends L-30. *From:* kernel #43.
- **L-121. When a test merge conflicts, check which tree it used before
  asking anyone to rebase.** Our gs201 bindings branch "conflicted" with
  zuma only on the unrelated local integration history; against
  `github/omamobile` and #13 it merged cleanly. *Check:* `git merge-base` and
  `git merge-tree` against the published branch and each open PR's head.
  Extends L-104. *From:* kernel #13, round 10.
- **L-122. "Same tree as before" is checked with the tree object.** `git
  rev-parse A^{tree} B^{tree}` on the same base carries the earlier boot and
  builds over to a reworded commit. Extends L-45 and L-84. *From:* kernel
  #41, #35, round 10.

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
  refs `review/prN-<round>` (now `review/prN-rR-<topic>`, L-127) and pass commit ids to the gates. *From:* kernel
  #12, round 3.
- **L-44. A staged descriptor's refusal depends on the tooling PRs in
  flight.** Tegu added `SOC_COMPATIBLE` while #27 was about to make either
  key acceptable, so merging both would have made tegu installable without
  the AVB footers its bootloader needs. *Check:* test a staged descriptor
  against the heads of open PRs that touch `bin/omamobile` or
  `tools/install-phone`. *From:* #24 with #27.
- **L-71. Our requests say which repository each piece goes in.** "A kernel
  PR … with an overlay that enables it" put a bring-up overlay in the kernel,
  against CONTRIBUTING §6.1 (extends L-31). *From:* issue #3 and kernel #32.
- **L-104. Run `git merge-tree` across every pair of open PRs that touch the
  same files,** one contributor's parallel PRs included, and give the merge
  order in each review. Look for duplicate mechanisms too (#34's
  `ro_gate_clks` beside #40's private read-only gates). Extends L-39 and
  L-73. *From:* kernel #34 with #40, #37 with #39.
- **L-105. When a contributor writes a private driver after we asked for
  the common helper, find what pushed them off it** (here a PMU check that
  can't defer inside the `__init` probe) and answer that, not only the
  request again. *From:* kernel #40.
- **L-123. A fix-up commit on a rebase-merged PR is folded in.** Kernel
  PRs land commit by commit, so #34's watchdog commit would have landed with
  the CG_VAL-only read (a bisect could stop there with the watchdogs
  unowned), and #38's driver commit claiming temperature. *Check:* `git
  range-diff` for a new commit that only changes lines an earlier commit of
  the same PR added; read the earlier messages against the new head.
  *From:* kernel #34, #35, #38, round 10.
- **L-124. Before asking again, check whether the contributor's report
  crossed our post.** The 23:11Z husky report answered round 9 before round 9
  was posted. *Check:* compare comment times with our post time. *From:*
  kernel #33, round 10.
- **L-125. Check a whitespace nit by column, not by counting tabs.**
  `expand` the hunk with its neighbours: `google,zumapro.h` gives every name
  of that length two tabs. *From:* kernel #34, round 10 (withdrawn nit).
- **L-126. A binding PR's SoC condition can reject another open board's
  DTB without a textual conflict.** #13's `soc_compatible: false` for
  non-zuma boards fails lynx (gs201 IPOP). *Check:* merge each open board PR
  with each open binding PR on the same schema and run `CHECK_DTBS=y`.
  Extends L-104. *From:* kernel #43 with #13 and #37.
- **L-127. Parallel reviewers suffix refs with their topic, and delete only
  refs they created.** In round 10 several used `review/prN-r10`, and one
  deleted (then restored) refs another was using. *Check:*
  `review/prN-r<round>-<topic>`; clean up from a list recorded at fetch time.
  Extends L-43. *From:* round 10.

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
- **L-65. A `-dirty` release means the tested code is in no commit.** Look
  up its hash (`git log -1 <sha>`); if it predates the PR's code, the notes
  must say the evidence came from an unpublished tree and name the
  differences the PR admits. Hardware facts stand; claims about the PR's
  code path don't (extends L-45). *From:* #34 with kernel #32.
- **L-66. A matrix cell's word needs the qualifier its neighbours use and a
  link to the notes entry.** "Touch: WIP" for a chip-id read reads as touch
  input. *From:* #34.
- **L-76. Fetch each `Link:` anchor and read the line it points at.**
  *Check:* `curl -s '<url>?format=TEXT' | base64 -d | sed -n Np`. #29's was
  two lines off: cosmetic there, but a wrong commit or file wouldn't be.
  *From:* kernel #29, round 2.
- **L-85. "Nothing else changed" needs a "before" from the same boot.** A
  stop condition such as "no other rail changed" with only an after-read of
  `regulator_summary` can't fail. *Check:* every "X didn't change" condition
  has a snapshot step before the action and a diff after. *From:* #34,
  round 2.
- **L-86. When a revised driver keeps the protocol but changes the power
  sequence, the earlier boot covers the protocol only.** Compare the trees
  (L-69): a changed probe or remove order (rails, reset) needs its own boot,
  even when the read path is identical. *From:* kernel #32, round 4.
- **L-106. One PR's hardware evidence can land in another PR's commits.**
  Husky test 23, the result #33 asked for, was in #23's BRINGUP-M1. *Check:*
  read the companion PRs before saying "no evidence yet". Extends L-34.
  *From:* kernel #33 with #23.
- **L-107. A plan's claim about the DEVICES.md matrix is checked against
  the open PRs that change that row.** Extends L-28 and L-44. *From:* #35
  with #34.
- **L-128. Read the host's USB log before interpreting a phone's
  "re-enumeration".** The laptop's `journalctl -k` timestamps the gadget
  leaving and arriving, and survives a phone whose RAM log is lost: husky
  test 23's "re-enumerated after 22 s" was the boot itself. *From:* kernel
  #33, round 10.
- **L-129. A CRC "clear" covers only what that register checks.** FTM5's
  CRC register is the base check; config and CX errors come as events after a
  reset. *Check:* which check covers the calibration area, and whether it
  needs a reset, before a plan says a read answers "is it valid". *From:*
  #35, round 10.
- **L-130. Before putting a bootloader requirement down to the SoC,
  compare the reference phone's stock images.** Cheetah's stock vbmeta chains
  `boot` and `init_boot` with the same rollback index and ABL build as lynx,
  yet boots footerless images: lynx's AVB footers are its ABL's
  configuration. *Check:* `avbtool info_image` on the stock vbmeta in
  `~/android/reference` (read-only). *From:* #37.
- **L-131. Evidence cites the tested file's blob id, not a commit id.**
  `git rev-parse <commit>:<path>` survives the folds and rebases we ask for,
  and ties an out-of-tree module to its source. Extends L-45. *From:* kernel
  #38 with #39.
- **L-132. A device can appear twice on DEVICES.md (matrix row and Wanted
  list); an edit to one must agree with the other**, and the plain words that
  say the evidence isn't public must survive. *Check:* `grep -n <codename>
  docs/DEVICES.md`. Extends L-28, L-66 and L-107. *From:* #39.

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
- **C-3 (2026-10-24). L-88 said husky's DWC3 cycle hung `device_shutdown`
  under `reboot-to`; it didn't.** The laptop's log shows the gadget left at
  the unbind and never returned: the phone froze at the bind, so the fallback
  never ran (#23 tests 23-28). L-88's rule stands, but a freeze that stops
  every CPU defeats every software dead-man, sysrq included. *Lesson:* for a
  step that can freeze the SoC, only the buttons or a hardware watchdog left
  unfed bring it back; the runbook says so and is run attended. *From:*
  kernel #33, round 10.
- **C-4 (2026-10-24). Round 9 told #35's author that LDO11M-LDO13M are CPU
  cluster rails; LDO13M is the TPU rail** (`L13M_VDD_TPU_M`), and our wording
  went into a commit message. *Lesson:* a fact we hand a contributor for a
  commit needs the line-level source we'd ask of them. *From:* kernel #35,
  round 10.
