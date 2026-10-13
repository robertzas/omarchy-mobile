# Fetch

This phone at a glance, fastfetch style: `user@host` under Arch's logo in the
accent colour, a row of the theme's colours, then the OS, host, kernel,
uptime, packages, shell, theme, CPU, memory, disk and battery.

Tap it for every detail, grouped as phone, hardware (CPU cores and top
clock, display mode, memory and storage bars), battery (level, temperature,
voltage, health, cycles, technology where the battery reports them) and
Linux (packages, explicitly installed ones, shell, last full upgrade), with
a **fastfetch ↗** button that runs `fastfetch` in a terminal. **close** goes
back.

A built-in home-screen widget, ported from
[`simonschubert/fetch`](https://github.com/SimonSchubert/omarchy-widgets/tree/main/widgets/simonschubert/fetch)
by simonschubert, in [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets),
the widget store of Simon Schubert's Omalauncher.

**Differences from the original:** the original reads the phone from
Android (`android.device`, `android.system`, `android.battery`) and Arch from
a command; Omandroid has no Android, so everything comes from Linux:
`fetch.py` reads `/proc`, `/sys`, `/etc/os-release`, `pacman`, the pacman
log and `hyprctl monitors`, and the battery level comes from UPower. The
Android-only lines (Android version, security patch, Android apps, the
launcher's version) are gone, and the logo is always Arch's. The
sixteen-colour palette becomes a row of the theme's own colours (the shell
has no terminal palette), and **fastfetch ↗** doesn't install fastfetch for
you. The facts are read again every 5 minutes and when the details open.

**Capabilities:** `commands` (runs `fetch.py`, and `fastfetch` in a
terminal).

**Needs:** `python`; `fastfetch` for the button.

## License

The original is MIT licensed, and so is this port:

    Copyright (c) 2026 Simon Schubert and contributors

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

The same text is in `LICENSE-omarchy-widgets` in the home screen's plugin folder
(`/usr/share/omandroid/shell/plugins/omandroid.home/LICENSE-omarchy-widgets`).
