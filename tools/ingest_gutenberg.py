#!/usr/bin/env python3
"""Ingest confessional documents from Project Gutenberg.

Fills the Lutheran gap, which was the last structural blocker for comparative
questions: the corpus held zero Lutheran sources, and the four that claimed to
be Lutheran were the Didache, the Philokalia, Gregory of Nyssa and Peter
Mogila's *Orthodox Confession*.

Why Gutenberg rather than a scan. The archive.org copies are OCR, and the
1851 Google scan renders Augsburg Article I as "Gk)d the Father", "quail*ty"
and "Manichs&ans" — roughly one error per hundred characters. In an app whose
whole purpose is quoting sources accurately that is a regression, not a
shortcut. Gutenberg's texts are proofread transcriptions, and these carry the
Bente and Dau translation prepared for the 1921 *Concordia Triglotta* — the
standard English text, and old enough to be unambiguously public domain.

    python3 tools/ingest_gutenberg.py fetch
    python3 tools/ingest_gutenberg.py parse
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "gutenberg"
UNITS = ROOT / "tools" / "data" / "gutenberg_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)
DELAY_SECONDS = 2.0

# Gutenberg wraps every text in these markers; everything outside is licence
# boilerplate and must not reach the corpus.
START_RE = re.compile(r"\*\*\*\s*START OF TH(?:E|IS) PROJECT GUTENBERG EBOOK.*?\*\*\*", re.I)
END_RE = re.compile(r"\*\*\*\s*END OF TH(?:E|IS) PROJECT GUTENBERG EBOOK.*?\*\*\*", re.I)

CHUNK_TARGET = 2200

# A display unit larger than this is not a citable passage. The Apology's
# thirteen article headings span 658 KB — 48 KB per unit — which reads badly
# and cites worse. Retrieval would cope, since chunking happens underneath,
# but a reader following a citation should land on something they can read.
MAX_UNIT_CHARS = 9000

WORKS = [
    {
        "id": 275,
        "title": "The Augsburg Confession",
        "date": "1530",
        "tradition": "Lutheran",
        "kind": "Confession",
        "unit_re": r"^Article ([IVXLC]+):\s*(.+?)\.?\s*$",
    },
    {
        "id": 6744,
        "title": "The Apology of the Augsburg Confession",
        "date": "1531",
        "tradition": "Lutheran",
        "kind": "Confession",
        # Headings italicise the subject with underscores.
        "unit_re": r"^Article ([IVXLC]+):\s*_?(.+?)_?\.?\s*$",
    },
    {
        "id": 273,
        "title": "The Smalcald Articles",
        "date": "1537",
        "tradition": "Lutheran",
        "kind": "Confession",
        "unit_re": r"^Article ([IVXLC]+)[:.]\s*(.*?)\.?\s*$",
    },
    {
        "id": 1670,
        "title": "Luther's Small Catechism",
        "date": "1529",
        "tradition": "Lutheran",
        "kind": "Catechism",
        # Structured by commandment and article of the creed, not by number.
        "unit_re": r"^(The (?:First|Second|Third|Fourth|Fifth|Sixth|Seventh|"
                   r"Eighth|Ninth|Tenth) (?:Commandment|Article|Petition))\s*$",
    },
]

_ROMAN = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100}


def to_int(value):
    if value.isdigit():
        return int(value)
    total = previous = 0
    for char in reversed(value.upper()):
        current = _ROMAN.get(char, 0)
        total += current if current >= previous else -current
        previous = max(previous, current)
    return total or None


def fetch():
    for work in WORKS:
        path = CACHE / f"{work['id']}.txt"
        if path.exists():
            print(f"  cached  {work['title']} ({path.stat().st_size:,} bytes)")
            continue
        result = subprocess.run(
            ["curl", "-fsSL", "--max-time", "120", "-A", USER_AGENT,
             f"https://www.gutenberg.org/cache/epub/{work['id']}/pg{work['id']}.txt"],
            capture_output=True,
        )
        if result.returncode != 0:
            print(f"  FAILED  {work['title']}: curl exit {result.returncode}",
                  file=sys.stderr)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(result.stdout)
        print(f"  fetched {work['title']} ({len(result.stdout):,} bytes)")
        time.sleep(DELAY_SECONDS)


def body_of(text, work_id):
    """Strip Gutenberg's header and licence footer."""
    start = START_RE.search(text)
    end = END_RE.search(text)
    if not start:
        raise SystemExit(f"{work_id}: no Gutenberg start marker — refusing to ingest")
    return text[start.end(): end.start() if end else len(text)]


