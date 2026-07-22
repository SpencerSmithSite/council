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
- [x] **Metadata-aware retrieval** — `EntityRecogniser`, wired into
  `searchForRAG`. Both engines honour a recognised scope; scoping only the
  lexical side let unscoped semantic hits back in through fusion, so a
  question about Trent still returned Carthage and Nicaea.

  | Class | Result |
  |---|---|
  | Source-scoped — "topics covered at Trent?" | scopes to *Council of Trent*, returns its decrees |
  | Author-scoped — "Augustine on grace?" | scopes to Augustine's 44 works |
  | Comparative — "Catholic vs Lutheran" | scopes to both traditions |

  **Rejected: identifying a work by a single rare token.** Tokens like
  "virgin", "topics" and "saved" appear in one or two titles while being
  ordinary vocabulary, so rarity scoped "how is a person saved?" to *Who is
  the Rich Man That Shall Be Saved?*. Two matching tokens are now required,
  which costs the ability to resolve a bare surname like "Aquinas" and buys
  freedom from that entire class of false positive.
- [ ] **Corpus distribution** — now urgent rather than theoretical: GitHub
  warns the 53 MB compressed corpus exceeds its 50 MB recommendation, and it
  grows with every tradition added.


---

## Phase 8 — What metadata scoping exposed (2026-07-21)

### Tradition labels in the legacy corpus are fabricated

Scoping is only as good as the column it scopes on. Every source labelled
**Lutheran** was something else: the Didache, the Philokalia, Gregory of
Nyssa's *Life of Moses*, and Peter Mogila's *Orthodox Confession* — two Eastern
Orthodox, two patristic. Before scoping these were buried; afterwards the app
answered "what do Lutherans teach" with Orthodox texts under a confident
Lutheran heading, which is worse than returning nothing.

- [x] **Correct the fabricated labels** — `tools/fix_legacy_metadata.py`.
  7 relabelled, 7 duplicate sources / 138 units deleted. Lutheran is now
  honestly **zero sources**.
- [x] **Deliberately not a blanket purge.** Sampling showed some unprovenanced
  sources carry genuine text — the Thirty-Nine Articles open with the real
  Article I, Westminster Shorter with the real Question 1. Deleting those would
  destroy exactly the confessional material the corpus lacks.

### Chunk ids were unstable, and it silently corrupted every vector

Deleting 138 units reassigned every chunk id after them, and embeddings are
keyed on chunk id. Sampled vectors matched their supposed chunk at cosine
0.33–0.49 — pointing at unrelated text. **Nothing errored.** Semantic search
would have returned nonsense with no symptom.

This fragility was noted two phases earlier, when the ids "happened to line up
because new units append after existing ones — luck rather than design". The
luck ran out the first time a deletion landed mid-corpus.

- [x] **Derive chunk ids from the parent unit** (`unit_id * 1000 + sequence`),
  so removing a unit invalidates only that unit's chunks.
- [x] **Drop orphaned embeddings automatically** when chunks are rebuilt.
- [x] **Verify alignment by re-embedding samples** rather than trusting counts,
  which is what caught it.

### Outstanding

- [x] **Lutheran corpus** — `tools/ingest_gutenberg.py`. Augsburg Confession
  (31 units), Apology (102), Smalcald Articles (13), Luther's Small Catechism
  (15) — **161 units**, the Bente/Dau translation prepared for the 1921
  *Concordia Triglotta*.

  **Rejected: the archive.org scans.** OCR renders Augsburg Article I as
  "Gk)d the Father", "quail*ty" and "Manichs&ans" — roughly one error per
  hundred characters. Tolerable in a search index, not in an app whose purpose
  is quoting sources accurately. Gutenberg's texts are proofread
  transcriptions of the same translation.

  The rights check records what it actually verified: Gutenberg's statement is
  collection-level ("nearly all the individual works…"), so it is evidence
  rather than a per-work guarantee, and the per-work basis is the 1921
  publication date. Both are stored against the source so a reader can check
  the reasoning instead of trusting it.
- [ ] **Re-ingest the genuine-but-unprovenanced confessions** — Thirty-Nine
  Articles, Westminster Shorter and Larger, Second Helvetic, Scots. Real text,
  no provenance, and now prominent in results because of diversity ranking.
- [ ] **Surface tradition and provenance on citations in the UI** — a
  comparative answer is only checkable if the reader can see which tradition
  each source speaks for and whether it is verified.
- [ ] **Corpus distribution** — GitHub warns at 53 MB and it grows per
  tradition.
- [ ] Wire the ONNX query encoder; build a scored retrieval evaluation set.


---

## Phase 9 — Lutheran corpus (2026-07-21)

The comparative class now works end to end. "What are the differences between
Catholic and Lutheran beliefs about baptism?" returns Luther's Small Catechism
on what baptism gives, alongside the Catholic material — genuine Lutheran
primary text, where a week ago the four "Lutheran" sources were Eastern
Orthodox and patristic.

**Caveat worth stating:** the Lutheran side is now verified primary text while
the Catholic side is still unprovenanced legacy paraphrase (Catechism of the
Catholic Church, Council of Trent, Summa selections). The comparison is real
on one side only.

- [x] Stable chunk ids proved themselves: adding 161 units required embedding
  **756 new chunks**, not all 54,322. Before the fix this would have been a
  14-minute rebuild — or worse, a silent misalignment.

