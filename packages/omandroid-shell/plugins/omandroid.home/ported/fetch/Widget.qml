// SPDX-License-Identifier: MIT
// This phone at a glance, fastfetch style: OS, host, kernel, uptime,
// packages, shell, theme, CPU, memory, storage and battery (fetch.py and
// UPower). Tap it for every detail. Ported from simonschubert/fetch in
// Simon Schubert's omarchy-widgets (MIT, Copyright (c) 2026 Simon Schubert
// and contributors; see
// ../../LICENSE-omarchy-widgets).
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Services.UPower
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
  readonly property color warn: Qt.tint(Commons.Color.accent, Util.alpha(Commons.Color.urgent, 0.5))

  // fetch.py's answer, plus at (ms). Memory and uptime change, so a minute.
  property var f: host && host.cached ? host.cached : null
  property bool details: false

  readonly property var bat: UPower.displayDevice
  readonly property bool hasBattery: !!bat && bat.isPresent === true
  readonly property int level: hasBattery ? Math.round(bat.percentage * 100) : -1
  readonly property string batState: hasBattery ? UPowerDeviceState.toString(bat.state).replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase() : ""

  readonly property string hostName: f ? String(f.model || f.host || "phone").toLowerCase().replace(/ /g, "-") : "…"
  readonly property string user: f ? String(f.user) : "user"

  function bytes(n) {
    var u = ["B", "K", "M", "G", "T"], i = 0
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++ }
    return (i > 0 && n < 10 ? n.toFixed(1) : Math.round(n)) + u[i]
  }
  function span(s) {
    s = Math.max(0, Math.round(s))
    var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60)
    return d > 0 ? d + "d " + h + "h" : h > 0 ? h + "h " + m + "m" : m + "m"
  }
  function used(x) { return x && x.total ? bytes(x.used) + " / " + bytes(x.total) + " (" + Math.round(x.used / x.total * 100) + "%)" : "…" }
  function cpuName() {
    if (!f || !f.cpu) return "…"
    var c = f.cpu
    return (c.soc !== "" ? c.soc : c.model !== "" ? c.model : c.arch) + " (" + c.cores + ")"
  }

  function refresh(force) {
    if (!host || host.busy) return
    if (!force && f && Date.now() - f.at < 60000) return
    host.run(["python3", host.dir + "/fetch.py"], function(result) {
      var d = null
      try { d = JSON.parse(result.stdout.trim()) } catch (e) { d = null }
      if (!d) return
      d.at = Date.now()
      widget.f = d
      widget.host.setCached(d)
    }, { timeout: 15 })
  }

  Component.onCompleted: refresh(false)
  Timer { interval: 300000; repeat: true; running: true; onTriggered: widget.refresh(true) }

  // Arch's A with its rounded cut, in the accent colour.
  component Logo: Canvas {
    property color tint: Commons.Color.accent
    onTintChanged: requestPaint()
    onWidthChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var pts = [[0.5, 0], [1, 1], [0.7, 0.84], [0.62, 0.62], [0.5, 0.56], [0.38, 0.62], [0.3, 0.84], [0, 1]]
      ctx.beginPath()
      for (let i = 0; i < pts.length; i++) {
        if (i === 0) ctx.moveTo(pts[i][0] * width, pts[i][1] * height)
        else ctx.lineTo(pts[i][0] * width, pts[i][1] * height)
      }
      ctx.closePath()
      ctx.fillStyle = tint
      ctx.fill()
    }
  }

  component Line: Row {
    id: line
    property string key: ""
    property string value: ""
    property int size: Style.font.caption
    property int keyWidth: 56
    width: parent ? parent.width : 0
    spacing: Style.spacing.md
    Text {
      width: line.keyWidth
      textFormat: Text.PlainText
      text: line.key
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: line.size
    }
    Text {
      width: line.width - line.keyWidth - line.spacing
      textFormat: Text.PlainText
      text: line.value
      color: widget.fg
      font.family: Style.font.family
      font.pixelSize: line.size
      elide: Text.ElideRight
    }
  }

  component Heading: Column {
    id: heading
    property string label: ""
    width: parent ? parent.width : 0
    topPadding: Style.spacing.lg
    spacing: Style.spacing.xs
    Text {
      textFormat: Text.PlainText
      text: heading.label
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Rectangle { width: heading.width; height: 1; color: Util.alpha(widget.fg, 0.2) }
  }

  component Meter: Column {
    id: meter
    property string label: ""
    property var x_: null
    width: parent ? parent.width : 0
    spacing: Style.spacing.xxs
    readonly property real p: x_ && x_.total ? x_.used / x_.total : 0
    Line { key: meter.label; value: widget.used(meter.x_); size: Style.font.bodySmall; keyWidth: 100 }
    Rectangle {
      x: 100 + Style.spacing.md
      width: meter.width - x
      height: Math.max(5, Style.spacing.sm)
      radius: height / 2
      color: Util.alpha(widget.fg, 0.15)
      Rectangle {
        width: parent.width * meter.p
        height: parent.height
        radius: parent.radius
        color: meter.p > 0.85 ? Commons.Color.urgent : Commons.Color.accent
      }
    }
  }

  // The swatches fastfetch draws, in the theme's own colours.
  component Swatches: Row {
    spacing: 2
    Repeater {
      model: [Commons.Color.urgent, Commons.Color.accent, widget.warn, widget.fg, Commons.Color.muted, Commons.Color.menu.border]
      delegate: Rectangle {
        required property color modelData
        width: 10; height: 5
        color: modelData
      }
    }
  }

  // ---------- the tile
  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: 1
    visible: !widget.details
    clip: true

    Row {
      width: parent.width
      spacing: Style.spacing.lg
      bottomPadding: Style.spacing.sm
      Logo { width: 28; height: 28 }
      Column {
        width: parent.width - 28 - parent.spacing
        spacing: 2
        anchors.verticalCenter: parent.verticalCenter
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: widget.user + "@" + widget.hostName
          color: Commons.Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          elide: Text.ElideRight
        }
        Swatches { }
      }
    }
    Line { key: "os"; value: widget.f ? widget.f.os : "…" }
    Line { key: "host"; value: widget.f ? (widget.f.model || widget.f.host) : "…" }
    Line { key: "kernel"; value: widget.f ? widget.f.kernel.split("-")[0] : "…" }
    Line { key: "uptime"; value: widget.f ? widget.span(widget.f.uptime + (Date.now() - widget.f.at) / 1000) : "…" }
    Line { key: "packages"; value: widget.f ? widget.f.pkgs + " (pacman)" : "…" }
    Line { key: "shell"; value: widget.f ? widget.f.shell : "…" }
    Line { key: "theme"; value: widget.f ? (widget.f.theme || "default") : "…" }
    Line { key: "cpu"; value: widget.cpuName() }
    Line { key: "memory"; value: widget.f ? widget.used(widget.f.memory) : "…" }
    Line { key: "disk"; value: widget.f ? widget.used(widget.f.storage) : "…" }
    Line { key: "battery"; value: widget.hasBattery ? widget.level + "% · " + widget.batState : "none" }
  }

  MouseArea {
    anchors.fill: parent
    visible: !widget.details
    enabled: !widget.editing
    onClicked: { widget.details = true; widget.refresh(true) }
  }

  // ---------- details (the original's full screen)
  Flickable {
    id: sheet
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    visible: widget.details
    clip: true
    interactive: !widget.editing
    boundsBehavior: Flickable.StopAtBounds
    contentHeight: more.height

    Column {
      id: more
      width: sheet.width
      spacing: Style.spacing.xs

      Row {
        width: parent.width
        spacing: Style.spacing.xl
        Logo { width: 56; height: 56 }
        Column {
          width: parent.width - 56 - parent.spacing - closeText.width
          spacing: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: widget.user + "@" + widget.hostName
            color: Commons.Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "omandroid · " + (widget.f ? String(widget.f.theme || "default").toLowerCase() : "…")
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Swatches { }
        }
        Text {
          id: closeText
          textFormat: Text.PlainText
          text: "close"
          color: Commons.Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.spacing.xl
            enabled: !widget.editing
            onClicked: widget.details = false
          }
        }
      }

      Heading { label: "phone" }
      Line { key: "host"; value: widget.f ? (widget.f.model || widget.f.host) : "…"; size: Style.font.bodySmall; keyWidth: 100 }
      Line { key: "kernel"; value: widget.f ? widget.f.kernel : "…"; size: Style.font.bodySmall; keyWidth: 100 }
      Line { key: "uptime"; value: widget.f ? widget.span(widget.f.uptime) : "…"; size: Style.font.bodySmall; keyWidth: 100 }
      Line { key: "locale"; value: widget.f ? widget.f.locale + " · " + widget.f.timezone : "…"; size: Style.font.bodySmall; keyWidth: 100 }

      Heading { label: "hardware" }
      Line { key: "cpu"; value: widget.f && widget.f.cpu ? (widget.f.cpu.soc || widget.f.cpu.model || "…") : "…"; size: Style.font.bodySmall; keyWidth: 100 }
      Line {
        key: "cores"
        value: widget.f && widget.f.cpu ? widget.f.cpu.cores + " · " + widget.f.cpu.arch
          + (widget.f.cpu.maxMhz ? " · up to " + (widget.f.cpu.maxMhz / 1000).toFixed(2) + " GHz" : "") : "…"
        size: Style.font.bodySmall; keyWidth: 100
      }
      Line {
        key: "display"
        value: widget.f && widget.f.display ? widget.f.display.width + "x" + widget.f.display.height + " @ " + widget.f.display.hz + "Hz · scale " + widget.f.display.scale : "…"
        size: Style.font.bodySmall; keyWidth: 100
      }
      Meter { label: "memory"; x_: widget.f ? widget.f.memory : null }
      Meter { label: "storage"; x_: widget.f ? widget.f.storage : null }

      Heading { label: "battery" }
      Line { key: "level"; value: widget.hasBattery ? widget.level + "% · " + widget.batState : "none"; size: Style.font.bodySmall; keyWidth: 100 }
      Rectangle {
        visible: widget.hasBattery
        x: 100 + Style.spacing.md
        width: more.width - x
        height: Math.max(5, Style.spacing.sm)
        radius: height / 2
        color: Util.alpha(widget.fg, 0.15)
        Rectangle {
          width: parent.width * Math.max(0, widget.level) / 100
          height: parent.height
          radius: parent.radius
          color: widget.level <= 15 ? Commons.Color.urgent : widget.level <= 30 ? widget.warn : Commons.Color.accent
        }
      }
      Line {
        visible: widget.f && widget.f.battery && !!widget.f.battery.temp
        key: "temperature"
        value: visible ? (Number(widget.f.battery.temp) / 10).toFixed(1) + "°C" : ""
        size: Style.font.bodySmall; keyWidth: 100
      }
      Line {
        visible: widget.f && widget.f.battery && !!widget.f.battery.voltage_now
        key: "voltage"
        value: visible ? (Number(widget.f.battery.voltage_now) / 1000000).toFixed(2) + " V" : ""
        size: Style.font.bodySmall; keyWidth: 100
      }
      Line {
        key: "health"
        value: widget.hasBattery && widget.bat.healthSupported ? Math.round(widget.bat.healthPercentage) + "%"
          : widget.f && widget.f.battery && widget.f.battery.health ? widget.f.battery.health : "unknown"
        size: Style.font.bodySmall; keyWidth: 100
      }
      Line {
        visible: widget.f && widget.f.battery && !!widget.f.battery.cycle_count
        key: "cycles"
        value: visible ? widget.f.battery.cycle_count : ""
        size: Style.font.bodySmall; keyWidth: 100
      }
      Line {
        visible: widget.f && widget.f.battery && !!widget.f.battery.technology
        key: "technology"
        value: visible ? widget.f.battery.technology : ""
        size: Style.font.bodySmall; keyWidth: 100
      }

      Heading { label: "linux" }
      Line { key: "os"; value: widget.f ? widget.f.os : "…"; size: Style.font.bodySmall; keyWidth: 100 }
      Line { key: "packages"; value: widget.f ? widget.f.pkgs + " (" + widget.f.explicit + " explicit)" : "…"; size: Style.font.bodySmall; keyWidth: 100 }
      Line { key: "shell"; value: widget.f ? widget.f.shell : "…"; size: Style.font.bodySmall; keyWidth: 100 }
      Line { key: "upgraded"; value: widget.f ? (widget.f.upgraded || "never") : "…"; size: Style.font.bodySmall; keyWidth: 100 }
      Text {
        anchors.right: parent.right
        topPadding: Style.spacing.lg
        bottomPadding: Style.spacing.lg
        textFormat: Text.PlainText
        text: "fastfetch ↗"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        MouseArea {
          anchors.fill: parent
          enabled: !widget.editing
          onClicked: if (widget.host) widget.host.launch(["xdg-terminal-exec", "-e", "sh", "-c",
            "fastfetch || echo 'fastfetch is not installed: sudo pacman -S fastfetch'; printf '\\nPress Enter to close'; read -r _"])
        }
      }
    }
  }
}
