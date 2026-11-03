# Pack golden fixtures

These fixtures pin down how the Flutter app installs, refuses and removes
content packs, so the native Apple app (`apple/`, `CouncilCore`) can be held to
the same behaviour. Everything is tiny and synthetic: 6 sources, 10 units and
11 chunks, small enough to read whole.

- **Flutter check:** `test/pack_golden_test.dart` replays every scenario through
  the real `PackService` and compares the database against `expected/` after
  each step.
- **Regenerate:** `python3 tools/build_pack_goldens.py` (stdlib only).

## Files

| Path | What it is |
|---|---|
| `corpus/schema.sql` | **Input.** The corpus DDL, copied verbatim from `sqlite_master` of `assets/theology.db`. The generator re-checks it column by column whenever that file is present. |
| `corpus/build1.sql` | **Input.** Rows of upstream build 1, the corpus the bundled core was cut from. Sources 1–2 are core, source 3 goes to `f-alpha` and source 4 to `f-beta`. |
| `corpus/build2.sql` | **Input.** An append-only rebuild on top of build 1. It adds source 5 (to `f-beta`) above build 1's high-water mark, a new tag, a new tradition, and a new branch with a second new tradition on it, and *revises* tradition 2's description. The published packs are cut from this build. |
| `corpus/build3-occupied.sql` | **Input.** On top of build 2, deletes core source 2 and reuses its unit ids 201–202 for a new `f-beta` source. |
| `corpus/build4-reshaped.sql` | **Input.** On top of build 2, adds the column `content_units.reviewed_by`. |
| `corpus/base.sql` | **Generated.** The bundled core the app starts from. It is `build_packs.build_core` applied to build 1, dumped as SQL: the schema, then every row, then an FTS `rebuild`. Load it into an empty database (one `execute` handles all of it; statements end with `;` at the end of a line), then create the bookkeeping tables (`PackService.createTables`). |
| `manifest.json`, `f-alpha.db.gz`, `f-beta.db.gz` | **Generated.** The published release: fragments cut from build 2 by `build_packs.build_pack` and gzipped by `build_packs.gzip_file`, the same format, compression and naming as `dist/packs/`. The manifest has the same keys and layout `build_packs.main` writes, with the app's real id space and embedding model. |
| `negative/<case>/` | **Generated.** A complete release per refusal case: a `manifest.json` plus every fragment it lists. |
| `expected/0-base.json` | **Generated.** The database after loading `base.sql` and creating the bookkeeping tables. |
| `expected/1-alpha.json` | **Generated.** The database after installing `golden-alpha` (`f-alpha`). |
| `expected/2-all.json` | **Generated.** The database after installing `golden-alpha` and then `golden-all` (`f-alpha` + `f-beta`). |
| `expected/3-uninstalled.json` | **Generated.** The database after everything is uninstalled. |
| `expected/4-alpha-without-collection.json` | **Generated.** The database after a `golden-all` install where `f-beta` failed its checksum. |
| `scenarios.json` | **Generated.** Every scenario and step, its expected downloads, error and state file, and the `build_packs.check_id_space` report for the build each release came from. |

### Expected-state format

```json
{
  "tables": { "<table>": { "columns": [...], "rows": [[...], ...] } },
  "fts": { "<rowid>": { "content": "tok tok ...", "title": "tok ..." } }
}
```

- **Tables:** 15 in all. That is every corpus table (`branches` included) plus the four bookkeeping tables: `installed_collections`, `collection_fragments`, `installed_fragments` and `fragment_sources`.
- **Row order:** rows are sorted by every column, left to right (`ORDER BY 1, 2, …, n`).
- **Omitted columns:** `installed_at` is left out because it holds `DateTime.now()`.
- **BLOBs:** written as `{"blob": "<lowercase hex>"}`.
- **`fts`:** read from the FTS5 index itself, not from `content_units`. It comes from `fts5vocab(main, content_fts, instance)`, with each row's tokens joined in position order per column. A stale or missing index entry therefore shows up as a difference. A row with a NULL title has no `title` key.
- **Integrity check:** each comparison also runs `INSERT INTO content_fts(content_fts) VALUES('integrity-check')`.

### Vector convention

