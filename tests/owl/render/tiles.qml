// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import Quickshell.Io

// Renders every task in $OWL_JOB offscreen, one at a time: our tile or the
// reference's, at the card size the phone gives the widget. For each it
// writes the layout dump (L4) and a picture (L5). Then it quits.
ShellRoot {
  id: shell

  FileView { id: jobFile; path: Quickshell.env("OWL_JOB"); blockLoading: true }
  readonly property var tasks: JSON.parse(jobFile.text())
  property int index: -1
  property var current: null

  FloatingWindow {
    id: win
    implicitWidth: 480
    implicitHeight: 1040
    color: "#000000"
    Item { id: stage; anchors.fill: parent }
  }

  Component { id: oursTile; OursTile { } }
  Component { id: refTile; RefTile { } }

  // A new FileView per file: one reused across paths skips a write whose
  // text equals the last one.
  Component { id: writerComponent; FileView { atomicWrites: true; blockWrites: true; printErrors: false } }
  function write(file, text) {
    const w = writerComponent.createObject(shell, { path: file })
    w.setText(text)
    w.destroy()
  }

  function next() {
    if (shell.current) { shell.current.destroy(); shell.current = null }
    shell.index++
    if (shell.index >= shell.tasks.length) { Qt.quit(); return }
    const t = shell.tasks[shell.index]
    shell.current = (t.side === "ref" ? refTile : oursTile).createObject(stage, { task: t, width: t.card[0], height: t.card[1] })
    settle.restart()
  }

  Timer { id: settle; interval: 900; onTriggered: shell.capture() }

  function capture() {
    const t = shell.tasks[shell.index]
    shell.write(t.dump, JSON.stringify(shell.current.dump()) + "\n")
    shell.current.grabToImage(function(result) {
      result.saveToFile(t.png)
      console.log("rendered " + t.side + " " + t.id + " " + t.theme)
      Qt.callLater(shell.next)
    })
  }

  Timer { interval: 300; running: true; onTriggered: shell.next() }
}
