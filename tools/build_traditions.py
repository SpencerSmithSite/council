#!/usr/bin/env python3
"""Apply the tradition taxonomy in `tools/data/traditions.json` to the corpus.

The `traditions` table was a flat list of fifteen rows that grew one ingest at
a time: whatever a source needed filing under got added, so "Early Church" and
"Baptist" sat at the same level as though they were the same kind of thing.
They are not. One is a period every branch inherits and the other is a family
inside one branch, and a reader arranging a shelf by tradition could not see
which was which.

This gives the table the shape the library actually has — **branch → family**,
with denominations to hang off families later — and it does so without moving
a single source. Families keep their ids and their `name`, so every foreign key
still resolves and every ingester's `lookup(conn, "traditions", ...)` still
finds its row by the name it has always passed.

**`name` is load-bearing and is never rewritten here.** Eleven ingesters and
every `*_units.json` file address traditions by name, and the app displays that
string on citations and shelf headings, where "Reformed, Presbyterian &
Congregational" would not fit. The taxonomy's expanded label goes in
`full_name` instead and the short name stays exactly as it was.

**The orphan guard is the point of the dry run.** A family removed from the
JSON while sources still point at its row would leave those sources filed under
a tradition the app cannot name, and nothing downstream would raise — the
citation would simply render blank. So a slug in the database and missing from
the taxonomy is a hard failure, not a warning, and the counts below are what to
read before passing --write.

Dry run by default.

    python3 tools/build_traditions.py
    python3 tools/build_traditions.py --write
"""

import argparse
import json
import shutil
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "assets" / "theology.db"
TAXONOMY = ROOT / "tools" / "data" / "traditions.json"

BRANCH_SCHEMA = """
CREATE TABLE IF NOT EXISTS branches (
  id INTEGER PRIMARY KEY,
  slug TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT,
  split_year INTEGER,
  sort_order INTEGER NOT NULL DEFAULT 0
);
"""

# Added rather than recreated: rebuilding `traditions` would renumber its ids,
# and `sources.tradition_id` points at them.
NEW_COLUMNS = {
    "branch_id": "INTEGER REFERENCES branches(id)",
    "parent_id": "INTEGER REFERENCES traditions(id)",
    "full_name": "TEXT",
    "sort_order": "INTEGER NOT NULL DEFAULT 0",
}


def add_missing_columns(conn):
    existing = {row[1] for row in conn.execute("PRAGMA table_info(traditions)")}
    for column, decl in NEW_COLUMNS.items():
        if column not in existing:
            conn.execute(f"ALTER TABLE traditions ADD COLUMN {column} {decl}")


def check_no_orphans(conn, families):
    """Every tradition already in the database must survive the taxonomy.

    Checked by slug and by name separately. Slug is the identity this script
    matches on; name is what the ingesters look up. A taxonomy that renamed a
    row would satisfy the first test and silently break every ingester, so both
    are asserted.
    """
    slugs = {f["slug"] for f in families}
    names = {f["name"] for f in families}
    rows = conn.execute("SELECT slug, name FROM traditions").fetchall()

    lost_slugs = sorted(s for s, _ in rows if s not in slugs)
    lost_names = sorted(n for _, n in rows if n not in names)
    if lost_slugs or lost_names:
        if lost_slugs:
            print(f"  slugs in the database and not in the taxonomy: {lost_slugs}",
                  file=sys.stderr)
        if lost_names:
            print(f"  names in the database and not in the taxonomy: {lost_names}",
                  file=sys.stderr)
        sys.exit(
            "refusing to run: this would leave sources pointing at a tradition "
            "the app cannot name."
        )

    used = dict(conn.execute(
        """SELECT t.slug, count(s.id) FROM traditions t
           LEFT JOIN sources s ON s.tradition_id = t.id
           GROUP BY t.id"""
    ).fetchall())
    return used


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--taxonomy", type=Path, default=TAXONOMY)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    taxonomy = json.loads(args.taxonomy.read_text(encoding="utf-8"))
    branches, families = taxonomy["branches"], taxonomy["families"]

    known = {b["slug"] for b in branches}
    for family in families:
        if family["branch"] not in known:
            sys.exit(f"{family['slug']}: unknown branch {family['branch']!r}")
    by_slug = {f["slug"]: f for f in families}
    for family in families:
        parent = family.get("parent")
        if parent and parent not in by_slug:
            sys.exit(f"{family['slug']}: unknown parent {parent!r}")

    mode = "" if args.write else "?mode=ro"
    conn = sqlite3.connect(f"file:{args.db}{mode}", uri=True)
    used = check_no_orphans(conn, families)

    existing = {row[0] for row in conn.execute("SELECT slug FROM traditions")}
    adding = [f for f in families if f["slug"] not in existing]

    print(f"{len(branches)} branches, {len(families)} families "
          f"({len(existing)} already present, {len(adding)} new)\n")
    for branch in sorted(branches, key=lambda b: b["sort_order"]):
        split = f"  (split {branch['split_year']})" if branch.get("split_year") else ""
        print(f"{branch['name']}{split}")
        members = [f for f in families if f["branch"] == branch["slug"]]
        for family in sorted(members, key=lambda f: f["sort_order"]):
            count = used.get(family["slug"])
            held = f"{count} sources" if count else "empty"
            mark = " " if family["slug"] in existing else "+"
            under = f" (under {family['parent']})" if family.get("parent") else ""
            print(f"  {mark} {family['name']:<32} {held}{under}")
        print()

    if not args.write:
        print("dry run — pass --write to apply")
        return

    backup = args.db.with_suffix(".db.bak")
    shutil.copy2(args.db, backup)
    print(f"backup -> {backup}")

    conn.executescript(BRANCH_SCHEMA)
    add_missing_columns(conn)

    for branch in branches:
        conn.execute(
            """INSERT INTO branches (slug, name, description, split_year, sort_order)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(slug) DO UPDATE SET
                 name = excluded.name,
                 description = excluded.description,
                 split_year = excluded.split_year,
                 sort_order = excluded.sort_order""",
            (branch["slug"], branch["name"], branch.get("description"),
             branch.get("split_year"), branch["sort_order"]),
        )
    branch_ids = dict(conn.execute("SELECT slug, id FROM branches").fetchall())

    # Two passes: every family must exist before any parent can be resolved to
    # an id, or a family declared before its parent gets a null one.
    for family in families:
        conn.execute(
            """INSERT INTO traditions (slug, name, description, full_name,
                                       branch_id, sort_order)
               VALUES (?, ?, ?, ?, ?, ?)
               ON CONFLICT(slug) DO UPDATE SET
                 description = coalesce(excluded.description, traditions.description),
                 full_name = excluded.full_name,
                 branch_id = excluded.branch_id,
                 sort_order = excluded.sort_order""",
            (family["slug"], family["name"], family.get("description"),
             family.get("full_name"), branch_ids[family["branch"]],
             family["sort_order"]),
        )
    family_ids = dict(conn.execute("SELECT slug, id FROM traditions").fetchall())
    for family in families:
        conn.execute(
            "UPDATE traditions SET parent_id = ? WHERE slug = ?",
            (family_ids[family["parent"]] if family.get("parent") else None,
             family["slug"]),
        )

    conn.commit()
    total = conn.execute("SELECT count(*) FROM traditions").fetchone()[0]
    print(f"\n{len(branches)} branches, {total} traditions")
    print("now re-run: build_packs.py --write")
    conn.close()


if __name__ == "__main__":
    main()
