#!/usr/bin/env python3
"""Ingest a public-domain Bible from an ebible.org USFM release.

The app ships the KJV and nothing else; this adds the other translations a
reader of a given tradition expects — the Douay-Rheims for Catholics, Brenton's
Septuagint for the Orthodox Old Testament, the World English Bible as a modern
public-domain baseline. They are downloadable packs, not bundled, so the app
stays small for someone who only wants the KJV.

Source: ebible.org's per-book USFM zips (`https://ebible.org/Scriptures/<id>_usfm.zip`).
ebible aggregates freely-licensed texts; each of these three is public domain
(Challoner Douay-Rheims, Brenton 1851, WEB is dedicated to the public domain).
The zip's `copr.htm` records the licence and is checked.

Units are **chapters**, matching the KJV already in the corpus: a verse is too
small to embed or cite, a chapter (~3,600 chars) sits where the rest of the
corpus sits and chunks the same way. Verse numbers are kept inline ("1. …\n2. …")
so a citation still resolves, exactly as the bundled KJV does.

USFM carries markup this strips to plain prose: Strong's-number word tags
(`\\w word|strong="H1234"\\w*`), footnotes and cross-references (`\\f … \\f*`,
`\\x … \\x*`), and the paragraph/poetry markers, while keeping the translation's
own words including italicised additions (`\\add … \\add*`) and words of Jesus.

    python3 tools/ingest_usfm.py eng-web --fetch
    python3 tools/ingest_usfm.py eng-web
"""

import argparse
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "bibles"
DATA = ROOT / "tools" / "data"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)

# The three translations this tool is expected to ingest, with the metadata the
# corpus needs. `author` doubles as the packaging key: build_packs assigns these
# to the downloadable f-bibles fragment by matching the author, which keeps the
# bundled KJV (author-less) in the core.
EDITIONS = {
    "eng-web": {
        "title": "The Holy Bible: World English Bible",
        "author": "World English Bible",
        "date": "2000",
        "rights": "Public domain (dedicated to the public domain by "
                  "eBible.org / Michael Paul Johnson)",
    },
    "eng-Brenton": {
        "title": "The Septuagint (Brenton's English Translation)",
        "author": "Lancelot C. L. Brenton",
        "date": "1851",
        "rights": "Public domain (Brenton, 1851; PD-old)",
    },
    "eng-asv": {
        "title": "The Holy Bible: American Standard Version",
        "author": "American Standard Version",
        "date": "1901",
        "rights": "Public domain (ASV, 1901; PD-old)",
    },
    # Douay-Rheims: the ebible id is resolved at fetch time from a small set of
    # known aliases, because ebible has renamed it across releases.
    "eng-dra": {
        "title": "The Holy Bible: Douay-Rheims (Challoner Revision)",
        "author": "Richard Challoner",
        "date": "1752",
        "rights": "Public domain (Challoner revision; PD-old)",
    },
}

