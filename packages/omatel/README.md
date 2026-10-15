# omatel

Omarchy Mobile's Phone (`omaphone`) and Messages (`omamessages`) apps and
`omatel-agent`, the background service both need. They are modelled on
AOSP's Dialer and Messaging; Rust, GTK 4 and libadwaita
([TELEPHONY-APPS-PLAN](../../docs/TELEPHONY-APPS-PLAN.md) T6/T7, §10.1b).
The code lives in its own repository, `omatel` (GPL-3.0-or-later). This
package builds a pinned release from it.

**One build, three packages:**

- `omatel-agent`: rings for calls, writes the call log, stores incoming
  SMS and raises notifications. It serves `org.omamobile.Phone1` and
  `org.omamobile.Messages1`.
- `omaphone`: the Phone app.
- `omamessages`: the Messages app.

Both apps depend on the agent, so either can be installed alone.
`omamobile-apps` doesn't pull them in yet; that waits for the phone tests
in the plan's runbook. The agent's user unit ships disabled. Enable it per
user with `systemctl --user enable --now omatel-agent`; D-Bus activation
also starts it when an app needs it.

**Emergency calls are not supported.** Phone says so and the agent refuses
emergency numbers, until the plan's §3.3 tests pass.

## Releases

1. Tag the release `vX.Y.Z` in omatel and push the tag.
2. Set `pkgver` here.
3. Put the sha256 of GitHub's tarball in `sha256sums`:
   `curl -sL https://github.com/derekross/omatel/archive/refs/tags/vX.Y.Z.tar.gz | sha256sum`.
4. Run `tools/build-packages packages/omatel`.

0.1.1 (US English, the `favorites` table renamed by a migration) waits for
step 3: its `sha256sums` is a placeholder until the repository and the tag
exist.

## Build

- `tools/build-packages packages/omatel` builds under qemu-user: 34
  minutes for 0.1.0 on the laptop (2026-10-14), with `check()`.
- While developing omatel, cross-compile with its `bin/cross package`
  instead: about four minutes cold, seconds after that. It makes the same
  three packages.
- `check()` runs the D-Bus-free unit tests: contacts, numbers, the stores
  and the API types. The D-Bus, agent and chain tests run on the laptop
  with omatel's `scripts/check.sh` and `scripts/chain-test.sh`.
