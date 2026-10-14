// SPDX-License-Identifier: MIT
// The before/after pictures of the OWL built-ins: the owner's layout shape
// (owner-layout.json, the same as test/home-model.js's fixture) drawn with
// main's QML ports, and migrated (HomeModel.parse) with the OWL originals,
// approved as the migration would (owl/catalog.js portApproval), with
// made-up data for them.
//   node layout-jobs.js <side: before|after> <out dir> <store widgets dir> <theme>
"use strict"
const fs = require("fs"), path = require("path")
const [side, out, storeDir, theme] = process.argv.slice(2)
const H = require(path.resolve(__dirname, "../../../packages/omamobile-shell/plugins/omamobile.home/HomeModel.js"))
const { load } = require(path.resolve(__dirname, "../../../packages/omamobile-shell/test/owl-load.js"))
const K = load("catalog.js")
const owner = require("./owner-layout.json")
const cases = require("../cases.json")
const T = cases.time

// A wttr.in j1 answer, made up.
const hours = (base) => [0, 300, 600, 900, 1200, 1500, 1800, 2100].map((t, i) => ({ time: String(t), tempC: String(base + [0, -1, -1, 2, 5, 6, 3, 1][i]), weatherCode: "116", chanceofrain: "10", FeelsLikeC: String(base), windspeedKmph: "11", uvIndex: "2" }))
const wttr = {
  current_condition: [{ temp_C: "14", FeelsLikeC: "12", weatherCode: "116", weatherDesc: [{ value: "Partly cloudy" }], humidity: "70", windspeedKmph: "11", winddir16Point: "W", uvIndex: "2", precipMM: "0.0", localObsDateTime: "2026-10-13 01:27 PM" }],
  nearest_area: [{ areaName: [{ value: "Sample Town" }], country: [{ value: "Example" }], latitude: "52.52", longitude: "13.40" }],
  weather: ["2026-10-13", "2026-10-14", "2026-10-15"].map((d, i) => ({ date: d, maxtempC: String(16 - i), mintempC: String(9 - i), avgtempC: "12",
    astronomy: [{ sunrise: "07:26 AM", sunset: "06:18 PM", moonrise: "03:02 AM", moonset: "05:10 PM", moon_phase: "Waning Crescent", moon_illumination: "40" }], hourly: hours(9 - i) }))
}
const prices = Array.from({ length: 42 }, (_, i) => 61000 + i * 80 + Math.round(Math.sin(i / 3) * 400))
const fixtures = {
  "owl:simonschubert.crypto": { market: { code: 200, text: JSON.stringify([{ id: "bitcoin", symbol: "btc", current_price: 64250, low_24h: 63480, high_24h: 64420,
    price_change_percentage_1h_in_currency: 0.21, price_change_percentage_24h_in_currency: 1.42, price_change_percentage_7d_in_currency: 3.1,
    market_cap: 1265000000000, total_volume: 31200000000, circulating_supply: 19750000, max_supply: 21000000, ath: 73700, ath_date: "2024-03-14T07:10:36Z",
    sparkline_in_7d: { price: prices } }]) } },
  "owl:simonschubert.today": { now: { value: T }, wx: { text: JSON.stringify(wttr) } },
  "owl:simonschubert.forecast": { w: { text: JSON.stringify({ place: "Berlin (sample)", now: { temp: "14", desc: "Partly cloudy" },
    days: wttr.weather.map((d) => ({ date: d.date, day: ["Tue", "Wed", "Thu"][wttr.weather.indexOf(d)], max: d.maxtempC, min: d.mintempC, hours: d.hourly.map((h) => Number(h.tempC)) })) }) } },
  "owl:simonschubert.earthquakes": cases.widgets.find((c) => c.id === "simonschubert/earthquakes").sources,
  "owl:simonschubert.habits": cases.widgets.find((c) => c.id === "simonschubert/habits").sources
}

const layout = side === "after" ? H.parse(JSON.stringify(owner), {}) : owner
const widgets = [], approvals = {}
if (side === "after") {
  for (const p of H.portPlacements(owner)) {
    const text = fs.readFileSync(path.join(storeDir, H.owlStoreId(p.to), "widget.owl"), "utf8")
    widgets.push({ id: p.to, text, fixture: { sources: fixtures[p.to] || {} } })
    const v = K.portApproval(H.portCapabilities(p.from), K.describe(p.to, text, H.GRID, 908 / 6, 480 / 6 / 69), p.enabled)
    if (v.approve) approvals[p.to] = v.approve
  }
}
const shots = layout.pages.map((page, i) => ({ png: path.join(out, `${side}-page${i + 1}-${theme}.png`), items: page.items, page: i, pages: layout.pages.length }))
console.log(JSON.stringify({ side, time: T, widgets, approvals, shots }))
