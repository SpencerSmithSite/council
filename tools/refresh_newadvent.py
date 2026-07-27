#!/usr/bin/env python3
"""Re-load re-parsed New Advent works over the ones already in the corpus.

`build_corpus.py` only appends: running it twice inserts every work a second
time. That was right for the initial load and is wrong for a correction, and a
correction is what the hub fix in `ingest_newadvent.py` produced — eighteen
works that were ingested as their contents page and are now ingested as their
text.

Works are matched on `source_url`, which is the New Advent work id and is
unique per work. A work whose parsed units are byte-identical to the ones
stored is **skipped entirely**, not rewritten. That is not an optimisation:
replacing units means new `content_units.id` values, and the app's highlights
and notes live in a separate user database keyed on exactly those ids. Rewriting
all 400 works to fix 18 would silently detach every annotation a reader has ever
made on the other 382.

    python3 tools/refresh_newadvent.py                # report
    python3 tools/refresh_newadvent.py --write
"""

import argparse
import json
import shutil
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_corpus import insert_works, tags_for  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "assets" / "theology.db"
UNITS = ROOT / "tools" / "data" / "newadvent_units.json"

# A work is only replaced when the new parse is a clear improvement. A parse
# that comes back *shorter* is a regression — a fetch that half-failed, or a
# page whose markup moved — and it must not be allowed to overwrite good text
# just because it is newer.
MIN_GROWTH = 1.0


def stored_units(conn, source_id):
    return [
        (row[0], row[1])
        for row in conn.execute(
            "SELECT title, content FROM content_units "
            "WHERE source_id = ? ORDER BY sequence",
            (source_id,),
        )
    ]


def replace_units(conn, source_id, units, tag_ids):
    """Swap a source's units for the re-parsed ones.

    Chunks and embeddings hang off unit ids and are rebuilt afterwards by
    `build_chunks.py` / `build_embeddings.py`; they are deleted here so the
    intervening state is empty rather than pointing at rows that are gone.
    """
    conn.execute(
        """DELETE FROM chunk_embeddings WHERE chunk_id IN (
             SELECT c.id FROM content_chunks c
             JOIN content_units u ON c.content_unit_id = u.id
             WHERE u.source_id = ?)""",
        (source_id,),
    )
    conn.execute(
        """DELETE FROM content_chunks WHERE content_unit_id IN (
             SELECT id FROM content_units WHERE source_id = ?)""",
        (source_id,),
    )
    conn.execute(
        """DELETE FROM content_tags WHERE content_unit_id IN (
             SELECT id FROM content_units WHERE source_id = ?)""",
        (source_id,),
    )
    conn.execute("DELETE FROM content_units WHERE source_id = ?", (source_id,))

    next_id = conn.execute(
        "SELECT coalesce(max(id), 0) FROM content_units"
    ).fetchone()[0] + 1

    for sequence, unit in enumerate(units, 1):
        conn.execute(
            """INSERT INTO content_units
               (id, source_id, unit_type, unit_number, title, content,
                sequence, provenance)
               VALUES (?, ?, 'section', ?, ?, ?, ?, 'primary_text')""",
            (next_id, source_id, unit.get("number"), unit["title"],
             unit["content"], sequence),
        )
        for tag_id in tags_for(f"{unit['title']} {unit['content'][:4000]}", tag_ids):
            conn.execute(
                "INSERT OR IGNORE INTO content_tags "
                "(content_unit_id, tag_id) VALUES (?, ?)",
                (next_id, tag_id),
            )
        next_id += 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--units", type=Path, default=UNITS)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    works = json.loads(args.units.read_text(encoding="utf-8"))
    conn = sqlite3.connect(args.db)

    by_url = {
        row[1]: row[0]
        for row in conn.execute("SELECT id, source_url FROM sources")
        if row[1]
    }

    changed, unchanged, absent, shrunk = [], 0, [], []

    for work in works:
        source_id = by_url.get(work["url"])
        if source_id is None:
            absent.append(work)
            continue

        old = stored_units(conn, source_id)
        new = [(u["title"], u["content"]) for u in work["units"]]
        if old == new:
            unchanged += 1
            continue

        old_chars = sum(len(c) for _, c in old)
        new_chars = sum(len(c) for _, c in new)
        row = (source_id, work, len(old), old_chars, len(new), new_chars)
        if old_chars and new_chars < old_chars * MIN_GROWTH:
            shrunk.append(row)
        else:
            changed.append(row)

    changed.sort(key=lambda r: r[5] - r[3], reverse=True)

    print(f"{len(works)} parsed works; {unchanged} already match the corpus")
    if absent:
        # Not "new upstream": these are works the ingester used to drop —
        # two-book works that fell between the hub and flat paths, and works
        # whose parts are lettered rather than numbered. They were never in the
        # corpus, and no check reported them, because every check looked at
        # sources that exist.
        print(f"\n{len(absent)} works are not in the corpus at all — inserting:")
        for work in sorted(absent, key=lambda w: w["title"]):
            print(f"    {work['title'][:52]:54} {len(work['units']):>4} units "
                  f"{sum(len(u['content']) for u in work['units']):>8} chars")

    print(f"\n{len(changed)} works to replace:")
    for _, work, old_u, old_c, new_u, new_c in changed[:30]:
        print(f"    {work['title'][:44]:46} {old_u:>4}u {old_c:>8}c  ->  "
              f"{new_u:>5}u {new_c:>9}c")

    if shrunk:
        print(f"\n{len(shrunk)} works parse SHORTER than what is stored — "
              f"not replaced, inspect these:")
        for _, work, old_u, old_c, new_u, new_c in shrunk[:20]:
            print(f"    {work['title'][:44]:46} {old_u:>4}u {old_c:>8}c  ->  "
                  f"{new_u:>5}u {new_c:>9}c")

    gained = sum(r[5] - r[3] for r in changed)
    print(f"\nnet change: {gained / 1e6:+.1f} M characters")

    if not args.write:
        print("\ndry run — pass --write to apply")
        return

    backup = args.db.with_suffix(".db.bak")
    shutil.copy2(args.db, backup)
    print(f"backup -> {backup}")

    tag_ids = {row[1]: row[0] for row in conn.execute("SELECT id, slug FROM tags")}
    for source_id, work, *_ in changed:
        replace_units(conn, source_id, work["units"], tag_ids)

    if absent:
        added = insert_works(conn, absent, tag_ids)
        print(f"inserted {added[0]} missing sources, {added[1]} units")

    conn.commit()
    conn.execute("INSERT INTO content_fts(content_fts) VALUES('rebuild')")
    conn.commit()
    conn.execute("VACUUM")

    sources = conn.execute("SELECT count(*) FROM sources").fetchone()[0]
    units = conn.execute("SELECT count(*) FROM content_units").fetchone()[0]
    chars = conn.execute("SELECT sum(length(content)) FROM content_units").fetchone()[0]
    print(f"replaced {len(changed)} works")
    print(f"corpus now: {sources} sources, {units} units, {chars / 1e6:.1f} M chars")
    print("now re-run: build_chunks.py --write && build_embeddings.py --write")
    conn.close()


if __name__ == "__main__":
    main()
