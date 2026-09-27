#!/usr/bin/env python3
"""Take CCEL's bookkeeping back off the author names it was glued to.

`read_creators` in `ingest_reformation.py` built an author's name out of CCEL's
`Creator(s)` field, and three faults in it stored names that are not anyone's:

    Table Talk                  Martin WILLIAM HAZLITT, Esq. Luther
    A Body of Divinity          Thomas d. 1686 Watson
    The Imitation of Christ     à Kempis, 1380-1471 Thomas
    Of Prayer                   John Henry Beveridge Calvin
    God's Way of Peace          Horatius, D.D. Bonar

This is not cosmetic. `sources.author` reaches the reader in the citation tile
under every answer, and it reaches the *model*, in `Citation.promptLabel` — so
a question answered out of Table Talk was told in its own prompt that the book
is by a man who does not exist, and could say so in the answer. For a corpus
whose claim is that you can check what it tells you against a named source, the
name is not metadata.

The parser is fixed, with tests, so this cannot recur; what follows repairs the
rows already written. Nothing here is guessed. Two passes, each justified by
evidence already in the database:

**Where the corpus disagrees with itself.** CCEL work URLs carry an author
slug — `ccel.org/ccel/luther/tabletalk` — so every source by one author is
already grouped. Five slugs hold more than one spelling of their author's name,
and in each the odd one out is outnumbered 3-to-1 or worse. That pass also
caught a plain typo no pattern would have: 67 sources say "Charles Haddon
Spurgeon" and one says "Hadden".

**Where a lone source has a name that cannot be right.** A name carrying a
year, an honorific, a shouted run or a stray comma, from a slug with nothing to
compare against. The corrected name is rebuilt *from the slug*: the surname is
the word the URL already names, and what remains after the dates and
qualifications is the forename. That is what places Thomas à Kempis, whom CCEL
writes forename-first and no rule could otherwise order.

A name this cannot justify is reported and left alone rather than guessed at.

Dry run by default.

    python3 tools/fix_author_names.py
    python3 tools/fix_author_names.py --write
"""

import argparse
import re
import shutil
import sqlite3
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "assets" / "theology.db"

# Bare dates and qualifications, the ones that are not in brackets and so were
# never stripped. Same list the ingester now applies at parse time.
NOISE = re.compile(
    r"""(?x)
      \b(?:b|d|fl|ca|c)\.\s*\d{3,4}(?:\s*[-–]\s*\d{3,4})?
    | \b\d{3,4}\s*[-–]\s*\d{3,4}\b
    | \b(?:D\.D\.|LL\.D\.|Ph\.D\.|S\.T\.D\.|M\.A\.|B\.D\.|Esq\.|S\.J\.|O\.P\.)
    """,
    re.I,
)

# A surname can begin with one of these and still be one word to a reader.
PARTICLES = {"à", "a", "van", "von", "de", "del", "della", "du", "la", "le",
             "ten", "ter", "den", "der", "di", "da", "of"}

ROMAN = re.compile(r"^[IVXLCDM]+$")


def shouted(word):
    """An absorbed translator credit, rather than an initial or a regnal number.

    Two letters at minimum and no period in the word. Without the period test
    this reads "G." as a shout — `"G.".isupper()` is true — and a dry run of an
    earlier draft duly offered to rewrite "Ellen G. White" as "Ellen White" and
    "Charles G. Finney" as "Charles Finney", across fourteen sources. Middle
    initials and "E.W. Bullinger" are names; "WILLIAM HAZLITT" is a translator
    who ended up inside one.
    """
    letters = re.sub(r"[^A-Za-z]", "", word)
    return (len(letters) > 1 and word.isupper()
            and "." not in word and not ROMAN.match(word))

SUSPECT = [
    ("a year", lambda n: re.search(r"\d{3,4}", n)),
    ("an honorific", lambda n: re.search(
        r"\b(?:D\.D\.|LL\.D\.|Ph\.D\.|S\.T\.D\.|M\.A\.|B\.D\.|Esq\.|S\.J\.)",
        n, re.I)),
    ("a shouted run", lambda n: any(shouted(w) for w in n.split())),
    ("a comma mid-name", lambda n: re.search(r",(?!\s*(?:Pope|Jr\.|Sr\.)\b)", n)),
]


def fold(text):
    """Accent-insensitive, so 'à Kempis' matches the slug 'kempis'."""
    decomposed = unicodedata.normalize("NFD", text.lower())
    return "".join(c for c in decomposed if unicodedata.category(c) != "Mn")


