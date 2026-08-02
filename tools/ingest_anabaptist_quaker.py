#!/usr/bin/env python3
"""Ingest the Anabaptist and Quaker traditions from Project Gutenberg.

`TODO.md` calls this "the largest tradition-shaped hole that is not blocked by
copyright, and the largest remaining win" — the corpus held nothing at all from
either tradition, so a question about believers' baptism, non-resistance or the
inward light was answered entirely by their critics.

Gutenberg rather than archive.org for the reason `ingest_gutenberg.py` gives:
these are proofread transcriptions by Distributed Proofreaders, not OCR. Every
title here is pre-1929 and public domain in the United States.

    python3 tools/ingest_anabaptist_quaker.py fetch
    python3 tools/ingest_anabaptist_quaker.py parse

## Splitting, and the one rule that makes it general

Seven books with six different internal structures — propositions, chapters,
years, and 6.3 MB of martyr accounts headed by name and date. Writing a bespoke
parser for each invites a bespoke bug in each.

What they share is a table of contents that repeats every heading verbatim, so a
naive split yields each heading twice: once as a contents line, once as the
section itself. **Keep the last occurrence of each distinct heading** and the
contents block falls away wherever it sits and however it is worded, because the
body always comes after it. Barclay resolves from 28 matches to his fifteen
propositions; Fox's first volume from 28 to fourteen chapters.

A gap rule was tried first and is what this does *not* do. Requiring a section
to sit `MIN_GAP` past the previous one reads well and quietly fails on exactly
the books that need it most: a contents block spanning more than the threshold
produces accepted matches of its own, so Barclay's first "unit" was his whole
contents page and *No Cross, No Crown* began at Chapter III with the first two
chapters swallowed. It is kept only as a secondary guard, well below the size of
a real section.

## What is not here

**Menno Simons**, and the Schleitheim (1527) and Dordrecht (1632) confessions —
which is to say the Anabaptist confessional backbone. Gutenberg has no edition
of any of them under any title, and CCEL has no Menno Simons author page. The
remaining copies are archive.org OCR, and the corpus's standard against OCR is
what this file is built on. They stay named gaps in `TODO.md`.

The Anabaptist side is therefore *Martyrs Mirror* alone. That is not a small
thing — after the Bible it is the book Mennonite households actually held — but
it is martyrology, not systematics, and the corpus should say so rather than
imply the tradition is covered.
"""

import argparse
import json
import re
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "anabaptist_quaker"
UNITS = ROOT / "tools" / "data" / "anabaptist_quaker_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)
DELAY_SECONDS = 2.0

START = re.compile(r"^\*\*\* START OF THE PROJECT GUTENBERG EBOOK.*$", re.M)
END = re.compile(r"^\*\*\* END OF THE PROJECT GUTENBERG EBOOK.*$", re.M)

# Two headings closer together than this are treated as neighbours in a contents
# block rather than two sections — a contents entry is a line, a section is
# thousands of characters. Only a run of RUN_LENGTH or more such neighbours is
# discarded, so a genuinely short section standing alone survives.
MIN_GAP = 600
RUN_LENGTH = 3

