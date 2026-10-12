<!-- SPDX-License-Identifier: MIT -->
# AoC plan (cheetah / gs201): audio and sensor DSP bring-up

Status (2026-10-12): **C1, C2, C3 and C4a passed on the phone; C4b (start)
did not finish** (section 0.2): the GSA accepted `START` but reported state
4, and the firmware never wrote its control block. C4b-2 (diagnostics,
setup re-apply, release reset) ran cleanly: the mailbox `START` cannot
start the firmware (section 0.3). Next is C4t: the same start through
Trusty's `hwmgr.aoc`, as stock does. Kernel branch
`omandroid-aoc` in `~/android/mainline/wt-aoc` (out dir
`~/android/mainline/out-aoc`), on `omandroid` @ `7b0f8b5d1` plus the Trusty
commits of `omandroid-fingerprint`. Everything new is disabled by default.
The runbook is section 7; stage C2 is next.

The AoC (Always-on Compute) is Google's audio and sensor DSP. On gs201 every
on-device audio path ends there: the speaker amplifiers' TDM link, the three
PDM microphones, the earpiece (the top speaker amp) and Bluetooth SCO
(`AUDIO-PLAN.md` 0.1). It also runs the sensor hub: accelerometer (auto-rotate),
proximity, light, gyro, magnetometers, barometer. `AUDIO-PLAN.md` stage A6 is
this plan.

Path abbreviations (as in the other plans):

- `L/` = our kernel, branch `omandroid-aoc` (`~/android/mainline/wt-aoc`)
- `G/` = `~/android/omandroid/out-kernel/google/gs-6.1/private` (Google's GPL gs201 kernel, the one stock runs)
- `GA/` = `G/google-modules/aoc`, `GSA/` = `G/google-modules/soc/gs/drivers/soc/google/gsa`
- `GS/` = `G/google-modules/soc/gs`
- `R/` = `~/android/reference/cheetah-stock-cp2a-root` (stock live DT, dmesg)
- `V/` = `~/android/omandroid/vendor/google/cheetah/proprietary/vendor` (stock vendor blobs)

---

## Checkpoint 2026-10-12

**Done on the phone:** C1 (GSA mailbox), C2 (read-only probes), C3 (rails
read: all five off at hand-off), C4a (load), C4t (**AoC firmware online**:
started through Trusty `hwmgr.aoc`, 82 services, 0 faults). The mailbox
`START` (cmd 91) is not enough (section 0.3).

**Done offline, built, not run** (kernel `omandroid-aoc` @ `f716b607e`,
merges cleanly into int; `make modules dtbs` passes in `out-aoc`):

- `drivers/soc/google/aoc/`: Google's AoC core (aoc.c, aoc_v1.c,
  aoc_service_core.c, aoc_firmware.c, aoc_ipc_core.c), mailbox driver
  (mailbox-wc.c, `google,gs201-aoc-mbox`), `/dev/acd-*` front ends
  (aoc_char_dev.c, aoc_channel_dev.c), imported (`f141bb96a`) and ported
  (`f716b607e`): GSA load + Trusty start, S2MPU open, System MMU windows
  from the header, vendor stubs in aoc-compat.h, restart disabled.
  Config: `CONFIG_GS201_AOC_MBOX`, `CONFIG_GS201_AOC`, `CONFIG_GS201_AOC_CHAR`
  (=m, in `kernel/configs/omandroid.config`).
- DT: three mailbox nodes and the AoC node's 48 `mboxes` (disabled).
- Repo: `overlays/aoc-core-test.dtso` (Trusty, GSA, System MMU, mailboxes,
  AoC); `omandroid-device-cheetah`: `bin/omandroid-aoc-start` (Trusty → gsa
  → rails → sysmmu → mailboxes → core → channel/char devs → load `aoc.bin`
  → wait for services and `/dev/acd-com.google.usf`, hang marker),
  `omandroid-aoc.service` (not enabled), `modprobe.d/omandroid-aoc.conf`
  (blacklists); package version not bumped. `tools/usf.py` (USF client:
  sensor list, registry load, sampling; `--self-test` passes offline) and
  `USF-PROTOCOL.md`.

**Half-done / not started:**

- W=1 and checkpatch not run over the imported Google files (vendor style).
- `dt_binding_check` not run (no dtschema here) for `google,gs201-aoc-mbox`
  and the AoC binding changes.
- No iio-sensor-proxy-style D-Bus service yet (only `tools/usf.py`).
- Audio: `aoc_alsa` not ported; CS35L41 A2/A3 not run.

**Next steps, in order:**

1. **C5 (ready to run):** merge `omandroid-aoc` @ `f716b607e` into int,
   build, push with `aoc-core-test` (instead of `aoc-boot-test` and
   `fingerprint-trusty`) plus the usual overlays. Install the device
   package files by hand for now (or bump and publish it), and the
   firmware: `tools/aoc-stage --fw … c4a` copies `aoc.bin`, or
   `tools/phone-ssh 'mkdir -p /usr/lib/firmware/updates && cat > /usr/lib/firmware/updates/aoc.bin' < V/firmware/aoc.bin`.
   Then:
   ```sh
   tools/phone-ssh 'rm -f /var/lib/omandroid/aoc-bringup-started'
   tools/phone-ssh 'cat > /usr/bin/omandroid-aoc-start && chmod +x /usr/bin/omandroid-aoc-start' < packages/omandroid-device-cheetah/bin/omandroid-aoc-start
   tools/phone-ssh 'cat > /etc/modprobe.d/omandroid-aoc.conf' < packages/omandroid-device-cheetah/vendor/modprobe.d/omandroid-aoc.conf
   tools/phone-ssh 'omandroid-aoc-start; dmesg | grep -iE "aoc|gsa|wc-mbox|sysmmu" | tail -40; ls /dev/acd-* | head; head -3 /sys/bus/platform/devices/181d0000.aoc/services'
   ```
   Expect "omandroid-aoc: up: Services : 82", `/dev/acd-com.google.usf`
   and `.non_wake_up`, "firmware version … did become online with 82
   services" from the core. Stop: any abort, "blocked" line, "aoc init no
   respond", or the AoC watchdog. Rollback: reboot (the marker then keeps
   the AoC off; `omandroid-aoc-start --retry`).
