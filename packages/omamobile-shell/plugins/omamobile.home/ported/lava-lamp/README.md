# Lava lamp

A pixel lava lamp in your theme's colours. Tap it for another wax colour.

A built-in home-screen widget, ported from
[`simonschubert/lava-lamp`](https://github.com/SimonSchubert/omarchy-widgets/tree/main/widgets/simonschubert/lava-lamp)
by simonschubert, in [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets),
the widget store of Simon Schubert's Omalauncher.

**Differences from the original:** the original is a GPU shader (AGSL); this draws the same metaballs, glass, cap and base on a coarse pixel grid with a Canvas. To keep the home screen cheap the wax moves a step once a second and flows smoothly for a few seconds after a tap. The four wax colours are mixed from the theme's accent, urgent and text colours. The choice is kept in the placement's settings.

**Capabilities:** none.

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
