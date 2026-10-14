// SPDX-License-Identifier: MIT
import QtQuick
import "paint.js" as Paint

// Input: a one-line field. onChange as it is typed, onSubmit on the
// keyboard's send key. `focus: true` (only in a screen) raises the keyboard.
OwlNodeBase {
  id: input

  Rectangle {
    x: input.innerX
    y: input.innerY
    width: input.innerW
    height: input.innerH
    radius: 6 * input.dp
    color: "transparent"
    border.width: Math.max(1, input.dp)
    border.color: Paint.withAlpha(input.ink("foreground"), field.activeFocus ? 0.5 : 0.2)

    TextInput {
      id: field
      anchors.fill: parent
      anchors.margins: 6 * input.dp
      verticalAlignment: TextInput.AlignVCenter
      enabled: !!input.view && input.view.interactive
      color: input.p.color || input.ink("foreground")
      font.pixelSize: input.num(input.p.fontSize, 14) * input.dp
      font.family: input.view ? input.view.family("sans") : "sans-serif"
      clip: true
      text: input.p.text === undefined || input.p.text === null || input.p.text === "…" ? "" : String(input.p.text)
      onTextEdited: if (input.handlers.onChange && input.view) input.view.changedValue(input.handlers.onChange, field.text)
      onActiveFocusChanged: if (input.view) input.view.fieldFocused(activeFocus)
      Component.onCompleted: if (input.p.focus === true) forceActiveFocus()
      onAccepted: {
        if (input.handlers.onSubmit && input.view) input.view.changedValue(input.handlers.onSubmit, field.text)
        if (input.p.clear === true) field.text = ""
      }
      Text {
        anchors.fill: parent
        verticalAlignment: Text.AlignVCenter
        visible: field.text === ""
        textFormat: Text.PlainText
        text: input.p.placeholder || ""
        color: input.ink("muted")
        font: field.font
      }
    }
  }
}
