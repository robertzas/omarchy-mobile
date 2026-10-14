// SPDX-License-Identifier: MIT
import QtQuick
import qs.Commons
import qs.Commons as Commons

// What the home screen's QML widgets read from Home.qml, for drawing the
// layout as it was before the OWL built-ins (the ports, from main).
Item {
  readonly property color foreground: Commons.Color.menu.text
  readonly property color dimForeground: Util.alpha(Commons.Color.menu.text, 0.68)
  readonly property color cardColor: Util.alpha(Commons.Color.menu.background, 0.8)
  readonly property string systemTimeFormat: "HH:mm"
  property var cache: ({})
  function widgetCache(id) { return cache[id] || null }
  function setWidgetCache(id, v) { cache[id] = v }
  function setConfig() {}
  function openSettings() {}
}
