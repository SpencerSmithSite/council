#!/usr/bin/env python3
"""Ingest the actual decrees of the Council of Trent.

The corpus already has a "Council of Trent" source, but it is seven units of
unprovenanced paraphrase — accurate as far as it goes ("If anyone says that the
sinner is justified by faith alone…" is a fair rendering of Canon 9) but not
the decree, with no source or translator. That made the Catholic half of every
Catholic-vs-Protestant comparison paraphrase while the Protestant half was
primary text.

This replaces it with Waterworth's 1848 translation (archive.org scan of the
1888 reprint), the standard English text and long out of copyright.

The scan is OCR, but clean OCR — a garble check over the body found no obvious
errors, unlike the 1851 Book of Concord scan that was rejected for one error
per hundred characters. The one systematic artifact is doubled spaces from
column justification, which normalises trivially.

    python3 tools/ingest_trent.py fetch
    python3 tools/ingest_trent.py parse
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "trent"
UNITS = ROOT / "tools" / "data" / "trent_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)
DELAY_SECONDS = 5.0

IDENTIFIER = "thecanonsanddecr00unknuoft"
URL = f"https://archive.org/download/{IDENTIFIER}/{IDENTIFIER}_djvu.txt"

# The doctrinal sessions worth carving into their own units. The council also
# passed disciplinary decrees on residence, benefices and so on; those matter
# far less for the questions this app answers, so the ingest focuses on
# doctrine and lets a session's decree stand as one unit each.
#
# Each session's body begins at its unique "SESSION THE <N>," line (the
# editorial preface numbers its chapters differently, so there is no clash).
SESSION_WORDS = [
    "FIRST", "SECOND", "THIRD", "FOURTH", "FIFTH", "SIXTH", "SEVENTH",
    "EIGHTH", "NINTH", "TENTH", "ELEVENTH", "TWELFTH", "THIRTEENTH",
    "FOURTEENTH", "FIFTEENTH", "SIXTEENTH", "SEVENTEENTH", "EIGHTEENTH",
    "NINETEENTH", "TWENTIETH", "TWENTY-FIRST", "TWENTY-SECOND",
    "TWENTY-THIRD", "TWENTY-FOURTH", "TWENTY-FIFTH",
]

# Doctrinal decrees, by the session that issued them, for readable unit titles.
SESSION_TOPICS = {
    "FOURTH": "On the Canonical Scriptures",
    "FIFTH": "On Original Sin",
    "SIXTH": "On Justification",
    "SEVENTH": "On the Sacraments in General",
    "THIRTEENTH": "On the Eucharist",
    "FOURTEENTH": "On Penance and Extreme Unction",
    "TWENTY-SECOND": "On the Sacrifice of the Mass",
    "TWENTY-THIRD": "On the Sacrament of Order",
    "TWENTY-FOURTH": "On the Sacrament of Matrimony",
    "TWENTY-FIFTH": "On Purgatory and the Veneration of Saints",
}

MAX_UNIT_CHARS = 9000


def fetch():
    path = CACHE / f"{IDENTIFIER}.txt"
    if path.exists():
        print(f"  cached  ({path.stat().st_size:,} bytes)")
        return
    result = subprocess.run(
        ["curl", "-fsSL", "--max-time", "180", "-A", USER_AGENT, URL],
        capture_output=True,
    )
    if result.returncode != 0:
        print(f"  FAILED: curl exit {result.returncode}", file=sys.stderr)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(result.stdout)
    print(f"  fetched ({len(result.stdout):,} bytes)")
    time.sleep(DELAY_SECONDS)


def assert_public_domain(text):
    """archive.org states no rights; the basis is the 1888 publication date."""
    marker = "public domain" in text[:4000].lower()
    return ("Public domain: Waterworth translation, 1848; this scan is the "
            "1888 reprint" + (" (archive.org marks the item public domain)"
                              if marker else ""))


def normalise(block):
    text = re.sub(r"[ \t]{2,}", " ", block)
    # Drop running heads and page numbers left in the OCR stream.
    text = re.sub(r"\n\s*\d+\s+SESSION [IVXL]+\.?\s*\n", "\n", text)
    text = re.sub(r"\n\s*SESSION [IVXL]+\.?\s+\d+\s*\n", "\n", text)
    paragraphs = [re.sub(r"\s+", " ", p).strip()
                  for p in re.split(r"\n\s*\n", text)]
    return "\n\n".join(p for p in paragraphs if len(p) > 1).strip()


def split_oversized(units):
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


def parse():
    path = CACHE / f"{IDENTIFIER}.txt"
    if not path.exists():
        print(f"  missing {path} — run fetch first", file=sys.stderr)
        return

    original = path.read_text(encoding="utf-8", errors="replace")
    rights = assert_public_domain(original)

    # Collapse the OCR's doubled spaces *before* anchoring. The column
    # justification puts them inside the headings too — the file reads
    # "SESSION  THE  FOURTH", so a pattern written against normal spacing
    # matches nothing at all.
    raw = re.sub(r"[ \t]+", " ", original)

    # Body-session offsets: the line "SESSION THE <N>," on its own. Only
    # doctrinal sessions are kept.
    starts = {}
    for word in SESSION_WORDS:
        match = re.search(rf"^ ?SESSION THE {word}[,.]?\s*$", raw, re.M)
        if match:
            starts[word] = match.start()

    ordered = sorted(starts.items(), key=lambda kv: kv[1])
    units = []
    for i, (word, start) in enumerate(ordered):
        if word not in SESSION_TOPICS:
            continue
        end = ordered[i + 1][1] if i + 1 < len(ordered) else len(raw)
        content = normalise(raw[start:end])
        if len(content) < 200:
            continue
        number = SESSION_WORDS.index(word) + 1
        units.append({
            "number": number,
            "title": f"Session {number} — {SESSION_TOPICS[word]}",
            "content": content,
        })

    units = split_oversized(units)

    record = {
        "title": "The Canons and Decrees of the Council of Trent",
        "date": "1545-1563",
        "tradition": "Catholic",
        "kind": "Council",
        "url": f"https://archive.org/details/{IDENTIFIER}",
        "rights": rights,
        "translator": "J. Waterworth",
        "units": units,
    }

    chars = sum(len(u["content"]) for u in units)
    print(f"  {record['title'][:44]:<46} {len(units):>4} units  {chars:>8,} chars")
    for u in units[:4]:
        print(f"      {u['title']}")

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    UNITS.write_text(json.dumps([record], indent=2) + "\n", encoding="utf-8")
    print(f"\n-> {UNITS}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()
    {"fetch": fetch, "parse": parse}[args.command]()


if __name__ == "__main__":
    main()
