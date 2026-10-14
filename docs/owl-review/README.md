<!-- SPDX-License-Identifier: MIT -->
# OWL widgets on Omarchy Mobile: review package, milestone 1

**Status (2026-10-13):** built and tested on the laptop only, on branch `owl-widgets`. **Nothing has been installed on the phone, and nothing will be until you have reviewed this and said yes.** Everything is behind a feature flag that is off by default, so even an installed package changes nothing on its own.

This is the first milestone of [WIDGET-INTEROP-PLAN.md](../WIDGET-INTEROP-PLAN.md), option (c): **our own OWL runtime**, written from the language guide, held to Simon Schubert's runtime by a conformance suite that runs his only as a black box inside a container. None of his code is in our tree.

Contents: [how it works on the phone](#how-it-works-on-the-phone) · [screenshots](#screenshots) · [how faithful it is](#how-faithful-it-is) · [tests](#tests) · [what is not done](#what-is-not-done-yet) · [trying it on the phone](#trying-it-on-the-phone-only-after-your-ok) · [questions for Simon](#questions-for-simon) · [the next phases](#the-next-phases)

---

## How it works on the phone

### Turning it on

OWL widgets stay invisible until `~/.config/omamobile/features.json` holds:

```json
{ "owlWidgets": true }
```

The home screen watches that file. With the flag off, OWL folders are not listed and a placed OWL widget shows a card saying the feature is off; QML widgets and built-ins are untouched either way.

### Adding an OWL widget

1. Put a widget in its own folder: `~/.config/omamobile/widgets/<author>.<name>/widget.owl` (for example a store widget's file). The folder rules are the same as for QML widgets: at most 64 files and 1 MiB, nothing linking outside it. `widget.owl` itself may be up to 256 KiB.
2. The scan (`omamobile-widget scan`, run by the home screen whenever the folder changes) lists the folder as an OWL widget. The home screen compiles it with our runtime.
3. Long-press, **Widgets**. OWL widgets appear under **YOURS** with an `OWL` tag, their size in our cells and what they do: "runs 1 command, uses the internet (earthquake.usgs.gov)". One that needs approval says "needs your OK: …"; one that doesn't compile shows its first error in red.
4. Tapping one that isn't approved opens the **approval sheet** (below). **Allow and add** stores the approval and places the widget; **Not now** goes back.
5. On the page it runs at once. Long-press moves and resizes it like any widget.

A widget whose file doesn't compile can still be placed: its card shows the error with line, column and a caret, and "Tap to fix with AI".

### The approval sheet

The words, as the phone shows them (screenshots: [earthquakes](screens/approve-earthquakes-tokyo-night.png), [a made-up risky widget](screens/approve-risky-tokyo-night.png)):

> **Allow "earthquakes"?**
>
> This OWL widget runs inside the home screen, as you. Omarchy Mobile read its file and lists everything it can do below. Nothing runs until you allow it, and if the widget changes what it runs, it asks again.
>
> **Runs this command** — the full text of every command, in a box.
>
> **Uses the internet** — "It talks to earthquake.usgs.gov." and a **Use the internet** switch, off by default: "Off: whatever uses the internet waits until you turn it on, as for the built-in widgets."
>
> **Reads these files** — every path.
>
> **Needs curl, jq** — "It never installs anything. If a package is missing, install it yourself (Omarchy's Install package)."
>
> **⚠ Look twice** (only when it applies, in red) — "It downloads something and runs it as a script: …", "It deletes files recursively (rm -rf): …", "runs a command built while it runs", "reads keys, tokens or passwords", "reads your notifications".
>
> From your widgets folder (~/.config/omamobile/widgets/simonschubert.earthquakes). Nobody reviewed it. This is a guard rail, not a sandbox: an allowed command runs with your rights.
>
> [**Allow and add**] [Not now]

The list on the sheet is not a guess: our compiler lists **every** command, web address and file a widget can reach, the same list (same strings, same order) the reference compiler produces (L2 below). Capabilities are derived from that list, never declared by the widget. The approval is stored per widget in `~/.config/omamobile/widget-approvals.json` as that exact list, plus the internet switch. If an update changes the list, the widget stops and its card says "It changed what it runs. Before it runs: …" until you allow it again; a change to layout or text alone doesn't ask.

### What a widget can and can't do

| It can | Where the limit is |
| --- | --- |
| Run the commands listed on the sheet, with `bash -c`, as you | Only after approval; under `timeout` (default 10 s, at most 30 s); at most every 2 s; output cut at 64 KiB; a command that uses the network (curl, wget, …) waits for the internet switch |
| Fetch web addresses with `http(...)` | GET only, at most 1 MB, a timeout, at most every 60 s, only with the internet switch on, only to the addresses listed |
| Read files with `file(...)` | Listed on the sheet; at most 1 MB |
| Show pictures | Local files (`~/…`, `/…`) and pictures embedded in the widget; **never a web address** (that would be an unlisted network fetch) |
| Open a link, a terminal or an app on a tap, copy, notify, set the volume, control media | One action a second; links through `omamobile-launch` (one app per screen) |
| Keep state across restarts (`state … persist`) | Per placement: the same widget placed twice keeps two states |

| It can't | Why |
| --- | --- |
| Run anything as root | A command naming `sudo`, `pkexec`, `doas`, `run0` or `su` is refused outright: the card says "Can't run on this phone" |
| Install packages | `requires { pacman: [...] }` is shown, never acted on |
| Load QML, reach the shell's objects, or import code | OWL has no way to name them; the runtime only draws its own node types |
| Hang the home screen with a loop | 200,000 evaluation steps per update, 500 nodes per tile, 2,000 drawing calls per frame, lists of 1,000; over a cap, that value shows `…` and the rest draws |
| Use `Terminal`, haptics or the torch, Android apps or notifications | Not served yet (below); the widget says "not available on this phone yet" in its error log |

### Theming

Colours come from the Omarchy theme's `colors.toml` with every OWL name filled in (the same derivation as the reference: all 22 bundled themes match exactly). On our card, `foreground`, `muted`, `background`, `surface`, `border` and `accent` come from the shell's own card colours, so OWL tiles read like our built-ins. A theme switch restyles them at once. Text is Omarchy's font (JetBrainsMono Nerd Font, as the launcher draws monospace). `corners` follows the theme's rounding (0 on a square theme). Compare [dark](screens/home-page1-tokyo-night.png) and [light](screens/home-page1-catppuccin-latte.png).

### Sizes

Omalauncher's grid is 6 columns of 69 dp; ours is 4x6 by default. We define one OWL dp from the phone's width (480 / 6 / 69 = 1.16 logical px), so every widget keeps the proportions it was designed with, and convert sizes: columns by 4/6, rows by pitch (69 dp = 80 px against our 151 px cells). The 14 milestone widgets:

| Widget | Store size | On our grid | Uses |
| --- | --- | --- | --- |
| simonschubert/analog-clock | 3x3 | 2x2 | Canvas, clock |
| simonschubert/calendar | 3x3 | 2x2 | Grid, clock |
| simonschubert/countdown | 3x3 | 2x2 | a command, lists |
| simonschubert/year-progress | 3x3 | 2x2 | Progress, animation |
| simonschubert/focus | 3x3 | 2x2 | Ring, buttons, state |
| simonschubert/habits | 6x3 | 4x2 | a command, persisted state, taps |
| simonschubert/earthquakes | 6x3 | 4x2 | a command with the internet, a scrolling list |
| simonschubert/hacker-news | 6x4 | 4x2 | a command with the internet, two-line items |
| simonschubert/exchange-rates | 6x2 | 4x1 | a command with the internet, Sparklines |
| derekross/bitcoin | 6x2 | 4x1 | two web requests, an area Sparkline |
| simonschubert/xkcd | 6x5 | 4x3 | a command with the internet, a picture |
| lucassynnott/year-left | 3x4 | 2x2 | Canvas with 365 squares (step budget) |
| simonschubert/todo | 3x4 | 2x2 | a command, `run()` on a tap |
| simonschubert/koi-pond | 6x3 | 4x2 | Canvas animated by `time`, sprites |

A widget reads `cols`, `rows`, `tileWidth` and `tileHeight` of **our** card, so its own `if cols < 4` layouts pick the right variant when you resize it.

### Data refresh

One clock for the whole home screen (`OwlScheduler`): a tick on each second boundary runs whatever source is due, aligned to its period (`every 1m` turns over on the minute), and `every` triggers. Sources run only while the widget's page or a neighbour is shown and no app covers the home screen. Coming back runs everything due at once, so a widget never shows hours-old data. `at` triggers (alarms, timers) keep ticking while hidden. A tap that runs an action refreshes that widget's sources.

### Battery

* Animation (anything that reads `time`: the koi pond, a Canvas clock with a sweep) runs from a frame clock **capped at 30 fps**, and only while a shown widget actually reads `time` in what it draws now. Nothing else redraws between source updates.
* Everything stops while an app covers the home screen. **Not wired yet:** the panel-off signal (gs-decon `screen_off`); until it is, a home screen left showing behind a dark panel keeps ticking (measure in P5, below).
* A widget whose frames take over 20 ms drops to 15 fps.
* Updates are keyed: a source that changes one number updates that one item, it doesn't rebuild the tile.
* No live effects (blur, shaders): a tinted picture is recoloured once.

The plan's P5 measurements (frame times at 120 Hz with 6 OWL tiles, CPU while hidden, an A/B drain with `tools/power-ab`) need the phone and are not done.

### When something goes wrong

| What | What you see |
| --- | --- |
| The file doesn't compile | An error card with line, column and a caret ([page 4](screens/home-page4-tokyo-night.png), "moon phase"); "Tap to fix with AI" |
| It uses something this phone refuses | An error card: "Can't run on this phone: runs a root tool: …" |
| It isn't approved, or changed what it runs | A card with a shield: "Before it runs: runs 2 commands, uses the internet (…)", "Tap to review" ([page 4](screens/home-page4-tokyo-night.png), "wallpaper of the day") |
| A value fails while it runs (over budget, a bad pattern) | That value shows `…`; the rest of the tile draws. The last 20 problems go to `~/.local/state/omamobile/owl/errors/<id>.txt` and the log |
| A command fails or times out | Its value doesn't update; stderr's first line goes to the error log |
| The widget crashes the shell | The existing crash guard: the widget is recorded while it starts; if the shell dies then, it stays off at the next start with "This widget crashed the shell, so it's off. Edit it to try again." until its file changes |

The error log lives outside the widget's folder (the plan said `.errors/` inside it): writing there would trigger the folder watcher and a rescan on every error.

### Creating widgets with AI (later, P10)

Today "Create a widget with AI" still makes QML widgets. In P10 it will make OWL by default: a folder with a `widget.owl` template, the agent pointed at the language guide and a short phone notes file, and `omamobile-widget check .` (or `shell call omamobile.home owlStatus <id>`, which exists now) to see compile errors, the commands list and a preview. An agent's mistake in OWL is a `…` or an error card, not a crash loop; what it can run is shown on the approval sheet before anything runs (a widget the user's own agent made is approved by making it, per the plan, but still listed). "Fix with AI" on an OWL error card currently starts the agent with the QML contract; it gets the OWL guide in P10.

---

## Screenshots

Rendered offscreen in the conformance container at the phone's resolution (1440x3120, scale 3, logical 480x1040, the shell's real geometry: 44 px bar, 72 px dock, 4x6 grid). The home cells, the Widgets sheet and the approval sheet are the real `OwlCell`, `OwlView` and `HomeSheets` code with Omarchy's own `Commons`/`Ui` modules, over a stand-in for `Home.qml` that answers sources from fixtures. **The status bar, the dock and the wallpaper are plain stand-ins.** All data is made up for the tests (no real feeds, accounts, places of yours or identifiers).

