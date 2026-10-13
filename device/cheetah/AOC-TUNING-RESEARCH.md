<!-- SPDX-License-Identifier: MIT -->
# AoC speaker tuning (C10-tuning): research, design and runbook

Status (2026-10-13): **T1 done offline; T2 and T3.1 passed on the phone;
T3.2 showed the AoC answers, but 0.1.1 discarded its replies.
omandroid-speaker-tuning 0.1.2 matches replies by command ID and sends only
during playback; next is T3b, the first exchange during a tone at the
everyday level.** The listener finds our flat speaker path thin next to
stock, and this is the lever that gives stock's own sound (`AOC-PLAN.md`,
"Why the speakers sound thin"). T4 follows T3b at the everyday level
(737/10), with omandroid-audio 0.4.0's speaker filter set flat. T5 onwards
(stock's levels) still waits for `AOC-PLAN.md` C9. The package stays
disabled (mode `off`).
Sources: static analysis of the stock libraries from the user's own
factory image (CP2A.260705.006), the AoC firmware's strings and Google's
GPL AoC driver, the Waves controller run under qemu with a fake sender
(T1.4), and T2/T3 on the phone. The code is its own package,
`packages/omandroid-speaker-tuning` (helper, chroot runner, daemon, unit;
disabled, mode `off`), plus the `waves` profile of
`tools/extract-vendor-chroot`; `packages/omandroid-audio` is untouched.
Follows `AOC-PLAN.md` C9 ("C10-tuning"), which another agent owns; this
file does not change it.

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
  "AoC Speaker Mixer ASP Mode" control is block 16. (T1: the platform
  library's "mixer tuning" path takes the first block id configured for
  the back end, H.)
- component **2**: `xlate_id` maps `TUNING_COMPONENT_WAVES` to 2, and the
  platform library's built-in table gives the same default (entry 0 of its
  component table; the Waves module asks for component 0, which the table
  translates, H).
- `tuning_id="2"` on `OUT_SPEAKER_BE_CFG` is what the Waves sender logs
  as "tuning_id" next to the instance. It is the back end's tuning
  selector; for the speaker there is no playback `.gatf` in `V/etc/aoc/`
  (only `recording.gatf`, `smartfeature.gstf` and Fortemedia's voice
  `.dat` files), so Waves is the speaker's only AoC tuning (M).
- Waves instance **1** (`Sink=SPK:1`, `SPEAKER_INSTANCE = INSTANCE:1`).
  The instance is an argument of the controller's sender, never part of
  the AoC command (H, T1).
- The Waves messages are exchanged as `SET_GET_PARAM_BULK` (0x00d5) with
  no extra header in the bulk buffer: the bulk payload is exactly the
  controller's buffer, `tx_size` its length, `rx_size` 0 (H, T1).
- Stock opens the three devices **for each exchange** and closes them
  after (`audio_output_tuning` `O_RDWR`, `audio_bulk_tx` `O_WRONLY`,
  `audio_bulk_rx` `O_RDONLY`, all `O_NONBLOCK`). It waits for the reply
  with a 500 ms `select`, after which the exchange counts as -110; it
  accepts only a 26-byte reply with the same command ID; a non-zero
  `rx_size` (offset 24) in a successful reply means that many bytes
  (at most 16384) are waiting on `audio_bulk_rx`, which stock copies back
  to the controller when they fit its reply buffer (H, T1).

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

### 2.6 Licence or key check (see also 2.7: initialisation needs no reply)

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

### 2.7 The Waves controller's API (T1; H unless marked)

From `libmahalcontroller.so`'s exports, the calls in `audio_waves_aoc.so`
and the controller run under qemu (T1.4). In our words; nothing of the
libraries is reproduced.

- **Exports.** 22 plain C functions named `ma_*`. Stock `dlopen`s
  `/vendor/lib64/libmahalcontroller.so` and looks up 15 of them; the
  helper needs 8. Every call takes the controller handle (a 64-bit value)
  and returns a `bool`; all but create/destroy/initialise take the Waves
  instance (`u32`, 1 for the speaker) second.
- **Create and initialise**: `ma_create(&handle, user)`, then
  `ma_initialize(handle, mps_path, "", ini_path, sender)` with
  `/vendor/etc/waves_preset.mps` and `/vendor/etc/waves_config.ini` (stock
  passes an empty string third). The controller loads
  `libAlgFx_HiFi3z.so` itself, from the `.ini`'s `AlgFxPath64`.