Each vector is 384 bytes, the real model's width. It is the chunk id as 4 big-endian bytes, repeated 96 times. For example, chunk `302001` is `00049bb1` repeated. A vector merged onto the wrong chunk is visible at a glance.

## Scenarios

Each scenario starts from a fresh base. Serve the scenario's `dir` as the release, then run the steps in order. A step with its own `dir` is served from that release instead, with its manifest fetched afresh: that is how a fragment gets republished between two installs. Each step is one of:

- `install` of a collection, with `appIdSpace` defaulting to the top-level value
- `uninstall` of a collection
- `markStale`: `UPDATE installed_fragments SET sha256='stale' WHERE id=?`

After each step, check three things where the step specifies them:

- the fragment files requested, in order (`downloads`)
- the error (`throws`)
- the full database (`state`)

The Flutter test also checks that no database named `pack` is still attached and that the `packs/` workspace holds no files.

| Scenario | Steps → state |
|---|---|
| `lifecycle` | Install `golden-alpha`: downloads `f-alpha` → `1-alpha`.<br>Install `golden-all`: downloads **only** `f-beta` → `2-all`.<br>Install `golden-all` again: no downloads → `2-all`.<br>Uninstall `golden-all`: `f-alpha` is still claimed, so it stays → `1-alpha`.<br>`markStale f-alpha`, then install `golden-alpha`: `f-alpha` is torn down and merged again → `1-alpha`.<br>Uninstall `golden-alpha` → `3-uninstalled`. |
| `replace-fails` | Install `golden-alpha` → `1-alpha`.<br>Install `golden-alpha` again from `negative/reshaped`. Its `f-alpha` has a different checksum, so the installed one is replaced: downloads `f-alpha`, verifies it, tears the old copy down and fails the merge with the `reshaped` column-count error → `1-alpha`. The teardown rolled back with the merge, so the old copy is still there, still recorded under its old checksum. |
| `wrong-idspace` | The manifest says id space 3, because `check_id_space` flagged source 6 as `occupied`. Installing with app id space 2 throws a `PackException` before any download → `0-base`.<br>Step 2 bypasses the gate by passing id space 3. It downloads `f-beta`, and the merge fails with `UNIQUE constraint failed: content_units.id` → `0-base`, fully rolled back. |
| `wrong-embedding-model` | The manifest names `golden-other-model-768`. Install throws a `PackException` before any download → `0-base`. |
| `checksum-mismatch` | `f-beta.db.gz` is truncated to half and the manifest is unchanged. Installing `golden-all` downloads `f-alpha` and merges it, then downloads `f-beta` and throws a `PackException` → `4-alpha-without-collection`. In that state `f-alpha` is installed but no collection is recorded. |
| `reshaped` | `content_units` has 11 columns against the app's 10. Install downloads `f-alpha` and throws a sqflite `DatabaseException`: `table content_units has 10 columns but 11 values were supplied` → `0-base`, rolled back. |

The exact `PackException` messages are in `scenarios.json`. A `DatabaseException` is matched by substring, because sqflite wraps SQLite's message.

## Merge semantics (what a reimplementation must reproduce)

All of this is `lib/src/services/packs/pack_service.dart`.

### 1. Gates, before any network I/O

1. **Id space.** `manifest.idSpace` must equal the app's `DatabaseService.idSpace`. A missing field reads as `1`. Otherwise it throws a `PackException` ("…different version of the app…").
2. **Embedding model.** `manifest.embeddingModel` must equal `DatabaseService.embeddingModel`, or be absent or null, which is trusted. Otherwise it throws a `PackException` ("…newer version of the app…").

### 2. Choosing fragments

The app walks `collection.fragments` in order:

- An id missing from the manifest is skipped silently, but it is still written to `collection_fragments` later.
- A fragment that is not installed is wanted.
- A fragment installed with a different, or NULL, `sha256` is wanted *and* marked for replacement.
- A fragment installed with the same `sha256` is skipped. Nothing is downloaded and nothing changes.

### 3. Each wanted fragment, one at a time

