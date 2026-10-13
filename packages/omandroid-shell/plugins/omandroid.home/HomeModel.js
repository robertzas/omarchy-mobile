// SPDX-License-Identifier: MIT
// Pure logic for omandroid.home: the layout format, the widget registry, grid
// placement and the edits made in edit mode. Node runs it in
// test/home-model.js through the module.exports at the end, so nothing here
// touches QML.
//
// The layout, as stored in ~/.config/omandroid/home.json:
//
//   { "version": 1,
//     "grid": { "columns": 4, "rows": 6 },
//     "home": 0,                       // the page Home returns to
//     "nextId": 7,
//     "pages": [ { "items": [
//       { "id": "w1", "kind": "widget", "type": "clock", "x": 0, "y": 0, "w": 4, "h": 2, "config": {} },
//       { "id": "a2", "kind": "app", "app": "chromium", "x": 0, "y": 5, "w": 1, "h": 1 } ] } ] }
//
// x and y are grid cells from the top-left, w and h spans. Every function
// that changes a layout returns a new one and leaves its argument alone.

var VERSION = 1
var GRID = { columns: 4, rows: 6 }
var LIMITS = { minColumns: 3, maxColumns: 6, minRows: 4, maxRows: 8, maxPages: 12 }

// Widget types. min/max/size are in cells; `network` widgets reach the
// internet and stay off until the user turns them on in their settings.
var REGISTRY = {
  clock:   { name: "Clock",          icon: "󰥔", min: [2, 1], max: [4, 3], size: [4, 2], network: false,
             config: { timeFormat: "HH:mm", dateFormat: "dddd d MMMM" } },
  weather: { name: "Weather",        icon: "󰖐", min: [2, 1], max: [4, 2], size: [4, 1], network: true,
             config: { enabled: false, place: "", latitude: null, longitude: null, units: "celsius" } },
  battery: { name: "Battery",        icon: "󰁹", min: [1, 1], max: [4, 2], size: [2, 1], network: false, config: {} },
  media:   { name: "Media",          icon: "󰝚", min: [3, 1], max: [4, 2], size: [4, 1], network: false, config: {} },
  agenda:  { name: "Calendar",       icon: "󰃭", min: [2, 2], max: [4, 4], size: [4, 3], network: false, config: {} },
  notes:   { name: "Note",           icon: "󰎚", min: [1, 1], max: [4, 6], size: [2, 2], network: false, config: { text: "" } },
  toggles: { name: "Quick toggles",  icon: "󰔡", min: [2, 1], max: [4, 2], size: [4, 1], network: false, config: {} },
  command: { name: "Text or command", icon: "󰆍", min: [1, 1], max: [4, 6], size: [2, 1], network: false,
             config: { title: "", text: "", command: "", interval: 300, tap: "" } }
}

var WIDGET_ORDER = ["clock", "weather", "battery", "media", "agenda", "notes", "toggles", "command"]

// What a fresh home gets, before the user changes anything: a clock and the
// first of these apps that are installed along the bottom row.
var DEFAULT_APPS = ["chromium", "Alacritty", "org.gnome.Nautilus", "omarchy-menu", "org.omarchy.settings",
                    "foot", "org.gnome.Calculator", "btop", "nvim", "localsend"]

function clampInt(value, lo, hi, fallback) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) n = fallback
  return Math.max(lo, Math.min(hi, n))
}

function copy(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value))
}

function widgetSpec(type) {
  return Object.prototype.hasOwnProperty.call(REGISTRY, type) ? REGISTRY[type] : null
}

function widgetTypes() {
  return WIDGET_ORDER.map(function(type) {
    var spec = REGISTRY[type]
    return { type: type, name: spec.name, icon: spec.icon, network: spec.network, w: spec.size[0], h: spec.size[1] }
  })
}

// The span limits of an item on a given grid.
function sizeLimits(item, grid) {
  if (!item || item.kind !== "widget") return { minW: 1, minH: 1, maxW: 1, maxH: 1 }
  var spec = widgetSpec(item.type)
  return {
    minW: Math.min(spec.min[0], grid.columns), minH: Math.min(spec.min[1], grid.rows),
    maxW: Math.min(spec.max[0], grid.columns), maxH: Math.min(spec.max[1], grid.rows)
  }
}

// ---------------------------------------------------------------- geometry