- **The sender**: `int sender(handle, instance, buf, len, reply,
  &reply_len, user)`, 0 for success. The controller calls it from inside
  `ma_flush` and `ma_get_version`, on the calling thread (observed). Stock's
  sender returns -22 without sending when that instance's sink is not
  active, retries once on -110, and copies a returned bulk reply into
  `reply` only when it fits `reply_len`.
- **Stock's send sequence** for a changed sink (`set_waves_tuning_from_sink`):
  `ma_get_version(handle, 1, "dsp", buf, 256)` once (failure tolerated),
  `ma_wait_for_flush`, `ma_on_dsp_wakeup` if the sink is not initialised
  yet (first time, and after an AoC restart), then `ma_set_data` for bypass,
  volume and orientation, the custom actions, and `ma_flush`.
- **`ma_set_data(handle, instance, type, data, size)`** types: 0 volume
  (`double`), 1 orientation (`u32` degrees), 3 output mode (`u32`; stock's
  test path only), 6 bypass (`u8`), and the custom action's own number:
  **258** with three `u32`s, the speaker back end's `audio_devices_t`,
  Android's `audio_mode_t` and the throttle state (0 enabled, 1 disabled,
  2 bypassed), exactly the `.ini`'s `[CUSTOM_ACTION_258]` numbers. The
  module confirms the action with `ma_is_feature_supported(handle,
  "CUSTOM_ACTION_258")` first.
- Not used by us: `ma_set_linklaws_value` (custom actions' and AMCS's
  link-law values, phase 2), `ma_set_parameters_array` and the text
  command interface `ma_set_command`/`ma_get_command` (stock: tests and
  calibration dumps), `ma_register_notifier`, and the direct setters
  (`ma_set_orientation`, `ma_set_volume`, `ma_set_bypass`, ...), which stock
  never calls.
- **Message format** seen at the sender: a `u32` Waves message ID, then
  (for parameter messages) a `u32` length of the rest. ID 5 is the 4-byte
  version query, ID 1 a parameter/coefficient upload.

### 2.8 What the speaker upload contains (structure only; 2026-10-13)

From the T1 run (the controller under qemu, `route 2 0 1`, `wake`,
`flush`) and the module names in `libAlgFx_HiFi3z.so`'s strings. No value
is recorded here or anywhere in the repository.

- After its two-word header, the 11204-byte upload is a flat list of
  records: a coefficient ID, a word count, then that many words. The list
  has 198 records. The ID's bits above bit 8 select the module, and the
  low 9 bits select the coefficient within it (M: the decoder's error
  text speaks of a "module ID", and the groups fall exactly on 0x200
  boundaries). Module numbers match the order of the chain's module
  name table (M).
- Modules with coefficients in the internal speaker's upload: the I/O
  stage, a crossover, MaxxS1, **MaxxBass**, MaxxStereo, MaxxDialog,
  MaxxTreble, two parametric EQs and a "finishing" EQ, two more EQ types
  (XEQ, TEQ), **a multiband dynamics stage** (by far the largest share of
  the upload), a multiband shaper, an exciter, and **MaxxVolume** (the
  leveler). Only the centre-gain module sends nothing.
- A coefficient set doesn't show that a module is switched on: the
  controller may send coefficients for a bypassed module too. Which ones
  are bypassed is not decoded (open question 8).
- What follows for our side, whatever the enable states:
  - **MaxxBass** works on the bass the speakers can't reproduce. It
    synthesises harmonics from it, so the bass is heard through the
    harmonics. It needs that low-frequency input, so a high-pass of ours
    in front of it starves it. T4 therefore sets our PipeWire filter to
    `preset waves` (a 20 Hz corner, nothing else).
  - The **multiband dynamics** stage and **MaxxVolume** raise the average
    level and hold the peaks. That is where most of stock's loudness comes
    from, and it is why Waves on our 737/10 levels will sound both louder
    and fuller. Waves runs before the amplifiers, so it cannot push the
    signal past digital full scale. Its worst case at 737/10 is the same
    full-scale signal at the same amplifier gains that our limiter
    already allows (3 dB more than our -3 dBFS ceiling), with the
    protection firmware in the path. That is still far below stock's
    power at 817/17.
  - Stereo: MaxxStereo has coefficients, and stock lets Waves do the
    orientation swap (section 2.5). Whether it treats the earpiece and the
    bottom speaker differently can't be seen from the record layout.
    T4.3 listens for it.

---

## 3. Design (built in T1: `packages/omandroid-speaker-tuning`)

### 3.1 Pieces

