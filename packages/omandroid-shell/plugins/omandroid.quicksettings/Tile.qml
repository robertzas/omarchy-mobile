// SPDX-License-Identifier: MIT
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One quick-settings toggle: glyph, name and a one-line status, sized for a
// thumb. Active tiles take the theme's selected fill and accent border; tiles
// whose backend is missing stay on screen, dimmed, and ignore taps.
//
// A tile with `details` also has a page behind it, as on Android: a chevron
// at the right edge (its own thumb-wide target) and a long-press anywhere
// open it, while a plain tap still toggles.
BorderSurface {
  id: root

  property string icon: ""
  property string label: ""
  property string status: ""
  property bool active: false
  property bool available: true
  property bool busy: false
  property bool details: false

  property color foreground: Commons.Color.popups.text
  property color accent: Commons.Color.accent

  signal clicked()
  signal detailsRequested()

  implicitHeight: Math.max(64, Style.space(68))
  radius: Style.cornerRadius
  opacity: available ? 1 : 0.45

  readonly property bool _pressed: touch.pressed && available
  readonly property int _chevronWidth: details ? Math.max(44, Style.space(48)) : 0
  readonly property var _activeSpec: Border.flat(accent, Math.max(1, Style.selectedBorderWidth || Style.normalBorderWidth))

  color: _pressed ? Style.pressedFillFor(foreground, accent)
    : active ? Util.alpha(accent, Style.selectedFillAlpha)
    : Style.normalFillFor(foreground, accent)
  borderSpec: active ? _activeSpec : Border.controlSpec("normal", foreground, accent)

  Behavior on color { ColorAnimation { duration: 120 } }

  Text {
    id: glyph
    anchors.left: parent.left
    anchors.leftMargin: root.borderLeft + Style.spacing.xxl
    anchors.verticalCenter: parent.verticalCenter
    width: Style.font.display
    horizontalAlignment: Text.AlignHCenter
    textFormat: Text.PlainText
    text: root.icon
    color: root.active ? root.accent : root.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.display
  }

  Column {
    anchors.left: glyph.right
    anchors.leftMargin: Style.spacing.xl
    anchors.right: parent.right
    anchors.rightMargin: root.borderRight + Style.spacing.lg + root._chevronWidth
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.xxs

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.label
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.status
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      opacity: root.busy ? 0.6 : 1
    }
  }

  MouseArea {
    id: touch
    anchors.fill: parent
    enabled: root.available
    cursorShape: Qt.PointingHandCursor
    pressAndHoldInterval: 450
    onClicked: root.clicked()
    // Handling pressAndHold is what stops the release from also clicking.
    onPressAndHold: if (root.details) root.detailsRequested()
  }

  // The chevron sits above the toggle's MouseArea, so its taps never toggle.
  Item {
    id: chevron
    visible: root.details
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    anchors.rightMargin: root.borderRight
    width: root._chevronWidth

    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: 1
      height: parent.height * 0.5
      color: Util.alpha(root.foreground, 0.2)
    }

    Rectangle {
      anchors.fill: parent
      anchors.margins: Style.spacing.xxs
      radius: Style.cornerRadius
      color: chevronTouch.pressed ? Style.pressedFillFor(root.foreground, root.accent) : "transparent"
    }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: "󰅂"
      color: root.active ? root.accent : root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.title
    }

    MouseArea {
      id: chevronTouch
      anchors.fill: parent
      enabled: root.available
      cursorShape: Qt.PointingHandCursor
      onClicked: root.detailsRequested()
    }
  }
}
