// SPDX-License-Identifier: MIT
// One game: crest, team, a fixed-width centre (score, status, score or the
// kick-off), team, crest, so the columns line up down the list.
import QtQuick
import qs.Commons
import qs.Commons as Commons

Item {
  id: rowView

  property var game: null
  property bool homeFirst: true      // football lists the home side first
  property bool wide: true
  property string timeFormat: "HH:mm"
  property string kickoffText: ""    // instead of the kick-off time, when set
  property color fg: Commons.Color.menu.text
  property color dim: Commons.Color.menu.text

  readonly property var first: game ? (homeFirst ? game.home : game.away) : null
  readonly property var second: game ? (homeFirst ? game.away : game.home) : null
  readonly property bool live: game !== null && game.state === "in"
  readonly property bool final: game !== null && game.state === "post"
  readonly property bool pre: game !== null && !live && !final
  // In a draw neither side is greyed out.
  readonly property bool firstLost: final && second !== null && second.winner
  readonly property bool secondLost: final && first !== null && first.winner

  readonly property int px: wide ? 18 : 14
  readonly property int scoreW: wide ? 26 : 20
  readonly property int dotW: wide ? 8 : 6
  readonly property int statusW: wide ? 72 : 40
  readonly property int centreW: 2 * scoreW + 2 * dotW + statusW
  readonly property int gap: wide ? Style.spacing.lg : Style.spacing.sm

  implicitHeight: Math.max(px, Style.font.bodySmall * 1.4)

  function kickoff() {
    if (!game) return ""
    if (kickoffText !== "") return kickoffText
    var d = new Date(game.at)
    return wide ? Qt.formatDateTime(d, "ddd " + timeFormat) : Qt.formatDateTime(d, timeFormat)
  }

  Row {
    anchors.fill: parent
    spacing: rowView.gap

    Crest { url: rowView.first ? rowView.first.logo : ""; px: rowView.px; anchors.verticalCenter: parent.verticalCenter }
    Text {
      width: (rowView.width - rowView.centreW - 2 * rowView.px - 4 * rowView.gap) / 2
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: rowView.first ? (rowView.wide ? rowView.first.name : rowView.first.abbr) : ""
      color: rowView.firstLost ? rowView.dim : rowView.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Item {
      width: rowView.centreW
      height: parent.height

      Text {
        anchors.fill: parent
        visible: rowView.pre
        textFormat: Text.PlainText
        text: rowView.kickoff()
        color: rowView.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }

      Row {
        anchors.fill: parent
        visible: !rowView.pre
        Text {
          width: rowView.scoreW
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: rowView.first && rowView.first.score !== "" ? rowView.first.score : "–"
          color: rowView.live ? Commons.Color.accent : rowView.firstLost ? rowView.dim : rowView.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: rowView.final && rowView.first !== null && rowView.first.winner
          horizontalAlignment: Text.AlignRight
        }
        Item {
          width: rowView.dotW
          height: parent.height
          Rectangle {
            anchors.centerIn: parent
            width: 5
            height: 5
            radius: 2.5
            visible: rowView.live
            color: Commons.Color.accent
          }
        }
        Text {
          width: rowView.statusW
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: rowView.game ? rowView.game.detail : ""
          color: rowView.live ? Commons.Color.accent : rowView.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
        Item { width: rowView.dotW; height: parent.height }
        Text {
          width: rowView.scoreW
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: rowView.second && rowView.second.score !== "" ? rowView.second.score : "–"
          color: rowView.live ? Commons.Color.accent : rowView.secondLost ? rowView.dim : rowView.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: rowView.final && rowView.second !== null && rowView.second.winner
        }
      }
    }

    Text {
      width: (rowView.width - rowView.centreW - 2 * rowView.px - 4 * rowView.gap) / 2
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: rowView.second ? (rowView.wide ? rowView.second.name : rowView.second.abbr) : ""
      color: rowView.secondLost ? rowView.dim : rowView.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
    }
    Crest { url: rowView.second ? rowView.second.logo : ""; px: rowView.px; anchors.verticalCenter: parent.verticalCenter }
  }
}
