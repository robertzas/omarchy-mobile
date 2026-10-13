// SPDX-License-Identifier: MIT
// Home Assistant entities with their states; tap a light or switch to
// toggle it. Ported from simonschubert/home-assistant in Simon Schubert's
// omarchy-widgets (MIT, Copyright (c) 2026 Simon Schubert and contributors;
// see
// ../../LICENSE-omarchy-widgets).
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
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

  readonly property string base: String(settings.url || "").trim().replace(/\/+$/, "")
  readonly property string token: String(settings.token || "").trim()
  readonly property var ids: String(settings.entities || "").split(/[,\s]+/).filter(function(s) { return /^[a-z0-9_]+\.[a-z0-9_]+$/.test(s) })
  readonly property bool configured: /^https?:\/\/./.test(base) && token !== ""
  readonly property string key: base + "|" + ids.join(",")

  // { key, states: { id: { name, state, unit } }, at } from the last poll.
  property var reading: host && host.cached && host.cached.key === key ? host.cached : null
  property var pending: ({})

  function request(method, path, body, done) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      var value = null
      if (xhr.status === 200) {
        try { value = JSON.parse(xhr.responseText) } catch (e) { value = null }
      }
      done(xhr.status, value)
    }
    xhr.open(method, base + path)
    xhr.setRequestHeader("Authorization", "Bearer " + token)
    xhr.setRequestHeader("Content-Type", "application/json")
    xhr.send(body ? JSON.stringify(body) : "")
  }

  function refresh(force) {
    if (!configured || ids.length === 0) return
    if (!force && reading && Date.now() - reading.at < 120000) return
    var key = widget.key
    var states = {}
    var left = ids.length
    ids.forEach(function(id) {
      widget.request("GET", "/api/states/" + id, null, function(status, e) {
        states[id] = e ? { name: String(e.attributes && e.attributes.friendly_name || id), state: String(e.state),
                           unit: String(e.attributes && e.attributes.unit_of_measurement || "") }
                       : { name: id, state: "unreachable", unit: "" }
        if (--left === 0 && key === widget.key) {
          widget.reading = { key: key, states: states, at: Date.now() }
          if (widget.host) widget.host.setCached(widget.reading)
        }
      })
    })
  }

  function toggle(id) {
    var domain = id.split(".")[0]
    if (["light", "switch", "fan", "input_boolean"].indexOf(domain) < 0 || pending[id]) return
    var p = Object.assign({}, pending); p[id] = true; pending = p
    request("POST", "/api/services/homeassistant/toggle", { entity_id: id }, function() {
      var q = Object.assign({}, widget.pending); delete q[id]; widget.pending = q
      widget.refresh(true)
    })
  }

  Component.onCompleted: refresh(false)
  onKeyChanged: refresh(true)
  Timer { interval: 120000; repeat: true; running: true; onTriggered: widget.refresh(true) }

  readonly property bool unset: !configured || ids.length === 0 || (reading !== null
    && ids.every(function(id) { return !reading.states[id] || reading.states[id].state === "unreachable" }))

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.md

    Text {
      id: titleView
      width: parent.width
      textFormat: Text.PlainText
      text: "home assistant"
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.spacing.md
        enabled: !widget.editing
        onClicked: if (widget.host) widget.host.openSettings()
      }
    }

    Text {
      width: parent.width
      visible: widget.unset
      textFormat: Text.PlainText
      text: "can't reach it: tap to set the URL, token and entities"
      color: widget.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
      MouseArea {
        anchors.fill: parent
        enabled: !widget.editing
        onClicked: if (widget.host) widget.host.openSettings()
      }
    }

    Flickable {
      width: parent.width
      height: parent.height - titleView.height - parent.spacing
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      contentHeight: grid.height

      Grid {
        id: grid
        width: parent.width
        columns: widget.cellsWide >= 4 ? 3 : 2
        spacing: Style.spacing.md
        Repeater {
          model: widget.ids
          delegate: Rectangle {
            id: tile
            required property string modelData
            readonly property var e: widget.reading && widget.reading.states[modelData]
              ? widget.reading.states[modelData] : { name: modelData, state: "…", unit: "" }
            readonly property bool on: e.state === "on"
            width: (grid.width - grid.spacing * (grid.columns - 1)) / grid.columns
            height: Math.max(44, columnView.implicitHeight + Style.spacing.md * 2)
            radius: Style.cornerRadius
            color: on ? Util.alpha(Commons.Color.accent, 0.2) : Util.alpha(widget.fg, 0.06)
            opacity: widget.pending[modelData] ? 0.6 : 1
            Column {
              id: columnView
              anchors.fill: parent
              anchors.margins: Style.spacing.md
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: tile.e.name
                color: widget.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: tile.e.state + (tile.e.unit ? " " + tile.e.unit : "")
                color: tile.on ? Commons.Color.accent : tile.e.state === "unreachable" ? Commons.Color.urgent : widget.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
            }
            MouseArea {
              anchors.fill: parent
              enabled: !widget.editing
              onClicked: widget.toggle(tile.modelData)
            }
          }
        }
      }
    }
  }
}
