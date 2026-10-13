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
| `omandroid.quicksettings` | `panel` (keepLoaded) | Pull-down sheet: up to 19 tiles the user arranges, brightness and volume; Wi-Fi picker and Bluetooth panel |
| `omandroid.launcher` | `panel` (keepLoaded) | Home bar: app search, app grid and coding-agent prompt in one input |
| `omandroid.home` | `panel` (keepLoaded) | Home screens: pages of apps and widgets on the wallpaper, with an edit mode |
| `omandroid.fingerprint` | `panel` (keepLoaded) | Fingerprint target over the sensor during verification, desktop guard, and the enrollment screen |
| `omandroid.keyboard` | `panel` (keepLoaded) | A hide button right above the on-screen keyboard while it is up (also over the lock) |
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
Omarchy popup (popups background and border). It opens collapsed, as on
Android: a clock and date header, the first four tiles and brightness. A pull
down on the sheet (or a tap on the handle at its foot) expands it to every
tile, eight to a page in two columns with a sideways swipe between pages,
then brightness and volume. Tap the scrim, swipe the sheet up, or press Escape
to close it.

The pencil under the expanded grid opens edit mode: tap a tile to remove it,
hold one and drag to move it, tap one under "Add tiles" to add it; Reset puts
the default back, Done (or Escape) leaves. The layout is per user, in
`~/.config/omandroid/quicksettings.json` (`{"version": 1, "tiles": [ids]}`,
rules and default in `TilesModel.js`, tests in `test/tiles-model.js`). Edits
to the file by hand show on the next refresh.

Default order: Wi-Fi, Bluetooth, Do not disturb, Torch (the collapsed row),
Mobile data, Rotation lock, Airplane mode, Location, Battery saver, Dark
theme, Night light, NFC, Fingerprint, Keyboard. Hotspot, Stay awake,
Microphone, Screenshot and Screen record start under "Add tiles".

