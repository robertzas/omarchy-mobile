# Rocket launches

A live countdown to the next rocket launch, with its status, provider and
pad, and the launches after it, from The Space Devs' Launch Library. Tap the
countdown to open the launch on Space Launch Now, or a later launch to open
that one.

A built-in home-screen widget, ported from
[`simonschubert/launches`](https://github.com/SimonSchubert/omarchy-widgets/tree/main/widgets/simonschubert/launches)
by Simon Schubert, in [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets),
the widget store of Simon Schubert's Omalauncher.

**Differences from the original:** The schedule comes from the same API
through `XMLHttpRequest` instead of `curl` and `jq`, so nothing has to be
installed; it is still asked once an hour, inside the free API's limit.
Dates follow the system's locale; colours come from the Omarchy theme.

**Capabilities:** `network` (ll.thespacedevs.com; spacelaunchnow.me opens in
the browser).

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