| | Dark (tokyo-night) | Light (catppuccin-latte) |
| --- | --- | --- |
| Page 1: clock, calendar, bitcoin, exchange rates, focus, year progress | [page 1](screens/home-page1-tokyo-night.png) | [page 1](screens/home-page1-catppuccin-latte.png) |
| Page 2: earthquakes, hacker news, countdown, todo | [page 2](screens/home-page2-tokyo-night.png) | [page 2](screens/home-page2-catppuccin-latte.png) |
| Page 3: koi pond, habits, year left | [page 3](screens/home-page3-tokyo-night.png) | [page 3](screens/home-page3-catppuccin-latte.png) |
| Page 4: xkcd (a stand-in picture), a widget waiting for approval, an error card | [page 4](screens/home-page4-tokyo-night.png) | [page 4](screens/home-page4-catppuccin-latte.png) |
| The Widgets sheet with OWL widgets | [sheet](screens/widgets-sheet-tokyo-night.png) | [sheet](screens/widgets-sheet-catppuccin-latte.png) |
| Approval: earthquakes | [approve](screens/approve-earthquakes-tokyo-night.png) | [approve](screens/approve-earthquakes-catppuccin-latte.png) |
| Approval: a made-up risky widget (`curl … \| bash`, `rm -rf`) | [approve](screens/approve-risky-tokyo-night.png) | [approve](screens/approve-risky-catppuccin-latte.png) |