| Tile | Backend |
| --- | --- |
| Wi-Fi | `Networking.wifiEnabled` (NetworkManager); status shows the SSID. The chevron or a long-press opens the Wi-Fi picker (below) |
| Bluetooth | `omarchy-bluetooth-power on/off`, the same rfkill path as Omarchy's Bluetooth panel. The chevron or a long-press opens the Bluetooth panel (below) |
| Mobile data | `omandroid-sit data on/off` (omandroid-modem-sit), which starts or stops `omandroid-sit-data.service` through polkit; on while that unit is active, with the operator and technology from `/run/omandroid-sit/state.json`. "No modem" until omandroid-sitd publishes that file |
| Airplane mode | Wi-Fi, Bluetooth and WWAN rfkill switches together; on when all are soft-blocked. Turning it off unblocks only the ones that were on (`~/.local/state/omandroid/airplane-restore`). NFC keeps its own tile, and the modem's radio (`omandroid-sit radio`) is not touched, since turning that back on needs a reboot today |
| Hotspot | `nmcli device wifi hotspot con-name Hotspot` (NetworkManager makes the SSID and password; the Wi-Fi client link drops while it runs) and `nmcli connection down Hotspot`. Long-press opens the Wi-Fi picker |
| Battery saver | power-profiles-daemon's `power-saver` profile, through `omarchy-powerprofiles-set autodetect power-saver/balanced` (remembered per AC or battery) |
| Dark theme | Swaps between the user's last dark and last light Omarchy theme (`omarchy-theme-set`; defaults Tokyo Night and Catppuccin Latte, choices kept in `~/.local/state/omandroid/theme-{dark,light}`). Long-press opens Omarchy's theme picker |
| Night light | `omarchy-toggle-nightlight` (hyprsunset); "No hyprsunset" without it |
| Stay awake | `omarchy-toggle-idle stay-awake/allow-idle`, Omarchy's idle indicator |
| Microphone | Mute of PipeWire's default source; "No microphone" without one |
| Screenshot | Puts the sheet away, then `omarchy-capture-screenshot fullscreen` (file, clipboard and a notification) |
| Screen record | `omarchy-capture-screenrecording --fullscreen`, a second tap `--stop-recording`; "No recorder" without gpu-screen-recorder |
| Location | `omandroid-gnss on` and `off` (omandroid-gnss), through polkit; "In use" while the receiver runs, "No GNSS" without the command or the vendor files |
| NFC | the controller's rfkill switch (`rfkill block nfc`, `rfkill unblock nfc`); "No NFC" until a controller probes (RADIOS-CAMERA-PLAN section 3) |
| Rotation lock | `omandroid-autorotate` (omandroid-sensors): locked by `~/.local/state/omandroid/rotation-lock`; unlocking also enables the service. "No sensor" while the sensor proxy has no accelerometer |
| Torch | The rear flash LED in torch mode (`brightnessctl --device=white:torch`); "No flash LED" without it |
| Do not disturb | The notification service's `notifications` IPC target on this shell instance |
| Keyboard | Shows or folds the on-screen keyboard (squeekboard's `sm.puri.OSK0` `SetVisible`); "No keyboard" without it on the session bus |
| Fingerprint | Opens fingerprint setup (`omandroid.fingerprint`); the status counts this user's fingerprints through fprintd (`omandroid-fp-enroll list`); "No sensor" without fprintd or its device |
| Brightness slider | `brightnessctl --class=backlight` (the panel backlight; dimmed when there is none) |
| Volume slider | PipeWire default sink; tap the speaker glyph to mute |

Tiles whose backend is missing render dimmed with the reason ("No modem",
"No sensor", "No flash LED") and ignore taps. The tiles without a Quickshell
service read their state in one pass of `tile-state.sh` each time the sheet
opens and after each change, and switch through `tile-action.sh`; both sit
beside the QML and are tested against fake commands in
`test/tile-scripts.sh`.

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
| `omarchy-shell shell call omandroid.quicksettings toggleTile <name>` | Same as tapping a tile, shown or not. Names are the ids in `TilesModel.js`: `wifi`, `bluetooth`, `mobile-data`, `airplane`, `hotspot`, `dnd`, `torch`, `rotation-lock`, `location`, `nfc`, `battery-saver`, `dark-theme`, `night-light`, `stay-awake`, `mic`, `screenshot`, `screen-record`, `fingerprint`, `keyboard`. Returns the new state, `unavailable` or `unknown` |
| `omarchy-shell shell summon omandroid.quicksettings '{"expanded":true}'` / `'{"page":"edit"}'` | Open expanded / in edit mode |
| `omarchy-shell shell call omandroid.quicksettings showPage <n>` | Expand and show page n (from 0) |
| `omarchy-shell shell call omandroid.quicksettings tiles ''` | JSON: every tile with shown, available, enabled and status |
| `omarchy-shell shell call omandroid.quicksettings setTiles 'wifi torch dnd'` | Save a layout (space-separated ids: `qs ipc` splits arguments on commas); `resetTiles ''` saves the default |

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
same entries, hidden-entry filters and icon index as the Omarchy menu. They
start the same way too (`uwsm-app -- gtk-launch`), but through
`omandroid-launch`, so each app gets a screen of its own (below).

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

Long-press an app in the drawer to put it on the home screen
(`omandroid.home addApp`).

## One app per screen

As on Android, every app gets the whole screen. Each launch from the phone
shell goes to a new empty workspace, and an app that is already open is
brought back instead of opening a second window beside the one you're
looking at. `bin/omandroid-launch` does it for every path: the drawer and
search results, home-screen apps, widgets (`host.launch`, `host.openUrl`, the
ported widgets' links and "↗" buttons, a text widget's tap), the agent
prompt, NFC links and the Create-a-widget agent.

* **New apps** start through Hyprland's exec with a per-launch rule,
  `hyprctl eval 'hl.exec_cmd(CMD, { workspace = "empty" })'` (Hyprland 0.56's
  Lua API; `hl.exec_cmd(cmd, rules)` in `/usr/share/hypr/stubs/hl.meta.lua`).
  The rule follows the started process (Hyprland's `HL_EXEC_RULE_TOKEN` in its
  environment, through `uwsm-app` and `gtk-launch`), so the app's own dialogs
  open on its screen and nothing else moves. Apps that slip past the token
  (D-Bus activated ones such as Files) still land on an empty screen: a launch
  from a screen that holds windows first goes to an empty workspace.
* **Open apps** are focused on their own screen instead: a window whose class
  matches the desktop entry (`StartupWMClass`, the desktop id, its last
  reverse-DNS part, Exec's program; web apps by their `chrome-<host>_` class).
  Terminals (and `omandroid-launch app --new`) always open a new window, each
  on its own screen. Links open in the running browser, shown first.
* **Together on request.** In recent apps, hold a card: **Show with…** lists
  the apps on other screens and moves this one onto the one you pick, where
  the two tile as Omarchy tiles them; **Move to its own screen** (shown when
  the app shares one) gives it a new empty workspace. Both act on the
  window's Hyprland address (`hl.dsp.window.move({ window = "address:…",
  workspace = … })`). Empty workspaces go away as Hyprland's always do.
* **Keyboards** keep Omarchy's workspace bindings (Super+1…9, Super+Shift+1…9
  and the rest) unchanged.

## omandroid.home

Home screens, after Android launchers (Omalauncher's widget pages, the Pixel
Launcher's grid and edit mode): pages of app shortcuts and widgets on the
wallpaper, swiped sideways, with page dots above the dock.

![Home screens](../../../phone/screenshots/home-screens.png)
![Edit mode](../../../phone/screenshots/home-screens-edit.png)

* **Pages.** Swipe sideways; tap a dot to jump. The home page (Home in recent
  apps goes back to it) is marked in the Pages sheet.
* **Grid.** 4 columns by 6 rows by default (3-6 by 4-8, set in Pages). Apps
  take one cell, widgets a span within their own limits.
* **Apps** launch the way the drawer does (`omandroid-launch app`: Omarchy's
  `uwsm-app -- gtk-launch`, on a screen of their own). An app that is no longer
  installed stays, dimmed, until you remove it: its package may come back.
* **Edit mode.** Long-press anywhere (empty space, an app, a widget). Then
  drag an item to move it (dropped on an item of the same size, the two swap;
  on a bigger one, it takes the nearest free cell; dragged past the left or
  right edge, it moves to that page, making a new page on the right), drag
  the round corner handle to resize a widget, tap the cross to remove, tap a
  widget for its settings. The toolbar: **Widgets** and **Apps** add to the
  page on screen (or the next one with room), **Wallpaper** opens Omarchy's
  Style menu (what the desktop's long-press opened before this surface
  covered it, `patches/omarchy/0005`), **Pages** adds, removes, reorders and
  picks the home page and sets the grid size, **Done** (or a tap on empty
  space, or Escape) ends it. Swipe empty space to change page while editing.

| Widget | Sizes | What it shows |
| --- | --- | --- |
| Clock | 2x1-4x3 | Time and date, Qt formats in its settings |
| Weather | 2x1-4x2 | Off until turned on with a place; then Open-Meteo (below) |
| Battery | 1x1-4x2 | UPower's display device: level, charging, time left |
| Media | 3x1-4x2 | MPRIS: cover, title, artist; previous, play/pause, next |
| Calendar | 2x2-4x4 | The next 7 days from khal when it's installed, else the month |
| Note | 1x1-4x6 | Your text, kept in `home.json`; tap to edit |
| Quick toggles | 2x1-4x2 | Wi-Fi, Bluetooth, do-not-disturb (quick settings' own `toggleTile`) and More |
| Text or command | 1x1-4x6 | Fixed text, or the first lines of a command run every N s (at least 30, killed after 10 s); optional tap command |

Privacy. Only the weather widget uses the network, and only after you turn
it on in its settings: it asks Open-Meteo's geocoder for the place's
coordinates once, then for that point's forecast every 30 minutes, with the
coordinates rounded to about 1 km. No key or account. Location from GeoClue
(`omandroid-gnss`) is not used: a typed place needs no location permission
and no GNSS power. The calendar reads khal's local store; syncing it is
vdirsyncer's job. The text/command widget runs only what you typed into your
own `home.json`.

Storage. `~/.config/omandroid/home.json`, written atomically 300 ms after an
edit and watched, so a hand edit shows up at once. `HomeModel.js` documents
the format and repairs what it reads: unknown widgets and broken items are
dropped, sizes are clamped, overlapping items move to the first free cell.
An unreadable file is left alone and the default is shown; the next edit
saves the old file as `home.json.bad` first. The first start puts a clock and
the first four of a short list of installed apps on page 1, and the media and
battery widgets on page 2.

Why a layer surface and not Hyprland workspaces. Each page could be an empty
workspace with a widget layer per workspace, and Hyprland would animate the
swipe. But workspaces are where apps live: an app opened from page 2 would
land on "page 2" and vanish from page 1, the switcher and `goHome` (which
focuses an empty workspace) would fight over what a page is, and Hyprland's
workspace swipe follows the whole screen, not a finger on the wallpaper. So
there is one surface on the bottom layer (above the wallpaper on the
background layer, below every window, between the bar and the dock by
normal exclusion), it shows on whichever empty workspace you're on, and the
pages are a `ListView` inside it. Apps cover it when open; nothing renders
while they do.

Smoothness. Widgets are plain rectangles and text: no blur, shadow or
`layer.enabled`, and only the clock (once a minute), the media widget (while
playing) and the toggles' do-not-disturb poll (30 s) change while you look.
Every layout edit rebuilds the page's delegates, so the weather answer and
command output are cached per widget id and an edit is not a new request.

Fingerprint. No long-press while a fingerprint operation runs, or while the
finger that reached the sensor is still down, nor for 1.5 s after: the same
state file (`/run/omandroid-fp-ui/state.json`, or `OMANDROID_FP_UI_STATE`)
the fingerprint plugin reads. Its desktop guard also maps above this surface
on the bottom layer while an operation runs.

IPC (`omarchy-shell shell call omandroid.home <method> <arg>`):

| Method | Effect |
| --- | --- |
| `state ''` | JSON: loaded, path, page, pages, home page, grid, editing, sheet, items per page, missing apps |
| `dump ''` | The layout as stored |
| `goHome ''` / `page <n>` | Show the home page / page n (from 0) |
| `edit on` / `edit off` | Enter (returns `busy` during a fingerprint operation) or leave edit mode |
| `addApp <desktop id>` / `addWidget <type>` | Add to the page on screen; returns the new item's id or `full` |
| `showSheet widgets\|apps\|pages\|create` / `settings <item id>` | Open an edit sheet / a widget's settings |
| `widgets ''` / `widgetStatus <id>` | JSON: the user's widgets (or one) with status, errors, warnings, capabilities, undeclared capabilities, hash, folder and how often it is placed |
| `rescanWidgets ''` | Scan `~/.config/omandroid/widgets` now |
| `createWidget <description>` / `editWidget <id>` | What Create / Edit with AI do: make the folder, place it, start the agent |
| `copyExample <id>` / `removeUserWidget <id>` | Copy an installed example into your widgets and place it / move a widget folder out and take it off every page |
| `addWidget user:<id>` | Place one of your widgets |

`omarchy-shell shell summon omandroid.home '{"edit":true}'` and
`'{"page":1}'` do the same through the host. The pure logic (grid placement,
moves, swaps, resizes, pages, persistence, the weather and khal parsing) is
in `HomeModel.js`; the user widgets' side (the scan, prompts, helper argv,
settings, the command limits) in `UserWidgets.js`. Both are tested by
`test/home-model.js`, and `bin/omandroid-widget` by `test/widget-tool.py`.

### Your own widgets

![Your own widgets, one with an error](../../../phone/screenshots/home-user-widgets.png)
![The Widgets sheet](../../../phone/screenshots/home-user-widgets-sheet.png)
![Create a widget with AI](../../../phone/screenshots/home-widget-create.png)

Users build their own widgets the way Omarchy desktop users build their own
bar widgets and panels: a folder with a `manifest.json` (Omarchy's plugin
manifest, kind `home-widget`, with a `homeWidget` block shaped like
`barWidget`: sizes in cells, capabilities, `defaults` and a settings
`schema` in Omarchy's field format) and the QML it names, drawn with
`qs.Commons` so theme switches restyle it. [`WIDGETS.md`](../widgets/WIDGETS.md)
is the contract, written for people and for coding agents.

* **Where.** `~/.config/omandroid/widgets/<id>/`, not
  `~/.config/omarchy/plugins/`: a widget isn't a shell plugin (the home
  screen hosts it, in a card, once per placement), and a save under
  Omarchy's plugin folder reloads every plugin, quick settings included.
  The folder is watched the way Omarchy's `PluginRegistry` watches its own
  (`inotifywait -m -r`), so a saved file shows up in under a second.
  Nothing loads from anywhere else: examples in
  `/usr/share/omandroid/shell/widget-examples/` are copied in, not loaded
  in place, and no widget code is fetched from the network.
* **In edit mode.** **Widgets** lists them under *Yours* next to the
  built-ins, placeable and resizable within their manifest's limits, with
  their settings in the settings sheet. Each is stored in `home.json` as
  type `user:<id>` with its own settings. A robot button starts the agent
  on one (**Edit with AI**), the bin (twice) removes it: its folder moves
  to `~/.local/share/omandroid/removed-widgets/` and every placement goes.
  *Examples* lists the installed examples to copy.
* **Create a widget with AI.** Asks for a description (squeekboard comes
  up), makes `<user>.<words>` from the template, places it, and starts
  Omarchy's default coding agent (the one chosen in Omarchy's menu,
  `omarchy-default-agent`) through Omarchy's own `omarchy-agent-prompt`,
  in a terminal, in the widget's folder. The prompt is the contract's path,
  the rules (only this folder, no root, declare capabilities, run
  `omandroid-widget check .`) and the description verbatim, passed as one
  argv element from the sheet to the agent: no shell sees it. With no
  default agent, Omarchy's chooser opens (`omarchy-agent --pick`) and the
  sheet says so; a chosen agent that isn't installed shows Omarchy's own
  message. Omarchy runs agents unattended, so the prompt and the contract
  both keep it to the widget's folder.
* **Checks before a new or changed widget loads** (`omandroid-widget scan`,
  cached by a hash of the folder): the manifest is valid and sizes are
  clamped to the grid; files stay inside the folder (no links out, at most
  64 files, 1 MiB); capabilities the code uses (`commands`: `Process`,
  `execDetached`, `host.run`; `network`: `XMLHttpRequest`, URLs, `curl`)
  must be declared, or the widget is not loaded and the sheet and its card
  say which is missing; no root tools, no QML from outside the folder or a
  URL; `qmllint` with the shell's `qs.` imports resolved finds no syntax
  errors, unknown types or properties. Effects, fast timers and endless
  animations are warnings.
* **Isolation.** Each placed widget loads in `UserWidgetCell.qml`: the
  component is compiled first and created with its properties set; any
  failure (the scan's errors, a compile error, a creation error) becomes an
  error card with the message in that cell only, and a tap opens its
  settings with Edit with AI (which passes the errors to the agent). The
  URL carries the folder's hash and the component cache is cleared, so
  edited code really reloads. A user widget whose folder is missing or
  broken stays in `home.json` with its size and settings. Widgets get a
  narrow `host` (`WidgetHost.qml`), not the home screen: colours, the
  system clock format, settings, a cache that outlives layout edits, and
  `run()` / `launch()`, which refuse without a declared `"commands"`, run
  argv without a shell under `timeout` (10 s default, 30 s at most), one at
  a time and at most one every 2 s per widget. These are guard rails, not a
  sandbox: like any Omarchy plugin, a widget runs in the shell as the user
  (never root).

## omandroid.fingerprint

The under-display fingerprint sensor in the shell, after Android. Three
surfaces, all driven by `omandroid-fp-bridge` (omandroid-fingerprint):

* **Target.** While an enrollment or a verification runs (`fprintd-verify`,
  the lock screen's fingerprint conversation, `pam_fprintd` for sudo or
  polkit), a faint fingerprint in a ring sits exactly over the sensor. Its
  window's input region is the circle the bridge reacts to (1.5 sensor
  radii), so a finger there reaches nothing in the shell. When no operation
  runs, nothing is mapped.
* **Desktop guard.** While any operation runs, a transparent surface on the
  bottom layer (just above the wallpaper, in the area the bar and dock leave
  free) takes the touches that would reach the desktop, so its long-press
  menu can't open. Windows, the bar, the dock and panels sit above it. After
  an operation ends it stays until the touch that reached the sensor lifts
  (the bridge's `contact`) plus 500 ms, at most 10 s: the finger that
  unlocked the phone is often still down when the lock goes away.
* **Enrollment.** A full-screen flow on the overlay layer: an intro (how
  many fingerprints are added, Delete all), then "Touch the sensor" with the
  glyph breathing at the sensor, a progress ring around it, the stage's
  words ("Lift, then touch again"; past half, "Now place the edges of your
  finger"), the HAL's hint for the last touch, and "Fingerprint added" (Add
  another, Done) or a readable error (Try again). Cancel stops it. Opened
  from the Fingerprint tile in quick settings, Omarchy's Setup > Security >
  Fingerprint (`omandroid-setup-user` points it here), or
  `omarchy-shell shell summon omandroid.fingerprint '{"page":"enroll"}'`.

Data. The bridge serves one client, fprintd, which keeps each user's prints
(an enrollment made straight through the bridge is invisible to fprintd and
the lock). So enrollment goes through fprintd's D-Bus API:
`bin/omandroid-fp-enroll` claims the default device (polkit asks first),
reports `claimed` once polkit is answered (until then the enrollment
screen is unmapped, so Omarchy's password prompt and the on-screen keyboard,
which draws under overlay layers, stay usable; the same for Delete all),
picks the next free finger (index fingers, then thumbs, ...), runs
`EnrollStart` and reports `EnrollStatus` as JSON lines; `list` and
`delete-all` do the rest. What fprintd doesn't carry comes from the bridge's
state file, `/run/omandroid-fp-ui/state.json` (world-readable, replaced with
`rename(2)`, removed when the stack stops):

```json
{"op":"enroll","finger":false,"x":717,"y":2360,"r":121,"w":1440,"h":3120,
 "seq":7,"acquired":1,"remaining":24,"error":0,"last":"none"}
