// SPDX-License-Identifier: MIT
// What's playing, from MPRIS: cover, track, progress and previous /
// play-pause / next. Ported from simonschubert/now-playing in Simon
// Schubert's omarchy-widgets (MIT, Copyright (c) 2026 Simon Schubert and
// contributors; see
// ../../LICENSE-omarchy-widgets).
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.Commons
import qs.Commons as Commons

Item {
  id: widget

  property var host: null
  property var settings: ({})
  property bool editing: false
  property int cellsWide: 1
  property int cellsHigh: 1

  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text

  // The player that is playing, else the last one that was.
  // Through an untyped property: qmllint 6.12 types Mpris.players as an
  // UntypedObjectModel and doesn't know its values.
  readonly property var playerModel: Mpris.players
  readonly property var players: playerModel ? playerModel.values : []
  property var lastPlayer: null
  readonly property var player: {
    for (let i = 0; i < players.length; i++)
      if (players[i] && players[i].isPlaying) return players[i]
    if (lastPlayer && players.indexOf(lastPlayer) >= 0) return lastPlayer
    return players.length > 0 ? players[0] : null
  }
  onPlayerChanged: { if (player) lastPlayer = player; sync() }

  readonly property bool has: !!player && !!player.trackTitle
  readonly property bool playing: !!player && player.isPlaying
  readonly property real dur: player && player.lengthSupported ? Math.max(0, player.length) : 0
  property real pos: 0
  property int beat: 0
  readonly property bool tall: height > width * 1.3
  readonly property bool narrow: cellsWide < 3
  readonly property int touch: 44

  function clock(s) {
    s = Math.max(0, Math.floor(s))
    var sec = s % 60
    return Math.floor(s / 60) + ":" + (sec < 10 ? "0" : "") + sec
  }
  function sync() {
    pos = player && player.positionSupported ? Math.min(player.position, dur > 0 ? dur : player.position) : 0
  }

  // MPRIS doesn't push the position: read it once a second, only while
  // something plays. The same tick steps the little level bars.
  Timer {
    interval: 1000
    repeat: true
    running: widget.playing
    triggeredOnStart: true
    onTriggered: { widget.sync(); widget.beat++ }
  }

  // ---------- pieces

  component Art: Rectangle {
    id: artBox
    property real d: 64
    width: d
    height: d
    radius: Style.cornerRadius
    clip: true
    color: Util.alpha(Commons.Color.accent, 0.25)
    Text {
      anchors.centerIn: parent
      visible: img.status !== Image.Ready
      textFormat: Text.PlainText
      text: "♪"
      color: Util.alpha(widget.fg, 0.85)
      font.family: Style.font.family
      font.pixelSize: artBox.d * 0.45
    }
    Image {
      id: img
      anchors.fill: parent
      source: widget.player && widget.player.trackArtUrl ? widget.player.trackArtUrl : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      sourceSize.width: artBox.d * 2
      sourceSize.height: artBox.d * 2
    }
  }

  component AppLine: Row {
    spacing: Style.spacing.md
    Row {
      visible: widget.playing
      spacing: 2
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 2
      Repeater {
        model: 3
        delegate: Rectangle {
          required property int index
          width: 3
          height: 3 + ((widget.beat * (index + 2) + index * 3) % 4) * 3
          anchors.bottom: parent.bottom
          radius: 1
          color: Commons.Color.accent
          Behavior on height { NumberAnimation { duration: 300 } }
        }
      }
    }
    Text {
      textFormat: Text.PlainText
      text: widget.player ? String(widget.player.identity || "").toLowerCase() : ""
      color: widget.playing ? Commons.Color.accent : widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  component Bar: Rectangle {
    height: Math.max(4, Style.spacing.sm)
    radius: height / 2
    color: Util.alpha(Commons.Color.muted, 0.3)
    visible: widget.dur > 0
    Rectangle {
      width: parent.width * (widget.dur > 0 ? Math.min(1, widget.pos / widget.dur) : 0)
      height: parent.height
      radius: parent.radius
      color: Commons.Color.accent
      Behavior on width { NumberAnimation { duration: 900 } }
    }
  }

  component Control: Item {
    id: ctl
    property string kind: "toggle"
    readonly property bool usable: !!widget.player && (kind === "toggle" ? widget.player.canTogglePlaying
      : kind === "next" ? widget.player.canGoNext : widget.player.canGoPrevious)
    width: widget.touch
    height: widget.touch
    opacity: usable ? 1 : 0.35
    Rectangle {
      anchors.centerIn: parent
      visible: ctl.kind === "toggle"
      width: 38
      height: 38
      radius: 19
      color: widget.fg
    }
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: ctl.kind === "toggle" ? (widget.playing ? "󰏤" : "󰐊") : ctl.kind === "next" ? "󰒭" : "󰒮"
      color: ctl.kind === "toggle" ? Commons.Color.menu.background : widget.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.iconLarge
    }
    MouseArea {
      anchors.fill: parent
      enabled: ctl.usable && !widget.editing
      onClicked: {
        var p = widget.player
        if (ctl.kind === "toggle") p.togglePlaying()
        else if (ctl.kind === "next") p.next()
        else p.previous()
      }
    }
  }

  component Times: Row {
    visible: widget.dur > 0
    spacing: Style.spacing.sm
    Text {
      textFormat: Text.PlainText
      text: widget.clock(widget.pos) + " / " + widget.clock(widget.dur)
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  // A tap on the tile (not on a control) brings up the player's window.
  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: if (widget.player && widget.player.canRaise) widget.player.raise()
  }

  // ---------- side by side
  Row {
    visible: !widget.tall
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.xxl

    Art {
      visible: !widget.narrow
      d: Math.min(parent.height, 132)
      anchors.verticalCenter: parent.verticalCenter
    }

    Column {
      id: info
      width: parent.width - (widget.narrow ? 0 : Math.min(parent.height, 132) + parent.spacing)
      height: parent.height
      spacing: Style.spacing.xxs

      Text {
        visible: !widget.has
        width: parent.width
        textFormat: Text.PlainText
        text: "nothing playing"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
      Text {
        visible: !widget.has
        width: parent.width
        textFormat: Text.PlainText
        text: "start music in any app"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      AppLine { visible: widget.has; width: parent.width }
      Text {
        visible: widget.has
        width: parent.width
        textFormat: Text.PlainText
        text: widget.player ? String(widget.player.trackTitle || "") : ""
        color: widget.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        wrapMode: Text.Wrap
        maximumLineCount: widget.narrow ? 2 : 1
        elide: Text.ElideRight
      }
      Text {
        visible: widget.has
        width: parent.width
        textFormat: Text.PlainText
        text: widget.player ? [widget.player.trackArtist, widget.narrow ? "" : widget.player.trackAlbum]
          .filter(function(x) { return !!x }).join(" · ") : ""
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
      Item {
        width: 1
        height: Math.max(0, info.height - y - bottomRowView.height - wideBar.height - Style.spacing.xxs * 2)
      }
      Bar { id: wideBar; visible: widget.has && widget.dur > 0; width: parent.width }
      Row {
        id: bottomRowView
        visible: widget.has
        width: parent.width
        Times {
          id: wideTimes
          anchors.verticalCenter: parent.verticalCenter
        }
        Item { width: Math.max(0, parent.width - wideTimes.width - widget.touch * 3); height: 1 }
        Control { kind: "previous" }
        Control { kind: "toggle" }
        Control { kind: "next" }
      }
    }
  }

  // ---------- stacked, for a tile taller than wide
  Column {
    visible: widget.tall
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.lg

    Art { d: Math.max(40, Math.min(parent.width, parent.height * 0.45)) }
    AppLine { visible: widget.has; width: parent.width }
    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: widget.has ? String(widget.player.trackTitle || "") : "nothing playing"
      color: widget.has ? widget.fg : widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: widget.has
      wrapMode: Text.Wrap
      maximumLineCount: 3
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: widget.has ? String(widget.player.trackArtist || "") : "start music in any app"
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
    }
    Bar { visible: widget.has && widget.dur > 0; width: parent.width }
    Times { visible: widget.has && widget.dur > 0 }
    Row {
      visible: widget.has
      anchors.horizontalCenter: parent.horizontalCenter
      Control { kind: "previous" }
      Control { kind: "toggle" }
      Control { kind: "next" }
    }
  }
}
