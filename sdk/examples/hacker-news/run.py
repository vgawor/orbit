#!/usr/bin/env python3
"""Orbit widget: the top five Hacker News stories (public, keyless API)."""
import json, urllib.request

def get(url):
    with urllib.request.urlopen(url, timeout=8) as r:
        return json.load(r)

ids = get("https://hacker-news.firebaseio.com/v0/topstories.json")[:5]
items = []
for i in ids:
    s = get(f"https://hacker-news.firebaseio.com/v0/item/{i}.json")
    items.append({"title": s.get("title", "?"), "value": f"{s.get('score', 0)} ▲",
                  "url": s.get("url") or f"https://news.ycombinator.com/item?id={i}"})
print(json.dumps({"title": "Hacker News", "value": items[0]["title"] if items else "",
                  "subtitle": "Top story right now", "items": items, "tint": "#FF6600",
                  "url": "https://news.ycombinator.com"}))