WORKS = [
    {
        "id": 56487,
        "dedupe": "last",
        "title": "An Apology for the True Christian Divinity",
        "author": "Robert Barclay",
        "date": "1678",
        "tradition": "Quaker",
        "kind": "Treatise",
        "translator": None,
        "rights": "Public domain in the US: published 1678; this edition pre-1929",
        # Barclay argues fifteen numbered propositions; the whole book is their
        # defence, so they are its own divisions rather than an imposed one.
        "split": r"^\s*PROP(?:OSITION)?\.?\s+[IVXLC]+",
        "label": "Proposition",
        "min_units": 12,
    },
    {
        "id": 75559,
        "dedupe": "last",
        "title": "The Journal of George Fox, Volume 1",
        "author": "George Fox",
        "date": "1694",
        "tradition": "Quaker",
        "kind": "Treatise",
        "translator": None,
        "rights": "Public domain in the US: written 1694; this edition pre-1929",
        "split": r"^\s*CHAPTER\s+[IVXLC0-9]+",
        "label": "Chapter",
        "min_units": 12,
    },
    {
        "id": 75590,
        "dedupe": "last",
        "title": "The Journal of George Fox, Volume 2",
        "author": "George Fox",
        "date": "1694",
        "tradition": "Quaker",
        "kind": "Treatise",
        "translator": None,
        "rights": "Public domain in the US: written 1694; this edition pre-1929",
        "split": r"^\s*CHAPTER\s+[IVXLC0-9]+",
        "label": "Chapter",
        "min_units": 12,
    },
    {
        "id": 44895,
        "dedupe": "last",
        "title": "No Cross, No Crown",
        "author": "William Penn",
        "date": "1669",
        "tradition": "Quaker",
        "kind": "Treatise",
        "translator": None,
        "rights": "Public domain in the US: published 1669; this edition pre-1929",
        "split": r"^\s*CHAPTER\s+[IVXLC0-9]+",
        "label": "Chapter",
        "min_units": 15,
    },
    {
        "id": 37311,
        "dedupe": "runs",
        "title": "The Journal of John Woolman",
        "author": "John Woolman",
        "date": "1774",
        "tradition": "Quaker",
        "kind": "Treatise",
        "translator": None,
        "rights": "Public domain in the US: published 1774; this edition pre-1929",
        "split": r"^\s*CHAPTER\s+[IVXLC0-9]+",
        "label": "Chapter",
        "min_units": 8,
    },
    {
        "id": 57241,
        "dedupe": "last",
        "title": (
            "The History of the Rise, Increase, and Progress of the "
            "Christian People Called Quakers"
        ),
        "author": "William Sewel",
        "date": "1722",
        "tradition": "Quaker",
        "kind": "Treatise",
        "translator": None,
        "rights": "Public domain in the US: published 1722; this edition pre-1929",
        # Sewel writes annalistically and heads each year; his own numbered
        # books run to a quarter of a million characters each, which is not a
        # unit anyone can read or cite.
        "split": r"^\s*1[5-7]\d\d\.\s*$",
        "label": "Year",
        "min_units": 40,
    },
    {
        "id": 65855,
        "dedupe": "runs",
        "title": "The Bloody Theatre, or Martyrs Mirror of the Defenseless Christians",
        "author": "Thieleman J. van Braght",
        "date": "1660",
        "tradition": "Anabaptist",
        "kind": "Treatise",
        "translator": "Joseph F. Sohm",
        "rights": (
            "Public domain in the US: van Braght 1660, Sohm's translation "
            "published by the Mennonite Publishing Company, Elkhart, 1886"
        ),
        # Each account is headed by its subject in capitals with the year of
        # martyrdom. Anchoring on the year is what separates an account heading
        # from the book's many other capitalised lines.
        "split": r"^[A-Z][A-Z0-9 ,.\'’—\-]{6,90}(?:A\.\s?D\.\s?|IN THE YEAR )\d{3,4}",
        "label": "Account",
        "min_units": 200,
    },
]


def cached(work):
    return CACHE / f"{work['id']}.txt"


def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    for work in WORKS:
        path = cached(work)
        if path.exists():
            print(f"  cached  {work['id']}  {path.stat().st_size:>9,} bytes")
            continue
        url = f"https://www.gutenberg.org/ebooks/{work['id']}.txt.utf-8"
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=90) as response:
            data = response.read()
        path.write_bytes(data)
        print(f"  fetched {work['id']}  {len(data):>9,} bytes")
        time.sleep(DELAY_SECONDS)


def body(text, work):
    start, end = START.search(text), END.search(text)
    if not (start and end):
        sys.exit(f"REFUSED: {work['id']} has no Gutenberg markers — the licence "
                 f"boilerplate would be ingested as text.")
    return text[start.end():end.start()]


