#!/usr/bin/env python3
"""Ingest the Westminster catechisms and the Thirty-Nine Articles.

These are three of the 23 sources that still carry no `source_url`. Their
wording is genuine but heavily abridged — the Westminster Confession stub holds
4,157 characters where the document runs to some 35,000 words — and with no
recorded origin nobody can check any of it against a published edition.

Each source here was verified before being accepted, not assumed:

* **Westminster Shorter and Larger Catechisms** — CCEL, which declares
  `Rights: Public Domain` in the text export's own header.

* **Thirty-Nine Articles** — from the 1662 Book of Common Prayer on Project
  Gutenberg, which carries the Articles complete as agreed in Convocation in
  1562. Gutenberg reports the volume as not in copyright.

**The Westminster Confession was looked for and deliberately rejected.** CCEL's
edition (`anonymous/westminster3`) is a critical apparatus carrying the PCUS and
UPCUSA recensions in parallel, with variant readings inline:

    yet [PCUS are they] [UPCUSA they are] not sufficient

That is careful scholarship and unusable here — it is the same defect that
disqualified Schaff's *Creeds of Christendom*, and the standard has to hold in
both cases. It also, alone among the three CCEL files, declares no rights at
all. The Confession stays unprovenanced until a clean edition is found.

    python3 tools/ingest_standards.py fetch
    python3 tools/ingest_standards.py parse
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache"
UNITS = ROOT / "tools" / "data" / "standards_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)

# CCEL's robots.txt sets Crawl-delay: 10 for '*'. Honour it.
DELAY_SECONDS = 10.0

SOURCES = [
    {
        "cache": "ccel/westminster1.txt",
        "url": "https://www.ccel.org/ccel/anonymous/westminster1/cache/westminster1.txt",
        "title": "The Westminster Shorter Catechism",
        "date": "1647",
        "tradition": "Reformed",
        "kind": "Catechism",
        "collection": "Christian Classics Ethereal Library",
        "rights": "Public Domain",
        "parser": "catechism",
    },
    {
        "cache": "ccel/westminster2.txt",
        "url": "https://www.ccel.org/ccel/anonymous/westminster2/cache/westminster2.txt",
        "title": "The Westminster Larger Catechism",
        "date": "1647",
        "tradition": "Reformed",
        "kind": "Catechism",
        "collection": "Christian Classics Ethereal Library",
        "rights": "Public Domain",
        "parser": "catechism",
    },
    {
        "cache": "gutenberg/bcp29622.txt",
        "url": "https://www.gutenberg.org/cache/epub/29622/pg29622.txt",
        "title": "The Thirty-Nine Articles of Religion",
        "date": "1562",
        "tradition": "Anglican",
        "kind": "Confession",
        "collection": "The Book of Common Prayer (Project Gutenberg 29622)",
        "rights": "Public domain in the United States",
        "parser": "articles",
    },
]

# The two catechisms are marked up differently, and the Shorter is not even
# internally consistent: it numbers most questions "Q1:" but seven of them
# "Q20." with a period. Matching only the colon form silently dropped questions
# 20 and 39-44 — including the covenant of grace — and produced a plausible
# 100-question file that simply was not the Shorter Catechism.
QUESTION_RE = re.compile(r"^\s*(?:Q|Question\s*)(\d+)\s*[:.]\s*(.*)$")
ANSWER_RE = re.compile(r"^\s*(?:A|Answer)\s*(\d*)\s*[:.]\s*(.*)$")

# "I. _Of Faith in the Holy Trinity_." — a Roman numeral, then an italicised
# title in Gutenberg's underscore convention.
#
# Matched across newlines because three of the thirty-nine titles wrap onto a
# second line, and a line-anchored pattern silently skipped exactly those three
# (24, 26 and 29) while producing a clean-looking file of thirty-six.
ARTICLE_RE = re.compile(r"^([IVXL]+)\.[ \t]+_(.+?)_\.", re.M | re.S)

ROMAN = {
    "I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000,
}


def clean(text):
    """Normalise whitespace and drop Gutenberg's underscore emphasis markers.

    Gutenberg marks italics as _like this_, which is invisible in a printed
    book and reads as stray punctuation in an app. Article 6 carries the list
    of canonical books under an italic sub-heading, so the markers appear in
    the middle of real content rather than only around titles.
    """
    return " ".join(re.sub(r"_([^_\n]+)_", r"\1", text).split())


def roman_to_int(value):
    total, previous = 0, 0
    for char in reversed(value):
        current = ROMAN[char]
        total += current if current >= previous else -current
        previous = max(previous, current)
    return total


def fetch(source):
    path = CACHE / source["cache"]
    if path.exists():
        print(f"  cached   {source['title']}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    print(f"  fetching {source['title']}")
    result = subprocess.run(
        ["curl", "-fsSL", "--max-time", "180", "-A", USER_AGENT,
         source["url"], "-o", str(path)],
        capture_output=True,
    )
    if result.returncode != 0:
        sys.exit(f"FAILED {source['title']}: curl exit {result.returncode}")
    time.sleep(DELAY_SECONDS)


def assert_rights(source, text):
    """Refuse anything that does not declare its rights where we expect them.

    CCEL puts `Rights:` in a header block. Checking it per work rather than
    trusting the collection is what caught the Westminster Confession export,
    which declares nothing at all.
    """
    if "ccel" not in source["cache"]:
        return
    header = text[:2000]
    if "Rights: Public Domain" not in header:
        sys.exit(
            f"REFUSED {source['title']}: no public-domain declaration in the "
            f"CCEL header. Do not ingest what has not stated its terms."
        )


def parse_catechism(text):
    """Pair each numbered question with its answer.

    Questions and answers are separate paragraphs and either may wrap over
    several lines, so lines are accumulated into whichever of the two is open.
    """
    units, number, question, answer, mode = [], None, [], [], None

    def flush():
        if number is None:
            return
        q = clean(" ".join(question))
        a = clean(" ".join(answer))
        if q and a:
            units.append({
                "number": number,
                "title": f"Question {number}",
                "content": f"{q}\n\n{a}",
            })

    for line in text.splitlines():
        q_match = QUESTION_RE.match(line)
        if q_match:
            flush()
            number = int(q_match.group(1))
            question, answer = [q_match.group(2)], []
            mode = "q"
            continue

        a_match = ANSWER_RE.match(line)
        if a_match:
            answer = [a_match.group(2)]
            mode = "a"
            continue

        stripped = line.strip()
        # CCEL separates sections with a rule of underscores. It is a page
        # ornament, and appended to the last answer on a page it reads as
        # corruption of the text.
        if not stripped or mode is None or set(stripped) == {"_"}:
            continue
        (question if mode == "q" else answer).append(stripped)

    flush()
    assert_complete(units)
    return units


def assert_complete(units):
    """Refuse a document with holes in its numbering.

    A catechism that parses cleanly and is missing seven questions looks
    entirely correct from the outside — the count is plausible, every unit is
    well-formed, and nothing errors. Only the numbering shows it.
    """
    numbers = [u["number"] for u in units]
    if not numbers:
        return
    expected = set(range(min(numbers), max(numbers) + 1))
    missing = sorted(expected - set(numbers))
    if missing:
        sys.exit(
            f"REFUSED: gaps in numbering at {missing[:12]}"
            f"{'...' if len(missing) > 12 else ''} — the parser is not "
            f"matching every question in this file."
        )


def parse_articles(text):
    """Carve the Articles of Religion out of the prayer book.

    The Articles are one section of a 1.2 MB volume, so the section is bounded
    first: article numbering restarts elsewhere in the book, and matching the
    pattern across the whole file would collect psalm headings and rubrics.

    Each article's text is the span between its own heading and the next, which
    handles wrapped titles without needing to reason about line breaks.
    """
    start = text.find("ARTICLES OF RELIGION")
    if start < 0:
        sys.exit("REFUSED Thirty-Nine Articles: section heading not found")

    end = text.find("THE RATIFICATION", start)
    body = text[start:end if end > 0 else len(text)]

    matches = list(ARTICLE_RE.finditer(body))
    units = []
    for index, match in enumerate(matches):
        stop = matches[index + 1].start() if index + 1 < len(matches) else len(body)
        content = clean(body[match.end():stop])
        if not content:
            continue
        units.append({
            "number": roman_to_int(match.group(1)),
            "title": f"Article {roman_to_int(match.group(1))}. "
                     f"{clean(match.group(2))}",
            "content": content,
        })

    assert_complete(units)
    if len(units) != 39:
        sys.exit(f"REFUSED Thirty-Nine Articles: parsed {len(units)}, not 39")
    return units


PARSERS = {"catechism": parse_catechism, "articles": parse_articles}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()

    if args.command == "fetch":
        for source in SOURCES:
            fetch(source)
        return

    documents = []
    for source in SOURCES:
        path = CACHE / source["cache"]
        if not path.exists():
            sys.exit(f"Missing {path}. Run `fetch` first.")

        text = path.read_text(encoding="utf-8", errors="replace")
        assert_rights(source, text)
        units = PARSERS[source["parser"]](text)

        chars = sum(len(u["content"]) for u in units)
        print(f"{source['title']:42} {len(units):4} units  {chars:7} chars")
        if not units:
            sys.exit(f"REFUSED {source['title']}: parsed nothing")

        documents.append({
            "title": source["title"],
            "date": source["date"],
            "tradition": source["tradition"],
            "kind": source["kind"],
            "url": source["url"],
            "rights": source["rights"],
            "collection": source["collection"],
            "editor": "",
            "units": units,
        })

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    with open(UNITS, "w") as handle:
        json.dump(documents, handle, indent=2)
        handle.write("\n")
    print(f"\nWrote {UNITS}")


if __name__ == "__main__":
    main()
