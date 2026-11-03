# Golden search fixtures

`search.json` records what the Flutter app's retrieval code returns at every
stage, for a fixed set of queries, against the bundled core corpus
(`assets/theology.db.gz`, Scripture only, with no content packs). The SwiftUI
app in `apple/` reimplements retrieval in `CouncilCore/Search` and has to
reproduce this file stage by stage. The Flutter side is held to the same file by
`integration_test/search_golden_test.dart`, which produces it. Its pure-Dart
stages are also checked in the ordinary unit run by `test/search_golden_test.dart`.

Never edit `search.json` by hand. If a Flutter ranking change is intended,
regenerate the file and commit it with the change. The Swift app then has to
follow.

## Regenerating and verifying

```sh
tools/search_goldens.sh            # verify: the Dart code must reproduce search.json
tools/search_goldens.sh --update   # regenerate search.json from the Dart code
```

Both commands need macOS and the ONNX model (`tools/fetch_model.sh`). The script
uses the CI-pinned Flutter at `~/development/flutter-3.44.8`; set `FLUTTER=` to
use a different one. A run takes about 20 seconds once the macOS build is cached.

The test can't read or write the repository directly because the macOS debug
build is sandboxed (`macos/Runner/DebugProfile.entitlements`). The script works
around this in two ways:

- **Verify:** it serves this directory on a loopback port and passes the URL as
  `--dart-define=SEARCH_GOLDEN_URL=...`.
- **Update:** the test prints the fixture gzip-compressed and base64-encoded, as
  `SEARCH_GOLDEN:` lines between `SEARCH_GOLDEN_BEGIN` and `SEARCH_GOLDEN_END`.
  The script decodes those lines back into `search.json`.

Running `flutter test integration_test/search_golden_test.dart -d macos`
directly (with no define) fails and tells you to use the script.

The test unpacks the bundled asset into a fresh temporary file instead of
calling `DatabaseService.initialize()`. That method reuses the database already
in the app's container, and on a machine that has run Council that database
has packs installed.

## Top-level fields

| Field | Meaning |
|---|---|
| `corpusVersion`, `idSpace`, `embeddingModel` | The `DatabaseService` constants at generation time. If any of them differs from the code, the fixture is stale. |
| `generator` | Which test produced the file and how to regenerate it. |
| `corpus` | Row counts of the corpus used (`sources`, `contentUnits`, `chunks`, `embeddings`) and `vectorIndexLength`, the number of chunks `VectorIndex.load` holds. |
| `parameters` | The limits the run used. `ragLimit` 6 is the chat screen's `searchForRAG(text, limit: 6)`. `readLimit` 40 is the Read tab's `search(text, limit: 40)`. `fusionLimit` and `semanticLimit` are both `ragLimit * 4`. `vectorTopLimit` is `semanticLimit * 6`, the number of chunks `SemanticSearch.rankedUnits` asks the index for. `rrfK` is `HybridRanker.k`, `maxTokens` is `WordPieceTokenizer.maxTokens` and `dims` is `QueryEncoder.dims`. |
| `queries` | One record per query. Each record's `why` says what it covers. |

## Per-query fields

The fields appear in pipeline order.

| Field | Stage | Source in Dart |
|---|---|---|
| `id`, `query`, `why` | The query text exactly as passed in (it may contain combining marks, leading or trailing spaces, or be empty) and the reason it is in the set. | — |
| `tokenIds` | WordPiece ids, including `[CLS]` 101 and `[SEP]` 102. | `WordPieceTokenizer.encode` |
| `vector` | The 384 float32 values of the L2-normalised, mean-pooled query embedding. Each float32 is written as the shortest decimal that round-trips its exact value, so parse it as a Double and convert to Float. | `QueryEncoder.encode` |
| `vectorTop` | The top `vectorTopLimit` chunks for `vector`, as `[chunkId, contentUnitId, score]` sorted by score descending. | `VectorIndex.search(vector, limit: 144)` |
| `entities` | `sourceIds` and `traditionIds` (each sorted ascending) and `labels` (in the order the code produced them). | `EntityRecogniser.recognise`, loaded via `DatabaseService.recogniser` |
| `ftsMatch` | The FTS5 MATCH expression. An empty string means no FTS query is run. | `DatabaseService.ftsMatchQuery` |
| `tags` | Tag slugs, in the order the code produced them. | `DatabaseService.extractTags` |
| `read` | **Read tab**, lexical only. `path` lists the queries that ran (`fts`, then `like` if FTS found nothing). `ids` holds the unit ids returned, and `ranks` holds each row's FTS5 `rank` (bm25), or `null` for rows from the LIKE fallback. | `DatabaseService.search(query, limit: 40)` |
| `rag` | **Chat retrieval**: the stages of `searchForRAG(query, limit: 6)`, described below. | `DatabaseService.searchForRAG` |

