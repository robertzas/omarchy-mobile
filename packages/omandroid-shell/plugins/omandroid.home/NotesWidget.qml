// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// A sticky note. The text lives in home.json with the layout; a tap opens it
// for editing (the home screen's settings sheet, with the keyboard).
Item {
  id: widget

  property var home: null
  property var entry: null
  property bool editing: false
  readonly property string body: entry && entry.config ? String(entry.config.text || "") : ""

  Text {
    anchors.fill: parent
    anchors.margins: Style.spacing.xxl
    textFormat: Text.PlainText
    text: widget.body.length > 0 ? widget.body : "Tap to write a note"
    color: widget.home ? (widget.body.length > 0 ? widget.home.foreground : widget.home.dimForeground) : "white"
    font.family: Style.font.family
    font.pixelSize: Style.font.title
    font.italic: widget.body.length === 0
    wrapMode: Text.Wrap
    elide: Text.ElideRight
    verticalAlignment: Text.AlignTop
  }

  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: if (widget.home) widget.home.openSettings(widget.entry.id)
  }
}
