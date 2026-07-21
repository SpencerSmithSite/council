#!/usr/bin/env python3
"""Ingest the Church Fathers corpus from newadvent.org into structured records.

New Advent hosts the Schaff Ante-Nicene / Nicene and Post-Nicene Fathers
translations (1885-1900), which are public domain. Each work page carries an
"About this page" footer naming the translator and edition, so provenance is
recorded per source rather than assumed.

Three stages, each independently runnable:

    python3 tools/ingest_newadvent.py manifest        # index -> works list
    python3 tools/ingest_newadvent.py fetch --limit 5 # download to .cache/
    python3 tools/ingest_newadvent.py parse           # cached html -> units.json

Fetching is cached on disk and rate limited; re-runs cost nothing. Nothing here
touches assets/theology.db — `build_corpus.py` does that from units.json.
"""

import argparse
import html
import json
import re
import sys
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "newadvent"
MANIFEST = ROOT / "tools" / "data" / "newadvent_manifest.json"
UNITS = ROOT / "tools" / "data" / "newadvent_units.json"

BASE = "https://www.newadvent.org/fathers/"
INDEX = BASE

# Polite: newadvent.org is a small volunteer-run site and robots.txt only
# disallows /cgi-bin/ and /tmp/. One request per second, identified.
USER_AGENT = "council-research/0.1 (offline theology corpus; contact via github SpencerSmithSite/council)"
DELAY_SECONDS = 1.0

# Ad slots interleaved with the text. Deliberately does NOT match
# <div class="pub">: that div holds the "About this page" provenance footer.
JUNK_DIV_RE = re.compile(
    r"<div[^>]*(?:CMtag|catholicadnet)[^>]*>.*?</div>",
    re.S | re.I,
)

# Works whose extracted text falls below this are link hubs or stubs, not text.
MIN_WORK_CHARS = 1200

# Paragraph-chunking target for works with no section headings.
CHUNK_TARGET_CHARS = 2500
TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"[ \t ]+")