```
 vendor chroot "waves" (read-only tree from the user's image)        host (Arch)
 ┌──────────────────────────────────────────────┐   stdin/stdout   ┌──────────────────────────────┐
 │ omandroid-waves-host (ours, C, bionic)        │ <──── frames ──> │ omandroid-speaker-tuning     │
 │  dlopen libmahalcontroller.so (Waves)         │                  │ (ours, Python, root, systemd)│
 │   └─ dlopen libAlgFx_HiFi3z.so (Waves)        │                  │  owns /dev/acd-audio_output_ │
 │  reads waves_preset.mps, waves_config.ini     │                  │  tuning, audio_bulk_tx/_rx   │
 │  no network, no AoC; /dev: null zero urandom  │                  │  policy, triggers, allowlist │
 └──────────────────────────────────────────────┘                  └──────────────────────────────┘
```

1. **`omandroid-waves-host`** (`bionic/omandroid-waves-host.c`): a small
   bionic program of ours (MIT), built with the NDK
   (`make -C packages/omandroid-speaker-tuning/bionic NDK=...`; links only
   libc and libdl). It `dlopen`s Waves' controller at run time, creates
   and initialises it with the `.mps`, the `.ini` and its sender, and turns
   line commands from stdin into the API of 2.7: `version NAME`, `begin`
   (wait_for_flush), `wake` (on_dsp_wakeup), `bypass 0|1`, `volume V`,
   `orientation 0|90|180|270`, `route DEV MODE THROTTLE` (custom action
   258), `flush`, `quit`; answers `ok CMD` / `fail CMD ...`. Its sender
   writes `send INSTANCE LEN HEX` and blocks (10 s) for `reply RC HEX|-`.
   Waves' own stdout and liblog output go to stderr. It cannot touch the
   AoC: the chroot has no `/dev/acd-*`.
2. **The `waves` profile** of `tools/extract-vendor-chroot`: the two Waves
   libraries, `waves_preset.mps`, `waves_config.ini`, the runtime APEX's
   linker and bionic, `liblog` and its `libc++` (14 files, 17 MB from
   CP2A.260705.006); the profile check refuses a controller without the
   eight entry points or an `.ini` without instance 1 and custom action 258.
   Built on the laptop, installed by hand under
   `/usr/lib/omandroid-vendor/waves` (like `gnss`). It is run by the
   package's own runner, `omandroid-waves-host-run`, not by
   `omandroid-vendor-chroot` (that one supervises daemons; the helper is a
   filter on stdin/stdout): a read-only tmpfs root with the image, the
   helper, `/proc`, a private `/tmp` and a `/dev` holding only `null`,
   `zero` and `urandom`; new mount, PID, network (empty), IPC and UTS
   namespaces; the helper runs as `nobody` with `no_new_privs`, as PID 1
   of its namespace.