### Next

- [x] **Verified Catholic primary text** — `tools/ingest_trent.py`. Waterworth's
  1848 translation (archive.org scan of the 1888 reprint): **104 units** across
  the ten doctrinal sessions, replacing the seven units of paraphrase.

  This OCR was accepted where the 1851 Book of Concord scan was rejected, and
  the difference was measured rather than assumed: a garble check over the body
  found no obvious errors here, against roughly one per hundred characters
  there. The one artifact is doubled spaces from column justification.

  That artifact then caused the parser to find nothing at all — the doubled
  spaces sit *inside* the headings, so the file reads "SESSION  THE  FOURTH"
  and a pattern written against normal spacing matched zero sessions.
  Whitespace is now collapsed before anchoring, not after.
- [ ] **Re-ingest the remaining unprovenanced confessions** — Thirty-Nine
  Articles, Westminster Shorter and Larger, Second Helvetic, Scots. Genuine
  text, no provenance. Not on Gutenberg, and the CCEL path tried returned 404;
  needs a located source. **23 sources still lack provenance.**
- [ ] Surface tradition and provenance on citations in the UI.
- [ ] Wire the ONNX query encoder; scored retrieval evaluation set.
- [ ] Corpus distribution — now 54 MB compressed.


---

## Phase 10 — Trent's actual decrees (2026-07-21)

The comparative class is now primary text on both sides. Asking how Catholic and
Lutheran teaching on baptism differ returns Trent's decrees alongside the
Smalcald Articles and Luther's Small Catechism — where a day ago the Catholic
side was seven units of paraphrase and the Lutheran side did not exist.

### A regression this caused, and the rule that fixes it

Renaming the source from "Council of Trent" to its full title silently broke
source scoping. The question supplies "council" and "trent" — two of four title
tokens, under the 0.6 fraction threshold — so a question explicitly naming the
council stopped being scoped to it.

The fix is narrow on purpose: a token appearing in at most two works is
distinctive enough to name that work **when matched alongside at least one
other token**. The two-token requirement still holds, so this does not reopen
the single-rare-token false positives ("saved", "virgin", "topics") that made
the earlier rule untenable. Both behaviours are pinned by tests, and the rule
is mirrored in `query_probe.py` and checked against the real corpus.

### Known quality gap, not yet addressed

Retrieval now finds the right *sources* for a comparative question but not
always the right *passages* — a baptism question returned Trent's session on
Penance and the Apology's article on God. Unit selection ranks whole units,
some of which are large; chunk selection then picks within the chosen unit
rather than choosing the best chunk corpus-wide. Worth revisiting when the
query encoder lands, since semantic scoring at chunk level is what fixes it.


---

## Phase 11 — The app actually runs (2026-07-21)

`TODO.md` had recorded "Test on macOS (needs Xcode)" as blocked since April.
Xcode 26.6 is installed, so it is not blocked. **The app had never been run.**
Everything to this point was verified by unit tests against fixtures and by a
Python mirror of the retrieval path — neither of which executes the shipped
code against the shipped data.

- [x] **Builds and launches on macOS.** Clean start, no exceptions.
- [x] **The gzipped-asset path works for real** — 54 MB asset decompresses to a
  120 MB database on first launch and the `corpusVersion` stamp is written.
  Previously only asserted by a unit test that the bytes were valid gzip.
- [x] **Integration tests against the real corpus** —
  `integration_test/retrieval_test.dart`, 9 tests, run with
  `flutter test integration_test/retrieval_test.dart -d macos`.

### It found a serious bug on its first run

FTS5 reads `"a b"` as an implicit AND. `search()` juxtaposed the words of the
question, so a sentence required **every** word — "what", "did", "the"
included — to appear in one passage:

| Query form | Units matched |
|---|---:|
| Dart, juxtaposed (AND) | **0** |
| Python probe, `OR` | 1,423 |

Lexical retrieval had been returning nothing for natural-language questions,
falling through to a `LIKE '%whole question%'` fallback that matches nothing
either. Every Python-side verification in this plan was run against a mirror
that was *more permissive than the code it mirrored*, so nothing caught it.

This is the specific risk of verifying a Dart path through a Python
reimplementation: the mirror is written to match, but nothing enforces the
match. The integration test exists to enforce it, and earned its place
immediately.

- [x] Terms now joined with `OR`; words of three characters or fewer dropped.
  Four unit tests pin the behaviour.

### Next

- [ ] Wire the ONNX query encoder — semantic search is still not live in the
  app; only the lexical half runs. This is also what fixes passage selection
  (right source, wrong passage).
- [ ] Generate `ios/`, `android/`, `windows/`, `linux/` targets and run there.
- [ ] Remaining 23 unprovenanced sources.
- [ ] Corpus distribution — 54 MB compressed, 120 MB installed.


---

## Phase 12 — Semantic search live; all platforms; web dropped (2026-07-21)

Decisions taken: accept the native dependency, support every OS including
mobile, drop web, and pursue downloadable data packs.

- [x] **Query encoder wired.** `onnxruntime` 1.4.1 declares android, ios,
  linux, macos and windows — every remaining target — which settles the risk
  flagged before committing to it. The 54,854 vectors shipped since Phase 5
  were dead weight until now; semantic search runs in the app for the first
  time.
