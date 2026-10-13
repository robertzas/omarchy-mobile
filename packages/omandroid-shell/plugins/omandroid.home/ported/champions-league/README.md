# Champions League

Champions League from ESPN: live scores first, then the latest results and the coming kick-offs (three days back, six ahead), with club crests; and the table, with a coloured bar for the European and relegation places. Tap **matches** or **table** to switch; tap the title to list every match of the window and the full table with won-drawn-lost, and again to go back.

A built-in home-screen widget, ported from
[`simonschubert/champions-league`](https://github.com/SimonSchubert/omarchy-widgets/tree/main/widgets/simonschubert/champions-league)
by simonschubert, in [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets),
the widget store of Simon Schubert's Omalauncher.

**Differences from the original:** the scoreboards and the table come from the same ESPN endpoints through `XMLHttpRequest` instead of `curl` and `jq`, so nothing has to be installed, and crests load straight from ESPN's image server instead of a folder in `~/.cache`. The full-screen view became the expanded list behind a tap on the title. The zone colours (Champions League, other European places, relegation play-off, relegation) are drawn from the theme's accent and urgent colours.

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
