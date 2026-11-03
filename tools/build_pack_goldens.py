#!/usr/bin/env python3
"""Rebuild the content-pack golden fixtures in shared/golden/packs/.

The native Apple app reimplements pack download, verification and merge, and
has to behave exactly as the Flutter app does. These fixtures pin that down: a
tiny corpus, packs cut from it by the real build code, and the database the
Flutter app ends up holding after each install, uninstall and refusal.
`test/pack_golden_test.dart` replays every scenario through the real
PackService and compares; the Swift side replays the same files.

Nothing here re-implements how packs are *built*. The corpus is split by the
functions in tools/build_packs.py, imported rather than copied, so a change to
the way real packs are cut shows up here on the next regeneration:

    assign_sources, build_core, build_pack, gzip_file, sha256, pack_stats,
    current_ledger, check_id_space

What this file does re-implement is the app's *merge* (PackService.install,
_merge, uninstall, _retire), in a few lines of SQL, to compute `expected/`.
That is deliberate: the expected states come from an implementation that is not
the one under test, and the Dart test then proves the two agree. The table lists
the merge copies are read out of pack_service.dart and checked against the ones
used here, so the two cannot drift silently.

Inputs (hand-maintained):  shared/golden/packs/corpus/{schema,build*}.sql
Outputs (regenerated):     everything else in shared/golden/packs/ except
                           README.md

    python3 tools/build_pack_goldens.py

Running it twice must leave `git status` clean; see the README for what can
legitimately change the binary files (a different SQLite or zlib).
"""

import contextlib
import gzip
import hashlib
import io
import json
import re
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path

# build_packs is imported from tools/, and writing its bytecode there would
# leave a __pycache__ behind in a directory this script has no business in.
sys.dont_write_bytecode = True
TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))
import build_packs as bp  # noqa: E402

ROOT = TOOLS.parent
GOLDEN = ROOT / "shared" / "golden" / "packs"
CORPUS = GOLDEN / "corpus"
DATABASE_SERVICE = ROOT / "lib" / "src" / "services" / "database_service.dart"
PACK_SERVICE = ROOT / "lib" / "src" / "services" / "packs" / "pack_service.dart"
REAL_CORPUS = ROOT / "assets" / "theology.db"

# The fixture's equivalent of tools/data/packs.json. Same shape, same
# first-match-wins assignment by author name.
FRAGMENTS = [
    {"id": "f-alpha", "authors": ["Golden Author Alpha"]},
    {"id": "f-beta", "authors": ["Golden Author Beta"]},
]
COLLECTIONS = [
    {"id": "golden-alpha", "kind": "author", "name": "Golden Author Alpha",
     "description": "Fixture collection holding one fragment.",
     "fragments": ["f-alpha"]},
    {"id": "golden-beta", "kind": "author", "name": "Golden Author Beta",
     "description": "Fixture collection holding the other fragment.",
     "fragments": ["f-beta"]},
    {"id": "golden-all", "kind": "era", "name": "Golden Library",
     "description": "Fixture collection overlapping golden-alpha.",
     "fragments": ["f-alpha", "f-beta"]},
]

OTHER_MODEL = "golden-other-model-768"

# PackException messages, verbatim from pack_service.dart. The Dart test
# compares them exactly, so an edit there fails the test until this is updated
# and the fixtures regenerated.
MSG_ID_SPACE = ("This content was built for a different version of the app. "
                "Update the app and try again.")
MSG_MODEL = ("This content was built for a newer version of the app. Update "
             "the app and try again.")
MSG_CHECKSUM = ("A download did not match its checksum and was discarded. "
                "Check your connection and try again.")

# PackService.createTables, verbatim.
BOOKKEEPING_DDL = """
CREATE TABLE IF NOT EXISTS installed_collections (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  corpus_version INTEGER NOT NULL,
  installed_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS collection_fragments (
  collection_id TEXT NOT NULL,
  fragment_id TEXT NOT NULL,
  PRIMARY KEY (collection_id, fragment_id)
);
CREATE TABLE IF NOT EXISTS installed_fragments (
  id TEXT PRIMARY KEY,
  bytes INTEGER NOT NULL,
  units INTEGER NOT NULL,
  installed_at TEXT NOT NULL,
  sha256 TEXT
);
CREATE TABLE IF NOT EXISTS fragment_sources (
  fragment_id TEXT NOT NULL,
  source_id INTEGER NOT NULL,
  PRIMARY KEY (fragment_id, source_id)
);
"""

