#!/usr/bin/env python3
"""List how OpenRouter caches each model, so the app's policy can be checked.

usage: scripts/openrouter-cache-audit.py <slug> [<slug> ...]
       scripts/openrouter-cache-audit.py < slugs.txt        (one slug per line)

For each model it reads the keyless endpoint directory and prints, over the
standard endpoints, how many support implicit caching, how many price a cache
read and how many price a cache write. Compare the verdict with
`OpenRouterCachePolicy.policy(for:)` (ForeverLMApp/Shared/Models/AIModelDefaultsCore.swift):

  explicit   no endpoint caches implicitly but a read and a write are priced:
             the provider needs `cache_control` markers and bills each write
             above the plain input rate (Anthropic, Gemini, GPT-5.6 and later)
  implicit   endpoints cache on their own and price only the read
  none       nothing is priced: nothing to buy

A model whose verdict is `explicit` but whose policy is `.implicit` pays the
write premium and loses the entry within about a minute; that is how GPT-5.6
went uncached until 2026-10-15.
"""
import json
import subprocess
import sys


def endpoints(slug):
    base = slug.split(":")[0]
    out = subprocess.run(
        ["curl", "-s", "--max-time", "25", f"https://openrouter.ai/api/v1/models/{base}/endpoints"],
        capture_output=True, text=True,
    ).stdout
    try:
        return json.loads(out)["data"]["endpoints"]
    except (ValueError, KeyError, TypeError):
        return None


def priced(endpoint, key):
    return endpoint.get("pricing", {}).get(key) not in (None, "", "0", 0, "0.0")


def main():
    slugs = sys.argv[1:] or [line.strip() for line in sys.stdin if line.strip()]
    if not slugs:
        sys.exit(__doc__)
    for slug in slugs:
        rows = endpoints(slug)
        if rows is None:
            print(f"{slug:55} unreadable")
            continue
        standard = [e for e in rows if not str(e.get("tag", "")).endswith(("/fast", "/flex", "/priority"))] or rows
        n = len(standard)
        implicit = sum(1 for e in standard if e.get("supports_implicit_caching"))
        read = sum(1 for e in standard if priced(e, "input_cache_read"))
        write = sum(1 for e in standard if priced(e, "input_cache_write"))
        if read and write and not implicit:
            verdict = "explicit"
        elif read:
            verdict = "implicit"
        else:
            verdict = "none"
        print(f"{slug:55} {verdict:9} implicit {implicit}/{n}  read-priced {read}/{n}  write-priced {write}/{n}")


if __name__ == "__main__":
    main()
