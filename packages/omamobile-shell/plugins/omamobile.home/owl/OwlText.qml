// SPDX-License-Identifier: MIT
import QtQuick
import "layout.js" as Layout

// Text, sized as layout.js measured it: lines 1.17 em apart, wrapped at
// spaces, `maxLines` with an ellipsis, `title`/`huge` on one line.
OwlNodeBase {
  id: textNode

  readonly property var style: Layout.textStyle(textNode.p)
  readonly property real size: Layout.fontSize(textNode.p) * textNode.dp
  readonly property int lines: Layout.maxLines(textNode.p)

  Text {
    x: textNode.innerX
    y: textNode.innerY
    width: textNode.innerW
    height: textNode.innerH
    textFormat: Text.PlainText
    text: textNode.p.text === undefined || textNode.p.text === null ? "…" : String(textNode.p.text)
    color: textNode.p.color || textNode.ink(textNode.style[1] ? "muted" : "foreground")
    font.family: textNode.view ? textNode.view.family(textNode.p.font) : "monospace"
    // Whole pixels, as layout.js measured it (OwlView.measure).
    font.pixelSize: Math.max(1, Math.round(textNode.size))
    font.bold: textNode.p.bold === true
    font.italic: textNode.p.italic === true
    lineHeightMode: Text.FixedHeight
    lineHeight: textNode.size * 1.17
    verticalAlignment: Text.AlignVCenter
    horizontalAlignment: textNode.p.align === "center" ? Text.AlignHCenter : textNode.p.align === "end" ? Text.AlignRight : Text.AlignLeft
    wrapMode: textNode.lines === 1 ? Text.NoWrap : Text.Wrap
    maximumLineCount: textNode.lines > 0 ? textNode.lines : 100000
    elide: textNode.lines > 0 ? Text.ElideRight : Text.ElideNone
    Behavior on color {
      enabled: !!textNode.anims.color
      ColorAnimation { duration: textNode.ms(textNode.anims.color) }
    }
  }
}