# What PackService._merge copies, in its order. Note `branches` is absent even
# though build_packs.REFERENCE_TABLES puts it in every pack: the app never reads
# it. Checked against pack_service.dart in `check_merge_lists`.
MERGE_REFERENCE = ["traditions", "source_types", "tags", "authors", "works"]
MERGE_CONTENT = ["sources", "content_units", "content_tags", "content_chunks",
                 "chunk_embeddings"]

# Every table an expected state records, in this order. `installed_at` columns
# are left out: they hold DateTime.now().
DUMP_TABLES = ["branches"] + MERGE_REFERENCE + MERGE_CONTENT + [
    "installed_collections", "collection_fragments", "installed_fragments",
    "fragment_sources"]
UNRECORDED_COLUMNS = {"installed_at"}


class PackError(Exception):
    """The oracle's PackException."""


# --------------------------------------------------------------------------
# guards: the fixture must describe the app as it is


def app_constants():
    text = DATABASE_SERVICE.read_text(encoding="utf-8")
    space = re.search(r"static const int idSpace = (\d+);", text)
    model = re.search(r"static const String embeddingModel = '([^']+)';", text)
    if not space or not model:
        sys.exit(f"Could not read idSpace / embeddingModel from {DATABASE_SERVICE}")
    if model.group(1) != bp.EMBEDDING_MODEL:
        sys.exit(f"database_service.dart encodes with {model.group(1)!r} but "
                 f"build_packs.py stamps {bp.EMBEDDING_MODEL!r}.")
    return int(space.group(1)), model.group(1)


def check_merge_lists():
    """The oracle must copy the same tables, in the same order, as the app."""
    text = PACK_SERVICE.read_text(encoding="utf-8")
    body = text[text.index("Future<void> _merge("):]
    lists = re.findall(r"for \(final table in const \[(.*?)\]\)", body, re.S)
    found = [re.findall(r"'(\w+)'", block) for block in lists[:2]]
    if found != [MERGE_REFERENCE, MERGE_CONTENT]:
        sys.exit(f"pack_service.dart merges {found}; this generator assumes "
                 f"{[MERGE_REFERENCE, MERGE_CONTENT]}. Update the oracle.")


def check_schema_against_corpus():
    """corpus/schema.sql must match the real corpus column for column."""
    if not REAL_CORPUS.exists():
        print(f"note: {REAL_CORPUS.relative_to(ROOT)} absent; schema.sql not "
              "re-checked against it")
        return
    real = sqlite3.connect(f"file:{REAL_CORPUS}?mode=ro", uri=True)
    ours = sqlite3.connect(":memory:")
    ours.executescript((CORPUS / "schema.sql").read_text(encoding="utf-8"))
    for table in bp.REFERENCE_TABLES + bp.CONTENT_TABLES:
        want = real.execute(f"PRAGMA table_info({table})").fetchall()
        have = ours.execute(f"PRAGMA table_info({table})").fetchall()
        if want != have:
            sys.exit(f"corpus/schema.sql: {table} differs from the real corpus\n"
                     f"  real: {want}\n  ours: {have}")
    real.close()
    ours.close()


# --------------------------------------------------------------------------
# building, through build_packs


def build_upstream(path, *scripts):
    """An upstream corpus: schema.sql followed by the named build scripts."""
    if path.exists():
        path.unlink()
    conn = sqlite3.connect(path)
    for name in ("schema.sql",) + scripts:
        conn.executescript((CORPUS / name).read_text(encoding="utf-8"))
    conn.commit()
    conn.close()
    return path


def by_fragment(conn):
    assignment = bp.assign_sources(conn, FRAGMENTS)
    grouped = {}
    for source_id, fragment_id in sorted(assignment.items()):
        grouped.setdefault(fragment_id, []).append(source_id)
    return grouped


def ledger_of(db_path, id_space, with_tables=True):
    """What build_packs would have written to id_ledger.json after publishing
    this build — optionally as an older ledger that predates table shapes."""
    conn = sqlite3.connect(db_path)
    ledger = bp.current_ledger(conn)
    conn.close()
    ledger["idSpace"] = id_space
    if not with_tables:
        del ledger["tables"]
    return ledger


