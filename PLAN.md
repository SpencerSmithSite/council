# Council — Remediation & Improvement Plan

A working checklist derived from the full project audit (2026-07-21). Ordered by
leverage: correctness bugs first, then the corpus integrity work, then UX.

Check items off as they land. Each item names the file(s) involved so it can be
picked up cold.

---

## Phase 1 — Bug cluster (small, independent, verifiable)

- [x] **Fix RAG tag-slug mismatch** — `lib/src/services/database_service.dart:171`
  `_extractTags` maps 7 terms to slugs that don't exist in the `tags` table
  (`soteriology`, `ecclesiology`, `pneumatology`, `atonement`, `resurrection`,
  `predestination`, `free-will`). Real slugs are `salvation`, `church`,
  `holy-spirit`. Those lookups silently return zero rows.
  Fix: map only to the 21 slugs that exist; add a debug assert that every mapped
  slug resolves.

- [x] **Fix "Unknown Source" everywhere** — `lib/src/services/database_service.dart:242`
  `getContentUnit()` queries `content_units` with no join, but
  `content_detail_screen.dart` reads `content['source_title']` (always null).
  Corrupts bookmarks, recently-viewed, and share text.
  Fix: `JOIN sources` (and traditions/source_types) in `getContentUnit`.

- [x] **Fix random-passage infinite spinner** — `lib/src/screens/random_passage_screen.dart:47`
  `_random.nextInt(total) + 1` assumes contiguous IDs; max id is 4933 vs 4918
  rows, so 15 IDs are missing. On a miss, `setState` is never called and the
  spinner hangs forever.
  Fix: add `getRandomContentUnit()` using `ORDER BY RANDOM() LIMIT 1`; also
  reset `_isLoading` in the null branch.

- [x] **Wire up `ThemeProvider`** — `lib/main.dart:28`
  Provider is never registered; `themeMode` is hardcoded to `ThemeMode.system`,
  so the Settings dark-mode dropdown does nothing.
  Fix: register in `MultiProvider`, consume for `themeMode`, have the settings
  screen drive the provider rather than `SettingsService` directly.

- [x] **Wire up font-size setting**
  Nothing reads `SettingsService.getFontSize()`. Fix: expose via a provider and
  apply through `MediaQuery.textScaler` (or the markdown stylesheet) on the
  reading surfaces.

- [x] **Wire up show-citations setting**
  Nothing reads `getShowCitations()`. Fix: gate the citation block in
  `_MessageBubble` (`chat_screen.dart`).

- [x] **Stop chat re-initializing the database** — `lib/src/screens/chat_screen.dart:30`
  Constructs its own `DatabaseService()` and calls `initialize()` again instead
  of using the Provider instance.

- [x] **Guard RAG context length** — `lib/src/services/ollama_service.dart`
  5 passages of full `content_plain` are injected; longest single unit is 83 KB.
  Fix: truncate per passage (~1500 chars) with an ellipsis marker, and cap total.

- [x] **Repair the test suite** — `test/widget_test.dart`
  Untouched counter template referencing a nonexistent `MyApp`; it's the only
  `flutter analyze` error and means zero tests compile.
  Fix: delete it, add real unit tests for `DatabaseService` query shapes and the
  tag-slug mapping.

- [x] **Clear remaining `flutter analyze` lints**
  4 × `prefer_const_constructors` in `chat_screen.dart` / `settings_screen.dart`.

- [x] **Fix stale counts and docs**
  - `assets/metadata.json`: says 3,014 units / 120 tags; actual 4,918 / 21.
  - `settings_screen.dart:195`: "523 Sources • 3,014 Passages".
  - `pubspec.yaml` says `version: 120.0.0+35` while About says `v1.0.0`.
  - `README.md` documents an Ollama host/model setting that does not exist.

- [x] **Fix substring matching in tag extraction** *(found while fixing the
  above; not in the original audit)*
  Tag phrases were matched with `String.contains`, so "hello" matched `hell`,
  "sincere" matched `sin`, "evangelical" matched `angel`, and "massive" matched
  `mass` — injecting unrelated passages into RAG context.
  Fix: whole-word regex with an optional plural suffix, so "sins" and
  "sacraments" still match. Covered by tests.