# USFM 3-letter book codes → display names, canonical order. Deuterocanon is
# included so the Douay-Rheims and Brenton keep the books their traditions read.
BOOKS = {
    "GEN": "Genesis", "EXO": "Exodus", "LEV": "Leviticus", "NUM": "Numbers",
    "DEU": "Deuteronomy", "JOS": "Joshua", "JDG": "Judges", "RUT": "Ruth",
    "1SA": "1 Samuel", "2SA": "2 Samuel", "1KI": "1 Kings", "2KI": "2 Kings",
    "1CH": "1 Chronicles", "2CH": "2 Chronicles", "EZR": "Ezra",
    "NEH": "Nehemiah", "EST": "Esther", "JOB": "Job", "PSA": "Psalms",
    "PRO": "Proverbs", "ECC": "Ecclesiastes", "SNG": "Song of Solomon",
    "ISA": "Isaiah", "JER": "Jeremiah", "LAM": "Lamentations",
    "EZK": "Ezekiel", "DAN": "Daniel", "HOS": "Hosea", "JOL": "Joel",
    "AMO": "Amos", "OBA": "Obadiah", "JON": "Jonah", "MIC": "Micah",
    "NAM": "Nahum", "HAB": "Habakkuk", "ZEP": "Zephaniah", "HAG": "Haggai",
    "ZEC": "Zechariah", "MAL": "Malachi",
    "MAT": "Matthew", "MRK": "Mark", "LUK": "Luke", "JHN": "John",
    "ACT": "Acts", "ROM": "Romans", "1CO": "1 Corinthians",
    "2CO": "2 Corinthians", "GAL": "Galatians", "EPH": "Ephesians",
    "PHP": "Philippians", "COL": "Colossians", "1TH": "1 Thessalonians",
    "2TH": "2 Thessalonians", "1TI": "1 Timothy", "2TI": "2 Timothy",
    "TIT": "Titus", "PHM": "Philemon", "HEB": "Hebrews", "JAS": "James",
    "1PE": "1 Peter", "2PE": "2 Peter", "1JN": "1 John", "2JN": "2 John",
    "3JN": "3 John", "JUD": "Jude", "REV": "Revelation",
    # Deuterocanon / apocrypha, as the DR and LXX carry them.
    "TOB": "Tobit", "JDT": "Judith", "WIS": "Wisdom", "SIR": "Sirach",
    "BAR": "Baruch", "1MA": "1 Maccabees", "2MA": "2 Maccabees",
    "1ES": "1 Esdras", "2ES": "2 Esdras", "MAN": "Prayer of Manasseh",
    "3MA": "3 Maccabees", "4MA": "4 Maccabees", "PS2": "Psalm 151",
    "ODA": "Odes", "PSS": "Psalms of Solomon", "DAG": "Daniel (Greek)",
    "S3Y": "Song of the Three Young Men", "SUS": "Susanna", "BEL": "Bel and the Dragon",
    "LJE": "Letter of Jeremiah", "ESG": "Esther (Greek)",
}

# Footnotes, cross-references and study apparatus: dropped whole, opening marker
# to closing.
FOOTNOTE_RE = re.compile(r"\\(f|x|fe)\b.*?\\\1\*", re.S)
# A tagged word: "\w heaven|strong="H8064"\w*" -> "heaven". Keep the surface
# word, drop the attribute payload after the pipe.
WORD_RE = re.compile(r"\\\+?w\s+([^|\\]*?)(?:\|[^\\]*?)?\\\+?w\*")
# Any remaining character-style marker pair that should keep its text:
# \add \wj \nd \qs \bk \it \em \tl \+add etc. Strip the markers, keep content.
CHAR_PAIR_RE = re.compile(r"\\\+?(add|wj|nd|qs|bk|it|em|tl|sc|pn|wh|k|w)\*?")
# Anything else beginning with a backslash marker on its own (paragraph/poetry
# markers \p \q \m \b \li …, and leftover standalone markers).
MARKER_RE = re.compile(r"\\[a-z0-9]+\*?")


def fetch(ebible_id):
    import subprocess
    CACHE.mkdir(parents=True, exist_ok=True)
    # ebible has shipped the Douay-Rheims under a few ids; try them in turn.
    aliases = {
        "eng-dra": ["eng-dra", "engDRA", "eng-drav", "eng-Douay"],
    }.get(ebible_id, [ebible_id])
    for alias in aliases:
        path = CACHE / f"{ebible_id}_usfm.zip"
        if path.exists():
            print(f"  cached {path.name}")
            return
        url = f"https://ebible.org/Scriptures/{alias}_usfm.zip"
        print(f"  trying {url}")
        r = subprocess.run(["curl", "-fsSL", "--max-time", "120", "-A",
                            USER_AGENT, url, "-o", str(path)],
                           capture_output=True)
        if r.returncode == 0 and path.stat().st_size > 10000:
            print(f"  fetched {path.name} ({path.stat().st_size} bytes)")
            return
        path.unlink(missing_ok=True)
    sys.exit(f"FAILED to fetch {ebible_id}: none of {aliases} resolved.")


def book_code(filename):
    """The 3-letter book code embedded in an ebible USFM filename.

    Names look like "02-GENeng-web.usfm" or "40-MATeng-Brenton.usfm": a two- or
    three-digit order, a hyphen, the code, then the edition id.
    """
    m = re.match(r"\d+-([A-Z0-9]{3})", filename)
    return m.group(1) if m else None


