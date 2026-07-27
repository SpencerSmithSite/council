#!/usr/bin/env python3
"""Discover what CCEL actually holds for a list of authors, and prove it.

This exists because the alternative is writing a list of plausible work ids
from memory. `SOURCES.md` is explicit that unverified URLs are exactly the kind
of content this corpus is meant to be free of, so the acquisition list for the
Reformation-era expansion is *derived* — every id below came off CCEL's own
author index page, and every rights line came out of the work's own export
header.

Three steps, each cached, so a re-run costs nothing:

    python3 tools/survey_ccel.py authors   # author index -> work ids
    python3 tools/survey_ccel.py works     # work id -> title, rights, size
    python3 tools/survey_ccel.py report    # the table to choose from

Why the header fetch is cheap: CCEL answers HTTP range requests (206), and the
export header carries Title, Creator(s) — including the translator — and
Rights within the first kilobyte. Surveying 200 works therefore moves ~200 KB
rather than ~2 GB. The full text is only pulled for works actually chosen, by
`ingest_reformation.py`.

CCEL's robots.txt sets `Crawl-delay: 10` for `*` and disallows nothing. Honour
it: this walks slowly on purpose and is meant to be run in the background.
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "ccel_survey"
INDEX_PATH = CACHE / "work_ids.json"
HEADERS_PATH = CACHE / "work_headers.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)
DELAY_SECONDS = 10.0

# CCEL author slugs to walk. Chosen to cover the request — Reformers,
# commentators, Puritans, and the Orthodox confessional documents that reach
# English only through Schaff — plus a few adjacent figures whose absence would
# be odd once the rest are in.
AUTHORS = [
    # Reformers
    "calvin", "luther", "knox", "zwingli", "melanchthon", "bullinger",
    # Commentators
    "henry", "gill", "clarke", "barnes", "poole", "jfb", "lightfoot",
    # Puritans and their heirs
    "bunyan", "owen", "baxter", "edwards", "sibbes", "brooks", "watson",
    "flavel", "charnock", "goodwin", "boston", "howe", "manton", "perkins",
    # Preachers
    "spurgeon", "whitefield", "ryle", "bonar", "newton", "murray",
    # Reference sets that carry other traditions' documents
    "schaff", "hodge",
    # Devotional / medieval, adjacent but public domain
    "kempis", "law", "lawrence",
]

# A work id looks like `/ccel/<author>/<work>` and may be followed by more
# path. Anything with a file extension is a page, not a work.
WORK_HREF = re.compile(r'href="(?:https?://(?:www\.)?ccel\.org)?/ccel/([a-z0-9_]+)/([a-z0-9_]+)')

FIELD = re.compile(r"^\s*(Title|Creator\(s\)|Rights|CCEL Subjects):\s*(.+?)\s*$", re.M)


def curl(url, extra=()):
    result = subprocess.run(
        ["curl", "-fsSL", "--max-time", "90", "-A", USER_AGENT, *extra, url],
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout


def curl_range(url, last_byte=1200):
    """Fetch the opening bytes and the work's full length in one request.

    A separate HEAD for Content-Length would double the request count against a
    site asking for ten seconds between them — and a 206 already carries the
    total in `Content-Range: bytes 0-1200/4618688`, so asking twice is pure
    waste. `-D -` writes the headers to stdout ahead of the body.
    """
    result = subprocess.run(
        ["curl", "-fsS", "-D", "-", "--max-time", "90", "-A", USER_AGENT,
         "-r", f"0-{last_byte}", url],
        capture_output=True,
    )
    if result.returncode != 0:
        return None, None

    raw = result.stdout.decode("utf-8", errors="replace")
    head, _, body = raw.partition("\r\n\r\n")
    match = re.search(r"^content-range:\s*bytes\s+\S+/(\d+)", head, re.I | re.M)
    return body, (int(match.group(1)) if match else None)


def text_url(author, work):
    return f"https://www.ccel.org/ccel/{author}/{work}/cache/{work}.txt"


def authors():
    """Walk each author index and record the work ids it links to."""
    CACHE.mkdir(parents=True, exist_ok=True)
    found = json.loads(INDEX_PATH.read_text()) if INDEX_PATH.exists() else {}

    for author in AUTHORS:
        if author in found:
            print(f"  cached  {author:<12} {len(found[author])} works")
            continue

        page = curl(f"https://www.ccel.org/ccel/{author}")
        if page is None:
            print(f"  MISSING {author:<12} (no author index)", file=sys.stderr)
            found[author] = []
            INDEX_PATH.write_text(json.dumps(found, indent=2, sort_keys=True) + "\n")
            time.sleep(DELAY_SECONDS)
            continue

        html = page.decode("utf-8", errors="replace")
        works = sorted({
            work for owner, work in WORK_HREF.findall(html)
            # Author index pages cross-link other authors; keep this one's.
            if owner == author and work != author
        })
        found[author] = works
        print(f"  fetched {author:<12} {len(works)} works")
        INDEX_PATH.write_text(json.dumps(found, indent=2, sort_keys=True) + "\n")
        time.sleep(DELAY_SECONDS)

    total = sum(len(v) for v in found.values())
    print(f"\n{total} work ids across {len(found)} authors -> {INDEX_PATH}")


def works():
    """Pull the first kilobyte of each text export for its metadata header."""
    if not INDEX_PATH.exists():
        sys.exit("no work ids yet — run `survey_ccel.py authors` first")

    index = json.loads(INDEX_PATH.read_text())
    headers = json.loads(HEADERS_PATH.read_text()) if HEADERS_PATH.exists() else {}

    pending = [
        (author, work)
        for author, works_ in sorted(index.items())
        for work in works_
        if f"{author}/{work}" not in headers
    ]
    print(f"{len(pending)} works to probe "
          f"({len(headers)} already cached)\n")

    for i, (author, work) in enumerate(pending, 1):
        key = f"{author}/{work}"
        url = text_url(author, work)

        # A header read, not a download. A work with no text export answers 404
        # and is recorded as absent rather than retried on the next run.
        head, size = curl_range(url)
        if head is None:
            headers[key] = {"url": url, "exists": False}
            print(f"  [{i}/{len(pending)}] absent  {key}")
        else:
            fields = {k: v for k, v in FIELD.findall(head)}
            headers[key] = {
                "url": url,
                "exists": True,
                "title": fields.get("Title"),
                "creators": fields.get("Creator(s)"),
                "rights": fields.get("Rights"),
                "subjects": fields.get("CCEL Subjects"),
                "bytes": size,
            }
            print(f"  [{i}/{len(pending)}] ok      {key:<24} "
                  f"{(fields.get('Title') or '?')[:56]}")

        HEADERS_PATH.write_text(json.dumps(headers, indent=2, sort_keys=True) + "\n")
        time.sleep(DELAY_SECONDS)

    print(f"\n-> {HEADERS_PATH}")


def report():
    if not HEADERS_PATH.exists():
        sys.exit("no headers yet — run `survey_ccel.py works` first")

    headers = json.loads(HEADERS_PATH.read_text())
    live = {k: v for k, v in headers.items() if v.get("exists")}
    public = {k: v for k, v in live.items()
              if "public domain" in (v.get("rights") or "").lower()}

    print(f"{len(headers)} probed · {len(live)} with a text export · "
          f"{len(public)} stating public domain\n")

    total = 0
    for key, meta in sorted(public.items(), key=lambda kv: -(kv[1].get("bytes") or 0)):
        size = meta.get("bytes") or 0
        total += size
        print(f"  {size/1e6:>7.2f} MB  {key:<26} {(meta.get('title') or '')[:60]}")

    print(f"\n  {total/1e6:>7.2f} MB  total if every public-domain work is taken")

    withheld = {k: v for k, v in live.items() if k not in public}
    if withheld:
        print(f"\n{len(withheld)} works whose export does not state public domain "
              f"— not ingestable:")
        for key, meta in sorted(withheld.items()):
            print(f"    {key:<26} rights: {meta.get('rights')!r}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["authors", "works", "report"])
    args = parser.parse_args()
    {"authors": authors, "works": works, "report": report}[args.command]()


if __name__ == "__main__":
    main()
