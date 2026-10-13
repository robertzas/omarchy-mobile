// SPDX-License-Identifier: MIT
// One line of a table. Football: zone, rank, crest, club, played (or W-D-L
// when expanded), goal difference, points. US leagues: seed, logo, team,
// record and the league's last column (games behind, points, differential).
import QtQuick
import qs.Commons
import qs.Commons as Commons

Item {
  id: rowView

  property var team: null
  property string kind: "soccer"
  property bool wide: true
  property bool full: false
  property color fg: Commons.Color.menu.text
  property color dim: Commons.Color.menu.text

  readonly property bool soccer: kind === "soccer"
  readonly property color zoneColor: !team || !soccer ? Util.alpha(Commons.Color.accent, 0)
    : team.zone === "green" ? Commons.Color.accent
    : team.zone === "blue" ? Util.alpha(Commons.Color.accent, 0.45)
    : team.zone === "orange" ? Util.alpha(Commons.Color.urgent, 0.55)
    : team.zone === "red" ? Commons.Color.urgent : Util.alpha(Commons.Color.accent, 0)
  readonly property int gd: team && soccer ? team.gd : 0
  readonly property int sign: !team ? 0 : soccer ? (gd > 0 ? 1 : gd < 0 ? -1 : 0) : team.sign

  readonly property string middle: !team ? ""
    : soccer ? (full ? team.won + "-" + team.drawn + "-" + team.lost : wide ? String(team.played) : "")
    : team.rec
  readonly property string last: !team ? "" : soccer ? (gd > 0 ? "+" + gd : String(gd)) : team.b

  implicitHeight: Math.max(16, Style.font.bodySmall * 1.4)

  Row {
    anchors.fill: parent
    spacing: Style.spacing.md

    Rectangle {
      visible: rowView.soccer
      width: 3
      height: 14
      radius: 1.5
      anchors.verticalCenter: parent.verticalCenter
      color: rowView.zoneColor
    }
    Text {
      id: rank
      width: 20
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: !rowView.team ? "" : rowView.soccer ? String(rowView.team.rank) : (rowView.team.seed < 99 ? String(rowView.team.seed) : "–")
      color: rowView.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
    }
    Crest { id: crest; url: rowView.team ? rowView.team.logo : ""; px: 16; anchors.verticalCenter: parent.verticalCenter }
    Text {
      width: Math.max(0, rowView.width - (rowView.soccer ? 3 + 6 * Style.spacing.md : 4 * Style.spacing.md)
                      - rank.width - crest.width - middle.width - last.width - points.width)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: rowView.team ? (rowView.wide ? rowView.team.name : rowView.team.abbr) : ""
      color: rowView.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
    Text {
      id: middle
      width: rowView.middle === "" ? 0 : rowView.soccer && !rowView.full ? 24 : 56
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: rowView.middle
      color: rowView.soccer ? rowView.dim : rowView.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: !rowView.soccer
      horizontalAlignment: Text.AlignRight
    }
    Text {
      id: last
      width: 36
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: rowView.last
      color: rowView.sign > 0 ? Commons.Color.accent : rowView.sign < 0 ? Commons.Color.urgent : rowView.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
    }
    Text {
      id: points
      visible: rowView.soccer
      width: rowView.soccer ? 28 : 0
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: rowView.team && rowView.soccer ? String(rowView.team.pts) : ""
      color: rowView.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      horizontalAlignment: Text.AlignRight
    }
  }
}
