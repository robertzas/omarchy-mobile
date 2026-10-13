// SPDX-License-Identifier: MIT
// Node tests for plugins/omandroid.home/HomeModel.js. Run by test/all.
"use strict"
const assert = require("assert")
const path = require("path")
const M = require(path.join(__dirname, "../plugins/omandroid.home/HomeModel.js"))

const tests = []
const test = (name, fn) => tests.push([name, fn])
const grid = { columns: 4, rows: 6 }
const app = (id, x, y, extra) => Object.assign({ id, kind: "app", app: id + ".app", x, y, w: 1, h: 1 }, extra || {})
const widget = (id, type, x, y, w, h) => ({ id, kind: "widget", type, x, y, w, h, config: {} })
const layoutOf = (...pages) => M.normalize({ grid, pages: pages.map((items) => ({ items })) })
const ids = (layout, page) => layout.pages[page].items.map((i) => i.id).sort()

// ---------------------------------------------------------------- placement

test("free spots are found in reading order", () => {
  const items = [widget("w1", "clock", 0, 0, 4, 2), app("a1", 0, 2)]
  assert.deepStrictEqual(M.freeSpot(items, grid, 1, 1), { x: 1, y: 2 })
  assert.deepStrictEqual(M.freeSpot(items, grid, 2, 2), { x: 1, y: 2 })
  assert.deepStrictEqual(M.freeSpot(items, grid, 4, 1), { x: 0, y: 3 })
  assert.strictEqual(M.freeSpot([widget("w", "notes", 0, 0, 4, 6)], grid, 1, 1), null)
})

test("overlap and fit", () => {
  assert.ok(M.overlaps({ x: 0, y: 0, w: 2, h: 2 }, { x: 1, y: 1, w: 1, h: 1 }))
  assert.ok(!M.overlaps({ x: 0, y: 0, w: 2, h: 2 }, { x: 2, y: 0, w: 1, h: 1 }))
  assert.ok(M.fits(grid, { x: 3, y: 5, w: 1, h: 1 }))
  assert.ok(!M.fits(grid, { x: 3, y: 5, w: 2, h: 1 }))
  assert.ok(!M.fits(grid, { x: -1, y: 0, w: 1, h: 1 }))
})

test("nearest free spot to a drop", () => {
  const items = [app("a1", 1, 1), app("a2", 2, 1)]
  assert.deepStrictEqual(M.nearestFreeSpot(items, grid, 1, 1, 1, 1, "x"), { x: 1, y: 0 })
  assert.deepStrictEqual(M.nearestFreeSpot(items, grid, 1, 1, 1, 1, "a1"), { x: 1, y: 1 })
})

test("a drag point maps to a cell on the grid", () => {
  assert.deepStrictEqual(M.cellForPoint(130, 160, 120, 150, 1, 1, grid), { x: 1, y: 1 })
  assert.deepStrictEqual(M.cellForPoint(-40, 9999, 120, 150, 2, 2, grid), { x: 0, y: 4 })
  assert.deepStrictEqual(M.cellForPoint(470, 0, 120, 150, 2, 1, grid), { x: 2, y: 0 })
  assert.strictEqual(M.pageShift(-0.7, 1, grid), -1)
  assert.strictEqual(M.pageShift(3.6, 1, grid), 1)
  assert.strictEqual(M.pageShift(2.9, 1, grid), 0)
})

// ---------------------------------------------------------------- persistence

test("the default layout uses only installed apps", () => {
  const l = M.defaultLayout(["foot.desktop", "chromium", "something-else"], grid)
  const apps = l.pages[0].items.filter((i) => i.kind === "app").map((i) => i.app)
  assert.deepStrictEqual(apps, ["chromium", "foot"])
  assert.strictEqual(l.pages.length, 2)
  assert.deepStrictEqual(M.parse(M.serialize(l)), l)
})

test("garbage reads as no layout", () => {
  for (const bad of ["", "{", "null", "[]", "{}", '{"pages": 3}'])
    assert.strictEqual(M.parse(bad), null, bad)
})

