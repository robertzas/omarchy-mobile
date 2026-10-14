.pragma library
// SPDX-License-Identifier: MIT
// A Terminal node's screen as plain lines: what a pseudo-terminal prints,
// with colour and cursor escapes removed, carriage returns overwriting the
// line and backspaces deleting. Full-screen programs (btop) need a real
// terminal: the tile offers to open one. Pure JS.

var MAX_LINES = 300

function empty() { return { lines: [], current: "" } }

function strip(text) {
  return String(text)
    .replace(/\u001b\][^\u0007\u001b]*(\u0007|\u001b\\)/g, "")      // OSC (titles)
    .replace(/\u001b\[[0-9;?]*[ -\/]*[@-~]/g, "")                     // CSI (colours, cursor)
    .replace(/\u001b[()][0-9A-Za-z]/g, "")                             // charset
    .replace(/\u001b[=>78DEHMc]/g, "")
}

// Feed printed text in; returns the new state (the old one is not changed).
function feed(state, chunk) {
  var lines = state.lines.slice()
  var current = state.current
  var text = strip(chunk)
  for (var i = 0; i < text.length; i++) {
    var c = text.charAt(i)
    if (c === "\n") { lines.push(current); current = "" }
    else if (c === "\r") {
      if (text.charAt(i + 1) !== "\n") current = ""
    } else if (c === "\b") current = current.slice(0, -1)
    else if (c === "\u0007") continue
    else if (c >= " " || c === "\t") current += c
  }
  if (lines.length > MAX_LINES) lines = lines.slice(lines.length - MAX_LINES)
  return { lines: lines, current: current }
}

function text(state) {
  return state.lines.concat([state.current]).join("\n")
}

// What runs: the command in a pseudo-terminal (util-linux `script`), or the
// login shell.
function argv(command) {
  var c = String(command || "").trim()
  return ["script", "-qfec", c ? c : "exec bash -l", "/dev/null"]
}

if (typeof module !== "undefined") {
  module.exports = { empty: empty, feed: feed, text: text, strip: strip, argv: argv, MAX_LINES: MAX_LINES }
}
