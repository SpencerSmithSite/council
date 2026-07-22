#!/usr/bin/env python3
"""Split the corpus into a bundled core and downloadable packs.

The app is 101 MB on Android and 119 MB on iOS, and 54 MB of that is the
corpus. Almost all of it is patristic: 56.3 of 58.8 million characters are
early-church, so a reader who only wants the confessions of their own tradition
currently downloads the complete works of Chrysostom to get them.

**Packs are a partition of one corpus build, not separately-built databases.**
That is the whole reason this is safe. Every row keeps the id it already has,
so ids are disjoint across packs by construction and nothing has to be
renumbered on install. The alternative — building each pack independently and
offsetting ids into reserved ranges — is how you get the failure this project
has already had once: chunk ids are derived from unit ids, embeddings are keyed
on chunk ids, and a renumbering that goes wrong does not raise an error, it
just silently points vectors at unrelated text.

The corollary is a rule: **packs and the core must always be built together
from the same corpus, and `corpusVersion` must be bumped when they are.** A
pack built against a different corpus can collide with ids the app already has.
The manifest records the version so the app can refuse a mismatch.

Packs carry no FTS index. The index lives in the app's database and is appended
to on install, which costs a little install time and saves shipping a second
copy of every byte of text.

    python3 tools/build_packs.py            # report the split, write nothing
    python3 tools/build_packs.py --write    # build core + packs
"""

import argparse
import gzip
import hashlib
import json
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "assets" / "theology.db"
CORE_GZ = ROOT / "assets" / "theology.db.gz"
CONFIG_PATH = ROOT / "tools" / "data" / "packs.json"
DIST = ROOT / "dist" / "packs"

# Must match DatabaseService.corpusVersion. The app refuses a pack whose
# corpusVersion differs from its own, because ids are only guaranteed disjoint
# within a single build.
CORPUS_VERSION = 3

# Reference tables are small, shared, and copied whole into every pack, so that
# installing a pack cannot leave a source pointing at a tradition the app has
# never heard of. They are inserted with OR IGNORE, so overlap is free.
REFERENCE_TABLES = ["traditions", "source_types", "tags", "authors", "works"]

# Copied per-pack, in dependency order.
CONTENT_TABLES = [
    "sources",
    "content_units",
    "content_tags",
    "content_chunks",
    "chunk_embeddings",
]


def load_config():
    with open(CONFIG_PATH) as handle:
        return json.load(handle)["packs"]


def assign_sources(conn, packs):
    """Map every source id to a pack id, defaulting to core.

    First match wins, in declaration order, which is what lets a broad pack sit
    after narrow ones: "fathers" claims all of early-church, but Augustine and
    Chrysostom are pulled out ahead of it.
    """
    rows = conn.execute(
        """SELECT s.id, s.author, COALESCE(t.slug, '')
           FROM sources s LEFT JOIN traditions t ON s.tradition_id = t.id"""
    ).fetchall()

    assignment = {}
    for source_id, author, tradition in rows:
        for pack in packs:
            if author and author in pack.get("authors", []):
                assignment[source_id] = pack["id"]
                break
            if tradition and tradition in pack.get("traditions", []):
                assignment[source_id] = pack["id"]
                break
        else:
            assignment[source_id] = "core"
    return assignment


def pack_stats(conn, source_ids):
    if not source_ids:
        return {"sources": 0, "units": 0, "chunks": 0, "chars": 0}
    marks = ",".join("?" * len(source_ids))
    units, chars = conn.execute(
        f"SELECT COUNT(*), COALESCE(SUM(LENGTH(content)), 0) "
        f"FROM content_units WHERE source_id IN ({marks})",
        source_ids,
    ).fetchone()
    chunks = conn.execute(
        f"""SELECT COUNT(*) FROM content_chunks
            WHERE content_unit_id IN
              (SELECT id FROM content_units WHERE source_id IN ({marks}))""",
        source_ids,
    ).fetchone()[0]
    return {
        "sources": len(source_ids),
        "units": units,
        "chunks": chunks,
        "chars": chars,
    }


def schema_statements(conn, include_fts):
    """DDL for a fresh pack database.

    FTS tables and their shadow tables are excluded: a pack's text is indexed
    into the app's existing index on install, so shipping an index here would
    duplicate the entire corpus a second time.
    """
    statements = []
    for name, sql in conn.execute(
        "SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL"
    ):
        if not include_fts and (name.startswith("content_fts")):
            continue
        statements.append(sql)
    return statements


def build_pack(conn, pack_id, source_ids, out_path):
    """Write a data-only database holding exactly this pack's sources."""
    if out_path.exists():
        out_path.unlink()

    out = sqlite3.connect(out_path)
    for sql in schema_statements(conn, include_fts=False):
        out.execute(sql)

    out.execute("ATTACH DATABASE ? AS src", (str(DB_PATH),))
    marks = ",".join("?" * len(source_ids))

    for table in REFERENCE_TABLES:
        out.execute(f"INSERT OR IGNORE INTO {table} SELECT * FROM src.{table}")

    out.execute(
        f"INSERT INTO sources SELECT * FROM src.sources WHERE id IN ({marks})",
        source_ids,
    )
    out.execute(
        f"""INSERT INTO content_units SELECT * FROM src.content_units
            WHERE source_id IN ({marks})""",
        source_ids,
    )
    out.execute(
        """INSERT INTO content_tags SELECT * FROM src.content_tags
           WHERE content_unit_id IN (SELECT id FROM content_units)"""
    )
    out.execute(
        """INSERT INTO content_chunks SELECT * FROM src.content_chunks
           WHERE content_unit_id IN (SELECT id FROM content_units)"""
    )
    out.execute(
        """INSERT INTO chunk_embeddings SELECT * FROM src.chunk_embeddings
           WHERE chunk_id IN (SELECT id FROM content_chunks)"""
    )

    out.commit()
    out.execute("DETACH DATABASE src")
    out.execute("VACUUM")
    out.commit()
    out.close()