- [x] **Semantic is optional by construction.** `SemanticSearch.tryLoad`
  returns null on failure and retrieval stays lexical. A device that cannot run
  the model gets a searchable library, not a failed launch — covered by a test
  that runs retrieval with the model explicitly absent.
- [x] **Kept out of the unit suite.** The encoder runs through a native plugin,
  so anything importing it transitively cannot run under `flutter test`.
  Injecting it into `DatabaseService` rather than constructing it there keeps
  55 unit tests platform-free.
- [x] **All five platforms generated** — android, ios, linux, macos, windows.
- [x] **Web dropped.** It compiled but threw at runtime: `sqflite` has no web
  implementation, so the database never opened. Removing it is honest rather
  than costly. It is **not** needed for data packs — see below.

### Hosting data packs — answered

Packs need static file hosting, not a web app or a server. **GitHub Releases**
covers it: free, CDN-backed, versioned, up to 2 GB per file, already where the
code lives, and reachable by plain HTTP GET from the app. Dropping the Flutter
web target has no bearing on it.

- [x] **Pack format designed and built** — see Phase 15.

---

## Phase 13 — Mobile builds and network reachability (2026-07-21)

Building the generated iOS and Android targets for the first time, which is
where the platform config that Ollama-over-LAN depends on had to be written.

- [x] **Android release had no network at all.** Flutter declares `INTERNET`
  only in the debug and profile manifests, for hot reload. Nothing in this repo
  had ever built a release APK, so the omission was invisible: Ollama, cloud
  keys and pack downloads would each have failed on exactly the builds users
  install, and worked for every developer.
- [x] **Cleartext permitted, via a network security config** rather than the
  `usesCleartextTraffic` boolean, so the reasoning sits next to the setting.
  The exception is general because the user types the host; it is narrow in
  effect because every cloud provider URL in the app is a literal `https://`
  constant and is unaffected.
- [x] **iOS/macOS local network access.** `NSLocalNetworkUsageDescription` plus
  `NSAllowsLocalNetworking` — deliberately not `NSAllowsArbitraryLoads`, which
  App Review treats as needing justification. macOS 15 applies the same prompt,
  and the omission was hidden there because a local Ollama does not trigger it:
  the developer's own setup is the one case that works without the key.
- [x] **Tailscale needed its own exception.** MagicDNS names end in `.ts.net`
  and its addresses sit in 100.64/10, neither of which counts as "local" to
  ATS. A `ts.net` exception domain covers it. Raw 100.x addresses are still
  refused on iOS — ATS matches domains, not IP literals — and refused as a
  plain connection failure that reads as "Ollama is down", so the host field
  says so on iOS rather than leaving the user to debug it.
- [x] **Android would not build.** `onnxruntime` pins `compileSdkVersion 33`
  while the AndroidX libraries the engine pulls in require 34+. The pin is in
  the published package, so it is overridden in the root Gradle file. Raising
  compileSdk changes only which APIs the plugin compiles against — minSdk and
  targetSdk are untouched, so no device loses support.
- [x] **App named Council** on Android and iOS; it was still "theology_app".
- [x] **Verified against the built artefacts, not the source.** The merged APK
  manifest carries `INTERNET`, the label and the network security config
  reference; the built `Runner.app` plist carries the ATS keys. Config that is
  correct in the repo and dropped during merge is the failure worth catching.

### Size — the argument for packs, measured

| | |
|---|---|
| Android, per-ABI (arm64) | **101 MB** |
| Android, universal APK | 145 MB |
| iOS `Runner.app` | 119 MB |

Of that, 54 MB is the compressed corpus and 22 MB the embedding model. Splitting
per ABI is worth doing on its own — the universal APK ships three architectures
so every device carries two it cannot run — but the corpus is the single
largest item and the reason packs matter.

- [ ] Ship Android as an App Bundle so Play does the ABI split.
- [x] **Identifier settled: `site.spencersmith.council`** — see Phase 14.

### Not yet verified

- [ ] **Run** on a physical iPhone/Android device. Both *build*; neither has
  been launched, and the local-network prompt in particular cannot be exercised
  by a build.
- [ ] Linux and Windows builds — cannot be produced from this machine.

---

## Phase 14 — The app is called Council (2026-07-21)

Done now rather than later because a bundle identifier is the one thing here
that cannot be changed after the fact: both stores refuse to reassign an app's
identifier once it has been published, so `com.example.*` would have been
permanent.

- [x] **`com.example.theologyApp` → `site.spencersmith.council`** across
  Android, iOS, macOS and Linux, with the Kotlin source moved to the matching
  package directory.
- [x] **Dart package renamed** `theology_app` → `council`, so the repo stops
  calling itself by the old name internally. Low risk and easy to revert,
  unlike the identifier.
- [x] **Product names and window titles** on every platform; macOS now builds
  `Council.app` rather than `theology_app.app`, and the stale `TEST_HOST` path
  that still pointed at the old bundle was fixed with it.
- [x] **Copyright strings** no longer read "com.example".
- [x] **Verified by rebuilding all three buildable platforms** and reading the
  identifier back out of each built bundle, not out of the source. A rename
  that is right in the project file and wrong in the artefact is the failure
  worth catching; all three report `site.spencersmith.council`.

Linux and Windows are edited but unverified — neither can be built from this
machine.

---

## Phase 15 — Content packs (2026-07-21)

