#!/usr/bin/env python3
"""Ingest 1 Enoch — canon in the Ethiopian and Eritrean Tewahedo churches.

The corpus's rule is to hold what a tradition actually receives as scripture,
and by that rule 1 Enoch was a gap rather than an omission: it is fully
canonical in the Ethiopian Orthodox Tewahedo and Eritrean Orthodox Tewahedo
churches, and the corpus had no Oriental Orthodox content at all. Note that
this is the same pass that removed the New Testament apocrypha — the two are
not in tension. Those were received by no one; this is scripture to a church of
tens of millions.

Why this edition. R. H. Charles' translation for the SPCK, London 1917, is the
standard English text and pre-1929, so unambiguously public domain in the US.
Project Gutenberg #77935 is a proofread transcription produced by Distributed
Proofreaders, not OCR — the same reason `ingest_gutenberg.py` prefers Gutenberg
to the archive.org scans, whose error rate is around one per hundred characters
and which have no place in an app built to quote accurately.

**The Book of Jubilees is deliberately not here.** It has the same canonical
standing in both Tewahedo churches and belongs in the corpus on the same
reasoning, but there is no proofread public-domain transcription of Charles'
1902 translation: Gutenberg has no edition of it under any title, and the
archive.org copies are OCR. Ingesting those would import exactly the class of
defect that got eight works deleted in the earlier prune. It stays a named gap
until a clean text exists.

What is ingested: chapters I–CVIII, the text only. Charles' introduction is his
own scholarship rather than the document, so it is left out, as the corpus
leaves out every other editor's apparatus.

Two normalisations, both recorded because they alter quoted text:

  * Gutenberg's `=emphasis=` markers are stripped. They encode the print
    edition's bold and are markup, not words.
  * Charles' own editorial apparatus is preserved as written — `〚 〛` for
    interpolations, `⌜ ⌝` for emendations, `† †` around corrupt text. These are
    part of a critical edition and dropping them would silently present
    conjecture as text.

    python3 tools/ingest_enoch.py fetch
    python3 tools/ingest_enoch.py parse
"""

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "enoch"
UNITS = ROOT / "tools" / "data" / "enoch_units.json"

EBOOK = 77935
TEXT_URL = f"https://www.gutenberg.org/ebooks/{EBOOK}.txt.utf-8"
CACHED = CACHE / f"{EBOOK}.txt"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)

# Gutenberg wraps every text in these; everything outside is licence
# boilerplate and must not reach the corpus.
START = re.compile(r"^\*\*\* START OF THE PROJECT GUTENBERG EBOOK.*$", re.M)
END = re.compile(r"^\*\*\* END OF THE PROJECT GUTENBERG EBOOK.*$", re.M)

# The printer's colophon closes the book. Anything after it is not Enoch.
COLOPHON = re.compile(r"^PRINTED IN GREAT BRITAIN", re.M)

# A Roman numeral opening a line, indented or not. Anchored to line start so a
# cross-reference mid-sentence cannot match.
#
# This matches more than chapter openings, and is meant to — the edition opens
# a chapter in three different shapes, and taking the first occurrence of each
# numeral in sequence resolves all of them:
#
#   XXIV. 1. And from thence…            the ordinary case
#   XXIV. XXV. _The Seven Mountains…_    a heading naming the chapters it spans
#   XXXVIII. _The Coming Judgement…_     heading only; the text opens at "1."
#
# Indentation has to be allowed because of a fourth: where the witnesses
# diverge, Charles prints the Ethiopic and Greek recensions in parallel under
# sigla (E, G^g) and indents both. Chapter XXXII exists *only* in that form, so
# anchoring hard to column zero loses it. The consequence is that such a
# chapter's span holds both recensions, which is what the printed page holds.
CHAPTER = re.compile(r"^[ \t]*([IVXLCDM]+)\.", re.M)

ROMAN = {
    "I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000,
}

EXPECTED_CHAPTERS = 108


def roman_to_int(s):
    total = prev = 0
    for ch in reversed(s):
        value = ROMAN[ch]
        total = total - value if value < prev else total + value
        prev = max(prev, value)
    return total