3. **`omandroid-speaker-tuning`** (Python, `BindsTo=` and `After=`
   `omandroid-speaker-watch.service`, `After=omandroid-aoc.service`):
   - the only opener of the three AoC devices (`lib/aoc_tuning.py`);
     implements section 2.2 as stock does (open per exchange, 16 KiB bulk
     buffer, command, 500 ms reply wait matched by command ID, one retry on
     -110, one exchange at a time);
   - **allowlist**: only `0x00d5` to block 16, component 2, with a payload
     of 1..16384 bytes, and the read-only `GET_PARAMETER` of block 16
     component 2 key 0 (ASP Mode); anything else is refused before a device
     is opened. A helper frame for another instance, over 16 KiB, with bad
     hex or a line we don't know is a protocol violation: logged, the
     helper stopped and started again at the next trigger (three failures
     in a row stop sending until an AoC restart or a unit restart);
   - **triggers**: speaker playback start (the speaker EPs' PCM `RUNNING`
     in `/proc/asound/card*/pcm*p/sub0/status` and "Audio DSP State" =
     `Playback`) → send the current route and orientation; orientation
     changes from `net.hadess.SensorProxy` (`ClaimAccelerometer`,
     `AccelerometerOrientation`; `normal` 0°, `bottom-up` 180°, `left-up`
     and `right-up` 90°/270°, which way round to be checked in T4), with a
     1 s hysteresis, only while playing; AoC restart (the AoC's
     `restart_count` or the online marker in `/run/omandroid/`) →
     `dsp-wakeup`; PipeWire sink volume → `volume` (phase 2);
   - **policy** from `/etc/omandroid/speaker.conf` or the package's
     `/etc/omandroid/speaker-tuning.conf`:
     `OMANDROID_SPK_TUNING=off|throttle|music` (default `off`: the unit
     exits at once); `throttle` sends `SPEAKER_MUSIC_THROTTLE` (route 2 0 0),
     `music` sends `SPEAKER_MUSIC` (route 2 0 1);
     `OMANDROID_SPK_TUNING_VOLUME` (0..1, default 1.0) and
     `OMANDROID_SPK_TUNING_LEFT_UP` (90 or 270);
   - **gates**: every exchange needs `omandroid-speaker-watch` active
     (`systemctl is-active`) and "Audio DSP State" = `Playback` (0.1.2,
     as stock), and `music` also the C9 verification stamp
     (`/var/lib/omandroid/speaker-protection-verified`); otherwise nothing
     is sent and the state says `blocked <reason>`;
   - **state for the watchdog**: writes `/run/omandroid/speaker-tuning`
     (`off`, `idle`, `stream`, `sending`, `active <preset> <angle>`,
     `failed <reason>`, `blocked <reason>`);
   - **logs** the AoC command ID, block, component, the Waves message ID,
     sizes, the first 16 hex digits of SHA-256 and return codes only. An
     optional `--record DIR` keeps the exchanges (directory 0700, files
     0600) for T5's determinism check; use
     `/var/lib/omandroid/speaker-tuning/`, never `logs/`, never committed;
   - `run --dry-run [--dry-reply RC] [--once] [--mode M] [--angle DEG]`
     starts the helper and the controller but opens no AoC device, logs
     what it would send and answers the controller with RC (default -110);
     `--once` sends one state now and exits; `status` prints the state and
     the setup;
   - tests (`test/all`): the protocol and allowlist against a fake AoC
     (SOCK_SEQPACKET socket pairs that check the 16 KiB padding and the
     framing and refuse other blocks), the helper protocol against
     `test/fake-waves-host` (including one that breaks it), the tuner and
     the triggers.
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

**Prerequisites.** C8f passed (T0-T4; T2 needs only the AoC up); C9
passed (T5 onwards); the AoC up through `omandroid-aoc.service`; the
backups are not involved (no NV, radio or Trusty work).

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

**T1 result (2026-10-12, laptop; no phone, no kernel involved): passed.**
Steps 1-3 as section 2.7 and 3.1; `test/all` passes; the helper builds
with `-Wall -Wextra -Werror` (NDK r23, API 30). Step 4 ran the helper in
the `waves` tree from CP2A.260705.006 under `qemu-aarch64` (user mode, in
an unprivileged user namespace through the package's own runner), with
replies "0, no data" unless noted:

- The controller initialises with no reply from a DSP: no handshake is
  needed before tuning (open question 3 answered).
- `version dsp`: one exchange, Waves ID 5, 4 bytes (sha256 `2594b6a92ebfb1c3`);
  with no reply payload the controller reports no version ("wrong id 0")
  and carries on, as stock tolerates.
- The first `flush` after start, and every `flush` after a `wake`: one
  exchange, Waves ID 1, **11204 bytes** (under the 16 KiB limit), sha256
  `5d5ade25887b684d`, the same on every run: the output is deterministic
  (section 3.2 replay becomes possible, T5 confirms on the phone).
- The full image is identical for `SPEAKER_MUSIC` and
  `SPEAKER_MUSIC_THROTTLE` and for orientations 0, 90 and 180, and
  switching between those sends nothing: in this `.mps` the two sound
  modes and the orientation subtypes carry the same parameters for the
  internal speaker, as far as the controller's host side goes (M;
  open question 7). `SPEAKER_SAFE_MUSIC` (route 1 0 1) gives a different
  full image (`8dd3cc562471a383`) and a 5084-5484-byte update when
  switched to or from.
- Volume changes send 596-644-byte updates (the volume link laws); a
  step that stays in the same range sends nothing.
- `ma_flush` returns success even when every exchange failed (the
  controller logs "SendBufferToDsp fail"): the daemon judges a batch by
  the exchanges' return codes, never by `ok flush`.
- The whole path through the daemon (`run --dry-run --once`, and a live
  `Tuner` against the fake AoC): version query, then the 11204-byte
  upload as one `0x00d5` exchange to block 16 component 2, zero-padded to
  16 KiB, no allowlist violation; after a simulated AoC restart the full
  upload again.

### T2 helper on the phone, no AoC writes (risk none)

Nothing here opens an AoC device or plays a sound; the package's unit
stays disabled. Laptop, from the omandroid repo:

```sh
make -C packages/omandroid-speaker-tuning/bionic NDK=$HOME/android/omandroid/out-kernel/google/gs-6.1/prebuilts/ndk-r23
tools/extract-vendor-chroot -p waves -o ~/android/vendor-chroot-work/waves \
  ~/android/factory/cheetah-cp2a.260705.006-factory-23d564ad.zip
packages/omandroid-speaker-tuning/test/all
```

1. Install the tree and the package (risk none; installs a disabled unit):
   ```sh
   tar -C ~/android/vendor-chroot-work/waves -cf - root MANIFEST SOURCE |
     tools/phone-ssh 'mkdir -p /usr/lib/omandroid-vendor/waves && tar --no-same-owner -C /usr/lib/omandroid-vendor/waves -xf -'
   tools/phone-install-package packages/omandroid-speaker-tuning
   tools/phone-ssh 'cat /usr/lib/omandroid-vendor/waves/SOURCE; /usr/lib/omandroid-speaker-tuning/omandroid-waves-host-run check;
     systemctl is-enabled omandroid-speaker-tuning; omandroid-speaker-tuning status'
   ```
   Expect: the CP2A.260705.006 fingerprint, "preconditions met",
   `disabled`, state "not running", mode `off`. Stop: the check fails
   (re-run the extraction; send its output). Rollback:
   `pacman -R omandroid-speaker-tuning; rm -r /usr/lib/omandroid-vendor/waves`.
2. Dry runs (risk none: no AoC device is opened):
   ```sh
   tools/phone-ssh 'uname -r; fuser -v /dev/acd-audio_output_tuning /dev/acd-audio_bulk_tx /dev/acd-audio_bulk_rx 2>&1;
     export OMANDROID_RUN=/tmp/spk-t2;
     omandroid-speaker-tuning run --dry-run --dry-reply 0 --once --mode throttle; echo "exit $?";
     omandroid-speaker-tuning run --dry-run --once --mode music --angle 90; echo "exit $?";
     fuser -v /dev/acd-audio_output_tuning /dev/acd-audio_bulk_tx /dev/acd-audio_bulk_rx 2>&1; dmesg | tail -5'
   ```
   Expect, first run: "dry run: no AoC device is opened"; exchange 1
   "waves id 5, 4 bytes, sha256 2594b6a92ebfb1c3"; exchange 2 "waves id 1,
   11204 bytes, sha256 5d5ade25887b684d", both "dry run, not sent";
   "state: active SPEAKER_MUSIC_THROTTLE 0 (dry run)"; exit 0. Second run
   (the default dry answer, a timeout): the same two exchanges, the
   helper's "SendBufferToDsp fail" notes, "state: failed 2 exchange(s)
   not accepted", exit 1, no crash. `fuser` lists no opener before or
   after; no new AoC lines in `dmesg`.
   Pass: the same sizes and hashes as T1 (the same image gives the same
   bytes; a different hash at the same size means a different `.mps`,
   `.ini` or library: record it, not a stop), only block 16 / component 2,
   nothing over 16 KiB. Stop: the helper dies on a signal, "broke the
   protocol", an exchange over 16 KiB, any opener of the devices, any AoC
   error in `dmesg`. Rollback: none (each run exits); `rm -r /tmp/spk-t2`.
3. Stream detection, still dry (risk low: one C8-level tone through the
   protection stack; announce it). Needs omandroid-speaker-protection and
   its watchdog active, as after C8f:
   ```sh
   U='U=$(loginctl list-users --no-legend | awk "\$2 != \"root\" {print \$2; exit}"); I=$(id -u $U); as_user() { runuser -u $U -- env XDG_RUNTIME_DIR=/run/user/$I "$@"; }'
   tools/phone-ssh 'omandroid-speaker-protection signal tone /tmp/t2.wav --level -23 --seconds 3'
   tools/phone-ssh "$U"'; (OMANDROID_RUN=/tmp/spk-t2 OMANDROID_SPK_TUNING=throttle timeout 15 omandroid-speaker-tuning run --dry-run --dry-reply 0 > /tmp/t2-run.log 2>&1 &);
     sleep 3; as_user timeout 6 pw-play /tmp/t2.wav; sleep 3; cat /tmp/t2-run.log; omandroid-speaker-protection health'
   ```
   Expect: "state: idle", then at the tone "sending (stream start)" with
   the same two exchanges, "active SPEAKER_MUSIC_THROTTLE 0 (dry run)",
   and after it "idle (...)"; the tone sounds as before; "healthy". If
   SensorProxy is up, turning the phone during the tone gives one more
   "sending (orientation ...)" after a second. Stop: no "stream start"
   (record `cat /proc/asound/cards` and the PCM status files), an
   amplifier or watchdog event. Rollback: none (the run ends after 15 s).