The app was 101 MB on Android and 119 MB on iOS, and 54 MB of that was corpus.
Of 58.8 million characters, 56.3 million are patristic — so a reader who wanted
their own tradition's confessions was downloading the complete works of
Chrysostom to get them.

**Android arm64 is now 50 MB.** The bundled corpus went from 54 MB to 2.6 MB.

| pack | sources | units | download |
|---|---|---|---|
| core (bundled) | 44 | 902 | — |
| Augustine of Hippo | 44 | 2,496 | 4.6 MB |
| John Chrysostom | 36 | 2,932 | 6.3 MB |
| Church Fathers | 313 | 12,201 | 22.8 MB |

### The decision that makes it safe

**Packs are a partition of one corpus build, not separately-built databases.**
Every row keeps the id it already had, so ids are disjoint by construction and
nothing is renumbered on install.

The alternative — building each pack independently and offsetting ids into
reserved ranges — is a rerun of the failure this project already had once:
chunk ids are derived from unit ids, embeddings are keyed on chunk ids, and a
renumbering that goes wrong does not raise an error. It silently points vectors
at unrelated text. Choosing a design with no renumbering step removes the
possibility rather than guarding against it.

The corollary is a rule the builder states and the app enforces: **packs and
core are always built together, and `corpusVersion` is bumped when they are.**
A pack declares the version it came from and is refused on mismatch.

- [x] `tools/build_packs.py`, driven by `tools/data/packs.json` — boundaries
  are declared in data because the right split depends on a corpus that keeps
  changing. Re-splitting is an edit and a rebuild, never a code change.
- [x] Every source is assigned exactly once; anything unclaimed falls into
  core, so adding a source without editing the config grows the app rather
  than vanishing.
- [x] Packs carry no FTS index — the app's index is appended to on install.
  That is why the three packs total 34 MB where the corpus they came from was
  54 MB.
- [x] `PackService` — download, checksum, merge, uninstall. Content rows are
  inserted *without* `OR IGNORE`: ids are disjoint by construction, so a
  collision means pack and app disagree and should fail loudly rather than
  drop half the pack and report success.
- [x] Uninstall rebuilds the FTS index rather than issuing `'delete'` commands,
  which require passing the exact original column values back and corrupt the
  index silently when they do not match.
- [x] Vector index reloaded on install. It is a snapshot taken at startup, so
  without this the new text is found by lexical search and ignored by semantic
  search — a successful-looking install with quietly worse answers.
- [x] Library screen under Settings; downloads show progress, removal is
  confirmed.
- [x] **Verified end to end against the real corpus**, with the packs served
  over real HTTP: install adds retrievable content, a second install is a
  no-op, a corrupted download is refused and not merged, and uninstall leaves
  no unreachable index entries. The retrieval suite now runs both ways — over
  the core alone and over a pack-assembled library — and passes identically.

### Hosting — published

- [x] **Release `corpus-v3` cut**, with the manifest and all three packs
  attached. The pack suite now runs against the real
  `releases/latest/download/` URL and passes: download, checksum, merge and
  uninstall over the actual CDN.
- [x] **Builds made reproducible.** gzip stamps the current time into its
  header, so rebuilding identical content produced different bytes and
  different checksums. Since checksums are what the app trusts to decide a
  download is intact, that made "did the corpus change?" unanswerable by
  comparing manifests and forced a 35 MB re-upload on every rebuild. `mtime=0`
  fixes it; two consecutive builds are now byte-identical.

### Known gaps

- [ ] Packs cannot be updated in place — only removed and reinstalled.
- [ ] Installing on mobile is untested; the merge is heavier there.

---

## Phase 16 — Telling the reader what is missing (2026-07-22)

Splitting the corpus made a new failure reachable, and it is the worst one this
app can have: **it can only search text it holds.** A library without the
fathers answers a question about the Eucharist from confessions alone — fluent,
cited, and drawn from 7 of the 83 passages that exist on the subject. For an app
whose purpose is showing what each tradition actually taught, omitting one
silently is worse than refusing to answer.

### The measurement that made it work

The first attempt asked *what share of a pack is about this subject*, and it
found nothing — the Eucharist is 0.2% of Augustine. That number is real and
completely irrelevant. The question a reader needs answered is the other
direction: **what share of everything written on this subject is missing?**

| tag | core | in packs | missing |
|---|---|---|---|
| eucharist | 7 | 76 | **91.6%** |
| baptism | 14 | 1,064 | 98.7% |
| justification | 13 | 92 | 87.6% |
| trinity | 37 | 443 | 92.3% |

- [x] `pack_catalogue.json` bundled, not fetched — the app has to describe what
  it is missing while offline, which for an offline-first library is the normal
  case. 19 KB, generated with the packs so it cannot drift.
- [x] Three signals, in order: the question names an author, names a work, or
  the subject is one where most material is uninstalled.
- [x] **Restraint is tested, not assumed.** Whole-word matching so "original
  sin" does not match Origen; common first names excluded so a question about
  the gospel of John does not summon Chrysostom; one notice per question, not
  one per missing pack; and installing the main collection quiets the warning
  for nearly every subject, because it genuinely closes the gap. A notice that
  is wrong once is a notice nobody reads again.
- [x] `extractTags` made public: the notice reads the question the same way
  retrieval did, so the two cannot disagree about what was asked.
- [x] Shown above the composer rather than inside the answer, so it reads as a
  note about the library and not as something the sources said.

---

