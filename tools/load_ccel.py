#!/usr/bin/env python3
"""Load ingested confessional documents into assets/theology.db.

Takes any units file produced by an ingester (`ingest_ccel.py`,
`ingest_gutenberg.py`) — they share a record shape deliberately, so adding a
source does not mean adding a loader.

Inserts each document as a source with real provenance — source_url, rights,
and the collection it came from — and replaces the unprovenanced legacy entry
of the same tradition where one exists.

Dry run by default.

    python3 tools/load_ccel.py
    python3 tools/load_ccel.py --write
"""

import argparse
import json
import re
import shutil
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "assets" / "theology.db"
UNITS = ROOT / "tools" / "data" / "ccel_units.json"


def slugify(text, taken):
    base = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:80] or "source"
    slug, n = base, 2
    while slug in taken:
        slug = f"{base}-{n}"
        n += 1
    taken.add(slug)
    return slug


def lookup(conn, table, name):
    row = conn.execute(f"SELECT id FROM {table} WHERE name = ?", (name,)).fetchone()
    if row is None:
        raise SystemExit(f"no {table} row named {name!r}")
    return row[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--units", type=Path, default=UNITS)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    records = json.loads(args.units.read_text(encoding="utf-8"))
    total = sum(len(r["units"]) for r in records)
    print(f"{len(records)} documents, {total} units")
    for record in records:
        print(f"  {record['title']:<30} {len(record['units']):>4} units  "
              f"{record['tradition']}")

    if not args.write:
        print("\ndry run — pass --write to load")
        return

    backup = args.db.with_suffix(".db.bak")
    shutil.copy2(args.db, backup)
    print(f"\nbackup -> {backup}")

    conn = sqlite3.connect(args.db)
    taken = {r[0] for r in conn.execute("SELECT slug FROM sources")}
    next_unit_id = conn.execute(
        "SELECT coalesce(max(id), 0) FROM content_units"
    ).fetchone()[0] + 1

    inserted_sources = inserted_units = 0

    for record in records:
        tradition_id = lookup(conn, "traditions", record["tradition"])
        type_id = lookup(conn, "source_types", record["kind"])

        # Drop any existing source with this title — the legacy entries are
        # unprovenanced paraphrase and this replaces them outright.
        stale = conn.execute(
            "SELECT id FROM sources WHERE title = ?", (record["title"],)
        ).fetchall()
        for (source_id,) in stale:
            conn.execute(
                """DELETE FROM content_tags WHERE content_unit_id IN
                   (SELECT id FROM content_units WHERE source_id = ?)""",
                (source_id,),
            )
            conn.execute("DELETE FROM content_units WHERE source_id = ?", (source_id,))
            conn.execute("DELETE FROM sources WHERE id = ?", (source_id,))
            print(f"  replaced stale source {source_id} ({record['title']})")

        origin = record["url"].split("/")[2] if "//" in record["url"] else "unknown"
        notes = " | ".join(x for x in (
            f"From {record['collection']}" if record.get("collection") else None,
            f"Translated by {record['translator']}" if record.get("translator") else None,
            f"Edited by {record['editor']}" if record.get("editor") else None,
            f"Rights: {record['rights']}",
            f"Ingested from {origin}",
        ) if x)

        cursor = conn.execute(
            """INSERT INTO sources
               (source_type_id, tradition_id, title, slug, date_composed,
                date_composed_approx, language_source, source_url, license,
                public_domain, notes)
               VALUES (?, ?, ?, ?, ?, 0, 'en', ?, 'public domain', 1, ?)""",
            (
                type_id,
                tradition_id,
                record["title"],
                slugify(record["title"], taken),
                record["date"],
                record["url"],
                notes,
            ),
        )
        source_id = cursor.lastrowid
        inserted_sources += 1

        for sequence, unit in enumerate(record["units"], 1):
            conn.execute(
                """INSERT INTO content_units
                   (id, source_id, unit_type, unit_number, title, content,
                    sequence, provenance)
                   VALUES (?, ?, ?, ?, ?, ?, ?, 'primary_text')""",
                (next_unit_id, source_id,
                 "qa" if record["kind"] == "Catechism" else "article",
                 unit["number"], unit["title"], unit["content"], sequence),
            )
            next_unit_id += 1
            inserted_units += 1

    conn.commit()
    conn.execute("INSERT INTO content_fts(content_fts) VALUES('rebuild')")
    conn.commit()

    print(f"inserted {inserted_sources} sources, {inserted_units} units")
    print("now re-run: build_chunks.py --write && build_embeddings.py --write")
    conn.close()


if __name__ == "__main__":
    main()