def clean(text):
    """A USFM verse body -> plain prose."""
    text = FOOTNOTE_RE.sub("", text)
    # Repeat the word substitution: nested/adjacent tags can leave a residue the
    # first pass steps over.
    for _ in range(3):
        text = WORD_RE.sub(r"\1", text)
    text = CHAR_PAIR_RE.sub("", text)
    text = MARKER_RE.sub(" ", text)
    text = text.replace("|", " ")
    # USFM uses ~ for a non-breaking space and // for a discretionary line break.
    text = text.replace("~", " ").replace("//", " ")
    return re.sub(r"\s+", " ", text).strip()


def parse_book(usfm):
    """Yield (chapter_number, chapter_text) for one book's USFM."""
    # Split on chapter markers, keeping the number.
    parts = re.split(r"\\c\s+(\d+)\b", usfm)
    # parts[0] is the header before chapter 1; then alternating number, body.
    for i in range(1, len(parts), 2):
        number = int(parts[i])
        body = parts[i + 1] if i + 1 < len(parts) else ""
        verses = re.split(r"\\v\s+(\d+[a-z]?)\b", body)
        lines = []
        for j in range(1, len(verses), 2):
            verse_no = verses[j]
            verse_text = clean(verses[j + 1] if j + 1 < len(verses) else "")
            if verse_text:
                lines.append(f"{verse_no}. {verse_text}")
        if lines:
            yield number, "\n".join(lines)


def check_licence(zf):
    for name in zf.namelist():
        if name.lower().endswith(("copr.htm", "copyright.htm", "license.htm")):
            body = zf.read(name).decode("utf-8", "replace").lower()
            if "public domain" in body or "creative commons" in body:
                return True
            print(f"  WARNING: {name} does not state public domain / CC; "
                  f"check the licence before shipping.", file=sys.stderr)
            return False
    print("  WARNING: no copyright file found in the zip.", file=sys.stderr)
    return False


def build(ebible_id):
    meta = EDITIONS[ebible_id]
    zip_path = CACHE / f"{ebible_id}_usfm.zip"
    if not zip_path.exists():
        sys.exit(f"No zip at {zip_path}; run with --fetch first.")

    units = []
    sequence = 0
    with zipfile.ZipFile(zip_path) as zf:
        pd = check_licence(zf)
        for name in sorted(zf.namelist()):
            if not name.endswith(".usfm"):
                continue
            code = book_code(Path(name).name)
            if code not in BOOKS:
                continue  # front matter, glossary, unknown book code
            usfm = zf.read(name).decode("utf-8", "replace")
            for number, text in parse_book(usfm):
                if len(text) < 40:
                    continue
                sequence += 1
                units.append({
                    "number": sequence,
                    "title": f"{BOOKS[code]} {number}",
                    "content": text,
                })

    if not units:
        sys.exit("REFUSED: parsed zero chapters; the USFM shape is unexpected.")

    chars = sum(len(u["content"]) for u in units)
    print(f"  {len(units)} chapters, {chars / 1e6:.2f} M chars, "
          f"licence-ok={pd}")

    document = {
        "title": meta["title"],
        "date": meta["date"],
        "tradition": "Scripture",
        "kind": "Scripture",
        "url": f"https://ebible.org/{ebible_id}/",
        "rights": meta["rights"],
        "collection": f"ebible.org ({ebible_id})",
        "author": meta["author"],
        "editor": "",
        "units": units,
    }

    out = DATA / f"{ebible_id.replace('-', '_')}_units.json"
    DATA.mkdir(parents=True, exist_ok=True)
    import json
    with open(out, "w") as handle:
        json.dump([document], handle, indent=2)
        handle.write("\n")
    print(f"  wrote {out}")
    return units


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("edition", choices=sorted(EDITIONS))
    ap.add_argument("--fetch", action="store_true")
    ap.add_argument("--verify", action="store_true",
                    help="print a few well-known verses to eyeball the parse")
    args = ap.parse_args()

    if args.fetch:
        fetch(args.edition)
    units = build(args.edition)

    if args.verify:
        wanted = ["Genesis 1", "John 3", "Psalms 23", "Psalm 23"]
        by_title = {u["title"]: u["content"] for u in units}
        for title in wanted:
            if title in by_title:
                first = by_title[title].split("\n")[0]
                print(f"\n  {title} v1: {first[:160]}")


if __name__ == "__main__":
    main()