def clean(chunk):
    """Rewrapped prose. Gutenberg hard-wraps; paragraphs are blank-line split."""
    chunk = re.sub(r"\[\d+\]", "", chunk)               # footnote anchors
    paragraphs = [
        " ".join(line.strip() for line in para.strip().splitlines())
        for para in re.split(r"\n\s*\n", chunk) if para.strip()
    ]
    text = "\n\n".join(p for p in paragraphs if p).strip()
    return re.sub(r"_([^_\n]+)_", r"\1", text)          # print italics


def split(text, work):
    """Section starts, with contents blocks discarded.

    A contents block is a *run* of headings packed close together, and the whole
    run goes. Both simpler rules fail on one of these books:

      * Dropping duplicate headings and keeping the last breaks Woolman, whose
        volume is three works each restarting at Chapter I — the Journal's own
        opening chapters lose to the later works' and vanish.
      * Requiring each heading to sit MIN_GAP past the previous one breaks
        Barclay and Penn, where the contents block is long enough to contain
        accepted matches of its own.

    Run detection separates them because it keys on the one thing a contents
    page always is and a sequence of real sections never is: many headings with
    almost no text between them.
    """
    matches = [(m.start(), " ".join(m.group(0).split()))
               for m in re.finditer(work["split"], text, re.M)]
    if not matches:
        return []

    # Single-work volumes whose contents repeat every heading verbatim: the
    # body always follows the contents, so the later of the two wins. Fox needs
    # this rather than run detection because his contents entries are
    # paragraph-long chapter summaries, spaced as widely as real sections.
    if work["dedupe"] == "last":
        last = {}
        for position, heading in matches:
            last[heading] = position
        return _units(sorted((p, h) for h, p in last.items()), text, work)

    keep = [True] * len(matches)
    index = 0
    while index < len(matches):
        end = index
        while (end + 1 < len(matches)
               and matches[end + 1][0] - matches[end][0] < MIN_GAP):
            end += 1
        if end - index + 1 >= RUN_LENGTH:
            for position in range(index, end + 1):
                keep[position] = False
        index = end + 1

    return _units([m for m, wanted in zip(matches, keep) if wanted], text, work)


def _units(starts, text, work):

    units = []
    for index, (position, heading) in enumerate(starts):
        finish = starts[index + 1][0] if index + 1 < len(starts) else len(text)
        content = clean(text[position:finish])
        if len(content) < 200:
            continue
        units.append({
            "number": len(units) + 1,
            "title": heading[:120] if work["label"] != "Year"
                     else f"{work['label']} {heading.rstrip('.')}",
            "content": content,
        })
    return units


def parse():
    records = []
    for work in WORKS:
        path = cached(work)
        if not path.exists():
            sys.exit(f"REFUSED: {path} missing — run `fetch` first.")
        text = body(path.read_text(encoding="utf-8", errors="replace"), work)
        units = split(text, work)

        if len(units) < work["min_units"]:
            sys.exit(
                f"REFUSED: {work['title'][:50]!r} split into {len(units)} units, "
                f"expected at least {work['min_units']}. A short split means the "
                f"pattern stopped matching, and would file most of the book as "
                f"one unit nobody can cite."
            )

        chars = sum(len(u["content"]) for u in units)
        print(f"  {work['title'][:46]:<46} {len(units):>4} units  {chars:>9,} chars")
        records.append({
            "title": work["title"],
            "date": work["date"],
            "tradition": work["tradition"],
            "kind": work["kind"],
            "author": work["author"],
            "translator": work["translator"],
            "url": f"https://www.gutenberg.org/ebooks/{work['id']}",
            "rights": work["rights"],
            "units": units,
        })

    total_units = sum(len(r["units"]) for r in records)
    total_chars = sum(len(u["content"]) for r in records for u in r["units"])
    UNITS.write_text(json.dumps(records, indent=2, ensure_ascii=False) + "\n",
                     encoding="utf-8")
    print(f"\n{len(records)} works, {total_units:,} units, {total_chars:,} "
          f"characters -> {UNITS}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()
    {"fetch": fetch, "parse": parse}[args.command]()


if __name__ == "__main__":
    main()
