// SPDX-License-Identifier: MIT
// The extra keys a terminal needs and squeekboard's normal layout lacks, as
// Termux has them: Esc, Tab, Ctrl and Alt (sticky for the next key only),
// the arrows and a few symbols, and a strip of Ctrl combinations (^C, ^D,
// ^Z, ...) while Ctrl is held, since a letter typed on squeekboard can't be
// combined with our Ctrl. Two ways out, one table:
//   bytes(key, mods)     what a pseudo-terminal reads (the OWL Terminal tile)
//   wtypeArgv(key, mods) a virtual key press for a terminal window (foot,
//                        Alacritty...) through wtype
// `mods` is { ctrl, alt }. Pure JS: node tests it.

// The rows, left to right. `id` is the key, `label` what it shows.
var ROWS = [
  [{ id: "esc", label: "Esc" }, { id: "/", label: "/" }, { id: "-", label: "-" }, { id: "|", label: "|" },
   { id: "~", label: "~" }, { id: ":", label: ":" }, { id: "up", label: "↑" }],
  [{ id: "tab", label: "Tab" }, { id: "ctrl", label: "Ctrl", modifier: true }, { id: "alt", label: "Alt", modifier: true },
   { id: "left", label: "←" }, { id: "down", label: "↓" }, { id: "right", label: "→" }]
]
// Shown while Ctrl is held: the combinations a shell, an editor and a pager use.
var CTRL_LETTERS = ["c", "d", "z", "l", "a", "e", "r", "w", "u", "k", "x", "o", "s"]

var ARROWS = { up: "A", down: "B", right: "C", left: "D" }
var SYMBOL_KEYSYMS = { "/": "slash", "-": "minus", "|": "bar", "~": "asciitilde", ":": "colon" }
var KEYSYMS = { esc: "Escape", tab: "Tab", up: "Up", down: "Down", left: "Left", right: "Right" }

function isLetter(k) { return typeof k === "string" && /^[a-z]$/i.test(k) }

// xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
function modifierParam(mods) {
  return 1 + (mods && mods.alt ? 2 : 0) + (mods && mods.ctrl ? 4 : 0)
}

// The bytes a terminal program reads for `key` with `mods`.
function bytes(key, mods) {
  var m = mods || {}
  if (ARROWS[key]) {
    var p = modifierParam(m)
    return p === 1 ? "\u001b[" + ARROWS[key] : "\u001b[1;" + p + ARROWS[key]
  }
  var out
  if (key === "esc") out = "\u001b"
  else if (key === "tab") out = "\t"
  else if (isLetter(key)) out = m.ctrl ? String.fromCharCode(key.toLowerCase().charCodeAt(0) & 0x1f) : key
  else if (key.length === 1) {
    // Ctrl with the few symbols that have a control code (as xterm sends them).
    if (m.ctrl && (key === "/" || key === "-")) out = "\u001f"
    else if (m.ctrl && key === "~") out = "\u001e"
    else out = key
  } else return ""
  // Alt is Esc first (meta sends escape), except for Esc itself.
  return m.alt && key !== "esc" ? "\u001b" + out : out
}

// wtype's argv for the same key on a terminal window: the modifiers pressed
// around one key (-M ... -k ... -m ...), never text through a shell.
function wtypeArgv(key, mods) {
  var m = mods || {}
  var sym = KEYSYMS[key] || SYMBOL_KEYSYMS[key] || (isLetter(key) ? key.toLowerCase() : "")
  if (!sym) return null
  var argv = ["wtype"]
  if (m.ctrl) argv.push("-M", "ctrl")
  if (m.alt) argv.push("-M", "alt")
  argv.push("-k", sym)
  if (m.alt) argv.push("-m", "alt")
  if (m.ctrl) argv.push("-m", "ctrl")
  return argv
}

// What a tap does: a modifier toggles (held for the next key only), any
// other key is sent with the held modifiers, which then let go.
// -> { send: key or null, mods: the modifiers to send with, held: { ctrl, alt } after }
function tap(held, key) {
  var h = { ctrl: !!(held && held.ctrl), alt: !!(held && held.alt) }
  if (key === "ctrl" || key === "alt") {
    h[key] = !h[key]
    return { send: null, mods: null, held: h }
  }
  return { send: key, mods: { ctrl: h.ctrl, alt: h.alt }, held: { ctrl: false, alt: false } }
}

// A terminal window's class, for the keyboard plugin's bar.
var TERMINALS = ["foot", "footclient", "alacritty", "kitty", "com.mitchellh.ghostty", "ghostty", "org.wezfurlong.wezterm",
                 "xterm", "org.gnome.console", "org.gnome.ptyxis", "st"]
function isTerminalClass(cls) { return TERMINALS.indexOf(String(cls || "").toLowerCase()) >= 0 }

if (typeof module !== "undefined") {
  module.exports = { ROWS: ROWS, CTRL_LETTERS: CTRL_LETTERS, bytes: bytes, wtypeArgv: wtypeArgv, tap: tap,
                     isTerminalClass: isTerminalClass, modifierParam: modifierParam }
}
