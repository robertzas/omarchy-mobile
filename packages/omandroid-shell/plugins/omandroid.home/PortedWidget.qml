// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "HomeModel.js" as HomeModel

// The frame of a built-in widget ported from Simon Schubert's
// omarchy-widgets (MIT; LICENSE-omarchy-widgets next to this file). Each
// port lives in its own folder under ported/ and is written against the
// same narrow `host` the user's own widgets get (WidgetHost: theme colours,
// the system time format, the cache that outlives layout edits, commands
// with a timeout and a rate limit). This frame gives it that host, its
// settings (the entry's config) and its size in cells, like every built-in.
//
// A port that uses the internet stays off, and makes no request, until the
// user turns it on in its settings (`enabled`), as the weather widget does.
Item {
  id: frame

  // Set by Home.qml's cell, like every widget.
  property var home: null
  property var entry: null
  property bool editing: false
  readonly property var config: entry && entry.config ? entry.config : ({})

  // Set by the <Type>Widget.qml that names the port.
  property string folder: ""
  property var capabilities: []

  readonly property var spec: entry ? HomeModel.widgetSpec(entry.type) : null
  // Network ports (the registry's `network`) are opt-in, as the weather widget is.
  readonly property bool usesNetwork: !!spec && spec.network === true
  readonly property bool on: !usesNetwork || config.enabled === true
  readonly property string url: folder ? Qt.resolvedUrl(folder + "/Widget.qml") : ""
  readonly property string dir: folder ? decodeURIComponent(String(Qt.resolvedUrl(folder)).replace(/^file:\/\//, "")) : ""

  readonly property color fg: home ? home.foreground : Commons.Color.menu.text
  readonly property color dim: home ? home.dimForeground : Commons.Color.menu.text

  WidgetHost {
    id: host
    home: frame.home
    instanceId: frame.entry ? frame.entry.id : ""
    widgetId: frame.entry ? frame.entry.type : ""
    dir: frame.dir
    capabilities: frame.capabilities
  }

  Loader {
    id: content
    anchors.fill: parent

    // Created with the contract's properties already set, so the port has
    // them in its Component.onCompleted; kept up to date from here on.
    onLoaded: {
      var w = item
      var bind = function(name, value) { if (name in w) w[name] = value }
      bind("settings", Qt.binding(function() { return frame.config }))
      bind("editing", Qt.binding(function() { return frame.editing }))
      bind("cellsWide", Qt.binding(function() { return frame.entry ? frame.entry.w : 1 }))
      bind("cellsHigh", Qt.binding(function() { return frame.entry ? frame.entry.h : 1 }))
    }
  }

  function build() {
    content.source = ""
    if (!on || !url) return
    content.setSource(url, {
      host: host,
      settings: config,
      editing: editing,
      cellsWide: entry ? entry.w : 1,
      cellsHigh: entry ? entry.h : 1
    })
  }
  onOnChanged: build()
  onUrlChanged: build()
  Component.onCompleted: build()

  // Off: say what it would do, and open the settings to turn it on.
  Column {
    anchors.centerIn: parent
    width: frame.width - Style.spacing.xxl * 2
    visible: !frame.on
    spacing: Style.spacing.xs

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: (frame.spec ? frame.spec.icon + "  " + frame.spec.name : "") + " is off"
      color: frame.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      visible: frame.height > 90
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: "Tap to turn it on. It uses the internet" + (frame.spec && frame.spec.source ? " (" + frame.spec.source + ")." : ".")
      color: frame.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      wrapMode: Text.Wrap
    }
  }

  MouseArea {
    anchors.fill: parent
    visible: !frame.on
    enabled: !frame.editing
    onClicked: if (frame.home && frame.entry) frame.home.openSettings(frame.entry.id)
  }
}
