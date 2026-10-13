# Sun and moon

Today's sunrise and sunset as an arc with the sun on it, how much daylight
is left (or how long until sunrise), and tonight's moon phase drawn with its
lit part. Located by IP, or the city you set. Tap it to change the city.

A built-in home-screen widget, ported from
[`simonschubert/sun-and-moon`](https://github.com/SimonSchubert/omarchy-widgets/tree/main/widgets/simonschubert/sun-and-moon)
by Simon Schubert, in [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets),
the widget store of Simon Schubert's Omalauncher.

**Differences from the original:** The times come from the same wttr.in
request through `XMLHttpRequest` instead of `curl`, `jq` and `date`, so
nothing has to be installed. The city is a setting (a tap opens it) instead
of a text field in a full-screen view. Times follow the system's 12/24-hour
setting; colours come from the Omarchy theme.

**Capabilities:** `network` (wttr.in).

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
(`/usr/share/omamobile/shell/plugins/omamobile.home/LICENSE-omarchy-widgets`).
