#!/usr/bin/env python3
"""Correct fabricated tradition labels and drop duplicated legacy sources.

Metadata-aware retrieval made a latent problem urgent. Scoping a question to a
tradition is only as good as the tradition column, and in the legacy corpus
that column is fabricated: every one of the four sources labelled Lutheran is
something else — the Didache, the Philokalia, Gregory of Nyssa, and Peter
Mogila's *Orthodox Confession*. Asking what Lutherans teach returned Eastern
Orthodox and patristic texts under a confident "Lutheran" heading, which is
worse than returning nothing.

Deliberately not a blanket purge of unprovenanced sources. Some of them carry
genuine text — the Thirty-Nine Articles open with the real Article I, the
Westminster Shorter Catechism with the real Question 1 — and deleting those
would destroy exactly the confessional material the corpus is short of. They
still need re-ingesting with provenance; that is tracked separately.

Dry run by default.

    python3 tools/fix_legacy_metadata.py
    python3 tools/fix_legacy_metadata.py --write
"""

import argparse
import shutil
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "assets" / "theology.db"

# title -> the tradition it actually belongs to.
RELABEL = {
    # None of these are Lutheran.
    "The Didache": "Early Church",
    "The Philokalia Selections": "Eastern Orthodox",
    "The Life of Moses (Gregory of Nyssa)": "Early Church",
    "The Orthodox Confession of Faith (Peter Mogila)": "Eastern Orthodox",
    # "Universal" was being used as an unknown bucket.
    "Council of Trent": "Catholic",
    "Summa Theologica Selections (Aquinas)": "Catholic",
    # Wesley is the founder of Methodism; filing him under Anglican makes a
    # question about Methodist teaching miss him.
    "Wesleys Standard Sermons": "Methodist",
}

# Unprovenanced sources whose text duplicates a properly-ingested one. Verified
# by comparing openings against the provenanced copy rather than by title
# similarity, which produced nonsense matches ("Against Heresies" against
# "Sermon against Auxentius").
DUPLICATES = [
    "On the Incarnation of the Word",
    "The City of God",
    "On the Trinity (Augustine)",
    "The Epistle of Ignatius to the Ephesians",
    "The Epistle of Ignatius to the Philadelphians",
    "The Epistle of Ignatius to the Trallians",
    "The Epistle of Ignatius to the Romans",
]


def unprovenanced_id(conn, title):
    row = conn.execute(
        """SELECT id FROM sources
           WHERE title = ? AND (source_url IS NULL OR source_url = '')""",
        (title,),
    ).fetchone()
    return row[0] if row else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    conn = sqlite3.connect(
        f"file:{args.db}{'' if args.write else '?mode=ro'}", uri=True
    )

    traditions = {n: i for i, n in conn.execute("SELECT id, name FROM traditions")}

    print("Relabelling:")
    relabel_ops = []
    for title, tradition in RELABEL.items():
        source_id = unprovenanced_id(conn, title)
        if source_id is None:
            print(f"  SKIP (not found) {title}", file=sys.stderr)
            continue
        current = conn.execute(
            """SELECT t.name FROM sources s
               LEFT JOIN traditions t ON s.tradition_id = t.id
               WHERE s.id = ?""",
            (source_id,),
        ).fetchone()[0]
        print(f"  {title[:46]:<48} {current} -> {tradition}")
        relabel_ops.append((traditions[tradition], source_id))

    print("\nDeleting duplicates of provenanced sources:")
    delete_ids, delete_units = [], 0
    for title in DUPLICATES:
        source_id = unprovenanced_id(conn, title)
        if source_id is None:
            print(f"  SKIP (not found) {title}", file=sys.stderr)
            continue
        units = conn.execute(
            "SELECT count(*) FROM content_units WHERE source_id = ?", (source_id,)
        ).fetchone()[0]
        print(f"  {title[:46]:<48} {units:>4} units")
        delete_ids.append(source_id)
        delete_units += units

    print(f"\n{len(relabel_ops)} relabelled, {len(delete_ids)} sources / "
          f"{delete_units} units deleted")

    if not args.write:
        print("\ndry run — pass --write to apply")
        return

    backup = args.db.with_suffix(".db.bak")
    shutil.copy2(args.db, backup)
    print(f"backup -> {backup}")

    conn.executemany(
        "UPDATE sources SET tradition_id = ? WHERE id = ?", relabel_ops
    )
    if delete_ids:
        marks = ",".join("?" * len(delete_ids))
        conn.execute(
            f"""DELETE FROM content_tags WHERE content_unit_id IN
                (SELECT id FROM content_units WHERE source_id IN ({marks}))""",
            delete_ids,
        )
        conn.execute(
            f"DELETE FROM content_units WHERE source_id IN ({marks})", delete_ids
        )
        conn.execute(f"DELETE FROM sources WHERE id IN ({marks})", delete_ids)

    conn.commit()
    conn.execute("INSERT INTO content_fts(content_fts) VALUES('rebuild')")
    conn.commit()
    print("applied — re-run build_chunks.py and build_embeddings.py")
    conn.close()


if __name__ == "__main__":
    main()
