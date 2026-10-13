// SPDX-License-Identifier: MIT
// wttr.in helpers shared by the weather examples. weatherIcon follows the
// OWL runtime's builtin of the same name (omarchy-widgets, MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).

// A city for wttr.in's path: "/", "?", "&" or "#" can't break the URL.
// Empty means located by IP.
function encodeCity(city) {
  return encodeURIComponent(String(city || "").trim()).replace(/%20/g, "+")
}

function url(city) {
  return "https://wttr.in/" + encodeCity(city) + "?format=j1"
}

function value(list) {
  return list && list[0] ? String(list[0].value || "") : ""
}

// Fahrenheit where omarchy's weather panel uses it.
function imperial(area) {
  var c = value(area ? area.country : null).trim().toLowerCase()
  return ["united states", "united states of america", "liberia", "myanmar", "burma"].indexOf(c) >= 0
}

// Nerd Font weather glyphs by wttr.in weather code.
function weatherIcon(code, night) {
  switch (Number(code)) {
  case 113: return night ? "" : ""
  case 116: return night ? "" : ""
  case 143: case 248: case 260: return night ? "" : ""
  case 176: case 263: case 353: return night ? "" : ""
  case 179: case 227: case 230: case 323: case 326: case 368: return night ? "" : ""
  case 182: case 185: case 281: case 284: case 311: case 314: case 317: case 320: case 350: case 362:
  case 365: case 374: case 377: return ""
  case 200: case 386: case 389: case 392: case 395: return ""
  case 266: case 293: case 296: case 299: case 302: case 305: case 308: case 356: case 359: return ""
  case 329: case 332: case 335: case 338: case 371: return ""
  default: return ""
  }
}

var moonIcons = {
  "New Moon": "", "Waxing Crescent": "", "First Quarter": "", "Waxing Gibbous": "",
  "Full Moon": "", "Waning Gibbous": "", "Last Quarter": "", "Waning Crescent": ""
}

// wttr gives "07:16 AM": [hours, minutes] on a 24-hour clock, or null.
function clock(s) {
  var m = /(\d+):(\d+)\s*(AM|PM)/.exec(String(s || ""))
  if (!m) return null
  return [Number(m[1]) % 12 + (m[3] === "PM" ? 12 : 0), Number(m[2])]
}

// [h, m] in the system's format ("HH:mm" or "h:mm AP").
function formatClock(hm, format) {
  if (!hm) return "–"
  var d = new Date(2000, 0, 1, hm[0], hm[1])
  return Qt.formatTime(d, format || "HH:mm")
}