### T3 first write: ASP Mode and one exchange (risk low; announce it, no sound)

Prerequisites: T0 and T2 passed; protection and its watchdog active
(C8f), nothing playing; the AoC log recorded (`AOCLOG=1` as in
`tools/aoc-audio-diag`, or `cat /dev/acd-logging` in a second terminal);
a log stream to the laptop for `dmesg`. Each step is one change.

1. ASP Mode, the rollback lever (no tuning yet):
   ```sh
   tools/phone-ssh 'C=$(awk "/aoc/{print \$1; exit}" /proc/asound/cards); N="AoC Speaker Mixer ASP Mode";
     V=$(amixer -c $C cget name="$N" | sed -n "s/.*: values=//p"); echo "T0 value $V";
     amixer -q -c $C cset name="$N" $V; amixer -c $C cget name="$N" | tail -1;
     amixer -q -c $C cset name="$N" 2; amixer -c $C cget name="$N" | tail -1;
     amixer -q -c $C cset name="$N" $V; amixer -c $C cget name="$N" | tail -1; dmesg | tail -3'
   ```
   Expect each read to show the value just written (V, 2 = `ASP_BYPASS`,
   V). Stop: a write error, a value that does not stick, an AoC error.
   Rollback: write V back.
2. The first exchange, with nothing playing: one live `--once`. The
   controller sends the version query and the full upload; with the DSP
   idle the AoC may refuse the upload (stock never sends outside
   playback), which is information, not damage: tuning lives in AoC RAM.
   ```sh
   tools/phone-ssh 'systemctl is-active omandroid-speaker-watch; mkdir -p -m 0700 /var/lib/omandroid/speaker-tuning;
     OMANDROID_RUN=/tmp/spk-t3 omandroid-speaker-tuning run --once --mode throttle --record /var/lib/omandroid/speaker-tuning/t3;
     echo "exit $?"; C=$(awk "/aoc/{print \$1; exit}" /proc/asound/cards);
     amixer -c $C cget name="AoC Speaker Mixer ASP Mode" | tail -1; dmesg | tail -5'
   ```
   Expect: "exchange 1: ... waves id 5, 4 bytes ...: rc 0" (with a reply
   of a few bytes, and a "DSP Waves version: ..." line if the AoC answers
   the query), then "exchange 2: ... 11204 bytes ...: rc N". Record N, the
   reply sizes, ASP Mode afterwards, and the AoC log's lines around
   "WAVES"/"asp" (no payloads). Pass: rc 0 for the version query; for the
   upload rc 0 or a clean refusal (negative rc with no AoC error beyond
   it); no AoC watchdog or crash. Stop: the AoC restarts or crashes,
   "Could not configure WAVES" with ASP Mode left changed, any `dmesg`
   error. Rollback: ASP Mode back to V (step 1); worst case reboot (AoC
   RAM only).
3. Superseded by T3b below (0.1.2 refuses to send outside playback).

**T2 and T3 results (2026-10-12, 7.3.0-rc6-omandroid-push1-00361-g32c474a89dd6,
omandroid-speaker-tuning 0.1.1; run by the human).**

- T2.1 passed: the `waves` tree installed (17 MB), "preconditions met".
  (0.1.1 fixed `test/all` for builds on the phone: it copied the package
  with `cp -a .`, which hit makepkg's unreadable `pkg/`.)
- T2.2 passed exactly as T1 predicted. Run 1: "DSP Waves version: not
  available" (the controller's reply parser says "wrong id 0" for the
  empty answer), exchange 2 11204 bytes sha256 `5d5ade25887b684d`,
  "active SPEAKER_MUSIC_THROTTLE 0 (dry run)". Run 2: "2 exchange(s), 2
  not accepted" with "SendBufferToDsp fail". No opener in `fuser`, no AoC
  lines in `dmesg`. T2.3 was not run.
- T3.1 passed. **ASP Mode reads 1 = `ASP_ON` at idle with no tuning ever
  sent** (open question 2), and writes of 1, 2 (`ASP_BYPASS`) and 1 stuck
  (the kernel's "set asp mode: block=16, component=2, key=0, val=1",
  `SET_PARAMETER` 0x00d1, 18 bytes).
