#!/usr/bin/env python3
"""Load ingested works into assets/theology.db with real provenance.

Adds a `provenance` column to content_units, backfills it for the existing
corpus using tools/audit_corpus.py, then inserts newly ingested works marked
`primary_text` with their source URL, translator and edition recorded.

Dry run by default.

    python3 tools/build_corpus.py                     # report
    python3 tools/build_corpus.py --write             # insert
    python3 tools/build_corpus.py --write --drop-generated
"""

import argparse
import json
import re
import shutil
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_corpus import classify, load_units, PRIMARY  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "assets" / "theology.db"
UNITS = ROOT / "tools" / "data" / "newadvent_units.json"

TRADITION_EARLY_CHURCH = 10
TRADITION_ECUMENICAL = 11
TYPE_COUNCIL = 4
TYPE_FATHER = 5

# Keyword -> tag slug, matched on whole words. Mirrors the app's own mapping in
# DatabaseService so newly ingested units are retrievable by tag too.
TAG_KEYWORDS = {
    "trinity": "trinity", "incarnation": "incarnation", "christology": "christology",
    "salvation": "salvation", "grace": "grace", "baptism": "baptism",
    "eucharist": "eucharist", "sin": "sin", "justification": "justification",
    "faith": "faith", "prayer": "prayer", "church": "church",
    "scripture": "scripture", "creation": "creation", "sanctification": "sanctification",
    "worship": "worship", "sacrament": "sacraments", "angel": "angels",
    "resurrection": "eschatology", "judgment": "last-judgment",
    "holy spirit": "holy-spirit",
}


def slugify(text, taken):
    base = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:80] or "source"
    slug, n = base, 2
    while slug in taken:
        slug = f"{base}-{n}"
        n += 1
    taken.add(slug)
    return slug


def ensure_provenance_column(conn):
    cols = {r[1] for r in conn.execute("PRAGMA table_info(content_units)")}
    if "provenance" not in cols:
        conn.execute("ALTER TABLE content_units ADD COLUMN provenance TEXT")
        return True
    return False


def backfill_provenance(conn):
    """Label the pre-existing corpus using the audit classifier."""
    verdicts = classify(load_units(conn))
    conn.executemany(
        "UPDATE content_units SET provenance = ? WHERE id = ?",
        [(verdict, uid) for uid, (verdict, _) in verdicts.items()],
    )
    return verdicts


def parse_years(author_dates):
    if not author_dates:
        return None, None
    years = re.findall(r"\d{3,4}", author_dates)
    if len(years) >= 2:
        return int(years[0]), int(years[1])
    return (int(years[0]), None) if years else (None, None)


def tags_for(text, tag_ids):
    lower = text.lower()
    found = set()
    for keyword, slug in TAG_KEYWORDS.items():
        if slug in tag_ids and re.search(rf"\b{re.escape(keyword)}(s|es)?\b", lower):
            found.add(tag_ids[slug])
    return found