## Phase 17 — Provenance: 23 unsourced legacy entries (2026-07-22)

They were not one problem. Sorting them was most of the work.

**Added as complete sourced texts** — Westminster Shorter Catechism (107
questions), Westminster Larger Catechism (196), Thirty-Nine Articles (39). The
stubs they replace held 23, 7 and 42 units of abridgement.

**Removed, superseded** (8) — a fuller sourced edition was already present. The
`Contra Celsum` stub held 2,015 characters; *Against Celsus* holds 1,325,124.

**Removed, not ours to ship** (2) — the Catechism of the Catholic Church and
Lumen Gentium are © Libreria Editrice Vaticana and were both recorded here as
`public domain`. Age and free availability online do not make a text free to
redistribute, and a licence field asserting otherwise is worse than an empty
one.

**Removed, not text** (1) — `Against Heresies` held chapter indexes: "Preface
Chapter 1 Absurd ideas of the disciples of Valentinus... Chapter 2 The Propator
was known to Monogenes alone..." It retrieves on every patristic keyword and
says nothing.

**Also removed** — 45 units whose source row no longer existed, left by an
earlier phase that deleted sources without cascading. They predate this work,
but with no source they have no title, tradition or origin, so the new citation
UI would have shown them as "Unknown source, origin not recorded".

**Remaining: 12**, marked in the app rather than hidden.

### Three things this nearly got wrong

- **`Against Heresies` was queued for deletion as superseded by the
  provenanced `Adversus haereses`** — 29,580 characters replaced by 28,578,
  which reads like a reasonable trade. Both are chapter indexes. The swap would
  have been recorded as an improvement. A corpus-wide scan found the defect in
  3 sources and 14 units, 0.07% — contained, but `Adversus haereses` and *The
  Harmony of the Gospels* still need re-ingesting from their chapter pages.
- **The Shorter Catechism parsed to a clean, plausible 100 questions.** It has
  107. The file numbers most questions `Q1:` and seven of them `Q20.`, and the
  parser matched only the first form — dropping the covenant of grace among
  others. The parser now refuses any document with holes in its numbering.
- **The Thirty-Nine Articles parsed to 36.** Three titles wrap onto a second
  line, and a line-anchored pattern skipped exactly those three.

### The Westminster Confession was rejected, not missed

CCEL's edition is a critical apparatus carrying the PCUS and UPCUSA recensions
in parallel with variant readings inline — `yet [PCUS are they] [UPCUSA they
are] not sufficient`. That is the same defect that disqualified Schaff's
*Creeds of Christendom*, and the standard holds in both cases. It is also the
only one of the three CCEL files that declares no rights at all. It stays
unsourced until a clean edition is found.

Corpus is **v4**, published. 429 sources, 18,719 units, 55,037 chunks and
embeddings, zero orphans in any direction.

### Next

- [x] Surface tradition and provenance on citations in the UI.

---

## Phase 18 — Source roadmap (2026-07-22)

[SOURCES.md](SOURCES.md): every branch of Christianity the app aims to cover,
the documents that define it, and where they can actually be obtained.

The finding that shapes the rest of the project: **copyright, not availability,
is the binding constraint, and it falls unevenly.** Traditions that formed
before roughly 1929 can be shipped whole; those that formed after cannot. That
maps almost exactly onto Pentecostalism and post-Vatican II Catholicism — so a
freely-redistributable corpus will systematically under-represent the
second-largest Christian movement in the world. That is a limitation to state,
not a gap to quietly fill with summaries.

Archives were checked rather than recalled. Seven resolve; four do not (EEBO
needs institutional access, GAMEO blocks automation, two are simply dead).
`newadvent.org/summa/` was checked for *article text* specifically, because two
sources already in this corpus turned out to hold New Advent index pages.

- [ ] **Aquinas from `newadvent.org/summa/`** — largest single gain available,
  on an archive already trusted and already parsed.
- [ ] **Second London Baptist Confession (1689)** — `baptist` is a defined
  tradition with zero sources.
- [ ] **Wesley's Standard Sermons** — `methodist` holds 0.001 M characters.
- [ ] Re-ingest `Adversus haereses` and *The Harmony of the Gospels*.
- [ ] A clean Westminster Confession.
- [ ] Remaining 23 unprovenanced sources.
- [ ] Scored retrieval evaluation set.


---

## Phase 19 — Tagging, and packs on two layers (2026-07-22)

### The tagging bug

Tagging only ever ran inside `build_corpus.py`, the New Advent path. Everything
ingested since — every confessional document — arrived untagged. 832 units, and
specifically *these*: Trent, the Augsburg Confession and its Apology, the
Westminster catechisms, Heidelberg, Dordt, the Belgic, the Thirty-Nine
Articles.

Tag search is one of the three engines fused in `searchForRAG`, so comparative
questions ran on two. It had also just got **worse**: the abridged legacy stubs
were 98% tagged, so replacing them with sourced full texts moved confessional
tag coverage from "works, via stubs" to "nothing at all" — an improvement in
the corpus that was a regression in retrieval.

| tradition | before | after |
|---|---|---|
| lutheran | 0/161 | **149/161** |
| anglican | 0/39 | **32/39** |
| reformed | 27/556 | **396/556** |
| catholic | 22/126 | **111/126** |

A question about baptism now draws on six traditions; justification on four.

### Fragments and collections