function overlaps(a, b) {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

function fits(grid, rect) {
  return rect.x >= 0 && rect.y >= 0 && rect.w >= 1 && rect.h >= 1
    && rect.x + rect.w <= grid.columns && rect.y + rect.h <= grid.rows
}

// The item that rect would overlap on this list, skipping ignoreId.
function collision(items, rect, ignoreId) {
  for (var i = 0; i < items.length; i++) {
    if (items[i].id === ignoreId) continue
    if (overlaps(items[i], rect)) return items[i]
  }
  return null
}

function isFree(items, grid, rect, ignoreId) {
  return fits(grid, rect) && !collision(items, rect, ignoreId)
}

// The first free w x h spot in reading order, or null.
function freeSpot(items, grid, w, h) {
  for (var y = 0; y + h <= grid.rows; y++)
    for (var x = 0; x + w <= grid.columns; x++)
      if (isFree(items, grid, { x: x, y: y, w: w, h: h }, null)) return { x: x, y: y }
  return null
}

// A free spot as close as possible to (x, y), for a drop that lands on
// another item. Nearest by cell distance, reading order on ties.
function nearestFreeSpot(items, grid, x, y, w, h, ignoreId) {
  var best = null, bestDistance = Infinity
  for (var cy = 0; cy + h <= grid.rows; cy++) {
    for (var cx = 0; cx + w <= grid.columns; cx++) {
      if (!isFree(items, grid, { x: cx, y: cy, w: w, h: h }, ignoreId)) continue
      var d = Math.abs(cx - x) + Math.abs(cy - y)
      if (d < bestDistance) { best = { x: cx, y: cy }; bestDistance = d }
    }
  }
  return best
}

// The top-left cell under an item dragged so its top-left corner sits at
// (px, py) in a page of cellWidth x cellHeight cells: rounded to the nearest
// cell and kept on the grid.
function cellForPoint(px, py, cellWidth, cellHeight, w, h, grid) {
  return {
    x: clampInt(px / cellWidth, 0, grid.columns - w, 0),
    y: clampInt(py / cellHeight, 0, grid.rows - h, 0)
  }
}

// A drag that ends this far past a page edge (in cells) moves the item to
// the neighbouring page: -1 left, +1 right, 0 stay.
function pageShift(px, w, grid) {
  if (px < -0.5) return -1
  if (px + w > grid.columns + 0.5) return 1
  return 0
}

// ---------------------------------------------------------------- the layout

function emptyLayout(grid) {
  return { version: VERSION, grid: { columns: grid.columns, rows: grid.rows }, home: 0, nextId: 1, pages: [{ items: [] }] }
}

function takeId(layout, prefix) {
  var id = prefix + layout.nextId
  layout.nextId += 1
  return id
}

// availableApps: desktop ids that exist now (without ".desktop").
function defaultLayout(availableApps, grid) {
  grid = grid || GRID
  var layout = emptyLayout(grid)
  var have = {}
  ;(availableApps || []).forEach(function(id) { have[normalizeAppId(id)] = true })
  var clock = REGISTRY.clock
  layout.pages[0].items.push({ id: takeId(layout, "w"), kind: "widget", type: "clock",
                               x: 0, y: 0, w: Math.min(clock.size[0], grid.columns), h: clock.size[1],
                               config: copy(clock.config) })
  var x = 0
  for (var i = 0; i < DEFAULT_APPS.length && x < grid.columns; i++) {
    if (!have[DEFAULT_APPS[i]]) continue
    layout.pages[0].items.push({ id: takeId(layout, "a"), kind: "app", app: DEFAULT_APPS[i],
                                 x: x, y: grid.rows - 1, w: 1, h: 1 })
    x += 1
  }
  layout.pages.push({ items: [] })
  var battery = REGISTRY.battery, media = REGISTRY.media
  layout.pages[1].items.push({ id: takeId(layout, "w"), kind: "widget", type: "media", x: 0, y: 0,
                               w: Math.min(media.size[0], grid.columns), h: media.size[1], config: {} })
  layout.pages[1].items.push({ id: takeId(layout, "w"), kind: "widget", type: "battery", x: 0, y: media.size[1],
                               w: battery.size[0], h: battery.size[1], config: {} })
  return layout
}

function normalizeAppId(id) {
  var value = String(id || "").trim()
  if (value.slice(-8) === ".desktop") value = value.slice(0, -8)
  return value
}

// Anything read from disk goes through here: unknown or broken items are
// dropped, sizes are clamped to the widget's limits and the grid, and items
// that no longer fit or overlap move to the first free spot (on a later page
// if need be). Apps that aren't installed stay: they may come back (and the
// user sees them, dimmed, to remove them). Returns null for input that isn't
// a layout at all, so the caller can fall back to the default.
function normalize(raw) {
  if (!raw || typeof raw !== "object" || !Array.isArray(raw.pages)) return null
  var rawGrid = raw.grid && typeof raw.grid === "object" ? raw.grid : {}
  var grid = {
    columns: clampInt(rawGrid.columns, LIMITS.minColumns, LIMITS.maxColumns, GRID.columns),
    rows: clampInt(rawGrid.rows, LIMITS.minRows, LIMITS.maxRows, GRID.rows)
  }
  var layout = emptyLayout(grid)
  layout.pages = []
  layout.nextId = clampInt(raw.nextId, 1, 1e9, 1)
  var seen = {}
  var homeless = []

  var pages = raw.pages.slice(0, LIMITS.maxPages)
  for (var p = 0; p < pages.length; p++) {
    var page = { items: [] }
    layout.pages.push(page)
    var items = pages[p] && Array.isArray(pages[p].items) ? pages[p].items : []
    for (var i = 0; i < items.length; i++) {
      var item = cleanItem(items[i], grid)
      if (!item) continue
      if (!item.id || seen[item.id]) item.id = takeId(layout, item.kind === "app" ? "a" : "w")
      seen[item.id] = true
      if (isFree(page.items, grid, item, null)) page.items.push(item)
      else homeless.push({ page: p, item: item })
    }
  }
  if (layout.pages.length === 0) layout.pages.push({ items: [] })

  // Keep generated ids clear of the ones on disk.
  Object.keys(seen).forEach(function(id) {
    var n = parseInt(id.slice(1), 10)
    if (isFinite(n) && n >= layout.nextId) layout.nextId = n + 1
  })

  for (var h = 0; h < homeless.length; h++)
    layout = placeOn(layout, homeless[h].page, homeless[h].item)

  layout.home = clampInt(raw.home, 0, layout.pages.length - 1, 0)
  return layout
}

function cleanItem(raw, grid) {
  if (!raw || typeof raw !== "object") return null
  var item = { id: typeof raw.id === "string" ? raw.id : "", kind: raw.kind }
  if (raw.kind === "app") {
    item.app = normalizeAppId(raw.app)
    if (!item.app) return null
    item.w = 1; item.h = 1
  } else if (raw.kind === "widget") {
    var spec = widgetSpec(raw.type)
    if (!spec) return null
    item.type = raw.type
    var limits = sizeLimits(item, grid)
    item.w = clampInt(raw.w, limits.minW, limits.maxW, spec.size[0])
    item.h = clampInt(raw.h, limits.minH, limits.maxH, spec.size[1])
    item.config = mergeConfig(spec.config, raw.config)
  } else {
    return null
  }
  item.x = clampInt(raw.x, 0, grid.columns - item.w, 0)
  item.y = clampInt(raw.y, 0, grid.rows - item.h, 0)
  return item
}

// The widget's defaults, overlaid with stored values of the same type.
function mergeConfig(defaults, stored) {
  var out = copy(defaults) || {}
  if (!stored || typeof stored !== "object") return out
  Object.keys(out).forEach(function(key) {
    var value = stored[key]
    if (value === undefined) return
    if (out[key] === null) {
      if (value === null || typeof value === "number") out[key] = value
    } else if (typeof value === typeof out[key]) {
      out[key] = value
    }
  })
  return out
}

// Only the stored fields: edits leave notes such as `placed` on the
// objects they return, and those don't belong in the file.
function serialize(layout) {
  var out = { version: VERSION, grid: { columns: layout.grid.columns, rows: layout.grid.rows },
              home: layout.home, nextId: layout.nextId, pages: layout.pages.map(function(page) {
                return { items: page.items.map(function(item) {
                  var o = { id: item.id, kind: item.kind }
                  if (item.kind === "app") o.app = item.app
                  else { o.type = item.type }
                  o.x = item.x; o.y = item.y; o.w = item.w; o.h = item.h
                  if (item.kind === "widget") o.config = item.config
                  return o
                }) }
              }) }
  return JSON.stringify(out, null, 2) + "\n"
}

// Parse a file's text; null when it isn't a usable layout.
function parse(text) {
  var raw
  try { raw = JSON.parse(String(text || "")) } catch (e) { return null }
  return normalize(raw)
}

// ---------------------------------------------------------------- lookups

function findItem(layout, id) {
  for (var p = 0; p < layout.pages.length; p++) {
    var items = layout.pages[p].items
    for (var i = 0; i < items.length; i++)
      if (items[i].id === id) return { page: p, index: i, item: items[i] }
  }
  return null
}

// Apps on the home screen whose desktop entries are gone.
function missingApps(layout, availableApps) {
  var have = {}
  ;(availableApps || []).forEach(function(id) { have[normalizeAppId(id)] = true })
  var out = []
  layout.pages.forEach(function(page) {
    page.items.forEach(function(item) { if (item.kind === "app" && !have[item.app]) out.push(item.app) })
  })
  return out
}

// ---------------------------------------------------------------- edits

// Put an item (any x/y) on page `pageIndex`: where it says if that's free,
// else the first free spot there, else on the next page with room, else on
// a new page at the end. Returns the new layout; result.placed tells where.
function placeOn(layout, pageIndex, item) {
  var out = copy(layout)
  var it = copy(item)
  var start = clampInt(pageIndex, 0, out.pages.length - 1, 0)
  if (fits(out.grid, it) && isFree(out.pages[start].items, out.grid, it, null)) {
    out.pages[start].items.push(it)
    out.placed = { page: start, x: it.x, y: it.y }
    return out
  }
  for (var n = 0; n < out.pages.length; n++) {
    var p = (start + n) % out.pages.length
    if (n > 0 && p < start) break // only forward, then a new page
    var spot = freeSpot(out.pages[p].items, out.grid, it.w, it.h)
    if (spot) {
      it.x = spot.x; it.y = spot.y
      out.pages[p].items.push(it)
      out.placed = { page: p, x: it.x, y: it.y }
      return out
    }
  }
  if (out.pages.length >= LIMITS.maxPages) { out.placed = null; return out }
  it.x = 0; it.y = 0
  out.pages.push({ items: [it] })
  out.placed = { page: out.pages.length - 1, x: 0, y: 0 }
  return out
}

function addWidget(layout, pageIndex, type) {
  var spec = widgetSpec(type)
  if (!spec) return null
  var out = copy(layout)
  var item = { id: takeId(out, "w"), kind: "widget", type: type, x: -1, y: -1,
               w: Math.min(spec.size[0], out.grid.columns), h: Math.min(spec.size[1], out.grid.rows),
               config: copy(spec.config) }
  out = placeOn(out, pageIndex, item)
  if (out.placed) out.placed.id = item.id
  return out
}

function addApp(layout, pageIndex, appId) {
  var app = normalizeAppId(appId)
  if (!app) return null
  var out = copy(layout)
  var item = { id: takeId(out, "a"), kind: "app", app: app, x: -1, y: -1, w: 1, h: 1 }
  out = placeOn(out, pageIndex, item)
  if (out.placed) out.placed.id = item.id
  return out
}

function removeItem(layout, id) {
  var found = findItem(layout, id)
  if (!found) return layout
  var out = copy(layout)
  out.pages[found.page].items.splice(found.index, 1)
  return out
}

// Move to (x, y) on page `pageIndex` (the same page or another). A spot that
// is taken or off the grid snaps to the nearest free one; with none free on
// that page the layout comes back unchanged. result.moved says if it moved.
function moveItem(layout, id, pageIndex, x, y) {
  var found = findItem(layout, id)
  if (!found) return layout
  var out = copy(layout)
  var page = clampInt(pageIndex, 0, out.pages.length - 1, found.page)
  var item = out.pages[found.page].items.splice(found.index, 1)[0]
  var rect = { x: clampInt(x, 0, out.grid.columns - item.w, 0), y: clampInt(y, 0, out.grid.rows - item.h, 0), w: item.w, h: item.h }
  // Dropped squarely onto an item of the same size on the same page: swap
  // the two, as app icons do on Android.
  var other = collision(out.pages[page].items, rect, id)
  if (other && page === found.page && other.w === item.w && other.h === item.h
      && other.x === rect.x && other.y === rect.y) {
    other.x = found.item.x; other.y = found.item.y
    item.x = rect.x; item.y = rect.y
    out.pages[page].items.push(item)
    out.moved = true
    return out
  }
  var spot = !other && fits(out.grid, rect) ? rect
    : nearestFreeSpot(out.pages[page].items, out.grid, rect.x, rect.y, item.w, item.h, id)
  if (!spot) { var same = copy(layout); same.moved = false; return same }
  item.x = spot.x; item.y = spot.y
  out.pages[page].items.push(item)
  out.moved = page !== found.page || spot.x !== found.item.x || spot.y !== found.item.y
  return out
}

// Resize a widget to w x h cells, clamped to its limits and the grid edge.
// A size that would overlap another item is refused (layout unchanged).
function resizeItem(layout, id, w, h) {
  var found = findItem(layout, id)
  if (!found || found.item.kind !== "widget") return layout
  var limits = sizeLimits(found.item, layout.grid)
  var rect = { x: found.item.x, y: found.item.y,
               w: clampInt(w, limits.minW, Math.min(limits.maxW, layout.grid.columns - found.item.x), found.item.w),
               h: clampInt(h, limits.minH, Math.min(limits.maxH, layout.grid.rows - found.item.y), found.item.h) }
  if (collision(layout.pages[found.page].items, rect, id)) return layout
  var out = copy(layout)
  out.pages[found.page].items[found.index].w = rect.w
  out.pages[found.page].items[found.index].h = rect.h
  return out
}

function setConfig(layout, id, patch) {
  var found = findItem(layout, id)
  if (!found || found.item.kind !== "widget") return layout
  var out = copy(layout)
  var target = out.pages[found.page].items[found.index]
  var merged = copy(target.config)
  Object.keys(patch || {}).forEach(function(key) { merged[key] = patch[key] })
  target.config = mergeConfig(REGISTRY[target.type].config, merged)
  return out
}

function addPage(layout, at) {
  if (layout.pages.length >= LIMITS.maxPages) return layout
  var out = copy(layout)
  var index = clampInt(at === undefined ? out.pages.length : at, 0, out.pages.length, out.pages.length)
  out.pages.splice(index, 0, { items: [] })
  if (index <= layout.home) out.home += 1
  return out
}

// Removing a page removes what is on it; the last page stays.
function removePage(layout, index) {
  if (layout.pages.length <= 1 || index < 0 || index >= layout.pages.length) return layout
  var out = copy(layout)
  out.pages.splice(index, 1)
  if (out.home > index) out.home -= 1
  else if (out.home === index) out.home = Math.min(index, out.pages.length - 1)
  return out
}

function movePage(layout, from, to) {
  var n = layout.pages.length
  if (from < 0 || from >= n || to < 0 || to >= n || from === to) return layout
  var out = copy(layout)
  var page = out.pages.splice(from, 1)[0]
  out.pages.splice(to, 0, page)
  // The home page follows its page.
  var order = []
  for (var i = 0; i < n; i++) order.push(i)
  order.splice(to, 0, order.splice(from, 1)[0])
  out.home = order.indexOf(layout.home)
  return out
}

function setHome(layout, index) {
  if (index < 0 || index >= layout.pages.length) return layout
  var out = copy(layout)
  out.home = index
  return out
}

// Change the grid; everything is re-placed through normalize().
function setGrid(layout, columns, rows) {
  var raw = copy(layout)
  raw.grid = { columns: columns, rows: rows }
  return normalize(raw)
}

// ---------------------------------------------------------------- widgets' pure parts

// Open-Meteo's WMO weather codes -> a glyph and words.
function weatherText(code) {
  var c = Number(code)
  if (c === 0) return { icon: "󰖙", text: "Clear" }
  if (c === 1 || c === 2) return { icon: "󰖕", text: c === 1 ? "Mostly clear" : "Partly cloudy" }
  if (c === 3) return { icon: "󰖐", text: "Overcast" }
  if (c === 45 || c === 48) return { icon: "󰖑", text: "Fog" }
  if (c >= 51 && c <= 57) return { icon: "󰖗", text: "Drizzle" }
  if ((c >= 61 && c <= 67) || (c >= 80 && c <= 82)) return { icon: "󰖖", text: "Rain" }
  if ((c >= 71 && c <= 77) || c === 85 || c === 86) return { icon: "󰖘", text: "Snow" }
  if (c >= 95 && c <= 99) return { icon: "󰖓", text: "Thunderstorm" }
  return { icon: "󰖐", text: "" }
}

// The two requests the weather widget makes, and only once it is turned on.
// Coordinates are rounded to 0.01° (about 1 km), which is all a forecast
// needs and all the service sees.
function geocodeUrl(place) {
  return "https://geocoding-api.open-meteo.com/v1/search?count=1&format=json&name=" + encodeURIComponent(String(place || "").trim())
}

function forecastUrl(latitude, longitude, units) {
  var lat = Math.round(Number(latitude) * 100) / 100
  var lon = Math.round(Number(longitude) * 100) / 100
  return "https://api.open-meteo.com/v1/forecast?latitude=" + lat + "&longitude=" + lon
    + "&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=auto"
    + (units === "fahrenheit" ? "&temperature_unit=fahrenheit" : "")
}

function parseGeocode(text) {
  var data
  try { data = JSON.parse(text) } catch (e) { return null }
  var r = data && Array.isArray(data.results) ? data.results[0] : null
  if (!r || typeof r.latitude !== "number" || typeof r.longitude !== "number") return null
  return { name: String(r.name || ""), latitude: r.latitude, longitude: r.longitude }
}

function parseForecast(text) {
  var data
  try { data = JSON.parse(text) } catch (e) { return null }
  var cur = data && data.current
  if (!cur || typeof cur.temperature_2m !== "number") return null
  var daily = data.daily || {}
  return {
    temperature: Math.round(cur.temperature_2m),
    code: cur.weather_code,
    high: daily.temperature_2m_max ? Math.round(daily.temperature_2m_max[0]) : null,
    low: daily.temperature_2m_min ? Math.round(daily.temperature_2m_min[0]) : null
  }
}

// The agenda widget runs
//   khal list --day-format "" --format "{start-date}\t{start-time}\t{title}" today 7d
// (khal is the local calendar Omarchy users sync with vdirsyncer): one event
// per line, all-day events with an empty time.
var AGENDA_ARGV = ["khal", "list", "--day-format", "", "--format", "{start-date}\t{start-time}\t{title}", "today", "7d"]

function parseAgenda(text, limit) {
  var out = []
  String(text || "").split("\n").forEach(function(line) {
    if (!line.trim()) return
    var f = line.split("\t")
    if (f.length < 3) return
    out.push({ date: f[0].trim(), time: f[1].trim(), title: f.slice(2).join(" ").trim() })
  })
  return out.slice(0, limit || 8)
}

// A month grid for the calendar widget: 6 weeks of { day, inMonth, today },
// weeks starting on `firstDay` (0 Sunday, 1 Monday).
function monthGrid(year, month, today, firstDay) {
  var first = new Date(year, month, 1)
  var offset = (first.getDay() - (firstDay || 0) + 7) % 7
  var cells = []
  for (var i = 0; i < 42; i++) {
    var d = new Date(year, month, 1 - offset + i)
    cells.push({ day: d.getDate(), inMonth: d.getMonth() === month,
                 today: !!today && d.getFullYear() === today.getFullYear() && d.getMonth() === today.getMonth() && d.getDate() === today.getDate() })
  }
  return cells
}

// The text/command widget: what to show from a command's output.
function commandText(output, maxLines) {
  var lines = String(output || "").replace(/\s+$/, "").split("\n")
  return lines.slice(0, Math.max(1, maxLines || 1)).join("\n")
}

if (typeof module !== "undefined") {
  module.exports = {
    VERSION: VERSION, GRID: GRID, LIMITS: LIMITS, REGISTRY: REGISTRY, DEFAULT_APPS: DEFAULT_APPS,
    widgetSpec: widgetSpec, widgetTypes: widgetTypes, sizeLimits: sizeLimits,
    overlaps: overlaps, fits: fits, collision: collision, isFree: isFree, freeSpot: freeSpot,
    nearestFreeSpot: nearestFreeSpot, cellForPoint: cellForPoint, pageShift: pageShift,
    emptyLayout: emptyLayout, defaultLayout: defaultLayout, normalizeAppId: normalizeAppId,
    normalize: normalize, serialize: serialize, parse: parse, mergeConfig: mergeConfig,
    findItem: findItem, missingApps: missingApps,
    placeOn: placeOn, addWidget: addWidget, addApp: addApp, removeItem: removeItem,
    moveItem: moveItem, resizeItem: resizeItem, setConfig: setConfig,
    addPage: addPage, removePage: removePage, movePage: movePage, setHome: setHome, setGrid: setGrid,
    weatherText: weatherText, geocodeUrl: geocodeUrl, forecastUrl: forecastUrl,
    parseGeocode: parseGeocode, parseForecast: parseForecast, parseAgenda: parseAgenda, AGENDA_ARGV: AGENDA_ARGV,
    monthGrid: monthGrid, commandText: commandText
  }
}
