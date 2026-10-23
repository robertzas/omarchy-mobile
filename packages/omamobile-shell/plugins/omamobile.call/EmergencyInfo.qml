// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// What the lock screen's "Emergency call" button opens (Omarchy patch
// 0014) until emergency calling has passed its test on a carrier
// (TELEPHONY-APPS-PLAN §3.2, §3.3): the warning that it doesn't work yet,
// in the plan's words, never a dialpad. It offers nothing but Close.
Item {
  id: info

  signal closed()

  readonly property color foreground: Commons.Color.foreground
  readonly property color warn: "#d9362b"

  Rectangle { anchors.fill: parent; color: Commons.Color.background }
  Rectangle {
    anchors.fill: parent
    gradient: Gradient {
      GradientStop { position: 0.0; color: Qt.rgba(info.warn.r, info.warn.g, info.warn.b, 0.22) }
      GradientStop { position: 0.6; color: "transparent" }
    }
  }
  MouseArea { anchors.fill: parent }

  Column {
    anchors.horizontalCenter: parent.horizontalCenter
    y: Math.round(parent.height * 0.18)
    width: parent.width - 56
    spacing: 22

    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: 104
      height: 104
      radius: 52
      color: Qt.rgba(info.warn.r, info.warn.g, info.warn.b, 0.18)
      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: "!"
        color: info.warn
        font.family: Style.font.family
        font.pixelSize: 60
        font.bold: true
      }
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: "Emergency calls don't work yet"
      color: info.foreground
      font.family: Style.font.family
      font.pixelSize: 30
      font.bold: true
      wrapMode: Text.Wrap
    }

    Text {
      objectName: "emergencyWarning"
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: "Emergency calls (911, 112) don't work on this phone yet. Keep another phone for emergencies."
      color: info.foreground
      opacity: 0.85
      font.family: Style.font.family
      font.pixelSize: 19
      lineHeight: 1.2
      wrapMode: Text.Wrap
    }
  }

  Rectangle {
    objectName: "emergencyClose"
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Math.round(parent.height * 0.1)
    width: 220
    height: 60
    radius: 30
    color: Qt.rgba(info.foreground.r, info.foreground.g, info.foreground.b, closeTap.pressed ? 0.22 : 0.12)
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: "Close"
      color: info.foreground
      font.family: Style.font.family
      font.pixelSize: 19
      font.bold: true
    }
    MouseArea { id: closeTap; anchors.fill: parent; onClicked: info.closed() }
  }
}
