#!/usr/bin/env python3
"""Remove the New Testament apocrypha and four named forgeries.

Every earlier prune was for a defect in the *text* — two works interleaved,
unsourced précis, or someone else's copyright. This one is different: these
sources are exactly what they claim to be, faithfully transcribed from the
Ante-Nicene Fathers, and they go because of what they are rather than because
the transcription failed. That is an editorial decision about the corpus, not a
correctness fix, so the reasoning belongs here in full.

Two selections, and neither is "everything that sounds apocryphal".

**By byline.** Forty sources carry the author `Apocrypha`, all in fragment
`f-apocrypha`: the infancy gospels, the Pilate cycle, the apocryphal Acts, the
late apocalypses, and three pieces of Second Temple pseudepigrapha. They were
never in the bundled core, but `f-apocrypha` is listed inside the **Church
Fathers** and **Ante-Nicene Writers** collections in `tools/data/packs.json`, so
a reader installing either received all forty without ever choosing them. That
distribution is what made this worth doing rather than leaving.

**By name.** Four more that the byline does not catch:

    The False Decretals            the Pseudo-Isidorian forgeries — fabricated
                                   papal letters, made to deceive
    Recognitions                   Pseudo-Clementine, carrying Ebionite
    Clementine Homilies            material, and bylined *Clement of Rome* here
                                   as though genuine
    The Book of the Laws of        Bardesanes, a heterodox author
      Various Countries
    The Legend of Barlaam and      a Christianised retelling of the life of
      Josaphat                     the Buddha

What is deliberately NOT removed, because it superficially resembles the above
and is none of it:

  * The **Apostolic Fathers** — the *Didache*, the *Epistle of Barnabas*, the
    *Shepherd* of Hermas, 1 Clement, Ignatius, Polycarp, *Diognetus*.
    Sub-apostolic and orthodox; early, not spurious.
  * The **refutations** — Tertullian's *Against Marcion* and *Against Praxeas*,
    Hippolytus' *Refutation of All Heresies*. These exist to argue against this
    material and are unreadable without knowing what they answer.
  * The **deuterocanon**, canon for Catholics and the Orthodox, already present
    inside the Douay-Rheims, Brenton's Septuagint and the WEB.

There are no Gnostic texts to remove. The Gospel of Mary, Judas, Philip, Truth
and Pistis Sophia are all absent and always were: the patristics here come from
the 1880s ANF/NPNF volumes, Nag Hammadi was not found until 1945, and its
translations are in copyright. Note also that the `Gospel of Thomas` in this
corpus is the *Infancy* Gospel of Thomas — ANF Vol. 8, the boy-Jesus miracle
stories — and not the Gnostic sayings gospel it shares a name with.

Dry run by default. `--write` copies the database to `theology.db.bak` first,
and **that copy is the only way back**. `assets/theology.db` is gitignored, so
`git checkout` restores nothing — a claim the docstrings of
`prune_unprovenanced.py` and `prune_bylined_sources.py` still make and should
not. `assets/theology.db.gz` is not a spare either: it unpacks to 9.2 MB, the
bundled core, against 895 MB for the full corpus. Short of the `.bak`, recovery
means re-running the ingest pipeline over `.cache`.

    python3 tools/prune_apocrypha.py
    python3 tools/prune_apocrypha.py --write
"""

import argparse
import shutil
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "assets" / "theology.db"

# Everything under this byline goes. Checked against the count below so that a
# byline appearing on something unexpected fails loudly rather than deleting it.
DOOMED_AUTHOR = "Apocrypha"
EXPECTED_AUTHOR_COUNT = 40

# Matched on exact title, each with the reason it is not caught by the byline.
DOOMED_TITLES = {
    "The False Decretals (c. 850)":
        "the Pseudo-Isidorian forgeries: fabricated papal letters",
    "Recognitions":
        "Pseudo-Clementine, bylined Clement of Rome as though genuine",
    "Clementine Homilies":
        "Pseudo-Clementine, bylined Clement of Rome as though genuine",
    "The Book of the Laws of Various Countries":
        "Bardesanes, a heterodox author",
    "The Legend of Barlaam and Josaphat":
        "a Christianised retelling of the life of the Buddha",
}

# Named so the script can prove it is not about to take them. If any of these
# is missing the corpus has drifted and the operator should know before a
# deletion runs, not after.
MUST_SURVIVE = [
    "The Didache (c. 100)",
    "Epistle of Barnabas",
    "Against Marcion",
    "The Refutation of All Heresies",
]


