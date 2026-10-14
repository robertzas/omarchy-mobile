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

**Until the repository is published,** the source is a local tarball:

1. Run `git -C ~/Projects/omatel archive --format=tar --prefix=omatel-$pkgver/ <commit> | gzip -n > packages/omatel/omatel-$pkgver.tar.gz`.
   The file is gitignored. makepkg uses a local file of the source's name
   instead of downloading it.
2. Put its sha256 in `sha256sums`.

0.1.0 is omatel commit `dd03594`.

**Once it is published:**

1. Tag the release `vX.Y.Z` in omatel and set `pkgver` here.
2. Replace `sha256sums` with the sha256 of GitHub's tarball:
   `curl -sL https://github.com/derekross/omatel/archive/refs/tags/vX.Y.Z.tar.gz | sha256sum`.
   It differs from the local archive's.
3. Run `tools/build-packages packages/omatel`.

## Build

- `tools/build-packages packages/omatel` builds under qemu-user. See the
  plan for the time it took.
- While developing omatel, cross-compile with its `bin/cross package`
  instead: about four minutes cold, seconds after that. It makes the same
  three packages.
- `check()` runs the D-Bus-free unit tests: contacts, numbers, the stores
  and the API types. The D-Bus, agent and chain tests run on the laptop
  with omatel's `scripts/check.sh` and `scripts/chain-test.sh`.
