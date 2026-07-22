#!/usr/bin/env python3
"""Ingest the King James Version, to be bundled rather than downloaded.

Scripture is what every tradition in this library is arguing about, so an app
that ships without it starts every conversation missing the text under
discussion. It is also the one body of material that makes the app useful on a
plane before anything has been downloaded.

Source: Project Gutenberg ebook 10, which Gutenberg reports as not in
copyright.

**A caveat worth recording rather than glossing.** The KJV is public domain in
the United States and most of the world, but in the United Kingdom it remains
under perpetual Crown copyright, administered through letters patent held by
Cambridge University Press. Shipping it is normal and widely done; it is not,
strictly, unencumbered everywhere. The licence field says so.

Units are **chapters**, not verses. A verse averages 130 characters, which is
too small to embed meaningfully and too small to read as a citation; a chapter
averages about 3,600, which sits where the rest of the corpus sits and chunks
the same way. Verse numbers are kept inline so a citation can still be located.

    python3 tools/ingest_kjv.py fetch
    python3 tools/ingest_kjv.py parse
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "gutenberg" / "kjv10.txt"
UNITS = ROOT / "tools" / "data" / "kjv_units.json"

URL = "https://www.gutenberg.org/cache/epub/10/pg10.txt"
USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)

START = "*** START OF THE PROJECT GUTENBERG EBOOK"
END = "*** END OF THE PROJECT GUTENBERG EBOOK"

# "1:1 In the beginning God created..."
#
# Deliberately *not* anchored to the start of a line. Verses wrap, and the next
# reference frequently begins mid-line: "of God was, and Samuel was laid down
# to sleep; 3:4 That the LORD called Samuel". Anchoring found 24,995 of the
# 31,102 verses and folded the missing 6,107 into whichever verse preceded
# them — every one of them still readable, and attributed to the wrong verse.
VERSE_RE = re.compile(r"(\d+):(\d+)\s+")

TESTAMENT_RE = re.compile(r"^The (Old|New) Testament of the King James Version")

# Samuel and Kings each carry a two-line heading giving an older alternate
# name, and the names collide across books: "The First Book of the Kings" is
# both the subtitle of 1 Samuel and the title of 1 Kings.
#
# Name alone cannot disambiguate them, so position does. A heading line that
# immediately follows another heading line, with no verses between, is a
# subtitle. Without this the parser found 68 books and mapped four of them
# wrongly — Samuel's text filed under Kings.
# The line that introduces the alternate name. It sits between the two heading
# lines, so it both breaks the "heading immediately follows heading" rule and,
# left alone, is swept into the book's text as though it were scripture.
ALTERNATE_MARKER = "Otherwise Called:"

SUBTITLES = {
    "The First Book of the Kings",
    "The Second Book of the Kings",
    "The Third Book of the Kings",
    "The Fourth Book of the Kings",
}

EXPECTED_BOOKS = 66
EXPECTED_CHAPTERS = 1189
EXPECTED_VERSES = 31102

# How the volume names its books, mapped to the short form a reader expects to
# see on a citation. "The First Book of Moses: Called Genesis" is accurate and
# nobody cites it that way.
SHORT_NAMES = {
    "The First Book of Moses: Called Genesis": "Genesis",
    "The Second Book of Moses: Called Exodus": "Exodus",
    "The Third Book of Moses: Called Leviticus": "Leviticus",
    "The Fourth Book of Moses: Called Numbers": "Numbers",
    "The Fifth Book of Moses: Called Deuteronomy": "Deuteronomy",
    "The Book of Joshua": "Joshua",
    "The Book of Judges": "Judges",
    "The Book of Ruth": "Ruth",
    "The First Book of Samuel": "1 Samuel",
    "The Second Book of Samuel": "2 Samuel",
    "The First Book of the Kings": "1 Kings",
    "The Second Book of the Kings": "2 Kings",
    "The First Book of the Chronicles": "1 Chronicles",
    "The Second Book of the Chronicles": "2 Chronicles",
    "Ezra": "Ezra",
    "The Book of Nehemiah": "Nehemiah",
    "The Book of Esther": "Esther",
    "The Book of Job": "Job",
    "The Book of Psalms": "Psalms",
    "The Proverbs": "Proverbs",
    "Ecclesiastes": "Ecclesiastes",
    "The Song of Solomon": "Song of Solomon",
    "The Book of the Prophet Isaiah": "Isaiah",
    "The Book of the Prophet Jeremiah": "Jeremiah",
    "The Lamentations of Jeremiah": "Lamentations",
    "The Book of the Prophet Ezekiel": "Ezekiel",
    "The Book of Daniel": "Daniel",
    "Hosea": "Hosea",
    "Joel": "Joel",
    "Amos": "Amos",
    "Obadiah": "Obadiah",
    "Jonah": "Jonah",
    "Micah": "Micah",
    "Nahum": "Nahum",
    "Habakkuk": "Habakkuk",
    "Zephaniah": "Zephaniah",
    "Haggai": "Haggai",
    "Zechariah": "Zechariah",
    "Malachi": "Malachi",
    "The Gospel According to Saint Matthew": "Matthew",
    "The Gospel According to Saint Mark": "Mark",
    "The Gospel According to Saint Luke": "Luke",
    "The Gospel According to Saint John": "John",
    "The Acts of the Apostles": "Acts",
    "The Epistle of Paul the Apostle to the Romans": "Romans",
    "The First Epistle of Paul the Apostle to the Corinthians": "1 Corinthians",
    "The Second Epistle of Paul the Apostle to the Corinthians": "2 Corinthians",
    "The Epistle of Paul the Apostle to the Galatians": "Galatians",
    "The Epistle of Paul the Apostle to the Ephesians": "Ephesians",
    "The Epistle of Paul the Apostle to the Philippians": "Philippians",
    "The Epistle of Paul the Apostle to the Colossians": "Colossians",
    "The First Epistle of Paul the Apostle to the Thessalonians":
        "1 Thessalonians",
    "The Second Epistle of Paul the Apostle to the Thessalonians":
        "2 Thessalonians",
    "The First Epistle of Paul the Apostle to Timothy": "1 Timothy",
    "The Second Epistle of Paul the Apostle to Timothy": "2 Timothy",
    "The Epistle of Paul the Apostle to Titus": "Titus",
    "The Epistle of Paul the Apostle to Philemon": "Philemon",
    "The Epistle of Paul the Apostle to the Hebrews": "Hebrews",
    "The General Epistle of James": "James",
    "The First Epistle General of Peter": "1 Peter",
    "The Second General Epistle of Peter": "2 Peter",
    "The First Epistle General of John": "1 John",
    "The Second Epistle General of John": "2 John",
    "The Third Epistle General of John": "3 John",
    "The General Epistle of Jude": "Jude",
    "The Revelation of Saint John the Divine": "Revelation",
}


def fetch():
    if CACHE.exists():
        print(f"cached {CACHE}")
        return
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["curl", "-fsSL", "--max-time", "300", "-A", USER_AGENT, URL,
         "-o", str(CACHE)], capture_output=True)
    if result.returncode != 0:
        sys.exit(f"fetch failed: curl exit {result.returncode}")
    print(f"fetched {CACHE}")


def body_of(text):
    """Strip the Gutenberg wrapper and the table of contents.

    The book names appear twice: once as a contents list and again as headings
    over the text. Splitting on the first verse separates them, and it does so
    without needing to guess how long the contents run.
    """
    start = text.index("\n", text.index(START)) + 1
    body = text[start:text.index(END)]

    match = re.search(r"^1:1\s", body, re.M)
    if match is None:
        sys.exit("REFUSED: no verses found")

    # The body starts at the last book heading that appears before the first
    # verse. Backing up by blank lines instead lands *after* that heading, so
    # the first book's verses arrive with no book open — which failed loudly,
    # but only because nothing was accumulating them.
    heading_start = max(
        (body.rfind(f"\n{name}\n", 0, match.start()) for name in SHORT_NAMES),
        default=-1,
    )
    if heading_start < 0:
        sys.exit("REFUSED: no book heading found before the first verse")
    return body[heading_start:]


def parse(text):
    """Group verses into one unit per chapter.

    Works on each book's text as a whole rather than line by line, because
    verse references do not reliably begin lines.
    """
    books = []
    current, lines, after_heading = None, [], False

    def close_book():
        if current is not None:
            books.append((current, " ".join(lines)))

    for raw in body_of(text).splitlines():
        line = raw.strip()
        if not line or TESTAMENT_RE.match(line):
            continue

        if line == ALTERNATE_MARKER:
            continue

        if line in SHORT_NAMES:
            if after_heading and line in SUBTITLES:
                continue
            close_book()
            current, lines = SHORT_NAMES[line], []
            after_heading = True
            continue

        after_heading = False
        lines.append(line)

    close_book()

    units, sequence, total_verses = [], 0, 0
    for book, body in books:
        chapters = {}
        matches = list(VERSE_RE.finditer(body))
        for index, match in enumerate(matches):
            stop = matches[index + 1].start() if index + 1 < len(matches) \
                else len(body)
            content = " ".join(body[match.end():stop].split())
            if not content:
                continue
            chapter, verse = int(match.group(1)), int(match.group(2))
            chapters.setdefault(chapter, []).append(f"{verse}. {content}")
            total_verses += 1

        for chapter in sorted(chapters):
            sequence += 1
            units.append({
                "number": sequence,
                "title": f"{book} {chapter}",
                "content": "\n".join(chapters[chapter]),
            })

    # Asserted rather than reported. A parser that silently drops a book still
    # produces a plausible Bible, and "plausible" is exactly the failure this
    # corpus keeps having to undo.
    if len(books) != EXPECTED_BOOKS:
        sys.exit(f"REFUSED: {len(books)} books, expected {EXPECTED_BOOKS}")
    if len(units) != EXPECTED_CHAPTERS:
        sys.exit(f"REFUSED: {len(units)} chapters, expected {EXPECTED_CHAPTERS}")
    if total_verses != EXPECTED_VERSES:
        sys.exit(f"REFUSED: {total_verses} verses, expected {EXPECTED_VERSES}")

    print(f"{len(books)} books, {len(units)} chapters, {total_verses} verses, "
          f"{sum(len(u['content']) for u in units) / 1e6:.2f} M chars")
    return units


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()

    if args.command == "fetch":
        fetch()
        return

    if not CACHE.exists():
        sys.exit(f"Missing {CACHE}. Run `fetch` first.")

    units = parse(CACHE.read_text(encoding="utf-8", errors="replace"))

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    with open(UNITS, "w") as handle:
        json.dump([{
            "title": "The Holy Bible: King James Version",
            "date": "1611",
            "tradition": "Scripture",
            "kind": "Scripture",
            "url": "https://www.gutenberg.org/ebooks/10",
            "rights": "Public domain in the United States; Crown copyright in "
                      "the United Kingdom",
            "collection": "Project Gutenberg",
            "editor": "",
            "units": units,
        }], handle, indent=2)
        handle.write("\n")
    print(f"Wrote {UNITS}")


if __name__ == "__main__":
    main()