The old split mixed two axes with no principle — Augustine and Chrysostom were
carved out because they were *large*, which is a size optimisation dressed as a
taxonomy. Supporting era, tradition and author groupings at once means the same
work belongs to several groups, and the obvious implementation publishes it
several times.

So there are two layers:

- **Fragments** are the files: a disjoint partition of one corpus build, each
  body of text published exactly once. Ids stay disjoint, so merging still
  needs no renumbering.
- **Collections** are what the reader picks: named, overlapping lists of
  fragment ids that own no text.

**17 fragments, 37.5 MB. The same 16 collections as standalone files: 95.3 MB.**
Adding a new way to browse now costs a few lines of config and no bytes.

- [x] Install fetches only fragments not already present; the library quotes
  what a collection costs *now*, and "Already downloaded" is a common answer.
- [x] Uninstall removes only fragments no other installed collection needs,
  computed from a local record rather than the manifest so it works offline and
  cannot change under the reader.
- [x] Coverage arithmetic moved to the fragment level. Summed over collections
  it counted Augustine four times, making every subject look almost entirely
  missing.
- [x] One notice per question, naming the **narrowest** collection that answers
  it. Asking about Chrysostom matches three collections; suggesting the largest
  would mean downloading the complete fathers to read one letter.

### Still to do from this design

- [ ] **Scripture collections** — freely licensed Bibles (KJV, ASV, WEB,
  Douay-Rheims), and the default the app opens with.
- [ ] **Onboarding** — first run should guide the choice rather than landing on
  an empty library. Currently the confessional core is still bundled.
- [ ] **Ask-and-install flow** — the coverage notice names a collection and
  links to the library; it should offer the download inline and then answer the
  question that prompted it.
- [ ] Denominational collections for traditions with no content yet (Baptist,
  Pentecostal, Oriental Orthodox) — blocked on the corpus, not the packaging.


---

## Phase 20 — Scripture, bundled (2026-07-22)

The King James Version now ships **inside the app** rather than as a download:
66 books, 1,189 chapters, 31,102 verses, 4.25 M characters. It is the text every
tradition in this library is interpreting, and it is what makes the app useful
on a plane before anything has been fetched.

The bundled corpus is now **Scripture and nothing else** — 3.7 MB. Every
tradition, era and author is a collection the reader chooses.

- [x] Units are **chapters, not verses.** A verse averages 130 characters, too
  small to embed meaningfully or to read as a citation; a chapter averages
  3,600 and chunks like everything else. Verse numbers stay inline so a
  citation remains locatable.
- [x] Counts are **asserted, not reported** — 66/1189/31102. A parser that
  drops a book still produces a plausible Bible, and plausible is the failure
  this corpus keeps having to undo.
- [x] Licence records the real position: public domain in the US, **perpetual
  Crown copyright in the UK**. Shipping it is normal; unencumbered everywhere
  it is not.
- [x] The Library says what is already included, rather than leaving a reader
  to infer it from a missing download button.

### Three parser bugs, each of which produced a plausible Bible

- **Verses do not reliably begin lines.** "…laid down to sleep; 3:4 That the
  LORD called Samuel" — a line-anchored pattern found 24,995 of 31,102 verses
  and folded the missing 6,107 into whichever verse preceded them. Every one
  still readable, every one attributed wrongly.
- **Samuel and Kings share heading text.** Each carries a two-line heading with
  an older name, and "The First Book of the Kings" is *both* the subtitle of 1
  Samuel and the title of 1 Kings. Name alone cannot disambiguate them;
  position can.
- **`Otherwise Called:` sits between those two lines**, which broke the
  positional rule *and* was being swept into the text as scripture.

### Also

macOS builds had stopped working: plugins declare deployment targets of 10.14
and 10.15 and current Xcode refuses anything below 12.0, failing at the Pods
stage with an error naming the pod rather than the cause. Forced in the
Podfile's `post_install`, which covers plugins added later too. CocoaPods also
needs `LANG=en_US.UTF-8` on this machine.

### Next

- [ ] **Onboarding.** First run should guide the choice of collections. The app
  now starts with Scripture alone, so this is what makes it useful.
- [ ] **Ask-and-install.** The coverage notice names a collection and links to
  the library; it should offer the download inline and then answer the question
  that prompted it.
- [ ] More Bibles — ASV, WEB, Douay-Rheims — as downloadable Scripture
  collections alongside the bundled KJV.


---

## Phase 21 — Onboarding and a four-area app (2026-07-22)

The navigation is left over from when the app shipped a full corpus and had no
AI. It has five tabs — Home, Browse, Search, Chat, Bookmarks — where Home is a
statistics dashboard, Chat is buried fourth, and Settings is at the bottom of
Home's quick actions. The Library, which is now the screen a new user most
needs, is three taps deep behind it.

**The four areas.**

1. **Chat** — the primary screen. Asking a question is what the app is for, and
   it should be what opens.
2. **Read** — the installed sources, read like an e-reader. A list of what you
   have, open one, read it. This is where Browse, Search and Bookmarks belong;
   they are three ways into the same act.
3. **Library** — cards for each collection, searchable, with an overview of
   what a pack contains before you spend the storage on it.
4. **Settings** — theme, fonts, AI provider, everything else.

### Done in this phase

- [x] **Onboarding.** First run explains that the Bible is included and offers
  the broad collections. Choices are collected before anything downloads, so
  the total is visible up front rather than discovered one download at a time,
  and the total sums the *union* of fragments — adding advertised collection
  sizes would overstate it, often badly. Skipping is a real option: the app
  works on Scripture alone.
