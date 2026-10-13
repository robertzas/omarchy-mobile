<!-- SPDX-License-Identifier: MIT -->
# AoC speaker tuning (C10-tuning): research, design and runbook

Status (2026-10-12): **research and design only; nothing has run on the
phone.** Static analysis of the stock libraries from the user's own factory
image, the AoC firmware's strings and Google's GPL AoC driver. Follows
`AOC-PLAN.md` C9 ("C10-tuning"), which another agent owns; this file does
not change it. Nothing here goes into `packages/omandroid-audio` until the
runbook's read-only steps have passed and the package owner takes it.

Path abbreviations as in `AOC-PLAN.md`: `V/` is the extracted stock vendor
tree (`~/android/omandroid/vendor/google/cheetah/proprietary/vendor`), `GA/`
Google's GPL AoC driver (`G/google-modules/aoc`), `L/` our kernel
(`~/android/mainline/wt-aoc`).

**Rules for this work.** No Google binary, decompiled code, preset file,
coefficient image or recorded tuning message is ever committed or pasted
into a log quote. Logs quote command IDs, block and component numbers,
sizes, return codes and SHA-256 hashes only. All tuning data is produced on
the phone from the user's own vendor files and lives under root-only
directories.

---

## 1. Bottom line

- Stock media on the speaker runs through **Waves MaxxAudio on the AoC**:
  the effect's code is in `aoc.bin` (the "MAM" chain: MaxxBass, MaxxVolume,
  leveler, EQs), and Android only *configures* it. The configuration is
  computed on the application processor by Waves' host library
  (`libmahalcontroller.so` with `libAlgFx_HiFi3z.so`, the coefficient
  converter) from `V/etc/waves_preset.mps` and `V/etc/waves_config.ini`,
  and sent to the AoC as **bulk parameter writes to the speaker mixer
  block (16), component 2 (Waves)** over `/dev/acd-audio_output_tuning`
  plus `/dev/acd-audio_bulk_tx`/`_rx`.
- The AoC side of that protocol is plain and documented by Google's GPL
  header (`GA/aoc-interface-gs201.h`): `CMD_AUDIO_OUTPUT_SET_PARAMETER_BULK`
  (0x00d2) and `CMD_AUDIO_OUTPUT_SET_GET_PARAM_BULK` (0x00d5). We can
  speak it from userspace with no kernel change.
- The payloads are Waves' own format and are not worth decoding. The
  practical way to get stock's sound is to **run the two Waves host
  libraries, unmodified, from the user's own image** in a vendor-chroot
  profile (the same approach as GNSS and fingerprint), behind a small
  helper of ours, and to let a Python daemon of ours carry their buffers
  to the AoC. A replay-only daemon (no Google code at run time) may follow
  if the recorded exchanges turn out to be deterministic.
- No licence or key check is visible on either side (section 2.6); the
  host libraries need only bionic's `libc`, `libm`, `libdl` and `liblog`.
