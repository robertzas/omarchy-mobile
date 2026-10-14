// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import "home/owl" as Owl
import "home/owl/extrakeys.js" as Keys

// The extra keys in the OWL Terminal tile, offscreen: taps on the bar reach
// a fake pty as the right bytes (Esc, Ctrl-C held for one key, Alt, an
// arrow, a symbol), and a picture of the armed tile is saved.
ShellRoot {
  id: t
  property int failures: 0
  property string written: ""
  function check(name, ok, detail) {
    console.log((ok ? "ok - " : "not ok - ") + name + (ok ? "" : " (" + detail + ")"))
    if (!ok) t.failures++
  }

  FloatingWindow {
    implicitWidth: 480
    implicitHeight: 360
    color: "#1a1b26"
    Owl.OwlView {
      id: view
      anchors.fill: parent
      anchors.margins: 8
      dp: 1.16
      colors: ({ foreground: "#ffc0caf5", accent: "#ff7aa2f7", background: "#ff1a1b26", muted: "#ff565f89", surface: "#ff24283b", border: "#ff414868" })
      monoFamily: "JetBrainsMono Nerd Font"
      terminals: ({ start: function(command, onOutput) {
        onOutput("$ nvim ~/notes/todo.md\r\n-- INSERT --\r\n")
        return { write: function(text) { t.written += text }, stop: function() {} }
      } })
      tree: ({ children: [{ kind: "Terminal", key: "t", p: { command: "bash -l" }, h: {}, a: {}, c: [] }] })
    }
  }

  function terminalItem() {
    for (const k in view.items) if (k.indexOf("Terminal") >= 0) return view.items[k]
    return null
  }
  function find(item, name) {
    if (!item) return null
    if (item.objectName === name || (item.tapKey !== undefined && name === "keys")) return item
    for (let i = 0; i < item.children.length; i++) { const f = t.find(item.children[i], name); if (f) return f }
    return null
  }

  Timer {
    interval: 800
    running: true
    onTriggered: {
      const term = t.terminalItem()
      t.check("the Terminal tile is drawn", !!term, "no item")
      term.armed = true
      Qt.callLater(function() {
        const keys = t.find(term, "keys")
        t.check("the extra keys show while the terminal has the keyboard", !!keys && keys.visible, "hidden")
        keys.tapKey("esc"); keys.tapKey("ctrl"); keys.tapKey("c"); keys.tapKey("alt"); keys.tapKey("left"); keys.tapKey("|"); keys.tapKey("up")
        t.check("Esc, Ctrl-C, Alt-Left, | and Up reach the pty as their bytes",
                t.written === "\u001b" + "\u0003" + "\u001b[1;3D" + "|" + "\u001b[A", JSON.stringify(t.written))
        keys.tapKey("ctrl")
        Qt.callLater(function() {
          t.check("holding Ctrl shows the Ctrl strip", keys.implicitHeight === keys.keyHeight * 3, keys.implicitHeight)
          term.grabToImage(function(r) {
            r.saveToFile(Quickshell.env("OWL_OUT") + "/terminal-keys.png")
            Qt.exit(t.failures ? 1 : 0)
          })
        })
      })
    }
  }
}
