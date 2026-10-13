# Rename: the steps outside git

The repository was renamed from Omandroid to Omarchy Mobile (`omamobile`) by
`tools/rename-omamobile` (Phase 1 of the rename plan; the old state is tagged
`omandroid-final`). The repository now refers to host-side names that don't
exist yet. Run these on the build laptop before the next kernel, image or
package build. None of them touches the phone.

This file names the old paths on purpose, so the rename tool skips it.

## 1. Docker build image

`omamobile.conf` now says `IMAGE=omamobile-build:24.04`, and `bin/omamobile`
runs it with `--hostname omamobile-build`.

```sh
docker tag omandroid-build:24.04 omamobile-build:24.04
docker image inspect omamobile-build:24.04 >/dev/null && docker rmi omandroid-build:24.04   # drops only the old tag
```

## 2. LineageOS source tree (`SRC_DIR`)

`omamobile.conf` now has `SRC_DIR="$HOME/android/omamobile"`. `bin/omamobile`
takes `mkbootimg`, `mkdtboimg.py` and the prebuilt clang from it, so this
must move before `bin/omamobile images`. Same filesystem, so `mv` is instant.

```sh
mv ~/android/omandroid ~/android/omamobile
```

The bionic prebuilts were rebuilt on 2026-10-13 against the tree at its old
path (see section 6); nothing in a built file records that path.

## 3. Caches

```sh
mv ~/.cache/omandroid-ccache ~/.cache/omamobile-ccache    # CCACHE_DIR in omamobile.conf
mv ~/.cache/omandroid-venv   ~/.cache/omamobile-venv      # tools/extract-camera-data's unicorn venv
rm -rf ~/.cache/omandroid                                 # widget-lint scratch from the shell's tests
```

A venv records its own path in `bin/activate` and the scripts' shebangs, so
call `~/.cache/omamobile-venv/bin/python` directly (as the docs do), or
recreate it: `python3 -m venv --clear ~/.cache/omamobile-venv && ~/.cache/omamobile-venv/bin/pip install unicorn pyelftools`.

## 4. NetworkManager profile for the USB link

`tools/phone-ssh` and the docs now name the profile `omamobile-phone`. The
profile keeps its settings (172.16.42.2/24, `ipv4.method shared`, match
`enp0s20f0u*`); only the name changes.

```sh
nmcli connection modify omandroid-phone connection.id omamobile-phone
nmcli -g connection.id,ipv4.method,ipv4.addresses connection show omamobile-phone
```

The "host changes to undo" note in Claude's memory names the old profile:
update it to `omamobile-phone`.

## 5. Ignored files in the working tree

- `omandroid.local.conf`, if you create one, is now `omamobile.local.conf`
  (none exists today).
- `out/repo/aarch64` still holds the old `omandroid.db` and the
  `omandroid-*` packages, and `tools/repo-build` adds every package it finds
  there to the database. Clear it before the next repository build:
  `rm -rf out/repo`.
- `out/fingerprint/` holds old `omandroid-fp-*` builds from an earlier run:
  `rm -rf out/fingerprint`.
- `keys/gnupg.bak-omandroid-final/` is a copy of the signing keyring from
  before the new user ID was added. Delete it once a signed repository
  build has worked with the new keyring.

## 6. Signing key and bionic prebuilts (done in Phase 1, for the record)

- The package-signing key (fingerprint
  `6C84FE3D240709E70E27CC94B301F5EA62B249FE`, unchanged) got a new primary
  user ID, "Omarchy Mobile Package Signing <derekross@gmail.com>". The old
  user ID stays on the key, so signatures made before the rename still
  verify. `packages/omamobile-keyring/omamobile.gpg` was re-exported;
  `-trusted` and `-revoked` didn't change. The keyring installs as
  `pacman-key --populate omamobile`.
- The gitignored bionic prebuilts were rebuilt with the new names and are
  current: `packages/omamobile-fingerprint/prebuilt/omamobile-fp-{shim.so,bridge}`,
  `packages/omamobile-gnss/bionic/prebuilt/{omamobile-fp-shim.so,stubs/libomamobile-sitril-gps.so}`
  and `packages/omamobile-speaker-tuning/bionic/prebuilt/omamobile-waves-host`.
  To rebuild after step 2, use the commands in FINGERPRINT-PLAN, GNSS-PLAN
  and AOC-TUNING-RESEARCH (they now point at `~/android/omamobile`).

## 7. Couplings with the kernel tree (Phase 2)

The kernel tree (`~/android/mainline`) still uses the old strings. Until
Phase 2 commits the new ones and they reach `omamobile-int`, a kernel built
from it doesn't match this repository in three places. Don't push a new
boot image to the phone between Phase 1 and Phase 2:

- **Command-line flags.** The initramfs now looks for `omamobile.debug`,
  `omamobile.ufs-probe` and `omamobile.initramfs`. The cheetah DTS's
  `/chosen/bootargs` has `omandroid.ufs-probe`, so the UFS probe report
  stays off until the DTS changes in the same push.
- **Camera firmware.** `tools/extract-camera-data` now writes
  `/usr/lib/firmware/omamobile/camera/`; the DTS `firmware-name` properties
  (5) still say `omandroid/camera/`.
- **Kernel release.** `kernel/configs/omamobile.config` sets
  `CONFIG_LOCALVERSION="-omamobile-push1"`, and the modules marker is
  `.omamobile-tarball`, so the first push after the rename reinstalls the
  modules (expected).

Also in Phase 2: rename the kernel branches (`omandroid*` to `omamobile*`) and
the GitHub repository (`linux-omandroid` to `linux-omarchy-mobile`) before
the next `tools/publish-kernel`, which now pushes to
`git@github.com:derekross/linux-omarchy-mobile.git`.

## 8. Phase 3 (GitHub and the working tree)

The docs already say `~/Projects/omarchy-mobile` and
`github.com/derekross/omarchy-mobile`.

```sh
gh repo rename omarchy-mobile -R derekross/omandroid
git -C ~/Projects/omandroid remote set-url origin git@github.com:derekross/omarchy-mobile.git
mv ~/Projects/omandroid ~/Projects/omarchy-mobile && ln -s omarchy-mobile ~/Projects/omandroid
cp -a ~/.claude/projects/-home-raven-Projects-omandroid/memory ~/.claude/projects/-home-raven-Projects-omarchy-mobile/
```

Check the remote's URL form with `git remote -v` first. The plan's Phase 3
has the rest (memory file updates, issue comments).
