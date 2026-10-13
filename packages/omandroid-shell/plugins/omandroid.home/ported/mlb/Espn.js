// SPDX-License-Identifier: MIT
// ESPN scoreboards and standings, reduced to what the rows show. Ported
// from the jq in simonschubert's league widgets in Simon Schubert's
// omarchy-widgets (MIT, Copyright (c) 2026 Simon Schubert and contributors;
// see
// ../../LICENSE-omarchy-widgets). Pure functions: no QML, so node can run them too.

var API = "https://site.api.espn.com/apis"

function pad2(n) { return (n < 10 ? "0" : "") + n }

// YYYYMMDD for each day offset from `now` (local days, like `date -d`).
function dayStamps(now, offsets) {
  return offsets.map(function(i) {
    var d = new Date(now.getFullYear(), now.getMonth(), now.getDate() + i)
    return "" + d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate())
  })
}

function scoreboardUrls(path, offsets, now) {
  var base = API + "/site/v2/sports/" + path + "/scoreboard"
  if (!offsets || offsets.length === 0) return [base]
  return dayStamps(now, offsets).map(function(d) { return base + "?dates=" + d })
}

function standingsUrl(path) { return API + "/v2/sports/" + path + "/standings" }

// A crest or logo at 96 px from ESPN's image combiner, by the file name the
// API gives ("132.png"); anything else gets no image.
function logoUrl(href, dir) {
  var m = /\/([a-z0-9]+\.png)$/.exec(String(href || ""))
  return m ? "https://a.espncdn.com/combiner/i?img=/i/teamlogos/" + dir + "/500/" + m[1] + "&w=96&h=96" : ""
}

function when(date) {
  var t = Date.parse(String(date || "").slice(0, 16) + ":00Z")
  return isNaN(t) ? 0 : t
}

// Several scoreboard answers -> [{ id, at, state, detail, home, away }], one
// per game, by kick-off.
function games(answers, dir) {
  var seen = {}, out = []
  answers.forEach(function(a) {
    ((a && a.events) || []).forEach(function(e) {
      if (!e || seen[e.id]) return
      var c = (e.competitions || [])[0]
      if (!c) return
      seen[e.id] = true
      var teams = (c.competitors || []).map(function(t) {
        var team = t.team || {}
        return { side: t.homeAway, abbr: String(team.abbreviation || ""), name: String(team.shortDisplayName || team.abbreviation || ""),
                 score: t.score === undefined || t.score === null ? "" : String(t.score), winner: t.winner === true,
                 logo: logoUrl(team.logo, dir) }
      })
      var find = function(side, i) {
        for (var k = 0; k < teams.length; k++) if (teams[k].side === side) return teams[k]
        return teams[i] || { abbr: "", name: "", score: "", winner: false, logo: "" }
      }
      var st = (c.status && c.status.type) || {}
      out.push({ id: String(e.id), at: when(e.date), state: String(st.state || "pre"), detail: String(st.shortDetail || ""),
                 home: find("home", 0), away: find("away", 1) })
    })
  })
  out.sort(function(a, b) { return a.at - b.at })
  return out
}

// What the tile lists: live games, then the latest results, then what's next.
function picked(all, cap) {
  var live = all.filter(function(g) { return g.state === "in" })
  var done = all.filter(function(g) { return g.state === "post" }).reverse()
  var next = all.filter(function(g) { return g.state === "pre" })
  return live.concat(done.slice(0, Math.ceil(cap / 2)), next).slice(0, cap)
}

function statsByName(entry) {
  var out = {}
  ;(entry.stats || []).forEach(function(s) { if (s && s.name) out[s.name] = s })
  return out
}

function groupsOf(answer) {
  if (!answer) return []
  if (answer.children && answer.children.length) return answer.children
  if (answer.standings) return [{ name: answer.name || "", abbreviation: answer.abbreviation || "", standings: answer.standings }]
  return []
}

