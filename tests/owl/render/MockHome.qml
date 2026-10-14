// SPDX-License-Identifier: MIT
import QtQuick
import qs.Commons
import qs.Commons as Commons
import "home/HomeModel.js" as HomeModel
import "home/UserWidgets.js" as UserWidgets
import "home/owl/catalog.js" as OwlCatalog
import "home/owl/phone.js" as OwlPhone

// What OwlCell and HomeSheets need from Home.qml, for the review
// screenshots: the same functions over a fixed widgets folder, fixtures in
// place of commands, and no files written. Nothing runs a widget's command.
Item {
  id: mock

  property var shot: null
  property var widgets: []          // [{ id, text, fixture }]
  property var approvals: ({})
  property real fixtureTime: 0

  // ---------- what Home.qml has
  readonly property color foreground: Commons.Color.menu.text
  readonly property color dimForeground: Util.alpha(Commons.Color.menu.text, 0.68)
  readonly property color cardColor: Util.alpha(Commons.Color.menu.background, 0.8)
  property string sheet: ""
  property string settingsId: ""
  property string owlApproveId: ""
  property string createMode: "create"
  property string createTarget: ""
  property string createText: ""
  property string createError: ""
  property bool helperBusy: false
  property bool editing: false
  readonly property var appLibrary: null
  readonly property bool owlEnabled: true
  readonly property string homeDir: "/home/you"
  readonly property string widgetsDir: "/home/you/.config/omamobile/widgets"
  // The page being shown, so "placed" reads right on the approval sheet.
  readonly property var layout: ({ grid: { columns: 4, rows: 6 }, home: 0, pages: [{ items: (mock.shot ? mock.shot.cells : []).map(function(c) {
    return { id: "w" + c.x + c.y, kind: "widget", type: "user:" + c.id, x: c.x, y: c.y, w: c.w, h: c.h, config: {} } }) }] })
  readonly property var userScan: UserWidgets.parseScan(JSON.stringify({
    dir: mock.widgetsDir,
    widgets: mock.widgets.map(function(w) { return { id: w.id, status: "ok", hash: "h-" + w.id, kind: "owl", owl: { text: w.text }, errors: [] } })
  }))
  readonly property real owlDp: OwlPhone.dpFor(480)
  readonly property real owlCellHeight: 908 / 6
  readonly property real owlScreenWidth: 480
  readonly property real owlScreenHeight: 924
  readonly property var owlInfo: {
    const out = {}
    mock.widgets.forEach(function(w) { out[w.id] = OwlCatalog.describe(w.id, w.text, { columns: 4, rows: 6 }, mock.owlCellHeight, mock.owlDp) })
    return out
  }
  readonly property var userCatalog: UserWidgets.catalog(mock.userScan, mock.owlSpecs)
  readonly property var owlSpecs: {
    const out = {}
    for (const id in mock.owlInfo) if (mock.owlInfo[id].ok) out[id] = mock.owlInfo[id].spec
    return out
  }
  function owlCard(widgetId) {
    const r = UserWidgets.findRecord(mock.userScan, widgetId)
    const info = mock.owlInfo[widgetId] || null
    const approval = mock.approvals[widgetId] || null
    const card = OwlCatalog.cardState(true, true, r, info, approval, "")
    card.record = r
    card.info = info
    card.approval = approval
    return card
  }
  function owlActive() { return true }
  function argbOf(c) {
    return ((Math.round(c.a * 255) << 24) | (Math.round(c.r * 255) << 16) | (Math.round(c.g * 255) << 8) | Math.round(c.b * 255)) >>> 0
  }
  property var themeColors: ({})
  readonly property var owlPalette: OwlPhone.cardPalette(OwlPhone.palette(mock.themeColors), {
    foreground: mock.argbOf(mock.foreground), dimForeground: mock.argbOf(mock.dimForeground), background: mock.argbOf(Commons.Color.menu.background),
    border: mock.argbOf(Commons.Color.menu.border), accent: mock.argbOf(Commons.Color.accent), urgent: mock.argbOf(Commons.Color.urgent)
  })
  readonly property var owlInk: {
    const out = {}
    for (const k in mock.owlPalette) {
      const s = (mock.owlPalette[k] >>> 0).toString(16)
      out[k] = "#" + "00000000".slice(s.length) + s
    }
    return out
  }

  // Sources answer from each widget's fixture; actions do nothing.
  readonly property var owlHost: ({
    now: function() { return mock.fixtureTime },
    interval: function(spec) { return spec.every },
    runSource: function(widget, spec, arg, headers, done) {
      const w = mock.widgets.filter(function(x) { return widget.stateKey.indexOf(x.id + "@") === 0 })[0]
      const e = w && w.fixture ? w.fixture.sources[spec.name] : null
      if (!e) { done({ error: "no fixture" }); return }
      if (e.value !== undefined) done({ value: e.value })
      else done({ code: 0, ok: true, out: e.text, err: "" })
    },
    android: function(widget, kind, done) { done({ value: null }) },
    act: function() {}, runInto: function() {},
    loadState: function() { return {} }, saveState: function() {},
    report: function(widget, message) { console.log("owl report " + widget.stateKey + ": " + message) }
  })
  readonly property var owlScheduler: ({
    add: function() {}, remove: function() {},
    // One frame at the fixture's time, so a drawing that reads `time` shows it.
    setAnimating: function(client, on) { if (on) client.frame(mock.fixtureTime % 3600 + 0.5) }
  })

  function guardBegin() {}
  function guardEnd() {}
  function openOwlApproval(id) { mock.owlApproveId = id; mock.sheet = "owl-approve" }
  function openCreate() {}
  function addWidgetHere() { return "" }
  function approveOwl() { return "approved" }
  function removeUserWidget() {}
  function openSettings() {}
  function setEditing(on) { mock.editing = on }
  function flash() {}
}
