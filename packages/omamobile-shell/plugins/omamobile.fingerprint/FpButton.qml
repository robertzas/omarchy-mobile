// SPDX-License-Identifier: MIT
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A button for the enrollment screen, as quick settings' SheetButton: the
// accent fill for the primary action, urgent text for a destructive one.
BorderSurface {
  id: sheetButton

  property string label: ""
  property bool primary: false
  property bool danger: false
  property color foreground: Commons.Color.menu.text
  readonly property int touchSize: Math.max(44, Style.space(48))
  signal tapped()

  height: visible ? sheetButton.touchSize : 0
  radius: Style.cornerRadius
  opacity: enabled ? 1 : 0.45
  color: buttonTouch.pressed ? Style.pressedFillFor(sheetButton.foreground, Commons.Color.accent)
    : primary ? Util.alpha(Commons.Color.accent, Style.selectedFillAlpha)
    : Style.normalFillFor(sheetButton.foreground, Commons.Color.accent)
  borderSpec: Border.controlSpec(primary ? "selected" : "normal", sheetButton.foreground, Commons.Color.accent)

  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: sheetButton.label
    color: sheetButton.danger ? Commons.Color.urgent : sheetButton.primary ? Commons.Color.accent : sheetButton.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.subtitle
    font.bold: true
  }

  MouseArea {
    id: buttonTouch
    anchors.fill: parent
    enabled: sheetButton.enabled
    cursorShape: Qt.PointingHandCursor
    onClicked: sheetButton.tapped()
  }
}
