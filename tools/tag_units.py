#!/usr/bin/env python3
"""Assign topic tags to content units that have none.

Tagging only ever ran inside `build_corpus.py`, which is the New Advent path.
Every document ingested since — through `load_ccel.py`, from CCEL, Gutenberg
and archive.org — arrived untagged. That is 832 units and, crucially, *which*
832: Trent, the Augsburg Confession and its Apology, the Westminster
catechisms, Heidelberg, Dordt, the Belgic, the Thirty-Nine Articles. The
confessional documents. The ones that answer "how do Catholics and Lutherans
differ on baptism?"

Three things were broken by it:

* **Tag search returned nothing for them.** It is one of the three engines
  fused in `searchForRAG`, so comparative questions ran on two.
* **The coverage notice overstated the gap.** It compares tag counts in the
  bundled core against those in the packs; core's confessional counts were
  zero, so every subject looked almost entirely missing.
* **It got worse, not better, in the last phase.** The abridged legacy stubs
  were 98% tagged. Replacing them with properly-sourced full texts moved
  confessional tag coverage from "works, via stubs" to "nothing at all" — an
  improvement in the corpus that was a regression in retrieval.

The keyword logic is imported from `build_corpus.py` rather than restated, so
the two cannot drift into tagging the same text differently.

Dry run by default.

    python3 tools/tag_units.py
    python3 tools/tag_units.py --write
"""

import argparse
import shutil
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from build_corpus import TAG_KEYWORDS, tags_for  # noqa: E402

DB_PATH = ROOT / "assets" / "theology.db"

# Matches build_corpus.py: the tagger reads the title and the opening of the
# body. A confession article states its subject early; scanning the whole text
# mostly adds passing mentions.
SCAN_CHARS = 4000


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--all", action="store_true",
                        help="re-tag every unit, not only untagged ones")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    conn = sqlite3.connect(args.db)
    tag_ids = {slug: tid for slug, tid in conn.execute("SELECT slug, id FROM tags")}

    missing = set(TAG_KEYWORDS.values()) - set(tag_ids)
    if missing:
        sys.exit(f"tag vocabulary missing rows for {sorted(missing)}")

    scope = "" if args.all else """
        WHERE cu.id NOT IN (SELECT content_unit_id FROM content_tags)"""
    rows = conn.execute(f"""
        SELECT cu.id, cu.title, cu.content FROM content_units cu {scope}
    """).fetchall()

    print(f"{len(rows)} units to consider")

    assignments = []
    untouched = 0
    for unit_id, title, content in rows:
        found = tags_for(f"{title or ''} {(content or '')[:SCAN_CHARS]}", tag_ids)
        if not found:
            untouched += 1
            continue
        assignments.extend((unit_id, tag_id) for tag_id in found)

    print(f"{len(assignments)} tag assignments across "
          f"{len(rows) - untouched} units")
    print(f"{untouched} units matched no keyword and stay untagged")

    # Report by tradition, because the point of this is the confessional
    # documents specifically, not the raw total.
    print("\nby tradition")
    for slug, total, tagged in conn.execute("""
        SELECT COALESCE(t.slug, '(none)'), COUNT(DISTINCT cu.id),
               COUNT(DISTINCT ct.content_unit_id)
        FROM sources s
        LEFT JOIN traditions t ON s.tradition_id = t.id
        JOIN content_units cu ON cu.source_id = s.id
        LEFT JOIN content_tags ct ON ct.content_unit_id = cu.id
        GROUP BY 1 ORDER BY 2 DESC
    """):
        print(f"  {slug:20} {tagged:6}/{total:<6} tagged")

    if not args.write:
        print("\ndry run — pass --write to apply")
        return

    backup = args.db.with_suffix(".db.bak")
    shutil.copy2(args.db, backup)
    print(f"\nbackup -> {backup}")

    if args.all:
        conn.execute("DELETE FROM content_tags")
    conn.executemany(
        "INSERT OR IGNORE INTO content_tags (content_unit_id, tag_id) "
        "VALUES (?, ?)", assignments)
    conn.commit()

    print("\nafter")
    for slug, total, tagged in conn.execute("""
        SELECT COALESCE(t.slug, '(none)'), COUNT(DISTINCT cu.id),
               COUNT(DISTINCT ct.content_unit_id)
        FROM sources s
        LEFT JOIN traditions t ON s.tradition_id = t.id
        JOIN content_units cu ON cu.source_id = s.id
        LEFT JOIN content_tags ct ON ct.content_unit_id = cu.id
        GROUP BY 1 ORDER BY 2 DESC
    """):
        print(f"  {slug:20} {tagged:6}/{total:<6} tagged")


if __name__ == "__main__":
    main()
