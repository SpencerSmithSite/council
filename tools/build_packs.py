#!/usr/bin/env python3
"""Split the corpus into a bundled core and downloadable packs.

The app is 101 MB on Android and 119 MB on iOS, and 54 MB of that is the
corpus. Almost all of it is patristic: 56.3 of 58.8 million characters are
early-church, so a reader who only wants the confessions of their own tradition
currently downloads the complete works of Chrysostom to get them.

Two layers. **Fragments** are the physical unit: a disjoint partition of one
corpus build, one file each, no source in more than one. **Collections** are
what the reader chooses — named, overlapping groupings that reference fragments
and own no text of their own.

That separation is what makes overlapping packs work at all. Augustine belongs
to "Augustine of Hippo", "Church Fathers", "Nicene & Post-Nicene Writers" and
"Catholic"; if those were each a file, his works would be published four times
and a reader who installed two of them would download him twice. As fragment
references they cost nothing, and installing a second overlapping collection
fetches only what is genuinely new.

**Fragments are a partition of one corpus build, not separately-built databases.**
That is the whole reason this is safe. Every row keeps the id it already has,
so ids are disjoint across packs by construction and nothing has to be
renumbered on install. The alternative — building each pack independently and
offsetting ids into reserved ranges — is how you get the failure this project
has already had once: chunk ids are derived from unit ids, embeddings are keyed
on chunk ids, and a renumbering that goes wrong does not raise an error, it
just silently points vectors at unrelated text.

The corollary used to be stated as a rule — *packs and the core must always be
built together, and `corpusVersion` bumped when they are* — and the app refused
any catalogue whose version differed from its own. That was stricter than the
thing it protected, and the cost was concrete: a corpus correction could not
reach a single reader until the app itself was released again, however careful
the rebuild had been.

What actually has to hold is narrower. **No id a fragment carries may already
mean something else on the reader's device.** A rebuild that only appends
satisfies that against every app built since the last renumbering, because
every id already in the field still holds exactly what it held. So the id space
is numbered separately from the corpus, and `check_id_space` decides per build
whether this one appended or reassigned — comparing against a ledger of what
was last published, rather than trusting anyone to remember. Only a reassigning
build advances the number and forces readers to update.

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
CATALOGUE_PATH = ROOT / "assets" / "pack_catalogue.json"
LEDGER_PATH = ROOT / "tools" / "data" / "id_ledger.json"
DIST = ROOT / "dist" / "packs"

# Which model produced every vector in these packs, and therefore which model a
# query must be encoded with to be comparable to them.
#
# Vectors from two different embedding models are not interchangeable — cosine
# similarity between them is noise, not a weak signal — so an app holding one
# model's vectors must refuse a pack built with another's. Nothing recorded this
# until now, which made replacing the embedding model unsafe in a way that would
# not have surfaced as an error: retrieval would simply have started returning
# irrelevant passages, with every count and checksum still correct.
#
# Recording it does not make the switch cheap. Changing this value invalidates
# all 445,445 stored vectors and requires a full re-embed. It makes the switch
# *safe*, which is the part that has to exist first.
EMBEDDING_MODEL = "all-MiniLM-L6-v2-int8-384"

# Must match DatabaseService.corpusVersion. This governs the *bundled* database:
# the app throws away its installed copy and unpacks the new one when this
# changes. It ships inside the binary, so it can only ever change with a release.
CORPUS_VERSION = 16

# What packs are actually gated on. See `read_ledger` below.
#
# This used to be CORPUS_VERSION, which meant every corpus change — however
# small, however careful — required an app release before any of it could reach
# a reader, because the app refused a manifest whose version differed from its
# own. That is stricter than the thing being protected. Ids only have to be
# *disjoint*; they do not have to come from the same build. A rebuild that only
# appends leaves every existing id meaning exactly what it meant before, and its
# packs merge safely into an app built against the previous corpus.
#
# So the id space gets its own number, bumped only when a rebuild reassigns an
# id that is already in the field. `check_id_space` decides that from the
# ledger rather than from anyone remembering to.
ID_SPACE_START = 1

# Reference tables are small, shared, and copied whole into every pack, so that
# installing a pack cannot leave a source pointing at a tradition the app has
# never heard of. They are inserted with OR IGNORE, so overlap is free.
# `branches` leads `traditions` because a tradition row carries a branch_id.
# SQLite does not enforce that by default, so the order is free rather than
# necessary — but a pack that carried families and not the branches they name
# would leave the shelf unable to group what it had just installed.
REFERENCE_TABLES = ["branches", "traditions", "source_types", "tags",
                    "authors", "works"]

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
        config = json.load(handle)
    fragments = config["fragments"]
    collections = config["collections"]

    known = {f["id"] for f in fragments}
    for collection in collections:
        unknown = set(collection["fragments"]) - known
        if unknown:
            sys.exit(f"collection {collection['id']!r} references unknown "
                     f"fragments {sorted(unknown)}")
    return fragments, collections


def assign_sources(conn, packs):
    """Map every source id to exactly one fragment, defaulting to core.

    First match wins, in declaration order, which is what lets a broad fragment
    sit after narrow ones: `f-fathers-rest` claims all of early-church, but
    Augustine and Chrysostom are pulled out ahead of it.

    Exactly one is the whole point. Overlap belongs to collections, which are
    lists of fragment ids; if it leaked down to this layer the same text would
    be published in several files.
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


