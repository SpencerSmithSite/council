#!/usr/bin/env python3
"""Ingest confessional documents from CCEL text exports.

Fills the corpus's largest hole. Every non-patristic source currently in the
database is unprovenanced paraphrase left over from the generated corpus —
Reformed 7/7, Lutheran 4/4, Catholic 4/4, Anglican 2/2, Methodist 1/1 have no
`source_url`, author or translator. A comparative question like "how do
Catholics and Lutherans differ on baptism?" therefore cannot be answered from
anything trustworthy.

Source: CCEL's plain-text exports, which carry `Rights: Public Domain` in their
own metadata header — verified per work rather than assumed, and asserted here
before anything is ingested.

Deliberately NOT used: Schaff's *Creeds of Christendom*, despite carrying most
of these documents in one place. CCEL's text export linearizes Schaff's
parallel Latin/English columns badly, running one straight into the other
mid-sentence ("...colatur et servetur Most Invincible Emperor, Caesar
Augustus..."). Ingesting that would produce passages no reader could use and
no model could cite.

    python3 tools/ingest_ccel.py fetch
    python3 tools/ingest_ccel.py parse
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "ccel"
UNITS = ROOT / "tools" / "data" / "ccel_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)

# CCEL's robots.txt sets Crawl-delay: 10 for '*'. Honour it. There are only a
# handful of works here, and each is one request for the whole text.
DELAY_SECONDS = 10.0

RULE = "_" * 20

# Works to ingest, and the documents to carve out of each.
#
# `tradition` and `kind` map onto the existing traditions / source_types rows.
WORKS = [
    {
        "id": "hstcrcon",
        "url": "https://www.ccel.org/ccel/brannan/hstcrcon/cache/hstcrcon.txt",
        "documents": [
            {
                "start": "The Heidelberg Catechism",
                "title": "The Heidelberg Catechism",
                "date": "1563",
                "tradition": "Reformed",
                "kind": "Catechism",
                "unit_re": r"^\s*Question (\d+)\s*$",
            },
            {
                "start": "The Canons of Dordt",
                "title": "The Canons of Dordt",
                "date": "1619",
                "tradition": "Reformed",
                "kind": "Confession",
                "unit_re": r"^\s*Article (\d+)\s*$",
            },
            {
                "start": "The Belgic Confession",
                "title": "The Belgic Confession",
                "date": "1561",
                "tradition": "Reformed",
                "kind": "Confession",
                # The Belgic numbers its articles in Roman numerals and follows
                # each with a subtitle line.
                "unit_re": r"^\s*Article ([IVXLC]+)\s*$",
                "subtitle": True,
            },
        ],
        "end": "Indexes",
    },
]


def fetch_one(url, path):
    if path.exists():
        return True, 0
    result = subprocess.run(
        ["curl", "-fsSL", "--max-time", "120", "-A", USER_AGENT, url],
        capture_output=True,
    )
    if result.returncode != 0:
        return False, result.returncode
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(result.stdout)
    return True, 0


def fetch():
    for work in WORKS:
        path = CACHE / f"{work['id']}.txt"
        cached = path.exists()
        ok, code = fetch_one(work["url"], path)
        if not ok:
            print(f"  FAILED {work['id']}: curl exit {code}", file=sys.stderr)
            continue
        print(f"  {'cached' if cached else 'fetched'} {work['id']} "
              f"({path.stat().st_size:,} bytes)")
        if not cached:
            time.sleep(DELAY_SECONDS)


def assert_public_domain(text, work_id):
    """CCEL states rights in the export header. Do not ingest without it."""
    header = text[:1500]
    match = re.search(r"Rights:\s*(.+)", header)
    rights = match.group(1).strip() if match else "(absent)"
    if "public domain" not in rights.lower():
        raise SystemExit(
            f"{work_id}: rights are '{rights}', not public domain — refusing "
            f"to ingest."
        )
    return rights


_ROMAN = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100}


def _to_int(value):
    """Article numbers appear as arabic in some documents, roman in others."""
    if value.isdigit():
        return int(value)
    total = previous = 0
    for char in reversed(value.upper()):
        current = _ROMAN.get(char, 0)
        total += current if current >= previous else -current
        previous = max(previous, current)
    return total


def clean(block):
    """CCEL indents body text; footnote markers are bracketed numerals."""
    lines = []
    for line in block.split("\n"):
        line = line.strip()
        if not line or line.startswith(RULE):
            continue
        # Drop standalone footnote bodies: "[384] Schaff, Creeds, Vol I..."
        if re.match(r"^\[\d+\]", line):
            continue
        lines.append(line)

    text = " ".join(lines)
    text = re.sub(r"\[\d+\]", "", text)          # inline footnote refs
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def carve(text, document, next_start, work_end):
    """Extract one document's units from the work's text."""
    # The title appears in the TOC as well as at the document itself; take the
    # last occurrence before the following document begins.
    bound = text.find(next_start) if next_start else text.find(work_end)
    if bound < 0:
        bound = len(text)

    occurrences = [m.start() for m in re.finditer(re.escape(document["start"]), text[:bound])]
    if not occurrences:
        return []
    body = text[occurrences[-1]:bound]

    unit_re = re.compile(document["unit_re"], re.M)
    marks = list(unit_re.finditer(body))
    if not marks:
        return []

    units = []
    for i, mark in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(body)
        raw = body[mark.end():end]

        # Only where the document actually carries a subtitle line under the
        # number ("Article I" / "There Is Only One God"). Applying this
        # everywhere silently ate the first line of each Heidelberg answer.
        subtitle = None
        if document.get("subtitle"):
            first, _, rest = raw.lstrip("\n").partition("\n")
            first = first.strip()
            if first and len(first) < 80 and not first.endswith("."):
                subtitle = first
                raw = rest

        content = clean(raw)
        if len(content) < 40:
            continue

        label = mark.group(0).strip()
        units.append({
            "number": _to_int(mark.group(1)),
            "title": f"{label} — {subtitle}" if subtitle else label,
            "content": content,
        })
    return units


def parse():
    records = []
    for work in WORKS:
        path = CACHE / f"{work['id']}.txt"
        if not path.exists():
            print(f"  missing {path} — run fetch first", file=sys.stderr)
            continue

        text = path.read_text(encoding="utf-8", errors="replace")
        rights = assert_public_domain(text, work["id"])

        title_match = re.search(r"Title:\s*(.+)", text[:1500])
        editor_match = re.search(r"Creator\(s\):\s*(.+)", text[:1500])
        collection = title_match.group(1).strip() if title_match else work["id"]
        editor = editor_match.group(1).strip() if editor_match else None

        docs = work["documents"]
        for i, document in enumerate(docs):
            next_start = docs[i + 1]["start"] if i + 1 < len(docs) else None
            units = carve(text, document, next_start, work["end"])
            if not units:
                print(f"  WARNING: no units for {document['title']}", file=sys.stderr)
                continue

            records.append({
                "title": document["title"],
                "date": document["date"],
                "tradition": document["tradition"],
                "kind": document["kind"],
                "url": work["url"],
                "rights": rights,
                "collection": collection,
                "editor": editor,
                "units": units,
            })
            chars = sum(len(u["content"]) for u in units)
            print(f"  {document['title']:<28} {len(units):>4} units  "
                  f"{chars:>7,} chars")

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
