<!-- SPDX-License-Identifier: MIT -->
# hyprland (Omandroid build)

This is Omarchy's aarch64 Hyprland 0.56.2-5 (`hyprland` and `hyprpm`),
rebuilt with one change. Hyprland gave up on a refused DPMS commit after a
single retry, and aquamarine refuses commits while a page flip is in flight.
So when a client kept rendering, DPMS off was lost: Hyprland reported the
screen off, but the CRTC never turned off. See
`device/cheetah/DISPLAY-PLAN.md`, D3b-1.

| File | What it is |
| --- | --- |
| `PKGBUILD` | Omarchy's `pkgbuilds/hyprland/PKGBUILD` at `3a0d01876fc9` (omacom-io/omarchy-pkgs), changes in its header |
| `software-renderer.patch` | Omarchy's backport of hyprwm/Hyprland#16343, unchanged (sha256 `380bb6d6…`) |
| `0001-dpms-keep-retrying-a-refused-dpms-commit.patch` | The Omandroid change to `src/output/Monitor.cpp` |

## What differs from Omarchy's `hyprland` 0.56.2-5

- The DPMS patch. A refused DPMS commit is retried every two frames for up
  to a second instead of once.
- `pkgrel=5.1`.
- `build()` runs the two cmake steps of `make release` itself:
  - with Arch's `-DCMAKE_SKIP_RPATH=ON` (Arch's PKGBUILD seds it into the
    Makefile);
  - with the job count from `MAKEFLAGS` (default 4) instead of `nproc`.
- Same package names, `provides=(wayland-compositor)`, dependencies, sonames
  and split as Omarchy's, so it replaces it in place. Nothing conflicts.

## Status

**Built natively on the phone (2026-10-12):** about 20 min at `-j4`.
`hyprland` 0.56.2-5.1 is installed and running (DISPLAY-PLAN.md, D3b-1b).

The phone's `/etc/makepkg.conf` sets `PKGEXT='.pkg.tar.xz'`, so packages
built there end in `.pkg.tar.xz`, not `.zst`. The commands below use a glob.

`hyprpm` isn't installed on the phone, so install only `hyprland`. The
`hyprpm` split is still built, and published by `tools/repo-build`. pacman
upgrades only installed packages, so publishing it changes nothing.

Checked offline before that:

- The source tarball's sha256 matches Arch's and Omarchy's
  (`03ad3f5e…`).
- Both patches apply to it with `--fuzz=0`, in the PKGBUILD's order.
- A full `makepkg -A` of this PKGBUILD in an x86_64 Arch container
  (2026-10-12) built `hyprland`, `hyprpm` and `hyprland-debug` 0.56.2-5.1,
  patched `Monitor.cpp` included. It took 5 min 56 s at `MAKEFLAGS=-j8` on 8
  cores of an Intel Core Ultra 5 225H, 2410 s of CPU. The largest single
  compiler process peaked at 1.1 GB RSS. The container's memory peak,
  including page cache, was 5.7 GB.

## Building on the phone

Hyprland is C++ with heavy templates (glaze, hyprutils). Estimate for the phone (8 cores: 2× X1, 2× A78, 4× A55; about 12 GB RAM):

- **Time:** about 2400 CPU-seconds on a fast x86 core is roughly
  6000–8000 on this SoC. That is **30–60 min at -j4** and about 25–45 min at
  -j6, longer if it throttles. Keep it on the charger.
- **Memory:** up to about 1.1 GB per compiler process, so about 4.5 GB at
  -j4 and about 7 GB at -j6. -j8 (makepkg's `nproc` default in upstream's
  Makefile) leaves too little for a running session.

Build as the `omandroid` user, which `tools/phone-install-package` and
`tools/repo-build` also use. Use `MAKEFLAGS=-j4` with the session running, or
`-j6` with the session stopped (`systemctl stop sddm`).

```sh
# on the phone, once: build tools and the makedepends
sudo pacman -S --needed base-devel cmake glaze hyprland-protocols hyprwayland-scanner meson ninja xorgproto
```

Then pick one of these:

1. **Into the [omandroid] repository** (the pinned way). Run on the laptop:

   ```sh
   tools/repo-build packages/hyprland   # signs and indexes it with the rest of out/repo
   tools/repo-push
   ```

   The job count comes from `MAKEFLAGS` in the phone's
   `/etc/makepkg.conf`. Arch leaves it unset, so the PKGBUILD's default of
   4 applies. Laptop environment variables don't reach the phone's makepkg.

   Then, on the phone, `omarchy update`, or
   `sudo OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu`. That upgrades
   `hyprland`, and `hyprpm` if it is installed.

2. **Quick test, without the repository**: build on the phone and install
   the two files.

   ```sh
   tools/phone-ssh 'rm -rf /home/omandroid/build/pkgs/hyprland && mkdir -p /home/omandroid/build/pkgs'
   tar cf - -C packages ./hyprland | tools/phone-ssh 'tar xf - -C /home/omandroid/build/pkgs --no-same-owner && chown -R omandroid: /home/omandroid/build/pkgs/hyprland'
   tools/phone-ssh "su - omandroid -c 'cd build/pkgs/hyprland && MAKEFLAGS=-j4 makepkg -f --noconfirm' 2>&1 | tail -3"
   tools/phone-ssh 'OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -U --noconfirm $(ls /home/omandroid/build/pkgs/hyprland/hyprland-0.56.2-5.1-aarch64.pkg.tar.* | grep -v "\.sig$")'
   ```

   (`tools/phone-install-package packages/hyprland` also works. It
   installs every `hyprland-*` file, so `hyprland-debug` too if makepkg
   built one, and it builds with the PKGBUILD's default of 4 jobs.)

After installing, restart the session (`systemctl restart sddm`) and check
`hyprctl version` and `pacman -Q hyprland` (expect `0.56.2-5.1`).
If `hyprpm` is installed, upgrade it too:
`hyprpm-0.56.2-5.1-aarch64.pkg.tar.*` from the same directory.

## Pinning

`[omandroid]` comes before `[omarchy]` in the phone's `pacman.conf`
(`omandroid-device-cheetah`). pacman takes a package from the first
repository that has it, so with `hyprland` in `[omandroid]`, `omarchy update`
won't replace it, even when Omarchy ships a higher release. That means we
have to follow Omarchy's updates ourselves:

1. Take the new `pkgbuilds/hyprland` files.
2. Re-apply the header changes and set `pkgrel` to Omarchy's plus `.1`.
3. Check that both patches still apply with `--fuzz=0`.

Drop the DPMS patch once upstream retries refused DPMS commits.

**`tools/repo-build`:**
- Packages are listed explicitly, so add `packages/hyprland` only when it
  should be rebuilt.
- The script recreates the database from every package file in
  `out/repo/aarch64`, so a previously built hyprland stays published.
- To unpublish it, delete its files from `out/repo/aarch64` before running
  it again.

## Rolling back to Omarchy's package

```sh
# on the phone
sudo OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -U \
  https://pkgs.omarchy.org/stable/aarch64/hyprland-0.56.2-5-aarch64.pkg.tar.zst
# add .../hyprpm-0.56.2-5-aarch64.pkg.tar.zst only if hyprpm is installed
# or from the cache, if still there:
sudo OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -U /var/cache/pacman/pkg/hyprland-0.56.2-5-aarch64.pkg.tar.zst
systemctl restart sddm
```

Also take the hyprland files out of `out/repo/aarch64` and run
`tools/repo-build` and `tools/repo-push`. Otherwise the next update brings
our build back. Until then, `IgnorePkg = hyprland hyprpm` in
`/etc/pacman.conf` holds the downgrade.