<img src="screens/home-page1-tokyo-night.png" width="240"> <img src="screens/home-page2-catppuccin-latte.png" width="240"> <img src="screens/approve-earthquakes-tokyo-night.png" width="240"> <img src="screens/home-page4-tokyo-night.png" width="240">

**Ours against the reference**, one picture per widget in [`side-by-side/`](side-by-side/): our tile, the reference runtime's tile, and their difference (red), at the same card size, theme, fonts and data.

<img src="side-by-side/simonschubert.analog-clock.png" width="480"> <img src="side-by-side/simonschubert.calendar.png" width="480">

---

## How faithful it is

`tools/owl-conformance --live --render` (output in [conformance.txt](conformance.txt) and [render-report.json](render-report.json)), with the reference at omarchy-widgets `b63886b`:

| Level | What | Result |
| --- | --- | --- |
| L1 compile | Accepted or rejected alike, rejects at the same line and column | **105/105** store widgets, **14/14** milestone widgets, **20/20** malformed probes |
| L2 capabilities | The same commands list, same strings and order; same derived capabilities | **105/105**, **14/14** |
| L3 evaluation | Every evaluated property and drawing call, as JSON, numbers to 1e-9 | **105/105** store widgets without data; **14/14** with data; **5/5** expression probes (about 300 expressions) |
| Palette | Our theme derivation against the reference's, every bundled Omarchy theme | **22/22** identical |
| L4 layout | Every node's box within 1 dp (Text 2 dp) | **13/14**. Calendar differs: its `Grid` rows are 6 dp taller in the reference, whose `GridLayout` rounds rows to whole pixels and sizes some by the font's own height; ours keep the guide's 1.17 em lines. The days sit in the same cells |
| L5 pixels | Share of pixels more than 10% apart | 0% (clock, year left, koi pond: identical) to 1.5% (calendar); the rest under 1.4%, from glyph positions a pixel apart. Reviewed by eye in `side-by-side/` |

