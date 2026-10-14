// SPDX-License-Identifier: MIT
pragma ComponentBehavior: Bound
import QtQuick
import "extrakeys.js" as Keys

// A Termux-style row of the keys a terminal needs and squeekboard's normal
// layout lacks: Esc, Tab, Ctrl and Alt (held for the next key only, lit
// while held), the arrows and | / - ~ :. While Ctrl is held a strip of
// Ctrl combinations (^C, ^D, ^Z...) shows above, since a letter typed on
// squeekboard can't take our Ctrl. Emits `pressed(key, mods)`; whoever holds
// it sends the bytes (extrakeys.js bytes()) or a key press (wtypeArgv()).
// Used by the OWL Terminal tile and, above squeekboard, for terminal windows.
Item {
  id: bar

  property color foreground: "#ffffff"
  property color accent: "#7aa2f7"
  property color background: "#1a1b26"
  property string fontFamily: "monospace"
  property real keyHeight: 44
  property var held: ({ ctrl: false, alt: false })

  signal pressed(string key, var mods)

  implicitHeight: (bar.held.ctrl ? 3 : 2) * bar.keyHeight

  function tapKey(id) {
    const r = Keys.tap(bar.held, id)
    bar.held = r.held
    if (r.send) bar.pressed(r.send, r.mods)
  }

  Rectangle { anchors.fill: parent; color: bar.background }

  Column {
    anchors.fill: parent

    // Ctrl combinations, while Ctrl is held.
    Row {
      visible: bar.held.ctrl
      width: parent.width
      height: visible ? bar.keyHeight : 0
      Repeater {
        model: Keys.CTRL_LETTERS
        delegate: KeyCap {
          required property var modelData
          width: bar.width / Keys.CTRL_LETTERS.length
          label: "^" + String(modelData).toUpperCase()
          onTapped: bar.tapKey(modelData)
        }
      }
    }

    Repeater {
      model: Keys.ROWS
      delegate: Row {
        id: keyRow
        required property var modelData
        width: bar.width
        height: bar.keyHeight
        Repeater {
          model: keyRow.modelData
          delegate: KeyCap {
            required property var modelData
            width: bar.width / keyRow.modelData.length
            label: modelData.label
            lit: modelData.modifier === true && bar.held[modelData.id] === true
            onTapped: bar.tapKey(modelData.id)
          }
        }
      }
    }
  }

  component KeyCap: Item {
    id: cap
    property string label: ""
    property bool lit: false
    signal tapped()
    height: bar.keyHeight
    Rectangle {
      anchors.fill: parent
      anchors.margins: 2
      radius: 4
      color: cap.lit ? bar.accent : touch.pressed ? Qt.rgba(1, 1, 1, 0.18) : Qt.rgba(1, 1, 1, 0.06)
    }
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: cap.label
      color: cap.lit ? bar.background : bar.foreground
      font.family: bar.fontFamily
      font.pixelSize: 15
    }
    MouseArea { id: touch; anchors.fill: parent; onClicked: cap.tapped() }
  }
}
