# Departures

Live departures from a stop you pick, anywhere Transitous has open
timetables: the minutes to the next departure large, then its line and where
it goes, and as many more as the tile fits. A live delay colours the
countdown; a cancelled trip shows ×. Set the stop's name in the settings,
then tap the tile and pick the stop from the matches. Afterwards a tap shows
the full board, with platforms (a changed one stands out) and departure
times.

A built-in home-screen widget, ported from
[`simonschubert/departures`](https://github.com/SimonSchubert/omarchy-widgets/tree/main/widgets/simonschubert/departures)
by Simon Schubert, in [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets),
the widget store of Simon Schubert's Omalauncher.

**Differences from the original:** Picking a stop works through the settings
(the name to search for) and a list of matches in the card, instead of a
search field in a full-screen view; the stop you pick is kept with the
placement. The board is asked every 2 minutes rather than every 30 seconds.
Line badges use the theme's accent instead of each operator's line colours,
and times follow the system's 12/24-hour setting. Qt's `XMLHttpRequest`
can't name the client in a User-Agent header as Transitous asks; the
requests are otherwise the same.

**Capabilities:** `network` (api.transitous.org).

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