Where the guide was silent we followed what the reference does and wrote the rule in our own words in [`owl/SPEC-NOTES.md`](../../packages/omamobile-shell/plugins/omamobile.home/owl/SPEC-NOTES.md) (N1-N38). One deliberate difference: `on x { }` doesn't fire for x's first value, as the guide says (the reference fires; N8).

The reference outputs for the milestone widgets and our probes are recorded once as our expectations (`tests/owl/expected/`, `packages/omamobile-shell/test/owl-probes/*.expected.json`), so our unit tests check them without the container.

## Tests

| Suite | Result |
| --- | --- |
| `packages/omamobile-shell/test/all` (the package's suite, with the new `owl-core.js` and the scan test) | all pass (162 checks) |
| `test/owl-core.js`: probes against the recorded reference outputs, error positions and carets, level rules, the commands list, constant folding, number printing, `sh()` through bash with hostile input, the step budget, 500 nodes, 2,000 drawing calls, lists of 1,000, a self-feeding trigger, the 10-a-second trigger limit, history/prev/persist, `at` after a restart, actions, `time` tracking, dp and size conversion, palette, capabilities and risk flags, source limits, layout rules, the home screen's card states | 54/54 |
| `tests/owl/lint/new-warnings`: qmllint warnings added to the home plugin | none on **Qt 6.11.2** (laptop) and none on **Qt 6.12.0** (container), which flagged one id shadowing a member (fixed). New code in `Home.qml`/`HomeSheets.qml` follows those files' existing unqualified-id pattern (20 accesses, reported as a count) |
| `tools/owl-conformance --live --render` | above |

## What is not done yet

| Gap | Phase |
| --- | --- |
| `screen { }` full-screen views and `screen()`/`close()`: they compile, the action reports "not served yet" | P6 |
| `stream(...)` sources (2 of 105 store widgets) | P5 |
| `file(...)` is read when due, not watched for changes | P5 |
| `android.media`, `volume`, `modes`, `notifications`, `system`, `device`: answered with fixed or empty shapes; `battery` reads the kernel | P5 |
| Pause while the panel is off | P5 |
| `haptic`, `torch`, `androidApp`, `notification()`, `share` (copies to the clipboard instead) | P5 (haptics and the torch announced before their first test) |
| `onDrag` competes with the page swipe; not tuned | P6 |
| Input fields and the on-screen keyboard | P6 |
| `Terminal` (3 store widgets): refused with a message | P11 |
| `omamobile-widget check` for OWL, the node checker, re-approval prompts for store updates | P7 |
| The store package and Store tab | P8 |
| Replacing the 47 hand ports | P9 |
| AI creation in OWL, shared links | P10 |
| Phone measurements: frame times, CPU while hidden, battery A/B | P5, on the phone |

## Trying it on the phone (only after your OK)

Nothing here has been run on the phone. If you approve, the steps would be (each announced before it runs, since it redraws the screen):

| Step | Command | Expect | Stop if | Rollback | Risk |
| --- | --- | --- | --- | --- | --- |
| 1 | Build and install `omamobile-shell` from `owl-widgets` (`tools/phone-install-package packages/omamobile-shell`), then `omarchy-restart-shell` | The home screen looks exactly as before (flag off) | Anything on the home screen changed | Reinstall the `main` package | Low: shell restart |
| 2 | Copy one widget without commands (analog clock) to `~/.config/omamobile/widgets/simonschubert.analog-clock/widget.owl`; write `{"owlWidgets": true}` to `~/.config/omamobile/features.json` | It appears under Widgets; Allow and add; it ticks | The shell restarts, or the guard holds it back | Remove `features.json` | Low |
| 3 | Add the koi pond; watch frame times and CPU with the page shown and covered | 30 fps at most while shown, nothing while an app covers it | Stutter in the page swipe | Remove the widget | Low |
| 4 | Add earthquakes; allow it with the internet off, then on | No request until the switch is on | A request with the switch off | Revoke in `widget-approvals.json` | Low |

## Questions for Simon

From the plan (§10.2), still open: Q1 a versioned spec in the store repository, Q2 runtime-neutral fixtures, Q3 a capability summary in `index.json`, Q4 typed settings, Q5 time format, Q6 a coarse location source, Q7 theme tokens and card overrides, Q8 a non-Android "open" path for shared links, Q9 catalogue governance, Q10 preview licensing, Q11 naming.

New from writing a second runtime against the guide:

1. **`on x { }` and the first value.** The guide says it doesn't fire for the first value and null doesn't count; the Quickshell runtime fires when a source first loads. Which is right? (We follow the guide.)
2. **Week start for `e`/`c` in `fmtTime`.** The jar leaves it to the launcher (the phone's locale); the calendar widget is drawn for Monday, the oracle runs Sunday. Could the spec say "the user's first day of the week", and the calendar widget read it?
3. **Grid row height.** Is a Grid row as tall as its tallest cell at the guide's 1.17 em lines (ours), or does the launcher size rows differently (the Quickshell runtime's `GridLayout` gives some rows the font's own height)?
4. **Division by zero gives 0** and **`alpha()` keeps the theme name** (so `alpha(accent, 0.5)` prints as `accent`): both in the jar, neither in the guide. Can they go into the spec?
5. **`Image { src: "https://…" }`** isn't in the guide's list (asset, path, app icon). We refuse web addresses in pictures, since they would be network access nobody approved. Is that the intent?
6. **The commands list as the approval surface.** We approve the exact list the compiler prints. Would you keep those strings stable across jar versions (or version them), so an update of the jar doesn't make every widget ask again?

## The next phases

Estimates from the plan, revised by what this milestone did (one developer; phone steps need you):

| Phase | Remaining work | Estimate |
| --- | --- | --- |
| P1-P3 | Done for this milestone; widen the probes as levels change | 0.5 d |
| P4 renderer | Screens, Input/keyboard, onDrag rules, animations checked on the phone, the calendar Grid difference, L4/L5 for all 102 non-Terminal store widgets (needs fixtures for each) | 5-6 d |
| P5 sources, scheduler, host | stream, file watching, android.* from MPRIS/UPower/wpctl, panel-off pause, actions left, **phone measurements** | 4-5 d |
| P6 home integration | Screen sheet, keyboard, instances that outlive layout edits, the "fix with AI" path for OWL | 2-3 d |
| P7 scan, check, approval | `omamobile-widget check` for OWL (node), IPC check with a preview, re-approval flows, crafted bad widgets on the phone | 2 d |
| P8 catalogue | `omamobile-owl-widgets` package (conformance-gated), Store tab, previews rendered locally | 3-4 d |
| P9 ports | Replace the 47 hand ports where the upstream widget passes | 4-5 d |
| P10 AI creation and links | OWL template, guide, prompt, shared links | 4 d |
| P11 Terminal | | 3-4 d |

About **27-33 days** remain to the plan's full scope, **15-19** to a first release that has store widgets with approval on the phone (through P8).

## Where things are

| Path | What |
| --- | --- |
| `packages/omamobile-shell/plugins/omamobile.home/owl/` | The runtime: `values.js`, `lexer.js`, `parser.js`, `builtins.js`, `compiler.js`, `runtime.js`, `layout.js`, `paint.js`, `phone.js`, `catalog.js`, the QML node items, `OwlView`, `OwlWidget`, `OwlScheduler`, `SPEC-NOTES.md` |
| `packages/omamobile-shell/plugins/omamobile.home/OwlCell.qml`, `OwlPhoneHost.qml` | The home-screen cell and the phone host (limits, commands, requests, state) |
| `Home.qml`, `HomeSheets.qml`, `UserWidgets.js`, `bin/omamobile-widget` | The flag, approvals, the Widgets sheet rows, the approval sheet, the scan's OWL branch |
| `packages/omamobile-shell/test/owl-*.js`, `owl-probes/` | Unit tests, our probes and their recorded reference outputs |
| `tests/owl/` | The conformance container, fixtures, recorded expectations, `conformance.js`, `render/` (L4/L5 and these screenshots), `lint/new-warnings` |
| `tools/owl-conformance` | Runs it all on the laptop: `--live`, `--record`, `--render` |