### `rag`

| Field | Meaning |
|---|---|
| `lexicalCalls` | Every lexical query `searchForRAG` ran before fusion, in order, each as `{kind, limit, ids, ranks}`. `kind` is `ftsScoped` (the FTS query restricted to the recognised scope, `limit` 24), `fts` (the unscoped `search`, `limit` 12) or `like` (its LIKE fallback). A scoped query that returns fewer than 2 rows falls back to `fts`, which can fall back to `like`. |
| `lexical` | The lexical ranking that was fused: the ids of the last entry in `lexicalCalls`. |
| `tagIds` | The tag-engine ranking (`searchByTags(tags, limit: 6)`). It is empty when `tags` is empty. |
| `semanticLimit` | The `limit` passed to `SemanticSearch.rankedUnits` (24). |
| `allowedUnitIds` | The scope passed to semantic search, as sorted inclusive `[start, end]` id runs. `null` means unscoped. `[]` means the scope admits no units, so semantic returns nothing. |
| `allowedUnitCount` | The number of ids in that scope, or `null`. |
| `semantic` | The ranked unit ids semantic search returned: `vectorTop` in order, filtered to `allowedUnitIds`, deduplicated by unit, cut at `semanticLimit`. |
| `fused` | `HybridRanker.fuse(lexical, semantic, tags: tagIds, limit: 24)`. |
| `namedTraditionCalls` | The scoped FTS queries `_ensureNamedTraditions` ran after fusion (`limit` 2). These happen only when 2 or more traditions are recognised. |
| `final` | The unit ids `searchForRAG` returned, which are what the chat screen uses: after diversification and named-tradition balancing. |
| `finalContent` | Per returned row: `id`, plus `length` and `head` (the first 48 characters) of the `content` that `_bestChunkText` chose. Both are measured in UTF-16 code units. |

The `rag` stages are observed, not recomputed. The test runs the real
`searchForRAG` against a `Database` wrapper that records each raw query with its
rows, and against a `SemanticSearch` wrapper that records each call. It does
this because `_searchScoped` and `_unitsInScope` are private. The one value the
test computes itself is `fused`, by calling the real `HybridRanker.fuse` on the
recorded inputs. The unit test checks it the same way.

## Tolerances for the Swift side

- **Ids, orderings, counts, strings and token ids must match exactly.** This
  covers `tokenIds`, every id list, the chunk and unit ids in `vectorTop`,
  `entities`, `ftsMatch`, `tags`, `path`/`kind`/`limit`, and `final`.
- **`vector`: absolute tolerance `1e-5` per component.** The values are float32
  from ONNX Runtime with the quantised model, and the Flutter test uses this same
  tolerance. Agreement depends on the ONNX Runtime *version*, not only the
  model: the Flutter plugin bundles ORT 1.15.1, and the Swift app's ORT 1.24.2
  differs by up to 0.03 unless `MatMulIntegerToFloatFusion` is disabled (see
  `QueryEncoder.swift`). With it disabled, 35/37 queries agree within 1e-7;
  `ent-catholic` (2.4e-5) and `edge-long` (1.2e-3) remain, with cosine
  similarity ≥ 0.99997. So the Swift retrieval tests rank from the recorded
  `vector`, not a re-encoded one, and stay exact. A CoreML-converted model
  drifts further and should not be used.