test("a stored layout round-trips", () => {
  const l = layoutOf([widget("w1", "clock", 0, 0, 4, 2), app("a2", 3, 5)], [widget("w3", "notes", 1, 1, 2, 2)])
  l.home = 1
  const again = M.parse(M.serialize(l))
  assert.deepStrictEqual(again, l)
  assert.strictEqual(again.home, 1)
  assert.strictEqual(again.pages[1].items[0].config.text, "")
})

test("serialize keeps only stored fields", () => {
  const l = M.addApp(layoutOf([]), 0, "foot")
  assert.ok(l.placed)
  const raw = JSON.parse(M.serialize(l))
  assert.strictEqual(raw.placed, undefined)
  assert.deepStrictEqual(Object.keys(raw.pages[0].items[0]).sort(), ["app", "h", "id", "kind", "w", "x", "y"])
})

test("normalize repairs what it can", () => {
  const l = M.normalize({
    grid: { columns: 99, rows: "x" },
    nextId: 2,
    home: 7,
    pages: [{ items: [
      widget("w1", "clock", 0, 0, 9, 9),            // too big: clamped to clock's max 4x3
      widget("w2", "nonsense", 0, 0, 1, 1),         // unknown type: dropped
      { kind: "app", app: "", x: 0, y: 0 },          // no app: dropped
      { kind: "app", app: "foot.desktop", x: 0, y: 0, id: "a9" }, // overlaps the clock: moved
      app("a9", 5, 5),                               // duplicate id: renumbered
      "junk", null
    ] }, { items: "nope" }]
  })
  assert.deepStrictEqual(l.grid, { columns: 6, rows: 6 })
  const clock = M.findItem(l, "w1").item
  assert.deepStrictEqual([clock.w, clock.h], [4, 3])
  assert.strictEqual(M.findItem(l, "w2"), null)
  const foot = l.pages[0].items.find((i) => i.app === "foot")
  assert.ok(foot && !M.overlaps(foot, clock))
  const idsSeen = l.pages[0].items.map((i) => i.id)
  assert.strictEqual(new Set(idsSeen).size, idsSeen.length)
  assert.ok(l.nextId > 9)
  assert.strictEqual(l.home, 1)
  assert.deepStrictEqual(l.pages[1].items, [])
})

test("widget config keeps known keys of the right type", () => {
  const c = M.mergeConfig(M.REGISTRY.weather.config, { enabled: "yes", place: "Oslo", latitude: 59.9, extra: 1 })
  assert.deepStrictEqual(c, { enabled: false, place: "Oslo", latitude: 59.9, longitude: null, units: "celsius" })
})

test("missing apps stay on the layout and are reported", () => {
  const l = layoutOf([app("gone", 0, 0), app("here", 1, 0)])
  assert.deepStrictEqual(M.missingApps(l, ["here.app.desktop"]), ["gone.app"])
  assert.strictEqual(l.pages[0].items.length, 2)
})

// ---------------------------------------------------------------- edits

test("adding fills the page, then the next, then a new page", () => {
  let l = layoutOf([widget("w1", "notes", 0, 0, 4, 5)], [widget("w2", "notes", 0, 0, 4, 6)])
  l = M.addApp(l, 0, "a")
  assert.deepStrictEqual(l.placed, { page: 0, x: 0, y: 5, id: l.placed.id })
  for (let i = 0; i < 3; i++) l = M.addApp(l, 0, "b" + i)
  l = M.addApp(l, 0, "c")
  assert.strictEqual(l.placed.page, 2)
  assert.strictEqual(l.pages.length, 3)
  l = M.addWidget(l, 1, "clock")
  assert.strictEqual(l.placed.page, 2)
  assert.strictEqual(M.addWidget(l, 0, "nope"), null)
})

test("adding does not change the argument", () => {
  const l = layoutOf([])
  const before = M.serialize(l)
  M.addWidget(l, 0, "battery")
  assert.strictEqual(M.serialize(l), before)
})

