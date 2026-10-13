# Todo

The open `- [ ] ` items of a Markdown checklist (`~/notes/todo.md` unless you pick another file). Tap an item to check it off (it becomes `- [x] `); tap the title to open the file in Omarchy's editor. The file is made with two example items the first time.

A built-in home-screen widget, ported from
[`simonschubert/todo`](https://github.com/SimonSchubert/omarchy-widgets/tree/main/widgets/simonschubert/todo)
by Simon Schubert, in [omarchy-widgets](https://github.com/SimonSchubert/omarchy-widgets),
the widget store of Simon Schubert's Omalauncher.

**Differences from the original:** The file is a setting. The list is read with `grep` and `sed` through `host.run()`, with the path passed as an argument, every two minutes and right after a check-off; the title opens `omarchy-launch-editor` instead of `$EDITOR` in a terminal.

**Capabilities:** `commands`.

**Needs:** nothing beyond the base system (`grep`, `sed`); Omarchy's `omarchy-launch-editor` for editing.

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