def pack_catalogue(conn, source_ids):
    """What a pack contains, described well enough to reason about it absent.

    This is the whole point: without it the app cannot tell a reader that the
    question they just asked is answered mainly by material they have not
    installed. It can only search text it has, so a library missing the fathers
    answers a question about the Eucharist confidently from confessions alone
    and says nothing about the omission.

    Authors and titles support naming a person the corpus cannot currently see;
    tag counts support the vaguer case where nobody is named but the subject is
    one a pack covers heavily.

    Traditions are carried for a case neither of those can reach. Tag counts
    measure volume, and volume says a question about believer's baptism is best
    served by the fathers, who have 1,063 passages tagged `baptism` against the
    Baptist confession's 8. That is true and useless: the reason to install the
    Baptist pack is not that it is large, it is that without it the tradition
    has no voice at all. Absence is a different question from scarcity and
    needs its own evidence.
    """
    marks = ",".join("?" * len(source_ids))

    authors = [
        row[0]
        for row in conn.execute(
            f"SELECT DISTINCT author FROM sources "
            f"WHERE id IN ({marks}) AND author IS NOT NULL",
            source_ids,
        )
    ]
    titles = [
        row[0]
        for row in conn.execute(
            f"SELECT title FROM sources WHERE id IN ({marks})", source_ids
        )
    ]
    tags = {
        slug: count
        for slug, count in conn.execute(
            f"""SELECT t.slug, COUNT(*) FROM content_tags ct
                JOIN tags t ON ct.tag_id = t.id
                JOIN content_units cu ON ct.content_unit_id = cu.id
                WHERE cu.source_id IN ({marks})
                GROUP BY t.slug""",
            source_ids,
        )
    }
    traditions = [
        row[0]
        for row in conn.execute(
            f"""SELECT DISTINCT t.name FROM sources s
                JOIN traditions t ON s.tradition_id = t.id
                WHERE s.id IN ({marks})""",
            source_ids,
        )
    ]
    return {
        "authors": sorted(authors),
        "titles": sorted(titles),
        "tags": tags,
        "traditions": sorted(traditions),
    }


def merge_catalogues(name, parts):
    """Fold several fragments' catalogues into one collection's.

    The coverage notice reasons about collections, because those are what a
    reader can act on — being told that fragment `f-augustine` is missing is
    not a useful thing to read.
    """
    authors, titles, tags, traditions = [], [], {}, []
    for part in parts:
        authors.extend(part["authors"])
        titles.extend(part["titles"])
        traditions.extend(part["traditions"])
        for slug, count in part["tags"].items():
            tags[slug] = tags.get(slug, 0) + count
    return {
        "name": name,
        "authors": sorted(set(authors)),
        "titles": sorted(set(titles)),
        "tags": tags,
        "traditions": sorted(set(traditions)),
    }


