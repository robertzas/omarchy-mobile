// SPDX-License-Identifier: MIT
import QtQuick

// A Button: its text in a frame of its colour (accent by default). The
// frame follows the corner style, as the launcher's buttons do.
OwlNodeBase {
  id: button

  readonly property color tone: button.p.color || button.ink("accent")

  Rectangle {
    anchors.fill: parent
    radius: button.p.radius !== undefined && button.p.radius !== null ? button.num(button.p.radius, 0) * button.dp
      : button.view ? 8 * button.view.corners * button.dp : 0
    color: "transparent"
    border.width: Math.max(1, button.dp)
    border.color: button.tone
  }
  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: button.p.text === undefined || button.p.text === null ? "…" : String(button.p.text)
    color: button.tone
    font.pixelSize: 13 * button.dp
    font.family: button.view ? button.view.family("mono") : "monospace"
  }
}
