# Planes overhead

Aircraft within 45 km (30 miles) of you on a radar, from the OpenSky
Network: each plane points along its track, coloured by altitude (low ones
in the urgent colour, cruising ones in the accent), with the nearest one
named under it. Located by IP via wttr.in, or the city you set. Tap it for
every flight's call sign, country, altitude, speed and distance; tap a
flight to follow it on ADS-B Exchange.

A built-in home-screen widget, ported from
[`simonschubert/planes-overhead`](https://github.com/SimonSchubert/omarchy-widgets/tree/main/widgets/simonschubert/planes-overhead)
by Simon Schubert, in [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets),
the widget store of Simon Schubert's Omalauncher.

**Differences from the original:** The radar's sweep steps once a second
instead of turning smoothly, and the planes move along their tracks once a
second between requests, as the original's clock does. OpenSky is asked
every 2 minutes. The flight list opens inside the card instead of a full
screen, and the city is a setting. Colours come from the Omarchy theme.

**Capabilities:** `network` (wttr.in for the location, opensky-network.org).

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
