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

---

**Second pass.** The eight left standing were kept on the reading that their
wording was genuine but abridged. Reading their unit *titles in order* shows
that it is not, and that the defect is worse than abridgement. Each of these
sources is **two unrelated works interleaved**, odd positions from one and even
from the other:

    Philokalia Selections      Slough of Despond · Watchfulness · The Cross and
                               the Burden · The Jesus Prayer · Vanity Fair ·
                               Dispassion · The Celestial City · Theosis

Half of that is *Pilgrim's Progress*. Under Wesley's name sit the Didache's
"Two Ways" and the arrest, trial and burning of Polycarp. Under Gregory of
Nyssa sit three sections of *Nostra Aetate* — Vatican II, 1965, and in
copyright. Under Teresa of Ávila's *Interior Castle* sit the inward, outward
and corporate disciplines of Richard Foster's *Celebration of Discipline*,
1978, also in copyright.

So all eight go. This is the rule about never placing text under an author's
byline that is not theirs, applied to the case where the byline is wrong *and*
the text is someone else's living copyright. A gap is better.

The Seven Ecumenical Councils is the one happy case: it is superseded rather
than merely deleted. Its seven paragraphs of summary are replaced by the actual
acts — creeds, canons and synodal letters — already in the corpus from New
Advent, which run to some 550,000 characters across the seven.

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

# Second pass: sources whose units belong to a different work than their title
# claims. The evidence is in the docstring; the byline is the point. Each entry
# names what is actually in there, so this reads as a finding rather than an
# assertion.
MISATTRIBUTED = {
    "The Philokalia Selections":
        "half the units are Pilgrim's Progress (Slough of Despond, "
        "Vanity Fair, the Celestial City)",
    "A Plain Account of the People Called Methodists (Wesley)":
        "opens with the Didache's Two Ways and the martyrdom of Polycarp",
    "The Life of Moses (Gregory of Nyssa)":
        "three units are Nostra Aetate (Vatican II, 1965, in copyright)",
    "The Interior Castle (Teresa of Avila)":
        "alternates with Richard Foster's Celebration of Discipline "
        "(1978, in copyright)",
    "The Spiritual Exercises (Ignatius)":
        "seven paragraphs of unsourced précis under Ignatius' byline",
    "The Orthodox Confession of Faith (Peter Mogila)":
        "six paragraphs of unsourced précis; the first is the Nicene Creed",
    "Second Helvetic Confession":
        "nine paragraphs of unsourced précis of a thirty-chapter confession",
}

# Superseded, but by a group rather than by a single edition — so it cannot go
# in SUPERSEDED above, which verifies one replacement title. Every council named
# here is checked to exist before the summary is deleted.
SUPERSEDED_BY_SET = {
    "The Seven Ecumenical Councils": [
        "Nicaea I (325)", "Constantinople I (381)", "Ephesus (431)",
        "Chalcedon (451)", "Constantinople II (553)",
        "Constantinople III (680)", "Nicaea II (787)",
    ],
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

    print("\nSuperseded by the acts themselves")
    for title, replacements in SUPERSEDED_BY_SET.items():
        stub_id = source_id(conn, title)
        if stub_id is None:
            print(f"  already gone   {title}")
            continue
        missing = [t for t in replacements if source_id(conn, t) is None]
        if missing:
            sys.exit(
                f"REFUSED: {title!r} is replaced by {replacements}, and "
                f"{missing} are not in the corpus. Deleting the summary now "
                f"would leave those councils with nothing at all."
            )
        chars = sum(unit_count(conn, source_id(conn, t))[1] for t in replacements)
        units, old_chars = unit_count(conn, stub_id)
        print(f"  {title[:44]:46} {units:4}u {old_chars:7}c  ->  "
              f"{len(replacements)} councils, {chars} c of creeds and canons")
        doomed.append((stub_id, title))

    print("\nMisattributed — the units are not the work the title names")
    for title, reason in MISATTRIBUTED.items():
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
    #
    # Both were re-ingested on 2026-07-26 once `is_hub` was fixed — 28,578
    # characters of chapter titles became 1.2 M of Irenaeus, and 32,546 became
    # 0.8 M of the Harmony. Left printing so the numbers stay in view: this is
    # where the defect was first named, and the figures beside it are what
    # says it is closed.
    print("\nProvenanced but holding indexes — fixed 2026-07-26, watched here")
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
