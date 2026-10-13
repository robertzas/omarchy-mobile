# Air and pollen

Air quality where you are, from Open-Meteo's Copernicus data: the US index
in the US and the European index everywhere else, on a gauge with its
rating, PM2.5 and UV. Taller, it lists the pollen in the air over the next
24 hours (Europe only). Located by IP via wttr.in, or the city you set. Tap
it for the details: what the rating means, the index hour by hour, the
pollutants now and every pollen type with its curve. Tap the header to come
back.

A built-in home-screen widget, ported from
[`simonschubert/air-and-pollen`](https://github.com/SimonSchubert/omarchy-widgets/tree/main/widgets/simonschubert/air-and-pollen)
by Simon Schubert, in [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets),
the widget store of Simon Schubert's Omalauncher.

**Differences from the original:** The details open inside the card instead
of a full screen, and the city is a setting instead of a text field there.
Colours come from the Omarchy theme: the ratings run from the accent (good)
to the urgent colour (worst) instead of green to magenta.

**Capabilities:** `network` (wttr.in for the location,
air-quality-api.open-meteo.com).

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