test("moves snap to the nearest free cell, or across pages", () => {
  let l = layoutOf([app("a1", 0, 0), app("a2", 1, 0)], [])
  l = M.moveItem(l, "a1", 0, 1, 0)               // onto a2: the two swap
  assert.ok(l.moved)
  assert.deepStrictEqual([M.findItem(l, "a1").item.x, M.findItem(l, "a2").item.x], [1, 0])
  let w = layoutOf([widget("w1", "notes", 0, 0, 2, 2), app("a1", 2, 0)])
  w = M.moveItem(w, "a1", 0, 1, 1)               // onto a bigger item: nearest free
  assert.deepStrictEqual([M.findItem(w, "a1").item.x, M.findItem(w, "a1").item.y], [2, 1])
  assert.ok(w.moved)
  const a1 = M.findItem(l, "a1").item
  l = M.moveItem(l, "a1", 1, 3, 5)
  assert.deepStrictEqual(M.findItem(l, "a1"), { page: 1, index: 0, item: Object.assign({}, a1, { x: 3, y: 5 }) })
  l = M.moveItem(l, "a1", 1, 99, -4)              // clamped to the grid
  assert.deepStrictEqual([M.findItem(l, "a1").item.x, M.findItem(l, "a1").item.y], [3, 0])
})

test("a move onto a full page is refused", () => {
  const full = []
  for (let y = 0; y < 6; y++) for (let x = 0; x < 4; x++) full.push(app("f" + x + y, x, y))
  const l = layoutOf([app("a1", 0, 0)], full)
  const out = M.moveItem(l, "a1", 1, 0, 0)
  assert.strictEqual(out.moved, false)
  assert.strictEqual(M.findItem(out, "a1").page, 0)
})

test("resizing respects the widget's limits, the grid and neighbours", () => {
  let l = layoutOf([widget("w1", "notes", 0, 0, 2, 2), app("a1", 3, 0)])
  l = M.resizeItem(l, "w1", 3, 3)
  assert.deepStrictEqual([M.findItem(l, "w1").item.w, M.findItem(l, "w1").item.h], [3, 3])
  const blocked = M.resizeItem(l, "w1", 4, 3)    // a1 is at (3, 0)
  assert.deepStrictEqual([M.findItem(blocked, "w1").item.w], [3])
  l = M.resizeItem(l, "w1", 0, 99)               // notes: min 1x1, max 4x6
  assert.deepStrictEqual([M.findItem(l, "w1").item.w, M.findItem(l, "w1").item.h], [1, 6])
  let c = layoutOf([widget("c", "clock", 0, 4, 4, 2)])
  c = M.resizeItem(c, "c", 1, 3)                 // clock: min 2x1, and only 2 rows left
  assert.deepStrictEqual([M.findItem(c, "c").item.w, M.findItem(c, "c").item.h], [2, 2])
  const a = layoutOf([app("a1", 0, 0)])
  assert.strictEqual(M.resizeItem(a, "a1", 2, 2), a)   // apps are 1x1
})

test("remove and config", () => {
  let l = layoutOf([widget("w1", "weather", 0, 0, 4, 1)])
  l = M.setConfig(l, "w1", { enabled: true, place: "Paris", latitude: 48.85, bogus: 1 })
  assert.deepStrictEqual(M.findItem(l, "w1").item.config,
    { enabled: true, place: "Paris", latitude: 48.85, longitude: null, units: "celsius" })
  l = M.removeItem(l, "w1")
  assert.deepStrictEqual(l.pages[0].items, [])
})

test("pages: add, remove, reorder, home follows", () => {
  let l = layoutOf([app("a", 0, 0)], [app("b", 0, 0)], [app("c", 0, 0)])
  l = M.setHome(l, 1)
  l = M.addPage(l, 0)
  assert.strictEqual(l.pages.length, 4)
  assert.strictEqual(l.home, 2)
  assert.deepStrictEqual(ids(l, 2), ["b"])
  l = M.movePage(l, 2, 3)
  assert.deepStrictEqual(ids(l, 3), ["b"])
  assert.strictEqual(l.home, 3)
  l = M.movePage(l, 1, 3)
  assert.deepStrictEqual(ids(l, 2), ["b"])
  assert.strictEqual(l.home, 2)
  l = M.removePage(l, 0)
  assert.strictEqual(l.home, 1)
  l = M.removePage(l, 1)
  assert.strictEqual(l.home, 1)
  assert.deepStrictEqual(ids(l, 0), ["c"])
  assert.deepStrictEqual(ids(l, 1), ["a"])
  const one = layoutOf([])
  assert.strictEqual(M.removePage(one, 0), one)
})

