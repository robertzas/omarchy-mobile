<!-- SPDX-License-Identifier: MIT -->
# omandroid-audio

The Pixel 7 Pro's speaker and microphones go through the AoC, the audio and
sensor DSP, whose ALSA card is `aoc-snd-card`. This package makes them a
normal PipeWire speaker ("Built-in Audio Speaker") and microphone ("Built-in
Audio Microphone"), and runs the two CS35L41 speaker amplifiers with Cirrus's
protection firmware and the phone's factory calibration, as stock Android does.

| File | What |
|---|---|
| `omandroid-speaker-protection` + `.service` (system, **not enabled by the package**) | loads the amplifier driver (or, when it is already bound, rebinds both amplifiers: a chip reset, so `systemctl restart` recovers a stuck DSP), mutes both at once, holds them out of runtime suspend (hibernation breaks the stock firmware), checks the kernel's volume limits, the stage's ceilings, the firmware and the factory calibration (`persist:/audio/speaker.cal` via debugfs, read-only), loads the protection firmware, writes `CAL_*` into both DSPs and reads it back, routes the DAC through the DSP, checks health (held awake, DSP controls present, no amplifier error in the kernel log), and only then unmutes. Any failure leaves both muted; a hang marker keeps the driver alone on the next boot. `status`, `health`, `monitor` and `verify` read the DSPs' state (coil temperature, CSPL state and errors, heartbeat), never the calibration values; `mute` mutes |
| `omandroid-speaker-watch.service` | started with it and bound to it: mutes both amplifiers on an amplifier error in the kernel log (CSPL error, failed wake, failed resume), an amplifier no longer held awake, a level above the ceilings, or, during playback, a DSP not running the protection firmware with the calibration applied; mutes too when it stops. Optionally writes stock's media delta at stream start |
| `udev.rules` | holds the amplifiers awake from the moment the driver binds |
| `/etc/omandroid/speaker.conf` | stage (c8 or c9), the amplifiers' levels (per amplifier too), the media delta switch |
| `modprobe.d/omandroid-audio.conf` | blacklists `snd_soc_cs35l41_spi`, so the card only comes up through the service |
| UCM2 `conf.d/aoc-snd-card`, `Google/cheetah/HiFi.conf` | HiFi verb: Speaker = AoC EP6 to TDM 0 (the amplifiers), Mic = AoC EP1 from the built-in microphones; PCMs found by id. Touches no amplifier control, so PipeWire uses software volume |
| WirePlumber `51-omandroid-aoc.conf` | no mmap and 4 × 20 ms periods for the AoC PCMs (as the stock HAL), software volume only, names for the card and its nodes |

The protection firmware and the per-speaker tunings are Google's and are not
shipped: `tools/extract-vendor-firmware` copies them from the user's own
factory image to `cirrus/cs35l41-dsp1-spk-prot-cheetah{.wmfw,-top.bin,-bottom.bin}`, and
stock's media deltas to `cirrus/cs35l41-cheetah-{top,bottom}-media-delta.txt`.
The calibration never leaves the phone.

Needs the AoC running (`omandroid-aoc.service` in omandroid-device-cheetah)
and a kernel with the AoC sound card and its speaker limits. Bring-up:
`device/cheetah/AOC-PLAN.md`, stages C8, C8f and C9. The kernel should also carry `cirrus,dsp-no-hibernate`
on both amplifiers (branch `omandroid-audio-amp`); the service holds them awake
either way.
