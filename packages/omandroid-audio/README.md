<!-- SPDX-License-Identifier: MIT -->
# omandroid-audio

The Pixel 7 Pro's speaker and microphones go through the AoC, the audio and
sensor DSP, whose ALSA card is `aoc-snd-card`. This package makes them a
normal PipeWire speaker ("Built-in Audio Speaker") and microphone ("Built-in
Audio Microphone"), and runs the two CS35L41 speaker amplifiers with Cirrus's
protection firmware and the phone's factory calibration, as stock Android does.

| File | What |
|---|---|
| `omandroid-speaker-protection` + `.service` (system, **not enabled by the package**) | loads the amplifier driver, mutes both amplifiers at once, checks the kernel's volume limits, the firmware and the calibration, loads the protection firmware into both DSPs, writes the factory calibration from `persist:/audio/speaker.cal` (read with debugfs, read-only) into their `CAL_*` controls, routes the DAC through the DSP, then unmutes. Any failure leaves both muted. Hang-safe: a marker keeps the amplifiers off on the boot after a hang. `status` reports the DSP state (no calibration values), `mute` mutes |
| `/etc/omandroid/speaker.conf` | the amplifiers' levels: digital ≤ 657 (-20 dB), analog ≤ 10 in this stage |
| `modprobe.d/omandroid-audio.conf` | blacklists `snd_soc_cs35l41_spi`, so the card only comes up through the service |
| UCM2 `conf.d/aoc-snd-card`, `Google/cheetah/HiFi.conf` | HiFi verb: Speaker = AoC EP6 to TDM 0 (the amplifiers), Mic = AoC EP1 from the built-in microphones; PCMs found by id. Touches no amplifier control, so PipeWire uses software volume |
| WirePlumber `51-omandroid-aoc.conf` | no mmap and 4 × 20 ms periods for the AoC PCMs (as the stock HAL), names for the card and its nodes |

The protection firmware and the per-speaker tunings are Google's and are not
shipped: `tools/extract-vendor-firmware` copies them from the user's own
factory image to `cirrus/cs35l41-dsp1-spk-prot-cheetah{.wmfw,-top.bin,-bottom.bin}`.
The calibration never leaves the phone.

Needs the AoC running (`omandroid-aoc.service` in omandroid-device-cheetah)
and a kernel with the AoC sound card and its speaker limits. Bring-up:
`device/cheetah/AOC-PLAN.md`, stage C8.
