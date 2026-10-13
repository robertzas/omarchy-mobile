// SPDX-License-Identifier: MIT
// A pixel owl to look after. Ported from simonschubert/owl in Simon
// Schubert's omarchy-widgets (MIT, Copyright (c) 2026 Simon Schubert and
// contributors; see
// ../../LICENSE-omarchy-widgets). Its moods come from real things: the hour
// (it sleeps from 23 to 7), when it was last fed (hungry after 8 h),
// whether music plays (MPRIS) and the battery (UPower). A tap does what it
// needs most: hatch the egg, feed it, or pet it. Idle, it moves once a
// second; after a tap it animates smoothly for a few seconds.
import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import "Sprite.js" as Sprite

Item {
  id: widget

  property var host: null
  property var settings: ({})
  property bool editing: false
  property int cellsWide: 1
  property int cellsHigh: 1

  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text
  readonly property color bg: Commons.Color.menu.background
  readonly property color accent: Commons.Color.accent
  readonly property color warm: mix(Commons.Color.urgent, fg, 0.3)

  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
  }

  // Kept in the placement's settings: Unix seconds, 0 for "not yet".
  property real born: Number(settings.born) || 0
  property real fed: Number(settings.fed) || 0
  property int pets: Number(settings.pets) || 0

  // ---------- the world
  SystemClock { id: clock; precision: SystemClock.Minutes }
  readonly property real now: clock.date.getTime() / 1000
  readonly property int hour: clock.date.getHours()
  // Through an untyped property: qmllint 6.12 types Mpris.players as an
  // UntypedObjectModel and doesn't know its values.
  readonly property var playerModel: Mpris.players
  readonly property var players: playerModel ? playerModel.values : []
  readonly property var playing: {
    for (let i = 0; i < players.length; i++) if (players[i] && players[i].isPlaying) return players[i]
    return null
  }
  readonly property var battery: UPower.displayDevice
  readonly property int level: battery && battery.isPresent ? Math.round(battery.percentage * 100) : -1

  readonly property bool hatched: born > 0
  readonly property bool asleep: hatched && (hour >= 23 || hour < 7)
  readonly property bool hungry: hatched && now - fed > 8 * 3600
  readonly property bool dancing: playing !== null
  readonly property bool tired: level >= 0 && level < 20 && UPower.onBattery
  readonly property string mood: !hatched ? "egg" : asleep ? "asleep" : hungry ? "hungry" : dancing ? "dancing" : tired ? "tired" : "content"
  readonly property int day: Math.floor((now - born) / 86400) + 1
  readonly property string ago: now - fed < 3600 ? Math.max(Math.floor((now - fed) / 60), 1) + "m" : Math.floor((now - fed) / 3600) + "h"
  readonly property string song: playing && playing.trackTitle ? String(playing.trackTitle).toLowerCase() : "music"

  // ---------- time: a step a second, smooth for a moment after a tap
  readonly property real t0: Date.now()
  property real time: 0
  property real since: 1000          // seconds since the last tap
  property string tapKind: ""
  property real burst: 1
  NumberAnimation { id: burstAnim; target: widget; property: "burst"; from: 0; to: 1; duration: 3000 }
  onBurstChanged: {
    since = burst >= 1 ? 1000 : burst * 3
    tick()
  }
  function tick() { time = (Date.now() - t0) / 1000; art.requestPaint() }
  Timer { interval: 1000; repeat: true; running: !burstAnim.running; onTriggered: widget.tick() }
  onMoodChanged: art.requestPaint()

  Timer {
    id: saveLater
    interval: 3500
    onTriggered: if (widget.host) widget.host.saveSettings({ born: widget.born, fed: widget.fed, pets: widget.pets })
  }

  function tap() {
    var now = Date.now() / 1000
    tapKind = !hatched ? "hatch" : asleep ? "peek" : hungry ? "feed" : "pet"
    if (!hatched || (hungry && !asleep)) fed = now
    if (hatched && !asleep && !hungry) pets += 1
    if (!hatched) born = now
    burstAnim.restart()
    saveLater.restart()
  }

  // ---------- the art
  readonly property var owlArt: Sprite.runs([
    ".b..........b.",
    ".bb........bb.",
    ".bbbbbbbbbbbb.",
    "bbFFFFbbFFFFbb",
    "bFFFFFFFFFFFFb",
    "bFFFFFFFFFFFFb",
    "bbFFFFkkFFFFbb",
    "bbbbbbkkbbbbbb",
    "wbbllllllllbbw",
    "wwbvlvllvlvbww",
    "wwbllllllllbww",
    "wwbblvllvlbbww",
    ".wwbbllllbbww.",
    "..bbbbbbbbbb..",
    "...ff....ff..."
  ])
  readonly property var eggArt: Sprite.runs([
    "..eeee..", ".eeeeee.", ".eeeeee.", "eeeeeeee", "eeeeseee",
    "eseeeeee", "eeeeeese", "eeeeeeee", ".eeeeee.", "..eeee.."
  ])
  readonly property var heartArt: Sprite.runs([".h.h.", "hhhhh", "hhhhh", ".hhh.", "..h.."])
  readonly property var cookieArt: Sprite.runs([".ccc.", "cdccc", "ccccd", "ccdcc", ".ccc."])
  readonly property var pal: ({
    b: accent, F: mix(fg, bg, 0.12), k: mix(warm, fg, 0.35), w: mix(accent, bg, 0.35),
    l: mix(accent, fg, 0.45), v: mix(accent, bg, 0.2), f: warm,
    e: mix(fg, bg, 0.15), s: mix(accent, bg, 0.3),
    h: Commons.Color.urgent, c: mix(warm, fg, 0.4), d: mix(warm, bg, 0.6)
  })
  onPalChanged: art.requestPaint()

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.xs

    Canvas {
      id: art
      width: parent.width
      height: parent.height - statusView.height - parent.spacing
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()

      onPaint: { let c, k;
        var ctx = getContext("2d")
        ctx.reset()
        var W = width, H = height, pal = widget.pal, t = widget.time, since = widget.since
        var mood = widget.mood, kind = widget.tapKind, bg = widget.bg, fg = widget.fg
        var p = Math.max(2, Math.min(8, Math.floor(Math.min(W / 18, H / 22))))
        var s = p + 0.5
        var branchY = Math.floor((H - 3 * p) / p) * p
        var ox = Math.floor((W / 2 - 7 * p) / p) * p
        var oy = branchY - 15 * p + p
        var rect = function(x, y, w, h, c) { ctx.fillStyle = c; ctx.fillRect(x, y, w, h) }

        // Night sky: a crescent moon and a few twinkling stars.
        if (widget.asleep) {
          for (c = 0; c < 25; c++) {
            let i = c % 5 - 2, j = Math.floor(c / 5) - 2
            if (i * i + j * j <= 5 && (i + 1) * (i + 1) + (j + 1) * (j + 1) > 4)
              rect(2 * p + (i + 2) * p, 2 * p + (j + 2) * p, s, s, pal.k)
          }
          for (k = 0; k < 5; k++)
            rect(Math.floor(W * (0.3 + 0.15 * k) / p) * p, (2 + (k * 7) % 5) * p, p, p,
                 Util.alpha(fg, 0.3 + 0.5 * Math.abs(Math.sin(t * 0.8 + k * 1.9))))
        }

        // The branch, with leaves.
        rect(0, branchY, W, p * 2, widget.mix(widget.warm, bg, 0.55))
        rect(0, branchY + p, W, p, widget.mix(widget.warm, bg, 0.7))
        var leaves = [[0.12, -1], [0.18, 0], [0.82, -1], [0.88, -2]]
        for (let l = 0; l < leaves.length; l++)
          rect(Math.floor(W * leaves[l][0] / p) * p, branchY + leaves[l][1] * p, 2 * p, p, widget.mix(widget.accent, bg, 0.2))

        if (!widget.hatched) {
          // The egg rocks now and then.
          let rock = t % 4 < 1 && t % 2 < 1 ? (Math.floor(t) % 2 ? 8 : -8) : 0
          ctx.save()
          ctx.translate(W / 2, branchY)
          ctx.rotate(rock * Math.PI / 180)
          Sprite.draw(ctx, widget.eggArt, Math.floor((W / 2 - 4 * p) / p) * p - W / 2, -10 * p, p, pal)
          ctx.restore()
          return
        }

        var happy = since < 2.5 && (kind === "pet" || kind === "hatch")
        var eating = since < 2.2 && kind === "feed"
        // A hop when happy, otherwise a one-pixel breath; feet stay put.
        var hop = happy ? Math.round(Math.abs(Math.sin(since * 7)) * 2 * Math.max(1.4 - since, 0)) * p : 0
        var breath = (Math.floor(t / (widget.asleep ? 2 : 1)) % 2) * p
        var shake = mood === "dancing" ? [0, 1, 0, -1][Math.floor(t) % 4] * p : 0
        var flap = happy && Math.floor(since * 8) % 2 === 0 ? -p : 0
        var bx = ox + shake, by = oy - hop
        Sprite.draw(ctx, widget.owlArt, bx, by, p, pal, function(letter) {
          return letter === "f" ? 0 : letter === "w" ? breath + flap : breath
        })

        // Eyes, over the face discs.
        var ey = by + breath, dark = bg
        var blink = Math.floor(t) % 5 === 4
        var e
        if (widget.asleep && !(kind === "peek" && since < 2)) {
          for (e = 2; e <= 8; e += 6) rect(bx + e * p, ey + 5 * p, 4 * p, s, dark)
        } else if (widget.asleep) {
          rect(bx + 2 * p, ey + 5 * p, 4 * p, s, dark)
          rect(bx + 9 * p, ey + 4 * p, 2 * p, 2 * p, dark)
        } else if (happy || (eating && since > 0.7) || mood === "dancing") {
          for (e = 2; e <= 8; e += 6) {
            rect(bx + e * p, ey + 5 * p, s, s, dark)
            rect(bx + (e + 1) * p, ey + 4 * p, 2 * p, s, dark)
            rect(bx + (e + 3) * p, ey + 5 * p, s, s, dark)
          }
        } else if (blink) {
          for (e = 2; e <= 8; e += 6) rect(bx + e * p, ey + 5 * p, 4 * p, s, dark)
        } else if (mood === "tired") {
          for (e = 2; e <= 8; e += 6) {
            rect(bx + e * p, ey + 4 * p, 4 * p, s, widget.mix(widget.accent, bg, 0.2))
            rect(bx + (e + 1) * p, ey + 5 * p, 2 * p, s, dark)
          }
        } else {
          // Looking around; a hungry one looks up at its thought.
          let lx = mood === "hungry" ? 1 : [0, 1, 0, -1][Math.floor(t / 3) % 4]
          let ly = mood === "hungry" ? -1 : 0
          for (e = 3; e <= 9; e += 6) rect(bx + (e + lx) * p, ey + (4 + ly) * p, 2 * p, 2 * p, dark)
        }

        // Chomping: the beak opens and shuts, crumbs fall.
        if (eating && since > 0.7) {
          if (Math.floor(since * 6) % 2 === 0) rect(bx + 6 * p, ey + 7 * p, 2 * p, s, dark)
          let fall = since - 0.7
          for (k = 0; k < 3; k++)
            rect(bx + (5 + k * 2) * p + (k - 1) * fall * 6 * p, ey + 8 * p + fall * fall * 20 * p, p, p, pal.c)
        }
        // The cookie drops into its beak.
        if (eating && since <= 0.7)
          Sprite.draw(ctx, widget.cookieArt, bx + 4.5 * p, -5 * p + (ey + 10 * p) * since / 0.7, p, pal)

        // Hearts float up.
        if (happy) {
          for (k = 0; k < 3; k++) {
            let ht = since - k * 0.35
            if (ht > 0 && ht < 1.8) {
              ctx.globalAlpha = 1 - ht / 1.8
              Sprite.draw(ctx, widget.heartArt, Math.floor((bx + [-1, 5, 11][k] * p + Math.sin(ht * 5 + k) * p) / p) * p,
                          Math.floor((by - ht * 6 * p) / p) * p, p, pal)
              ctx.globalAlpha = 1
            }
          }
        }
        // Shell pieces flying off a fresh hatchling.
        if (kind === "hatch" && since < 1.2) {
          ctx.globalAlpha = 1 - since / 1.2
          for (let q = 0; q < widget.eggArt.length; q++) {
            let cell = widget.eggArt[q]
            if (cell[1] >= 5) continue
            let dir = cell[0] < 4 ? -1 : 1
            ctx.fillStyle = pal[cell[2]]
            ctx.fillRect(bx + (3 + cell[0]) * p + dir * since * 30 * p, by + (cell[1] - 2) * p - since * 12 * p + since * since * 30 * p, cell[3] * p + 0.5, s)
          }
          ctx.globalAlpha = 1
        }

        ctx.textAlign = "center"
        ctx.textBaseline = "middle"
        // Zzz.
        if (widget.asleep && !(kind === "peek" && since < 2)) {
          for (k = 0; k < 3; k++) {
            let zt = ((t * 0.4 + k / 3) % 1)
            ctx.fillStyle = Util.alpha(fg, 1 - zt)
            ctx.font = "bold " + Math.round((2 + zt * 2) * p) + "px '" + Style.font.family + "'"
            ctx.fillText("z", bx + 12 * p + zt * 4 * p, by + p - zt * 8 * p)
          }
        }
        // Music notes drift up while it dances.
        if (mood === "dancing") {
          for (k = 0; k < 2; k++) {
            let nt = (t * 0.5 + k / 2) % 1
            let nx = Math.floor((bx + (k === 0 ? -2 : 14) * p + Math.sin(nt * 6) * p) / p) * p
            let ny = Math.floor((by + 6 * p - nt * 8 * p) / p) * p
            let nc = Util.alpha(k === 0 ? widget.accent : widget.warm, 1 - nt)
            rect(nx, ny + 2 * p, 2 * p, 2 * p, nc)
            rect(nx + p, ny - p, p, 3 * p, nc)
            rect(nx + 2 * p, ny - p, p, p, nc)
          }
        }
        // Hungry: a thought bubble with a cookie.
        if (mood === "hungry" && !eating) {
          let cloud = widget.mix(fg, bg, 0.4)
          let tx = bx + 9 * p, ty = Math.max(by - 8 * p, 0)
          rect(tx - p, ty + 7 * p, p, p, cloud)
          rect(tx, ty + 6 * p, p, p, cloud)
          rect(tx + p, ty, 7 * p, 7 * p, cloud)
          Sprite.draw(ctx, widget.cookieArt, tx + 2 * p, ty + p, p, pal)
        }
      }

      MouseArea {
        anchors.fill: parent
        enabled: !widget.editing
        onClicked: widget.tap()
      }
    }

    Text {
      id: statusView
      width: parent.width
      textFormat: Text.PlainText
      readonly property bool narrow: widget.cellsWide < 3
      text: widget.mood === "egg" ? (narrow ? "tap to hatch" : "an egg · tap to hatch")
        : widget.mood === "asleep" ? "zzz · day " + widget.day
        : widget.mood === "hungry" ? (narrow ? "tap to feed" : "hungry · tap to feed")
        : widget.mood === "dancing" ? "♪ " + widget.song
        : widget.mood === "tired" ? (narrow ? "tired · " : "tired · battery ") + widget.level + "%"
        : narrow ? "day " + widget.day + " · ♥" + widget.pets
        : "day " + widget.day + " · fed " + widget.ago + " ago · ♥" + widget.pets
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
    }
  }
}