- **`vectorTop` scores: absolute `1e-5`, with the order exact.** Within the
  part of the list semantic search actually consumes (at most the first 34
  entries in this fixture), the smallest gap between neighbouring scores is
  `7.4e-7`. Further down, gaps get as small as `2.5e-8` (`ref-rom-8` position
  139, `empty-result` position 59). If Swift's order differs only at one of
  those deep positions, the cause is float noise, not a logic bug. Investigate
  it, but it can't change `semantic`.
- **FTS `ranks`: absolute `1e-5`, with the order exact.** bm25 is computed by
  SQLite. Very common terms make `idf` clamp to `1e-6`, so ranks like
  `-2.09e-6` (see `mix-lords-supper`) differ only in the 10th decimal place, and
  only their order is meaningful.

## Swift implementation notes

Things in the Dart code that are easy to get subtly wrong:

1. **RRF ties are everywhere.** A unit at position *i* in one list scores the
   same as a different unit at position *i* in another list. Most queries here
   have 5 to 15 exactly tied fused scores. `fuse` breaks ties by **ascending unit
   id**. It sums contributions in the order lexical, semantic, tags, each
   `weight / (60.0 + i + 1)` in Double. Use that same order so tied sums are
   bit-identical. A repeated id within one list counts once, at its first
   position.
2. **Vector index scoring** accumulates `Double(int8) * Double(float32 query)`
   in a Double, sequentially over `d = 0..<384`, and then divides by 127.0.
   Float32 SIMD accumulation (for example vDSP) gives different low bits.
   Insertion into the top-N is stable: a later chunk with an equal score goes
   after the earlier one.
3. **Pooling** stores the running sum and the mean in float32 (`Float32List`),
   accumulates the norm in Double, and divides each float32 component by the
   Double norm, storing float32. Every token is pooled, `[CLS]` and `[SEP]`
   included, because the attention mask is all ones.
4. **Traditions are matched whole names first, then word by word.** A
   tradition whose name has two or more words (after `_tokenise` drops
   stopwords) matches when the question contains all of them, and those words
   are then used up: `Eastern Orthodox icons` names tradition 3 alone, not 3
   and 4. Names are tried in ascending id. Each remaining word, and each
   adjectival form (`catholics`, `roman`, `orthodox`), goes to the tradition
   with the fewest words in its name, then the fewest characters, then the
   lowest id. So `catholic` is *Catholic* (2), not *Polish National Catholic*
   (28), and a bare `orthodox` is *Eastern Orthodox* (3), not *Oriental
   Orthodox* (4). See `ent-catholic`, `ent-two-traditions` and `ent-orthodox`.
   The result does not depend on row order. Until this was fixed, matching was
   last-write-wins over rows SQLite returned alphabetically from the UNIQUE
   index on `name`.
5. **Every retrieval query breaks ties by ascending unit id.** The FTS queries
   order by `fts.rank, cu.id`, the LIKE fallback by `cu.sequence, cu.id` and
   the tag query by `tag_matches DESC, cu.id`. Exact bm25 ties exist
   (`ref-genesis-1-1`, `ref-psalm-23`), and nearly every tagged unit has
   `tag_matches = 1`, so the tie-breaker decides which 6 tag rows survive the
   limit. Use the same SQL text, `ORDER BY` included.
6. **The Flutter app uses the SQLite bundled by `sqlite3_flutter_libs`** (via
   the FFI factory), not the system one, and this fixture was generated through
   it. With the tie-breakers in note 5 the orderings should not depend on that.
   bm25 values are still computed by SQLite, hence the tolerance above.
7. **Scripture references are not parsed.** `John 3:16` reaches FTS as
   `"John"*`, because terms of 2 characters or fewer are dropped. The verse is
   found, if at all, by semantic search.
8. **`ftsMatchQuery` keeps letters and digits from any script**, but a combining
   mark (`\p{M}`) is a separator. Decomposed `Nicée` therefore becomes `"Nice"*`,
   while the tokenizer strips the mark and folds the word to `nicee`.
9. **A scope that admits no units is not the same as no scope.**
   `allowedUnitIds: []` makes semantic search return nothing. In the core
   corpus that happens to every tradition except Scripture, which is why
   `empty-result` and `ent-orthodox` come back empty.
10. **Empty input** still runs semantic search on `[CLS] [SEP]` and returns
    results (`edge-empty`), while `search('')` returns nothing.
