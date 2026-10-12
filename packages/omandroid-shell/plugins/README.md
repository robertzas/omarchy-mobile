<!-- SPDX-License-Identifier: MIT -->
# Omandroid plugins

Phone surfaces for Omarchy's own shell, written as ordinary third-party
Omarchy plugins. Nothing in Omarchy is patched: each directory here is a
plugin with a `manifest.json`, discovered from `~/.config/omarchy/plugins/`
and switched on by `phone/profile/shell.json`. They draw with the shell's
`qs.Commons` (Color, Style, Border) and `qs.Ui` components, so they follow
the current Omarchy theme: fonts, colours, borders, corner rounding, spacing.

All touch targets are at least 44 logical px (the Pixel 7 Pro is 480x1040
logical at scale 3).

| Plugin | Kind | What it is |
| --- | --- | --- |
| `omandroid.bar` | `bar` | Status bar: clock, connectivity, battery; tap or pull down for quick settings |
| `omandroid.quicksettings` | `panel` (keepLoaded) | Pull-down sheet: eight toggle tiles, brightness and volume; Wi-Fi picker and Bluetooth panel |
| `omandroid.launcher` | `panel` (keepLoaded) | Home bar: app search, app grid and coding-agent prompt in one input |
| lockpad | none | Not built; see [Lock screen](#lock-screen-pin-pad) for why and what upstream needs |

## Enabling

`phone/profile/shell.json` already does this:

```json
{
  "bar": { "id": "omandroid.bar", "clockFormat": "HH:mm", "showBatteryPercent": true,
           "quickSettings": "omandroid.quicksettings" },
  "plugins": [
    { "id": "omandroid.quicksettings" },
    { "id": "omandroid.launcher" }
  ]
}
```

It also lists `omarchy.idle` under `disabledPlugins`. An idle timeout of `0`
means "act immediately" to that service, not "never", so the old profile ran
the screensaver and `omarchy-system-lock` the moment the session went idle.
The phone has no touch lock yet (below), so idle stays off for now.

## omandroid.bar

A full bar that replaces `omarchy.bar`. It is 44 px tall (or the theme's bar
size if larger), anchored to the top, and reserves its height so windows tile
below it. Left: the clock. Right: do-not-disturb (when on), Bluetooth (when
on), cellular signal (when a modem exists), Wi-Fi or Ethernet, battery glyph
and percentage. The centre is left empty for the camera cutout.

The whole strip is one touch target: a tap toggles quick settings, a downward
pull past ~14 px opens it.

Sources: `Quickshell.Networking` (NetworkManager) for Wi-Fi/Ethernet,
`Quickshell.Bluetooth`, `UPower.displayDevice`, and the do-not-disturb flag
through the host's `omarchy.notifications` proxy (only full bars get that).
Glyphs are the same sets Omarchy's network and power panels use.

Settings live on the `bar` object in `shell.json`:

| Key | Default | |
| --- | --- | --- |
| `clockFormat` | `"HH:mm"` | Qt date format |
| `showBatteryPercent` | `true` | |
| `quickSettings` | `"omandroid.quicksettings"` | Plugin id the bar opens |

**Stubbed:** cellular signal. `Quickshell.Networking` has no modem backend and
the Pixel 7 Pro modem has no mainline driver, so `cellular.available` is
hard-wired to `false` and the icon never renders.

IPC (`omarchy-shell omandroid.bar <method>`), for edge-swipe gestures or
hardware keys:

| Method | Effect |
| --- | --- |
| `pullDown` | Open quick settings |
| `toggleQuickSettings` | Open or close it |

## omandroid.quicksettings

A sheet that slides down from the top edge over the status bar, styled as an
Omarchy popup (popups background and border). It has a clock and date header,
eight toggle tiles in two columns, then brightness and volume sliders. Tap the
scrim, swipe the sheet up, or press Escape to close it.

| Tile | Backend |
| --- | --- |
| Wi-Fi | `Networking.wifiEnabled` (NetworkManager); status shows the SSID. The chevron or a long-press opens the Wi-Fi picker (below) |
| Bluetooth | `omarchy-bluetooth-power on/off`, the same rfkill path as Omarchy's Bluetooth panel. The chevron or a long-press opens the Bluetooth panel (below) |
| Mobile data | **Stub**: no modem backend (ModemManager wiring is the TODO) |
| Location | `omandroid-gnss on` and `off` (omandroid-gnss), through polkit; "In use" while the receiver runs, "No GNSS" without the command or the vendor files |
| NFC | the controller's rfkill switch (`rfkill block nfc`, `rfkill unblock nfc`); "No NFC" until a controller probes (RADIOS-CAMERA-PLAN section 3) |
| Rotation lock | `omandroid-autorotate` (omandroid-sensors): locked by `~/.local/state/omandroid/rotation-lock`; unlocking also enables the service. "No sensor" while the sensor proxy has no accelerometer |
| Torch | **Stub**: the flash LED has no mainline driver; once a `*:flash`/`*:torch` LED appears in `/sys/class/leds`, drive it with `brightnessctl -d` |
| Do not disturb | The notification service's `notifications` IPC target on this shell instance |
| Brightness slider | `brightnessctl --class=backlight` (the panel backlight; dimmed when there is none) |
| Volume slider | PipeWire default sink; tap the speaker glyph to mute |

Stub tiles render dimmed, report "No modem" / "No sensor" / "No flash LED",
and do nothing when tapped. Their `toggle()` bodies are deliberately empty.

The plugin is `keepLoaded` so the sheet can animate out before it unmaps.

### Wi-Fi picker

`WifiPanel.qml`, after Android's Internet panel. A tap on the Wi-Fi tile still
toggles the radio; the chevron at the tile's right edge, or a long-press
anywhere on it, swaps the sheet for the picker. It is its own window on the
top layer with normal exclusion (like the launcher's drawer), so it sits
between the status bar and the on-screen keyboard. The back glyph returns to
quick settings; tapping outside or Escape closes it.

* **Use Wi-Fi** switch, then the connected network, then everything in range
  strongest first, with a signal glyph and a lock on secured networks. Saved
  profiles show "Saved"; saved profiles out of range get their own section.
* **Rescans** on open, from the refresh glyph, and on a pull-down of the list.
* **Tap** an open or saved network to connect; a secured new one asks for the
  password in a sheet (masked, with show/hide, Connect/Cancel, Enter submits)
  above the on-screen keyboard. Failures show in a banner and on the row; a
  wrong password reopens the sheet.
* **Long-press** a connected or saved network (or tap the connected one) for
  Disconnect and Forget.

Backends: `Quickshell.Networking` for the device (found by type, never by
name), the scanner, `connect()`, `connectWithPsk()`, `disconnect()`,
`forget()` and `connectionFailed`. nmcli covers what it lacks: saved profiles
out of range (`nmcli -t -f NAME,UUID,TYPE connection show`, forgotten with
`nmcli connection delete uuid`), and connecting with a password on a
Quickshell without `connectWithPsk`, where the password goes to
`nmcli --ask` on stdin. The password is never in argv or the log. The pure
logic (sorting, signal buckets, sections, nmcli parsing, failure text) is in
`WifiModel.js`, tested by `test/wifi-model.js`.

Limits: hidden networks and 802.1X (enterprise) networks can't be joined from
here yet; an out-of-range saved profile is matched to its network by profile
name, which is the SSID unless someone renamed it.

### Bluetooth panel

`BluetoothPanel.qml`, built the same way: a tap on the Bluetooth tile still
toggles power (through `omarchy-bluetooth-power`), the chevron or a
long-press opens the panel, the back glyph returns to quick settings.

* **Use Bluetooth** switch, then **Make visible to other devices** with the
  phone's own name; visibility lasts two minutes (a countdown shows) and ends
  when the panel closes.
* **Paired devices**: connected first, then by name, with battery when BlueZ
  has it. **Available devices**: what discovery finds, named devices strongest
  first; address-only devices fold behind "Show N unnamed devices". Discovery
  runs only while the panel is open; the refresh glyph restarts it.
* Icons come from the LE appearance, then the class of device, then BlueZ's
  icon name: headphones, speaker, keyboard, mouse, gamepad, phone, computer,
  watch, or a plain Bluetooth glyph.
* **Tap** an available device to pair, trust and connect; a paired one to
  connect; the connected one for its actions. **Long-press** a paired device
  for Connect/Disconnect, Rename and Forget. Failures (pairing failed or
  rejected, connection refused, out of range, timeouts) show in a banner and
  on the row.
* **Pairing prompts**: Just Works needs nothing; numeric comparison shows the
  six digits with Pair/Cancel; a keyboard shows the passkey to type, lighting
  up digits as they're typed; a PIN or passkey request gets a field above the
  on-screen keyboard. A device pairing *to* the phone gets the same sheets.

Quickshell.Bluetooth provides the devices, power, visibility, disconnect,
forget and rename, but no pairing agent, RSSI, device class or failure
reasons. So while the panel is open it runs `omandroid-bt-agent` (python3
with python-dbus and python-gobject): it registers a KeyboardDisplay agent as
the default, holds the discovery session (BlueZ ends it when the helper
exits), reports RSSI/appearance/class, and runs Pair, Trusted and Connect so
errors come back with BlueZ's reason. It talks JSON lines on stdin/stdout;
PINs travel only over stdin and D-Bus and are never printed. If the helper
can't start, the banner says so and the panel falls back to Quickshell's own
discovery and Just Works pairing. The pure logic is in `BluetoothModel.js`
(`test/bluetooth-model.js`); the helper's pure parts are tested by
`test/bt-agent.py`.

Limits: no file transfer or per-profile toggles (media/calls); the panel only
answers the agent while it is open, so pairing *to* the phone needs the panel
up (which visibility does anyway).

IPC:

| Call | Effect |
| --- | --- |
| `omarchy-shell shell toggle omandroid.quicksettings '{}'` | Open or close |
| `omarchy-shell shell summon omandroid.quicksettings '{}'` / `hide omandroid.quicksettings` | Open / close |
| `omarchy-shell shell call omandroid.quicksettings state ''` | JSON: open state, Wi-Fi, Bluetooth, DND, brightness, volume |
| `omarchy-shell shell summon omandroid.quicksettings '{"page":"wifi"}'` | Open the Wi-Fi picker |
| `omarchy-shell shell call omandroid.quicksettings openWifi ''` | The same; returns the picker's state, or `unavailable` |
| `omarchy-shell shell call omandroid.quicksettings wifiPanel ''` | JSON: picker open, device, connected SSID, networks in range, saved out of range, action, failure, sheet |
| `omarchy-shell shell summon omandroid.quicksettings '{"page":"bluetooth"}'` | Open the Bluetooth panel |
| `omarchy-shell shell call omandroid.quicksettings openBluetooth ''` | The same; returns the panel's state, or `unavailable` |
| `omarchy-shell shell call omandroid.quicksettings bluetoothPanel ''` | JSON: panel open, adapter name, power, discovering, visible, helper, paired, available (with RSSI and type), unnamed count, action, failure, sheet, pairing phase |
| `omarchy-shell shell call omandroid.quicksettings toggleTile <name>` | Same as tapping a tile. Names: `wifi`, `bluetooth`, `mobile-data`, `rotation-lock`, `location`, `nfc`, `torch`, `dnd`. Returns the new state, `unavailable` or `unknown` |

## omandroid.launcher

The home surface, after Omalauncher: one bar along the bottom of the screen.

* **Dock (always on screen).** A search pill, "Search apps or ask Claude…",
  in a bar-coloured strip that reserves its height so windows tile above it.
  Tapping it opens the drawer.
* **Drawer.** The app grid (4 columns of 44 px icons with names) under the
  status bar, with the one input at the bottom, focused. Typing filters the
  grid; while searching, results stack upward from the input so the best match
  sits by your thumb, highlighted.
* **Ask the agent.** Any text also offers an "Ask Claude" row above the input.
  Text that reads as a prompt (3+ words, ends in `?`, `.` or `!`, or matches no
  app) makes that row the primary action: it is highlighted, the input glyph
  turns into the agent, and Enter asks the agent instead of launching the top
  app. Asking runs `terminalCommand + agentCommand + [prompt]`, with the prompt
  as a single argv element (no shell parsing), then closes the drawer.

Apps come from Omarchy's application library (`services/AppLibrary.qml`): the
same entries, hidden-entry filters, icon index and `uwsm-app -- gtk-launch`
launch path as the Omarchy menu.

Settings: defaults are in `manifest.json` under `settings.defaults`; override
any of them on the plugin's entry in `shell.json`, which the launcher watches:

```json
{ "id": "omandroid.launcher", "agentName": "Codex", "agentCommand": ["codex"],
  "agentIcon": "shell/plugins/agents/assets/codex.svg" }
```

| Key | Default | |
| --- | --- | --- |
| `agentName` | `"Claude"` | Shown as "Ask <name>" |
| `agentCommand` | `["claude"]` | The prompt is appended as one argument |
| `agentIcon` | `"shell/plugins/agents/assets/claude.svg"` | Absolute, or relative to `$OMARCHY_PATH` (reuses the Agents plugin's marks) |
| `terminalCommand` | `["xdg-terminal-exec"]` | |
| `columns` | `4` | 3 to 6 |
| `sentenceWords` | `3` | Word count at which text counts as a prompt |

IPC:

| Call | Effect |
| --- | --- |
| `omarchy-shell shell summon omandroid.launcher '{"query":"fix the tests"}'` | Open the drawer, optionally pre-filled |
| `omarchy-shell shell hide omandroid.launcher` | Close the drawer (the dock stays) |
| `omarchy-shell shell call omandroid.launcher search <text>` | Open and type; returns the mode (`apps`/`agent`) and the top app ids |
| `omarchy-shell shell call omandroid.launcher ask <prompt>` | Ask the agent directly |
| `omarchy-shell shell call omandroid.launcher state ''` | JSON: open state, query, mode, app count, agent argv |

## Testing in the desktop harness

`phone/dev/run-desktop` copies the shell and runs it in a nested Hyprland, so
point IPC at that copy and its Wayland display, never at
`/usr/share/omarchy/shell` (your real desktop):

```sh
HOME=~/android/phone-dev/home WAYLAND_DISPLAY=wayland-2 \
  quickshell ipc -p ~/android/phone-dev/shell call shell listPlugins
```

(`quickshell list --all` shows which `wayland-N` the nested shell is on.)
`WAYLAND_DISPLAY=wayland-2 grim out.png` screenshots the nested screen and
`WAYLAND_DISPLAY=wayland-2 wtype 'text'` types into the launcher.

Hot reload is not enough for every change. Relaunch the harness after:

* adding a new file to a plugin directory (Qt's type loader caches each
  directory's listing, so a file that appears later stays "No such file");
* editing a `keepLoaded` plugin (quick settings, launcher): the reload
  rebuilds it from the cached component;
* editing `phone/profile/shell.json` (it is copied at launch).

## Plugin API limits found

### Lock screen PIN pad

There is no `lockpad` plugin, because a third-party plugin cannot provide the
lock screen's input without going around Omarchy's lock.

* `omarchy.lock` is a first-party `service` whose manifest carries
  `omarchy.capabilities: ["authentication"]`. The host stamps that capability
  only onto first-party manifests (and onto user clones made with
  `omarchy plugin clone`, which inherit it through `omarchy.clonedFrom`), keeps
  authentication services in a private store outside the QML object graph,
  and never hands them to other plugins' facades. Good, and intended.
* `LockView.qml` has one input: a fixed 381x67 password field driven by key
  events. There is no extension point for another input surface, and an
  on-screen keyboard is a layer-shell client that the compositor does not
  show over an `ext-session-lock` surface, so a phone with no hardware
  keyboard cannot unlock it at all.
* A plugin *could* import `Quickshell.Wayland` and `Quickshell.Services.Pam`
  and run its own `WlSessionLock`. That would be a second lock client
  competing with `omarchy.lock`: `omarchy-system-lock`, `omarchy.idle`, the
  stranded-lock recovery and the fingerprint flow all drive `omarchy.lock`, so
  the two would fight over the session. Shipping a plugin that declares
  `clonedFrom: omarchy.lock` just to inherit the capability would abuse the
  clone mechanism, which exists for a user's own copy.

What upstream needs instead, smallest first:

1. **A touch input mode in `LockView`.** A `lock.input` setting (`"password"`
   default, `"pin"`) in `shell.json` or the theme's `shell.lock.toml`. In PIN
   mode the view renders a numeric keypad (12 keys, at least 64 px on a phone)
   plus delete and enter, feeding the existing `passwordTextEdited` /
   `submitPassword` signals. PAM is unchanged: the PIN is a numeric password
   for `omarchy-lock-password`, or a separate `omarchy-lock-pin` PAM service if
   the PIN should differ from the login password. The keypad lives inside the
   session-lock surface, so no external keyboard client is needed.
2. **Or a `lock-input` plugin kind.** `omarchy.lock` loads a declared input
   component *inside* its own `WlSessionLockSurface`. The component gets a
   narrow facade (`append(char)`, `backspace()`, `submit()`, `failureMessage`,
   `authenticating`) and never the `PamContext` or the service, so the
   authentication boundary stays where it is while the input surface becomes
   replaceable.

### Smaller ones

* **Third-party `menu` plugins lose their shell facade.** In `shell.qml` the
  panel loader passes `modelData.manifest` from an `Instantiator` model to
  `pluginShellFor()`. Arrays inside `modelData` are not JS arrays
  (`Array.isArray()` is `false`), so `manifestHasKind(manifest, "menu")`
  fails: the facade is built without `appLibrary`, and on the next config
  change `prunePluginApis()` (which reads the registry's real manifest) sees a
  different capability profile and destroys the facade, leaving the plugin's
  `shell` null. The launcher therefore declares `panel` and instantiates
  Omarchy's `AppLibrary` type itself via `import qs.services`. Fix upstream:
  pass `shell.pluginRegistry.installedPlugins[panelEntry.pluginId]` to the
  loader's injections (or make `manifestHasKind` accept array-likes).
* **Panel plugins get no settings.** Inline settings on a `plugins[]` entry are
  only handed to bar widgets, so the launcher reads its own entry from
  `shell.json` with a `FileView`.
* **Panel plugins cannot reach do-not-disturb.** The host proxies
  `omarchy.notifications` only to full bars. Quick settings calls the
  `notifications` IPC target on its own shell instance (`qs ipc -p
  Quickshell.shellDir`) instead.
