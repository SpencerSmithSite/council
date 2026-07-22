#!/usr/bin/env python3
"""Remove legacy sources that should not be in the corpus.

Twenty-three sources carry no `source_url`. Their wording is genuine but
abridged — the Westminster Confession stub holds 4,157 characters where the
document runs to some 35,000 words — and with no recorded origin none of it can
be checked against a published edition.

They are not all the same problem, and the difference matters:

**Superseded.** A properly-sourced, far fuller edition of the same document is
already in the corpus, so the stub is a duplicate that competes with it in
search results. `Against Celsus` runs to 1.3 million characters; the
`Contra Celsum` stub holds 2,015.

**Not ours to ship.** The Catechism of the Catholic Church and Lumen Gentium
are © Libreria Editrice Vaticana. Both were recorded here as `public domain`,
which is simply wrong. Neither their age nor their availability online makes
them free to redistribute, and a licence field asserting otherwise is worse
than a missing one.

**Still needed.** Everything else — no clean public-domain edition has been
found yet. These stay, and the app now marks them plainly as having no recorded
origin rather than presenting them with the confidence of a sourced text.

Dry run by default.

    python3 tools/prune_unprovenanced.py
    python3 tools/prune_unprovenanced.py --write
"""

import argparse
import shutil
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "assets" / "theology.db"

# Stub title -> the provenanced edition that replaces it. The replacement is
# looked up and verified to exist before anything is deleted, so a rename
# upstream fails loudly instead of quietly destroying the only copy.
SUPERSEDED = {
    "Westminster Shorter Catechism": "The Westminster Shorter Catechism",
    "Westminster Larger Catechism": "The Westminster Larger Catechism",
    "Thirty-Nine Articles": "The Thirty-Nine Articles of Religion",
    "Belgic Confession": "The Belgic Confession",
    "Heidelberg Catechism": "The Heidelberg Catechism",
    "The Didache": "The Didache (c. 100)",
    "Contra Celsum": "Against Celsus",
    "Fragments of Papias": "Fragments",
    # 1,996 characters of unsourced abridgement, against 14.1 million in the
    # complete translation now present.
    "Summa Theologica Selections (Aquinas)": "Summa Theologiae: Prima Pars",
}

# Not prose at all: chapter indexes captured instead of chapter text, so the
# "content" is a run of headings — "Preface Chapter 1 Absurd ideas of the
# disciples of Valentinus... Chapter 2 The Propator was known to Monogenes
# alone..." — which retrieves on every patristic keyword and says nothing.
#
# `Against Heresies` was very nearly deleted as superseded by the provenanced
# `Adversus haereses`, which is 28,578 characters against the stub's 29,580 and
# looks like the fuller edition. It is not. Both are indexes, and swapping one
# for the other would have been recorded as an improvement.
INDEX_NOT_TEXT = {
    "Against Heresies": "chapter index, not the text of the work",
}

# Removed on rights grounds, not quality grounds.
NOT_OURS_TO_SHIP = {
    "Catechism of the Catholic Church":
        "© Libreria Editrice Vaticana; recorded here as public domain",
    "Lumen Gentium":
        "© Libreria Editrice Vaticana; recorded here as public domain",
}


def source_id(conn, title):
    row = conn.execute("SELECT id FROM sources WHERE title = ?", (title,)).fetchone()
    return row[0] if row else None


def unit_count(conn, source):
    return conn.execute(
        "SELECT COUNT(*), COALESCE(SUM(LENGTH(content)), 0) "
        "FROM content_units WHERE source_id = ?",
        (source,),
    ).fetchone()


