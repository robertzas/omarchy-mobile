# omandroid-shell

Omandroid's phone profile for Omarchy's own shell. It isn't a fork: these are ordinary Omarchy shell plugins plus a phone `shell.json`, linked into the user's config by `omandroid-setup-user`.

| Path | What it is |
| --- | --- |
| `plugins/omandroid.bar` | Phone status bar (a full `bar` plugin) |
| `plugins/omandroid.quicksettings` | Pull-down quick settings |
| `plugins/omandroid.launcher` | Home bar: app search, app grid and a prompt to the user's Omarchy default agent |
| `profile/shell.json` | The phone layout the setup seeds once |
| `bin/omandroid-setup-user` | Omandroid's per-user setup (Omarchy lifecycle `setup-user`) |
| `bin/omandroid-bt-agent` | BlueZ pairing agent and discovery helper the quick-settings Bluetooth panel runs while open |

The package contract follows omarchy-mac's: `./install DESTDIR` stages files and enables nothing, `test/all` runs the package's own tests, and `version` holds the version.

Develop on a desktop with `phone/dev/run-desktop` from the repo root.
