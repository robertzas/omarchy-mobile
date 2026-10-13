#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# The IFSC Climbing World Cup from ifsc.results.info, as one line of JSON:
# the season's calendar, the latest event's top 8 per category and, with
# "cup", the cup standings (top 10 per Olympic discipline). Ported from the
# curl and jq in simonschubert/ifsc in Simon Schubert's omarchy-widgets (MIT,
# Copyright (c) 2026 Simon Schubert and contributors; see README.md).
# The API answers only with a Referer, which a widget's XMLHttpRequest can't
# send, so this runs as a command. Standard library only.
import concurrent.futures
import datetime
import json
import re
import sys
import time
import urllib.request

BASE = "https://ifsc.results.info"


def get(path):
    req = urllib.request.Request(BASE + path, headers={"Referer": BASE + "/", "Accept": "application/json",
                                              "User-Agent": "Mozilla/5.0 (omamobile ifsc widget)"})
    with urllib.request.urlopen(req, timeout=12) as r:
        return json.load(r)


def many(paths):
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        out = []
        for result in pool.map(lambda p: _try(get, p), paths):
            out.append(result)
        return out


def _try(fn, arg):
    try:
        return fn(arg)
    except Exception:  # noqa: BLE001 - one missing category isn't fatal
        return None


def stamp(s):
    # "2026-04-30 16:00:00 UTC"
    return int(datetime.datetime.strptime(s.replace(" UTC", ""), "%Y-%m-%d %H:%M:%S")
               .replace(tzinfo=datetime.timezone.utc).timestamp())


def day(s):
    d = datetime.date.fromisoformat(s)
    return "%d %s" % (d.day, d.strftime("%b"))


def short(name):
    parts = name.split(" ")
    return "%s %s" % (parts[0].lower(), parts[1][:1] if len(parts) > 1 else "")


def events(league, now):
    out = []
    for e in league.get("events", []):
        a, b = stamp(e["starts_at"]), stamp(e["ends_at"])
        cats = e.get("d_cats", [])
        names = [c["name"] for c in cats]
        kinds = sorted(set([n.split(" ")[0].lower() for n in names if n.split(" ")[0].lower() != "speed"]
                           + ["speed" for n in names if re.match(r"^SPEED (Men|Women)", n)]))
        if now >= b or (cats and all(c.get("status") == "finished" for c in cats)):
            state = "done"
        elif now >= a:
            state = "live"
        else:
            state = "next"
        ls, le = e.get("local_start_date", ""), e.get("local_end_date", "")
        out.append({
            "id": e["event_id"],
            "name": re.sub(r" [0-9]{4}$", "", re.sub(r"^(World Climbing Series|IFSC World Cup|IFSC Climbing World Cup|IFSC) ", "", e["event"])),
            "full": e["event"], "start": a, "end": b,
            "dates": day(ls) if ls == le else "%s – %s" % (day(ls), day(le)),
            "kinds": kinds,
            "cats": [{"id": c["id"], "name": c["name"], "status": c.get("status")} for c in cats if "RELAY" not in c["name"]],
            "state": state,
        })
    out.sort(key=lambda e: e["start"])
    return out


def last_score(rounds):
    scores = [r.get("score") for r in rounds or [] if r.get("score") not in (None, "")]
    return str(scores[-1]).split(" (")[0] if scores else ""


def results(event):
    out = []
    for r in many(["/api/v1/events/%s/result/%s" % (event["id"], c["id"]) for c in event["cats"]]):
        if not r or not r.get("ranking"):
            continue
        played = [cr for cr in r.get("category_rounds", []) if cr.get("status") not in (None, "pending")]
        out.append({
            "name": r["dcat"], "short": short(r["dcat"]), "kind": r["dcat"].split(" ")[0].lower(), "status": r.get("status"),
            "round": played[-1]["name"] if played else None,
            "top": [{"rank": a.get("rank"), "name": "%s %s" % (a.get("firstname", ""), a.get("lastname", "")),
                     "country": a.get("country", ""), "score": last_score(a.get("rounds"))} for a in r["ranking"][:8]],
        })
    return out


def number(v):
    try:
        f = float(v)
        return str(int(f)) if f == int(f) else str(f)
    except (TypeError, ValueError):
        return str(v if v is not None else "")


def cup(league):
    cups = league.get("cups") or []
    if not cups:
        return []
    urls = [c["ranking_url"] for c in cups[0].get("d_cats", []) if re.match(r"^(BOULDER|LEAD|SPEED) (Men|Women)$", c["name"])]
    out = []
    for r in many(urls):
        if not r or not r.get("ranking"):
            continue
        out.append({"name": r["dcat_name"], "short": short(r["dcat_name"]), "kind": r["dcat_name"].split(" ")[0].lower(),
                    "top": [{"rank": a.get("rank"), "name": "%s %s" % (a.get("firstname", ""), a.get("lastname", "")),
                             "country": a.get("country", ""), "score": number(a.get("score"))} for a in r["ranking"][:10]]})
    out.sort(key=lambda c: (c["kind"], "Women" in c["name"]))
    return out


def main():
    want_cup = len(sys.argv) > 1 and sys.argv[1] == "cup"
    root = get("/api/v1/")
    url = next(l["url"] for l in root["current"]["leagues"] if l.get("league_id") == 1)
    league = get(url)
    evs = events(league, int(time.time()))
    started = [e for e in evs if e["state"] != "next"]
    latest = None
    if started:
        latest = dict(started[-1])
        latest["results"] = results(latest)
    out = {"season": league.get("season"), "events": evs, "latest": latest}
    if want_cup:
        out["cup"] = cup(league)
    print(json.dumps(out, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        print("ifsc.results.info: %s" % e, file=sys.stderr)
        sys.exit(1)
