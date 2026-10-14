# omamobile-shell

Omarchy Mobile's phone profile for Omarchy's own shell. It isn't a fork: these are ordinary Omarchy shell plugins plus a phone `shell.json`, linked into the user's config by `omamobile-setup-user`.

| Path | What it is |
| --- | --- |
| `plugins/omamobile.bar` | Phone status bar (a full `bar` plugin) |
| `plugins/omamobile.quicksettings` | Pull-down quick settings |
| `plugins/omamobile.launcher` | Home bar: app search, app grid and a prompt to the user's Omarchy default agent |
| `plugins/omamobile.switcher` | Recent apps: swipe up on the dock; hold a card to show the app with another one, or give it its own screen again |
| `plugins/omamobile.home` | Home screens: pages of apps and widgets on the wallpaper, with an edit mode. The built-ins include every widget in Simon Schubert's [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets) `widgets/simonschubert/` (MIT): the OWL originals, from the `omamobile-owl-widgets` package, run by our own OWL runtime (`owl/`, see `owl/SPEC-NOTES.md`). `widgets/OWL.md` is his OWL language guide (MIT, `widgets/LICENSE-owl-guide`) |
| `plugins/omamobile.keyboard` | Hide button above the on-screen keyboard |
| `plugins/omamobile.update` | The update sheet: Omarchy's update for a phone, through `omamobile-update` (package `omamobile-omarchy`) |
| `plugins/omamobile.fingerprint` | The under-display fingerprint sensor: target during verification, enrollment screen |
| `profile/shell.json` | The phone layout the setup seeds once |
| `bin/omamobile-setup-user` | Omarchy Mobile's per-user setup (Omarchy lifecycle `setup-user`) |
| `bin/omamobile-launch` | One app per screen: every launch from the shell (drawer, home screen, widgets, links, the agent) gets a new empty workspace through a per-launch Hyprland exec rule, or focuses the app's open window; and the switcher's "Show with…" and "Move to its own screen" |
| `bin/omamobile-osk-watch` | Reports squeekboard's visibility (sm.puri.OSK0) to the fingerprint plugin |
| `bin/omamobile-fp-enroll` | fprintd enrollment helper the fingerprint screen runs (JSON lines) |
| `bin/omamobile-bt-agent` | BlueZ pairing agent and discovery helper the quick-settings Bluetooth panel runs while open |
| `bin/omamobile-widget` | The user's own home-screen widgets: scan and check them, make one from the template, copy an example, remove one, start Omarchy's default agent in a widget's folder |
| `widgets/WIDGETS.md` | The contract for user widgets, for people and coding agents (installed to `/usr/share/omamobile/shell/`) |
| `widgets/template`, `widgets/examples` | The starter **Create a widget with AI** copies, and examples to copy (`widget-template/`, `widget-examples/`) |

The package contract follows omarchy-mac's: `./install DESTDIR` stages files and enables nothing, `test/all` runs the package's own tests, and `version` holds the version.

Develop on a desktop with `phone/dev/run-desktop` from the repo root.
