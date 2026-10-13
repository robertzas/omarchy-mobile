<!-- SPDX-License-Identifier: MIT -->
# Widget interop plan: OWL widgets on the Omarchy Mobile home screen

**Status:** design only, nothing implemented. Written 2026-10-13. Implementation starts after the installer and reinstall work ([RELEASES](RELEASES.md) §6).
**Goal:** one widget catalogue for Omalauncher and Omarchy Mobile. A widget written for one runs on the other, and a person who uses both phones has one set of widgets.
**Recommendation in one line:** host OWL with Simon Schubert's Quickshell runtime, vendored at a pinned commit (option a). Make OWL the default format for new and AI-made widgets, and keep QML widgets for power users (option c). Replace our 47 hand ports with the upstream `.owl` files wherever the runtime draws them as well as the port does.

Sources read for this plan (all MIT, Copyright (c) 2026 Simon Schubert and contributors):

| Repository | Commit | What was read |
| --- | --- | --- |
| [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets) | `b63886b` (2026-10-14 00:13 +0200) | `README.md`, `docs/LANGUAGE.md`, `order.txt`, `w/index.html`, `tools/verify-pr.sh`, all of `runtimes/quickshell/`, the 105 `widget.owl` files as data |
| [omalauncher](https://github.com/SimonSchubert/omalauncher) | `d355bdb` (2026-10-14 00:01 +0200) | `README.md`, `app/src/main/assets/widgets/README.md` (the full language guide), `owl/.../market/Review.kt` and `Catalog.kt` |

Nothing from either repository was built or run. `tools/owl.jar` was not run.

On our side: [`packages/omamobile-shell/plugins/omamobile.home`](../packages/omamobile-shell/plugins/omamobile.home) (`Home.qml`, `HomeModel.js`, `WidgetHost.qml`, `PortedWidget.qml`, `UserWidgetCell.qml`, `UserWidgets.js`, `ported/`), [`bin/omamobile-widget`](../packages/omamobile-shell/bin/omamobile-widget), [`widgets/WIDGETS.md`](../packages/omamobile-shell/widgets/WIDGETS.md) and [`plugins/README.md`](../packages/omamobile-shell/plugins/README.md), with `omamobile-shell` at 0.1.47.

---

## 1. OWL and our widget contract

### 1.1 How OWL works

OWL ("a small declarative language in the spirit of QML") describes one widget per file. The Android launcher draws it with Jetpack Compose. `runtimes/quickshell/` draws the same file with Quickshell. The reference implementation is the Kotlin `owl` module in Omalauncher, and `tools/owl.jar` is built from it.

**There are two language documents, and they differ.** The store's `docs/LANGUAGE.md` (288 lines) is an older subset. The launcher's `app/src/main/assets/widgets/README.md` (529 lines) documents language level 7 in full: `http`, `file`, `status`, `optional`, triggers, screens, `Slider`, `Input`, `Terminal`, `android.media`/`notifications`/`volume`/`alarm`/`modes`, and the `owl:` version table. The Quickshell runtime implements level 7 (`Owl.js`: `var LEVEL = 7`). Anything we write for agents must start from the launcher's README, not the store's LANGUAGE.md (question Q1 in §7).

| Area | What OWL has |
| --- | --- |
| Structure | `widget "name" { … }`, with declarations at the top and then one node tree. Properties are live expressions: when a source updates, only what reads it redraws. `component Name(a, b = 1) { … }` defines reusable nodes. `if`/`else` and `for x, i in list key k` work inside nodes |
| Values | Numbers, durations (`5m`), `3x2` sizes, interpolated strings `"${x}"`, raw `'…'`, `"""…"""`, lists, maps. A missing path is `null`, never an error, and `null` shows as `…`. Numeric text acts as a number. Arrow functions work, and methods are functions (`x.map(f)`) |
| Builtins | Math, text, `fmtBytes`/`fmtDuration`/`fmtTime`, `match`/`matchAll`/`parseJson`, list operations, colours (`rgb`, `hsl`, `alpha`, `mix`), gradients, `weatherIcon`, and `sh(x)`, which quotes a value as one shell word (owl 6) |
| Data sources | `cmd("…") every 5s [json] [timeout 30s] [status] [optional]`: `bash -c`, default every 60 s, 10 s timeout. `stream("…")`: one line is one value, at most 4 streams. `http(url, headers) every 10m`: GET only, at most 1 MB, an interval of at least 5 s. `file("~/…")`: watched, at most 1 MB. `clock every 1s`. `android.battery`/`device`/`system`/`media`/`notifications`/`volume`/`alarm`/`modes` |
| State | `state x = 0 [persist]`, `let`, `history(x, n) [persist]` and `prev(x)`. Persisted state belongs to the launcher and is keyed by file name |
| Triggers (owl 4) | `every 10s { }`, `at t { }` (fires at a Unix time even while off screen), `when cond { }`, `on x { }`. A trigger that runs more than 10 times a second is held back |
| Nodes | `Column` `Row` `Flow` `Box` `Grid` `Text` `Button` `Progress` `Ring` `Sparkline` `Image` `Canvas` (drawing calls, `sprite` pixel art) `Shader` (AGSL, with a `fallback`) `Spacer` `Slider` `Input` `Terminal` |
| Every node | Size, `fill`, `weight`, `padding`, `background`, `border`, `radius`, `clip`, `opacity`, `rotation`, `scale`, `offset`, `visible`, `onTap(x, y)`, `onDrag(dx, dy, x, y)`, `animate prop: spring()/tween()` |
| Actions | `run(cmd)` and `x = run(cmd)`, `terminal(cmd)`, `app(cmd)`, `url(link)`, which also takes `tel:`/`geo:`/`mailto:`, `copy`, `notify`, `share`, `haptic`, `torch`, `media(op)`, `volume(v)`, `androidApp(pkg)`, `notification(op, key)`, `launcher(screen)`, `refresh()`, and `screen()`/`close()` |
| Screens (owl 5) | `screen { title: …; … }`: one full-screen view of the same widget, with up to 1000 nodes |
| Theming | Theme colour names: `accent foreground background muted surface border red green yellow blue magenta cyan orange`, plus `bright_*` and `color0`-`color15`. Hex and functions also work. `corners` is the user's corner style as a multiplier, 0, 0.5 or 1 |
| Sizing | Phone grid of 6 columns by about 12 rows, with roughly square 69 dp cells. `size: 3x4` and `minSize: 2x3` are in those cells. `cols`/`rows`/`tileWidth`/`tileHeight`/`screenWidth`/`screenHeight` are readable, so a widget can change layout with its size |
| Settings | None as such. A widget keeps its configuration in `state … persist`, usually set from an `Input` on its `screen`. The store forbids personal values hard-coded in the file |
| Dependencies | `requires { pacman: ["jq", "curl"] }`. A missing package turns the tile into "needs jq" with an **install** button that runs `pacman -Syu --needed` |
| Metadata | `meta { description; version; license; category; owl: N }`. `owl: N` is the language level the widget needs. Using a newer feature without declaring it is a compile error, and an older launcher says "update the launcher" |
| Limits | 500 nodes per tile and 1000 per screen. 2000 drawing calls per frame, lists of 1000, and a budget of 200,000 evaluation steps per update. Errors show `…` and go to `.errors/<file>.txt`. "Errors never take the home screen down" |
| Scripts | `owl-send file.owl set state value` and `refresh`, from any process (launcher only; the Quickshell runtime has no equivalent) |
| Sharing | The reviewed store, plus links: `https://simonschubert.github.io/omarchy-widgets/w#owl1.<raw DEFLATE, base64url>` (about 2.9 KB per QR code) or `#dpaste.<id>` for larger widgets |
| Review | `owl.jar review` (CI): `meta` rules, `requires` checked against Arch, values in commands only through `sh()` or numbers, and a list of risky command patterns (`Review.RISKS`: download piped to a shell, `rm -rf`, `sudo`, `base64 -d`, `eval`, `dd`/`mkfs`, reads of `.ssh`/tokens, commands built at run time, notification access…). The compiler lists every command a widget can run, every `http GET` and every file it reads |
| Versioning | Two separate numbers: the language level `owl: 1..7`, and each widget's `meta.version`, which the store requires to rise. If an update changes commands or packages, the app asks the user to approve it again |

### 1.2 The Quickshell runtime

| File | Lines | Role |
| --- | --- | --- |
| `Owl.js` | 3080 | Lexer, parser, compiler, builtins and the live `Instance`. It has no QML, so it also runs under node. `compile()` returns `name`, `size`, `minSize`, sources, triggers, **`commands`** (the static list of what the widget can run) and an `animated` flag |
| `OwlWidget.qml` | 412 | One live widget. It watches the file, compiles it, keeps persisted state in `stateDir/<file>.json`, runs sources and triggers, `FrameAnimation` for `time`, `run()` processes, and writes `.errors/` |
| `OwlSource.qml` | 257 | `cmd` (`bash -c`, with a timeout kill), `stream` (restarted after 5 s), `http` (XHR with a timeout), `file` (FileView), `clock`, and `android.*` from UPower, MPRIS and the `owl-source` script. Sources run only while `active` |
| `OwlNode.qml`, `OwlLayout.js` | 784 + 307 | The nodes, laid out by Compose's Row/Column rules, with TapHandler and DragHandler. `Image` tint uses `MultiEffect` |
| `OwlCanvas.qml`, `OwlTerminal.qml` | 55 + 202 | Canvas replay, and a pseudo-terminal tile |
| `OwlHost.qml` | 115 | **The embedding seam**: `dp`, fonts, `stateDir`, `sourceCommand`, `media`, `fieldFocused(focused)` (the on-screen keyboard hook), `act(widget, name, args)` with `defaultAct`, and `launch(argv)` ("a phone puts it on a fresh workspace first") |
| `owl-source` | 231 | `android.device/system/volume/modes` answered from Linux. It uses base tools only |
| `shell.qml` | 170 | An example board: 6 columns, `dp = pitch / 69`, palette from `~/.local/state/omarchy/current/theme/colors.toml` through `themeFromToml`, and a square 2 dp `muted` frame |
| `test/run.sh` | 105 | Holds `Owl.js` to `owl.jar` byte for byte, over 198 edge expressions, fixtures and every store widget. It needs Java 17 and node |

What doesn't carry over to Linux, according to its README: `Shader` draws its `fallback`, `Terminal` is its own pseudo-terminal, `android.notifications` is empty, `androidApp()` and `notification()` report that there is no Android, and `android.alarm` is never set. A note for upstream: the comment in `OwlWidget.qml` says state persists under `~/.local/state/omarchy-mobile/widgets/`, but the code uses `OwlHost.stateDir`, which defaults to `~/.local/state/owl`.

### 1.3 Our contract, for comparison

A user widget is a folder `~/.config/omamobile/widgets/<id>/` with an Omarchy-style `manifest.json` (kind `home-widget`, a `homeWidget` block with `size`/`min`/`max` cells, `capabilities`, `defaults` and a settings `schema`) and a `Widget.qml`. The QML gets a narrow `host` (`WidgetHost.qml`): theme text colours, `timeFormat`, `saveSettings`/`openSettings`, `cached`/`setCached`, `run(argv, cb, {timeout})` (argv with no shell, at most 30 s, one command at a time, one start per 2 s, output cut at 64 KiB), `launch` (once a second) and `openUrl` (http(s) only, once a second). `omamobile-widget scan|check` validates the manifest, keeps files inside the folder (at most 64 files and 1 MiB), detects use of commands and network by regex and **refuses widgets that use an undeclared capability**, refuses root tools, `Qt.createQmlObject` and remote imports, and runs `qmllint`. `UserWidgetCell.qml` compiles each widget synchronously into its own cell, turns failures into an error card, and records each load in `widget-guard.json`. A widget whose load crashed the shell is held back at the next start until the user acts. Built-ins are `REGISTRY` entries in `HomeModel.js`. The 47 ports in `ported/<id>/Widget.qml` (11,541 lines in total) use the same host, through `PortedWidget.qml`. Ports that use the network stay off until the user turns them on.

### 1.4 Gap table

**What OWL has that our contract lacks:**

| OWL feature | Our side today | Needed for interop |
| --- | --- | --- |
| A declarative, budgeted language | Arbitrary QML | The runtime brings it |
| Static list of every command, URL and file (`compile().commands`) | Regex detection plus a declaration | Use the list for approval (§3) |
| Live sources with intervals, `stream`, `file` watch | `host.run` with callbacks | The runtime brings it |
| Triggers (`every`/`at`/`when`/`on`) | Hand-written timers | The runtime brings it. `at` keeps a 1 s timer running off screen |
| `screen { }` full-screen view | Settings sheet only | A host surface for screens (§4.4) |
| `Input`, `Slider`, `Terminal` | Any QML | `fieldFocused` linked to squeekboard. `Terminal` is opt-in |
| `requires { pacman }` with an install button | None, since agents may not install | No silent root install (§3.3) |
| `android.media/battery/volume/modes` | Media and battery widgets of our own | The runtime gives MPRIS and UPower. We supply volume and modes (DND, torch) |
| `notify`, `copy`, `share`, `haptic`, `torch`, `volume`, `media` | Not in `host` | Map them to `notify-send`, `wl-copy`, feedbackd and our torch (§3.4) |
| `meta.version`, `owl:` level, categories | `version` is free text | Read them from `meta` |
| Store, review CI, shared links, previews per theme | Examples folder only | §5 |
| `owl-send` from scripts | None | Possible later through `omarchy-shell shell call` |

**What our contract has that OWL lacks:**

| Our feature | OWL today | Interop approach |
| --- | --- | --- |
| A settings `schema` per widget, a settings sheet, **settings per placement** | No schema. State is per file name, so the same widget placed twice shares its state | Use a per-placement `stateDir` (possible today through `OwlHost`). Propose a `settings { }` declaration upstream (Q4) |
| A capability declaration, refused when missing | Commands are listed, not declared | Our approval stores a capability set derived from the listed commands (§3) |
| Network ports off until turned on | Network runs at once | Same opt-in for OWL widgets that use the network (§3) |
| `host.timeFormat`, the system's 12/24-hour setting | `fmtTime(now, "HH:mm")` with a fixed pattern | Propose a `timeFormat` tile variable upstream (Q5). Until then, a host override of `fmtTime` patterns is not possible, so it stays a known difference |
| Location from GeoClue, rounded to about 1 km (`useLocation` in 7 ports) | IP location through wttr.in, or a typed city | Propose a coarse `location` source (Q6). Keep those ports until it exists |
| Commands as argv with no shell | `bash -c` strings, with values safe only through `sh()` | Accept `bash -c` for OWL, since the commands are static and listed, and refuse store-rule violations (§3.2) |
| A crash guard per widget (`widget-guard.json`) | "Errors never take the home screen down" (evaluator level) | Keep the guard around runtime cells too (§3.5) |
| Cache that survives layout edits (`host.cached`) | Not needed: state lives in `OwlWidget` | Keep `OwlWidget` instances alive across rebuilds, or accept a re-run of sources |
| `editing` mode (taps go to the editor) | Long-press belongs to the home screen, the same model | Disable the node handlers while editing |
| 120 Hz performance rules (no endless animation, no effects) | `time` animates every frame. `Image` tint uses `MultiEffect` | Throttle and gate animation (§4.5) |
| Card look: rounded, mostly opaque theme background | A square 2 dp `muted` frame | Our card, with the widget's `padding` inside |

---

## 2. Integration options

### (a) Host `.owl` widgets in our home screen with the upstream runtime

Add a fourth cell kind next to built-ins, ports and user QML: `OwlCell.qml`, which holds an `OwlWidget` and an `OwlNode`, and an `OmamobileOwlHost` that subclasses `OwlHost` (fonts from `Style`, `dp` from the grid, per-placement `stateDir`, `act()` mapped to our launch/URL/torch/haptics, `fieldFocused` raising squeekboard).

* **Vendored at a pinned commit** (recommended): copy `runtimes/quickshell/` unmodified into `plugins/omamobile.home/owl/`, add `VENDOR` (upstream URL, commit, date, sha256 of each file) and the MIT notice, and keep our changes as patches in `patches/owl-runtime/`, each one also offered upstream. Quickshell imports QML only from inside the config folder (the runtime's README says to copy the folder in), and Omarchy loads our plugin from its own directory, so a vendored copy is the simplest thing that works. An update is a maintainer action: `tools/owl-runtime-update <commit>` copies the files and shows the diff, then the tests in §8 run. Nothing fetches at run time.
* **A packaged dependency** (`owl-quickshell` built from Simon's repository): this suits the long run if Simon wants one runtime package for Omarchy (the desktop Widgets app, `omarchy-widgets-app`) and for us. But the QML still has to sit inside our plugin folder, so the package would install into our path or need symlinks that Quickshell resolves. Revisit this once the runtime has a release cadence (Q2).

**For:** fidelity by construction, because it is the code held byte for byte to `owl.jar`. A widget works in both places the day Simon adds it. Little code of our own. Upstream already designed `OwlHost` for embedding in a phone shell.
**Against:** we inherit its bugs and its pace (the language reached level 7 within weeks). It runs on the shell's GUI thread. It assumes the launcher's semantics (69 dp cells, square frame, monospace text).

### (b) Translate OWL to QML at install time

A compiler from `.owl` to a `Widget.qml` and `manifest.json` for our existing contract.

**Against, decisively:** OWL's semantics live in the evaluator (null propagation, numeric text, budgets, `history`/`prev`, triggers, `key`ed lists, Compose layout rules). A translator either embeds `Owl.js` anyway, which makes it option (a) with extra steps, or reimplements it and drifts from `owl.jar` with no oracle. Generated QML is arbitrary QML again, with all its crash risk. An update upstream means re-translating every installed widget. Live editing (save, and the widget redraws) would need the translator in the loop. **Rejected.**

### (c) Converge on OWL as the main format for user and AI widgets, with QML for power users

This is a policy choice on top of (a), not a different mechanism. **Create a widget with AI** emits OWL by default. The Widgets sheet's store, examples and shared links are OWL. QML user widgets stay supported for what OWL can't express (Quickshell services, sensors, Bluetooth, anything that needs a real API) and are labelled "QML (advanced)".

### Recommendation: (a), vendored and pinned, plus (c)

1. **Safety.** OWL can't instantiate arbitrary QML types, reach the shell's objects, call `Qt.createQmlObject`, or import code. Its evaluator caps nodes, drawing calls, list sizes and steps per update, so a runaway loop becomes an error in one tile, not a hung shell. A QML widget can do all of those things, which is why we need qmllint, a crash guard and "keep widgets you didn't write to ones you have read". OWL is **not** harmless: `cmd()` is `bash -c` with the user's rights. The gain is that every command is fixed text in the file (or flagged as built at run time), so the user can see and approve exactly what runs (§3). For AI-made widgets this is the main reason: an agent's mistake in OWL is a `…` on a tile, while in QML it can be a crash loop.
2. **Maintenance.** One runtime held to a reference implementation by tests that someone else also maintains, and 105 reviewed widgets (48 of them Simon's) that we no longer have to port by hand. The 11,541 lines of `ported/` shrink to the few ports that need things OWL lacks.
3. **Fidelity.** The same file renders the same way on Omalauncher and on our phone, with the same layout rules, and our users get the store's widgets the day they are merged.
4. **Interop is the goal.** Only (a) and (c) give one catalogue. (b) gives a one-way import.

---

## 3. Safety model

### 3.1 From "declare or refuse" to "listed, derived and approved"

For QML we can't know statically what a widget does, so the manifest declares capabilities and the scan refuses code that uses an undeclared one. For OWL, `Owl.compile(text).commands` is the exact list, so capabilities are **derived**, and the user approves the list once per content hash:

| OWL construct | Listed by the compiler as | Our capability |
| --- | --- | --- |
| `cmd`, `stream`, `run`, `x = run`, `terminal`, `app`, `Terminal` | The command text, or "built from widget values" | `commands` |
| `http(url)` | `http GET <url>` | `network` (with the hosts listed) |
| `cmd("curl …")`, `wget`, or `requires` with `curl`/`wget` | The command text | `network` too: our existing regex runs over the listed commands |
| `file(path)`, and `Image { src: "~/…" }` | `read file <path>` (images not listed) | `files` (new, shown, not refused) |
| `android.notifications` | `read Android notifications` | `notifications` (new). Our notification history counts as private |
| `notify`, `copy`, `share`, `haptic`, `torch`, `volume`, `media`, `url` | Not listed | Allowed, but rate-limited (§3.3) |

`omamobile-widget scan` gains an OWL branch: it compiles with `Owl.js` (see §6.2 for how to run it), stores `{hash, level, commands, capabilities, risks}`, and the cell loads the widget only when `~/.config/omamobile/widget-approvals.json` holds an approval for that hash. An update that changes the command list asks again, as Omalauncher does. An update that changes only layout doesn't. Widgets the user wrote, or that their agent wrote in their folder, are approved by the act of creating them, but are still shown with their list in the Widgets sheet.

### 3.2 Refused or flagged at install

* **Refused**, whatever the source: the compile fails; `owl:` is above our runtime's `LEVEL`; a command names a root tool (`sudo`, `pkexec`, `doas`, `run0`, `su`), as our QML rule already does.
* **Flagged** with a second confirmation: every `Review.RISKS` pattern, ported to Python in `omamobile-widget` and credited (download piped to a shell, `rm -rf`, `base64 -d`, `eval`, `dd`/`mkfs`/`shred`, reads of `.ssh`/`.gnupg`/tokens, a command, URL or file path built from widget values, notification access). Store widgets have passed this review in CI. Shared links have not ("nobody reviewed it"), and the sheet says so.

### 3.3 Limits on the phone (clamped in our copy of `OwlSource`, as a patch offered upstream as host options)

| Thing | Upstream | On the phone | Why |
| --- | --- | --- | --- |
| `cmd` interval | Any (default 60 s) | At least 2 s, which matches `host.run`. `clock` is exempt | Battery, and the same rule as QML |
| Timeout | Default 10 s, `timeout` has no cap | Default 10 s, at most 30 s | Same as `host.run` |
| Output | Unlimited (`cmd`), 1 MB (`http`, `file`) | 64 KiB for `cmd`/`stream` lines, 1 MB for `http`/`file` | Same as `host.run`. JSON feeds need more |
| `stream` | 4 per launcher | 2 across the home screen, all stopped when the screen is off | Each is a resident process |
| `run()` / actions from taps | No limit | One start per second per widget | Same as `launch` |
| `http` | At least 5 s | At least 60 s unless the user allows faster | Mobile data, once the modem works |
| Network | Runs at once | **Off until turned on** in the widget's settings, as for our network ports, with the listed hosts shown | Our privacy rule |
| `requires` install button | `pacman -Syu --needed` | **No silent install.** The tile says "needs jq". Its button opens a terminal running Omarchy's package install for those names, so the user sees the prompt and types the password | No widget triggers root. A partial `-Syu` with our pinned `[omamobile]` repository ordering is the user's call |
| `Terminal` node | Allowed | Allowed only after approval, as `commands` | It is a shell in a tile |
| `file()` of private paths | Flagged | Refused unless the user confirms per path | The same risk list |
| `androidApp(pkg)` | Opens the app | `waydroid app launch <pkg>` once [Waydroid](../device/cheetah/WAYDROID-PLAN.md) is installed. Until then, a "no Android here" report | Interop bonus |
| `launcher("store")` etc. | Launcher screens | `store` and `drawer` map to our Widgets sheet and app grid, `style`/`themes` to Omarchy's Style menu, `agents` to `omarchy-agent --pick`. `linux` does nothing | |

### 3.4 Actions

`OmamobileOwlHost.act()` sends `terminal`/`app` through `omamobile-launch` (one app per screen, as `host.launch` does) and `url` through `host.openUrl` for http(s). `tel:`/`geo:`/`mailto:` go through `xdg-open` only once handlers exist. `notify` uses `notify-send`, `copy` uses `wl-copy`, `share` copies and notifies (the runtime's default), `haptic` uses feedbackd (a short event, respecting the user's feedback setting), `torch` uses the quick-settings torch path, and `volume`/`media` use `wpctl` and `playerctl` (the runtime's defaults). **Announce before the first test of `haptic` and `torch` on the phone** (AGENTS.md §1).

### 3.5 Crash guard

The evaluator contains widget errors, but a runtime bug (a QML binding loop, a huge `Image`, a `Canvas` path that stalls the renderer) can still take down the shell. `OwlCell` calls the same `guardBegin(id, hash)` and `guardEnd` as `UserWidgetCell`, keyed by the `.owl` file's hash. A widget that crashed a load is held back at the next start and shows its error card with "Tap to fix with AI". The guard covers OWL and QML alike.

### 3.6 What stays out of reach

Neither format is a sandbox: both run as the user, inside the shell. OWL makes what a widget does **visible and reviewable**. QML can only make it **declared**. WIDGETS.md's sentence "these checks are guard rails, not a sandbox" stays true and goes into the OWL contract too. A real sandbox (commands run under `systemd-run --user` with `ProtectHome=read-only` or a Landlock wrapper, and network through a per-widget proxy) is possible later. It is out of scope here.

---

## 4. Theming, sizing and touch

### 4.1 Colours

Build the palette with `Owl.themeFromToml()` from the same `colors.toml` that Omarchy's shell reads (`~/.local/state/omarchy/current/theme/colors.toml`), watched, so a theme switch restyles OWL tiles at the same moment as `qs.Commons`. Then override the names that must read on **our card** rather than on a bare background:

| OWL name | Ours |
| --- | --- |
| `foreground` | `host.foreground` (Home's card text colour) |
| `muted` | `host.dimForeground` |
| `background`, `surface` | `Commons.Color.menu.background`, and that colour mixed toward the foreground |
| `border` | `Commons.Color.menu.border` |
| `accent` | `Commons.Color.accent` |
| `red` | `Commons.Color.urgent` when the theme has no `red` |
| `color0`-`color15`, `bright_*`, the other hues | From `colors.toml` as upstream derives them |

A check on the laptop compares `themeFromToml` against `qs.Commons` for all bundled Omarchy themes and lists any name whose colour differs by more than a small ΔE, so the two never quietly drift apart.

### 4.2 Fonts and corners

`OwlHost.monoFamily`, `sansFamily` and `iconFamily` all take `Style.font.family` (Omarchy's Nerd Font). OWL's text defaults to monospace, as the launcher draws it. `corners` comes from `Style.cornerRadius`: 0 maps to 0, at most 6 px maps to 0.5, otherwise 1. Simon's runtime hard-codes 0 for Omarchy, so this needs `bridge.tile("corners")` read from the host (a small upstream patch).

### 4.3 Grid, sizes and dp

| | Omalauncher | Our home screen |
| --- | --- | --- |
| Grid | 6 columns, about 12 rows, square 69 dp cells | 4x6 by default (3-6 by 4-8), cells about 120x150 logical px on 480x1040 |
| Sizes | `size: 3x2`, `minSize` | `size`/`min`/`max` in our cells |

Approach: **one OWL dp per phone**, from the width, as `shell.qml` does: `dp = (gridWidth / 6) / 69`, about 1.16 logical px on the Pixel 7 Pro. Every OWL tile then draws at the proportions it was designed with, whatever our grid. Sizes convert with that pitch:

* our `w = clamp(round(owlW × columns / 6), 1, columns)`, and our `h = clamp(round(owlH × owlPitch / ourCellHeight), 1, rows)`;
* `min` from `minSize` the same way (rounded up), and `max` equal to the grid;
* the widget reads `cols = round(cardWidth / owlPitch)`, `rows = round(cardHeight / owlPitch)`, and `tileWidth`/`tileHeight` = card size / dp, so its own `if cols < 3` layouts pick the right variant;
* `screenWidth`/`screenHeight` = the screen surface / dp.

Checked against our existing ports: upstream `forecast` is `6x3` and our port is `4x2`. `3x2` tiles become `2x1`. A user who sets a 6-column grid in Pages gets an exact column match. Tiles wider than their `size` (landscape, when auto-rotate is on) work, since OWL widgets already read `tileWidth`.

### 4.4 Screens and the keyboard

`screen()` opens a full-screen sheet in Home's overlay layer (the same layer as the Widgets sheet), titled with the screen's `title`, with a close button. Back, the home gesture and `close()` close it. `OwlNode` renders `widget.screenTree`. `Input` focus calls `fieldFocused(true)`, which shows squeekboard through the same path the launcher field uses. Our keyboard plugin's hide button covers the other direction. The home surface needs keyboard focus while a screen is open (the launcher's `WlrLayershell` focus mode), and focus must go back when the screen closes.

### 4.5 Touch, editing and performance

* **Tap** goes to `TapHandler` and needs no change. **Long-press** belongs to the home screen in both projects, so edit mode is entered the same way. While `editing` is on, OWL handlers are disabled, so taps move and resize.
* **`onDrag`** (3 store widgets) competes with the sideways page swipe. Give it the drag only after the first 10 px are more vertical than horizontal, or only after a tap has armed the tile, as upstream does for `Terminal`.
* **Touch targets:** OWL `Button`s are sized in dp, and at 1.16 px/dp a 28 dp button is about 32 px, under our 44 px rule. We don't rewrite widgets. We report undersized targets in `check` as a warning, and propose a minimum hit area in the runtime upstream.
* **120 Hz:** `FrameAnimation` runs only while `active && visible`. On the phone, `active` = the page or a neighbour is on screen, **and** the home surface is not covered by an app, **and** the panel is on (gs-decon `screen_off`). Widgets that read `time` are capped at 30 fps by a frame-skip in our copy (patch upstream as an `OwlHost.maxFps`). `Image { tint }` keeps `MultiEffect` (one static effect per image, which is acceptable). `Shader` already draws its fallback.

---

## 5. Catalogue

### 5.1 The store as our source of built-ins

* A new data package, **`omamobile-owl-widgets`**, pinned to an omarchy-widgets commit: every `widgets/<author>/<name>/widget.owl` (1.4 MB for 105 widgets, all `license: "MIT"`), `preview.png` (2.6 MB), `order.txt`, and the store's `index.json` shape built locally from the files (`id`, `version`, `owl`, `size`, `requires`, `commands`, `sha256`, `category`). It installs into `/usr/share/omamobile/owl-widgets/`. **Previews per theme are left out** (67 MB, 105 per theme). We render previews in the user's theme on the phone instead, lazily, by drawing the tile into an offscreen item with `grabToImage`, and cache them.
* The Widgets sheet gets a **Store** tab: categories (`news dev productivity time world fun home system`), store order (`order.txt`: listed ids first, the rest by name, the ids after `...` last), a preview, the description, the author, and a "runs N commands / uses the network" line.
* **Placing a store widget** copies its `widget.owl` into `~/.config/omamobile/widgets/<author>.<name>/widget.owl`, through the approval in §3.1, so the user's widgets folder stays the one place code is loaded from, and editing a placed store widget with AI changes the copy, not the package.
* **Updates.** The package update (`omarchy update`) ships new store files. For placed copies, the Widgets sheet shows "update available" when the package has a higher `meta.version` for an unmodified copy (the hash matches an older release's). Accepting re-runs the approval when the commands changed. A copy the user changed is never overwritten. **No network fetch of widget code without the user's action:** a later "Check the store now" button may fetch `index.json` and the widget files from GitHub Pages, but only when tapped, with each file verified against the index's `sha256` as Omalauncher does, and still through approval.

### 5.2 Retiring the 47 hand ports

Simon's `widgets/simonschubert/` has 48 widgets (it now includes `whats-new`, which we never ported). For each port:

| Verdict | When | Expected |
| --- | --- | --- |
| **Replace** with the upstream `.owl` | The runtime draws it as well as the port, and our additions are only settings that OWL keeps in `state … persist` with an `Input` | The large majority: the sports leagues, news feeds, clocks, `koi-pond`, `lava-lamp`, `owl`, `focus`, `habits`, `todo`, `year-progress`… |
| **Keep the port** for now | It depends on GeoClue `useLocation` (`air-and-pollen`, `forecast`, `today`, `sun-and-moon`, `planes-overhead`), or on our notification history (`notifications`) | Until a `location` source exists upstream (Q6) or we add one as a host extension |
| **Upstream our change** | The port fixed something real (theme colours instead of fixed hues, XHR instead of `curl \| jq`) | A pull request to the widget, so both sides benefit |

**Layout migration:** `HomeModel.normalize()` maps the old type (`earthquakes`) to the new one (`owl:simonschubert.earthquakes`) and moves known config keys into the widget's per-placement persisted state (`city` goes to `state city`, for example). The opt-in `enabled: true` carries over into the network approval. Ports stay in the package for one release after their replacement ships, so a bad replacement can be rolled back by setting a flag in `home.json`.

### 5.3 Shared links (`w/#owl1.…`)

The phone's Chromium sends a mobile user agent. If the page sees "Android", its **Open in Omalauncher** button becomes `intent://simonschubert.github.io/omarchy-widgets/w#Intent;…;S.widget=owl1.<data>;end`. Today `omamobile-open-intent` swallows every `intent://` link. Teach it one case: an intent whose host and path are the widget page and that carries `S.widget=owl1.…` decodes (inflate plus base64url, sizes capped) and opens the home screen's **Import widget** sheet, which shows the source, every command and the risk flags, and installs into `shared.<name>` only on approval. Also:

* **Paste a link** in the Widgets sheet (the same decoder), and support `omarchy-widgets import '<link>'` if Simon's desktop CLI is packaged for Omarchy (Q8);
* `#dpaste.<id>` links need a network fetch of widget code, so they are fetched only after the user taps "Fetch from dpaste.com", with the same review after;
* **Share** from our side produces the same `owl1` link (and a QR code later), so a widget made on our phone opens on Omalauncher.

### 5.4 One catalogue for someone who uses both

Same files, same store ids (`author/name`), same `meta.version`. Omalauncher keeps `~/.config/omalauncher/widgets/*.owl`, and we keep a folder per widget (`<author>.<name>/widget.owl`, which leaves room for a preview and for `.errors/`). Moving between them is a link, a copy, or a pull request to the store. Syncing a person's set between devices is out of scope. A shared format (`widgets.json` listing store ids and versions) would be a later conversation with Simon (Q9).

---

## 6. Creating widgets with AI

### 6.1 OWL by default

**Create a widget with AI** creates `~/.config/omamobile/widgets/<user>.<words>/widget.owl` from a new OWL template (a `meta { owl: 7 }` header, a `size`, a `Text`). It starts Omarchy's default agent as today (`omamobile-widget agent`, `omarchy-agent-prompt`) with a prompt that points to:

1. **The OWL language guide**: the launcher's `widgets/README.md`, vendored next to the runtime at the pinned commit and installed as `/usr/share/omamobile/shell/OWL.md`. If Simon moves the full guide into the store's `docs/LANGUAGE.md` (Q1), we vendor that instead;
2. **`WIDGETS-OWL.md`, our phone notes**, kept short: the folder rules (stay in the folder, no `sudo`, no package installs, no fetching widget code), the grid conversion (§4.3), "sizes in OWL cells, design for `3xN` and `6xN`", the network opt-in, the absent `android.*` features (`notifications`, `alarm`, `androidApp`), "no endless `time` animation unless it is the point of the widget", touch targets, and `omamobile-widget check .` to finish;
3. QML remains available: "Create a QML widget (advanced)" keeps today's template and `WIDGETS.md`.

**Edit with AI** works the same for both formats. For OWL it passes `.errors/<id>.txt` (which the runtime writes) instead of the scan's QML errors.

### 6.2 A checker on the phone without `owl.jar`

The launcher's `owl-check` compiles the file, waits for the live tile, reports runtime problems and **renders a preview PNG for the agent**. Options for us:

| Option | Compile and list commands | Run-time problems | Preview | Cost |
| --- | --- | --- | --- | --- |
| **A. `Owl.js` under node** (`omamobile-owl-check`, a short `check.js` that loads the vendored `Owl.js`, as `test/walk.js` does) | Yes, the same code the shell runs | No | No | `nodejs` (about 60 MB) as an optional dependency of `omamobile-shell`. It is usually already present on Omarchy for agent CLIs |
| **B. Ask the running shell** (`omarchy-shell shell call omamobile.home owlCheck <id>`) | Yes | **Yes**: it waits for the cell to load and returns `.errors/` | **Yes**: `grabToImage` of the live card into `.preview/<id>.png` | Only IPC. Needs the home screen running, which it always is on the phone |
| C. `owl.jar` with a JRE | Yes, the reference | No | No | About 200 MB of JRE on a phone, for nothing B lacks |
| D. QuickJS port of `check.js` | Yes | No | No | A new dependency, and more upkeep than A |

**Use B as the main check and A as the fallback** (when the shell isn't running, for CI, and for `omamobile-widget scan` at boot, before the shell is up). `omamobile-widget check .` tries B, falls back to A, and prints the same shape as `owl-check`: `compiles`, the problems, and `preview: <path> (3x2 cells, WxH px)`. The agent is told to open the preview, as Omalauncher's guide already tells it. The reference `owl.jar` runs only on the laptop, in a container, when the maintainer updates the vendored runtime (§8, P1).

---

## 7. Upstream contributions and questions for Simon

### 7.1 What we'd contribute

* **Runtime host options** instead of local patches: `maxFps`, clamps for interval, timeout and output, a stream cap, `corners` from the host, a hook to override `fmtTime` defaults for 12/24 hours, and a minimum hit area for `Button`.
* **Phone-portrait rendering fixes** found while bringing it up on Hyprland at 120 Hz (gesture arbitration for `onDrag` against page swipes, keyboard focus for `Input` in layer shells).
* **`owl-source` facts from a real Linux phone**: model and SoC from the device tree, display Hz from DRM, `modes.torch` from the LED class device, `modes.dnd` from the Omarchy notification daemon.
* **Our built-ins as OWL**: Clock (with system time format), Battery, Quick toggles (if a `toggles` source is accepted), Calendar (khal), Note. Our ports' fixes go back as pull requests to the original widgets (§5.2).
* **Tests**: the size conversion and palette mapping as fixtures; our phone `check.js` if it is useful to the desktop Widgets app.

### 7.2 Questions for Simon

| # | Question |
| --- | --- |
| Q1 | **Spec home and stability.** The store's `docs/LANGUAGE.md` lags the launcher's guide (level 7). Can the full guide live in the store repository, versioned, with a changelog per `owl:` level? Will a level, once released, never change meaning? |
| Q2 | **Runtime releases.** Would you tag `runtimes/quickshell` releases (or publish a package) that we pin, and keep `OwlHost` as a stable embedding API? Are you open to the host options in §7.1? |
| Q3 | **Permissions model.** The store reviews commands and the app asks again on changes. Would you accept a machine-readable capability summary in `index.json` (`commands`, `network` hosts, `files`, `notifications`) so both hosts show the same approval screen? Would you consider `http` hosts as a declared allow-list? |
| Q4 | **Settings.** Would a typed `settings { city: text; units: choice("C", "F") }` declaration (rendered by the host as a settings sheet, read as values, persisted per placement) fit OWL? Both hosts would then get settings sheets, and widgets would stop rebuilding settings UIs with `Input`. |
| Q5 | **Time format.** A `timeFormat` tile variable (the user's 12/24-hour choice), or `fmtTime(now, "time")`? |
| Q6 | **Location.** A coarse `location` source (`{lat, lon}` rounded to about 1 km, null until the user allows it), from Android on the launcher and GeoClue here? It would retire IP geolocation via wttr.in in the weather widgets. |
| Q7 | **Theme tokens.** Is `themeFromToml` the reference mapping for Omarchy themes? We want `foreground`/`muted`/`surface` to come from the card the host draws. Should hosts be allowed to override names, and which names are fixed? Can `corners` be non-zero on Linux hosts whose theme rounds? |
| Q8 | **Shared links.** May the `w/` page offer a non-Android "open" path (a custom scheme or `web+owl:`) that a Linux phone can register? Is `omarchy-widgets import` packaged anywhere we can depend on? |
| Q9 | **Catalogue governance.** Can widgets that only make sense on Linux phones, or on Omarchy Mobile, live in the same store (a `hosts:` or `needs:` field)? Who reviews pull requests from our users, and can we co-maintain? Would you consider a shared "my widgets" list format for people who use both? |
| Q10 | **Licensing of previews.** Widgets declare `license` in `meta`. Are `preview.png` and `previews/*.webp` covered by the widget's licence or by the repository's MIT licence? They show theme wallpapers and third-party data (sports crests, comics). We need this before shipping them in a package. |
| Q11 | **Naming.** Can we say "OWL widgets" and "works with the Omalauncher widget store" in our UI and README, and is there a mark you'd rather we avoid? |

---

## 8. Phased plan

The effort figures assume one developer, with the human approving phone steps. They are estimates. No phase reboots or flashes anything. Every phone step is a package install and a shell restart (`omarchy-restart-shell`), **announced before it runs** because it redraws the screen.

| Phase | Work | Effort | Tests and exit criteria |
| --- | --- | --- | --- |
| **P0** Agree | Send §7.2 to Simon. Pick the pin. Get answers to Q1, Q2 and Q10 at least | 0.5 d plus waiting | Written answers recorded in this plan |
| **P1** Vendor the runtime | `plugins/omamobile.home/owl/` at the pin, `VENDOR`, licence, `tools/owl-runtime-update`, `patches/owl-runtime/`. Run upstream `test/run.sh` **on the laptop in a container** (Java plus node) at each update | 1 d | `run.sh` passes at the pin. Our patches apply. CI diff check: the vendored files equal the pin plus our patches |
| **P2** `OwlCell` and host | `OwlCell.qml`, `OmamobileOwlHost`, palette mapping, dp and size conversion, `editing`, `active` gating (page, cover, panel off), per-placement `stateDir`, crash guard, error card, `screen` sheet, `Input` and squeekboard, action mapping, clamps (§3.3), 30 fps cap | 4-5 d | Node unit tests for size conversion, palette and clamps (in `test/home-model.js` style). Desktop harness (`phone/dev/run-desktop`, when allowed) with 20 store widgets. On the phone: screenshots of each verdict, frame times at 120 Hz with 6 OWL tiles, and an A/B battery drain with `tools/power-ab` (8 OWL tiles against 8 ports) |
| **P3** Scan, check and approval | OWL branch in `omamobile-widget scan/check`, `check.js` under node (A), IPC check with preview (B), `Review.RISKS` port, `widget-approvals.json`, approval sheet, re-approval on command changes | 3 d | Golden tests: the 105 store widgets compile, with their command lists equal to a laptop run of `owl.jar review` (same container as P1). Crafted bad widgets (a `sudo`, `curl \| sh`, a built URL, `owl: 99`) are refused or flagged. The guard holds back a widget that crashes a load |
| **P4** Catalogue package and Store tab | `omamobile-owl-widgets` PKGBUILD, a local index, the Store tab with categories and order, offscreen previews in the user's theme, copy-on-place, an "update available" flow | 3-4 d | Package builds. Sizes as measured. Placing, updating (copy unmodified, then modified), and an approval prompt when commands change. No network access during install (checked with ufw logging) |
| **P5** Replace the ports | Per-port verdict table (§5.2), screenshots of port and OWL side by side, layout migration in `HomeModel.normalize()` with config-to-state moves, rollback flag, and PRs upstream for port fixes | 4-5 d | A migration test over sample `home.json` files (every port type, opt-in on and off). Screenshot review by the human. One release with both, then the ports are removed |
| **P6** AI creation in OWL | Template, `OWL.md` vendored, `WIDGETS-OWL.md`, prompt, the "QML (advanced)" path, Edit with AI reading `.errors/` | 2 d | Five prompts made end to end with the default agent on the phone (the human watches). Each passes `check` with a preview the agent looked at. Each is under 6 KB, so it fits one link |
| **P7** Links and sharing | `omamobile-open-intent` case for `S.widget=owl1.…`, Import sheet, paste-a-link, dpaste on tap, Share to an `owl1` link | 2 d | Decoder unit tests (sizes, damaged links, oversized inflate). A link from Omalauncher installs on our phone, and one from our phone opens on Omalauncher (needs an Android phone and Simon's help) |
| **P8** Upstream | Host options, `owl-source` facts, our built-ins as OWL, fixtures | Ongoing, about 3 d | Merged upstream. Our patch directory shrinks |

**Total:** about 20-25 days of work, plus the waiting time in P0.

### 8.1 Migrating existing user QML widgets

Nothing breaks: QML user widgets keep loading through `UserWidgetCell` and `WIDGETS.md`. The Widgets sheet labels them "QML". **Convert to OWL with AI** (an action on each QML widget) starts the agent in a **new** folder (`<id>-owl`) with both contracts and the QML as input. The user compares the two and removes one. Nothing is converted automatically: the QML side may use APIs OWL lacks, and the agent should say so instead of guessing.

### 8.2 Risks

| Risk | Mitigation |
| --- | --- |
| Spec churn (level 1 to 7 within weeks), and the runtime moving in lockstep with `owl.jar` | Pin, and update deliberately with `run.sh`. Refuse widgets above our `LEVEL` with "update Omarchy Mobile". Ask for stability (Q1, Q2) |
| GUI-thread cost: evaluation, Compose-style layout in JS, Canvas replay at 120 Hz | `active` gating, the 30 fps cap, and power and frame-time measurements in P2 before OWL becomes the default |
| `bash -c` commands, as opposed to our argv rule | Commands are static and listed, with approval per hash, the risk flags, refused root tools and clamps. The "not a sandbox" sentence stays in both contracts |
| The store's widgets assume Android (`android.notifications`, `androidApp`, alarm) | Hide widgets whose sources we can't serve, using the compiled source list, or mark them "partial" in the Store tab |
| Two catalogues drifting (store ids against our copies) | Copies keep `author.name` and the upstream hash. "Modified" is computed, never guessed |
| Preview licensing unclear | Ship `preview.png` only after Q10. Theme previews are rendered locally anyway |
| Our patches to the runtime pile up | Each patch has an upstream PR link in `patches/owl-runtime/`. Review the list at every pin update |
| Agent quality in OWL compared with QML | P6 exit criteria, the preview loop, and keeping the QML path open |
| `intent://` handling widens what the browser can push into the shell | Accept only the exact host and path and the `owl1` payload, cap the inflated size, and never install without the approval sheet |
