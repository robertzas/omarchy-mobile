# Pixel 7 Pro (cheetah) bring-up notes

Findings from real hardware, newest first. `BRINGUP-M1.md` is the research map written before first boot.

## 2026-10-11: hardware buttons (gpio-keys)

- **All three buttons are plain GPIOs**, so one `gpio-keys` node covers them (kernel branch `omandroid-buttons`): Volume Down `gpa10-1` (pull-up), Volume Up `gpa8-5` (FAR_ALIVE, no pull), Power `gpa10-0` (pull-up). All active low, all `wakeup-source`. They appear as `/dev/input/by-path/platform-gpio-keys-event` with KEY_VOLUMEDOWN/UP/POWER.
- **Power is `PMIC_PWRON_OD_L`** (Google's `gs201-common.dtsi`): the S2MPG12 PWRONB line is also routed to the SoC. Stock configures the pin but reports the key through `s2mpg12-keys` over ACPM instead. Upstream gs101 Pixels use the GPIO (`gpa10-1` there), so we do the same. Reading the line doesn't affect the PMIC's own long-press reset.
- **Needed the ALIVE pin controller** (`0x180d0000`, banks gpa0-5, 9, 10; alias `pinctrl0`). The driver data was already there; the DT node wasn't. Wake-up interrupts are direct, one GIC SPI per pin (gpa10 = SPI 42/43), from the stock DT.
- **Test:** `evtest --grab /dev/input/by-path/platform-gpio-keys-event`. `--grab` keeps logind and Hyprland from also acting on the key.
- **PMIC path (not needed for KEY_POWER, kept for regulators/RTC):** upstream has gs101 ACPM (`exynos-acpm*.c`, `google,gs101-acpm-ipc`) and S2MPG10/11 on top of it (`sec-acpm.c`). gs201 needs (1) a `google,gs201-acpm-ipc` match (mailbox `0x18210000`, SRAM `0x18500000`; check `initdata_base` in Google's ACPM driver), (2) S2MPG12/S2MPG13 register maps and IRQ tables in `sec-acpm.c`/`sec-irq.c`, from Google's GPL `soc/gs/drivers/mfd/s2mpg12-*.c` and `s2mpg13-*.c`, (3) regulator data. Google's `s2mpg12-key.c` only duplicates the GPIO key; upstream has no s2mpg10 key driver either.

## 2026-10-11: touchscreen (Synaptics S3908 on SPI)

- **Works with our own driver** (`drivers/input/touchscreen/synaptics_tcm.c`, kernel branch `omandroid-touch`): TouchComm v1, message CRC off, firmware `S3908GA1B0-15.0` build 4104960, 1440x3120, 10 objects. Hyprland lists it under Touch; the panel is portrait with transform 0, so no axis swap or flip.
- **Wiring:** PERIC1 USI0 SPI at 0x10d10000 (GIC SPI 690), mode 0, 10 MHz; CS on gpp20-3 as a GPIO; ATTN gpa7-0 (FAR_ALIVE, GIC SPI 52, level low); reset gpp23-2 (active low).
- **ABL holds the controller in reset** (gpp23-2 driven low) but leaves both supplies (S2MPG12 LDO25M 1.8 V, LDO26M 3.3 V) on. Releasing reset by hand with devmem made ATTN fall, which proved power before any driver existed.
- **gs201 EINT numbering skips EINT19**, so from EINT20 on the GIC SPI is the EINT number minus one (gpa7-0 = EINT53 = SPI 52; gs101 uses 53).
- **USI IPCLK gates need `CLK_SET_RATE_PARENT`.** Without it the SPI ran from the undivided 400 MHz source and never shifted a byte (TX FIFO stuck, `I/O Error ... res-(-5)`).
- **The controller answers 0xff when not ready**; reads are retried until the 0xa5 marker appears, as Synaptics' driver does.

## 2026-10-11: A/B slot metadata lives in `devinfo`

- **ABL keeps the slot state in the first 128 bytes of `devinfo`** (8 KiB, not slotted), not in `misc` and not in GPT attributes. Source: Google's boot HAL, `device/google/gs-common` `bootctrl/aidl/` (Apache-2.0, tag android-14.0.0_r75), the one that builds `android.hardware.boot-service.default-pixel`. It uses GPT attributes only if devinfo is invalid. `misc` holds only the bootloader message and, at 32 KiB, the virtual A/B merge status.
- **Layout:** magic `DEVI` (0x49564544), version u16 3 . u16 15, then 4 bytes per slot at 0x30 (a) and 0x34 (b): retry count, then flags bit0 unbootable, bit1 successful, bit2 active, bit3 fastboot-ok. No CRC. Every other header byte is ABL's own; bytes from 0x80 hold factory records (serials, IMEI).
- **The 11 October backup decodes exactly to `getvar all`:** a: active, successful, retry 2, fastboot-ok. b: successful, unbootable, retry 2.
- **`omandroid-bootctl`** (in the initramfs, not called by init yet) dumps it and can `mark-successful` / `set-active` behind `--i-understand`. On the backup, `set-active b` then `mark-successful b` changes only 0x31, 0x34 and 0x35. The HAL's `set-active` also writes the UFS `bBootLunEn` attribute, which the tool does not do.

## 2026-10-11: lost USB for an hour (our bug, not hardware)

- **Symptom:** USB enumerated, then bulk transfers stalled after a few seconds ("transmit queue timed out" on the host, then "not responding to setup address" on re-enumeration). Background jobs with `sleep` never finished.
- **Cause:** init ended with `exec setsid cttyhack sh ...`, and Alpine's busybox has no `cttyhack`. The exec failed, PID 1 exited, and the kernel panicked. The panic never showed, because ABL appends `console=null`.
- **Fix:** PID 1 never exits: it keeps the screen shell in a `while true` loop, using `setsid -c` for the controlling tty. The DTB bootargs carry `panic=10`, so any future panic reboots instead of freezing. After a few failed boots ABL falls back to stock slot A, where `adb reboot bootloader` reaches fastboot.
- **Ruled out along the way:** the gs201 clock driver, the host port, PMU state, and the HSI0 S2MPU firewall. On a non-pKVM boot, `S2MPU_HSI0` (0x11070000) reads `CTRL0` = 0, i.e. already disabled. Note for later: shipping needs real S2MPU programming for DMA protection.
- **`reboot-to bootloader` is unreliable.** syscon-reboot-mode binds to the PMU, but ABL usually ignores the reason. The one success may have coincided with the buttons being held. Open.

## 2026-10-11: M1 first light

Mainline v7.3-rc6 boots from slot B, with all 8 CPUs, 11.5 GB of RAM, USB networking and SSH at `172.16.42.1`, and a readable console on the panel.

### Boot chain

- **ABL ignores our `vendor_boot` cmdline.** The kernel cmdline is the DTB `/chosen/bootargs` plus ABL's own additions (ending with `console=null ... bootconfig`). Put kernel arguments in the DTB.
- **ABL accepted our DTB** with `soc_id = <0x09855001 0x0>` (B0 silicon), and our empty dtbo keyed `0x30306` / `0x10000`. Unsigned images boot fine on an unlocked bootloader (orange state).
- **Slot B fallback works.** Our Linux never marks the slot successful, so after its retries ABL boots stock slot A. From slot A, `adb reboot bootloader` reaches fastboot without buttons.
- **The unlocked-warning screen is not fastboot.** Pausing it doesn't expose fastboot over USB. Real fastboot is reached by holding Volume Down through the restart, until the "Fastboot Mode / Start" screen appears.
- **After a forced reset out of our Linux,** fastboot sometimes doesn't enumerate on USB.
- **Reaching fastboot by hand, as it works on this phone:** hold Power about 30 s until fully off. Then hold Volume Down, add Power, and keep both held about 20 s until the "Fastboot Mode" screen with "Start" appears. Letting go early lands on the unlocked-warning screen, which carries on booting slot B.
- **From a working Linux,** `reboot-to bootloader` (in the initramfs) reaches fastboot in about 2 s. It uses `LINUX_REBOOT_CMD_RESTART2` so syscon-reboot-mode stores 0xfc in SYSIP_DAT0 through the PMU regmap. Plain busybox `reboot` hangs.

### Display

- **ABL's framebuffer is at `0xfac00000`,** 1440x3120, stride 5760, a8r8g8b8. DPP0's RDMA base address register (`0x1c0b0000 + 0x40`) reads `0xfac00000`. simple-framebuffer at that address is correct.
- **The panel (Samsung S6E3HC4) runs in MIPI DSI command mode.** `DECON0 GLOBAL_CON` (`0x1c240020`) = `0x133`, which is command mode and running. ABL leaves `TRIG_CON` (`0x1c240030`) = `0x3070`: hardware trigger disabled, with `HW_TRIG_MASK_DECON` set. So the panel never receives a new frame after the logo.
- **Writing `TRIG_CON = 0x3061`** (unmask the trigger, enable hardware TE trigger) makes DECON send a frame on every panel TE pulse, so the framebuffer refreshes continuously. The init script does this until we have a real DECON/DSI driver. Register layout: Google GPL `google-modules/display/samsung/cal_9845/regs-decon.h` (gs201 uses cal_9855, which reuses it).
- **Console font:** `fbcon=font:TER16x32` with `CONFIG_FONT_TER16x32`. 8x16 is unreadable on this panel.

### Watchdogs

- **ABL leaves both cluster watchdogs running.** `CL0` at `0x10060000`, `CL1` at `0x10070000`, about 60 s, and the phone resets at roughly 60 s of uptime.
- **Fixed** by the upstream `s3c2410_wdt` driver with a `google,gs201-wdt` compatible (gs101 data). With `tmr_atboot=0` it stops both watchdogs at probe ("watchdog inactive, reset disabled").

### PMU and reboot

- **PMU registers are secure-only.** Google's drivers write them through `set_priv_reg` (an SMC). Plain `/dev/mem` writes (e.g. reboot reason at `0x18060810`) are silently ignored. Use the kernel's exynos-pmu regmap, which goes through SMC for gs101 data.
- **`reboot -f` hangs** (the phone stops responding but stays powered). On gs201, Google's `pixel-gs201-reboot.c` restart handler does nothing itself, so the reset is expected to come from PSCI `SYSTEM_RESET`. Root cause still open.

### kexec

- **kexec with `--reuse-cmdline` and the live DT works:** the new kernel and initramfs boot and draw to the screen.
- **USB does not come back after kexec.** The host sees the device but enumeration fails ("not responding to setup address", -71). The PHY/link is likely left powered down by the old kernel's shutdown, and can't be re-initialised with placeholder clocks. Revisit after `clk-gs201` and a proper USB PHY reset.

### Host setup

- **NetworkManager profile `omandroid-phone`** gives `172.16.42.2/24` on any `enp0s20f0u*` gadget link. Without it, NM tears the link down after DHCP fails.
- **`tools/phone-ssh`** runs commands on the phone. dropbear has no scp/sftp server, so stream files with `ssh 'cat > file' < file`.

## Host changes to undo later

Made on the development laptop to give the phone internet over USB. Revert when no longer needed:

- **ufw forwarding for the phone's USB link** (added 2026-10-11): `sudo ufw route allow in on enp0s20f0u2`. Undo with `sudo ufw route delete allow in on enp0s20f0u2`.
- **NetworkManager profile `omandroid-phone`** set to `ipv4.method shared` (NAT for the phone). Undo with `nmcli con modify omandroid-phone ipv4.method manual`, or remove the profile: `nmcli con delete omandroid-phone`.

## Phone UX to-dos

- **First-run notifications are desktop-oriented.** "Learn Keybindings (Super + K…)" makes no sense on a touch phone, and "Setup Wi-Fi" needs to open the phone's Wi-Fi settings. Find how Omarchy's first run triggers them (`install/user/first-run`) and how omarchy-mac adapts them for its platform, then do the same in the Omandroid package. No local hacks.
- **Make `omarchy update` the update path on the phone.** Omarchy installs a pacman hook that blocks direct `pacman -Syu` and points to `omarchy update` (snapshots, keyrings, migrations, restarts). On the phone this needs `sudo` for the user and decisions about snapshots (no snapper/btrfs here, since the root is ext4). The `[omarchy]` repo must come **before** `[core]` in pacman.conf on aarch64, so Omarchy's own builds (quickshell 0.3.2-4, hyprland 0.56.2-5) win over Arch Linux ARM's. With ALARM's quickshell 0.3.2-1 on Qt 6.12, the shell's theme colours didn't resolve.
- **Agent choice in onboarding.** The launcher's "Ask Claude" is hardcoded. Use Omarchy's standard default-agent mechanism (`omarchy-default-agent` and its settings, which Omalauncher also follows) for the launcher's agent, and let the user pick their agent during first-run onboarding, as Omarchy does. Claude stays Derek's choice, not the default.
- **Temporary patch on the phone's Omarchy shell (2026-10-11).** Qt 6.12 (already in Arch Linux ARM) adds `QtQuick/Color`, which shadows Omarchy's `Commons.Color`, so every palette colour was undefined. Upstream fixed this in omacom/omarchy b83d3df084 (#14553, after v4.0.4) by importing `qs.Commons as Commons` and qualifying `Commons.Color`. We applied the same transformation to the installed v4.0.4 shell (54 files; original backed up at `/root/omarchy-shell-4.0.4-orig.tar.gz` on the phone). The next Omarchy release replaces those files with upstream's fix. Our phone plugins now follow the same rule.
- **Done (2026-10-11): first-run keybindings toast and agent choice.**
  - The launcher reads Omarchy's default agent (`~/.config/omarchy/defaults/agent`, set by `omarchy-default-agent`). It prompts through `omarchy-agent-prompt`, or opens Omarchy's picker (`omarchy menu summon setup.default.agent`) when none is chosen.
  - `omandroid-setup-user` marks `welcome-keybindings-not-applicable`, which the upstream change honours: submitted as omacom/omarchy#15075 (https://github.com/omacom/omarchy/pull/15075). The patch in `patches/omarchy/0001-*` is applied on the phone as a bridge until it ships.
  - The setup script will become Omandroid's `setup-user` entrypoint in Omarchy's lifecycle-dispatch contract once a release includes it.
- **Done: UTF-8 locale and timezone** via `omandroid-setup-system` (en_US.UTF-8; timezone from the host; NTP synced).
- **USB doesn't reconnect after unplugging (2026-10-11).** The USB PHY forces VBUS valid at boot (no Type-C / MAX77759 TCPC driver yet), so the gadget never sees detach or attach. After an unplug, the link stays down until the next boot. Fixed properly by the MAX77759 TCPC + dwc3 role-switch work (plan: USB-C row).
- **Done (2026-10-11): apps open off-screen.** Omarchy floats its terminal, btop and dialogs at desktop sizes (875 x 600) through a `floating-window` tag, so on a 480 px wide screen they landed mostly off-screen (seen when installing an agent). `packages/omandroid-shell/hypr/phone.lua` drops the tag and maximizes every window, Android-style; it's loaded from the user's `looknfeel.lua`.
- **Done (2026-10-11): on-screen keyboard.** squeekboard, with Omarchy's fcitx5 masked for the user and Wayland text-input selected (`20-omandroid-osk.conf`). The drawer uses on-demand focus: Hyprland routes no touch to other layers while one holds exclusive keyboard focus. Size follows the panel's real millimetres, now in the device tree.
- **Done (2026-10-11): power button menu.** Omarchy already binds XF86PowerOff to the system menu, so our extra binding toggled it twice; removed. Omarchy's menu drew its card at the top for one frame while its window still had a placeholder size (`patches/omarchy/0002-*`, applied on the phone, to send upstream). Suspend is hidden with Omarchy's `suspend-off` toggle until the kernel can suspend; later, short press = screen off + suspend, long press = menu, like Android.
- **Screensaver isn't phone-shaped.** It runs in a terminal, so focusing it pops up the on-screen keyboard. Its art (`~/.config/omarchy/branding/screensaver.txt`) is one ~80-column line of lettering, too wide for portrait. On exit it sets `cursor:invisible false`, which brings back the pointer we hide. Needs a portrait art file, no keyboard, and the phone's cursor setting kept.
- **Lock screen and PIN.** Wanted: Omarchy's lock after boot (autologin, then lock) and after the screensaver, unlocked with a PIN/password or fingerprint. Omarchy's lock (shell `lock` plugin, PAM) hides every other surface while locked, including the on-screen keyboard, so the phone needs a PIN pad inside the lock view. The PIN is the user's password, so `sudo` and the lock agree.
- **Fingerprint.** Omarchy's lock already supports fprintd. The Pixel 7 Pro sensor is under the display and normally driven through Google's secure world; feasibility research in `FINGERPRINT-RESEARCH.md`.
- **Omarchy's per-user install never fully ran on the phone (2026-10-11).** Example: no default keyring, so the first app to use the keyring (Chromium, during an agent login) popped up a desktop-sized "create a keyring password" prompt. Fixed by hand with Omarchy's own `install/user/default-keyring.sh`. The phone image must run Omarchy's user install (`install/user/all.sh`), not a hand-picked subset; audit the other steps (theme, chromium, git, xcompose, mise) too.
- **Chromium's first-run dialogs don't fit.** Its "Additional Terms of Service" page (blank text in open-source builds) put Accept off-screen and blocked an OAuth login. `omandroid-setup-user` adds `--no-first-run` to `~/.config/chromium-flags.conf`.
- **System dialogs aren't phone-shaped.** gcr-prompter (keyring), polkit and portal dialogs are GTK windows sized for desktops. Now that every window is maximized they fit the width, but they'll want a phone-friendly look.
- **Stale `/usr/local/bin/omandroid-setup-user` (fixed 2026-10-11).** An early hand-copied version shadowed the packaged `/usr/bin` one on PATH, so newly added setup steps were silently skipped when the script ran by name. Removed. Since then both packages are installed with pacman (below).
- **Shell plugin development gotchas (2026-10-11).**
  - Omarchy's live plugin reload ("Local plugin changed, reloading") can keep running the old code. After changing a plugin's QML, restart the shell (`omarchy-restart-shell`) before testing.
  - A Qt pointer handler (DragHandler, TapHandler) declared directly on a Quickshell window gets no events. Put it on an Item inside the window.
  - A plugin may only summon panels it owns (`_summon` checks `pluginOwnsTarget`). To open another plugin, run `omarchy-shell shell summon <id>`, as Omarchy's background does.
  - To debug touch, `console.log` is hard to read back (binary `log.qslog`, needs `qs log`). Appending to a file through `Quickshell.execDetached` gave a clear trace.
- **Packaged (2026-10-11).** `omandroid-shell` and `omandroid-device-cheetah` are built natively on the phone with makepkg and installed with pacman. Hand-copied files in `/etc`, `/usr/local/bin` and `/usr/share/omandroid/phone` are gone; the user's config points at `/usr/share/omandroid/shell`. The MAX77759 blacklist moved from the rootfs overlay into the device package (`/usr/lib/modprobe.d`). Still to do: a package repository so `omarchy update` (pacman -Syu) picks up new versions, instead of `pacman -U`.
- **Omarchy per-user install audit (2026-10-11).** Against `install/user/all.sh`: theme, Chromium extensions and the keyring are in place; `mise-work.sh` (`~/Work`, node) and `xcompose.sh` were run by hand. Still open: git identity (`git.sh` needs the user's name and email) and `mise.sh` (Omarchy installs about 11 agent CLIs; only Claude is installed). The image build must run Omarchy's whole user install instead.
- **Package repository (2026-10-11).** `[omandroid]` is in the phone's pacman.conf, before `[omarchy]`, through `/etc/pacman.d/omandroid-mirrorlist` (from `omandroid-device-cheetah`). Packages and the database are signed with the Omandroid key (`keys/`, never committed; public half in `omandroid-keyring`). While the project is private the repository lives on the phone at `/var/lib/omandroid/repo`: `tools/repo-build` builds (on the phone), signs and indexes it, `tools/repo-push` copies it over, and `pacman -Syu` / `omarchy update` installs new versions. Bootstrap on a new phone: `pacman-key --add` and `--lsign-key` the key once, then install `omandroid-keyring`. Our Mesa is tracked from `[omandroid]`, so Arch's can't replace it (we must keep it current with Arch's Mesa). `omarchy update` needs sudo, which asks for the PIN, so it runs in a terminal like on a computer.
- **Reserved memory audit (2026-10-11).** Firmware writing into memory the kernel thinks is free corrupts data, so every stock `reserved-memory` node was checked against `/proc/iomem`. Five were plain System RAM in our kernel: `seclog` (0xc3000000, written by the secure world at runtime), the modem's `cp_rmem`/`cp_rmem_1` (0xea400000, 0xe8000000), AoC's `xhci_dma` (0x97000000) and `ect_binary` (0x90000000). All are now `no-map` in gs201.dtsi (kernel e7cb10fe5). The regions they named, 0xd8100000 and 0xdc210000, were already inside our `dss` reservation.