def http_get(url):
    # Shelling out to curl rather than urllib: the python.org macOS build ships
    # without a CA bundle, so urllib fails cert verification out of the box.
    result = subprocess.run(
        [
            "curl", "--silent", "--show-error", "--fail",
            "--location", "--max-time", "30",
            "--user-agent", USER_AGENT,
            url,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise FetchError(f"curl exit {result.returncode}: {result.stderr.strip()}")
    return result.stdout


class FetchError(Exception):
    pass


def cached_get(url, cache_path):
    if cache_path.exists():
        return cache_path.read_text(encoding="utf-8"), True
    body = http_get(url)
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(body, encoding="utf-8")
    time.sleep(DELAY_SECONDS)
    return body, False


def clean_text(fragment):
    """HTML fragment -> plain text, entities resolved, whitespace normalised."""
    text = TAG_RE.sub(" ", fragment)
    text = html.unescape(text)
    text = WS_RE.sub(" ", text)
    return re.sub(r"\s*\n\s*", "\n", text).strip()


# --------------------------------------------------------------------------
# stage 1: manifest


def build_manifest():
    body, _ = cached_get(INDEX, CACHE / "index.html")

    # The index is a flat run of <p> blocks: an author in <strong>, then that
    # author's works as links to /fathers/NNNN.htm.
    works = []
    for block in re.split(r"<p[^>]*>", body):
        if "/fathers/" not in block:
            continue
        author_match = re.search(r"<strong>(.*?)</strong>", block, re.S)
        if not author_match:
            continue
        author_raw = clean_text(author_match.group(1))
        # "Athanasius" or "Aphraates (c. 280-367)"
        dates_match = re.search(r"\(([^)]*\d[^)]*)\)\s*$", author_raw)
        dates = dates_match.group(1) if dates_match else None
        author = re.sub(r"\s*\([^)]*\d[^)]*\)\s*$", "", author_raw).strip()

        for href, label in re.findall(
            r'href="(?:\.\./)?fathers/(\d+)\.htm"[^>]*>(.*?)</a>', block, re.S
        ):
            title = clean_text(label)
            if not title or title.lower() == author.lower():
                continue
            works.append(
                {
                    "id": href,
                    "url": f"{BASE}{href}.htm",
                    "title": title,
                    "author": author,
                    "author_dates": dates,
                }
            )

    # The index links some works more than once.
    seen, unique = set(), []
    for w in works:
        if w["id"] in seen:
            continue
        seen.add(w["id"])
        unique.append(w)

    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(json.dumps(unique, indent=2) + "\n", encoding="utf-8")

    authors = {w["author"] for w in unique}
    print(f"{len(unique)} works by {len(authors)} authors -> {MANIFEST}")
    return unique


# --------------------------------------------------------------------------
# stage 2: fetch


def fetch(limit=None, only=None):
    works = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if only:
        works = [w for w in works if w["id"] in only]
    if limit:
        works = works[:limit]

    fetched = cached = failed = 0
    for i, w in enumerate(works, 1):
        try:
            _, was_cached = cached_get(w["url"], CACHE / f"{w['id']}.html")
            cached += was_cached
            fetched += not was_cached
        except FetchError as e:
            print(f"  FAILED {w['id']} {w['title'][:40]}: {e}", file=sys.stderr)
            failed += 1
        if i % 25 == 0:
            print(f"  {i}/{len(works)} ({fetched} fetched, {cached} cached)")

    print(f"done: {fetched} fetched, {cached} already cached, {failed} failed")


# --------------------------------------------------------------------------
# stage 3: parse


def parse_provenance(body):
    """Pull translator/edition out of the 'About this page' footer."""
    idx = body.find("About this page")
    if idx < 0:
        return {}
    tail = clean_text(body[idx : idx + 900])
    source = re.search(r"Source\.\s*(.*?)(?:Contact information|$)", tail, re.S)
    if not source:
        return {}
    text = WS_RE.sub(" ", source.group(1)).strip()
    # Stop at the clause boundary, not the first period — translators are
    # routinely cited by initials ("S.D.F. Salmond").
    translator = re.search(r"Translated by (.+?)\.\s+(?:From|Edited|Revised|$)", text)
    edition = re.search(r"From (.+?)\.\s*(?:Edited|Revised|\()", text)
    year = re.search(r"\b(1[6-9]\d\d)\b", text)
    return {
        "citation": text[:400],
        "translator": translator.group(1).strip() if translator else None,
        "edition": edition.group(1).strip() if edition else None,
        "year": int(year.group(1)) if year else None,
    }


# Site furniture that sits inside the content region. The previous corpus
# ingested this verbatim as though it were patristic text.
CHROME_RE = re.compile(
    r"Please help support the mission of New Advent"
    r"|Includes the Catholic Encyclopedia"
    r"|Copyright\s*©"
    r"|Get the full contents of this website",
    re.I,
)


def paragraphs_of(fragment):
    return [
        text
        for text in (clean_text(p) for p in re.split(r"</?p[^>]*>", fragment))
        if len(text) > 1 and not CHROME_RE.search(text)
    ]


def units_from_sections(region):
    """Preferred shape: one unit per <h2> section heading."""
    units = []
    for section in re.split(r"<h2[^>]*>", region)[1:]:
        parts = section.split("</h2>", 1)
        if len(parts) != 2:
            continue
        heading, rest = parts
        heading = clean_text(heading)
        if heading.lower().startswith("about this page"):
            continue

        content = "\n\n".join(paragraphs_of(rest))
        if not content.strip():
            continue

        # Headings are numbered in the source: "12. On the resurrection..."
        number_match = re.match(r"^(\d+)\.?\s*", heading)
        units.append(
            {
                "number": int(number_match.group(1)) if number_match else None,
                "title": heading[:300],
                "content": content,
            }
        )
    return units


def units_from_paragraphs(region, work_title):
    """Fallback: some works are a flat run of <p> with no section headings.

    Group paragraphs into units of roughly CHUNK_TARGET_CHARS, never splitting
    a paragraph, so passages stay coherent for both reading and retrieval.
    """
    units, chunk, size = [], [], 0

    def flush():
        if not chunk:
            return
        # These texts are usually numbered in the translation ("1. The true
        # Thesaurus…"); prefer the author's own numbering over an invented one.
        number_match = re.match(r"^(\d+)\.\s", chunk[0])
        number = int(number_match.group(1)) if number_match else len(units) + 1
        units.append(
            {
                "number": number,
                "title": f"{work_title} — {number}",
                "content": "\n\n".join(chunk),
            }
        )

    for para in paragraphs_of(region):
        chunk.append(para)
        size += len(para)
        if size >= CHUNK_TARGET_CHARS:
            flush()
            chunk, size = [], 0
    flush()
    return units


def parse_work(work, body):
    """Split a work page into content units.

    Provenance is read before the ad-stripping pass, since the footer lives in
    a div adjacent to the ad slots.
    """
    provenance = parse_provenance(body)
    body = JUNK_DIV_RE.sub(" ", body)

    # Content ends at the "About this page" footer; everything before the first
    # heading is site navigation.
    end = body.find("About this page")
    if end < 0:
        end = len(body)

    # Region starts after the <h1> title so nothing before it is lost; site
    # navigation sits above that.
    title_end = body.find("</h1>")
    start = title_end + 5 if 0 <= title_end < end else 0
    region = body[start:end]

    # Prefer section headings, but only when the work actually uses them
    # throughout. Some pages carry a single stray <h2> over a long flat body —
    # trusting it would silently discard everything before that heading.
    units = units_from_sections(region)
    section_chars = sum(len(u["content"]) for u in units)
    region_chars = sum(len(p) for p in paragraphs_of(region))

    if len(units) < 3 or section_chars < region_chars * 0.6:
        units = units_from_paragraphs(region, work["title"])

    total = sum(len(u["content"]) for u in units)
    if not units or total < MIN_WORK_CHARS:
        return None

    return {
        "work_id": work["id"],
        "url": work["url"],
        "title": work["title"],
        "author": work["author"],
        "author_dates": work.get("author_dates"),
        "provenance": provenance,
        "units": units,
    }


def parse_all():
    works = json.loads(MANIFEST.read_text(encoding="utf-8"))
    parsed, skipped = [], 0

    for w in works:
        path = CACHE / f"{w['id']}.html"
        if not path.exists():
            continue
        record = parse_work(w, path.read_text(encoding="utf-8"))
        if record is None:
            skipped += 1
            continue
        parsed.append(record)

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    UNITS.write_text(json.dumps(parsed, indent=2) + "\n", encoding="utf-8")

    total_units = sum(len(r["units"]) for r in parsed)
    chars = sum(len(u["content"]) for r in parsed for u in r["units"])
    with_prov = sum(1 for r in parsed if r["provenance"].get("translator"))
    print(f"parsed {len(parsed)} works, {skipped} unparseable")
    print(f"  {total_units} content units, {chars / 1e6:.1f}M chars")
    print(f"  {with_prov}/{len(parsed)} works have translator provenance")
    print(f"  -> {UNITS}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("manifest")
    f = sub.add_parser("fetch")
    f.add_argument("--limit", type=int)
    f.add_argument("--only", nargs="*")
    sub.add_parser("parse")

    args = parser.parse_args()
    if args.command == "manifest":
        build_manifest()
    elif args.command == "fetch":
        fetch(limit=args.limit, only=args.only)
    elif args.command == "parse":
        parse_all()


if __name__ == "__main__":
    main()