def delete_source(conn, source):
    """Remove a source and everything hanging off it.

    Order matters, and so does the FTS step. The index is external-content
    FTS5 with no sync triggers: deleting the rows alone leaves it describing
    text that is gone, and searches then return passages that cannot be opened.
    """
    conn.execute(
        """DELETE FROM chunk_embeddings WHERE chunk_id IN (
             SELECT c.id FROM content_chunks c
             JOIN content_units u ON c.content_unit_id = u.id
             WHERE u.source_id = ?)""", (source,))
    conn.execute(
        """DELETE FROM content_chunks WHERE content_unit_id IN (
             SELECT id FROM content_units WHERE source_id = ?)""", (source,))
    conn.execute(
        """DELETE FROM content_tags WHERE content_unit_id IN (
             SELECT id FROM content_units WHERE source_id = ?)""", (source,))
    conn.execute("DELETE FROM content_units WHERE source_id = ?", (source,))
    conn.execute("DELETE FROM sources WHERE id = ?", (source,))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    conn = sqlite3.connect(args.db)
    doomed = []

    print("Superseded by a provenanced edition")
    for stub, replacement in SUPERSEDED.items():
        stub_id = source_id(conn, stub)
        new_id = source_id(conn, replacement)
        if stub_id is None:
            print(f"  already gone   {stub}")
            continue
        if new_id is None:
            sys.exit(
                f"REFUSED: {stub!r} claims to be replaced by {replacement!r}, "
                f"which is not in the corpus. Deleting would lose the only copy."
            )
        old_units, old_chars = unit_count(conn, stub_id)
        new_units, new_chars = unit_count(conn, new_id)
        print(f"  {stub[:44]:46} {old_units:4}u {old_chars:7}c  ->  "
              f"{replacement[:34]:36} {new_units:4}u {new_chars:8}c")
        doomed.append((stub_id, stub))

    print("\nIndexes rather than text")
    for title, reason in INDEX_NOT_TEXT.items():
        stub_id = source_id(conn, title)
        if stub_id is None:
            print(f"  already gone   {title}")
            continue
        units, chars = unit_count(conn, stub_id)
        print(f"  {title[:44]:46} {units:4}u {chars:7}c   {reason}")
        doomed.append((stub_id, title))

    print("\nRemoved on rights grounds")
    for title, reason in NOT_OURS_TO_SHIP.items():
        stub_id = source_id(conn, title)
        if stub_id is None:
            print(f"  already gone   {title}")
            continue
        units, chars = unit_count(conn, stub_id)
        print(f"  {title[:44]:46} {units:4}u {chars:7}c   {reason}")
        doomed.append((stub_id, title))

    # Provenanced sources with the same defect. Reported rather than deleted:
    # they are real works whose text should be re-ingested from the chapter
    # pages, not entries to drop.
    print("\nProvenanced but holding indexes — re-ingest, do not delete")
    for title in ("Adversus haereses", "The Harmony of the Gospels"):
        found = source_id(conn, title)
        if found is not None:
            units, chars = unit_count(conn, found)
            print(f"  {title[:44]:46} {units:4}u {chars:7}c")

    remaining = conn.execute(
        "SELECT COUNT(*) FROM sources WHERE source_url IS NULL").fetchone()[0]
    print(f"\n{len(doomed)} sources to remove; "
          f"{remaining - len(doomed)} will still lack provenance")

    if not args.write:
        print("\ndry run — pass --write to delete")
        return

    backup = args.db.with_suffix(".db.bak")
    shutil.copy2(args.db, backup)
    print(f"backup -> {backup}")

    for source, title in doomed:
        delete_source(conn, source)

    # Units whose source row is already gone, left behind by an earlier phase
    # that deleted sources without cascading. They predate this script — the
    # count is identical before and after it runs — but they are unciteable by
    # construction: with no source there is no title, no tradition and no
    # origin, so they surface as "Unknown source" with nothing to check.
    orphans = conn.execute(
        """SELECT COUNT(*) FROM content_units u
           LEFT JOIN sources s ON u.source_id = s.id
           WHERE s.id IS NULL""").fetchone()[0]
    if orphans:
        print(f"also removing {orphans} units whose source no longer exists")
        conn.execute(
            """DELETE FROM chunk_embeddings WHERE chunk_id IN (
                 SELECT c.id FROM content_chunks c
                 JOIN content_units u ON c.content_unit_id = u.id
                 LEFT JOIN sources s ON u.source_id = s.id
                 WHERE s.id IS NULL)""")
        conn.execute(
            """DELETE FROM content_chunks WHERE content_unit_id IN (
                 SELECT u.id FROM content_units u
                 LEFT JOIN sources s ON u.source_id = s.id
                 WHERE s.id IS NULL)""")
        conn.execute(
            """DELETE FROM content_tags WHERE content_unit_id IN (
                 SELECT u.id FROM content_units u
                 LEFT JOIN sources s ON u.source_id = s.id
                 WHERE s.id IS NULL)""")
        conn.execute(
            """DELETE FROM content_units WHERE id IN (
                 SELECT u.id FROM content_units u
                 LEFT JOIN sources s ON u.source_id = s.id
                 WHERE s.id IS NULL)""")

    conn.execute("INSERT INTO content_fts(content_fts) VALUES('rebuild')")
    conn.commit()
    conn.execute("VACUUM")
    conn.commit()

    left = conn.execute(
        "SELECT COUNT(*) FROM sources WHERE source_url IS NULL").fetchone()[0]
    total = conn.execute("SELECT COUNT(*) FROM sources").fetchone()[0]
    print(f"removed {len(doomed)}; {left} of {total} sources still lack "
          f"provenance")
    print("now re-run: build_chunks.py --write && build_embeddings.py --write")


if __name__ == "__main__":
    main()