def ccel_slug(url):
    match = re.search(r"/ccel/([^/]+)/", url or "")
    return match.group(1).lower() if match else None


def suspect_reasons(author):
    return [why for why, test in SUSPECT if test(author or "")]


def rebuild_from_slug(author, slug):
    """The name, reordered around the surname the CCEL URL already names.

    The stored string has usually been through a surname-first swap already, so
    re-parsing it cannot help — the words are in the wrong order and the parser
    has no way to know. The slug does know: it *is* the surname. So drop the
    dates and qualifications, find the word the slug names, carry any particle
    in front of it, and the rest is the forename.
    """
    cleaned = NOISE.sub(" ", author).replace(",", " ")
    words = [w for w in cleaned.split() if w]
    if not words:
        return None

    index = next(
        (i for i, w in enumerate(words) if fold(w).strip(".") in fold(slug)),
        None,
    )
    if index is None:
        return None

    start = index
    if start and fold(words[start - 1]) in PARTICLES:
        start -= 1
    surname = " ".join(words[start:index + 1])
    # A shouted run is a translator credit that was absorbed into the name.
    forename = [w for w in words[:start] + words[index + 1:] if not shouted(w)]
    if not forename:
        return None
    return re.sub(r"\s+", " ", f"{' '.join(forename)} {surname}").strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    if not args.db.exists():
        sys.exit(f"no database at {args.db}")

    conn = sqlite3.connect(args.db)
    rows = conn.execute(
        "SELECT id, author, title, source_url FROM sources "
        "WHERE author IS NOT NULL AND author != ''"
    ).fetchall()

    units_by_source = dict(conn.execute(
        "SELECT source_id, COUNT(*) FROM content_units GROUP BY source_id"
    ).fetchall())

    by_slug = defaultdict(Counter)
    for _, author, _, url in rows:
        slug = ccel_slug(url)
        if slug:
            by_slug[slug][author] += 1

    ops, skipped = [], []
    seen = set()

    print("where the corpus disagrees with itself\n")
    for source_id, author, title, url in rows:
        slug = ccel_slug(url)
        if not slug or len(by_slug[slug]) < 2:
            continue
        (winner, wins), = by_slug[slug].most_common(1)
        if author == winner or by_slug[slug][author] >= wins:
            continue
        seen.add(source_id)
        ops.append((winner, source_id, author, title,
                    f"{wins} other sources under slug '{slug}' say so"))

    for fixed, source_id, author, title, why in ops:
        print(f"  {author!r}\n    -> {fixed!r}   "
              f"({units_by_source.get(source_id, 0)} units, {why})")
        print(f"       {title}")

    print("\nwhere a lone source has a name that cannot be right\n")
    for source_id, author, title, url in rows:
        if source_id in seen:
            continue
        reasons = suspect_reasons(author)
        if not reasons:
            continue
        slug = ccel_slug(url)
        why = ", ".join(reasons)
        if not slug:
            skipped.append((author, title, f"{why}; no CCEL url to rebuild from"))
            continue
        fixed = rebuild_from_slug(author, slug)
        if not fixed or fixed == author:
            skipped.append((author, title, f"{why}; slug '{slug}' does not name it"))
            continue
        ops.append((fixed, source_id, author, title,
                    f"{why}; surname from slug '{slug}'"))
        print(f"  {author!r}\n    -> {fixed!r}   "
              f"({units_by_source.get(source_id, 0)} units, {why})")
        print(f"       {title}")

    if skipped:
        print("\nreported, not changed:")
        for author, title, reason in skipped:
            print(f"  {author!r} — {reason}\n       {title}")

    if not ops:
        print("\nnothing to do")
        conn.close()
        return

    if not args.write:
        print(f"\n{len(ops)} corrections — dry run, pass --write to apply")
        conn.close()
        return

    backup = args.db.with_suffix(".db.bak")
    shutil.copy2(args.db, backup)
    print(f"\nbackup -> {backup}")
    conn.executemany(
        "UPDATE sources SET author = ? WHERE id = ?",
        [(fixed, source_id) for fixed, source_id, *_ in ops],
    )
    conn.commit()
    # No FTS rebuild and no re-embedding: content_fts indexes content and title,
    # and the chunk vectors are built from unit text. An author is neither.
    print(f"applied {len(ops)} — re-run build_packs.py to republish")
    conn.close()


if __name__ == "__main__":
    main()
