# World clock

A row of flip clocks with city nameplates, the weekday there and the
difference from local time. A card goes dark where it's night, so day and
night read across the row at a glance. A tile taller than wide stacks the
clocks. Tap it to change the clocks: each is a nameplate and a time zone
from the tz database, as `Name=Area/City`, separated by commas (`New
York=America/New_York, London=Europe/London, Tokyo=Asia/Tokyo` by default;
up to six).

A built-in home-screen widget, ported from
[`simonschubert/world-clock`](https://github.com/SimonSchubert/omarchy-widgets/tree/main/widgets/simonschubert/world-clock)
by Simon Schubert, in [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets),
the widget store of Simon Schubert's Omalauncher.

**Differences from the original:** The clocks are one setting instead of the
original's full-screen editor with a city search, reordering and renaming:
write them in the order you want. The cards show 12-hour digits with am or
pm when the system clock is set to 12 hours. Time zones that aren't in
/usr/share/zoneinfo are left out. Colours come from the Omarchy theme.

**Capabilities:** `commands` (`sh` and `date`, once every 5 minutes, for
each zone's UTC offset).

**Needs:** `tzdata` (installed on Arch Linux ARM).

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