- T3.2 (live `--once`, throttle, nothing playing, watchdog active): **the
  AoC answers**, a 26-byte reply with ID 0x00d5, but 0.1.1 discarded it as
  "ignored a stray reply" because it matched our counter as well as the
  ID, and the AoC's reply does not carry our counter. Both exchanges
  therefore timed out after their retry (rc -110; the retry found the
  late first reply waiting, "dropped 1 stale message(s)"), the controller
  logged "SendBufferToDsp fail", "2 exchange(s), 2 not accepted". ASP Mode
  still 1 afterwards; the AoC log showed "AMixSPKR PostProcessing Config:
  WAVES"; no AoC error, the AoC and speaker protection still active. What
  the reply's return code was is unknown (0.1.1 did not log it, and the
  `--record` directory keeps only payloads).
- Fixed in **0.1.2**: replies are matched by command ID only, exactly as
  stock's platform library does (it never compares the counter); one
  exchange at a time and the drain before each keep an older reply from
  being taken; the first mismatch is logged once ("the AoC's reply
  counter is not ours (sent N, got M)"), and every exchange's log line
  now carries the reply's counter and `rx_size`. The fake AoC in the
  tests now answers with its own counter.
- **Decision: no sends outside playback.** Stock's sender returns -22
  without sending when the sink is not active, and the AoC's state for
  an idle mixer is not something we need to learn. From 0.1.2 every live
  exchange needs "Audio DSP State" = `Playback` besides the watchdog
  (`blocked the AoC DSP is Idle, ...` otherwise), `--once` included. The
  daemon already waited for `Playback` at stream start.

### T3b first live exchange during a tone (risk low; announce it: one 8 s tone)

Prerequisites as T3; 0.1.2 installed (`tools/phone-install-package
packages/omandroid-speaker-tuning`), the AoC log recorded. One -23 dBFS tone
at the everyday amplifier level (stage media, 737/10; this step was first
written for C8's 657/6, and nothing in it depends on the level); the `--once` starts two seconds into it, so Waves (if the AoC takes
it) changes the sound for the last seconds only.

```sh
U='U=$(loginctl list-users --no-legend | awk "\$2 != \"root\" {print \$2; exit}"); I=$(id -u $U); as_user() { runuser -u $U -- env XDG_RUNTIME_DIR=/run/user/$I "$@"; }'
tools/phone-ssh 'omandroid-speaker-protection signal tone /tmp/t3b.wav --level -23 --seconds 8'
tools/phone-ssh "$U"'; systemctl is-active omandroid-speaker-watch; C=$(awk "/aoc/{print \$1; exit}" /proc/asound/cards);
  (as_user timeout 10 pw-play /tmp/t3b.wav &); sleep 2; amixer -c $C cget name="Audio DSP State" | tail -1;
  OMANDROID_RUN=/tmp/spk-t3b omandroid-speaker-tuning run --once --mode throttle --record /var/lib/omandroid/speaker-tuning/t3b;
  echo "exit $?"; sleep 7; amixer -c $C cget name="AoC Speaker Mixer ASP Mode" | tail -1;
  omandroid-speaker-protection health; dmesg | tail -5'
```

Expect: DSP State `Playback` (item 1); "the AoC's reply counter is not
ours" once; exchange 1 (waves id 5, 4 bytes) "rc 0 (reply counter ..,
rx_size N)", and with N > 0 a "DSP Waves version: ..." line; exchange 2
(11204 bytes) "rc R (...)"; "active SPEAKER_MUSIC_THROTTLE 0"; exit 0;
"healthy". Record R, both `rx_size`s, the version text, ASP Mode, the AoC
log's lines around "WAVES", and whether the tone changed audibly at about
2 s. Pass: rc 0 for both, no AoC error, the watchdog never muted.
Stop: a negative rc (record it, then the AoC log), an AoC restart or
crash, "Could not configure WAVES", a watchdog mute, distortion.
Rollback: `amixer ... cset name="AoC Speaker Mixer ASP Mode" 2`
(`ASP_BYPASS`, proven in T3.1) or `omandroid-speaker-protection mute`;
worst case reboot (AoC RAM only).

### T4 Waves on, throttle preset, the everyday level (risk medium; announce it)

Updated 2026-10-13 for omandroid-audio 0.4.0: the amplifiers at stage media
(737 / 10, the everyday default since C9d-2, about 17 dB below stock), the
watchdog on with `OMANDROID_SPK_TEMP_JUMP=5`, `monitor` in a second
terminal, sink volume 40 % to start. T1 showed that `throttle` and `music`
send the same bytes for the internal speaker, so `throttle` is stock's
media sound here. omandroid-audio 0.4.0's speaker filter (`AOC-PLAN.md`
C9g) shapes the signal too, so set it flat for every T4 step
(`omandroid-speaker-eq preset waves`, as the desktop user): Waves then
gets the full-range signal, and the two don't add up. `eq` is the helper
from C9g.