1. **Download.** The URL is `manifestUrl.replaceFirst('manifest.json', file)`. A response other than 200 throws `PackException('Download failed (HTTP n).')`.
2. **Verify.** SHA-256 is computed over the **compressed `.gz` bytes** and compared with `sha256`. A mismatch throws a `PackException`. The manifest's `bytes` field is **not** checked; it only drives progress and size display.
3. **Expand.** The file is gunzipped to `<appSupport>/packs/<id>.db`.
4. **Merge.** `ATTACH DATABASE ? AS pack` runs **outside** a transaction. Then, in **one** transaction:
   - **Replace.** If the fragment is being replaced, it is torn down first, inside this same transaction: the delete described under Uninstall, followed by an FTS `rebuild`.
   - **Reference tables.** For `branches`, `traditions`, `source_types`, `tags`, `authors` and `works`, in that order (`build_packs.REFERENCE_TABLES`): `INSERT OR IGNORE INTO t SELECT * FROM pack.t`.
     - Branch 3 and tradition 4, which sits on it, both arrive with `f-alpha` (see `1-alpha.json`). Every pack carries the full reference vocabulary, so whichever fragment comes first delivers them.
     - **OR IGNORE keeps the app's row.** Tradition 2's build-2 revision never arrives (see `2-all.json`). A new row whose `name` or `slug` collides with an existing row under a different id is also dropped silently.
   - **Content tables.** For `sources`, `content_units`, `content_tags`, `content_chunks` and `chunk_embeddings`, in that order: `INSERT INTO t SELECT * FROM pack.t`. These are plain inserts, so any id collision aborts the transaction.
   - **FTS.** `INSERT INTO content_fts(rowid, content, title) SELECT id, content, title FROM pack.content_units` appends to the index and does not rebuild it.
   - **`fragment_sources`.** One row `(fragment id, source id)` for every `pack.sources` row.
   - **`installed_fragments`.** One row `(id, bytes, units, installed_at, sha256)`. All three values come from the **manifest**, not from the file.
   - `DETACH DATABASE pack` runs in a `finally`. The archive and the expanded database are deleted in a `finally`, whether or not the install succeeded.

### 4. After every fragment succeeds

These two writes happen outside any of the fragment transactions:

- `installed_collections`: an `INSERT OR REPLACE` of `(id, name, corpus_version, installed_at)`. **The `corpus_version` column stores the id space** passed to `install`, not the corpus version.
- `collection_fragments`: an `INSERT OR IGNORE` for every id in `collection.fragments`.

### Ids

Ids are copied verbatim and never offset or renumbered. Packs are a partition of one upstream build, so their ids are disjoint by construction. The id space is the only thing that says an app's existing ids still mean the same text.

- The merge relies on `SELECT *`, so `INTEGER PRIMARY KEY` values arrive as they are.
- The chunk id convention (`unit id * 1000 + sequence`) belongs to the corpus build only. The app never computes it.

### Column order

Every copy is positional `SELECT *`, so tables must have the same columns **in the same declaration order**, including columns added later by `ALTER TABLE`. Those sit at the end: `traditions.branch_id … sort_order` and `content_units.provenance`. Use `corpus/schema.sql` exactly as it is.

- **A different column count** fails in SQLite and rolls back. That is the `reshaped` case.
- **Same count, different order** is **not detected by anything**. The merge succeeds with values in the wrong columns. A Swift version that matched columns by name would be "more correct", but it would be *different*. If that is wanted, change both apps.

### Vectors

`chunk_embeddings` rows are copied as raw BLOBs, keyed by `chunk_id`. The app never checks their length or model beyond the manifest-level `embeddingModel` gate. Nothing is re-embedded.

The app's in-memory vector index is a snapshot, so `PackService.onContentChanged` fires after any install or uninstall that changed content.

### FTS

`content_fts` is an external-content FTS5 table over `content_units` with no sync triggers:

- **Install** appends rows to the index.
- **Uninstall** and **replacement** run `INSERT INTO content_fts(content_fts) VALUES('rebuild')` instead of FTS `delete` commands.

The resulting token sets are the same either way, which is why `lifecycle` returns to `1-alpha` after an uninstall.

### Uninstall

All of these steps run in one transaction:

