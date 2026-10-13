# SPDX-License-Identifier: MIT
# The newest posts of the RSS and Atom feeds given as arguments, merged,
# newest first, as one line of JSON. Fetched in parallel; unreachable feeds
# are skipped. From simonschubert/feeds in Simon Schubert's omarchy-widgets
# (MIT, Copyright (c) 2026 Simon Schubert and contributors; see README.md).
import sys, json, urllib.request, xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from email.utils import parsedate_to_datetime

A = "{http://www.w3.org/2005/Atom}"


def when(s):
    try:
        return int(parsedate_to_datetime(s).timestamp())
    except Exception:
        try:
            return int(datetime.fromisoformat(s.strip().replace("Z", "+00:00")).timestamp())
        except Exception:
            return 0


def text(e, *tags):
    for t in tags:
        x = e.find(t)
        if x is not None and x.text:
            return " ".join(x.text.split())
    return ""


def web(u):
    # Only http(s) links are handed to the browser.
    u = (u or "").strip()
    return u if u.lower().startswith(("http://", "https://")) else ""


def fetch(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "omandroid feeds widget"})
        root = ET.fromstring(urllib.request.urlopen(req, timeout=10).read(4 << 20))
    except Exception:
        return []
    out = []
    ch = root.find("channel")
    if ch is not None:
        feed = text(ch, "title")
        for i in ch.findall("item"):
            out.append({"title": text(i, "title"), "url": web(text(i, "link")), "at": when(text(i, "pubDate")), "feed": feed})
    else:
        feed = text(root, A + "title")
        for e in root.findall(A + "entry"):
            link = e.find(A + "link[@rel=\"alternate\"]")
            if link is None:
                link = e.find(A + "link")
            out.append({"title": text(e, A + "title"), "url": web(link.get("href") if link is not None else ""),
                        "at": when(text(e, A + "published", A + "updated")), "feed": feed})
    return [p for p in out if p["url"]]


urls = [u for u in sys.argv[1:] if web(u)][:16]
with ThreadPoolExecutor(8) as pool:
    posts = [p for ps in pool.map(fetch, urls) for p in ps]
posts.sort(key=lambda p: -p["at"])
for p in posts:
    p["title"] = p["title"][:200]
    p["feed"] = p["feed"][:60]
print(json.dumps(posts[:40]))
