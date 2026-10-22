// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "CallModel.js" as CallModel

// The heads-up card: a call ringing on an unlocked phone, or a second call
// waiting during one. It sits at the top, over apps, with Decline and
// Answer; a tap on the caller opens the Phone app's answer page. As a
// strip ("mini"), it is also the folded in-call card over the lock, with
// the elapsed time and an end button, and a tap unfolds it.
Item {
  id: headsUp

  property var call: null
  property double nowMs: Date.now()
  // "heads-up" or "mini"
  property string mode: "heads-up"
  readonly property bool mini: mode === "mini"

  signal answer()
  signal decline()
  signal hangup()
  signal open()

  readonly property color foreground: Commons.Color.popups.text
  readonly property color accent: Commons.Color.accent
  readonly property color answerColor: "#1e9e53"
  readonly property color endColor: "#d9362b"

  implicitHeight: body.height + 16

  Rectangle {
    id: body
    x: 8
    y: 8
    width: parent.width - 16
    height: headsUp.mini ? 76 : 156
    radius: 28
    color: Commons.Color.popups.background
    border.width: 1
    border.color: Qt.rgba(headsUp.accent.r, headsUp.accent.g, headsUp.accent.b, 0.45)

    MouseArea { anchors.fill: parent; onClicked: headsUp.open() }

    Rectangle {
      id: avatar
      x: 16
      y: headsUp.mini ? 14 : 18
      width: 48
      height: 48
      radius: 24
      color: Qt.rgba(headsUp.accent.r, headsUp.accent.g, headsUp.accent.b, 0.22)
      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: CallModel.initials(headsUp.call)
        color: headsUp.foreground
        font.family: Style.font.family
        font.pixelSize: 19
        font.bold: true
      }
    }

    Column {
      anchors.left: avatar.right
      anchors.leftMargin: 14
      anchors.right: headsUp.mini ? endSmall.left : parent.right
      anchors.rightMargin: 14
      anchors.verticalCenter: avatar.verticalCenter
      spacing: 2
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: CallModel.title(headsUp.call)
        color: headsUp.foreground
        font.family: Style.font.family
        font.pixelSize: 19
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: CallModel.stateLabel(headsUp.call, headsUp.nowMs)
        color: headsUp.foreground
        opacity: 0.7
        font.family: Style.font.family
        font.pixelSize: 15
        elide: Text.ElideRight
      }
    }

    // Folded in-call strip: end the call from here too.
    Rectangle {
      id: endSmall
      objectName: "endSmall"
      visible: headsUp.mini
      anchors.right: parent.right
      anchors.rightMargin: 14
      anchors.verticalCenter: avatar.verticalCenter
      width: 64
      height: 48
      radius: 24
      color: endSmallTap.pressed ? Qt.darker(headsUp.endColor, 1.2) : headsUp.endColor
      Text { anchors.centerIn: parent; textFormat: Text.PlainText; text: String.fromCodePoint(0xF03F5); color: "white"; font.family: Style.font.family; font.pixelSize: 26 }
      MouseArea { id: endSmallTap; anchors.fill: parent; onClicked: headsUp.hangup() }
    }

    Row {
      visible: !headsUp.mini
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: 16
      spacing: 12

      Action {
        objectName: "declineButton"
        width: (parent.width - parent.spacing) / 2
        fill: headsUp.endColor
        glyph: 0xF03F5
        label: "Decline"
        onTapped: headsUp.decline()
      }
      Action {
        objectName: "answerButton"
        width: (parent.width - parent.spacing) / 2
        fill: headsUp.answerColor
        glyph: 0xF03F2
        label: "Answer"
        onTapped: headsUp.answer()
      }
    }
  }

  component Action: Rectangle {
    id: action
    property color fill: "grey"
    property int glyph: 0
    property string label: ""
    signal tapped()
    height: 56
    radius: height / 2
    color: actionTap.pressed ? Qt.darker(action.fill, 1.2) : action.fill
    Row {
      anchors.centerIn: parent
      spacing: 10
      Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: String.fromCodePoint(action.glyph); color: "white"; font.family: Style.font.family; font.pixelSize: 24 }
      Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: action.label; color: "white"; font.family: Style.font.family; font.pixelSize: 18; font.bold: true }
    }
    MouseArea { id: actionTap; anchors.fill: parent; onClicked: action.tapped() }
  }
}