def insert_works(conn, works, tag_ids):
    taken_slugs = {r[0] for r in conn.execute("SELECT slug FROM sources")}
    author_slugs = {r[0]: r[1] for r in conn.execute("SELECT slug, id FROM authors")}

    next_unit_id = (
        conn.execute("SELECT coalesce(max(id), 0) FROM content_units").fetchone()[0] + 1
    )
    inserted_sources = inserted_units = inserted_tags = 0

    for work in works:
        author = work["author"]
        is_council = author.lower().startswith("council")
        birth, death = parse_years(work.get("author_dates"))
        prov = work.get("provenance") or {}

        # authors table has been empty since the project started; populate it.
        author_slug = re.sub(r"[^a-z0-9]+", "-", author.lower()).strip("-")
        if author_slug and author_slug not in author_slugs:
            cur = conn.execute(
                """INSERT INTO authors (name, slug, birth_year, death_year, tradition_id)
                   VALUES (?, ?, ?, ?, ?)""",
                (author, author_slug, birth, death,
                 TRADITION_ECUMENICAL if is_council else TRADITION_EARLY_CHURCH),
            )
            author_slugs[author_slug] = cur.lastrowid

        citation = prov.get("citation") or ""
        notes = " | ".join(
            x for x in (
                f"Translated by {prov['translator']}" if prov.get("translator") else None,
                prov.get("edition"),
                f"Public-domain translation, {prov['year']}" if prov.get("year") else None,
                "Ingested from newadvent.org",
            ) if x
        )

        cur = conn.execute(
            """INSERT INTO sources
               (source_type_id, tradition_id, title, slug, author, date_composed,
                date_composed_approx, language_source, source_url, license,
                public_domain, notes)
               VALUES (?, ?, ?, ?, ?, ?, 1, 'en', ?, 'public domain', 1, ?)""",
            (
                TYPE_COUNCIL if is_council else TYPE_FATHER,
                TRADITION_ECUMENICAL if is_council else TRADITION_EARLY_CHURCH,
                work["title"],
                slugify(f"{work['title']}-{author}", taken_slugs),
                author,
                work.get("author_dates"),
                work["url"],
                notes or citation[:300],
            ),
        )
        source_id = cur.lastrowid
        inserted_sources += 1

        for seq, unit in enumerate(work["units"], 1):
            content = unit["content"]
            conn.execute(
                """INSERT INTO content_units
                   (id, source_id, unit_type, unit_number, title, content,
                    content_plain, sequence, provenance)
                   VALUES (?, ?, 'section', ?, ?, ?, ?, ?, 'primary_text')""",
                (next_unit_id, source_id, unit.get("number"), unit["title"],
                 content, content, seq),
            )
            for tag_id in tags_for(f"{unit['title']} {content[:4000]}", tag_ids):
                conn.execute(
                    "INSERT OR IGNORE INTO content_tags (content_unit_id, tag_id) VALUES (?, ?)",
                    (next_unit_id, tag_id),
                )
                inserted_tags += 1
            next_unit_id += 1
            inserted_units += 1

    return inserted_sources, inserted_units, inserted_tags


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--units", type=Path, default=UNITS)
    parser.add_argument("--write", action="store_true")
    parser.add_argument(
        "--drop-generated",
        action="store_true",
        help="also delete units the audit classifies as generated or boilerplate",
    )
    args = parser.parse_args()

    if not args.units.exists():
        sys.exit(f"no ingested units at {args.units} — run ingest_newadvent.py first")

    works = json.loads(args.units.read_text(encoding="utf-8"))
    total_units = sum(len(w["units"]) for w in works)
    print(f"ingested input: {len(works)} works, {total_units} units")

    if not args.write:
        by_author = {}
        for w in works:
            by_author[w["author"]] = by_author.get(w["author"], 0) + len(w["units"])
        for author, n in sorted(by_author.items(), key=lambda kv: -kv[1])[:10]:
            print(f"    {n:>5} units  {author}")
        print("\ndry run — pass --write to apply")
        return

    backup = args.db.with_suffix(".db.bak")
    shutil.copy2(args.db, backup)
    print(f"backup -> {backup}")

    conn = sqlite3.connect(args.db)
    conn.row_factory = sqlite3.Row

    added = ensure_provenance_column(conn)
    print(f"provenance column: {'added' if added else 'already present'}")

    verdicts = backfill_provenance(conn)
    generated = [uid for uid, (v, _) in verdicts.items() if v != PRIMARY]
    print(f"backfilled {len(verdicts)} existing units ({len(generated)} not primary)")

    tag_ids = {r["slug"]: r["id"] for r in conn.execute("SELECT id, slug FROM tags")}
    s, u, t = insert_works(conn, works, tag_ids)
    print(f"inserted {s} sources, {u} units, {t} tag associations")

    if args.drop_generated:
        marks = ",".join("?" * len(generated))
        conn.execute(
            f"DELETE FROM content_tags WHERE content_unit_id IN ({marks})", generated
        )
        conn.execute(f"DELETE FROM content_units WHERE id IN ({marks})", generated)
        conn.execute(
            """DELETE FROM sources WHERE id NOT IN
               (SELECT DISTINCT source_id FROM content_units)"""
        )
        print(f"dropped {len(generated)} generated units and now-empty sources")

    conn.commit()
    conn.execute("INSERT INTO content_fts(content_fts) VALUES('rebuild')")
    conn.commit()
    conn.execute("VACUUM")

    final_sources = conn.execute("SELECT count(*) FROM sources").fetchone()[0]
    final_units = conn.execute("SELECT count(*) FROM content_units").fetchone()[0]
    print(f"corpus now: {final_sources} sources, {final_units} content units")
    conn.close()


if __name__ == "__main__":
    main()
