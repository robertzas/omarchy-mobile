// SPDX-License-Identifier: MIT
import QtQuick

// Shader: AGSL is Android's, and Qt compiles shaders ahead of time, so this
// draws the widget's `fallback` (surface by default), as older Android
// phones do. Terminal (level 2) isn't served yet and says so.
OwlNodeBase {
  id: fallbackNode

  Rectangle {
    x: fallbackNode.innerX
    y: fallbackNode.innerY
    width: fallbackNode.innerW
    height: fallbackNode.innerH
    color: fallbackNode.node && fallbackNode.node.kind === "Terminal" ? "transparent"
      : fallbackNode.p.fallback || fallbackNode.ink("surface")
  }
  Text {
    anchors.centerIn: parent
    width: parent.width - 8
    visible: fallbackNode.node !== null && fallbackNode.node.kind === "Terminal"
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "Terminal isn't supported on this phone yet"
    color: fallbackNode.ink("muted")
    font.pixelSize: 11 * fallbackNode.dp
    font.family: fallbackNode.view ? fallbackNode.view.family("mono") : "monospace"
  }
}
