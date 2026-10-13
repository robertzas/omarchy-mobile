// SPDX-License-Identifier: MIT
// A starter home-screen widget. The contract is
// /usr/share/omamobile/shell/WIDGETS.md: read it before you change this.
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

Item {
  id: widget

  // Set by the home screen.
  property var host: null           // WidgetHost: colours, settings, commands
  property var settings: ({})       // the manifest's defaults + the user's values
  property bool editing: false      // edit mode: don't react to taps
  property int cellsWide: 1         // the size in grid cells
  property int cellsHigh: 1

  Text {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    textFormat: Text.PlainText
    text: String(widget.settings.text || "")
    color: widget.host ? widget.host.foreground : Commons.Color.menu.text
    font.family: Style.font.family
    font.pixelSize: Style.font.display
    fontSizeMode: Text.Fit
    minimumPixelSize: Style.font.caption
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
  }

  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: if (widget.host) widget.host.openSettings()
  }
}