test("a smaller grid re-places what no longer fits", () => {
  const l = layoutOf([widget("w1", "notes", 0, 0, 4, 6), app("a1", 0, 0)])
  const small = M.setGrid(l, 3, 4)
  assert.deepStrictEqual(small.grid, { columns: 3, rows: 4 })
  const notes = M.findItem(small, "w1").item
  assert.deepStrictEqual([notes.w, notes.h], [3, 4])
  assert.strictEqual(M.findItem(small, "a1").page, 1)
})

// ---------------------------------------------------------------- widgets

test("weather requests carry only a rounded place", () => {
  assert.strictEqual(M.geocodeUrl(" São Paulo "),
    "https://geocoding-api.open-meteo.com/v1/search?count=1&format=json&name=S%C3%A3o%20Paulo")
  const u = M.forecastUrl(59.91273, 10.74609, "fahrenheit")
  assert.ok(u.startsWith("https://api.open-meteo.com/v1/forecast?latitude=59.91&longitude=10.75&"))
  assert.ok(u.endsWith("&temperature_unit=fahrenheit"))
  assert.ok(!M.forecastUrl(1, 2, "celsius").includes("fahrenheit"))
})

test("weather responses", () => {
  assert.deepStrictEqual(M.parseGeocode('{"results":[{"name":"Oslo","latitude":59.9,"longitude":10.7}]}'),
    { name: "Oslo", latitude: 59.9, longitude: 10.7 })
  assert.strictEqual(M.parseGeocode('{"generationtime_ms":0.1}'), null)
  assert.strictEqual(M.parseGeocode("<html>"), null)
  assert.deepStrictEqual(M.parseForecast(JSON.stringify({ current: { temperature_2m: 11.6, weather_code: 3 },
    daily: { temperature_2m_max: [14.2], temperature_2m_min: [6.5] } })), { temperature: 12, code: 3, high: 14, low: 7 })
  assert.strictEqual(M.parseForecast("{}"), null)
  assert.strictEqual(M.weatherText(0).text, "Clear")
  assert.strictEqual(M.weatherText(63).text, "Rain")
  assert.strictEqual(M.weatherText(1234).text, "")
})

test("agenda lines from khal", () => {
  const out = M.parseAgenda("2026-10-13\t09:30\tStand-up\n2026-10-14\t\tHoliday\tall day\n\nbroken line\n", 8)
  assert.deepStrictEqual(out, [{ date: "2026-10-13", time: "09:30", title: "Stand-up" },
                               { date: "2026-10-14", time: "", title: "Holiday all day" }])
  assert.strictEqual(M.parseAgenda("a\tb\tc\n".repeat(20), 5).length, 5)
})

test("month grid", () => {
  const cells = M.monthGrid(2026, 9, new Date(2026, 9, 13), 1) // October 2026, weeks from Monday
  assert.strictEqual(cells.length, 42)
  assert.deepStrictEqual(cells.slice(0, 4).map((c) => [c.day, c.inMonth]), [[28, false], [29, false], [30, false], [1, true]])
  assert.strictEqual(cells.filter((c) => c.today).length, 1)
  assert.strictEqual(cells.find((c) => c.today).day, 13)
})

test("command output", () => {
  assert.strictEqual(M.commandText("one\ntwo\nthree\n\n", 2), "one\ntwo")
  assert.strictEqual(M.commandText("", 3), "")
})

let failed = 0
for (const [name, fn] of tests) {
  try { fn(); console.log("ok - home model: " + name) } catch (e) { failed++; console.log("not ok - home model: " + name + "\n  " + (e.stack || e)) }
}
process.exit(failed ? 1 : 0)