```

`op` is `idle`, `enroll` or `auth`; the circle is in panel pixels of the
portrait `w`x`h` panel; `acquired`, `remaining` and `error` are the HAL's last
AcquiredInfo, samples left and Error of the current or last operation, `seq`
counts them. The ring follows `remaining` (the HAL needs about 15 samples,
two counts each); without it, fprintd's stages (20, from our driver) stand
in. Hints follow `acquired` (PARTIAL/INSUFFICIENT: press your whole finger;
SENSOR_DIRTY: clean the screen; IMMOBILE: move your finger slightly; ...),
else fprintd's retry results. Errors use the HAL's code when this
enrollment produced one (TIMEOUT: "Time's up"), else fprintd's result. The
pure logic is in `SensorModel.js` (`test/sensor-model.js`), the helper's in
`test/fp-enroll.py`.

Placement. Panel pixels scale by the screen's logical size (480/1440 at
scale 3) and follow Hyprland's transform for the panel (0-3, as
`omandroid-autorotate` sets them); a flipped transform or a screen of another
shape hides the target. Before the bridge has written its file once, the
enrollment screen uses stock cheetah's sensor (717, 2360, radius 121).

On-screen keyboard. While squeekboard is unfolded (its `sm.puri.OSK0`
`Visible` on the session bus, through `bin/omandroid-osk-watch`; Hyprland's
layer events did not arrive while locked), the target hides
(it would sit on the keys) and the plugin keeps
`/run/omandroid-fp-ui/inhibit/osk-<user>` fresh (every 5 s; removed when the
keyboard hides), so the bridge takes no key over the sensor for a finger: no
LHBM, no capture, no failed attempt. The bridge ignores files older than
15 s.

Finger down. The panel lights its own circle (LHBM) under the finger, so
the glyph fades out; that follows the bridge's touch state, not LHBM, and
works the same with `allow_lhbm=0`.

Lock screen. Hyprland draws layer surfaces above a session lock only with
the `above_lock` layer rule; `hypr/phone.lua` sets it to 1 for the target's
namespace `omandroid-fingerprint`: drawn above the lock, but without input
there (2 would also take input). It needs none: the bridge reads the
touchscreen itself, and Omarchy's PIN pad (`patches/omarchy/0003`) keeps the
lower third of the screen clear once fingerprints are set up, with "Touch the
fingerprint sensor or enter your PIN" above the field. A touch on the sensor
lands on the lock's background, which only wakes the screen.

IPC:

| Call | Effect |
| --- | --- |
| `omarchy-shell shell summon omandroid.fingerprint '{"page":"enroll"}'` | Open enrollment |
| `omarchy-shell shell call omandroid.fingerprint state ''` | JSON: bridge op, finger, placed sensor, transform, target/guard shown, enrollment page, progress, hint, fingers |

The desktop harness can fake the bridge: `OMANDROID_FP_UI_STATE=<file>`
points the plugin at another state file, and a stub `omandroid-fp-enroll`
earlier in `PATH` stands in for fprintd.

## omandroid.keyboard

While squeekboard is unfolded (`sm.puri.OSK0` `Visible`, through
`bin/omandroid-osk-watch`), a small keyboard-close button sits right above the
keyboard's top-right corner; a tap folds it (`SetVisible false`). The window
is the button only (anchored bottom-right with normal exclusion, so the
compositor puts it just above the keyboard's reserved area), on the overlay
layer, without keyboard focus; `hypr/phone.lua` lets it work over the lock
(`above_lock = 2`). Quick settings has a Keyboard tile that shows or folds the
keyboard on demand (showing closes the sheet).

IPC: `omarchy-shell shell call omandroid.keyboard showKeyboard|hideKeyboard|toggleKeyboard|state ''`
(not `show`/`hide`: the IPC command line takes `show` for itself).

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

### Lock screen input: PIN or password

Omarchy's lock now takes a PIN on its number pad or a password on the
on-screen keyboard, with an ABC/123 switch (`patches/omarchy/0003`, `0011`);
`omandroid-set-pin` records the user's choice and sets Omarchy's
`credential-password` toggle. The polkit prompt follows the same choice
(`0010`, `0011`). The rest of this section is the history of why the lock
input lives in Omarchy rather than in a plugin.

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