def unit_stats(conn, source_id):
    row = conn.execute(
        """SELECT COUNT(*), COALESCE(SUM(LENGTH(content)), 0)
           FROM content_units WHERE source_id = ?""", (source_id,)).fetchone()
    return row[0], row[1]


def delete_source(conn, source_id):
    """Remove a source and everything hanging off it.

    Order matters, and so does the FTS rebuild the caller does afterwards. The
    index is external-content FTS5 with no sync triggers, so deleting rows
    alone leaves it describing text that is gone — and searches then return
    passages that cannot be opened.
    """
    conn.execute(
        """DELETE FROM chunk_embeddings WHERE chunk_id IN (
             SELECT c.id FROM content_chunks c
             JOIN content_units u ON c.content_unit_id = u.id
             WHERE u.source_id = ?)""", (source_id,))
    conn.execute(
        """DELETE FROM content_chunks WHERE content_unit_id IN (
             SELECT id FROM content_units WHERE source_id = ?)""", (source_id,))
    conn.execute(
        """DELETE FROM content_tags WHERE content_unit_id IN (
             SELECT id FROM content_units WHERE source_id = ?)""", (source_id,))
    conn.execute("DELETE FROM content_units WHERE source_id = ?", (source_id,))
    conn.execute("DELETE FROM sources WHERE id = ?", (source_id,))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    conn = sqlite3.connect(args.db)
    doomed = []

    by_author = conn.execute(
        "SELECT id, title FROM sources WHERE author = ? ORDER BY id",
        (DOOMED_AUTHOR,)).fetchall()

    print(f"Bylined {DOOMED_AUTHOR!r}")
    if len(by_author) != EXPECTED_AUTHOR_COUNT and by_author:
        sys.exit(
            f"REFUSED: expected {EXPECTED_AUTHOR_COUNT} sources bylined "
            f"{DOOMED_AUTHOR!r}, found {len(by_author)}. The corpus has moved "
            f"since this was written — re-read the list before deleting."
        )
    for source_id, title in by_author:
        units, chars = unit_stats(conn, source_id)
        print(f"  [{source_id}] {title[:58]:<58} {units:>4}u {chars:>9,}c")
        doomed.append((source_id, title))

    print("\nNamed individually")
    for title, why in DOOMED_TITLES.items():
        row = conn.execute(
            "SELECT id FROM sources WHERE title = ?", (title,)).fetchone()
        if row is None:
            print(f"  already gone   {title}")
            continue
        units, chars = unit_stats(conn, row[0])
        print(f"  [{row[0]}] {title[:58]:<58} {units:>4}u {chars:>9,}c")
        print(f"          {why}")
        doomed.append((row[0], title))

    print("\nMust survive")
    missing = []
    for title in MUST_SURVIVE:
        row = conn.execute(
            "SELECT id FROM sources WHERE title = ?", (title,)).fetchone()
        state = f"[{row[0]}] present" if row else "MISSING"
        print(f"  {title[:58]:<58} {state}")
        if row is None:
            missing.append(title)
    if missing:
        sys.exit(
            f"REFUSED: {len(missing)} source(s) that must survive are already "
            f"absent: {missing}. Fix the corpus before pruning it further."
        )

    total_units = sum(unit_stats(conn, s)[0] for s, _ in doomed)
    total_chars = sum(unit_stats(conn, s)[1] for s, _ in doomed)
    before = conn.execute("SELECT COUNT(*) FROM sources").fetchone()[0]
    print(f"\n{len(doomed)} sources, {total_units:,} units, {total_chars:,} "
          f"characters — {before} sources before, {before - len(doomed)} after")

    if not args.write:
        print("\ndry run; pass --write to apply")
        return

    backup = args.db.with_suffix(".db.bak")
    shutil.copy2(args.db, backup)
    print(f"\nbackup -> {backup}")

    for source_id, _ in doomed:
        delete_source(conn, source_id)

    conn.execute("INSERT INTO content_fts(content_fts) VALUES('rebuild')")
    conn.commit()
    conn.execute("VACUUM")
    conn.commit()

    after = conn.execute("SELECT COUNT(*) FROM sources").fetchone()[0]
    print(f"removed {len(doomed)}; {after} sources remain")
    print("\nnow re-run, in order:")
    print("  python3 tools/build_chunks.py --write")
    print("  python3 tools/build_embeddings.py --write")
    print("  python3 tools/build_packs.py --write")
    print("and drop f-apocrypha from tools/data/packs.json — it is now empty.")


if __name__ == "__main__":
    main()