- **"AoC Speaker Mixer ASP Mode"** is the Waves component's own state on
  the speaker block (`ASP_OFF`, `ASP_ON`, `ASP_BYPASS`, `ASP_GROUND`), and
  our kernel already exposes it. Stock never writes it from
  `mixer_paths.xml`; the amplifier library only reads it (`ASP_ON` means
  Waves handles the orientation's left/right swap, so the amplifiers
  don't). It is also our rollback lever, if `ASP_BYPASS` proves to take
  Waves out of the path (T3).
- Waves will raise the average level going into the amplifiers. It does
  not change the amplifier gains, so the C9 ceilings and the protection
  watchdog stay exactly as they are, and tuning comes **after** C9 passes
  (section 4).

---

## 2. Facts

Confidence: **H** = read directly from GPL source, a config file, or
unambiguous code; **M** = inferred from code we read in part, consistent
with the other evidence; **L** = a guess to test.

### 2.1 Who does what on stock

| Piece | Role | Conf. |
| --- | --- | --- |
| `audio_waves_aoc.so` (HAL external module, argument `Sink=SPK:1`) | Google's glue: `dlopen`s `/vendor/lib64/libmahalcontroller.so`, picks the preset from the audio device, mode and battery/thermal throttle state, feeds orientation, volume and proximity, and gives Waves a "buffer sender" that hands each buffer to the platform library | H |
| `libmahalcontroller.so` (Waves) | Parses the `.ini` and `.mps`, keeps the preset state, and emits DSP messages through the sender (its own sources name the protocol file `MaAocTuningProtocol`) | H |
| `libAlgFx_HiFi3z.so` (Waves, path from the `.ini`'s `[COEFS_CONVERTER_SETTING]`) | Turns preset parameters into the coefficient images of the HiFi3z build that runs on the AoC (same "CFloatMAM_Google" algorithm build string as in `aoc.bin`) | H |
| `audio.platform.aoc.so` (Google) | Owns the AoC tuning devices and frames the AoC commands (section 2.2); also sends other tuning (voice, recording `.gatf`) | H |
| `aoc.bin` | Runs the Waves chain in the speaker mixer (`asp_waves.cc`, "Mixer %d active (WAVES - LL)", "(bypass)", "Could not configure WAVES") | H |

Only bionic is needed by the two Waves libraries: `libmahalcontroller.so`
and `libAlgFx_HiFi3z.so` link `libc`, `libm`, `libdl` and `liblog` and
nothing else (H, `readelf -d`). `audio_waves_aoc.so` itself is not usable
outside the HAL (it links the primary HAL, libbase, libtinyalsa, the
spatializer and thermal/battery services).

### 2.2 The AoC tuning protocol (H unless marked)

Devices (all three opened by stock; `aoc_char_dev` allows one opener
each, so whoever owns them owns tuning):

| Device | AoC service (seen in our C5 service list) | Use |
| --- | --- | --- |
| `/dev/acd-audio_output_tuning` | 7 `audio_output_tuning` | commands out, replies in |
| `/dev/acd-audio_bulk_tx` | 22 `audio_bulk_tx` | the payload of a bulk write (opened non-blocking, write-only) |
| `/dev/acd-audio_bulk_rx` | 23 `audio_bulk_rx` | the payload of a bulk reply |

Service 8 `audio_output_tuning_ext` exists too; the stock libraries never
open it (L: purpose unknown).

Commands are the GPL header's structures; every one starts with
`CMD_HDR` = `{u8 type = 0 (command), u8 counter, u16 length, u16 id,
i16 reply}`, packed, little-endian:

| Command | ID | Size | Fields after the header |
| --- | --- | --- | --- |
| `SET_PARAMETER` | 0x00d1 | 18 | `u8 block, u8 component, u32 key, u32 value` |
| `GET_PARAMETER` | 0x00d3 | 18 | same; the reply carries `value` |
| `SET_PARAMETER_BULK` | 0x00d2 | 22 | `u8 block, u8 component, u32 tx_offset = 0, u32 tx_address = 0, u32 tx_size` |
| `SET_GET_PARAM_BULK` | 0x00d5 | 26 | `u8 block, u8 component, u16 tx_offset = 0, u16 rx_offset = 0, u32 tx_address = 0, u32 rx_address = 0, u16 tx_size, u16 rx_size = 0` |

(Input-side twins: 0x00e9 / 0x00ea / 0x00ed on `audio_input_*`.)

A bulk write, as stock does it:

1. Build the payload in a **16 KiB buffer** (16384 bytes for output,
   5120 for input), zero-padded after the used length; `tx_size` is the
   used length. Larger payloads are refused before anything is sent.
2. `write()` the whole 16 KiB buffer to `audio_bulk_tx`.
3. `write()` the command to `audio_output_tuning`.
4. A reader thread reads the reply from `audio_output_tuning` (and, for
   `SET_GET`, the returned payload from `audio_bulk_rx`); the caller waits
   on it. The `reply` field is the AoC's return code. The Waves module
   retries once on a timeout (-110).

Under one lock: stock never interleaves two bulk exchanges (H).

**Addressing for Waves on the speaker** (H from config, M for the joining
code):

- block **16**: `audio_platform_configuration.xml` gives the speaker back
  end `OUT_SPEAKER_BE_CFG` the interface `TDM_RX_0`, `block_id="16"`;
  `GA/alsa/aoc_alsa_hw.c` says "Sink 0-4 with block ID from 16-20"; the
  "AoC Speaker Mixer ASP Mode" control is block 16.
- component **2**: `xlate_id` maps `TUNING_COMPONENT_WAVES` to 2, and the
  platform library's built-in table gives the same default.
- `tuning_id="2"` on `OUT_SPEAKER_BE_CFG` is what the Waves sender logs
  as "tuning_id" next to the instance. It is the back end's tuning
  selector; for the speaker there is no playback `.gatf` in `V/etc/aoc/`
  (only `recording.gatf`, `smartfeature.gstf` and Fortemedia's voice
  `.dat` files), so Waves is the speaker's only AoC tuning (M).
- Waves instance **1** (`Sink=SPK:1`, `SPEAKER_INSTANCE = INSTANCE:1`).
  The instance travels inside the Waves payload, not in the AoC command
  (M).
- The Waves messages are exchanged as `SET_GET` bulk (the sender passes
  reply pointers and reads a status back) (M).

**ASP Mode** (H, `GA/alsa/aoc_alsa_ctl.c`, `aoc_alsa_hw.c`; present in
`L/`): "AoC Speaker Mixer ASP Mode" is `SET_PARAMETER`/`GET_PARAMETER`
with block 16, component 2, key 0, values 0-3 = `ASP_OFF`, `ASP_ON`,
`ASP_BYPASS`, `ASP_GROUND`. Reading it is a read-only `GET_PARAMETER`.
"Audio DSP State" reads `Idle`, `Playback` or `Telephony`.

### 2.3 When stock sends

- At start, the module creates the Waves controller with the `.mps`, the
  `.ini` and the sender, and asks for the host and `algfx` versions (H).
- Tuning goes out **only while the AoC DSP is in playback**: "skip to send
  tuning because dsp wasn't in playback mode", "trigger to update tuning
  when first track is running" (H for the strings, M for the exact
  trigger). So on stock the first moments of a stream on a fresh route
  play untuned.
- After an AoC restart the module calls the controller's DSP-wake entry
  and the state is sent again (M).
- Changes that resend: route/preset (custom action 258), orientation,
  volume (the module's "AMCS" part passes the stream volume into Waves'
  volume-dependent link laws), proximity and thermal/battery throttling
  (H for the hooks, M for which ones produce AoC traffic).

### 2.4 Presets and how they're picked (H, `V/etc/waves_config.ini`)

- Four presets, all on instance 1, 48 kHz: `SPEAKER_MUSIC` (output mode 1,
  sound mode 2), `SPEAKER_SAFE_MUSIC` (output mode 10, sound mode 2), and
  their `_THROTTLE` versions (sound mode 3).
- The output modes in the `.mps` are named "Internal Speaker" (1) and
  "Speaker Safe" (10); the sound modes are battery levels ("Music Battery
  High/Medium/Low", "SpeakerSafe Battery …"). So the throttled presets are
  the lower-power battery modes (M).
- Selection is Waves' "custom action 258", fed with Android's
  `(audio_devices_t, audio_mode_t, throttle state)` and matched against
  six cases in priority order. For us that reduces to:
  - media on the speaker (device `SPEAKER` 0x2, mode `NORMAL` or
    `RINGTONE`), throttle disabled or bypassed → `SPEAKER_MUSIC`;
  - the same with battery throttling enabled → `SPEAKER_MUSIC_THROTTLE`;
  - `SPEAKER_SAFE` (0x400000, Android's notification/alarm route) or any
    call mode → the `SAFE` presets.
- Orientation picks a **subtype** within the preset
  (`OST_SPEAKER = 0:12, 90:13, 180:12, 270:0|13`); the `.mps` names its
  subtypes Portrait, Landscape and Reverse Landscape. We pass the angle;
  the controller does the mapping.
- The `.mps` describes itself as a template/test file dated 2021-11-16;
  it is still what stock ships and uses (H).

Files the design reads, all from the user's image, never committed:
`vendor/etc/waves_preset.mps`, `vendor/etc/waves_config.ini`,
`vendor/lib64/libmahalcontroller.so`, `vendor/lib64/libAlgFx_HiFi3z.so`,
plus bionic and `liblog` from the system image.

### 2.5 Mixer controls stock sets on the speaker path that we don't

- `mixer_paths.xml` sets **no AoC-side processing control** for the
  speaker: its `speaker`/`speaker-post` paths are amplifier controls (boost
  limit, enables, the fast-use-case deltas), and `TDM_0_RX` format and
  routing we already set in UCM (C7d/C8). The only AoC "ASP Mode" it
  writes is the modem's ASRC (`ASP_ON`). (H)
- So what we lack is exactly the Waves configuration (and with it Waves'
  own left/right swap by orientation), not a forgotten control (H).
- The amplifier library reads "AoC Speaker Mixer ASP Mode" and treats
  `ASP_ON` as "Waves is active" (H): then it leaves the channel swap to
  Waves. Our speaker service must do the same when tuning is on.

### 2.6 Licence or key check

- No licence, serial, expiry, activation or signature strings in
  `libmahalcontroller.so`, `libAlgFx_HiFi3z.so` or `audio_waves_aoc.so`,
  and none in `aoc.bin` (zero matches for "licen"); the only device inputs
  the host side takes are the two config files (M: absence of strings is
  not proof).
- The firmware has an explicit failure path, "Could not configure WAVES",
  and logs the mixer's mode. If a hidden check existed, the expected
  symptom is that log line and a negative `reply`, with the mixer staying
  in bypass: audio still plays, flat. The AoC's own log
  (`/dev/acd-logging`, `AOCLOG=1`) is where to look (AGENTS.md: the AoC
  answers a rejected command with -1 and the kernel does not treat it as
  an error).
- Redistribution is the real constraint: these are Google's and Waves'
  binaries and data, so as with GNSS and fingerprint the user extracts
  them from their own image and we ship only our glue.

---

## 3. Design (proposal for `packages/omandroid-audio`; not built)

### 3.1 Pieces

```
 vendor chroot "waves" (read-only tree from the user's image)        host (Arch)
 ┌──────────────────────────────────────────────┐   stdin/stdout   ┌──────────────────────────────┐
 │ omandroid-waves-host (ours, C, bionic)        │ <──── frames ──> │ omandroid-speaker-tuning     │
 │  dlopen libmahalcontroller.so (Waves)         │                  │ (ours, Python, root, systemd)│
 │   └─ dlopen libAlgFx_HiFi3z.so (Waves)        │                  │  owns /dev/acd-audio_output_ │
 │  reads waves_preset.mps, waves_config.ini     │                  │  tuning, audio_bulk_tx/_rx   │
 │  no /dev, no network, no AoC access           │                  │  policy, triggers, allowlist │
 └──────────────────────────────────────────────┘                  └──────────────────────────────┘
```

1. **`omandroid-waves-host`**: a small bionic program of ours (MIT),
   built like the GNSS shim (`packages/omandroid-gnss/bionic`, NDK or an
   AOSP clang). It `dlopen`s Waves' controller at run time (nothing of
   Google's is linked at build time), creates and initialises it with the
   `.mps`, the `.ini` and a sender callback, and turns line commands from
   stdin (`route <device> <mode> <throttle>`, `orientation <deg>`,
   `volume <index>`, `dsp-wakeup`, `flush`, `version`) into the
   controller's API. Its sender writes each buffer as a frame
   (`instance`, length, bytes) to stdout and blocks for the reply frame
   (`status`, length, bytes) from stdin. It cannot touch the AoC: the
   chroot binds no `/dev/acd-*`.
2. **A `waves` profile** for `tools/extract-vendor-chroot` and
   `omandroid-vendor-chroot`: the two Waves libraries, the two config
   files and the runtime APEX's bionic, plus `liblog`. Built on the laptop
   from the user's factory image, installed by hand (like `gnss`).
3. **`omandroid-speaker-tuning`** (Python, `BindsTo=` and `After=`
   `omandroid-speaker-watch.service`, `After=omandroid-aoc.service`):
   - the only opener of the three AoC devices; implements section 2.2
     (16 KiB bulk buffer, command, reply, one retry on timeout, one
     exchange at a time);
   - **allowlist**: only `0x00d5`/`0x00d2` to block 16, component 2, and
     `GET_PARAMETER` of block 16 component 2 key 0; payload ≤ 16384;
     anything else from the helper is refused and logged, and the helper
     restarted;
   - **triggers**: speaker playback start (the speaker EPs' PCM `RUNNING`
     in `/proc/asound/card*/pcm*p/sub0/status` and "Audio DSP State" =
     `Playback`) → send the current route and orientation; orientation
     changes from `net.hadess.SensorProxy` (`ClaimAccelerometer`,
     `AccelerometerOrientation`; `normal` 0°, `bottom-up` 180°, `left-up`
     and `right-up` 90°/270°, which way round to be checked in T4), with a
     1 s hysteresis, only while playing; AoC restart (the AoC's
     `restart_count` or the online marker in `/run/omandroid/`) →
     `dsp-wakeup`; PipeWire sink volume → `volume` (phase 2);
   - **policy** from `/etc/omandroid/speaker.conf`:
     `OMANDROID_SPK_TUNING=off|throttle|music` (default `off`);
     `throttle` sends `SPEAKER_MUSIC_THROTTLE` (device 0x2, mode 0,
     throttle state 0), `music` sends `SPEAKER_MUSIC` (throttle 1);
   - **state for the watchdog**: writes `/run/omandroid/speaker-tuning`
     (`off`, `sending`, `active <preset> <angle>`, `failed <reason>`) and
     never sends while the watchdog's protection-verified stamp is absent;
   - **logs** command IDs, sizes, SHA-256 of payloads and AoC return codes
     only. An optional `--record DIR` keeps the exchanges under
     `/var/lib/omandroid/speaker-tuning/` (root, 0700) for T5's
     determinism check; never in `logs/`, never committed.
4. **Watchdog hooks** (for the package owner to decide): at stream start
   `omandroid-speaker-watch` reads ASP Mode; `ASP_ON` while the tuning
   state is not `active`, or `failed`, is a mute condition. With Waves
   active the watchdog must not apply its own left/right swap.

### 3.2 Later: replay without Google code at run time

If T5 shows that the bytes for a given (preset, angle) are the same on
every boot and do not depend on replies, the daemon can send recorded
exchanges itself and the chroot runs only at install time, to generate
them. Until then the live helper is the reference.

### 3.3 Not in scope

Thermal and battery throttling inputs (stock's BCL "BAACL" and skin
temperature), proximity-driven presets, the stereo spatializer and the
`SAFE` presets for notifications. `throttle` covers the cautious case.

---

## 4. Speaker protection (C9) and loudness

- Waves processes before the TDM link, so it changes **the signal**, not
  the amplifier gains. The amplifier ceilings (digital/analog, the
  kernel's `speaker_protection` limit) and the watchdog's rules stay
  exactly as C9 leaves them. Nothing in this design writes an amplifier
  control.
- Its leveler and loudness stages raise average level, and with it the
  power into the speakers. That is the point, and also why the coil
  temperature model must be trustworthy first: **C10 waits for C9 to pass
  at the levels it settles on** (C9d-2's temperature explanation and C9f
  real use). T4 runs at C8 levels so that it can start earlier.
- Order of trust: protection verified (stamp) → tuning daemon allowed to
  send → watchdog sees `active`. Tuning off is always safe: the AoC
  falls back to flat, the amplifiers are unchanged.
- First sends use `SPEAKER_MUSIC_THROTTLE`, the lower-power battery mode,
  and a low sink volume; `SPEAKER_MUSIC` only after its numbers are in.
- Tuning lives in the AoC's RAM only: a reboot (fresh `aoc.bin`) clears
  it. Nothing is written to flash, `persist` or the amplifiers.

---

## 5. Runbook

Each step: one change, the watchdog active from T4 on, `monitor` running
during every sound (as in C9's rules), the AoC log recorded for any step
that sends. Results go into this file with the date and `uname -r`.

**Prerequisites.** C8f passed (T0-T3); C9 passed (T5 onwards); the AoC up
through `omandroid-aoc.service`; the backups are not involved (no NV,
radio or Trusty work).

### T0 read-only facts (risk none; no sound)

```sh
tools/phone-ssh 'grep -A2 -E "\"(audio_output_tuning|audio_output_tuning_ext|audio_bulk_tx|audio_bulk_rx)\"" /sys/bus/platform/devices/181d0000.aoc/services'
tools/phone-ssh 'ls -l /dev/acd-audio_output_tuning /dev/acd-audio_bulk_tx /dev/acd-audio_bulk_rx; fuser -v /dev/acd-audio_output_tuning /dev/acd-audio_bulk_tx 2>&1'
tools/phone-ssh 'C=$(awk "/aoc/{print \$1; exit}" /proc/asound/cards); amixer -c $C cget name="AoC Speaker Mixer ASP Mode"; amixer -c $C cget name="Audio DSP State"'
```

Expect: the four services with slot sizes, bulk slots of at least 16 KiB;
the devices present and unopened; ASP Mode readable (record the idle value);
DSP State `Idle`. Pass: all readable, no kernel error. Stop: an AoC error in
`dmesg` after the `cget`, or a bulk slot smaller than 16 KiB (then stock's
16 KiB write would not fit: re-read section 2.2 before going on). Rollback:
none needed.

T0b, during a C8-level tone (`omandroid-speaker-protection signal tone … --level -23 --seconds 3`,
as in C8f): read "Audio DSP State" and ASP Mode again. Expect `Playback`;
ASP Mode's value with a stream running and no tuning is the baseline.

### T1 offline (laptop; risk none)

1. Confirm with REA on `libmahalcontroller.so` the exact signatures and
   command numbers the helper needs (create, initialise, set command for
   custom action / orientation, DSP wake, version, flush), from its own
   exports and the call sites in `audio_waves_aoc.so`. Record facts in
   our words only.
2. Write and build `omandroid-waves-host`; checkpatch-style review, `-Wall
   -Wextra -Werror`.
3. Add the `waves` profile to `tools/extract-vendor-chroot`; build it from
   the user's factory image; check `MANIFEST`.
4. Optional: run the helper under `qemu-aarch64` with the chroot's linker
   on the laptop, with a fake sender that answers "status 0, no data":
   does initialisation and a `route` produce frames, and how many, of what
   sizes?

Pass: frames come out for `route 2 0 0` and `orientation 0`. Stop: the
controller refuses to initialise without a reply it cannot get offline
(then T2 runs on the phone with the AoC still untouched, and T3 sends
the handshake first).

### T2 helper on the phone, no AoC writes (risk none)

Install the chroot tree and the helper; run the daemon in `--dry-run`:
it starts the helper, plays the route/orientation sequence, logs what it
would send (command, block, component, sizes, hashes) and answers the
helper with a timeout. Expect the same frames as T1.4. Pass: only block
16 / component 2 traffic; payloads ≤ 16 KiB. Stop: anything outside the
allowlist; the helper crashing. Rollback: stop the unit.

### T3 first write: ASP Mode and one exchange (risk low; announce it, no sound)

1. With nothing playing, write ASP Mode to its T0 value (a no-op write)
   and read it back. Then `ASP_BYPASS` and back to the T0 value. Expect
   the values to stick. This proves the rollback lever before any tuning.
2. If T1/T2 showed a handshake (a version or state query), send that one
   exchange with `AOCLOG=1` recording. Expect reply 0 and no "Could not
   configure WAVES".

Stop: a negative reply, an AoC watchdog or crash, any AoC log error.
Rollback: write the T0 value; worst case reboot (AoC RAM only).

### T4 Waves on, throttle preset, C8 levels (risk medium; announce it)

Stage c8 levels (657 / 6), the watchdog on, `monitor` in a second
terminal. Sink volume 40 %.

1. Baseline: the package's multitone through PipeWire for 5 s, tuning
   `off`; record `monitor` (temperatures, `SPK_OUTPUT_POWER`) and the
   sound.
2. `OMANDROID_SPK_TUNING=throttle`, restart the tuning unit, the same
   multitone. Expect the daemon's "active SPEAKER_MUSIC_THROTTLE 0",
   reply 0, the AoC log's mixer line for Waves, ASP Mode `ASP_ON` (or
   record what it reads), audibly fuller and louder.
3. Orientation: turn the phone to each landscape side; expect one resend
   each and left/right following the phone. Note which iio orientation is
   90° and which 270°.
4. Stop the stream, start it again: does the AoC keep the tuning (no
   resend needed), or does the daemon's resend fire? Record.

Pass: replies 0; output power and coil temperatures within C9's rules;
no xruns, no amplifier event. Stop: any watchdog mute, a temperature rise
above twice the baseline's for the same signal, `SPK_OUTPUT_POWER` above
twice the baseline, audible distortion, a negative reply, an AoC log
error. Rollback: `ASP_BYPASS` (if T3 proved it) or
`omandroid-speaker-protection mute`; tuning `off`; reboot to be sure.

### T5 `SPEAKER_MUSIC` at the C9 levels (after C9 passed; risk medium-high)

The same as T4 at the levels C9 settled on, first with `throttle`, then
with `music`, each with the C9 burst limits (≤ 10 s, 60 s rest). With
`--record`, repeat across two boots and compare hashes per (preset,
angle): equal hashes allow section 3.2. Pass/Stop/Rollback as T4, with C9's
temperature rules.

### T6 at boot and in real use (risk medium)

Enable the unit with `OMANDROID_SPK_TUNING` at the T5 result; 15 minutes
of mixed media at normal volume, rotations, an AoC restart (a reboot).
Pass: `active` after every stream start, no mute, temperatures back to
ambient after. Then hand the result to the `omandroid-audio` owner for
packaging (version bump; nothing enabled that is not hang-safe).

---

## 6. Open questions

1. Does the AoC drop the Waves state when the speaker stream stops, or
   only on an AoC restart? (T4.4)
2. What does ASP Mode read with no tuning sent: `ASP_OFF`, `ASP_BYPASS`
   or `ASP_ON` with default coefficients? (T0) And does `ASP_BYPASS` take
   Waves out of the path immediately? (T3)
3. Does the controller need a reply (version, meters) before it emits the
   tuning? (T1.4, T2)
4. Which `SensorProxy` side (`left-up`/`right-up`) is stock's 90°? (T4.3)
5. Volume link laws: how much of stock's sound depends on feeding the
   stream volume into Waves? Phase 2, after T5.
6. `audio_output_tuning_ext` (service 8): unused by the stock libraries
   we read; leave closed.