def assert_public_domain(text, work_id):
    """Check Gutenberg's own rights statement, and be honest about its scope.

    Gutenberg's statement is collection-level — "nearly all the individual
    works in the collection are in the public domain in the United States" —
    so it is evidence, not a per-work guarantee. The per-work basis here is
    publication date: the confessions themselves are sixteenth century, and
    the English is the Bente and Dau translation prepared for the 1921
    *Concordia Triglotta*, comfortably before the 1929 US cutoff.

    Both halves are recorded against the source so a reader can check the
    reasoning rather than take it on trust.
    """
    if not re.search(r"public domain", text, re.I):
        raise SystemExit(
            f"{work_id}: no public-domain statement anywhere in the file — "
            f"refusing to ingest"
        )
    return ("Public domain in the US: Project Gutenberg collection statement, "
            "and the Bente/Dau translation was published 1921")


def translator_of(text):
    match = re.search(r"Translated by ([^\n]+)", text[:6000])
    if not match:
        return None
    return re.sub(r"\s+", " ", match.group(1)).strip().rstrip(".")


def clean(block):
    paragraphs = [
        re.sub(r"\s+", " ", p).strip()
        for p in re.split(r"\n\s*\n", block)
    ]
    text = "\n\n".join(p for p in paragraphs if len(p) > 1)
    # Gutenberg marks italics with underscores.
    return re.sub(r"_([^_\n]{1,80})_", r"\1", text).strip()


def paragraph_units(body, title):
    """Fallback for works whose headings a pattern cannot capture."""
    units, chunk, size = [], [], 0

    def flush():
        if chunk:
            units.append({
                "number": len(units) + 1,
                "title": f"{title} — part {len(units) + 1}",
                "content": "\n\n".join(chunk),
            })

    for para in [re.sub(r"\s+", " ", p).strip()
                 for p in re.split(r"\n\s*\n", body)]:
        if len(para) < 2:
            continue
        chunk.append(para)
        size += len(para)
        if size >= CHUNK_TARGET:
            flush()
            chunk, size = [], 0
    flush()
    return units


def split_oversized(units):
    """Break units too large to read into paragraph-grouped parts."""
    result = []
    for unit in units:
        if len(unit["content"]) <= MAX_UNIT_CHARS:
            result.append(unit)
            continue

        parts, chunk, size = [], [], 0
        for para in unit["content"].split("\n\n"):
            chunk.append(para)
            size += len(para)
            if size >= MAX_UNIT_CHARS * 0.6:
                parts.append("\n\n".join(chunk))
                chunk, size = [], 0
        if chunk:
            parts.append("\n\n".join(chunk))

        for i, part in enumerate(parts, 1):
            result.append({
                "number": unit["number"],
                "title": f"{unit['title']} ({i} of {len(parts)})",
                "content": part,
            })
    return result


def parse_work(work, text):
    body = body_of(text, work["id"])
    rights = assert_public_domain(text, work["id"])
    translator = translator_of(text)

    marks = list(re.compile(work["unit_re"], re.M).finditer(body))
    units = []

    for i, mark in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(body)
        content = clean(body[mark.end():end])
        if len(content) < 60:
            continue

        groups = mark.groups()
        if len(groups) >= 2 and groups[1]:
            number, subject = to_int(groups[0]), groups[1].strip()
            label = f"Article {groups[0]} — {subject}"
        else:
            number, label = None, groups[0].strip()
        units.append({"number": number, "title": label[:200], "content": content})

    if len(units) < 3:
        print(f"  {work['title']}: {len(units)} heading matches — "
              f"falling back to paragraph chunking", file=sys.stderr)
        units = paragraph_units(body, work["title"])

    units = split_oversized(units)

    return {
        "title": work["title"],
        "date": work["date"],
        "tradition": work["tradition"],
        "kind": work["kind"],
        "url": f"https://www.gutenberg.org/ebooks/{work['id']}",
        "rights": rights,
        "translator": translator,
        "units": units,
    }


def parse():
    records = []
    for work in WORKS:
        path = CACHE / f"{work['id']}.txt"
        if not path.exists():
            print(f"  missing {path} — run fetch first", file=sys.stderr)
            continue
        record = parse_work(work, path.read_text(encoding="utf-8", errors="replace"))
        records.append(record)
        chars = sum(len(u["content"]) for u in record["units"])
        print(f"  {record['title']:<42} {len(record['units']):>4} units  "
              f"{chars:>8,} chars  ({record['translator'] or 'translator not stated'})")

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    UNITS.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
    print(f"\n-> {UNITS}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()
    {"fetch": fetch, "parse": parse}[args.command]()


if __name__ == "__main__":
    main()
