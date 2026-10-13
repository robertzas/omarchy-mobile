// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "HomeModel.js" as HomeModel

// Current weather from Open-Meteo (open-meteo.com: free, no key, no
// account). Off until the user turns it on in the widget's settings and
// names a place; then it asks for that place's forecast every 30 minutes,
// sending only coordinates rounded to about 1 km. Nothing else leaves the
// phone, and with the widget off it makes no request at all.
Item {
  id: widget

  property var home: null
  property var entry: null
  property bool editing: false
  readonly property var config: entry && entry.config ? entry.config : ({})
  readonly property bool configured: config.enabled === true && typeof config.latitude === "number" && typeof config.longitude === "number"

  readonly property color fg: home ? home.foreground : "white"
  readonly property color dim: home ? home.dimForeground : "white"

  // The last answer survives the widget being rebuilt (every layout edit
  // does that), so an edit is not a new request.
  readonly property var cached: home && entry ? home.widgetCache(entry.id) : null
  property var forecast: cached && cached.key === requestKey ? cached.data : null
  property string failure: ""
  readonly property string requestKey: configured ? [config.latitude, config.longitude, config.units].join(",") : ""

  function refresh(force) {
    if (!configured) return
    var c = home ? home.widgetCache(entry.id) : null
    if (!force && c && c.key === requestKey && Date.now() - c.at < 30 * 60 * 1000) { forecast = c.data; return }
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      var parsed = xhr.status === 200 ? HomeModel.parseForecast(xhr.responseText) : null
      if (!parsed) { widget.failure = "Weather unavailable"; return }
      widget.failure = ""
      widget.forecast = parsed
      if (widget.home) widget.home.setWidgetCache(widget.entry.id, { key: widget.requestKey, at: Date.now(), data: parsed })
    }
    xhr.open("GET", HomeModel.forecastUrl(config.latitude, config.longitude, config.units))
    xhr.send()
  }

  onRequestKeyChanged: refresh(false)
  Component.onCompleted: refresh(false)

  Timer {
    interval: 30 * 60 * 1000
    repeat: true
    running: widget.configured
    onTriggered: widget.refresh(true)
  }

  readonly property var look: forecast ? HomeModel.weatherText(forecast.code) : ({ icon: "󰖐", text: "" })
  readonly property string unit: config.units === "fahrenheit" ? "°F" : "°C"

  // Not set up: say what it would do and open the settings.
  Column {
    anchors.centerIn: parent
    width: widget.width - Style.spacing.xxl * 2
    visible: !widget.configured
    spacing: Style.spacing.xs

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: "󰖐  Weather is off"
      color: widget.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.title
    }
    Text {
      width: parent.width
      visible: widget.height > 90
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: "Tap to choose a place. Uses open-meteo.com."
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      wrapMode: Text.Wrap
    }
  }

  Row {
    anchors.centerIn: parent
    visible: widget.configured
    spacing: Style.spacing.xl

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: widget.look.icon
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Math.min(widget.height * 0.55, Style.font.displayLarge * 1.6)
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs

      Text {
        textFormat: Text.PlainText
        text: widget.forecast ? widget.forecast.temperature + widget.unit : (widget.failure || "…")
        color: widget.fg
        font.family: Style.font.family
        font.pixelSize: widget.forecast ? Style.font.displayLarge : Style.font.body
      }
      Text {
        textFormat: Text.PlainText
        visible: !!widget.forecast
        text: widget.forecast ? [widget.config.place, widget.look.text,
          widget.forecast.high !== null ? "↑" + widget.forecast.high + "° ↓" + widget.forecast.low + "°" : ""]
          .filter(function(s) { return !!s }).join(" · ") : ""
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: Math.min(implicitWidth, widget.width - Style.space(90))
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: {
      if (!widget.configured && widget.home) widget.home.openSettings(widget.entry.id)
      else widget.refresh(true)
    }
  }
}
