// SPDX-License-Identifier: MIT
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A thumb-sized glyph button for the Wi-Fi and Bluetooth panels' headers
// and fields; spins its glyph while `spinning`.
Item {
  id: glyphButton

  property string glyph: ""
  property bool spinning: false
  property color foreground: Commons.Color.popups.text
  readonly property int touchSize: Math.max(44, Style.space(48))
  signal tapped()

  width: glyphButton.touchSize
  height: glyphButton.touchSize
  opacity: enabled ? 1 : 0.45

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: glyphTouch.pressed ? Style.pressedFillFor(glyphButton.foreground, Commons.Color.accent) : "transparent"
  }

  Text {
    id: glyphText
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: glyphButton.glyph
    color: glyphButton.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.iconLarge

    RotationAnimator on rotation {
      running: glyphButton.spinning
      from: 0
      to: 360
      duration: 900
      loops: Animation.Infinite
      onRunningChanged: if (!running) glyphText.rotation = 0
    }
  }

  MouseArea {
    id: glyphTouch
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: glyphButton.tapped()
  }
}