def check_id_space(db_path, ledger, tmp):
    """build_packs.check_id_space against [ledger]; returns (space, report)."""
    ledger_path = tmp / "id_ledger.json"
    ledger_path.write_text(json.dumps(ledger), encoding="utf-8")
    bp.LEDGER_PATH = ledger_path
    conn = sqlite3.connect(db_path)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        space, _ = bp.check_id_space(conn)
    conn.close()
    return space, out.getvalue().rstrip("\n").splitlines()


def publish(db_path, out_dir, tmp, id_space, embedding_model=None):
    """Cut and publish fragments exactly as build_packs.main does.

    The manifest is assembled here because main() is not callable piecemeal,
    but it has the same keys, order and formatting.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(dir=tmp))
    bp.DB_PATH = db_path  # build_pack ATTACHes the corpus by this path
    conn = sqlite3.connect(db_path)
    grouped = by_fragment(conn)
    built = {}
    for fragment in FRAGMENTS:
        source_ids = grouped.get(fragment["id"], [])
        if not source_ids:
            continue
        pack_db = work / f"{fragment['id']}.db"
        bp.build_pack(conn, fragment["id"], source_ids, pack_db)
        final = out_dir / f"{fragment['id']}.db.gz"
        shutil.copyfile(bp.gzip_file(pack_db), final)
        stats = bp.pack_stats(conn, source_ids)
        built[fragment["id"]] = {
            "id": fragment["id"],
            "file": final.name,
            "bytes": final.stat().st_size,
            "sha256": bp.sha256(final),
            "sources": stats["sources"],
            "units": stats["units"],
            "chunks": stats["chunks"],
        }
    conn.close()
    manifest = {
        "corpusVersion": bp.CORPUS_VERSION,
        "idSpace": id_space,
        "embeddingModel": embedding_model or bp.EMBEDDING_MODEL,
        "fragments": [built[f["id"]] for f in FRAGMENTS if f["id"] in built],
        "collections": [
            {
                "id": c["id"],
                "kind": c["kind"],
                "name": c["name"],
                "description": c["description"],
                "fragments": [f for f in c["fragments"] if f in built],
            }
            for c in COLLECTIONS
            if any(f in built for f in c["fragments"])
        ],
    }
    write_manifest(out_dir / "manifest.json", manifest)
    return manifest


def write_manifest(path, manifest):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")


def sql_literal(value):
    if value is None:
        return "NULL"
    if isinstance(value, bytes):
        return "X'" + value.hex().upper() + "'"
    if isinstance(value, (int, float)):
        return repr(value)
    return "'" + value.replace("'", "''") + "'"


def write_base_sql(core_db, out_path):
    """The bundled core as one replayable SQL script.

    Schema in sqlite_master order, then every row of every table (ordered by
    all columns, left to right), then an FTS rebuild. The FTS shadow tables are
    not dumped: the rebuild regenerates them, which is also what keeps the
    script independent of how a given SQLite lays out its index.
    """
    conn = sqlite3.connect(core_db)
    objects = conn.execute(
        "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL "
        "ORDER BY rowid").fetchall()
    lines = [
        "-- GENERATED by tools/build_pack_goldens.py — do not edit by hand.",
        "--",
        "-- The bundled core the app starts from: build_packs.build_core applied",
        "-- to corpus/build1.sql. Load it into an empty database, then run",
        "-- PackService.createTables (or its DDL) to get expected/0-base.json.",
        "-- Statements are separated by a semicolon at the end of a line.",
        "",
    ]
    tables = []
    for kind, name, sql in objects:
        if name.startswith("content_fts_"):
            continue  # FTS shadow tables: rebuilt below
        lines.append(sql + ";")
        if kind == "table" and name != "content_fts":
            tables.append(name)
    lines.append("")
    for table in tables:
        width = len(conn.execute(f"PRAGMA table_info({table})").fetchall())
        order = ", ".join(str(i) for i in range(1, width + 1))
        for row in conn.execute(f"SELECT * FROM {table} ORDER BY {order}"):
            values = ", ".join(sql_literal(v) for v in row)
            lines.append(f"INSERT INTO {table} VALUES ({values});")
    lines.append("")
    lines.append("INSERT INTO content_fts(content_fts) VALUES('rebuild');")
    conn.close()
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------
# the oracle: PackService's merge, uninstall and replace, in SQL


class Oracle:
    def __init__(self, base_sql, tmp, app_model):
        self.db = sqlite3.connect(":memory:", isolation_level=None)
        self.db.executescript(base_sql)
        self.db.executescript(BOOKKEEPING_DDL)
        self.tmp = tmp
        self.app_model = app_model
        self.downloads = []

    def install(self, manifest, collection_id, app_space, serve_dir):
        if manifest.get("idSpace", 1) != app_space:
            raise PackError(MSG_ID_SPACE)
        model = manifest.get("embeddingModel")
        if model is not None and model != self.app_model:
            raise PackError(MSG_MODEL)

        collection = next(c for c in manifest["collections"]
                          if c["id"] == collection_id)
        fragments = {f["id"]: f for f in manifest["fragments"]}
        installed = dict(self.db.execute(
            "SELECT id, sha256 FROM installed_fragments"))
        wanted, stale = [], set()
        for fragment_id in collection["fragments"]:
            fragment = fragments.get(fragment_id)
            if fragment is None:
                continue
            if fragment_id not in installed:
                wanted.append(fragment)
            elif installed[fragment_id] != fragment["sha256"]:
                stale.add(fragment_id)
                wanted.append(fragment)

        for fragment in wanted:
            self._install_fragment(fragment, fragment["id"] in stale, serve_dir)

        self.db.execute(
            "INSERT OR REPLACE INTO installed_collections "
            "(id, name, corpus_version, installed_at) VALUES (?, ?, ?, ?)",
            (collection["id"], collection["name"], app_space, "now"))
        for fragment_id in collection["fragments"]:
            self.db.execute(
                "INSERT OR IGNORE INTO collection_fragments "
                "(collection_id, fragment_id) VALUES (?, ?)",
                (collection["id"], fragment_id))

    def _install_fragment(self, fragment, replacing, serve_dir):
        self.downloads.append(fragment["file"])
        archive = serve_dir / fragment["file"]
        if not archive.exists():
            raise PackError("Download failed (HTTP 404).")
        data = archive.read_bytes()
        if hashlib.sha256(data).hexdigest() != fragment["sha256"]:
            raise PackError(MSG_CHECKSUM)
        expanded = self.tmp / f"oracle-{fragment['id']}.db"
        expanded.write_bytes(gzip.decompress(data))
        try:
            if replacing:
                self._transaction(lambda: self._delete_fragment(fragment["id"]),
                                  rebuild=True)
            self._merge(fragment, expanded)
        finally:
            expanded.unlink()

    def _transaction(self, body, rebuild=False):
        self.db.execute("BEGIN")
        try:
            body()
            if rebuild:
                self.db.execute(
                    "INSERT INTO content_fts(content_fts) VALUES('rebuild')")
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def _merge(self, fragment, expanded):
        def body():
            for table in MERGE_REFERENCE:
                self.db.execute(
                    f"INSERT OR IGNORE INTO {table} SELECT * FROM pack.{table}")
            for table in MERGE_CONTENT:
                self.db.execute(f"INSERT INTO {table} SELECT * FROM pack.{table}")
            self.db.execute(
                "INSERT INTO content_fts(rowid, content, title) "
                "SELECT id, content, title FROM pack.content_units")
            self.db.execute(
                "INSERT INTO fragment_sources(fragment_id, source_id) "
                "SELECT ?, id FROM pack.sources", (fragment["id"],))
            self.db.execute(
                "INSERT INTO installed_fragments "
                "(id, bytes, units, installed_at, sha256) VALUES (?, ?, ?, ?, ?)",
                (fragment["id"], fragment["bytes"], fragment["units"], "now",
                 fragment["sha256"]))

        self.db.execute("ATTACH DATABASE ? AS pack", (str(expanded),))
        try:
            self._transaction(body)
        finally:
            self.db.execute("DETACH DATABASE pack")

    def _delete_fragment(self, fragment_id):
        scope = "(SELECT source_id FROM fragment_sources WHERE fragment_id = ?)"
        for sql in (
            f"""DELETE FROM chunk_embeddings WHERE chunk_id IN (
                  SELECT c.id FROM content_chunks c
                  JOIN content_units u ON c.content_unit_id = u.id
                  WHERE u.source_id IN {scope})""",
            f"""DELETE FROM content_chunks WHERE content_unit_id IN (
                  SELECT id FROM content_units WHERE source_id IN {scope})""",
            f"""DELETE FROM content_tags WHERE content_unit_id IN (
                  SELECT id FROM content_units WHERE source_id IN {scope})""",
            f"DELETE FROM content_units WHERE source_id IN {scope}",
            f"DELETE FROM sources WHERE id IN {scope}",
            "DELETE FROM fragment_sources WHERE fragment_id = ?",
            "DELETE FROM installed_fragments WHERE id = ?",
        ):
            self.db.execute(sql, (fragment_id,))

    def uninstall(self, collection_id):
        own = {r[0] for r in self.db.execute(
            "SELECT fragment_id FROM collection_fragments WHERE collection_id = ?",
            (collection_id,))}
        still_needed = {r[0] for r in self.db.execute(
            """SELECT DISTINCT cf.fragment_id FROM collection_fragments cf
               JOIN installed_collections ic ON ic.id = cf.collection_id
               WHERE cf.collection_id != ?""", (collection_id,))}
        doomed = own - still_needed
        present = {r[0] for r in self.db.execute(
            "SELECT id FROM installed_fragments")}

        def body():
            for fragment_id in sorted(doomed):
                if fragment_id in present:
                    self._delete_fragment(fragment_id)
            self.db.execute(
                "DELETE FROM collection_fragments WHERE collection_id = ?",
                (collection_id,))
            self.db.execute("DELETE FROM installed_collections WHERE id = ?",
                            (collection_id,))

        # The Dart code rebuilds before deleting the bookkeeping rows; both are
        # inside one transaction and neither reads the other, so the order of
        # those two does not change the result.
        self._transaction(body, rebuild=bool(doomed))

    def mark_stale(self, fragment_id):
        self.db.execute("UPDATE installed_fragments SET sha256 = 'stale' "
                        "WHERE id = ?", (fragment_id,))

    def state(self):
        return dump_state(self.db)


def jsonable(value):
    if isinstance(value, bytes):
        return {"blob": value.hex()}
    return value


def dump_state(db):
    """Every recorded table, plus what the FTS index holds per row.

    The FTS part is read from the index itself (fts5vocab, `instance`), not
    from the external content table, so a row missing from the index or a
    stale entry left behind shows up as a difference. Each row's tokens are
    joined in position order per column.
    """
    tables = {}
    for table in DUMP_TABLES:
        columns = [r[1] for r in db.execute(f"PRAGMA table_info({table})")
                   if r[1] not in UNRECORDED_COLUMNS]
        order = ", ".join(str(i) for i in range(1, len(columns) + 1))
        rows = db.execute(
            f"SELECT {', '.join(columns)} FROM {table} ORDER BY {order}")
        tables[table] = {"columns": columns,
                         "rows": [[jsonable(v) for v in row] for row in rows]}

    db.execute("CREATE VIRTUAL TABLE temp.golden_vocab "
               "USING fts5vocab(main, content_fts, instance)")
    tokens = {}
    for doc, column, term in db.execute(
            "SELECT doc, col, term FROM temp.golden_vocab "
            "ORDER BY doc, col, offset"):
        tokens.setdefault(doc, {}).setdefault(column, []).append(term)
    db.execute("DROP TABLE temp.golden_vocab")
    # Raises if the index disagrees with content_units.
    db.execute("INSERT INTO content_fts(content_fts) VALUES('integrity-check')")
    fts = {str(doc): {col: " ".join(terms) for col, terms in cols.items()}
           for doc, cols in sorted(tokens.items())}
    return {"tables": tables, "fts": fts}


def render_state(state):
    """JSON with one table row per line, so diffs read row by row."""
    out = ["{", '  "tables": {']
    names = list(state["tables"])
    for i, name in enumerate(names):
        table = state["tables"][name]
        out.append(f"    {json.dumps(name)}: {{")
        out.append(f'      "columns": {json.dumps(table["columns"])},')
        if table["rows"]:
            out.append('      "rows": [')
            rows = table["rows"]
            for j, row in enumerate(rows):
                out.append("        " + json.dumps(row)
                           + ("," if j < len(rows) - 1 else ""))
            out.append("      ]")
        else:
            out.append('      "rows": []')
        out.append("    }" + ("," if i < len(names) - 1 else ""))
    out.append("  },")
    out.append('  "fts": {')
    docs = list(state["fts"].items())
    for i, (doc, cols) in enumerate(docs):
        out.append(f"    {json.dumps(doc)}: {json.dumps(cols)}"
                   + ("," if i < len(docs) - 1 else ""))
    out.append("  }")
    out.append("}")
    text = "\n".join(out) + "\n"
    assert json.loads(text) == state
    return text


# --------------------------------------------------------------------------
# scenarios


def scenarios(app_space):
    """Every flow the fixtures pin. Run here through the oracle (which must
    agree with each declared expectation) and in Dart through PackService."""
    base = "expected/0-base.json"
    return [
        {
            "name": "lifecycle",
            "dir": ".",
            "description": (
                "Install, overlap, reinstall, uninstall with reference "
                "counting, replace a republished fragment, uninstall the rest."),
            "steps": [
                {"op": "install", "collection": "golden-alpha",
                 "downloads": ["f-alpha.db.gz"],
                 "state": "expected/1-alpha.json"},
                {"op": "install", "collection": "golden-all",
                 "note": "f-alpha is already held, so only f-beta is fetched",
                 "downloads": ["f-beta.db.gz"],
                 "state": "expected/2-all.json"},
                {"op": "install", "collection": "golden-all",
                 "note": "everything already current: no download, no change",
                 "downloads": [],
                 "state": "expected/2-all.json"},
                {"op": "uninstall", "collection": "golden-all",
                 "note": "f-alpha is still claimed by golden-alpha and stays",
                 "state": "expected/1-alpha.json"},
                {"op": "markStale", "fragment": "f-alpha",
                 "note": ("UPDATE installed_fragments SET sha256 = 'stale': "
                          "what the device looks like once the catalogue has "
                          "republished the fragment")},
                {"op": "install", "collection": "golden-alpha",
                 "note": "checksum differs, so the fragment is torn down and "
                         "merged again",
                 "downloads": ["f-alpha.db.gz"],
                 "state": "expected/1-alpha.json"},
                {"op": "uninstall", "collection": "golden-alpha",
                 "note": "content returns to the core; reference rows the "
                         "packs added stay",
                 "state": "expected/3-uninstalled.json"},
            ],
        },
        {
            "name": "wrong-idspace",
            "dir": "negative/wrong-idspace",
            "description": (
                "A build that reused ids the core holds, so build_packs bumped "
                "the id space. The app refuses it before downloading. The "
                "second step bypasses the gate (passes the manifest's own id "
                "space) to pin what it protects against: a primary-key "
                "collision that rolls the whole fragment back."),
            "steps": [
                {"op": "install", "collection": "golden-beta",
                 "downloads": [],
                 "throws": {"type": "PackException", "message": MSG_ID_SPACE},
                 "state": base},
                {"op": "install", "collection": "golden-beta",
                 "appIdSpace": app_space + 1,
                 "downloads": ["f-beta.db.gz"],
                 "throws": {"type": "DatabaseException",
                            "messageContains":
                                "UNIQUE constraint failed: content_units.id"},
                 "state": base},
            ],
        },
        {
            "name": "wrong-embedding-model",
            "dir": "negative/wrong-embedding-model",
            "description": (
                "The published packs with a different embeddingModel. Refused "
                "before downloading."),
            "steps": [
                {"op": "install", "collection": "golden-all",
                 "downloads": [],
                 "throws": {"type": "PackException", "message": MSG_MODEL},
                 "state": base},
            ],
        },
        {
            "name": "checksum-mismatch",
            "dir": "negative/checksum-mismatch",
            "description": (
                "f-beta.db.gz is truncated; the manifest still describes the "
                "real file. f-alpha installs first and is KEPT: each fragment "
                "commits on its own, and the collection itself is never "
                "recorded."),
            "steps": [
                {"op": "install", "collection": "golden-all",
                 "downloads": ["f-alpha.db.gz", "f-beta.db.gz"],
                 "throws": {"type": "PackException", "message": MSG_CHECKSUM},
                 "state": "expected/4-alpha-without-collection.json"},
            ],
        },
        {
            "name": "reshaped",
            "dir": "negative/reshaped",
            "description": (
                "content_units has an extra column. The app performs no shape "
                "check of its own; the positional INSERT … SELECT * fails in "
                "SQLite and the fragment's transaction rolls back."),
            "steps": [
                {"op": "install", "collection": "golden-alpha",
                 "downloads": ["f-alpha.db.gz"],
                 "throws": {"type": "DatabaseException",
                            "messageContains": "table content_units has 10 "
                                               "columns but 11 values were "
                                               "supplied"},
                 "state": base},
            ],
        },
    ]


def run_scenario(scenario, base_sql, tmp, app_space, app_model, states):
    oracle = Oracle(base_sql, tmp, app_model)
    serve_dir = GOLDEN / scenario["dir"]
    manifest = json.loads((serve_dir / "manifest.json").read_text())
    for number, step in enumerate(scenario["steps"], 1):
        where = f"{scenario['name']} step {number}"
        oracle.downloads = []
        error = None
        try:
            if step["op"] == "install":
                oracle.install(manifest, step["collection"],
                               step.get("appIdSpace", app_space), serve_dir)
            elif step["op"] == "uninstall":
                oracle.uninstall(step["collection"])
            elif step["op"] == "markStale":
                oracle.mark_stale(step["fragment"])
            else:
                sys.exit(f"{where}: unknown op {step['op']}")
        except (PackError, sqlite3.DatabaseError) as caught:
            error = caught

        expected = step.get("throws")
        if expected is None and error is not None:
            sys.exit(f"{where}: unexpected {error!r}")
        if expected is not None:
            if error is None:
                sys.exit(f"{where}: expected {expected}, nothing was raised")
            kind = ("PackException" if isinstance(error, PackError)
                    else "DatabaseException")
            ok = kind == expected["type"] and (
                str(error) == expected["message"] if "message" in expected
                else expected["messageContains"] in str(error))
            if not ok:
                sys.exit(f"{where}: expected {expected}, got {kind}: {error}")
        if "downloads" in step and oracle.downloads != step["downloads"]:
            sys.exit(f"{where}: downloaded {oracle.downloads}, "
                     f"declared {step['downloads']}")
        if "state" in step:
            record_state(states, step["state"], oracle.state(), where)


def record_state(states, name, state, where):
    if name in states and states[name] != state:
        sys.exit(f"{where}: state differs from the earlier {name}")
    states[name] = state


# --------------------------------------------------------------------------


def clean_outputs():
    for directory in ("expected", "negative"):
        shutil.rmtree(GOLDEN / directory, ignore_errors=True)
    for path in list(GOLDEN.glob("*.db.gz")) + [
            GOLDEN / "manifest.json", GOLDEN / "scenarios.json",
            CORPUS / "base.sql"]:
        if path.exists():
            path.unlink()


def main():
    if sqlite3.sqlite_version_info < (3, 41, 0):
        sys.exit(f"SQLite {sqlite3.sqlite_version} lacks unhex(); the corpus "
                 "scripts need 3.41 or later.")
    app_space, app_model = app_constants()
    check_merge_lists()
    check_schema_against_corpus()
    clean_outputs()
    (GOLDEN / "expected").mkdir(parents=True)

    with tempfile.TemporaryDirectory() as tmp_name:
        tmp = Path(tmp_name)
        build1 = build_upstream(tmp / "build1.db", "build1.sql")
        build2 = build_upstream(tmp / "build2.db", "build1.sql", "build2.sql")
        build3 = build_upstream(tmp / "build3.db", "build1.sql", "build2.sql",
                                "build3-occupied.sql")
        build4 = build_upstream(tmp / "build4.db", "build1.sql", "build2.sql",
                                "build4-reshaped.sql")

        # The app's bundled core: build 1 minus every fragment's sources.
        conn = sqlite3.connect(build1)
        core_ids = by_fragment(conn).get("core", [])
        conn.close()
        bp.build_core(build1, core_ids, tmp / "core.db")
        write_base_sql(tmp / "core.db", CORPUS / "base.sql")

        # Build 1 is taken as already published on the app's id space.
        ledger1 = ledger_of(build1, app_space)
        builders = {}

        space, report = check_id_space(build2, ledger1, tmp)
        if space != app_space:
            sys.exit(f"build 2 should keep id space {app_space}, got {space}")
        builders["."] = {"builtFrom": ["schema.sql", "build1.sql", "build2.sql"],
                         "ledger": "build 1", "idSpace": space,
                         "report": report}
        good = publish(build2, GOLDEN, tmp, space)

        # Negative publications are measured against build 2's ledger: build 2
        # is what was last published.
        ledger2 = ledger_of(build2, app_space)

        space, report = check_id_space(build3, ledger2, tmp)
        if space != app_space + 1 or not any("occupied" in r for r in report):
            sys.exit(f"build 3 should bump to {app_space + 1} as occupied: "
                     f"{report}")
        builders["negative/wrong-idspace"] = {
            "builtFrom": ["schema.sql", "build1.sql", "build2.sql",
                          "build3-occupied.sql"],
            "ledger": "build 2", "idSpace": space, "report": report}
        publish(build3, GOLDEN / "negative" / "wrong-idspace", tmp, space)

        model_dir = GOLDEN / "negative" / "wrong-embedding-model"
        model_dir.mkdir(parents=True)
        for fragment in good["fragments"]:
            shutil.copyfile(GOLDEN / fragment["file"], model_dir / fragment["file"])
        write_manifest(model_dir / "manifest.json",
                       {**good, "embeddingModel": OTHER_MODEL})
        builders["negative/wrong-embedding-model"] = {
            "builtFrom": ["the published packs (.)"],
            "note": f"manifest.json with embeddingModel {OTHER_MODEL!r}"}

        checksum_dir = GOLDEN / "negative" / "checksum-mismatch"
        checksum_dir.mkdir(parents=True)
        for fragment in good["fragments"]:
            data = (GOLDEN / fragment["file"]).read_bytes()
            if fragment["id"] == "f-beta":
                data = data[: len(data) // 2]
            (checksum_dir / fragment["file"]).write_bytes(data)
        write_manifest(checksum_dir / "manifest.json", good)
        builders["negative/checksum-mismatch"] = {
            "builtFrom": ["the published packs (.)"],
            "note": "f-beta.db.gz cut to its first half; manifest unchanged"}

        full_space, full_report = check_id_space(build4, ledger2, tmp)
        if full_space != app_space + 1 or not any(
                "reshaped" in r for r in full_report):
            sys.exit(f"build 4 should bump as reshaped: {full_report}")
        space, report = check_id_space(
            build4, ledger_of(build2, app_space, with_tables=False), tmp)
        if space != app_space:
            sys.exit(f"build 4 against a shape-less ledger should keep "
                     f"{app_space}, got {space}")
        builders["negative/reshaped"] = {
            "builtFrom": ["schema.sql", "build1.sql", "build2.sql",
                          "build4-reshaped.sql"],
            "ledger": "build 2, without its `tables` entry (a ledger from "
                      "before table shapes were recorded)",
            "idSpace": space, "report": report,
            "withFullLedger": {"idSpace": full_space, "report": full_report}}
        publish(build4, GOLDEN / "negative" / "reshaped", tmp, space)

        # Expected states, from the oracle.
        base_sql = (CORPUS / "base.sql").read_text(encoding="utf-8")
        states = {}
        record_state(states, "expected/0-base.json",
                     Oracle(base_sql, tmp, app_model).state(), "base")
        plan = scenarios(app_space)
        for scenario in plan:
            scenario["builder"] = builders[scenario["dir"]]
            run_scenario(scenario, base_sql, tmp, app_space, app_model, states)

    for name, state in sorted(states.items()):
        (GOLDEN / name).write_text(render_state(state), encoding="utf-8")

    document = {
        "comment": ("GENERATED by tools/build_pack_goldens.py. Replayed by "
                    "test/pack_golden_test.dart; see README.md."),
        "appIdSpace": app_space,
        "appEmbeddingModel": app_model,
        "baseSql": "corpus/base.sql",
        "baseState": "expected/0-base.json",
        "scenarios": plan,
    }
    (GOLDEN / "scenarios.json").write_text(
        json.dumps(document, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8")

    print(f"\nWrote {GOLDEN.relative_to(ROOT)}/ (id space {app_space}, "
          f"{len(plan)} scenarios, {len(states)} expected states)")


if __name__ == "__main__":
    main()
