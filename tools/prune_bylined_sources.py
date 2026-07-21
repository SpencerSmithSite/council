#!/usr/bin/env python3
"""Remove modern in-copyright works whose text is model-generated.

These sources carry a real author's byline over prose the corpus generator
wrote — Lewis, Piper, Bonhoeffer, Packer, Stott and others. Publishing
generated text under a living or recent author's name is not defensible
regardless of what we decide about corpus quality generally, so they go.

Dry run by default. Pass --write to modify assets/theology.db in place; the
original is recoverable with `git checkout assets/theology.db`.

Selection rule (both must hold):
  * in copyright, or dated after 1928 — i.e. not plausibly public domain
  * the title ends in a personal-name parenthetical, e.g. "Knowing God (Packer)"

Institutional documents without a personal byline (Lumen Gentium, the Barmen
Declaration, the Catechism) are deliberately NOT removed here. They have a
licensing problem but not an attribution one, and are handled separately.

Usage:
    python3 tools/prune_bylined_sources.py            # report only
    python3 tools/prune_bylined_sources.py --write    # apply
"""

import argparse
import re
import shutil
import sqlite3
import sys
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent.parent / "assets" / "theology.db"

BYLINE_RE = re.compile(r"\(([^)]+)\)\s*$")

# Parentheticals that are subtitles, editions, or institutions rather than a
# personal byline. Institutional documents have a licensing question but not an
# attribution one, so they are out of scope for this script.
NOT_A_BYLINE = {
    "word of god",
    "selections",
    "sbc",
    "a.d. 325",
    "a.d. 431",
    "1672",
}

PUBLIC_DOMAIN_CUTOFF = 1928


def parse_year(date_composed):
    try:
        return int((date_composed or "")[:4])
    except (ValueError, TypeError):
        return None


def is_bylined(title):
    match = BYLINE_RE.search(title or "")
    if not match:
        return False
    inner = match.group(1).strip().lower()
    if inner in NOT_A_BYLINE:
        return False
    # A byline is a name, not a sentence.
    return len(inner.split()) <= 3 and not inner.isdigit()


def select_sources(conn):
    doomed = []
    for s in conn.execute(
        "SELECT id, title, author, date_composed, license FROM sources"
    ):
        year = parse_year(s["date_composed"])
        modern = s["license"] in ("copyright", "fair use") or (
            year is not None and year > PUBLIC_DOMAIN_CUTOFF
        )
        if modern and is_bylined(s["title"]):
            doomed.append(s)
    return doomed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    if not args.db.exists():
        sys.exit(f"database not found: {args.db}")

    mode = "" if args.write else "?mode=ro"
    conn = sqlite3.connect(f"file:{args.db}{mode}", uri=True)
    conn.row_factory = sqlite3.Row

    doomed = select_sources(conn)
    ids = [s["id"] for s in doomed]

    if not ids:
        print("nothing to remove")
        return

    placeholders = ",".join("?" * len(ids))
    unit_count = conn.execute(
        f"SELECT count(*) FROM content_units WHERE source_id IN ({placeholders})", ids
    ).fetchone()[0]
    tag_count = conn.execute(
        f"""SELECT count(*) FROM content_tags WHERE content_unit_id IN
            (SELECT id FROM content_units WHERE source_id IN ({placeholders}))""",
        ids,
    ).fetchone()[0]

    print(f"{'REMOVING' if args.write else 'would remove'}:")
    print(f"  {len(ids):>5} sources")
    print(f"  {unit_count:>5} content units")
    print(f"  {tag_count:>5} tag associations\n")

    for s in sorted(doomed, key=lambda r: r["title"])[:15]:
        print(f"    {s['date_composed'] or '—':<10} {s['title']}")
    if len(doomed) > 15:
        print(f"    … and {len(doomed) - 15} more")

    before = conn.execute("SELECT count(*) FROM content_units").fetchone()[0]
    print(f"\n  corpus: {before} units → {before - unit_count} units")

    if not args.write:
        print("\ndry run — pass --write to apply")
        return

    backup = args.db.with_suffix(".db.bak")
    shutil.copy2(args.db, backup)
    print(f"\nbackup written to {backup}")

    conn.execute("PRAGMA foreign_keys = ON")
    with conn:
        conn.execute(
            f"""DELETE FROM content_tags WHERE content_unit_id IN
                (SELECT id FROM content_units WHERE source_id IN ({placeholders}))""",
            ids,
        )
        conn.execute(
            f"DELETE FROM content_units WHERE source_id IN ({placeholders})", ids
        )
        conn.execute(f"DELETE FROM sources WHERE id IN ({placeholders})", ids)

    # content_fts is an external-content FTS5 table with no sync triggers, so
    # deleting rows from content_units leaves the index stale. Rebuild it.
    conn.execute("INSERT INTO content_fts(content_fts) VALUES('rebuild')")
    conn.commit()
    conn.execute("VACUUM")
    conn.close()

    print("deleted, FTS index rebuilt, database vacuumed")


if __name__ == "__main__":
    main()