2. **C6 first sensor** (after C5 passed in the same boot):
   ```sh
   # Google's registry, from the extracted vendor tree (never commit it)
   tar -C ~/android/omandroid/vendor/google/cheetah/proprietary/vendor/etc/sensors -c registry |
     tools/phone-ssh 'mkdir -p /usr/share/omandroid/sensors && tar -C /usr/share/omandroid/sensors -x'
   tools/phone-ssh 'for f in product stage major minor variant; do printf "%s=" $f; od -An -tx1 /sys/firmware/devicetree/base/chosen/plat/$f; done'
   # C6a: read-only (sensor list, registry state)
   tools/phone-ssh 'python3 - --check-registry --duration 0' < tools/usf.py
   # C6b: load the registry into the AoC's RAM, then 3 s of accelerometer at 50 Hz
   tools/phone-ssh 'python3 - --load-registry /usr/share/omandroid/sensors/registry /usr/share/omandroid/sensors/registry/append --duration 3' < tools/usf.py
   ```
   Expect: `plat` present (stock: product 3, stage 6, major 1, minor 0,
   variant 0); after the load, a sensor list with the LSM6DSV accelerometer
   and samples near (0, 9.8, 0) m/s² with the phone upright. Only the AoC's
   RAM changes; an AoC restart (reboot) undoes it. Stop: an empty list after
   the load (the rails: `omandroid-aoc-start` turns them on before the
   firmware, check `dmesg | grep rails`), USF errors.

   **C6b result (first run):** the seven `cheetah_*.reg` scripts and the two
   `append/` ones loaded, `"/" loaded=1` (CDT 0x36100), then "0 sensors".
   Loading every script is what the HAL does and is right: each script
   starts with CDT filter lines that the AoC checks against the CDT sent with
   it (`?+0x30000:0xFFFF0000`, minus `0x32xxx` proto and `0x33xxx` EVT, in
   `cheetah_dvt.reg`), so for 0x36100 only `cheetah_dvt.reg` applies and the
   other six are dropped, not merged. The list was read at once, though:
   the AoC creates its sensors asynchronously after `loaded=1` (Registry
   Loaded, Physical Devices Ready, Virtual Devices Ready, USF Ready), and
   Android's HAL waits 500 ms after loading before its first SensorList,
   then retries once (`SensorHal::Init`). `usf.py` now polls the list
   (`--wait`, default 5 s) until it stops growing, and `--list` skips the
   sampling.

   **C6b-2** (the same boot as C6b: the registry is already loaded, so do
   not load it again):
   ```sh
   tools/phone-ssh 'python3 - --check-registry --list --wait 10' < tools/usf.py
   tools/phone-ssh 'python3 - --wait 10 --duration 3' < tools/usf.py      # accelerometer, 50 Hz
   ```
   Expect `"/" properties [('loaded', '1')]`, "N.N s: M sensors" lines as
   the list grows, then a few dozen sensors (LSM6DSV accelerometer, gyroscope,
   two MMC5633, ICP20100, TMD3719, VD6282 and Google's fused ones) and
   samples near (0, 9.8, 0) m/s² upright. If the list stays empty after
   10 s: `dmesg | grep -iE "aoc|usf" | tail -30` and stop. A clean retry is
   a reboot, `omandroid-aoc-start`, then C6b with the new `usf.py` (it now
   polls after the load). The persist calibration is not needed for a first
   reading (the service loads it read-only; never copy it into the repo).

   **C6c, auto-rotate** (package `omandroid-sensors`, build it on the phone
   with makepkg like the others, or copy `lib/` by hand):
   ```sh
   tools/phone-ssh 'systemctl start omandroid-sensor-proxy; journalctl -u omandroid-sensor-proxy -b --no-pager | tail -5'
   tools/phone-ssh 'timeout 10 monitor-sensor --accel 2>&1 | tail -5'     # iio-sensor-proxy's tool, if installed
   tools/phone-ssh 'U=$(id -nu 1000); runuser -u $U -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start omandroid-autorotate'
   ```
   Expect: "sensors: accel (handle …), light …, proximity …", then turning
   the phone rotates the screen and touch. If a direction is mirrored, the
   transform table in `autorotate.py` needs 1 and 3 swapped (report which).
   Rollback: `systemctl stop omandroid-sensor-proxy`; the user service
   restores nothing by itself, so `hyprctl reload` (or rotate back to
   upright) before stopping it.

   **C6c result (first run):** the proxy failed with ENODEV, and every
   `AOCC_CMD_OPEN_CHANNEL` failed with -19. Not a channel leak (channel
   IDs only ever count up). The proxy unit `Requires=omandroid-aoc.service`.
   The AoC had been started by hand, so the unit was inactive and systemd
   ran `omandroid-aoc-start` again. That wrote `aoc.bin` to a running AoC:
   the core took the AoC offline, the GSA refused the image (-16), and the
   AoC stayed down until a reboot. Fixed twice:
   - `omandroid-aoc-start` (omandroid-device-cheetah 0.1.17) exits 0 when
     the AoC is already online, and refuses when an earlier start this boot
     failed;
   - kernel `67abdfab5` refuses a firmware write unless the AoC is offline.

   **Clean sequence, next boot** (device-cheetah 0.1.17 and
   omandroid-sensors 0.1.1 installed; no audio before this passes):
   ```sh
   tools/phone-ssh 'systemctl start omandroid-aoc; journalctl -u omandroid-aoc -b --no-pager | tail -3'
   tools/phone-ssh 'systemctl start omandroid-sensor-proxy; sleep 3; journalctl -u omandroid-sensor-proxy -b --no-pager | tail -8'
   tools/phone-ssh 'python3 - --check-registry --list --wait 10' < tools/usf.py
   tools/phone-ssh 'timeout 10 monitor-sensor --accel 2>&1 | tail -5'
   tools/phone-ssh 'U=$(id -nu 1000); runuser -u $U -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start omandroid-autorotate'
   ```
   Always start the AoC through the unit (`systemctl start omandroid-aoc`),
   not the script, so units that require it see it active. The proxy loads
   the registry itself (stock scripts, then the factory calibration read
   from persist, read-only) and waits up to 10 s for the sensors. Expect
   "up: Services : 82", then "sensors: accel (handle …), light …,
   proximity …", `loaded=1` and the sensor list, then rotation.

   **C6c result (2026-10-12, 7.3.0-rc6-omandroid-push1-00269-ga874b95ca381,
   device-cheetah 0.1.18): passed.** "up: Services : 82", then "sensors:
   accel (handle 30), light (handle 44), proximity (handle 23), compass
   (handle 53)". A claim of the accelerometer read `right-up`/`tilted-up`,
   and turning the phone rotated the screen and touch in every direction.
   With the phone lying flat the orientation stays `undefined`, as with
   iio-sensor-proxy (neither axis passes 35°), so read it with the phone
   upright. Two boot problems were fixed first:
   - `aoc_alsa_dev` autoloads from the sound card node and pulls in
     `aoc_core`, `gsa` and Trusty, where `aoc_core` waits unbound (mailbox
     -517). The start script took the loaded module for "already started"
     and refused. 0.1.18 blacklists `aoc_alsa_dev`/`aoc_alsa_dev_util`,
     loads the sound card after the services are up, and tracks the
     firmware load with a marker in `/run`.
   - A copy of `omandroid-aoc.conf` left in `/etc/modprobe.d` from bring-up
     overrode the package's file of the same name: delete it (and
     `omandroid-aoc-bringup.conf`).

   **Accelerometer missing when the AoC starts at boot** (2026-10-12,
   00283 kernel, device-cheetah 0.1.20): the AoC started at about 4.8 s and
   the proxy loaded the registry at about 5.7 s. Light, proximity and the
   magnetometers (I2C) came up; the LSM6DSV (I3C) did not, even after a
   proxy restart at 225 s. On the earlier boot the registry was loaded
   minutes after the AoC started, and all of them came up. The AoC probes
   its physical sensors once, when the registry loads (the restart found it
   loaded and skipped it), so a probe that fails at that moment stays
   failed until the AoC restarts. The rails were on in both cases. Most
   likely the I3C sensor is probed before the AoC's I3C bus is ready.
   omandroid-sensors 0.1.3 waits until the AoC's firmware was loaded at
   least 15 s ago (the start script's `/run/omandroid/aoc-firmware-loaded`;
   `OMANDROID_AOC_SETTLE_S` overrides it) before loading the registry.
   **Result (00285 kernel): not enough.** The proxy waited 13.8 s and still
   found light, proximity and compass without the accelerometer. The AoC
   log (`/dev/acd-logging` holds everything since AoC boot, 16 KB here)
   has no sensor probe lines at its default level. Two candidates are left:
   the AoC needs much longer than 15 s after boot before the LSM6DSV
   probes, or the factory calibration from persist (which the proxy adds
   and `usf.py --load-registry` does not) is what drops the
   accelerometer; C6b-2 (stock scripts only) and C6c (proxy) both found
   it, but on C6c check whether the proxy actually read persist
   (`journalctl -u omandroid-sensor-proxy -b -N | grep loaded` for that
   boot).

   **C6d** (read-only apart from the AoC's registry RAM): before the
   reboot, `systemctl disable omandroid-sensor-proxy` (the AoC itself still
   starts at boot). Two minutes after boot, start the proxy by hand: the same
   load as at boot (stock scripts, then persist), only later:
   ```sh
   tools/phone-ssh 'systemctl start omandroid-sensor-proxy; sleep 15; journalctl -u omandroid-sensor-proxy -b --no-pager | grep -E "loaded|sensors:"'
   ```
   - accelerometer listed: boot timing; the fix is a longer settle (the
     log shows how long the AoC had been up);
   - accelerometer missing: the persist calibration is the suspect (C6b-2
     found it with the stock scripts only). On the next boot, with the proxy
     still disabled, load the stock scripts only
     (`python3 - --load-registry /usr/share/omandroid/sensors/registry /usr/share/omandroid/sensors/registry/append --list --wait 10 < tools/usf.py`)
     and send the list, plus the names of the persist files the proxy
     loaded (not their contents).
   Rollback: `systemctl enable omandroid-sensor-proxy`.

   **C6d result: neither timing nor calibration.** The proxy started about
   95 s after the AoC and still found no accelerometer, and every boot
   loads the same eight calibration files. The difference is the rails: on
   the boot where the accelerometer worked, `gs201_aoc_rails` found LDO7S
   (ctrl 0x2c) and LDO5S (0x3c) off and turned them on before the
   firmware; on every boot since, they read on (0xac, 0xbc) at 4.9 s,
   left powered through the warm reboot. The I3C LSM6DSV then keeps the
   previous AoC session's state and the new AoC never finds it; the I2C
   sensors don't care. Google's driver power-cycles these supplies around
   an AoC restart (`reset_sensor_power()`: off in reverse order, 150 ms,
   on). Kernel `829fd316a` adds `gs201_aoc_rails cycle=1` (with
   `enable=1`): sensor rails already on are turned off (LDO5S, then
   LDO7S) for `cycle_ms` (150) ms first; device-cheetah 0.1.22 passes it.

   **C6e** (same boot as C7d-6; re-enable the proxy first:
   `systemctl enable omandroid-sensor-proxy`; warm reboot from a session
   where the AoC ran, so the rails start on):
   ```sh
   tools/phone-ssh 'dmesg | grep gs201-aoc-rails; journalctl -u omandroid-sensor-proxy -b --no-pager | grep -E "settle|sensors:"'
   ```
   Expect "LDO5S prox: was on (ctrl 0xbc), cycled: off for 150 ms", the
   same for LDO7S, then both "enabled", and the proxy's "sensors: accel
   (handle …), light …, proximity …, compass …". Stop: a rail that does not
   come back on (no microphones or sensors; reboot), or accel still
   missing (send the `gs201-aoc-rails` lines). Rollback: device-cheetah
   0.1.21's start script (no `cycle`).

   **Don't `rmmod` the AoC modules.** Removing `aoc_alsa_dev`,
   `aoc_alsa_dev_util`, `aoc_core`, `gs201_aoc_sysmmu` and `gsa` while
   `aoc_core` waited for deferred probe oopsed the deferred-probe worker
   (`__device_attach_driver` on a freed driver: one of them leaves a
   driver on the bus). The device lock it held then hung every reboot in
   `device_shutdown`, which the shutdown watchdog doesn't cover: it needed
   a held power key. **Found and fixed** (kernel `dfeafb2ba`, modules
   only): `aoc_alsa_dev_util` registers its seven platform drivers (PCM,
   voice, compress, path, no-host, in-call, VoIP) at module init, but its
   exit unregistered them only once every AoC audio service had probed.
   With the AoC not online, unloading it left them on the platform bus in
   freed memory. It now always unregisters them and unwinds a failed init.
   Until that kernel is on the phone, still don't `rmmod` these modules.
3. **C7 audio** (kernel `omandroid-aoc` @ `33b28cee6` or later: the AoC
   sound card, `aoc_alsa_dev`/`aoc_alsa_dev_util`, ported from Google's
   driver, with the speaker limits in code; the amplifier description from
   `omandroid-audio` merged in). Merging into int has one conflict in
   `gs201.dtsi`: int's `usi5`/`spi_5` (GNSS) and the branch's
   `usi7`/`spi_7` (amplifiers) were added at the same place; keep both,
   `usi5` first. Config: `CONFIG_GS201_AOC_ALSA=m`, `CONFIG_SND_SOC_CS35L41_SPI=m`.
   Overlays: `aoc-core-test`, `audio-amps-test`, `aoc-sound-test` (the
   stock sound card with the amplifiers as TDM 0 codecs, generated from
   the stock tree; top amplifier slot 0, bottom slot 1).

   **Limits in code** (`aoc_alsa_card.c`, `aoc_speaker_limits()`, logged
   at card probe): "Top/Bottom Digital PCM Volume" capped at 817 (0 dB) and
   set to 657 (-20 dB); "Top/Bottom Analog PCM Volume" capped at 10 (17
   only with `speaker_protection=1`, never before C9). Boost peak 2.5 A,
   1 µH, 30 µF come from the DT (`cirrus,boost-*`). AUDIO-PLAN section 4
   applies on top: earpiece (top amp) analog ≤ 6, 1 kHz bursts of 1-2 s,
   never below 300 Hz, ≤ 30 s without protection.

   No step here uses `devmem`. The phone's `/usr/local/bin/devmem` is our
   `tools/devmem.c` (`devmem ADDRESS [VALUE]`): a second argument WRITES, so
   never pass a width (`devmem ADDR 32` writes 0x20), and never read PMU
   registers from userspace. PCM numbers do not follow the stock order
   (C7b: EP1 capture is 44, EP6 playback 47), so the steps find a device by
   its id in `/proc/asound`:
   `pcm() { grep -l "^id: $1" /proc/asound/card$C/pcm*/info | sed -n 's#.*/pcm\([0-9]*\)[pc]/info#\1#p' | head -1; }`.

   - **C7a amplifiers, read-only:** `AUDIO-PLAN.md` A2 (IDs over spidev)
     and A3 (driver probe, no card), unchanged. Stop as there.
   - **C7b card, no sound** (C5 passed this boot):
     ```sh
     tools/phone-ssh 'modprobe snd-soc-cs35l41-spi; modprobe aoc_alsa_dev_util; modprobe aoc_alsa_dev; sleep 3;
       cat /proc/asound/cards; aplay -l; arecord -l; dmesg | grep -E "aoc_speaker_limits|cs35l41|aoc_snd|aoc-snd" | tail -20'
     ```
     Expect a card with driver `aoc-snd-card`, both amplifiers ("Cirrus
     Logic CS35L41 (35a40), Revision: B2"), and four `aoc_speaker_limits`
     lines ending in `: 0`. **Stop** if any limit line is not `: 0` (the
     control was not found, so the limit is not in force): no sound tests.
   - **C7c microphones** (rails on: `omandroid-aoc-start` turned them on):
     ```sh
     tools/phone-ssh 'C=$(awk "/aoc-snd-card/{print \$1; exit}" /proc/asound/cards);
       amixer -c $C cset name="EP1 TX Mixer INTERNAL_MIC_TX" 1;
       amixer -c $C cset name="BUILDIN MIC ID CAPTURE LIST" 0,3,2,-1;
       amixer -c $C cset name="MIC DC Blocker" 1; amixer -c $C cset name="MIC Record Soft Gain (dB)" 22;
       pcm() { grep -l "^id: $1" /proc/asound/card$C/pcm*/info | sed -n "s#.*/pcm\([0-9]*\)[pc]/info#\1#p" | head -1; };
       arecord -D hw:$C,$(pcm "EP1 capture") -f S16_LE -r 48000 -c 2 -d 3 /tmp/mic.wav; ls -l /tmp/mic.wav'
     ```
     (control names from the stock `mixer_paths.xml`, `handset-mic` and
     `audio-recordC`.) Expect a 3 s file that is not all zeros (tap the phone
     while it records). **Passed** on 2026-10-12: floor RMS about 35, peaks
     to 946 / 2635 with noise.
   - **C7d first sound, top amplifier alone, DSP bypassed, -20 dB:**
     ```sh
     tools/phone-ssh 'python3 - <<"PY"
     import math, struct, wave
     w = wave.open("/tmp/tone.wav", "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
     a = int(32767 * 0.1)  # -20 dBFS
     w.writeframes(b"".join(struct.pack("<hh", s, s) for s in (int(a * math.sin(2 * math.pi * 1000 * n / 48000)) for n in range(72000))))
     w.close()
     PY'
     tools/phone-ssh 'C=$(awk "/aoc-snd-card/{print \$1; exit}" /proc/asound/cards);
       amixer -c $C cset name="Bottom Digital PCM Volume" 0; amixer -c $C cset name="Bottom Analog PCM Volume" 0;
       amixer -c $C cset name="Top PCM Source" ASP; amixer -c $C cset name="Top Analog PCM Volume" 6;
       amixer -c $C cget name="Top Digital PCM Volume";
       amixer -c $C cset name="TDM_0_RX Mixer EP6" 1;
       pcm() { grep -l "^id: $1" /proc/asound/card$C/pcm*/info | sed -n "s#.*/pcm\([0-9]*\)[pc]/info#\1#p" | head -1; };
       aplay -M -D hw:$C,$(pcm "EP6 playback") /tmp/tone.wav; dmesg | grep -iE "cs35l41|aoc" | tail -10'
     ```
     Expect a quiet 1.5 s 1 kHz tone from the **top** speaker (the
     earpiece grille): that also confirms top = chip select 0. Then the same
     for the bottom amplifier (swap Top and Bottom; Bottom Analog ≤ 10).
     **Stop:** no sound or the wrong speaker (report; do not raise the
     gain), any CS35L41 error or IRQ line, distortion, a warm phone. Never
     raise "Digital PCM Volume" above 657 or loop the tone before C9.
     Rollback: `amixer … cset name="TDM_0_RX Mixer EP6" 0`, then
     `rmmod aoc_alsa_dev aoc_alsa_dev_util snd_soc_cs35l41_spi` (the amps go
     back into reset).

     **C7d result (first run):** card, amplifiers and limits fine, but
     `aplay` (copy mode, no `-M`) failed at once with "Bad address":
     `ERR: inconsistent write/read pointers, avail = 0, towrite = 15360`.
     Not the iov_iter port (capture uses the same copy path and works).
     Prepare resets the down ring's write pointer to the ring start; on a
     ring that was never used (wp 0) that marks the whole ring as written,
     and the first copy finds no room. Google's HAL plays through mmap,
     where prepare treats the ring as full anyway and the AoC drains it.
     Hence `aplay -M` above (C7d-2). Kernel `d696fde42` (modules only:
     `aoc_alsa_dev_util.ko`) logs the ring's written/read counters if a
     copy write still fails. Stop as before, and also if `aplay -M` reports
     an mmap error or the AoC logs a SysMMU fault (report the dmesg).

     **C7d-2 result:** `aplay -M` hung (killed after 60 s) and nothing was
     heard. The AoC accepted bind, EP setup and start (`0x00c9`), then sent
     no period interrupts and no position updates. The PCM's interrupt is
     AoC mailbox index 20 (`PCM_CHANNEL`), which is the F1 mailbox
     (0x18320000, SPI 76), channel 4; the sensors use the A32 mailbox only.
     Still to tell apart: the AoC never ran the stream (no TDM 0 clock, so
     nothing drains the ring); it ran but its interrupt does not reach us;
     or the amplifiers never powered up.

   - **C7d-3, diagnosis** (kernel `omandroid-aoc` @ `dee7e2334` for the
     complete `debugfs aoc/services` listing; the sysfs `services` file
     stops at a page; modules only: `aoc_core.ko`, `aoc_alsa_dev_util.ko`).
     `tools/aoc-audio-diag` sets the C7d mixer (bottom amplifier 0/0, Top
     PCM Source ASP, Top Analog 6, Top Digital left at 657, `TDM_0_RX Mixer
     EP6` 1), plays `/tmp/tone.wav` for at most 5 s with mmap and then in
     copy mode (each under `timeout`), snapshots before, during and after,
     and sets EP6 and Top Analog back to 0:
     ```sh
     tools/phone-ssh 'bash -s' < tools/aoc-audio-diag > logs/c7d3.txt 2>&1
     ```
     Only reads apart from the mixer and the two `aplay` runs (the regmap
     files are read up to 0x10100 and the reading stops there). What the
     snapshots show:
     - the F1 mailbox's count in `/proc/interrupts` (`18320000.mailbox` or
       similar) going up during playback means the AoC signals and we
       lose it after the IRQ; no change means the AoC sends nothing;
     - `audio_playback5` Down `Rx` going up means the AoC drains the
       ring (the stream runs); flat means it never started;
     - CS35L41 0x2014 bit 0 (GLOBAL_EN) and 0x2018 bit 0 (AMP_EN) set,
       "Main AMP: On" in DAPM: the amplifier is on; 0x10090 and 0x10098
       hold the raw status bits (a PLL or clock error means no BCLK from
       the AoC); 0x4800 shows the enabled receive slots.
     Run it after the clean sequence above, C7b, and the tone file step of
     C7d (`/tmp/tone.wav` is gone after a reboot).
     Stop on anything louder than a tone burst, an amplifier error, or a
     watchdog. Send `logs/c7d3.txt`.

     **C7d-3 result (2026-10-12, 7.3.0-rc6-omandroid-push1-00269-ga874b95ca381):
     nothing heard; the AoC never read the ring.**
     - `audio_playback5` Down ring (1 × 4 MiB): Tx 0 before, 4194304
       during and after the mmap run, Rx 0 throughout. The copy run then
       failed with "avail = 0 … written 8388608, read 0".
     - Interrupts: A32 mailbox (IRQ 107) flat at 4732; F1 mailbox
       (IRQ 108, the PCM's) 12 → 15 → 16; P6 (109) 0.
     - Amplifiers: GLOBAL_EN and AMP_EN on during playback, RX slot 1
       enabled (0x4800 0x10000). IRQ1_STATUS3 0x2000003f afterwards has
       PLL_LOCK (bit 1) and PLL_CLK_CTRL moved 0x10 → 0x510: **both
       amplifiers locked to the AoC's TDM 0 bit clock**, so the AoC's
       sink ran (playing silence) while EP6 never pulled from its ring.
     - The AoC answered every command (bind 0x010f, EP setup 0x00ce and
       0x012a, start 0x00c9) with no error reply.

     What that rules out: the amplifiers, TDM 0 clocking, the PCM
     interrupt line, and the AP sending TDM configuration (it never does:
     the `TDM_0_RX` Chan/Format/Rate controls only feed the codec's
     `hw_params`; the AoC configures its port itself). The ring itself is
     the suspect: prepare "resets" the write pointer by advancing it to the
     ring start, and on a fresh ring (wp 0) that advanced it by a whole
     ring, so the ring read as full of stale data before the AoC saw the
     setup, and the AoC never flushed it. Google's HAL plays in copy mode
     (not mmap), so the copy path must work on a fresh ring.

   - **C7d-4** (kernel `omandroid-aoc` @ `24483c36e`, modules only:
     `aoc_core.ko`, `aoc_alsa_dev_util.ko`; a fresh boot, because the
     rings this boot used stay full until the AoC restarts):
     - `2211dd734` leaves a ring alone when its write pointer is already
       at the start, so a fresh ring stays empty after prepare;
     - `24483c36e` adds `aoc_alsa_dev_util ring_debug=1`, which logs the
       ring's written/read counters at prepare, start, stop and each AoC
       PCM interrupt (`aoc-audio-diag` sets it).

     Run C7b's check, the C7d tone step, then copy mode first:
     ```sh
     tools/phone-ssh 'EP=6 MODES="copy" bash -s' < tools/aoc-audio-diag > logs/c7d4a.txt 2>&1
     ```
     Expect "aoc pcm audio_playback5 prepared: written 0 read 0", then
     `irq` lines with `read` going up, Rx going up in the snapshots, and a
     quiet 1.5 s tone from the top speaker (-20 dB digital, analog 6).
     - If the tone plays: run the same with `MODES="copy copy"` (second
       stream on the same ring, wp no longer 0) and send both logs.
     - If `read` stays 0 again: try the low-latency endpoint EP2 (service
       `audio_playback1`) the same way, to tell an EP6 problem from a
       general one:
       `tools/phone-ssh 'EP=2 MODES="copy" bash -s' < tools/aoc-audio-diag > logs/c7d4b.txt 2>&1`.
     Stop: anything louder than the tone, distortion, an amplifier error,
     an AoC watchdog or a SysMMU line. Rollback: the script sets the route
     and Top Analog back to 0 itself.

     **C7d-4 result (2026-10-12, 7.3.0-rc6-omandroid-push1-00283-gafa4d777403d,
     fresh boot): the ring fix works, the AoC still reads nothing.**
     - EP6 (`audio_playback5`, 4 MiB ring), copy mode: "prepared: written 0
       read 0", "started: written 96000 read 0", then "stopping: written
       96000 read 0" 8 s later. aplay ended with EIO. No `irq` line: the AoC
       raised no PCM interrupt.
     - EP2 (`audio_playback1`, 16 KiB ring): 15360 bytes written before the
       start, never read; the next write found 1024 bytes free (-EFAULT).
     - A second EP6 run in the same boot: "prepared: written 4194304": the
       reset advances a partly used ring (wp 96000) to its start, which reads
       as full again. Use each endpoint once per boot until the AoC reads.
     - A click when the amplifier powers up (silence on TDM 0).

     **Compared with Google's older driver.** Google's gs-5.10 android14
     AoC driver (google-modules/aoc 222ba49, aoc-ipc 61ee513), written for
     older AoC firmware, against our gs-6.1 import:
     - the ring core (`aoc_ipc_core.c`) is the same, including the reset in
       prepare, so the firmware is expected to flush the ring at entry
       point setup; ours neither flushes nor reads;
     - the bind (0x010f), entry point setup (0x00ce) and source start
       (0x00c9) commands and their structures are the same;
     - gs-6.1 adds CMD_AUDIO_OUTPUT_EP_SETUP2 (0x012a: buffer and period
       size) after 0x00ce; gs-5.10 never sends it;
     - nothing else reaches the AoC: the card sends no commands at probe,
       and the `TDM_0_RX` Chan/Format/Rate controls only feed the codec;
     - the module order differs only in time (there the ALSA modules and
       the card load before the firmware; ours load after it is online,
       before `aoc_char_dev`, so the audio services still bind to ALSA).

     Our firmware is 14022723. Its strings include "Attempt to start
     playback without configuration", "Entrypoint %s is not configured and
     cannot be started" and "Entrypoint %u cannot be configured": the AoC
     logs why an entry point does not run. Google's `aocd` forwards that log
     from `/dev/acd-logging`, which our `aoc_char_dev` already exposes.

   - **C7d-5** (kernel `omandroid-aoc` @ `e8929e1b2`, modules only:
     `aoc_alsa_dev_util.ko`, which adds `ep_setup2`; fresh boot; C7b and
     the C7d tone step first). `tools/aoc-audio-diag` now also reads the
     AoC's "Audio DSP State", "Audio DSP Mode", "Audio Sink 0 Processing
     State" and "AoC Speaker Sink Channel Bitmap" in every snapshot, and with
     `AOCLOG=1` records the AoC firmware log while it runs (read only).
     1. **C7d-5a, the AoC's own account** (EP6, both setup commands, as
        before):
        ```sh
        tools/phone-ssh 'AOCLOG=1 EP=6 MODES="copy" bash -s' < tools/aoc-audio-diag > logs/c7d5a.txt 2>&1
        ```
        Expect the same failure, now with AoC log lines around the
        entry point setup and start (look for "Entrypoint", "configur",
        "Binding", "Enabling Audio Output Source", "sink"). Check the log
        excerpt for identifiers before quoting it.
     2. **C7d-5b, without EP_SETUP2** (a ring not used this boot: EP2):
        ```sh
        tools/phone-ssh 'AOCLOG=1 SETUP2=0 EP=2 MODES="copy" bash -s' < tools/aoc-audio-diag > logs/c7d5b.txt 2>&1
        ```
        Pass: "read" grows in the `irq` lines and a short quiet tone plays
        (EP2 is the stock low-latency endpoint, also routed to TDM 0). Then
        EP_SETUP2 is what stops this firmware, and its values (or its
        ordering) are the next thing to fix.
     3. Only if both fail and the log does not say why: compare with an
        older AoC firmware from an older factory image of the user's own
        (`tools/extract-vendor-firmware`), with `SETUP2=0`, on a later boot.

     Stop on anything louder than the tone, an amplifier error, an AoC
     watchdog or a SysMMU line. Rollback: the script resets the route and
     Top Analog; `echo 1 > /sys/module/aoc_alsa_dev_util/parameters/ep_setup2`.

     **C7d-5a result (2026-10-12, 7.3.0-rc6-omandroid-push1-00285-ge821a4becdea):
     root cause found in the AoC's own log.**
     ```
     F1: ERR: controller_audio_output.cc, 1912: Mode Playback is not supported by Entrypoint 47
     F1: ERR: controller_audio_output.cc, 2005: Entrypoint 47 cannot be configured
     F1: ERR: controller.cc, 906: AudioOutCtrl: ipc: audio_output_co, cmd ID: 0x00ce, tag: 0x10, rc: -1
     F1: ERR: controller_audio_output.cc, 1764: Entrypoint 47 cannot be enabled
     ```
     The driver takes the AoC entry point from the PCM device number
     (`entry_point_idx = pcm->device`, Google's "TODO: refactor needed on
     mapping between device number and entrypoint"), and the capture use
     case too (`UC_AUDIO_RECORD` is 8, EP1 capture). ASoC numbers a card's
     PCMs in DAI link order. `fdtoverlay` (libfdt) inserts every node an
     overlay creates as the first child of its parent, so the card's links
     came out reversed: BE links first, then EP6..EP1 capture, then
     EP8..EP1 playback, which made EP6 playback PCM 47 and EP1 capture
     PCM 44. Capture "worked" through the generic path, not the record use
     case. The AoC also answers a rejected command with rc -1, which the
     driver does not treat as an error (it only flags 4-byte replies).
     The snapshots read Audio DSP State 1 (Playback), DSP Mode 0, Sink 0
     Processing State 1, Speaker Sink Channel Bitmap 32.

     Fixes (second attempt; the first, writing the overlay in reverse,
     changed nothing on the phone: the applied DTB kept the source order and
     the PCM numbers stayed the same, so node order cannot be relied on and
     the overlay is back in the stock order):
     - kernel `24d9b9826` (`aoc_alsa_dev.ko`): the card sorts its parsed
       DAI links by link id into the stock order (the known front ends in
       Google's order, other front ends, then the back ends), whatever the
       device tree order: EP1-EP8 playback are PCM 0-7, EP1-EP6 capture
       PCM 8-13, as in Google's HAL configuration.
     - kernel `71c7777b0` (`aoc_alsa_dev_util.ko`): the PCM driver refuses
       to open an EP playback or capture PCM whose number does not match its
       link id ("… is PCM N, expected PCM M: the card's DAI links are not
       in the stock order"), instead of configuring another entry point.

   - **C7d-6** (kernel `omandroid-aoc` @ `829fd316a`, modules only:
     `aoc_alsa_dev.ko`, `aoc_alsa_dev_util.ko`, `gs201-aoc-rails.ko`; the
     overlay content is unchanged; device-cheetah 0.1.22; one boot together
     with C6e; C7b and the C7d tone step first):
     1. Numbering, read-only:
        ```sh
        tools/phone-ssh 'head -2 /proc/asound/card0/pcm5p/info /proc/asound/card0/pcm8c/info; dmesg | grep -c "not in the stock order"'
        ```
        Expect `id: EP6 playback` for pcm5p, `id: EP1 capture` for pcm8c,
        and 0. Stop otherwise (the new `aoc_alsa_dev.ko` is not loaded).
     2. First sound, top amplifier, -20 dB digital, analog 6:
        ```sh
        tools/phone-ssh 'AOCLOG=1 EP=6 MODES="copy" bash -s' < tools/aoc-audio-diag > logs/c7d6a.txt 2>&1
        ```
        Expect in the AoC log "Enabling Audio Output Source 5 in Mode
        Playback" and no "Entrypoint … cannot", `irq` lines with "read"
        growing, Rx moving in the snapshots, and a quiet 1.5 s 1 kHz tone
        from the top speaker. Stop: no sound with "read" growing (report the
        amplifier registers), anything louder than the tone, distortion, an
        amplifier error, an AoC watchdog.
     3. The ring after a played stream: run step 2 again in the same boot.
        Expect "prepared: written N read N" (the AoC drained the ring), and
        the tone again. If "prepared" shows written ahead of read by a whole
        ring, report it: the prepare-time reset then needs the AoC's flush.
     4. Bottom amplifier: as C7d (swap Top and Bottom, Bottom Analog ≤ 10),
        with `aoc-audio-diag` adapted or by hand under `timeout 5`.
     5. Microphones again (C7c with PCM 8, which is now the AoC record use
        case): expect a 3 s file that is not all zeros.

## 0. Top findings

1. **Stock starts the AoC through Trusty; this phone's GSA also takes the
   mailbox command (C1).** Stock
   loads `aoc.bin` from the kernel (`aoc 19000000.aoc: attempting to load
   firmware "aoc.bin"`, `R/dmesg.txt:5799`), the GSA authenticates it over its
   mailbox (`GSA_MB_CMD_LOAD_AOC_FW_IMG` = 90, `GSA/gsa_core.c:169-176`), and
   then `GSA_AOC_START` goes to the Trusty service
   `com.android.trusty.gsa.hwmgr.aoc` (`GSA/gsa_core.c:187-194`,
   `R/dmesg.txt:5886` "TZ: com.android.trusty.gsa.hwmgr.aoc connected").
   Every public Google kernel does the same, back to the first Pixel 6 branch
   (`android-gs-raviole-5.10-android12-d1`). But the GSA mailbox also
   carries AoC state commands (command 91), and C1 got an answer: the
   **GSA-direct path** (section 0.1) needs no Trusty. Trusty (already ported
   on `omandroid-fingerprint`, shared with fingerprint) stays as the
   fallback; `gsa.c` speaks both.
2. **The bootloader does not leave the AoC running.** Stock's kernel loads and
   starts it 4.07 s into boot and it reports "firmware version
   14022723-polygon did become online with 82 services" at 4.60 s
   (`R/dmesg.txt:5799-6042`). Nothing earlier touches it. So there is no
   running firmware for a minimal client to talk to; the full
   load-authenticate-start path is needed.
3. **The firmware and Google's 6.1 driver match, and the firmware carries its
   own IOMMU map.** Parsed offline from our `V/firmware/aoc.bin` (21,328,448
   bytes, auth header generation 1, superbin magic `0xaabbccdd`, release
   build "14022723-polygon"):
   - all 286 interface UUIDs that `GA/aoc-interface-gs201.h` checks
     (`AocInterfaceCheck()`) are in the firmware's 537-entry table, so the
     driver accepts this firmware;
   - the image config puts the body at `0x94000000` (`fw_size` 0x1600000,
     22 MiB), the IPC area at carve-out offset 0x1600000, and lists **six
     IOMMU windows** (AoC address → physical, size):

     | AoC VA | PA | Size | What |
     |---|---|---|---|
     | `0x98000000` | `0x94000000` | 48 MiB | the AoC carve-out (`aoc@94000000`) |
     | `0x9b000000` | `0x97000000` | 4 MiB | `xhci-dma` (USB audio offload) |
     | `0x9e000000` | `0x18200000` | 2 MiB | APM/AoC mailboxes (`0x18210000`, `0x18300000`-`0x18340000`) |
     | `0x9e200000` | `0x17c00000` | 1 MiB | GSA block (`0x17c60000` S2MPU, `0x17c90000` mailbox) |
     | `0x9e500000` | `0x11200000` | 1 MiB | USB PHY/dwc3 (HSI0) |
     | `0x9e300000` | `0x40000000` | 1 MiB | PCIe ch0 outbound window (modem) |

     All are 1 MiB multiples, so a first-level-only SysMMU v8 table (the
     format our Wi-Fi work already uses, `WIFI-BATTERY-PLAN.md` 9.17) covers
     them: about 300 lines instead of Google's 3,200-line IOMMU driver.
4. **AoC state commands work over the GSA mailbox.**
   `GSA_MB_CMD_AOC_CMD` (91) is defined next to the load command
   (`GSA/gsa_mbox.h:49-52`) but no public driver sends it. C1 asked it for
   `GSA_AOC_GET_STATE` and got a proper answer (state 0, inactive). Start,
   shutdown and reset are the same command with another argument.
5. **ACPM channel 13 is a doorbell, not a queue, and is not needed to start
   the AoC.** Our A1 dump shows it as type 2 (buffer), all offsets 0, `mlen
   0` (`logs/acpm-20261012-112536-a1.log`). Google's driver handles a type-2
   channel by calling the client's callback on the APM→AP mailbox interrupt
   bit (`GS/drivers/soc/google/acpm/acpm_ipc.c:499-505`), and the AoC callback
   ignores the payload (`GA/aoc_v1.c:58-67`, sets `aoc_reset_done`). It is
   used only after an AoC watchdog reset (`aoc_watchdog_restart()`,
   `GA/aoc_v1.c:109-206`). So the fix for crash recovery is to watch bit 13
   of the AP2APM mailbox status (SPI 78), not to read any SRAM ring. A
   **clean** restart needs no ACPM at all: Google's `aoc_take_offline()`
   (`GA/aoc.c:1582-1640`) does shutdown (GSA 4, back to "loaded"), then
   unload (the GSA unlocks the carve-out, "inactive"), after which load and
   start run again.
6. **First sensor reading comes before first sound.** Sensors need the AoC
   core plus a character-device client in userspace; audio additionally
   needs the 16,700-line `aoc_alsa` port, the amplifiers and their protection.

### 0.1 C1 result and the GSA-direct path

C1 on `omandroid-int` `7.3.0-rc6-omandroid-push1-00186-ga0b0c0ebb3f6`
(default DTB + `display-decon-test` + `aoc-gsa-test`):

```
google-gsa 17c90000.gsa: mailbox ready, irq 104
sjtag_status: args 3: debug_allowed 0x00000000 hw_status 0x00000010 debug_time 0x00000000
cmd 100: answer 0x80000064 err 0 argc 3
cmd 91: answer 0x8000005b err 0 argc 1
aoc_state: args 1: 0x00000000 ... (state inactive)
```

`hw_status 0x10` is what stock prints for the same command
(`R/dmesg.txt:2012`). No hang.

GSA commands for the AoC (`GSA/gsa_mbox.h:49-52`, `include/linux/gsa/gsa_aoc.h`,
`GSA/hwmgr-ipc.h`):

| Mailbox cmd | Args | Reply | Stock sends it |
|---|---|---|---|
| 90 `LOAD_AOC_FW_IMG` | header DMA lo, hi; body PA lo, hi | none | yes, on the mailbox; a "data transfer" command: under a GSA wakelock (150/151) with the GSA S2MPU open |
| 91 `AOC_CMD` | one: `GET_STATE` 0, `START` 1, `SHUTDOWN` 4, `RELEASE_RESET` 5, `RESET` 6 | one: state `INACTIVE` 0, `LOADED` 1, `RUNNING` 2 | no: stock sends the same commands as Trusty `hwmgr.aoc` `STATE_CMD` (1) |
| 92 `UNLOAD_AOC_FW_IMG` | none | none | no: stock uses `hwmgr.aoc` `UNLOAD_IMG` (2) |
| 150 / 151 `WAKELOCK_ACQUIRE/RELEASE` | none | none | yes, around data transfers (`GSA/gsa_mbox.c:466-560`) |

Stock's order:

- **Boot** (`GA/aoc.c:508-710`): `aoc_req` = 1 → copy the body → load (90) →
  write the parameter block → `START` → the firmware fills its control
  block ("online with 82 services" 0.45 s later).
- **Offline** (`GA/aoc.c:1582-1640`): `aoc_req` = 1 and wait for the
  acknowledge → `SHUTDOWN` (expects "loaded") → unload (expects success,
  state "inactive").
- **Crash**: the PCU watchdog, ACPM channel 13, then boot again.

So the GSA-direct path is: load (90), then 91 `START`; restart = 91
`SHUTDOWN`, 92, load, 91 `START`. `gsa.c` sends 91/92 when loaded with
`aoc_cmd_mbox=1`, and the Trusty messages otherwise.

### 0.2 C2-C4 results (omandroid-int 00200, DTB default + display-decon-test + aoc-boot-test)

| Stage | Result |
|---|---|
| C2 | pass. `aoc_req` 1, ack 1: **BLK_AOC is on at hand-off**. GSA state 0. Chip 0x9855000, type 0x1, revision 0x10; board 0x30301/0x10000. Carve-out not System RAM. **AoC S2MPU CTRL0 0x5** (enabled, blocking). AoC System MMU v8.1, CTRL 0x24, CAPA0 0x41085800, CAPA1 0xe051 (8 VIDs), every VID off (ctrl 0, cfg 0x20000, no table) |
| C3 | pass. S2MPG12 and S2MPG13 CHIPID 0x05. **All five rails off**: LDO20M/19S/20S/7S ctrl 0x2c (1800 mV), LDO5S 0x3c (3300 mV), enable bits clear |
| C4a | pass. GSA S2MPU CTRL0 0x1 → 0 for the load; "cmd 90: answer 0x8000005a err 0"; state 1 (loaded); no faults |
| C4b | **no**. "cmd 91 … argc 1", reply **4**; no control block in 5 s; GSA state stays 4; no System MMU fault line. `SHUTDOWN` then gives state 1 (loaded), and the phone is fine |

**The "magic 0xa0cda7a" is our own parameter block.** The boot driver wrote
`AOC_PARAMETER_MAGIC` 0x0a0cda7a at carve-out + 0x1600000 before the start,
and the firmware overwrites that area with its control block (magic
0xa0c00a0c) when it comes up (`GA/aoc.c` writes both at the same address).
The "control block" printed is that parameter block read as one: status
0x1001 is the first key (`kAOCBoardID`), "4098 services" is 0x1002
(`kAOCBoardRevision`), "size 4" its length, "+0x10000" the board revision
value. Nothing is half-written or mis-parsed: **the firmware never got as
far as writing its control block.**

**State 4 is not in Google's enum** (`gsa_aoc.h`: inactive 0, loaded 1,
running 2; the TPU adds suspended 3, the DSP's own enum has 5 values). It is
the reply to `START`, read the same way as the replies that were right
(0 before load, 1 after load and after `SHUTDOWN`), so it is a real state.
Google's `aoc_take_offline()` carries a note that the shutdown command's
number changed in the GSA firmware (`GA/aoc.c:1619-1621`), so the GSA's AoC
interface has moved over time and its states are not all in the public
header. Readings to tell apart in C4b-2:

1. **A block reset during load or start cleared our setup.** The AoC S2MPU
   was 0x5 (blocking) at hand-off and the System MMU was off. If cmd 90 or
   `START` resets BLK_AOC, the S2MPU blocks every AoC access again (its
   faults are not reported to us) or the System MMU passes the AoC's
   addresses through untranslated. Either way the A32 cannot fetch its code.
   Stock restores both after a reset (pKVM for the S2MPU, the IOMMU driver
   on runtime resume). C4b-2 reads both after the load and before and after
   the start, and puts them back before `START`.
2. **The A32 is still in reset.** `START` may prepare the AoC and leave the
   A32 to a separate release (`GSA_AOC_RELEASE_RESET` 5, "take AoC A32 out of
   reset" in `gsa_aoc.h`), which Trusty's service might send itself. C4b-2
   reads the PCU reset control and, only if the A32 is held, sends 5.
3. **The firmware runs but waits or crashes early.** The ramdump header at
   carve-out + 32 MiB (`GA/aoc_ramdump_regions.h`, outside the locked body)
   has boot breadcrumbs, and the AoC watchdog (SPI 116) fires on a crash.
   C4b-2 dumps both.
4. **The rails.** Stock powers the microphone and sensor LDOs before the
   load (`configure_sensor_regulator()` and `configure_dmic_regulator()` at
   probe); on this phone all five are off at hand-off. The firmware publishes
   its control block before it probes sensors, so this is the least likely,
   but C4b-3 tests it.

Stock needs nothing else from the AP between `START` and "online": the
firmware writes its control block and rings an AoC mailbox; the AP only
checks the magic (`aoc_mbox_rx_callback()` → `aoc_fw_ready()`) and then
drops `aoc_req` (`aoc_did_become_online()`, `GA/aoc.c:1358-1440`). No ACPM
message, no AP doorbell first.

### 0.3 C4b-2 result: the GSA-direct start is not enough; use Trusty

C4b-2 rerun (int 00238, `deb7b47bd`): no abort, no fault, no watchdog.
After the load the System MMU translates VID 0 (global ctrl 0x25, VID 0
ctrl 0x9, our table), the AoC S2MPU stays 0 through the start, `START`
gives state 4 again, the IPC area keeps our parameters, the ramdump header
has no "AOCDUMP" and no breadcrumbs (0x300-0x32f zero). `RELEASE_RESET` (5)
gives state 2 ("running"), twice, but still nothing: no control block, no
breadcrumbs, no System MMU fault (`int` 0).

What Google's driver does that we did not, compared line by line
(6.1 `GA/aoc.c` `aoc_fw_callback()` and Google's 5.10 aoc.c at commit
222ba49, the version that drives this firmware generation through Trusty):

| Step | 5.10 driver | 6.1 driver | Ours |
|---|---|---|---|
| `aoc_req` = 1 before the load | yes | yes | yes |
| AoC S2MPU | CTRL0 read at probe, written back after a restart | (pKVM) | 0 before the load, stays 0 |
| System MMU windows | `aoc_configure_sysmmu()` at probe, non-secure domain via samsung-iommu (VID 0) | IOMMU driver | same windows, VID 0, before the load |
| body copy, GSA load (90), parameter block | yes | yes | yes |
| `START` | `gsa_send_aoc_cmd()` → **Trusty `hwmgr.aoc`** | same | **mailbox 91** |
| mailboxes | AP-side masks only; the firmware writes its control block first and rings after | same | not set up |

The only material difference left is **who sends `START`**. The mailbox
path answers, but not like Trusty's: `START` leaves state 4, and an explicit
`RELEASE_RESET` runs the A32 without any visible progress. The System MMU
has a secure half (`sysmmu,secure_base = <0x1a0a0000>`, secure fault
interrupt SPI 119) that only the secure world can program and whose faults
never reach Linux. The likeliest reading: Trusty's `hwmgr.aoc` service does
secure-side setup for the authenticated image (its secure translation,
security state of the AoC's masters) before it has the GSA start the AoC,
and the bare mailbox command skips it. An A32 that runs with that missing
would fault silently on the secure side, which is exactly what we see.

So the **Trusty path is now the main path**: load with the mailbox (as
stock), state commands through `hwmgr.aoc`. `gsa.c` already speaks it
(`CONFIG_GOOGLE_GSA_TRUSTY`, default when `aoc_cmd_mbox=0`), and the Trusty
driver is the fingerprint port (gate F2 not yet run), already in
`omandroid-aoc`. It is also the order stock uses (`R/dmesg.txt:5886`, "TZ:
com.android.trusty.gsa.hwmgr.aoc connected" right before the AoC comes up).

The rails (all off) stay a separate variable: change one thing at a time,
Trusty first, rails after if needed.

What is mandatory, in boot order:

| Piece | Why | Source | Our status |
|---|---|---|---|
| GSA mailbox | authenticates and loads `aoc.bin`; AoC state commands (91) | `GSA/gsa_mbox.c` (600) + `gsa_core.c` | **written**; C1 passed |
| S2MPU off for the GSA and the AoC | the GSA reads the image header by DMA; stock's pKVM programs both S2MPUs at power-up (`R/dmesg.txt:462`), nothing does without a hypervisor | `GS/drivers/soc/google/s2mpu/s2mpu-regs.h` (CTRL0 at 0x0; 0 passes everything) | **written**: CTRL0 = 0 only, GSA's under a GSA wakelock and restored after the load, the AoC's while BLK_AOC is on |
| Trusty + GSA `hwmgr.aoc` client | `GSA_AOC_START` on stock | `G/google-modules/trusty`, `GSA/gsa_tz.c` (236) | **fallback, written** (`CONFIG_GOOGLE_GSA_TRUSTY`); not needed while command 91 works |
| SysMMU `sysmmu_asoc` (`0x1a090000`, v8) | the AoC's view of DRAM and its peripherals | `GS/drivers/iommu/samsung-iommu.[ch]` (v8 VM register set) | **written**: windows from the image header, VID 0 |
| AoC mailboxes (`0x18300000`, `0x18320000`, `0x18340000`) | service doorbells | `GA/mailbox-wc.c` (412) | to port |
| AoC boot (parameters, start, control block) | gets the firmware to "online" | `GA/aoc.c` `aoc_fw_callback()`, `aoc_v1.c` | **written** as a bring-up driver (`gs201-aoc-boot`) |
| AoC core | services, rings, char devices | `GA/aoc.c`, `aoc_service_core.c`, `aoc_channel_dev.c`, `aoc_char_dev.c`, `aoc_control_dev.c`, `aoc_ipc` (~6,000) | to port (C5) |
| PMIC rails over ACPM ch 2 | mics (LDO20M, LDO19S, LDO20S), sensors (LDO7S then LDO5S) | `GS/include/linux/mfd/samsung/s2mpg1[23]-register.h`, `GS/drivers/regulator/s2mpg1[23]-regulator.c` | **written** (`gs201-aoc-rails`, read-only unless `enable=1`) |
| `aoc_alsa` | the sound card | `GA/alsa/` (~16,700) | audio only; to port |
| ACPM ch 13 | AoC restart after a crash | above | later |

---

## 1. How stock brings the AoC up (evidence)

Order in `aoc_fw_callback()` (`GA/aoc.c:508-710`), with `gsa-enabled` set in
the stock DT (`R/live.dts:6068`):

1. `request_aoc_on(true)`: write 1 to `aoc_req` (`0x181d0000`); the
   acknowledge is `aoc_req + 0x40` (`GA/aoc_v1.c:87-106`).
2. Validate the superbin, check the interface UUIDs, refuse unsigned images.
3. Copy the image body (without the 4 KiB auth header) into the carve-out
   at `0x94000000` (`_aoc_fw_commit()`; `AOC_BINARY_DRAM_OFFSET` is 0).
4. `aoc_fw_authenticate()`: copy the 4 KiB header into a
   `dma_alloc_coherent()` buffer **of the GSA device**, then mailbox command
   90 with header DMA address (lo, hi) and body physical address (lo, hi)
   (`GSA/gsa_core.c:82-95`). The GSA authenticates, then locks the body: from
   here the AP must not touch `0x94000000`-`0x955fffff`.
5. `aoc_pass_fw_information()`: write the parameter block at the IPC area
   (carve-out + 0x1600000): magic `0x0a0cda7a`, then key/size/value triples:
   board id `0x30301`, board rev `0x10000` (DT `aoc-board-cfg = "C10"`),
   carve-out address and size, the three heap addresses (sensor direct 4 MiB,
   playback 16 KiB, capture 64 KiB, carved from the top of the carve-out and
   given as AoC addresses = PA - 0x94000000 + 0x98000000), chip revision,
   type and product id, a random seed, and zeros for the debug switches.
6. `gsa_send_aoc_cmd(GSA_AOC_START)` over Trusty.
7. Enable the watchdog IRQ (SPI 116), keep the AP out of deep idle for 2 s,
   and wait for the firmware to write `AOC_MAGIC` into the control block;
   then it enumerates its services (82) and the bus binds drivers by name:
   `aoc_alsa` to `audio_output_control` and friends, `aoc_channel_dev` to
   `com.google.usf`, `com.google.usf.non_wake_up`, `com.google.chre`
   (`R/dmesg.txt:6076-6082`), everything else to `aoc_char_dev`.

With `gsa-enabled`, the kernel does **not** install the firmware's IOMMU table
(`aoc_configure_iommu()` runs only on the non-GSA path); stock's samsung-iommu
driver owns `sysmmu_asoc` and restores its state on runtime resume
(`GA/aoc_v1.c:185-198`). Which side programs the six windows on stock (the
non-secure table, or the secure half at `sysmmu,secure_base = 0x1a0a0000`)
is not visible in the GPL code; on our kernel nothing programs it, so we
install the six windows ourselves (C4).

Other facts the port needs:

- `pd_aoc` (`0x18061880`) is `disabled` in the stock DT: the APM powers
  BLK_AOC on `aoc_req`, the kernel never does. AoC power status is PMU
  `0x18061884` (`GS/drivers/soc/google/cal-if/gs201/flexpmu_cal_local_gs201.h:8-23`),
  but **do not read the PMU from user space**: a `/dev/mem` read of a PMU
  power-domain register crashed the phone (`GPU-PLAN.md`, incident).
- No SSMT setup on gs201 (`aoc_configure_ssmt()` is gs101-only,
  `GA/aoc_v1.c:314-342`).
- Pins: `aoc_vsync_pins` = gpp3-1, gpp5-1, gpp7-1, gpp9-1, function 2
  (`R/live.dts:4212-4216`, PERIC0 pin controller): display TE to the AoC,
  which times the under-display light sensor.
- Sensor supplies `sensor_1v8` then `sensor_3v3` (`sensor_power_list`,
  `R/live.dts:6092-6094`); DMIC supplies are always-on regulators in the DT.
- The AoC's view of time: `aoc_clock_and_kernel_boottime`, used to stamp
  sensor events.

---

## 2. Shortcuts considered

| Idea | Verdict | Why |
|---|---|---|
| The bootloader leaves the AoC running; talk to it with a minimal mailbox client | **no** | stock's kernel loads and starts it (finding 2) |
| Load with the GSA mailbox, start without Trusty (mailbox cmd 91) | **yes** | C1: the GSA answers command 91 (section 0.1) |
| Release the AoC from reset ourselves (`aoc_release_from_reset()`, PCU bit 0) | **no** | only for unsigned images without GSA; signed images are locked by the GSA, and the production firmware is signed |
| Skip the SysMMU (bypass) | **no** | the firmware addresses its carve-out at `0x98000000`, which is physically the GXP region; translation is required |
| Skip ACPM ch 13 | **yes** | needed only for crash recovery; a clean restart is shutdown, unload, load, start (finding 5) |
| Skip `aoc_alsa` for sensors | **yes** | sensors use `aoc_channel_dev` only |
| Skip the S2MPG12/13 regulator driver | **yes, at first** | five LDO enable bits over ACPM ch 2 (section 5); a proper regulator driver later |
| Port Google's samsung-iommu (3,200 lines) | **no** | a static six-window table is enough; the AoC needs no runtime maps for first light (the heaps are inside the 48 MiB window) |

### 2.1 Can the AoC client live in userspace, as Android's HAL does?

Partly. On stock the split is already kernel core + userspace HALs: the kernel
loads the firmware, runs the mailbox doorbells and the service rings, and
exposes each service as a character device (`/dev/acd-com.google.usf`,
`/dev/aoc`); the sensor HAL (`V/lib64/sensors.usf.so`, `libusf.so`) and the
audio HAL speak the services' message formats from userspace.

- **The kernel part cannot move to userspace.** The GSA needs a DMA buffer below 4 GiB that it can
  read, the SysMMU and S2MPUs need privileged writes, and the services are
  interrupt-driven rings. A UIO/`/dev/mem` client would reimplement the same
  core worse and could not be upstreamed.
- **The sensor client should live in userspace**, exactly like stock: our own
  USF client over `/dev/acd-com.google.usf` (FlatBuffers messages; the
  stock registry in `V/etc/sensors/registry/cheetah_dvt.reg` and
  `persist:/sensors/registry`), feeding an iio-sensor-proxy-compatible
  D-Bus service for Hyprland rotation and brightness.
- **Audio could, in principle, skip `aoc_alsa`** with a userspace daemon
  that drives `audio_output_control` and a playback ring through
  `aoc_char_dev` and exposes a PipeWire node. But the command set it would
  have to replicate is `aoc_alsa_hw.c`/`aoc_alsa_ctl.c` (7,400 lines), and
  PipeWire/UCM/volume keys all expect an ALSA card. Port `aoc_alsa`
  out of tree (with the CS35L41 as TDM codecs) instead.

---

## 3. Effort

| Piece | Lines (Google) | Effort | Notes |
|---|---|---|---|
| GSA mailbox driver, load/state/unload | 600 | **done** | `L/drivers/soc/google/gsa.c` |
| S2MPU CTRL0 handling | - | **done** | in `gsa.c` and `gs201-aoc-boot.c` |
| GSA `hwmgr.aoc` client over Trusty IPC | 236 | **done** (fallback) | on the fingerprint branch's `tipc` kernel API |
| SysMMU six-window driver | (3,200) → ~400 | **done** | v8 VM registers as in `GS/drivers/iommu/samsung-iommu.c:38-75,182-240` |
| AoC boot to "online" (bring-up) | (part of `aoc.c`) | **done** | `gs201-aoc-boot.c`, debugfs steps |
| AoC mailbox + core + char devices | ~6,000 | 2 weeks | out of tree first; vendor hooks (`exynos_pmu`, `dbg_snapshot`, `acpm_ipc`, `gs_chipid`, ITMON, power-mode) become stubs or upstream equivalents; the boot steps come from `gs201-aoc-boot` |
| Rails over ACPM ch 2 | - | **done** for the five LDO bits; 2-3 weeks for a real S2MPG12/13 regulator driver | `gs201-aoc-rails.c`; `ACPM-PLAN.md` 6 |
| USF sensor client + D-Bus service | - | 2-4 weeks | clean-room from the stock library's behaviour |
| `aoc_alsa` port to 7.3 ASoC | ~16,700 | 3-6 weeks | dummy codec on links with no driver, TDM slots from the DT |
| Machine/UCM/calibration/protection | - | 2 weeks | `AUDIO-PLAN.md` A7 |
| ACPM ch 13 doorbell + AoC restart | - | 3-5 days | upstream `exynos-mailbox` has no RX interrupt support yet |

Calendar, one developer: **first AoC "online" as soon as C2-C4 pass (the
code is written), first accelerometer reading 3-4 weeks after that (core
port + USF client), first protected speaker sound 6-10 weeks after
"online"**. Much shorter than the "months" estimate in `AUDIO-PLAN.md`:
no Trusty needed, the IOMMU is a static table, and ACPM works.

---

## 4. Risks

| Risk | Mitigation |
|---|---|
| S2MPU registers other than CTRL0 can reset the SoC; any S2MPU register can abort while its block is off | touch only CTRL0, only after the GSA wakelock (`GSA_MB_CMD_WAKELOCK_ACQUIRE` 150) or `aoc_req` acknowledge; never from user space |
| PMU reads from user space crash the phone (`GPU-PLAN.md` incident) | AoC power state only through the kernel, via `aoc_req + 0x40` or the GSA/Trusty `GET_STATE` |
| After `LOAD_AOC_FW_IMG` the carve-out body is locked; an AP read faults | never read `0x94000000`-`0x955fffff` after load; the carve-out is already `no-map` (`gs201.dtsi`) |
| A failed start cannot be retried in the same boot | hang-safe marker as for Wi-Fi: `tools/aoc-stage c4a` writes and syncs `/var/lib/omandroid/aoc-bringup-started` before the load and refuses to run while it exists; `c4b` clears it on success. A clean retry is `unload`, then load and start; after a failure, reboot |
| The AoC writes outside its windows (wrong table, wrong VID) | the System MMU translates VID 0 with only the six windows; anything else faults and is logged ("blocked ... VID n"). Untranslated traffic would reach physical memory directly, so C2 records the VID registers first, and C4b counts "blocked" lines |
| GSA mailbox command never answered | `gsa.c` times out after 1 s and disables the mailbox until reload (Google's waits forever) |
| AoC watchdog / IOMMU fault storms | the AoC watchdog IRQ (SPI 116) is not requested by the bring-up driver; System MMU fault lines are rate-limited |
| The AoC holds the AP awake or wakes MIF constantly (sensors at high rate) | non-wakeup USF channels for UI sensors; pause sensors when the screen is off |
| Firmware/driver mismatch after a vendor update | the UUID check refuses it; extract `aoc.bin` from the phone's own vendor partition with the matching kernel sources (checked offline for 14022723) |
| **Speaker damage** | `AUDIO-PLAN.md` section 4 limits apply unchanged: boost peak ≤ 2.5 A, `Analog PCM Volume` ≤ 6 for the top amp as earpiece and ≤ 10 for either amp with the DSP bypassed, `Digital PCM Volume` ≤ 657 for first sound, 1 kHz bursts of 1-2 s, ≤ 30 s without protection, mapping and calibration confirmed before tuning loads. Also AoC-specific: the amps take their PLL reference from the AoC's TDM BCLK, so the TDM link must run before an amp's `GLOBAL_EN` and the amp must be muted before the AoC stops TDM |
| Mic rails off: recordings are a burst then zeros | turn LDO20M, LDO19S, LDO20S on (ACPM ch 2) before the first capture |
| Sensor rails off when the registry loads: only virtual sensors until the AoC restarts | LDO7S then LDO5S on before loading the registry |
| Under-display light/proximity (TMD3719) never converts | send the display state (panel on/off, brightness, refresh rate) to the AoC's display-info service at start and on every change |

---

## 5. Kernel and repo changes made

Kernel branch `omandroid-aoc` (`L/`), on `omandroid` @ `7b0f8b5d1`. It
merges cleanly into `omandroid-int` @ `741b6ed1d` (`git merge-tree`).

| Commit | What | Default |
|---|---|---|
| `58e9fb0a2` dt-bindings: soc: google: add the gs201 GSA mailbox | `google,gs201-gsa` | - |
| `21aa277d2` soc: google: add a GSA mailbox driver | `drivers/soc/google/gsa.c` (`CONFIG_GOOGLE_GSA`): Google's register protocol, 1 s timeout per command, then the mailbox is refused; debugfs `sjtag_status`, `aoc_state` (`aoc_query=1`) | module |
| `aed858b94` arm64: dts: exynos: google: gs201: add the GSA mailbox | `gsa@17c90000`, SPI 363 | `disabled` |
| `372cdfcb5` merge of `omandroid-fingerprint` @ `5a9cf359f` | the Trusty driver commits, shared with fingerprint (same commits, so both branches merge into int together) | modules, node disabled |
| `477a82e16` arm64: dts: ... gs201: add Trusty | cherry-pick of `0c28d9948` (identical hunk; merges cleanly with fingerprint) | `disabled` |
| `18c468053` dt-bindings: ... gs201-gsa: add the GSA's S2MPU | optional second range | - |
| `6b3275d37` soc: google: gsa: load and start AoC firmware | `gsa_load_aoc_fw_image()` (cmd 90 under a GSA wakelock, GSA S2MPU CTRL0 = 0 for the load and restored after, 32-bit DMA mask), `gsa_send_aoc_cmd()` (Trusty `hwmgr.aoc`, or cmd 91 with `aoc_cmd_mbox=1`), `gsa_get_device()`; debugfs `aoc_state_tz`, `s2mpu_ctrl0` (`s2mpu_probe=1`) | - |
| `36319e05e` arm64: dts: ... gs201: add the GSA's S2MPU range | `0x17c60000` | - |
| `d239d411e`, `2fcba2704` AoC System MMU binding and driver | `gs201-aoc-sysmmu.c` (`CONFIG_GS201_AOC_SYSMMU`): first-level table of 1 MiB sections from the windows it is given, VID 0, stall on fault, stock QoS/TLB setup, fault lines with VID and AxID; touches no register until the AoC driver calls it with BLK_AOC on; `empty=1` = negative test | module |
| `5caf0d303`, `0610de752` AoC binding and boot driver | `gs201-aoc-boot.c` (`CONFIG_GS201_AOC_BOOT`): debugfs `info`, `power`, `blk`, `load`, `start`, `control`, `shutdown` (section 7) | module |
| `3a71f0471` soc: google: add the gs201 AoC supplies over ACPM | `gs201-aoc-rails.c` (`CONFIG_GS201_AOC_RAILS`): reads S2MPG12/13 CHIPID and the five LDOs; sets their enable bits only with `enable=1`, never a voltage | module, no DT |
| `973b54b71` arm64: dts: ... gs201: add the AoC and its System MMU | `sysmmu@1a090000` (SPI 118), `aoc@181d0000` | `disabled` |
| `0e5c2082d`, `edfb4e5df`, `aa453aaee`, `c868f906b` C4b diagnostics | System MMU "lost" check and reprogram, VID 0 fault registers in the dump; the AoC node gains the PCU (`0x19a00000`) and the watchdog interrupt (SPI 116); the boot driver logs S2MPU, PCU reset control, System MMU, IPC words and ramdump breadcrumbs around `START`, re-applies a cleared S2MPU/System MMU setup first (`reapply=1`), and gains `cmd` (any GSA AoC command) and `ramdump` (hex dump) | - |
| `01be75e8a`, `d9cc04ae4`, `7bea582c5` AoC mailbox view | the AoC node gains the three mailbox ranges; debugfs `mbox` (and `diag_mbox=1` around start) reads masks, raw status and shared registers, AP side | - |
| `deb7b47bd` gate the PCU read, no lock in read-only views | after the PCU read aborted (C4b-2 first try) | - |
| `2f785843b`, `615b5188a` unload | `gsa_unload_aoc_fw_image()` (cmd 92 or Trusty `UNLOAD_IMG`); debugfs `unload` (shutdown, unload, System MMU off, as `aoc_take_offline()`) | - |

Build in `out-aoc`: release `7.3.0-rc6-omandroid-push1-00079-g615b5188a148`
(kernel, modules tarball, images). The new C files build with `W=1` and no
warnings and pass `checkpatch.pl`; the DTB has only the existing framebuffer
`unit_address_vs_reg` warning; both overlays apply with `fdtoverlay`. Not
run: `dt_binding_check` (no dtschema on this host).

**Module dependencies:** with `CONFIG_GOOGLE_GSA_TRUSTY=y`, `gsa.ko` needs
the Trusty modules, so `modprobe gsa` also loads `trusty-core`,
`trusty-virtio` and `trusty-ipc` (a blacklist does not stop dependencies).
With the `/trusty` node disabled, as in all AoC overlays, they bind to
nothing and never call into the secure world.

Repo:

- `kernel/configs/omandroid.config`: `CONFIG_GOOGLE_GSA=m`,
  `CONFIG_GOOGLE_GSA_TRUSTY=y`, `CONFIG_GS201_AOC_SYSMMU=m`,
  `CONFIG_GS201_AOC_BOOT=m`, `CONFIG_GS201_AOC_RAILS=m`.
- `device/cheetah/overlays/aoc-gsa-test.dtso` (C1), `aoc-boot-test.dtso`
  (C2-C4: GSA, AoC System MMU, AoC node with cheetah's board id `0x30301`
  and revision `0x10000`).
- `tools/aoc-stage`: runs C2-C4 with the log streamed to `logs/` first,
  optional hardware watchdog, the hang marker, `--pstore`.

---

## 6. Stages

| Stage | What | Writes to hardware | Risk | Needs |
|---|---|---|---|---|
| C0 | offline: firmware header, IOMMU windows, UUID check | none | none | **done** |
| C1 | GSA mailbox: `sjtag_status`, `aoc_state` (cmd 91) | mailbox only | low | **passed** |
| **C2** | read-only: `aoc_req` and acknowledge, GSA AoC state, chip id, GSA S2MPU CTRL0 (under a GSA wakelock), carve-out not System RAM; if BLK_AOC is on, the AoC System MMU registers (which VIDs exist, which are already on) and the AoC S2MPU CTRL0 | GSA wakelock commands | low | this branch, `aoc-boot-test` |
| C2p | only if C2 found BLK_AOC off: `aoc_req` = 1, then C2's reads | `aoc_req` | low | C2 |
| **C3** | read-only: S2MPG12/13 CHIPID and the five AoC LDOs over ACPM channel 2 | none | low | ACPM loaded (int) |
| **C4a** | load: power, AoC S2MPU CTRL0 = 0, System MMU windows on VID 0, body into the carve-out, GSA authentication (90), parameters; state must become "loaded" | S2MPUs, System MMU, carve-out | medium | C2, C3 |
| **C4b** | start: 91 `START`; control block within 5 s, ~82 services, no "blocked" lines | AoC runs | **high** (first run of the firmware) | C4a |
| C4c | `unload`, then C4a/C4b again: proves a clean restart | GSA | medium | C4b |
| C4n | negative test (separate boot): `gs201_aoc_sysmmu empty=1`, C4a, C4b: the AoC must fault at once with "blocked READ at 0x98..." on VID 0 and never come up; proves its traffic goes through this System MMU on VID 0 | as C4 | medium | C4b passed |
| C5 | AoC core port (mailboxes, services, char devices) | - | - | C4b |
| C6 | first sensor reading: `gs201_aoc_rails enable=1` (LDO7S then LDO5S), registry load, accelerometer samples; then rotation | PMIC LDO bits | medium | C5, USF client |
| C7 | microphones: mic rails, capture EP1 (PCM 8) | PMIC, AoC | low | C5, `aoc_alsa` |
| C8 | first sound: top amp alone, DSP bypassed, section 4 limits | amps, AoC TDM | **speaker damage** | `AUDIO-PLAN.md` A2/A3, C7 |
| C9 | protection firmware + calibration, UCM, PipeWire | amps | medium | `AUDIO-PLAN.md` A7 |
| C10 | crash recovery: ACPM ch 13 doorbell, AoC watchdog | AoC PCU watchdog | medium | C5 |

The order inside C4 follows stock (section 0.1). C4n comes after a working
C4b on purpose: before the firmware runs there is no AoC traffic to test,
and a firmware that runs with a wrong VID would reach physical memory
untranslated. If C4b shows "blocked ... VID n" with n not 0, stop: rerun C4
with `gs201_aoc_sysmmu vids=<1<<n>` after a reboot.

---

## 7. Runbook

From the omandroid repo, phone in Arch over USB. Overlays as in
`HAPTICS-TORCH-PLAN.md` 4. **Never use `devmem` for any of this.** The
phone's `/usr/local/bin/devmem` is our `tools/devmem.c`, with usage
`devmem ADDRESS [VALUE]`: a second argument WRITES (`devmem ADDR 32` writes
0x20). All AoC registers are read from the kernel; PMU registers must not be
read from user space at all (`GPU-PLAN.md` incident).

### C1: GSA mailbox status queries (read-only): passed

Overlay `aoc-gsa-test`, `modprobe gsa` then `cat
/sys/kernel/debug/17c90000.gsa/sjtag_status`, and `modprobe gsa aoc_query=1`
then `cat …/aoc_state`. Results in section 0.1.

### Build and install for C2-C4

On the integration kernel (merge `omandroid-aoc` again: it now carries the
Trusty commits, the System MMU, boot and rails drivers):

```sh
export KERNEL_DIR=$HOME/android/mainline/wt-int KERNEL_OUT=$HOME/android/mainline/out-int
O=$KERNEL_OUT D=$O/arch/arm64/boot/dts/exynos/google/gs201-cheetah.dtb
git -C $KERNEL_DIR merge --no-edit omandroid-aoc
bin/omandroid kernel && bin/omandroid modules && bin/omandroid initramfs && bin/omandroid images
tools/phone-ssh 'printf "blacklist gsa\nblacklist gs201_aoc_sysmmu\nblacklist gs201_aoc_boot\nblacklist gs201_aoc_rails\n" > /etc/modprobe.d/omandroid-aoc-bringup.conf'
cp "$D" "$D.default"
$O/scripts/dtc/dtc -q -I dts -O dtb -o out/aoc-boot-test.dtbo device/cheetah/overlays/aoc-boot-test.dtso
$O/scripts/dtc/fdtoverlay -i "$D.default" -o "$D" out/aoc-boot-test.dtbo   # add display-decon-test etc. as usual
bin/omandroid images && bin/omandroid modules-push && bin/omandroid push
tools/phone-ssh 'lsmod | grep -cE "^(gsa|gs201_aoc|trusty)"'     # expect 0
```

Rollback for every stage below: reboot (nothing persists; the PMIC keeps a
rail that C6 turns on until a cold boot), or the default DTB:
`cp "$D.default" "$D"; bin/omandroid images && bin/omandroid push`.

### C2: read-only probes

```sh
tools/aoc-stage --watchdog c2
```

- **Does:** loads `gsa aoc_cmd_mbox=1 s2mpu_probe=1` (pulls in the Trusty
  modules, which bind to nothing), `gs201_aoc_sysmmu`, `gs201_aoc_boot`.
  None of them touches an AoC register at probe. Then reads: `aoc_req` and
  `aoc_req + 0x40` (acknowledge), GSA AoC state (cmd 91), the chip id block,
  the GSA S2MPU CTRL0 (GSA wakelock acquire, read, release), the carve-out
  check against `/proc/iomem`. Then `blk`: only if the acknowledge is set,
  the AoC System MMU registers and the AoC S2MPU CTRL0.
- **Expect:**
  - `gsa aoc state 0 (inactive)`;
  - `chip product 0x9855000`, `revision 0x10` (stock: "CPU[GS201]B0
    CPU_REV[0x10]", `R/dmesg.txt:397`), board `0x30301/0x10000`;
  - "carve-out 94000000-96ffffff: not System RAM";
  - GSA S2MPU `CTRL0 0x…` (record it; bit 0 set = blocking);
  - `aoc_req`/ack: record both. If BLK_AOC is on, the kernel log has
    `blk: version 0x… (v8.x) … capa1 0x… (8 VIDs)` and one line per VID:
    **record which VIDs are enabled and their table addresses**. All VIDs off
    (ctrl bit 0 = 0) is expected before the AoC was ever loaded.
- **Stop:** any abort or hang (the watchdog resets the phone; then
  `tools/aoc-stage --pstore`); a `blk` line on a VID with a table already
  set (someone else programs this System MMU: report it before C4); the
  carve-out overlapping System RAM.
- **If BLK_AOC is off:** run `tools/aoc-stage --watchdog c2p` (one write:
  `aoc_req` = 1, then the same reads). Expect `aoc_req 1: ack 0x1`. A
  time-out ("aoc_req 1: ack 0x0 (timed out)") is a stop: the APM did not
  power the block.

### C3: the AoC rails, read-only

```sh
tools/phone-ssh 'lsmod | grep -c "^acpm_protocol"'   # 1 on int (the GPU uses ACPM)
tools/aoc-stage c3
```

- **Expect:** `S2MPG12 CHIPID 0x…` and `S2MPG13 CHIPID 0x…` (non-zero, not
  equal), then five lines `LDO… : ctrl 0x…, on|off, N mV`. Expected
  voltages: LDO20M, LDO19S, LDO20S and LDO7S 1800 mV (vsel `0x2c`), LDO5S
  2500-3300 mV. The stock DT marks the sensor rails `regulator-boot-on`, so
  LDO7S and LDO5S are probably on already; record the mic rails.
- **Stop:** an ACPM error or timeout; a voltage outside the stock ranges
  (the rail is then never enabled by the driver).
- Nothing is written. Enabling (`modprobe gs201_aoc_rails enable=1`) comes
  in C6/C7, not now.

### C4a: load (the AoC stays in reset)

```sh
tools/aoc-stage --watchdog c4a
```

- **Does:** copies `V/firmware/aoc.bin` to `/usr/lib/firmware/updates/aoc.bin`
  if the phone's copy differs (it is Google's file: never commit or publish
  it), writes and syncs the hang marker, then `echo aoc.bin > load`:
  1. GSA state must be "inactive";
  2. validates the image (signed, superbin, `fw_start` = carve-out base,
     IPC offset, six windows);
  3. `aoc_req` = 1 and the acknowledge;
  4. AoC S2MPU CTRL0 = 0 (logged before and after);
  5. System MMU: the six windows on VID 0 (logged one per line, then the
     registers again);
  6. copies the 21 MB body to `0x94000000`;
  7. GSA load (cmd 90): wakelock, GSA S2MPU CTRL0 = 0, load, CTRL0 restored,
     wakelock released;
  8. writes the parameter block at carve-out + `0x1600000`.
- **Expect:** "image 14022723-polygon (release), body 0x… bytes at
  0x94000000, IPC at +0x1600000, 6 windows"; "cmd 90: answer 0x8000005a err
  0"; "loaded; GSA AoC state 1 (loaded)".
- **Stop:**
  - `cmd 90 … err 1` (invalid args: the header address or the S2MPU),
    `err 2` (authentication failed: wrong or modified image);
  - "no answer in 10000 ms" (the GSA mailbox is then disabled until
    reboot);
  - a System MMU fault line already now (the AoC is still in reset and must
    not access anything).
  Report the log and reboot. The marker stays, so `c4a` refuses to run again
  until you have rebooted and removed `/var/lib/omandroid/aoc-bringup-started`.
- **Never** read the carve-out (`0x94000000`-`0x955fffff`) after this step:
  the GSA has locked it.

### C4b: start

```sh
tools/aoc-stage --watchdog c4b
```

- **Does:** power request, cmd 91 `START`, then polls the control block at
  carve-out + `0x1600000` for magic `0xa0c00a0c` (5 s), prints the firmware
  version and the service list, counts "blocked" lines.
- **Expect:** "AoC command 1: GSA state 2 (running)"; "firmware up: 82
  services" (stock: 82, `R/dmesg.txt:6042`); `control` shows `fw
  14022723-polygon` and names such as `audio_output_control`,
  `com.google.usf`, `com.google.chre`; **0 "blocked" lines**. The hang
  marker is removed.
- **Stop:**
  - any "blocked READ/WRITE at … (VID n …)": note n and the address, then
    `tools/aoc-stage stop`. With n other than 0, see section 6;
  - "no control block after 5 s": the firmware did not come up; `stop`,
    then report the log;
  - a hang: the watchdog resets the phone; `tools/aoc-stage --pstore`.
- The AoC now runs without its AP-side services (no mailbox driver yet): it
  may log nothing or wait for the AP. Leave it running at most a few minutes,
  then `tools/aoc-stage stop` (`GSA_AOC_SHUTDOWN`, expect "state 1
  (loaded)"), or reboot.

### C4b-2: diagnose the start (one boot)

**First try (int 00214, `c868f906b`): synchronous external abort** in
`aoc_diag+0xdc` during C2's `blk` read. `llvm-objdump` puts `+0xdc` on the
load from `ab->pcu + 0`: the **PCU at 0x19a00000 aborts** with BLK_AOC on
and the AoC in reset (the S2MPU and System MMU reads just before it were
fine, as in the first C2). The `blk` task died holding the driver's lock,
so load and start blocked. Fixed in `deb7b47bd`: the PCU is read only with
`diag_pcu=1` from its own `pcu` file, the ramdump header only with
`diag_ramdump=1` or from the `ramdump` file, the System MMU fault registers
only with `gs201_aoc_sysmmu dump_faults=1`; read-only views take no lock,
and optional reads around start run outside it. `blk` and the start
diagnostics now read only what has already read fine on the phone.

Rebuild int with `omandroid-aoc` @ `deb7b47bd` (merge again) and push as
before, same overlay. Then:

```sh
tools/phone-ssh 'rm -f /var/lib/omandroid/aoc-bringup-started'
tools/aoc-stage --watchdog c2
tools/aoc-stage --watchdog c4a
tools/aoc-stage diag          # after the load, before the start
tools/aoc-stage --watchdog c4b
tools/aoc-stage diag
```

Read, in the kernel log (prefixed blk/before/after/5 s):

- `aoc s2mpu CTRL0`: 0 after our load, or 0x5 again (a block reset).
- the System MMU lines: global ctrl bit 0 and VID 0 ctrl bit 0 set, table at
  our address, `int` status.
- "AoC S2MPU CTRL0 is 0x… again, setting 0" or "System MMU setup was
  cleared, programming it again": printed by the re-apply before `START`.
- `ipc …`: 0a0cda7a … (our parameters) or a0c00a0c … (the firmware's).
- "AoC watchdog interrupt": the firmware ran and stopped.

Then the ramdump header, one read on its own (never read before; it is
ordinary DRAM outside the locked body, and Google's driver reads it after a
crash):

```sh
tools/aoc-stage --watchdog ramdump
```

- **Expect:** a hex dump. "AOCDUMP" at offset 0 and non-zero words at 0x318
  (the breadcrumbs) mean the firmware ran; all zeros mean it never wrote
  there.
- **Stop:** an abort (the watchdog resets the phone): the region is
  protected; never read it again.

Then, only if `START` gave state 4 and nothing came up:

```sh
tools/aoc-stage --watchdog release    # GSA_AOC_RELEASE_RESET (5)
tools/aoc-stage diag
tools/aoc-stage stop
```

- **Expect (if this is it):** state 2 (running), "firmware up: 82 services".
- **Stop:** any "blocked … VID n", the watchdog interrupt, or an unexpected
  state (record it). `stop` returns the AoC to "loaded"; a reboot clears
  everything.

The PCU stays unread: it aborts with the AoC in reset. If everything above
is inconclusive, a later step reads it once **after** a start that left
state 4, with `echo 1 > /sys/module/gs201_aoc_boot/parameters/diag_pcu`
and `cat /sys/kernel/debug/aoc/pcu`, armed watchdog, as the last action of
a boot.

Send the logs (`logs/aoc-*-diag.log`, `-c4b.log`, `-ramdump.log`,
`-release.log`).

### C4t: start through Trusty (next)

Rebuild int with `omandroid-aoc` @ `7bea582c5` (merge again; adds the
mailbox view) and push with **both** overlays, `aoc-boot-test` and
`fingerprint-trusty` (enables `/trusty`), plus the usual ones. The Trusty
modules stay blacklisted (`omandroid-fingerprint.conf`, or add
`blacklist trusty_core/trusty_log/trusty_ipc/trusty_virtio` to
`omandroid-aoc-bringup.conf`). Note: `modprobe gsa` loads `trusty_core` and
`trusty_ipc` as dependencies, so load Trusty first, on purpose.

```sh
tools/phone-ssh 'rm -f /var/lib/omandroid/aoc-bringup-started'
tools/aoc-stage --watchdog trusty        # FINGERPRINT-RESEARCH.md F2, the first SMCs into Trusty
tools/aoc-stage --watchdog --trusty c2   # gsa without aoc_cmd_mbox: state via hwmgr.aoc
tools/aoc-stage mbox                     # baseline: AoC mailboxes, AP side (read-only)
tools/aoc-stage --watchdog c4a           # load: mailbox 90, as stock
tools/aoc-stage --watchdog c4b           # START through Trusty hwmgr.aoc
tools/aoc-stage diag; tools/aoc-stage mbox; tools/aoc-stage ramdump
tools/aoc-stage stop                     # SHUTDOWN through Trusty (back to "loaded")
```

- **trusty, expect** (stock `R/dmesg.txt:737-890`): "trusty version:
  Project: cloudripper …", "selected api version: 5" (or lower),
  `/dev/trusty-ipc-dev0`, "trusty_ipc virtio0: is online".
  **Stop:** a hang (watchdog), "failed" lines, no `trusty-ipc-dev0`.
- **c2 --trusty, expect:** `gsa aoc state 0 (inactive)` through Trusty;
  dmesg "TZ: com.android.trusty.gsa.hwmgr.aoc connected" (stock prints the
  same, `R/dmesg.txt:5886`). **Stop:** "TZ: connect failed" (the service is
  not there: report).
- **c4a, expect:** as before, state 1 (loaded).
- **c4b, expect:** "AoC command 1 (Trusty): 2", "GSA state 2 (running)",
  then "firmware up: 82 services", `control` with `fw 14022723-polygon`.
  `mbox` may show bits in `intsr1` (the AoC's doorbells) and the ramdump
  header may gain breadcrumbs. **Stop:** state 4 again (then the secure
  setup is not the answer: report), any "blocked" line, the watchdog
  interrupt.
- If it comes up but stalls later, or does not come up with Trusty: C4b-3
  below, with the rails on before the load.
- Rollback: `tools/aoc-stage stop`, or reboot.

The mailbox view (`mbox`) has not been read on the phone yet: it reads the
AP side of three APM-domain mailboxes, the same kind of block as the
AP-to-APM mailbox ACPM uses every boot. If it aborts, drop it (the
watchdog resets the phone).

### C4b-3: rails first (separate boot, if C4t starts the A32 but no control block appears)

```sh
tools/phone-ssh 'rm -f /var/lib/omandroid/aoc-bringup-started'
tools/aoc-stage --watchdog trusty
tools/aoc-stage --watchdog --trusty c2
tools/aoc-stage rails         # LDO7S, LDO5S and the mic LDOs on, stock voltages
tools/aoc-stage --watchdog c4a
tools/aoc-stage --watchdog c4b
tools/aoc-stage diag; tools/aoc-stage mbox
```

- **Expect:** "LDO… : enabled, ctrl now 0xac" (LDO7S; LDO5S 0xbc, the mic
  rails 0xec), then the read-back "on". Rails stay on until a cold boot
  (stock keeps them on all the time).

### C4c: clean restart (optional, after C4b)

```sh
tools/phone-ssh 'echo 1 > /sys/kernel/debug/aoc/unload; cat /sys/kernel/debug/aoc/info'
tools/phone-ssh 'rm -f /var/lib/omandroid/aoc-bringup-started'
tools/aoc-stage --watchdog c4a && tools/aoc-stage --watchdog c4b
```

- **Expect:** "AoC unload (mailbox): 0", "unloaded; GSA AoC state 0
  (inactive)", then the same C4a/C4b results as the first time.
- **Stop:** unload refused or failing: reboot instead.

### C4n: negative test (separate boot, after C4b passed)

```sh
tools/phone-ssh 'modprobe gsa aoc_cmd_mbox=1 s2mpu_probe=1; modprobe gs201_aoc_sysmmu empty=1; modprobe gs201_aoc_boot'
tools/aoc-stage --watchdog c4a && tools/aoc-stage --watchdog c4b
```

- **Expect:** "empty table: every AoC access will fault"; C4a as before (the
  AoC is in reset); C4b: "blocked READ at 0x98…" or similar on **VID 0**
  right after `START`, and "no control block after 5 s". That proves the
  AoC's traffic goes through this System MMU on VID 0.
- Then `tools/aoc-stage stop` and reboot.
- **Stop:** the firmware comes up anyway, with no "blocked" lines: its
  traffic does not go through VID 0 of this System MMU. Do not run the AoC
  again until that is understood.

---

## 8. Open questions

1. Is BLK_AOC on at hand-off (C2 `aoc_req` acknowledge)?
2. Which System MMU VIDs exist and are any already programmed (C2 `blk`)?
   Expect 8 VIDs (VM support), all off, and AoC traffic on VID 0 (C4n).
3. Who programmed `sysmmu_asoc` on stock? Older Google AoC drivers map the
   same windows into the AoC's IOMMU domain from the kernel, so the
   non-secure table is the one that matters; C4b confirms it.
4. GSA and AoC S2MPU CTRL0 at hand-off (C2): blocking (bit 0 set) is
   expected for the GSA one.
5. Are the mic LDOs on at hand-off (C3)? The sensor LDOs are
   `regulator-boot-on` in the stock DT.
6. Does the firmware need anything from the AP before it publishes its
   control block (C4b without a mailbox driver)?
7. Is the factory sensor calibration in `persist:/sensors/registry` intact
   on this phone (read-only, as `speaker.cal` was read)?