- [x] **Four-tab navigation** — Ask, Read, Library, Settings. Chat was the
  fourth tab behind a statistics dashboard and is now what opens. Browse,
  Search and Bookmarks have collapsed into Read.
- [x] **A reader.** Sections open in sequence with next/previous and a contents
  sheet, honouring the font-size setting. Previously a passage could only be
  opened as an isolated card with no way to continue — wrong for any long work
  and completely wrong for Scripture.
- [x] Verified on the running app: first run → download → four tabs → shelf →
  reading Trent at "1 of 104".

### Release builds fixed — Apple Silicon only

Flutter's framework-unpack step refused the universal `FlutterMacOS` binary
under the macOS 27 / Xcode 26 beta toolchain, reporting that it "does not
contain architectures arm64 x86_64" while `lipo` on that same file listed
exactly those. Debug builds skip the check, which is why only release was
affected and why it went unnoticed for so long.

`ARCHS = arm64` on the Release and Profile configurations sidesteps it.
**Release artefacts no longer run on Intel Macs** — an accepted trade, decided
rather than drifted into. Every framework in the built bundle is now a single
arm64 slice; the app is 70 MB.

**Revisit in September 2025**, when macOS 27 and Xcode 27 ship properly. The
beta is required for testing until then. The check is the bug, not the
universal binary, so restoring Intel support should be a two-line revert once
the toolchain is stable — not a re-architecture.

### Reading, made usable (2026-07-22)

- [x] **Resume where you stopped**, per work rather than globally — someone
  reading Genesis and dipping into Trent should find both where they left them.
- [x] **A contents sheet that scales.** A flat list is fine for forty articles
  and useless for 1,189 chapters: reaching Habakkuk meant scrolling past
  everything before it. Now filterable, and grouped into books with chapter
  chips — 66 rows instead of 1,189, opened at the book you are in.

  The grouping derives from the titles rather than knowing what a Bible is:
  "Genesis 1" and "Genesis 2" share a stem, and so do "Session 4" and "Session
  5". It only groups when that collapses the list by half or more, so a
  catechism of 196 distinct questions stays flat rather than gaining 196
  headings.
- [x] **The shelf is filterable.** With 380 works installed, a reader looking
  for the Bible was scrolling past every apocryphal Acts to reach it — and the
  only search box on the screen searched passage text, not the shelf. Typing
  now filters the shelf; return still searches inside the texts.

### Ask-and-install (2026-07-22)

- [x] The coverage notice downloads the collection **in place**, shows progress,
  and then re-asks the question that prompted it. Sending someone to another
  screen to fix a problem they did not know they had, and expecting them to
  come back and retype the question, was most of a feature.
- [x] The size is on the button, because this is an unsolicited suggestion to
  spend someone's data. The manifest is now fetched at startup — 1.4 KB — since
  otherwise the first time anyone saw the offer was the one time it could not
  quote a price.

**A bug the app itself exposed.** Installing "Augustine of Hippo" and asking
again produced *"You asked about Augustine of Hippo, whose writings are not
installed"* — immediately after the download that was supposed to fix it. The
Catholic collection also lists Augustine among its authors and was still
incomplete, and the check asked whether a *collection* was complete rather than
whether the *author's text* was present. Those are different questions.

Fragments now carry authors and titles, not just tag counts, so the notice can
ask the right one. Verified the regression test fails without the fix before
keeping it: a test that passes either way is worse than none.

### Still to do — recorded so it is not lost

- [ ] **Chat as a real home.** Suggested questions, visible backend state, and
  the coverage notice inline rather than as an afterthought.
- [ ] **A genuine reading experience.** Continuous scroll within a work,
  next/previous chapter, position memory, adjustable type. Today a passage
  opens as an isolated card with no way to keep reading — for Scripture in
  particular that is the wrong shape entirely.
- [x] **Scripture navigation.** Done — see below.
- [ ] **Library cards.** A pack overview worth reading before downloading:
  authors, principal works, date range, what subjects it covers.
- [ ] **Search inside the Read area**, scoped to what is installed, with
  filters by tradition and author.
- [x] **Ask-and-install.** Done — the notice downloads in place and re-answers
  the question on its own.
- [ ] **Bookmarks and reading history** folded into Read rather than owning a
  tab.
- [ ] **Empty states** everywhere: with only Scripture installed, most screens
  need to say what is missing and offer the fix.
- [x] **Reading position memory.** Done — see below.
- [ ] **Trent's OCR needs cleaning.** Page furniture is embedded in the text —
  "1 8 SESSION IV." mid-paragraph — which was invisible while passages were
  only ever seen as search snippets and is obvious when read continuously.


---

## Phase 22 — Aquinas (2026-07-22)

The largest single gain available, and the corpus held none of him: the only
entry under his name was a 1,996-character unsourced abridgement.

**The complete Summa Theologiae** — all five parts, 611 questions, **3,115
articles, 14.1 M characters** — from New Advent's `/summa/`, a section the
existing ingester never walked. Benziger Bros. 1947 translation, public domain.

Units are **articles**, not questions: an article is the atomic argument and
the way Aquinas is cited (ST I, q.1, a.3), so it is both the right retrieval
granularity and the right thing for a citation to name.

