# NHL

NHL from ESPN: yesterday's, today's and tomorrow's games, live ones first, then finals and the coming start times, with team logos; and the standings per conference in seed order, with a line under the playoff places and the points column. Tap **scores** or **standings** to switch; tap the title to list every game, and again to go back.

A built-in home-screen widget, ported from
[`simonschubert/nhl`](https://github.com/SimonSchubert/omarchy-widgets/tree/main/widgets/simonschubert/nhl)
by simonschubert, in [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets),
the widget store of Simon Schubert's Omalauncher.

**Differences from the original:** the scoreboard and standings come from the same ESPN endpoints through `XMLHttpRequest` instead of `curl` and `jq`, so nothing has to be installed, and logos load straight from ESPN's image server instead of a folder in `~/.cache`. The full-screen view became the expanded list behind a tap on the title.

**Capabilities:** `network` (site.api.espn.com, a.espncdn.com).

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