def gzip_file(path):
    """Compress reproducibly.

    `mtime=0` matters more than it looks. gzip stamps the current time into its
    header, so rebuilding unchanged content produces different bytes and a
    different checksum — and checksums are what the app trusts to decide a
    download is intact. Without this, "did the corpus actually change?" cannot
    be answered by comparing manifests, and every rebuild forces a re-upload of
    35 MB of identical data.
    """
    out = path.with_suffix(path.suffix + ".gz")
    with open(path, "rb") as raw, open(out, "wb") as handle:
        with gzip.GzipFile(fileobj=handle, mode="wb", compresslevel=9, mtime=0) as gz:
            shutil.copyfileobj(raw, gz)
    return out


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


# --------------------------------------------------------------------------
# id space
#
# The property a downloadable fragment needs is not "same build as the app". It
# is: **no id it carries already means something else on the reader's device.**
# Those are different, and the second one survives a rebuild that the first one
# does not.
#
# The ledger records, per source, the id range its units occupy and a hash of
# their text. That is enough to decide the question, because units are inserted
# in one contiguous run per source, so "same range and same text" means every
# individual id in it still holds what it held.


def current_ledger(conn):
    """Per-source id footprint of the corpus as it stands."""
    sources = {}
    rows = conn.execute(
        """SELECT s.source_url, MIN(u.id), MAX(u.id), COUNT(u.id),
                  GROUP_CONCAT(u.content, char(30))
           FROM sources s JOIN content_units u ON u.source_id = s.id
           WHERE s.source_url IS NOT NULL AND s.source_url <> ''
           GROUP BY s.id"""
    )
    for url, low, high, count, text in rows:
        sources[url] = {
            "min": low,
            "max": high,
            "count": count,
            "hash": hashlib.sha256((text or "").encode()).hexdigest()[:16],
        }
    top = conn.execute("SELECT MAX(id) FROM content_units").fetchone()[0] or 0
    return {"maxUnitId": top, "sources": sources}


def read_ledger():
    if not LEDGER_PATH.exists():
        return None
    return json.loads(LEDGER_PATH.read_text(encoding="utf-8"))