// The zone a club's note puts it in (Champions League, relegation...).
function zoneOf(note) {
  var d = String(note || "").toLowerCase()
  if (!d) return ""
  if (/relegat/.test(d) && /playoff/.test(d)) return "orange"
  if (/relegat|eliminat/.test(d)) return "red"
  if (/champions league$|round of 16/.test(d)) return "green"
  return "blue"
}

// Football tables: [{ name, teams: [{ id, abbr, name, logo, rank, played, won, drawn, lost, gd, pts, zone }] }]
function soccerTable(answer, dir) {
  return groupsOf(answer).map(function(g) {
    var teams = ((g.standings && g.standings.entries) || []).map(function(e) {
      var s = statsByName(e), team = e.team || {}
      var v = function(n) { return s[n] ? Math.floor(Number(s[n].value) || 0) : 0 }
      return { id: String(team.id || ""), abbr: String(team.abbreviation || ""), name: String(team.shortDisplayName || ""),
               logo: logoUrl(((team.logos || [])[0] || {}).href, dir), rank: v("rank"), played: v("gamesPlayed"),
               won: v("wins"), drawn: v("ties"), lost: v("losses"), gd: v("pointDifferential"), pts: v("points"),
               zone: zoneOf(e.note && e.note.description), zoneText: String((e.note && e.note.description) || "") }
    })
    teams.sort(function(a, b) { return a.rank - b.rank })
    return { name: String(g.name || ""), teams: teams }
  })
}

// US leagues: [{ name, teams: [{ id, abbr, name, logo, seed, rec, b, sign }] }] in
// seed order. `bStat` is the last column: gamesBehind, points or
// pointDifferential.
function usTable(answer, dir, bStat) {
  return groupsOf(answer).map(function(g) {
    var teams = ((g.standings && g.standings.entries) || []).map(function(e) {
      var s = statsByName(e), team = e.team || {}
      var b = s[bStat]
      var bText = "–", sign = 0
      if (b) {
        if (bStat === "points") bText = String(Math.floor(Number(b.value) || 0))
        else bText = String(b.displayValue !== undefined ? b.displayValue : b.value)
        if (bStat === "pointDifferential") sign = Number(b.value) > 0 ? 1 : Number(b.value) < 0 ? -1 : 0
      }
      var seed = s.playoffSeed ? Math.floor(Number(s.playoffSeed.value) || 99) : 99
      return { id: String(team.id || ""), abbr: String(team.abbreviation || ""), name: String(team.shortDisplayName || ""),
               logo: logoUrl(((team.logos || [])[0] || {}).href, dir), seed: seed,
               rec: s.overall ? String(s.overall.displayValue || "").split(", ")[0] : "", b: bText, sign: sign }
    })
    teams.sort(function(a, b) { return a.seed - b.seed })
    return { name: String(g.abbreviation || g.name || ""), teams: teams }
  })
}

// The rows of the list: a flat model for one ListView.
function rows(view, list, groups, cuts, bLabel, kind) {
  var out = []
  if (view === "games") {
    list.forEach(function(g) { out.push({ kind: "game", key: "g" + g.id, g: g }) })
    return out
  }
  groups.forEach(function(grp) {
    if (kind === "us" || groups.length > 1) out.push({ kind: "head", key: "h" + grp.name, text: grp.name, b: kind === "us" ? bLabel : "" })
    grp.teams.forEach(function(t, i) {
      if (i > 0 && cuts.indexOf(i) >= 0) out.push({ kind: "cut", key: "c" + grp.name + i })
      out.push({ kind: "team", key: "t" + t.id, t: t })
    })
  })
  return out
}

if (typeof module !== "undefined" && module.exports) module.exports = { dayStamps: dayStamps, scoreboardUrls: scoreboardUrls, logoUrl: logoUrl,
  games: games, picked: picked, soccerTable: soccerTable, usTable: usTable, rows: rows, zoneOf: zoneOf, standingsUrl: standingsUrl }