def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    if CACHED.exists():
        print(f"cached  {CACHED} ({CACHED.stat().st_size:,} bytes)")
        return
    request = urllib.request.Request(TEXT_URL, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    CACHED.write_bytes(data)
    print(f"fetched {TEXT_URL} -> {CACHED} ({len(data):,} bytes)")


def body(text):
    """The book itself: inside Gutenberg's markers, before the colophon."""
    start = START.search(text)
    end = END.search(text)
    if not start or not end:
        sys.exit("REFUSED: Gutenberg start/end markers not found — the "
                 "boilerplate would be ingested as scripture.")
    text = text[start.end():end.start()]

    colophon = COLOPHON.search(text)
    if colophon:
        text = text[:colophon.start()]

    # Charles' introduction runs until the text proper opens at "I. 1.".
    first = re.search(r"^I\.\s1\.\s", text, re.M)
    if not first:
        sys.exit("REFUSED: could not find the opening of chapter I.")
    return text[first.start():]


def clean(chunk):
    """One chapter's prose, rewrapped, with Gutenberg's markup removed.

    Order matters: the text is hard-wrapped, so an `=emphasised phrase=` is
    routinely split across two lines and a same-line pattern misses it. Join
    the lines first, strip the markup second.
    """
    chunk = re.sub(r"\[\d+\]", "", chunk)          # footnote anchors
    # Paragraphs are blank-line separated; lines inside one are hard-wrapped.
    paragraphs = [
        " ".join(line.strip() for line in para.strip().splitlines())
        for para in re.split(r"\n\s*\n", chunk) if para.strip()
    ]
    # Drop running heads: section lines of numerals and rules carrying no prose.
    paragraphs = [p for p in paragraphs if not re.fullmatch(r"[IVXLCDM\-–. _]+", p)]
    text = "\n\n".join(p for p in paragraphs if p).strip()
    return re.sub(r"=([^=]+)=", r"\1", text)       # print bold, not words


def parse():
    text = CACHED.read_text(encoding="utf-8")
    text = body(text)

    # First appearance of each numeral wins; later ones are back-references.
    first = {}
    for mark in CHAPTER.finditer(text):
        value = roman_to_int(mark.group(1))
        if 1 <= value <= EXPECTED_CHAPTERS and value not in first:
            first[value] = (mark.group(1), mark.start())

    absent = [n for n in range(1, EXPECTED_CHAPTERS + 1) if n not in first]
    if absent:
        sys.exit(f"REFUSED: chapters {absent} not found. The chapter split has "
                 f"broken; nothing written.")

    # Ordered by position, not by number — and those differ. Charles restores
    # what he takes to be the original sequence of the Apocalypse of Weeks, so
    # the edition runs XC, XCII, XCI, XCIII, with XCI. 12-17 printed after
    # XCIII. Renumbering that into arithmetic order would silently undo an
    # editorial decision the whole edition is built on, so reading order is the
    # page's order and the numeral stays in the title.
    starts = sorted(((position, numeral, value)
                     for value, (numeral, position) in first.items()))

    units = []
    for index, (position, numeral, _) in enumerate(starts):
        finish = starts[index + 1][0] if index + 1 < len(starts) else len(text)
        content = clean(text[position:finish])
        if not content:
            sys.exit(f"REFUSED: chapter {numeral} parsed as empty.")
        units.append({
            "number": index + 1,
            "title": f"Chapter {numeral}",
            "content": content,
        })

    if len(units) != EXPECTED_CHAPTERS:
        sys.exit(f"REFUSED: parsed {len(units)} chapters, expected "
                 f"{EXPECTED_CHAPTERS}. 1 Enoch is I–CVIII; a short parse "
                 f"means the chapter split broke.")

    total = sum(len(u["content"]) for u in units)
    work = {
        "title": "The Book of Enoch (1 Enoch)",
        "date": "c. 300 BC – 100 BC",
        "tradition": "Oriental Orthodox",
        "kind": "Scripture",
        "url": f"https://www.gutenberg.org/ebooks/{EBOOK}",
        "rights": (
            "Public domain in the US: R. H. Charles' translation, "
            "Society for Promoting Christian Knowledge, London 1917, "
            "via Project Gutenberg's proofread transcription"
        ),
        "translator": "R. H. Charles",
        "author": "Anonymous",
        "units": units,
    }

    UNITS.write_text(json.dumps([work], indent=2, ensure_ascii=False) + "\n",
                     encoding="utf-8")
    print(f"{len(units)} chapters, {total:,} characters -> {UNITS}")
    print(f"  first: {units[0]['title']}  {units[0]['content'][:70]}…")
    print(f"  last:  {units[-1]['title']}  {units[-1]['content'][:70]}…")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()
    {"fetch": fetch, "parse": parse}[args.command]()


if __name__ == "__main__":
    main()