def build_core(conn_path, keep_source_ids, out_path):
    """Copy the corpus and delete everything the core does not keep.

    Built by subtraction rather than by copying rows into a fresh database so
    that the core keeps its FTS index, its shadow tables and its page layout
    exactly as the app expects to open them.
    """
    if out_path.exists():
        out_path.unlink()
    shutil.copyfile(conn_path, out_path)

    db = sqlite3.connect(out_path)
    marks = ",".join("?" * len(keep_source_ids))

    db.execute(
        f"""DELETE FROM chunk_embeddings WHERE chunk_id IN (
              SELECT c.id FROM content_chunks c
              JOIN content_units u ON c.content_unit_id = u.id
              WHERE u.source_id NOT IN ({marks}))""",
        keep_source_ids,
    )
    db.execute(
        f"""DELETE FROM content_chunks WHERE content_unit_id IN (
              SELECT id FROM content_units WHERE source_id NOT IN ({marks}))""",
        keep_source_ids,
    )
    db.execute(
        f"""DELETE FROM content_tags WHERE content_unit_id IN (
              SELECT id FROM content_units WHERE source_id NOT IN ({marks}))""",
        keep_source_ids,
    )
    db.execute(
        f"DELETE FROM content_units WHERE source_id NOT IN ({marks})",
        keep_source_ids,
    )
    db.execute(f"DELETE FROM sources WHERE id NOT IN ({marks})", keep_source_ids)

    # External-content FTS5 has no sync triggers: deleting the underlying rows
    # leaves the index describing text that is no longer there, and searches
    # return matches that cannot be opened. Rebuilding is the only fix.
    db.execute("INSERT INTO content_fts(content_fts) VALUES('rebuild')")
    db.commit()
    db.execute("VACUUM")
    db.commit()
    db.close()


def gzip_file(path):
    out = path.with_suffix(path.suffix + ".gz")
    with open(path, "rb") as raw, gzip.open(out, "wb", compresslevel=9) as gz:
        shutil.copyfileobj(raw, gz)
    return out


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="build the packs")
    args = parser.parse_args()

    if not DB_PATH.exists():
        sys.exit(f"No corpus at {DB_PATH}")

    packs = load_config()
    conn = sqlite3.connect(DB_PATH)
    assignment = assign_sources(conn, packs)

    by_pack = {}
    for source_id, pack_id in assignment.items():
        by_pack.setdefault(pack_id, []).append(source_id)

    declared = {pack["id"] for pack in packs}
    unknown = set(by_pack) - declared - {"core"}
    if unknown:
        sys.exit(f"Sources assigned to undeclared packs: {sorted(unknown)}")

    print(f"{'pack':22} {'sources':>8} {'units':>8} {'chunks':>8} {'chars':>10}")
    order = ["core"] + [pack["id"] for pack in packs]
    for pack_id in order:
        stats = pack_stats(conn, by_pack.get(pack_id, []))
        print(
            f"{pack_id:22} {stats['sources']:8} {stats['units']:8} "
            f"{stats['chunks']:8} {stats['chars'] / 1e6:9.1f}M"
        )

    if not args.write:
        print("\nDry run. Pass --write to build.")
        return

    DIST.mkdir(parents=True, exist_ok=True)
    manifest = {"corpusVersion": CORPUS_VERSION, "packs": []}

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)

        print("\nBuilding core...")
        core_db = tmp / "core.db"
        build_core(DB_PATH, by_pack.get("core", []), core_db)
        core_gz = gzip_file(core_db)
        shutil.copyfile(core_gz, CORE_GZ)
        print(f"  {CORE_GZ.name}  {CORE_GZ.stat().st_size / 1e6:.1f} MB")

        for pack in packs:
            source_ids = by_pack.get(pack["id"], [])
            if not source_ids:
                print(f"  skipping empty pack {pack['id']}")
                continue

            print(f"Building {pack['id']}...")
            pack_db = tmp / f"{pack['id']}.db"
            build_pack(conn, pack["id"], source_ids, pack_db)
            pack_gz = gzip_file(pack_db)
            final = DIST / pack_gz.name
            shutil.copyfile(pack_gz, final)

            stats = pack_stats(conn, source_ids)
            manifest["packs"].append(
                {
                    "id": pack["id"],
                    "name": pack["name"],
                    "description": pack["description"],
                    "file": final.name,
                    "bytes": final.stat().st_size,
                    "sha256": sha256(final),
                    "sources": stats["sources"],
                    "units": stats["units"],
                    "chunks": stats["chunks"],
                }
            )
            print(f"  {final.name}  {final.stat().st_size / 1e6:.1f} MB")

    with open(DIST / "manifest.json", "w") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")

    print(f"\nWrote {DIST / 'manifest.json'}")
    print(f"Remember: DatabaseService.corpusVersion must be {CORPUS_VERSION}")


if __name__ == "__main__":
    main()
