# Notifications

The notifications Omarchy's notification service keeps (the ones on screen and the last ten in its history), newest first, with a chip per app. Tap one to run its action, × to hide it from the card. Tap the title for all of them grouped by app, and again to go back.

A built-in home-screen widget, ported from
[`simonschubert/notifications`](https://github.com/SimonSchubert/omarchy-widgets/tree/main/widgets/simonschubert/notifications)
by Simon Schubert, in [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets),
the widget store of Simon Schubert's Omalauncher.

**Differences from the original:** There are no Android notifications on Omandroid: it reads Omarchy's notification files in `~/.local/state/omarchy/notifications/` (and `history/`) through `host.run()`, every two minutes and when the title is tapped. Tapping one runs the action Omarchy saved with it (as clicking it in Omarchy does); × only hides it on this card, since the widget doesn't change Omarchy's history. Without notification access to ask for, that message is gone.

**Capabilities:** `commands`.

**Needs:** nothing beyond the base system.

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