---

## Phase 2 — Corpus integrity (highest value; largest effort)

The corpus mixes genuine primary text with auto-generated filler, presented
identically and cited identically by the RAG. This is the core credibility issue
for a research tool.

Evidence: 400 sources have exactly 9 content units and 82 have exactly 7 (a
template); The Nicene Creed has duplicate unit titles plus word-shuffled
variants ("On the Creed That Is the Nicene" / "On the Nicene That the Creed
Professes"); 187 duplicate `content_plain` values; 18 units of scraper
boilerplate (`title = "About this page"`, New Advent footers).

- [x] **Audit and classify the corpus** — `tools/audit_corpus.py` (read-only)

  **Result: at least 49% of the corpus is auto-generated.**

  | verdict | units | share |
  |---|---:|---:|
  | `primary_text` | 2,314 | 47.1% |
  | `summary` (generated) | 2,412 | 49.0% |
  | `unknown` | 174 | 3.5% |
  | `boilerplate` | 18 | 0.4% |

  Treat 49% as a **floor, not an estimate**: `primary_text` means "no signal
  fired", not "verified genuine". Spot-checking found clearly generated units
  still in that bucket (e.g. unit 3582, "The preparation for baptism is the
  preparation that Cyril required — …"), and editorial summaries like the
  Athanasian Creed's "Historical Context" / "Liturgical Use" score primary too.

  The generator's tell is a recursive relative clause that restates the subject
  instead of asserting anything — 1,259 units contain three or more of
  `who/that/which is the`. The clearest specimen (unit 4371):

  > "The creed that is the Nicene is the Nicene that the Council who is the
  > Nicaea establishes — the Nicene that the Father who is the creator reveals…"

- [ ] **Restore the Nicene Creed** — the source titled "The Nicene Creed"
  contains **none of the Nicene Creed**. Its 9 units are scraped New Advent nav
  chrome, two summary paragraphs each stored twice, and two word-salad units.
  The genuine text does exist, under "First Council of Nicæa (A.D. 325)"
  (unit 514). The app's namesake document is the worst-affected entry.

- [ ] **Fix 5 sources with zero primary-text units** — The Problem of Pain
  (Lewis, 18 units), The Nicene Creed, On the Sermon on the Mount (Augustine),
  On the Holy Spirit (Basil the Great), The Martyrdom of Polycarp.

- [ ] **De-duplicate 35 duplicated source rows** — e.g. On the Duties of the
  Clergy (Ambrose) appears 3×; The Problem of Pain, The Weight of Glory,
  Theological Orations, The Pursuit of God each 2×.

**Decision (2026-07-21): rebuild the corpus from real public-domain sources**
rather than quarantining the generated material in place. The generated units
are not salvageable as research content, so the end state is a smaller corpus
of genuine primary text with real provenance URLs. Removal of the worst
material happens first so the app stops shipping it; re-ingestion follows.

- [x] **Remove generated text published under real authors' bylines** —
  `tools/prune_bylined_sources.py` (dry-run by default, `--write` to apply).
  Removed **93 sources / 812 units / 1,032 tag associations**: Lewis, Piper,
  Bonhoeffer, Packer, Stott, Barth, Tozer, Schaeffer, Yancey and others.
  Corpus 4,918 → 4,106 units; 523 → 430 sources; 8.0 MB → 6.9 MB.
  Institutional documents without a personal byline (Lumen Gentium, Barmen,
  the Catechism, Baptist Faith & Message) were deliberately left — they have a
  licensing question but not an attribution one. FTS index rebuilt afterwards
  (`content_fts` is external-content with no sync triggers, so deletes leave it
  stale); `PRAGMA integrity_check` clean, zero orphaned FTS rows.

- [x] **Add a `provenance` column to `content_units`**

- [ ] **Delete scraper boilerplate** (18 units, incl. `title = "About this page"`)

- [ ] **De-duplicate** the 187 duplicate `content_plain` values.

- [x] **Build the re-ingestion pipeline** — `tools/ingest_newadvent.py`
  (manifest → fetch → parse) and `tools/build_corpus.py` (load into the DB with
  provenance). Rate limited, disk cached, re-runnable.

### Coverage target

The app should hold the teachings, writings and council statements of every
major branch of the Christian faith, plus the individual church fathers, so
that an AI answer can cite several traditions at once. Ingestion is therefore
organised by tradition, working down from highest value.

- [x] **Early Church / Church Fathers** — newadvent.org (Schaff ANF/NPNF,
  public domain). **406 works, 17,792 units, 57M chars ingested**, 405 of 406
  with translator provenance.
- [ ] **Ecumenical councils & creeds** — partially covered by the New Advent
  councils set; verify the seven councils and the creeds are complete and
  genuine, since the current Nicene Creed entry is fabricated.
- [ ] **Catholic** — papal encyclicals (vatican.va), Trent, Vatican I & II,
  the Catechism. Note most post-1928 Vatican texts are in copyright.
- [ ] **Eastern Orthodox** — Philokalia, Desert Fathers, Palamas, Cabasilas;
  much is public domain in older translations.
- [ ] **Lutheran** — Book of Concord (bookofconcord.org, public domain):
  Augsburg Confession, Apology, Smalcald Articles, Formula of Concord.
- [ ] **Reformed** — Calvin's Institutes, Westminster Standards, Heidelberg
  Catechism, Belgic Confession, Canons of Dort (CCEL).
- [ ] **Anglican** — Thirty-Nine Articles, Book of Common Prayer, Hooker.
- [ ] **Baptist** — London Baptist Confessions 1644/1689, New Hampshire
  Confession, Baptist Faith & Message (note: BF&M is in copyright).
- [ ] **Methodist / Wesleyan** — Wesley's sermons and Notes (CCEL), Articles
  of Religion.
- [ ] **Nazarene** — Articles of Faith, Manual (check licensing).
- [ ] **Pentecostal** — Statement of Fundamental Truths, Azusa Street
  documents (check licensing).
- [ ] **Oriental Orthodox** — Coptic, Armenian and Syriac sources; likely the
  hardest to source in English translation.

- [x] **Purge remaining generated filler** — done via `build_corpus.py
  --drop-generated`. Per-unit classification alone was not enough (generated
  text was still the top FTS hit for "incarnation"), so sources are judged
  wholesale: a legacy source at least 25% generated is discarded entirely.
  **405 of 452 legacy sources went**; the 47 survivors are the genuine ones —
  Thirty-Nine Articles, Westminster Shorter Catechism, Heidelberg Catechism,
  the Ignatius epistles. Every remaining unit is now `primary_text`.

- [ ] **Label provenance in the UI**
  A passage the model paraphrased must never look like the creed itself. Badge
  non-primary units in detail, search results, and citations.

- [ ] **Exclude non-primary units from RAG retrieval** — `searchForRAG`

- [x] **Populate `authors`** — 69 patristic authors with birth/death years.
  (`works` remains empty and may simply be redundant with `sources`.)

- [ ] **Fix 71 orphaned content units** — their `source_id` matches no row in
  `sources`. They're already invisible to search (which inner-joins) and to
  random passage; `getContentUnit` left-joins so they at least still open.
  Either repair the FK or delete them.

- [x] **Populate `source_url`** — 406 of 437 sources, up from 0 of 523, each
  with translator and edition recorded in `notes`. The 31 without are the
  retained legacy confessions, which still need real provenance.

### Attribution and licensing — needs a decision before any public release

- [ ] **43 sources are marked `public_domain = 1` but are not public domain** —
  Lumen Gentium (1964), Dei Verbum (1965), Gaudium et Spes (1965), Catechism of
  the Catholic Church (1992), Barmen Declaration (1934), Tozer's The Pursuit of
  God (1948), Schaeffer's The God Who Is There (1968), and several C.S. Lewis
  titles (1940–1945). The corpus does correctly mark 61 others as `copyright`,
  so the flag is inconsistent rather than uniformly wrong.

- [ ] **Generated text is attributed to named modern authors** — the more
  serious version of the problem above. "The Problem of Pain (Lewis)" is 18
  units, **none** of them classified primary: it is generated prose carrying
  Lewis's name. Whatever is decided about the rest of the corpus, text a model
  wrote must not sit under a real author's byline. Same pattern affects Piper,
  Bonhoeffer, Packer, Yancey, Murray.

- [ ] **Expand the tag vocabulary** — 21 tags over 7,526 associations is very
  coarse for topic-based retrieval.

- [ ] **Re-classify `source_type`** — the browse-by-type axis is effectively
  broken: only 5 types exist and **500 of 523 sources are typed "Confession"**,
  including the Church Fathers and Scripture. Aquinas, Augustine, and Lewis all
  land in the same bucket. (The old `metadata.json` claimed 14 well-distributed
  types — Theologian: 120, Modern: 55, Mystic: 15 — none of which were real.)

- [ ] **Re-check tradition balance** — also misreported by the old metadata:
  actual Early Church is 135 sources (claimed 45), Reformed 61 (claimed 52),
  Baptist 7 (claimed 12).

---

## Phase 3 — UX / UI improvements

Ordered by value.

- [ ] **Make citations tappable** — biggest miss for a research tool. Citations
  are inert `Chip`s; they should open the exact passage the model saw. Carry
  `content_unit.id` through `ContextPassage`.
- [ ] **Show retrieval preview before/while generating** — users can't tell
  whether a bad answer came from bad retrieval or a bad model. Collapsible
  panel of retrieved passages above the streaming answer.
- [ ] **Search snippets with highlighting** — results show the first 150 chars,
  which often lack the search term. FTS5 `snippet()` / `highlight()` are free.
- [ ] **Stop button during streaming** — long local generations are currently
  uninterruptible.
- [ ] **Model picker in the chat app bar** — `_selectedModel` silently defaults
  to Ollama's first model, which may be an embedding model.
- [ ] **Persist chat history + multi-turn** — conversations vanish on tab switch
  and prior turns aren't sent, so follow-up questions don't work.
- [ ] **Author browsing** — depends on Phase 2 populating `authors`.
- [ ] **Ollama status in app chrome** — availability is checked once in
  `initState` and hidden behind an ⓘ dialog; no retry path if Ollama starts late.
- [ ] **Search filters** — scope by tradition, century, source type. Schema
  already supports it.
- [ ] **Counts in browse lists** — no sense of where the corpus has depth.

### Polish

- [ ] Replace `Icons.casino` (a die — reads as gambling) with `auto_stories`.
- [ ] Move Settings to an app-bar action instead of the bottom of Home.
- [ ] `_getPreview` uses `substring`, which can split a multi-byte grapheme.
- [ ] Reconsider the generic deep-purple seed color.

---

## Phase 4 — Platform & infrastructure

- [ ] **Test on macOS** (carried over from `TODO.md`; needs Xcode)
- [ ] **Test streaming responses on device** (carried over from `TODO.md`)
- [ ] **Decide on mobile** — no `android/` or `ios/` directories exist; only
  macOS and web are built.
- [ ] **Semantic search with embeddings** (carried over from `TODO.md`)
- [ ] **CI** — no automation; at minimum `flutter analyze` + `flutter test`.


---

## Phase 5 — Retrieval quality (started 2026-07-21)

- [x] **Retrieval-level chunking** — `tools/build_chunks.py`. 18,231 units →
  **53,500 chunks** (~1,200 chars, 200 overlap), split on paragraph → sentence
  → word boundaries. Stored as **offsets into the parent unit, never copied
  text** — copying would have added ~55 MB for nothing, the mistake
  `content_plain` made. DB grew 95 → 97 MB.
  Reclaims text that was previously unreachable: Augustine's *Enchiridion*
  "Faith" is 162,014 chars and the word "resurrection" first appears at char
  36,488, so the old first-1,500-chars window never contained it. It is now in
  21 of that unit's 153 chunks.

- [x] **Semantic embeddings** — `tools/build_embeddings.py`, all-MiniLM-L6-v2
  quantized (22 MB, 384 dims). 53,500 vectors, L2-normalized then int8
  quantized so cosine is a plain dot product: **21 MB**. 14.4 min to compute.
  The model file the app ships is the same one used to precompute — document
  and query vectors must come from one model.

- [x] **Dart WordPiece tokenizer** — `lib/src/services/search/`. The ONNX
  runtime does not tokenize and there is no maintained Dart port of HF
  tokenizers. Tested against ground truth generated by the Python tokenizer;
  a mismatch here degrades every search silently rather than erroring.

- [x] **Hybrid ranking primitives** — `VectorIndex` (exhaustive int8 scan;
  at 53.5k vectors an approximate index would add a dependency to save
  milliseconds) and `HybridRanker` using reciprocal rank fusion, since BM25
  and cosine are on incomparable scales.

- [ ] **Wire the query encoder** — needs the `onnxruntime` Flutter package,
  the first native dependency in the project. Until this lands, the vectors
  are computed and stored but semantic search is not live in the app.

- [ ] **Retrieval evaluation set** — a few dozen questions with known-good
  expected sources. Without it, "hybrid beats lexical" is an argument from
  first principles, not a measurement, and the fusion weights are guesses.

- [ ] **Decide how to distribute the corpus** — the bundled DB is now 118 MB
  (53 MB gzipped) plus a 22 MB model. Every rebuild commits another ~53 MB
  blob; `.git` is already ~84 MB. Options: Git LFS, GitHub release assets, or
  the downloadable per-tradition packs already planned in ARCHITECTURE.md.


---

## Phase 6 — Goal-question verification (2026-07-21)

The app must answer an open-ended stream of questions of this shape, not any
fixed list. Three representative ones were tested end-to-end with
`tools/query_probe.py`; each stands for a **class** of question, and the fix
belongs at the class level rather than the example.

| Class | Example tested | Needs |
|---|---|---|
| Comparative across traditions | Catholic vs Lutheran on baptism | broad coverage + diverse results |
| Author-scoped | What did Aquinas say about Mary? | author recognition + author's works |
| Source-scoped enumeration | Topics covered at Trent? | source recognition + that source |
| Doctrinal / vocabulary mismatch | How is a person saved? | semantic search *(works today)* |
| Tradition-scoped | What do Baptists teach about communion? | coverage + tradition filter |
| Practice / liturgical | How was the Eucharist celebrated? | semantic search *(works today)* |

**None of the first three work yet, for three different reasons.**
The retrieval machinery is sound — two doctrinal control questions return
excellent results — so what is missing is coverage and constraints, not ranking.

### "What are the differences between Catholic and Lutheran beliefs on baptism?"

Five of six retrieved passages came from one work, Augustine's *On Baptism,
Against the Donatists*; every result was Early Church. The corpus holds **zero**
Luther, Augsburg Confession, or Book of Concord.

It also actively misleads: it matched "Catholic" in Augustine's 4th-century
sense — the universal church as against the Donatists — not the modern
denomination. Confident-looking results answering a different question.

### "What did Aquinas say about the Virgin Mary?"

Topic right, author entirely absent. One hit surfaced "the most blessed Thomas"
— the *apostle*, in the Assumption narrative. Retrieval has no concept of
author, source, or tradition; "Aquinas" is just another query term.

### "What topics were covered at the Council of Trent?"

Returned Carthage, Nicaea and Athanasius' *De Synodis*. Same root cause: a named
document is treated as search terms rather than as "enumerate this source".

### The provenance hole this exposed

A "Council of Trent" source and a "Summa Theologica Selections (Aquinas)" source
do exist — **7 units each, the generated-template size**. Their text is
substantively accurate (a faithful paraphrase of Trent's Canon 9, a correct
summary of the Five Ways) but it is not the decree or the Summa, and it carries
no `source_url`, author or translator. The classifier passes it as
`primary_text` because its signals were tuned to catch word-salad, not
competent summary.

This generalises. **All 31 sources lacking provenance are the non-patristic
ones** — Reformed 7/7, Lutheran 4/4, Catholic 4/4, Anglican 2/2, Methodist 1/1.
Every source that could answer a cross-tradition question is unverified
paraphrase. The patristic depth masked how much of the old corpus survives
outside it.

### Reordered next steps

Wiring the ONNX query encoder was next, but it would make these questions fail
*faster*, not succeed — semantic search cannot retrieve documents that do not
exist, nor filter on an author it has no concept of.

- [ ] **Ingest the confessional corpora** *(now first)* — Book of Concord,
  Westminster/Heidelberg/Belgic/Dort, Trent, Thirty-Nine Articles. Unblocks the
  comparative question and replaces the 31 unprovenanced sources with real text.
  Schaff's *Creeds of Christendom* (1877, public domain) carries most of these
  in one consistently structured work.
- [ ] **Metadata-aware retrieval** — recognise when a question names an author,
  source or tradition and constrain retrieval accordingly. Unblocks the
  author-scoped and source-scoped questions. Mostly SQL plus a recogniser over
  the `authors` and `sources` tables.
- [ ] **Purge the unprovenanced legacy survivors** once replacements land — the
  classifier will not catch them, so this is a provenance rule, not a text
  check: a source with no `source_url` is not a source.
- [ ] Wire the ONNX query encoder *(after the above)*
- [ ] Retrieval evaluation set — extend the `query_probe.py` suite with
  expected sources per question so results are scored, not eyeballed.


---

## Phase 7 — Diversity-aware ranking (2026-07-21)

Ingesting the Reformed confessions proved insufficient on its own: Heidelberg
Q74, "Are infants also to be baptized?", is the **single best semantic match**
for a Reformed infant-baptism question (0.687) and still does not appear in
fused results.

Reciprocal rank fusion rewards agreement between the lexical and semantic
engines. With 398 Early Church sources against 3 Reformed, the lexical engine
floods with patristic hits, so agreement becomes a proxy for *how much of a
tradition the corpus happens to hold*:

| | RRF score |
|---|---:|
| Heidelberg Q74 — semantic rank 1, absent from lexical | 0.0164 |
| Any patristic unit present in both lists | 0.0292 |

For an app whose purpose is comparing traditions this is a design flaw, not a
tuning parameter. It will recur for **every** tradition added while the corpus
stays lopsided, and it silently penalises exactly the small-tradition sources
that make a comparative answer possible.

- [x] **Cap results per source and per tradition** — `HybridRanker.diversify`,
  wired into `searchForRAG`. Quotas are a *reservation, not a ceiling*: they
  guarantee minority sources reach the result set, then the majority tops the
  list up rather than returning a needlessly short one.
- [x] **Mirror the algorithm in `query_probe.py`** — verified against the real
  corpus, not only in unit tests. Measured effect:

  | Question | Before | After |
  |---|---|---|
  | Reformed infant baptism | 1 tradition, Heidelberg Q74 absent | 3 traditions, **Q74 present** |
  | Catholic vs Lutheran baptism | 1 tradition | **4 traditions** |
  | Reformed predestination | — | Dordt, Belgic, Second Helvetic |

### What diversity exposed

Making minority traditions visible promotes exactly the sources that have no
provenance. "Catechism of the Catholic Church", "Thirty-Nine Articles",
"Westminster Shorter Catechism" and "Second Helvetic Confession" now appear
prominently in results — and all four are unprovenanced legacy paraphrase.

Diversity ranking did not create this problem; it made it visible and much
more consequential. **Replacing those sources is now urgent rather than
housekeeping**, because they are no longer buried.
- [ ] **Surface the tradition on each citation** in the UI — a comparative
  answer is only checkable if the reader can see which tradition each source
  speaks for.

### Still outstanding from Phase 6

- [ ] **Lutheran corpus** — the last thing blocking the comparative class.
  `bookofconcord.org` does not respond; a mirror does, but its Augsburg text
  could not be confirmed as the public-domain 1921 Triglotta rather than a
  modern copyrighted translation. Needs either a verified public-domain source
  (archive.org scan of the Concordia Triglotta) or a licensing decision.
- [ ] **Metadata-aware retrieval** — author, source and tradition recognition,
  for the author-scoped and source-scoped classes.
- [ ] **Corpus distribution** — now urgent rather than theoretical: GitHub
  warns the 53 MB compressed corpus exceeds its 50 MB recommendation, and it
  grows with every tradition added.