def check_id_space(conn):
    """Decide this build's id-space number, and say why it is what it is.

    A source is *settled* if it sits entirely at or below the previous build's
    high-water mark — meaning some reader out there may already hold those ids.
    Anything above the mark is new ground and cannot collide with anything.

    A build is compatible when every settled id still holds the text it held.
    Three things break that, and all three are reported by name rather than
    collapsed into a bump:

      moved     a source kept its text and changed its ids
      rewritten a source kept its ids and changed its text
      occupied  new content landed on ids the previous build had already used

    The first two are what a careless rebuild does. The third is what reusing
    freed ids does, and it is the genuinely dangerous one: the reader's copy
    would keep the old text under an id the new pack expects to insert, and the
    merge fails on a primary-key collision halfway through.
    """
    now = current_ledger(conn)
    before = read_ledger()

    if before is None:
        print(f"id space: {ID_SPACE_START} (no ledger yet — first recorded build)")
        return ID_SPACE_START, now

    mark = before["maxUnitId"]
    was = before["sources"]
    moved, rewritten, occupied = [], [], []

    for url, entry in now["sources"].items():
        old = was.get(url)
        settled = entry["min"] <= mark
        if old is None:
            if settled:
                occupied.append(url)
            continue
        same_ids = (old["min"], old["max"], old["count"]) == (
            entry["min"], entry["max"], entry["count"])
        same_text = old["hash"] == entry["hash"]
        if same_ids and same_text:
            continue
        if same_text and not same_ids:
            # Only a problem if the new home is on settled ground; a source
            # rebuilt into fresh ids above the mark retires its old ones and
            # collides with nothing.
            if settled:
                moved.append(url)
        elif same_ids and not same_text:
            rewritten.append(url)
        elif settled:
            occupied.append(url)

    faults = [("moved", moved), ("rewritten", rewritten), ("occupied", occupied)]
    if not any(items for _, items in faults):
        space = before.get("idSpace", ID_SPACE_START)
        print(f"id space: {space} (unchanged — this build only appends, so its "
              f"packs install into any app already on space {space})")
        return space, now

    space = before.get("idSpace", ID_SPACE_START) + 1
    print(f"id space: {space} (BUMPED — ids in the field have been reassigned)")
    for label, items in faults:
        for url in items[:6]:
            print(f"    {label:10} {url}")
        if len(items) > 6:
            print(f"    {label:10} … and {len(items) - 6} more")
    print("  Readers must update the app before they can install these packs.")
    return space, now


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="build the packs")
    args = parser.parse_args()

    if not DB_PATH.exists():
        sys.exit(f"No corpus at {DB_PATH}")

    fragments, collections = load_config()
    conn = sqlite3.connect(DB_PATH)
    assignment = assign_sources(conn, fragments)

    by_fragment = {}
    for source_id, fragment_id in assignment.items():
        by_fragment.setdefault(fragment_id, []).append(source_id)

    declared = {f["id"] for f in fragments}
    unknown = set(by_fragment) - declared - {"core"}
    if unknown:
        sys.exit(f"Sources assigned to undeclared fragments: {sorted(unknown)}")

    print(f"{'fragment':24} {'sources':>8} {'units':>8} {'chunks':>8} {'chars':>10}")
    for fragment_id in ["core"] + [f["id"] for f in fragments]:
        stats = pack_stats(conn, by_fragment.get(fragment_id, []))
        print(f"{fragment_id:24} {stats['sources']:8} {stats['units']:8} "
              f"{stats['chunks']:8} {stats['chars'] / 1e6:9.1f}M")

    print(f"\n{len(collections)} collections over "
          f"{len(by_fragment) - 1} published fragments")
    for collection in collections:
        missing = [f for f in collection["fragments"]
                   if not by_fragment.get(f)]
        note = f"  (empty fragments: {missing})" if missing else ""
        print(f"  {collection['id']:26} {collection['kind']:10} "
              f"{len(collection['fragments'])} fragments{note}")

    if not args.write:
        # Reported on a dry run too, because whether this build's packs can
        # reach readers without an app release is the thing worth knowing
        # *before* spending ten minutes compressing 74 MB.
        print()
        check_id_space(conn)
        print("\nDry run. Pass --write to build.")
        return

    DIST.mkdir(parents=True, exist_ok=True)
    built = {}

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)

        print("\nBuilding core...")
        build_core(DB_PATH, by_fragment.get("core", []), tmp / "core.db")
        shutil.copyfile(gzip_file(tmp / "core.db"), CORE_GZ)
        print(f"  {CORE_GZ.name}  {CORE_GZ.stat().st_size / 1e6:.1f} MB")

        for fragment in fragments:
            source_ids = by_fragment.get(fragment["id"], [])
            if not source_ids:
                print(f"  skipping empty fragment {fragment['id']}")
                continue

            db_path = tmp / f"{fragment['id']}.db"
            build_pack(conn, fragment["id"], source_ids, db_path)
            final = DIST / f"{fragment['id']}.db.gz"
            shutil.copyfile(gzip_file(db_path), final)

            stats = pack_stats(conn, source_ids)
            built[fragment["id"]] = {
                "id": fragment["id"],
                "file": final.name,
                "bytes": final.stat().st_size,
                "sha256": sha256(final),
                "sources": stats["sources"],
                "units": stats["units"],
                "chunks": stats["chunks"],
            }
            print(f"  {final.name:28} {final.stat().st_size / 1e6:6.1f} MB")

    # A collection lists fragment ids only. Its size is the sum of the
    # fragments a reader does not already have, so it is computed in the app
    # rather than fixed here — the same collection costs different amounts to
    # different people.
    id_space, ledger = check_id_space(conn)
    manifest = {
        "corpusVersion": CORPUS_VERSION,
        "idSpace": id_space,
        "embeddingModel": EMBEDDING_MODEL,
        "fragments": [built[f["id"]] for f in fragments if f["id"] in built],
        "collections": [
            {
                "id": c["id"],
                "kind": c["kind"],
                "name": c["name"],
                "description": c["description"],
                "fragments": [f for f in c["fragments"] if f in built],
            }
            for c in collections
            if any(f in built for f in c["fragments"])
        ],
    }

    with open(DIST / "manifest.json", "w") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")

    # Written only on a real build, and only after the manifest it describes.
    # The ledger is the record of what is *published*; writing it on a dry run
    # would move the high-water mark for a build nobody can install, and the
    # next real build would then measure itself against fiction.
    ledger["idSpace"] = id_space
    LEDGER_PATH.write_text(json.dumps(ledger, indent=1) + "\n", encoding="utf-8")

    total = sum(f["bytes"] for f in manifest["fragments"])
    naive = sum(
        sum(built[f]["bytes"] for f in c["fragments"] if f in built)
        for c in collections)
    print(f"\npublished {len(manifest['fragments'])} fragments, "
          f"{total / 1e6:.1f} MB total")
    print(f"the same collections as standalone files would be "
          f"{naive / 1e6:.1f} MB")

    # Bundled, not published: the app needs to know what it is missing before
    # it has any network connection, and offline is the normal case here.
    # Core's tag counts let the app judge what a *missing* collection would add
    # relative to everything that exists, rather than relative to itself: the
    # Eucharist is 0.2% of Augustine, which says nothing, while the fragments
    # together hold most of the corpus's Eucharist material, which is exactly
    # what a reader needs told.
    # Tag counts are recorded per *fragment*, not per collection, because
    # collections overlap. Summing them per collection counts Augustine once
    # for "Augustine of Hippo", again for "Church Fathers", again for "Nicene &
    # Post-Nicene Writers" and again for "Catholic" — which makes the library
    # look several times larger than it is and every subject look almost
    # entirely missing.
    catalogue = {
        "corpusVersion": CORPUS_VERSION,
        "core": pack_catalogue(conn, by_fragment.get("core", []))["tags"],
        # Authors and titles per fragment, not only tags. A suggestion needs
        # to know whether *this author's text* is present, which is a property
        # of fragments; asking whether a collection is complete answers a
        # different question and answers it wrongly.
        "fragments": {
            f["id"]: pack_catalogue(conn, by_fragment[f["id"]])
            for f in fragments
            if by_fragment.get(f["id"])
        },
        "packs": {
            c["id"]: {
                **merge_catalogues(
                    c["name"],
                    [pack_catalogue(conn, by_fragment[f])
                     for f in c["fragments"] if by_fragment.get(f)],
                ),
                "fragments": [f for f in c["fragments"] if by_fragment.get(f)],
            }
            for c in collections
            if any(by_fragment.get(f) for f in c["fragments"])
        },
    }
    with open(CATALOGUE_PATH, "w") as handle:
        json.dump(catalogue, handle, indent=2)
        handle.write("\n")
    print(f"Wrote {CATALOGUE_PATH.name}  "
          f"{CATALOGUE_PATH.stat().st_size / 1024:.0f} KB")

    print(f"\nWrote {DIST / 'manifest.json'}")
    print(f"\nDatabaseService.corpusVersion must be {CORPUS_VERSION} "
          f"and idSpace must be {id_space}.")
    if id_space == (read_ledger() or {}).get("idSpace", ID_SPACE_START):
        print("These packs install into any app already on id space "
              f"{id_space} — publish them whenever you like.")
    else:
        print("This build reassigned ids, so these packs need the app release "
              "to go out first. Publish them together.")


if __name__ == "__main__":
    main()