1. Baseline: `eq preset waves`; the package's multitone through
   PipeWire for 5 s, tuning `off`; record `monitor` (temperatures,
   `SPK_OUTPUT_POWER`) and the sound.
2. `OMANDROID_SPK_TUNING=throttle`, restart the tuning unit, the same
   multitone. Expect the daemon's "active SPEAKER_MUSIC_THROTTLE 0",
   reply 0, the AoC log's mixer line for Waves, ASP Mode `ASP_ON` (or
   record what it reads), audibly fuller and louder.
3. Music the listener knows, 20 s each, told which only afterwards:
   tuning on with `eq preset waves`; tuning on with `eq preset default`;
   tuning off (`ASP_BYPASS`, as in T3.1, or the unit stopped) with `eq
   preset default`. Record the preference.
4. Orientation: turn the phone to each landscape side; expect one resend
   each and left/right following the phone. Note which iio orientation is
   90° and which 270°.
5. Stop the stream, start it again: does the AoC keep the tuning (no
   resend needed), or does the daemon's resend fire? Record.

Pass: replies 0; coil temperatures within the C9 rules (tenths of a degree
at this level); no xruns, no amplifier event. Record `SPK_OUTPUT_POWER`
against the baseline. Waves is meant to raise it; at 737/10 even several
times the baseline stays far below stock's power at 817/17. Stop: any
watchdog mute (including the 5 °C jump), audible distortion, a negative
reply, an AoC log error, an over-exc count that moves. Rollback:
`ASP_BYPASS` (proven in T3.1) or `omandroid-speaker-protection mute`;
tuning `off`; `eq preset default`; reboot to be sure (tuning lives in AoC
RAM only).

### T5 `SPEAKER_MUSIC` at the C9 levels (after C9 passed; risk medium-high)

The same as T4 at the levels C9 settled on, first with `throttle`, then
with `music`, each with the C9 burst limits (≤ 10 s, 60 s rest). With
`--record`, repeat across two boots and compare hashes per (preset,
angle): equal hashes allow section 3.2. Pass/Stop/Rollback as T4, with C9's
temperature rules.

### T6 at boot and in real use (risk medium)

Set `OMANDROID_SPK_TUNING` to the T5 result in
`/etc/omandroid/speaker-tuning.conf` and `systemctl enable --now
omandroid-speaker-tuning` (it starts and stops with the watchdog); 15
minutes of mixed media at normal volume, rotations, an AoC restart (a
reboot). Pass: `active` after every stream start, no mute, temperatures
back to ambient after. Then the package's default and the watchdog hooks
of section 3.1 item 4 are settled with the `omandroid-audio` owner
(version bump; nothing enabled that is not hang-safe).

---

## 6. Open questions

1. Does the AoC drop the Waves state when the speaker stream stops, or
   only on an AoC restart? (T4.4)
2. What does ASP Mode read with no tuning sent? **`ASP_ON`** (T3.1), so
   "ASP_ON" alone does not mean "tuned": the watchdog hook of 3.1 item 4
   must use the daemon's state, not ASP Mode. Does `ASP_BYPASS` take
   Waves out of the path immediately? (T4, by ear)
3. Does the controller need a reply (version, meters) before it emits the
   tuning? **No** (T1.4): it sends the full upload with no reply at all.
   What the AoC returns to the version query, and whether the controller
   then sends anything else, is T3.2.
4. Which `SensorProxy` side (`left-up`/`right-up`) is stock's 90°? (T4.3)
5. Volume link laws: how much of stock's sound depends on feeding the
   stream volume into Waves? Phase 2, after T5.
6. `audio_output_tuning_ext` (service 8): unused by the stock libraries
   we read; leave closed.
7. The orientation subtypes and the two sound modes gave identical
   uploads in T1.4. Does the AoC's Waves chain swap left and right by
   itself (ASP Mode `ASP_ON`, section 2.5), or does the swap depend on
   state the controller only sends after a reply? T4.3 listens; with the
   daemon running, a turn costs nothing when the controller has nothing
   to send.
8. Which of the speaker chain's modules (section 2.8) does the preset
   switch on? The upload carries coefficients for all but one. The
   controller's text interface (`ma_get_command`, with
   get-parameter commands) could list the parameters, but it takes
   base64-coded command buffers that haven't been worked out. By ear in
   T4 for now: Waves on against off, at the same sink volume.