1. `doomed` = the collection's fragments minus every fragment claimed by another *installed* collection, read from the local `collection_fragments` table, never from the manifest.
2. Each doomed fragment that is present is deleted, in this order:
   1. `chunk_embeddings`
   2. `content_chunks`
   3. `content_tags`
   4. `content_units`
   5. `sources`
   6. its `fragment_sources` rows
   7. its `installed_fragments` row

   All of these are scoped through `fragment_sources`.
3. If anything was doomed, the FTS index is rebuilt.
4. The collection's `collection_fragments` and `installed_collections` rows are deleted.

**Reference rows are never removed.** `3-uninstalled.json` still has branch 3, traditions 3 and 4, and tag 3, which the packs added.

### Transaction boundaries and failure atomicity

- **Each fragment is its own transaction.** A collection whose second fragment fails keeps the first one merged and recorded in `installed_fragments` and `fragment_sources`. No collection row is written (`checksum-mismatch`). Installing the collection again later fetches only what is missing.
- **A failed merge rolls back completely:** reference rows, content, FTS rows and bookkeeping (`reshaped`, and step 2 of `wrong-idspace`).
- **Replacing a fragment is one transaction:** the teardown and the merge commit together. Download, checksum and gunzip failures happen before either. A merge that fails after the teardown rolls the teardown back too, so the reader keeps the copy they had (`replace-fails`). Before this was fixed the teardown committed on its own, and such a failure left the reader with neither copy.

## What the app does *not* check

These are recorded here instead of being invented as fixtures:

- **Table shape.** No column comparison exists in the app. Only SQLite's column-count error stops a reshaped pack, and reordered columns get through. The build side catches reshaping (`check_id_space` reports `reshaped` and bumps the id space) when the ledger records table shapes. The `reshaped` release was deliberately cut against a ledger without them, which is the older-ledger path where the build keeps id space 2. `scenarios.json` → `builder.withFullLedger` shows the same build bumping to 3.
- **Manifest counts and sizes.** `corpusVersion`, and each fragment's `bytes`, `sources`, `units` and `chunks`, are never compared with the file.
- **Pack contents.** Foreign keys are not enforced, so nothing checks that a pack's rows reference rows that exist. Vector widths, and whether an id falls in a fragment's expected range, are not checked either.
- **Unknown fragment ids** in a collection install nothing and raise no error.

## Regenerating

```sh
python3 tools/build_pack_goldens.py
~/development/flutter-3.44.8/bin/flutter test test/pack_golden_test.dart
```

### Inputs and outputs

The `corpus/*.sql` files other than `base.sql`, and this README, are hand-maintained. The generator deletes and rewrites everything else.

### What the generator reuses

Splitting and building go through `tools/build_packs.py`, imported rather than copied: `assign_sources`, `build_core`, `build_pack`, `gzip_file`, `sha256`, `pack_stats`, `current_ledger` and `check_id_space`. It points `build_packs.DB_PATH` and `build_packs.LEDGER_PATH` at temporary files.

### What it reimplements

The expected states come from a small SQL reimplementation of `PackService` (the oracle in the generator), so the Dart test is comparing two independent implementations.

### Self-checks before writing

The generator stops instead of writing fixtures if any of these fail:

- `idSpace` and `embeddingModel` are read from `database_service.dart`, and the model must match `build_packs.EMBEDDING_MODEL`.
- The merge table lists are read from `pack_service.dart` and must match the oracle's.
- `schema.sql` must match `assets/theology.db`, when that file is present.
- Build 2 must keep the id space, build 3 must bump it as `occupied`, and build 4 must bump it as `reshaped` against a full ledger and keep it against a shape-less one.
- Every declared download, error and state in `scenarios.json` must be what the oracle produces.

### Determinism

Running the generator twice gives byte-identical output:

- `gzip_file` writes `mtime=0` and a fixed name in the gzip header.
- Builds run from SQL in a fixed order, and `build_pack` VACUUMs.

The `.db.gz` bytes, and therefore the checksums in the manifests, can still change with a **different SQLite or zlib version**. SQLite stamps its library version into the database header, and page layout can differ between versions. `corpus/base.sql` and `expected/*.json` should not change in that case. If they do, the logical content changed.

The corpus scripts use `unhex()`, which needs SQLite 3.41 or later in the Python that runs the generator.