- [x] New collections: **Thomas Aquinas** (author) and **Medieval Theology**
  (era), plus folded into **Catholic**.
- [x] The loader now honours an `author` field. Without one a work is invisible
  to entity scoping — "what did Aquinas say about x" cannot be narrowed to his
  writing — and its citations cannot say who wrote it.

### Two things caught by refusing to trust the run

**Three questions were silently dropped.** New Advent's `<title>` is malformed
on any page whose question title contains double quotes: Q120 *"Epikeia"* ships
as `<head><name=""Epikeia" or equity (...)">`, with no title element at all.
608 of 611 parsed, so the run looked like a success. Identity now comes from
the page's `<h1>`, which is well-formed and carries the question number — a
stronger check than the part name, since it confirms the page is the question
that was actually asked for.

**Comparative retrieval broke.** 14 M characters of Catholic material against
0.79 M Lutheran meant "how do Catholics and Lutherans differ on baptism"
returned six Catholic passages and no Lutheran ones. The diversity quota could
not prevent it: it caps how many slots a tradition may take, but when the other
tradition never reaches the candidate pool there is nothing to fill the
remainder with and the backfill hands the slots straight back.

A question naming two traditions is asking for a comparison, so retrieval now
guarantees each named tradition is present, displacing the lowest-ranked
passage from whichever is most over-represented. The test asserts the traditions
**by name** rather than counting them — with the fathers installed, "more than
one" was satisfied by an answer that still had no Lutheran voice in it.

Corpus is **v7**, published. 18 fragments, 45.4 MB; the same collections as
standalone files would be 119.0 MB.


---

## Phase 23 — Apple platform appearance (2026-07-22)

The app was Material 3 on every platform, which on a Mac reads as an Android
app in a Mac window. It used **zero** Cupertino widgets.

### What Liquid Glass can and cannot be here

Flutter draws every pixel through its own engine and never instantiates UIKit
or AppKit views, so an app built with it has no system controls for the OS to
restyle. A SwiftUI app inherits Liquid Glass by linking the new SDK; a Flutter
app inherits nothing. Flutter's own team
[paused this work in June 2025](https://github.com/flutter/flutter/issues/170310)
and is moving Cupertino into standalone packages, so first-party support is
coming — but its ceiling is still "drawn by Flutter".

`GlassSurface` is therefore an approximation, and the two ways it differs are
documented in the file rather than left to be discovered:

* `BackdropFilter` samples only what Flutter painted behind it. The real
  material samples the *window's* backdrop, so on a Mac it picks up the desktop
  and the windows underneath.
* Real glass refracts and casts specular highlights that track the pointer and
  the content moving beneath. Ours are static.

Used for chrome only — which is also where Apple uses it, and never behind body
text, where translucency costs legibility for nothing.

- [x] `GlassSurface` on the navigation bar, with `extendBody` so there is
  something to blur. Without that the bar sits on dead space and the effect is
  a tint with extra steps.
- [x] **Apple typography** — `Typography.material2021(platform:)` resolves to SF
  on Apple and Roboto elsewhere, rather than shipping Roboto to a Mac.
- [x] **Cupertino page transitions** on iOS and macOS: the horizontal push with
  an interactive back-swipe, not Material's vertical fade.
- [x] **Opaque fallback** when the system asks for higher contrast. Flutter
  exposes no "Reduce Transparency" flag, so `highContrast` is the closest
  proxy and a partial one — someone who has enabled Reduce Transparency alone
  still sees glass. Worth revisiting if Flutter surfaces the real setting.
- [x] Glass is Apple-only. On Android and desktop Linux/Windows it would be
  borrowing another platform's visual language.

### Still to do

- [ ] **The widgets themselves are still Material.** Typography, transitions
  and chrome are adapted; `NavigationBar`, `ListTile`, `Card` and the rest are
  not. Proper adoption means Cupertino equivalents on Apple targets, and is the
  larger half of this job.
- [ ] Revisit when Flutter's standalone Cupertino package ships with Liquid
  Glass support, and replace the approximation with whatever it provides.
### The adoption deadline, and why it is already handled

Adoption is not required today: an app may build against the iOS 26 SDK and set
`UIDesignRequiresCompatibility` to keep the legacy appearance. **Xcode 27
ignores that flag**, and Xcode 27 becomes the minimum for App Store submission
around **April 2027**, after which every app renders with Liquid Glass whether
or not it asked to.

For this app that is already true and already tested. We build with **Xcode
27.0 against the 27.0 SDKs**, and the flag is set on neither platform — so the
configuration that becomes mandatory is the one every build this session has
used. It compiles, launches and runs.

**And the flag should stay unset**, for a reason beyond it being ignored:
setting it would make the *system* chrome render legacy while our own chrome
approximates glass, which is the worst available combination. Unset, our
approximation sits beside the real material, which is what it should be judged
against.

What the deadline actually forces is coherence, not compliance. The mechanism
restyles **system controls**, and this app has none — Flutter draws its own
canvas. What becomes glass is everything *around* it: the macOS window chrome
and title bar, the iOS status bar and home indicator, share sheets, pickers,
keyboards. By April 2027 the frame will be glass, and a flat Material interior
will look like a mistake rather than a choice.

That is the same argument for adopting Cupertino properly that already exists
above — with roughly 21 months of runway, and Flutter's standalone Cupertino
package likely to land inside it.
