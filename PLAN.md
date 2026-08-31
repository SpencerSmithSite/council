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

- [x] **The widgets themselves are still Material.** Substantially addressed
  2026-07-22 in Phase 25 (the theme catalogue). Apple targets now get system
  colours, inset-grouped tables in place of stacked cards, hairline separators,
  a tab bar with no Material selection pill, and adaptive controls that render
  the real Cupertino switch, slider and alerts. Verified on the iOS 27 simulator
  in light, dark and Catppuccin. What remains is genuinely optional polish —
  large collapsing navigation titles, a back-chevron-plus-label nav bar, and an
  iPad/macOS sidebar layout — none of which the current screens read as missing.
- [ ] Revisit when Flutter's standalone Cupertino package ships with Liquid
  Glass support, and replace the approximation with whatever it provides.

## Phase 25 — Theme catalogue and Apple-native chrome (2026-07-22)

The app was Material 3 with a purple seed on every platform, which on an iPhone
read as an Android app that happened to run on iOS. Two things changed together:
a theme the user can choose, and a platform look the app commits to.

### The theme model

`AppThemeChoice` — System, Light, Dark, Catppuccin Mocha — is deliberately
*not* one hard-coded scheme per name. The platform-following choices resolve to
the device's own appearance: Apple system colours on iOS and macOS, Fluent on
Windows and Linux, Material 3 baseline on Android. "Light" therefore means "the
standard light look for this device", which is what makes it feel native rather
than themed. Catppuccin Mocha is the one fixed palette, identical everywhere,
because a named community palette is the reason to pick it.

`palette.dart` holds the raw colours behind an `AppPalette`, which pairs a
`ColorScheme` with the two things `ColorScheme` cannot express and Apple needs:
a grouped page background distinct from the cell colour (Apple's
`systemGroupedBackground` vs `secondarySystemGroupedBackground` — grey page,
white cells in light; black page, `#1C1C1E` cells in dark), and a real hairline
separator colour. Getting that pair backwards — white page, grey cells — is the
single commonest way a cross-platform app looks not-quite-iOS.

`app_theme.dart` turns a palette into a `ThemeData` and is where the
Apple-native styling lives, so screens keep using `Card`, `ListTile` and
`Scaffold` and still look native. `InsetGroup` joins settings rows into one
rounded section with text-inset hairlines under a grey uppercase header;
controls are adaptive so the Cupertino switch, slider and alerts appear on
Apple.

### Decisions worth keeping

* **The iOS switch is green, not the accent colour.** That is native: iOS
  switches are system green regardless of tint, including under Catppuccin.
  Matching the platform beats matching the palette here.
* **`extendBody` bit back.** The new accent colours made an old latent bug
  loud: the tab screens paint behind the translucent bar and reserved no bottom
  inset, so an accent-filled button sat permanently under the glass.
  `MediaQuery.padding.bottom` reads zero through the nested Scaffold, so the
  inset is computed from the window via `appleTabBarInset`.
* **Windows/Fluent and Android/Material palettes are built but not visually
  verified** — there is no Windows or Android target to run here. They are plain
  `ColorScheme` mappings and compile; the risk is cosmetic, not structural.
* **Dynamic colour on Android** (reading the wallpaper palette, the truly-native
  step) is deliberately deferred: it needs a platform channel the app does not
  yet have, and Apple was the stated priority.
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

### Choosing a Liquid Glass implementation (2026-07-22)

The requirement was stated precisely: look as native as possible now,
**without** a second codebase, and be able to switch to Flutter's official
solution the moment it ships. Those pull against each other, and the resolution
is not the package choice — it is the seam.

**The seam is the answer.** Every glass surface in the app goes through
`GlassSurface` in `lib/src/theme/glass.dart`, and nothing else imports a glass
package. Replacing the implementation — with Flutter's own, when the standalone
Cupertino package ships support in late 2026 — is a change to one file. The
`GlassBackend` enum makes that explicit rather than merely true: both
implementations are kept compiling, so switching is a constant, and a
performance problem on weak hardware is one edit away from being ruled out.

**Native platform views were rejected**, despite being the only path to real
fidelity. They are `UiKitView` — iOS-specific, requiring a per-platform
fallback for everything else, which is the one thing the whole Flutter decision
exists to avoid. They also have known z-order trouble with modals and sheets,
which this app uses throughout.

**Shader emulation was chosen**: `liquid_glass_widgets`. The research that
prompted this recommended `cupertino_liquid_glass`; pub.dev says 10 likes and
775 downloads, so the recommendation was checked rather than taken.

| package | likes | downloads/30d | last published |
|---|---|---|---|
| `liquid_glass_widgets` | 193 | 37,032 | 5 days ago |
| `liquid_glass_renderer` | 882 | 29,781 | Nov 2025 (stale) |
| `adaptive_platform_ui` | 355 | 9,138 | 3 days ago |
| `cupertino_native` | 340 | 3,745 | Sep 2025 (stale) |
| `cupertino_liquid_glass` | 10 | 775 | — |

**Decided on screen, not on paper.** The first tuning pass produced a nav bar
indistinguishable from the plain `BackdropFilter` — which would have made the
dependency pure cost, and nearly did. The cause was worth writing down: the
package has two rendering paths, and on the Impeller path — which is every
platform we draw glass on — `glowIntensity` is **ignored**, while `ambientRim`
and `whitenStrength`, the two settings that actually produce an edge and a
frost, both default to `0`. Turning down the obvious knob and leaving the
effective ones at zero yields a blur with extra steps. Retuned, the bar has the
Fresnel rim and vibrancy that distinguish glass from blur; verified in both
light and dark mode, with content scrolled under the bar so there was something
to refract.

The general lesson is the one this project keeps relearning: the build passed,
the tests passed, and the feature was doing nothing.

## Phase 24 — Filling empty traditions (2026-07-22)

### The Second London Baptist Confession (1689)

Done. 32 chapters, 160 paragraphs, corpus v8, published as `f-baptist`.
Sourcing and the rejected editions are recorded in `SOURCES.md`; the short
version is that three of four candidate editions were rejected — one for
destroyed OCR, one for being a modern-English paraphrase under live copyright,
one for not existing — and the surviving text is corroborated paragraph by
paragraph against a second edition because its own transcription declares no
base edition.

Verified in the running app, not only in tests: the pack appears in the Library
at 98 KB, installs, and the confession reads correctly from the shelf. That
last step is not ceremony — the Library reads its manifest from the published
GitHub Release, so a pack that is correct in `dist/` and absent from the
release is invisible to every user and to the entire test suite.

### Two gaps this turned up

- [x] **Subject coverage was measured by volume, so a small tradition-defining
  document could never be surfaced by it.** Fixed 2026-07-22 (#35): fragments
  and collections now carry their traditions, and a named tradition with
  nothing installed is offered with no threshold, ranked above subject
  coverage. Aliases are matched ("Presbyterian", "Episcopalian") because
  nobody types the database's label; "Orthodox" is excluded because it is
  more often an adjective. Verified in the app with the pack removed first.
  The original diagnosis follows.

  **Subject coverage is measured by volume.** The confession holds 8 passages
  tagged `baptism`; the fathers hold 1,063. `suggest()` names the collection
  holding the *most* of a tag, so a question about believer's baptism will
  always be answered by offering the fathers. That is correct arithmetic and
  the wrong answer: the reason to install the Baptist pack is not that it is
  large but that without it the tradition is unrepresented. Coverage should
  weigh *whether a named tradition is absent entirely*, not only how many
  passages are missing.

- [x] **Works were matched by their full title verbatim.** "The Second London
  Baptist Confession" omits "of Faith" and so matched nothing — and the same
  held for every anonymous confession in the corpus, which is most of them and
  which have no author to fall back on. Now matched on three consecutive
  significant words, which is specific enough that the existing restraint
  tests all still pass.

### Next in this phase

1. **Wesley's Standard Sermons** — `methodist` holds 16 units. The Wesley
   Center corpus has moved; the archive needs finding before anything else.
2. **A clean Westminster Confession** — still unprovenanced, and now clearly
   tractable: the same corroboration method that worked here applies directly,
   and CCEL's critical apparatus is no longer the only option considered.
3. **Anabaptist, Mennonite, Quaker** — absent entirely. Gutenberg has Penn and
   Woolman with confirmed ids.

`poppler` is now a build-host dependency of the ingest tooling (`brew install
poppler`). Several of the remaining confessions exist only as PDFs.

## Phase 26 — iOS 26 Liquid Glass redesign (2026-07-22)

The Apple build still read as Android-with-Apple-colours: a solid bottom tab
bar, solid app bars, Material text fields. iOS 26's Liquid Glass language moved
chrome *off* the edges — floating translucent controls that hover over
full-bleed content — and this restructures the app to match.

### What changed

* **Navigation is a left drawer**, opened from a floating glass **menu bubble**
  top-left; **settings** is a floating glass **gear** top-right, not a tab. This
  is the requested placement and the iOS convention: primary areas on the left,
  app-level settings top-right.
* **The bottom is a floating glass entry bubble** — `GlassComposer`, a squircle
  capsule inset from the edges. On Ask it is the question composer; on Read it
  is the search field (live filter, return runs full-text search). One widget,
  two uses.
* **Content is full-bleed**, painting under the floating controls, with large
  iOS titles (`LargeTitle`) that scroll away.
* **Icons are SF symbols on Apple** via `AppIcons`, Material elsewhere.
* **Corners are true squircles** — Flutter 3.44's `RoundedSuperellipseBorder`
  and `ClipRSuperellipse`, the real iOS continuous corner, not a circular arc.
* Floating inset is Apple's 18–21pt; tap targets are 44pt.

### The glass decision worth keeping

The floating controls do **not** use the fragment-shader glass. The
`liquid_glass_widgets` shader blurs the *entire screen backdrop* when several of
its surfaces float over a full-content screen — Read came up frosted end to end,
every element behind the bubbles smeared, only the last-painted gear crisp. Ask
had hidden this because its content is empty black, and blurred black is black.

`floatingGlass` uses `BackdropFilter` clipped to each control's shape instead. It
blurs only what is directly beneath the bubble and leaves the rest sharp, which
is what a floating control actually needs. The true material's refraction is
lost; a clean translucent blur that works beats a shader that frosts the screen,
and the user's rule was explicit — never let Apple feel non-native, even if that
means less flash.

### Verified

iOS 27 simulator, dark: Ask, Read, Library and the drawer all render correctly
with the floating chrome, SF icons, large titles, squircle composer and blue
capsule buttons; no full-screen frost. Drawer navigation works by tap and by
left-edge swipe. The light Apple palette was proven in Phase 25 and is unchanged
here — only the chrome layout moved.

### Not done

* The simulator-panel tooling is broken by this host's Xcode-beta (missing
  `SimulatorKit`), and a menu-bar notch utility blocks clicks in the top band,
  so top-bar interactions were driven by edge-swipe and `simctl`. Light-mode
  glass-over-content was reasoned about rather than screenshotted.
* Pushed detail views (source reader, AI backend, bookmarks) keep standard nav
  bars with a back button — correct iOS for a pushed view, and left as is.

## Phase 27 — Theme catalogue (2026-07-23)

Split the single theme setting into the two axes it was really conflating: a
**brightness mode** (System / Light / Dark) and a **named theme**. Every named
theme carries a full light *and* dark palette, so the mode switch always has
somewhere to go — even for schemes that ship dark-only upstream, which get a
tasteful light counterpart built from the same accent.

* `themes.dart` — a `NamedTheme` catalogue of 24 community palettes (Tokyo
  Night, Everforest, Ayu, Catppuccin + Macchiato, Gruvbox, Kanagawa, Nord,
  Matrix, One Dark, Dracula, Solarized dark/light, Monokai, GitHub dark/light,
  Material Palenight, Night Owl, Rosé Pine, Nightfox, Horizon, Cobalt2, Darcula,
  High Contrast). A `_palette()` helper expands a handful of identifying colours
  (bg / surface / text / accent …) into a full `ColorScheme`, so each theme is a
  compact, readable block rather than a hand-filled scheme.
* "Default" stays platform-adaptive (Apple / Fluent / Material) and sits at the
  top of the picker; it isn't in the catalogue because it has no fixed palette.
* Two axes persist independently (`theme_mode` + `theme_id`), replacing the old
  `theme_choice` enum. Migration: `catppuccinMocha` → dark + `catppuccin`; plain
  `light`/`dark` → that mode on Default; the pre-theme `dark_mode` bool still
  maps too.
* Named palettes are the same on every platform but keep the platform *shapes*
  (Apple's grouped glass, Fluent cards) — colour changes, layout doesn't. This
  reuses the existing `_build(palette, family)` path, the same one Catppuccin
  used before.
* Picker screen (`theme_screen.dart`): a segmented mode control over a list of
  themes, each with a **live swatch** rendered in the mode currently selected,
  so the whole list restyles the instant the mode flips.

Verified on the Android emulator: mode toggle and theme selection both restyle
the whole app live; swatches show the correct light/dark variant per theme; the
legacy Catppuccin choice migrated cleanly. 89 tests pass (2 new migration
tests); `flutter analyze` clean.

---

## Phase 28 — Device-test UI fixes (2026-07-23)

Eight issues from a device test pass (`testNotes/Council.pdf`), fixed together
in PR #50.

* **Packs — no Download on already-present collections.** Installed collections
  showed Remove, but a collection whose every fragment was already downloaded
  via another pack still offered a Download that fetched nothing. Now: header
  reads "Already downloaded", no button. (`library_screen.dart`)
* **Packs — App Store download ring.** The linear progress bar is replaced by a
  circular fill-arc around a centre square (`_DownloadRing`) while a pack
  downloads.
* **"Manage content" page fixed.** `LibraryScreen` pushed as a route had a
  transparent scaffold (fell through to black) and no back button. Added an
  `embedded` flag: the tab host stays transparent and lets the shell's chrome
  float over it; the pushed route paints the themed background and floats its
  own back button. `main.dart` passes `embedded: true` for the tab.
* **Settings — Show Citations toggle respects the palette.** The adaptive switch
  is a Cupertino switch on Apple, whose "on" track defaulted to system green;
  pinned to `scheme.primary`.
* **Settings — Apple floating header.** Dropped the solid `AppBar` for the
  full-bleed `LargeTitle` + floating round back `GlassBubble` the primary
  screens use.
* **Read — swipe to pin / bookmark.** Swipe a source right to pin it to a
  Pinned section at the top, left to bookmark it (filled-bookmark glyph via a
  `Dismissible` that springs back rather than dismissing). New
  `ReadShelfService` persists pinned + saved source ids and collapsed
  traditions in SharedPreferences.
* **Read — collapsible tradition sections.** Each tradition header is a
  disclosure row with a count and a rotating chevron; collapsed state persists.
* **Ollama — Test button + model dropdown.** "Test connection" verifies the
  host and pulls its model list, then swaps the free-text model field for a
  dropdown of the models actually installed on that host. (`ai_backend_screen`,
  reusing `OllamaService.getModels`.)

Verified end-to-end on the Android emulator (already-downloaded packs show no
button; the download ring renders; Manage-content has a themed background and
back button; Settings uses the floating header with an accent citations toggle;
Read pin/bookmark swipes and section collapse all work and persist; the Ollama
Test button populated a 17-model dropdown from a live host at `10.0.2.2:11434`).
89 tests pass; `flutter analyze` clean.

---

## Phase 29 — Sub-page consistency and cross-platform parity (2026-07-24)

Follow-ups after checking the Phase 28 work on every platform.

* **Read "bookmark" → "star" (PR #52).** The source-level swipe favourite was
  labelled "Bookmark", colliding with the passage-level Bookmarks reached from
  the header. Renamed to **Star** (Star / Unstar, filled-star glyph, stored as
  `shelf_starred_sources`) so a whole-work favourite and a single-passage
  bookmark are never confused.
* **Theme and AI Backend pages got the Apple floating header (PR #53).** Both
  Settings sub-pages still opened under a solid `AppBar`. Converted to the
  full-bleed `LargeTitle` + floating back `GlassBubble`, and laid the Theme
  page's mode control and theme list out as grouped `InsetGroup` sections so it
  matches the Settings screen it is launched from.
* **InsetGroup ink fix (PR #54).** Grouped sections paint an opaque fill over
  the Scaffold's Material, so row ripples had no Material to render on (Flutter
  logged "ListTile … ink splashes may be invisible"). Wrapped each section's
  column in a transparent Material.

All of the above (and every Phase 28 change) live in shared Dart code — there
is no per-platform branching that would leave one platform behind; the iOS and
macOS apps only looked stale because they were running builds from before the
work. Rebuilt and verified on **all three platforms**: macOS (Settings floating
header + accent citations toggle, new grouped Theme page), iOS (collapsible Read
sections, the star glyph after a swipe), and Android (Settings + Theme pages,
star, and all eight Phase 28 fixes). The ink-splash warning is gone on all
three. 89 tests pass; `flutter analyze` clean.

---

## Phase 30 — Second device-test round (2026-07-24)

Five issues from another test pass (`testNotes/Council.pdf`), shipped in PR #56.

* **Read auto-refreshes on library changes.** The shelf was loaded once at
  init, so a freshly downloaded source only showed after a manual
  pull-to-refresh. `ReadScreen` now listens to `PackProvider` and reloads when
  the *installed set* changes (not on the many progress ticks a download fires).
* **Read collapse-all / expand-all.** A header button collapses every tradition
  section at once and flips to expand-all when all are collapsed;
  `ReadShelfService.setCollapsed` persists it.
* **AI Backend — removed** the "Coming: on-device models" card, **fixed the
  cramped layout** (option cards' borders were touching; added consistent
  spacing), and **stopped the cloud-provider selector wrapping "ChatGPT"** onto
  two lines (dropped the selected-segment checkmark, one-line labels sized to
  fit four across).
* **Onboarding rebuilt as three swipeable steps** — Scripture (KJV installed +
  the other PD translations), Build-your-library (Creeds & Confessions badged
  "Start here"), and the AI backend (search-only default, Ollama / API-key
  options that open the full setup). Page-indicator dots, Back / Next / Skip,
  "Get started" on the last step, swipe between steps.
* **"Show Onboarding"** added beside "Reset All Settings" to re-run the
  walkthrough; it pushes the flow and pops back on finish. First-run display was
  already gated on `hasOnboarded`.

Verified on the Android emulator (all three onboarding steps, the Start-here
badge, the AI choice persisting to Settings, the AI-Backend spacing +
single-line provider labels + removed box, the collapse/expand toggle, and — the
reported bug — the ASV appearing in Read the instant it finished downloading,
with no refresh). Onboarding + Settings also re-verified on macOS; iOS rebuilt
from the same shared code. 89 tests pass; `flutter analyze` clean.

---

## Phase 31 — Animated logo loading screen (2026-07-24)

A loading indicator built from the app's own mark rather than a generic
spinner (PR #58).

* **`BrandLoader`** (`lib/src/widgets/brand_loader.dart`) animates the logo with
  three quiet motions off one `AnimationController`: a breathing scale, a glow
  that swells with it, and a band of light that sweeps across the tile like
  light on an open page. A `ShaderMask` (srcATop) keeps the highlight inside the
  rounded corners. Cheap enough for a cold-start splash on a slow device.
* **`BrandSplash`** wraps it on the logo's indigo with a "Council / Preparing
  your library…" caption. `main()` now `runApp`s a `_CouncilBootstrap` that
  paints this first frame immediately and runs the heavy startup (DB decompress,
  ~20 MB embedding model, `loadInstalled`) inside a `FutureBuilder`, swapping to
  the real app when it resolves. No minimum splash time — a fast boot barely
  flashes it. A `_BootstrapError` view covers a startup that throws.
* The onboarding **"Downloading …"** view uses the same `BrandLoader` in place
  of the old `CircularProgressIndicator`.

Gotcha: text in a bare widget under `MaterialApp.home` renders in Flutter's
yellow-underlined debug style — `BrandSplash` needs a `Scaffold`/`Material`
ancestor (and `decoration: TextDecoration.none`) for the caption to paint
cleanly.

Verified on the Android emulator (splash steady with a temporary boot delay,
since removed): the mark animates on indigo, the light-sweep visibly moves
between frames, and the Downloading view shows the same mark on the themed
background. Both Apple builds boot cleanly through the new bootstrap path. 89
tests pass; `flutter analyze` clean.

---

## Phase 32 — Contents pages ingested as the works themselves (2026-07-26)

Reported from the app: the Ecumenical Councils section holds summaries and not
the canons; the City of God is a summary; so are *Christian Doctrine*, the
*Confessions*, Augustine's letters and Basil's letters. Every one of those was
true, and they had three unrelated causes.

### The cause that hid the longest

New Advent gives a long work a contents page. `1201.htm` is not the City of God
— it is Augustine's argument for each of its 22 books, with links to
`120101`…`120122` where the text lives. The ingester already knew about
multi-part works, and its test for one was:

```python
def is_hub(work, body):
    """A hub has no text of its own but links to three or more parts."""
    return parse_work(work, body) is None and len(sub_links(body)) >= 3
```

That first clause is the bug. A contents page **does** have text of its own —
several thousand well-formed characters of it, genuinely written by Augustine —
so `parse_work` returned a record, `is_hub` said no, and the work was ingested
as the contents page. It then looked correct from every angle that gets
checked: right title, right author, right source URL, right translator, real
prose, provenance `primary_text`. It was only wrong by **length**, and nothing
measured length.

Eighteen works were affected, and not marginal ones:

| work | was | now |
|---|---:|---:|
| City of God | 3 units, 8 K | 665 units, 2.36 M |
| Basil, Letters | 1 unit, 3 K | 323 units, 0.84 M |
| Confessions | 2 units, 4 K | 276 units, 0.63 M |

The fix is one clause: the links decide alone, and `parse_multipart` then takes
the text from the parts and discards the hub body. Restricting the link scan to
ids that extend the work's own (`1201` owns `120101`) also dropped 20 stray
cross-references that a bare count would have miscounted.

### Three more, found by counting what was thrown away

Fixing `is_hub` made the parts readable, and reading them exposed three further
losses. All three were pre-existing; none had ever produced an error. Each was
found the same way — not by inspecting output, but by asking, for every page,
*what did this drop and why*.

**1. Short letters were being discarded.** 111 of Basil's 325 letters parsed to
nothing. `MIN_WORK_CHARS = 1200`, the floor that rejects a page too short to be
a work, was being applied to each *part*. Basil's letter 13 is 193 characters:

> To Olympius. As all the fruits of the season come to us in their proper time,
> flowers in spring, grain in summer, and apples in autumn, so the fruit for
> winter is talk.

A part is not a candidate hub — its parent already answered that — so the only
thing the floor has to reject there is navigation chrome, which strips to
nothing. It is 80 characters for parts now. This was not introduced by the hub
fix: Cyprian's Epistles had been a recognised hub all along, quietly losing
four of its 82 letters since the first ingest.

**2. Works in exactly two books were absent from the corpus entirely.** The hub
threshold was three parts. A two-book work was therefore not a hub, and its
contents page was too short to survive the length floor as a flat work, so it
fell between the two paths and was never ingested at all — not summarised,
*missing*. Ten works went that way: Tertullian's *Ad Nationes*, Augustine's
*Soliloquies*, *Our Lord's Sermon on the Mount*, *On the Grace of Christ*,
*The Predestination of the Saints*, Jerome *Against Jovinianus*, Ambrose *On
Repentance* and *On the Death of Satyrus*, Athanasius' *Apologia Contra
Arianos*, and Sulpitius Severus' *Sacred History*. Two is safe as a threshold
now that the link scan only counts a page's own children.

**3. Parts are not always numbered.** Most works number them (`3202` →
`3202001`); some letter them. Gregory Nazianzen's letters are `3103a`, `3103b`,
`3103c`, and Ephraim's *Nisibene Hymns* and the *Gospel of Nicodemus* the same.
A pattern matching digits saw no parts on those pages, and their contents pages
are a few hundred characters, so they failed the length floor too and were
likewise absent rather than short.

With the hub check finally doing its own job, `MIN_WORK_CHARS` was doing only
its own — and 1,200 was too high for that. The surviving fragment of Quadratus,
the earliest Christian apology there is, is 853 characters and was being
dropped. At 500 that one work is admitted and nothing else in the manifest
moves. **Every work in the New Advent manifest now parses to text.**

### Two audits, because one was not enough

`tools/audit_completeness.py` is new. Its first check is statistical: a contents
page is a run of headings, so it carries a structural marker every hundred
characters or so and few sentence-ending periods, while prose does the reverse.
Measured across the corpus the two populations do not overlap — flagged sources
run 3 to 96 markers per 1,000 characters and the next unflagged source is at
2.3. Conciliar acts are the case that makes a naive threshold wrong: Laodicea
is 71 "Canon N" markers in 33 KB, but each canon is followed by real prose, so
its sentence density is normal. Both bounds are needed.

A ratio test — markers outpacing sentences — was written first, read better,
and **silently missed the City of God, the Confessions and the Harmony of the
Gospels**, whose contents pages summarise each book in a sentence or two and so
keep an ordinary sentence rate. It is recorded in the module docstring as what
the tool deliberately does not do.

The second check is not a heuristic at all. For New Advent works the cached hub
page says how many parts the work has, so "22 parts, 3 units stored" is a fact
rather than a judgement. It catches the four the punctuation signal misses —
including *Christian Doctrine*, whose contents page describes each book in a
full sentence and scores 0.62.

### The audit that was supposed to catch this had gone blind

`audit_corpus.py` is the tool that separates generated filler from real text,
and it was reporting **59% of the corpus as "unknown" and 220 of 415 sources as
holding no confidently-primary text** — Chrysostom's homilies on Matthew,
Augustine's sermons, Cyprian's epistles. A tool that flags everything is a tool
nobody reads, which is part of why the contents pages sat there.

The cause is one character class. `normalized_title_tokens` matched `[a-z]+`,
so it stripped the numbers — and "Homily 12" and "Homily 13" became the same
token set, i.e. word-shuffles of each other. That single signal fired 17,469
times. The generator's shuffles were of *words* ("On the Creed That Is the
Nicene" against "On the Nicene That the Creed Professes"), so keeping digits
costs it nothing, and a one-token title now cannot fire it at all: "Preface"
twice in a work is a fact about the work.

| | before | after |
|---|---:|---:|
| classified primary_text | 36.4% | **89.9%** |
| sources with no primary text | 220 of 415 | **6 of 415** |

Four of the remaining six are the contents pages this phase is about. The other
two are heuristic edge cases in a dialogue and a liturgical list, and are left
flagged rather than tuned away.

### The second cause: eight sources that were two works each

`prune_unprovenanced.py` had left eight sources standing on the reading that
their wording was genuine but abridged. Reading their unit titles *in order*
shows it is not. Each is two unrelated works interleaved, odd positions from
one and even from the other:

    Philokalia Selections   Slough of Despond · Watchfulness · The Cross and
                            the Burden · The Jesus Prayer · Vanity Fair ·
                            Dispassion · The Celestial City · Theosis

Half of that is *Pilgrim's Progress*. Under Wesley's name sit the Didache's Two
Ways and the arrest, trial and burning of Polycarp. Under Gregory of Nyssa sit
three sections of *Nostra Aetate* — Vatican II, 1965, in copyright. Under
Teresa of Ávila sit the inward, outward and corporate disciplines of Richard
Foster's *Celebration of Discipline*, 1978, also in copyright.

All eight removed. **Every source in the corpus now has a `source_url`**, which
is the first time that has been true.

The Seven Ecumenical Councils was the one happy case: superseded rather than
merely deleted. Its seven paragraphs of summary are replaced by acts already in
the corpus — creeds, canons and synodal letters running to 503 K characters
across the seven — and the deletion is gated on all seven being present, so a
rename upstream fails loudly instead of leaving those councils with nothing.

### The third cause: a confession that was never there

The corpus had the Second London Baptist Confession (1689) and not the First
(1644), which reads as though Baptists began in 1689.

`tools/ingest_first_london.py` adds it: 53 articles from reformedreader.org's
transcription of the first edition, corroborated against Underhill's *Confessions
of Faith* (Hanserd Knollys Society, 1854) on archive.org.

**What that corroboration is worth is stated rather than implied.** Underhill
prints the 1646 second impression, "corrected and enlarged", so it is not a
second transcription of the same words and a word-identity check against it
would mean nothing — article I was rewritten wholesale between the two. What it
does settle is every way a confessional text found on the open web actually
goes wrong: it fixes the article count and order, proves this is the whole
document rather than an abridgement, and its 17th-century vocabulary proves the
text has not been quietly modernised into a paraphrase. Median vocabulary
overlap is 93%, lowest 71%; the gate is set to what that supports and no
higher.

Two numbering defects are asserted rather than tolerated: the 1644 printing
sets the 36th article as XXVI and the last as LII when the preceding article is
already LII. Both are in Underhill. A page that has been silently re-edited now
fails the ingester instead of shipping.

### A loader that does not churn what it does not fix

`build_corpus.py` only appends — running it twice inserts every work again.
`tools/refresh_newadvent.py` matches on `source_url` and replaces only works
whose parsed units actually differ. That is not an optimisation. Replacing
units means new `content_units.id` values, and the app's highlights and notes
live in a separate database keyed on exactly those ids, so rewriting all 400
works to fix 18 would silently detach every annotation a reader has made on the
other 382. It also refuses to replace a work that parses *shorter* than what is
stored, since a half-failed fetch must not overwrite good text for being newer.

### Result

| | before | after |
|---|---:|---:|
| sources | 439 | 446 |
| content units | 28,520 | 36,917 |
| characters | 99.2 M | **123.7 M** |
| chunks | 92,697 | 115,409 |
| sources with no `source_url` | 8 | **0** |
| sources holding a contents page | 14 | **0** |
| New Advent works missing entirely | 14 | **0** |
| `audit_corpus` primary_text | 36.4% | **87.3%** |

The 24.5 M characters gained are almost entirely from works the app already
listed. It was not short of texts; it was short of their contents.

### What is tracked now

`TODO.md` was two months stale and claimed figures that no longer described the
app. It is now the corpus ledger — have, don't have, should have, and a
**shouldn't have** table naming every removal and what it actually was, so none
of it comes back. Three audits are named at the top of it and are meant to be
run before and after any corpus change.

---

## Phase 33 — Packs publishable without an app release (2026-07-26)

Phase 32 produced 24.5 M characters of corrections and then could not deliver
them: the app refused any catalogue whose `corpusVersion` differed from its
own, so every reader on the previous build would have been told

> This content was built for a different version of the app.

until they updated. Raised as: *"we can't update the packs without pushing an
app update? If we push changes to the packs, the app should just point to the
new packs."*

### The gate was testing the wrong thing

Fragments merge by raw row id — `INSERT INTO content_units SELECT * FROM
pack.content_units`, no renumbering — which is what keeps install cheap, since
chunk ids are derived from unit ids and embeddings are keyed on chunk ids. The
requirement that creates is that ids be **disjoint**. The version check enforced
something stronger and easier: that the pack and the app came from *the same
build*.

Those coincide only by accident. Checking the two builds directly:

| | v12 | v13 |
|---|---:|---:|
| KJV core unit ids | 23558–24746 | **23558–24746** |
| max unit id | 33453 | 42757 |

The core did not move and everything new was appended above the old maximum. v13
was installable into a v12 app the whole time; the gate refused it anyway.

### Three changes

**1. Packs are gated on `idSpace`, not `corpusVersion`.** `corpusVersion` keeps
its real job — it governs the database bundled *inside the binary*, which can
only change with a release. `idSpace` is a separate number that advances only
when a rebuild reassigns an id that is already in the field.

**2. `build_packs.py` proves the build appended.** `check_id_space` keeps a
ledger of what was last published — per source, the id range its units occupy
and a hash of their text — and compares. Three faults, each named rather than
collapsed into a bump:

- `moved` — a source kept its text and changed its ids
- `rewritten` — a source kept its ids and changed its text
- `occupied` — new content landed on ids the previous build had handed out

`occupied` is the dangerous one: the reader keeps the old text under an id the
new pack expects to insert, and the merge fails on a primary-key collision
partway through. Ids *freed* and left fallow are fine, which matters because
that is exactly the shape of Phase 32 — 23 works were re-ingested into fresh
ids above the mark and their old ids abandoned.

Verified against all six cases (three faults, plus append-only, a removed
source, and Phase 32's own shape) rather than reasoned about.

**3. A republished fragment replaces the installed one.** This is the half that
actually delivers an update, and without it relaxing the gate would have been
worse than useless. `install()` skipped any fragment already present, keyed on
id — so a reader holding `f-augustine` would have been told they were up to
date and kept the City of God summary for ever. Fragments now record the
checksum they were installed from, and a catalogue offering a different one
triggers a rebuild: `_retire` tears the old rows down and the new file merges
over. Teardown happens only *after* the replacement has downloaded, verified
and unpacked, so a failed update leaves the reader with what they had rather
than with nothing.

### What is still coupled, and honestly

- The bundled core ships inside the binary. Core content changes always need a
  release. Today the core is the KJV alone, so this rarely binds.
- **v13 itself still ships together with the app.** Apps already in TestFlight
  are running the old equality check and cannot be talked out of it. The
  decoupling applies from the *next* corpus build onward — that is the nature
  of the fix, and it is worth saying rather than implying otherwise.

`build_packs.py` now ends by saying which case a build is in, so this is not
something to reason out at publish time.

---

## Phase 34 — The Reformation, and an Orthodox tradition that exists (2026-07-26)

Two gaps, closed together because they are the same gap seen from two sides:
the corpus was a patristic library with a confessional appendix. 402 of its 446
sources were early-church; Reformed had seven, Baptist two, Anglican one, and
Eastern Orthodox none at all. A question about assurance or the atonement could
be answered out of Augustine and Chrysostom without a single voice from the
tradition that spent four centuries arguing about them.

### Eastern Orthodox — from zero to a tradition

`tools/ingest_orthodox.py`. Three primary texts, each chosen because it has an
unambiguously public-domain English translation, not because it was the first
thing found:

- **The Longer Catechism** (Philaret of Moscow, 1830; Blackmore's 1845 English
  as reprinted in Schaff) — 611 numbered questions on faith, hope and love.
- **The Confession of Dositheus** (Synod of Jerusalem, 1672; Robertson, 1899) —
  the Orthodox answer to Cyril Lucaris, and the nearest thing Orthodoxy has to
  a post-schism conciliar symbol.
- **The Book of Needs** (the *Trebnik*; Shann, 1894) — baptism, chrismation,
  confession, marriage, unction and burial. A catechism says what a tradition
  believes; a service book shows what it does, and for Orthodoxy most of the
  theology lives in the second.

Each web transcription is gated against a scan of the printing it claims to
reproduce — Blackmore's 1845 Aberdeen edition and Robertson's 1899 volume, both
pinned by archive.org identifier. The scans are OCR and unusable as text; the
Robertson volume is bilingual and its OCR confuses Greek and Latin scripts
outright. That is fine for the question actually being asked, which is whether
this is the same document, at full length, in its own century's English. The
check is word-*pair* containment rather than word containment, because
single-word overlap passes on any two texts of the same period and subject.
Philaret scores a median of 95%, Dositheus 87%.

**What the gates caught.** Every one of these was a defect that would have
shipped looking correct:

- A length floor on answers silently dropped 93 of Philaret's 610 questions,
  because a catechism answers many questions in a single clause.
- Three genuine holes in the Philaret transcription — question 288 absent
  outright, 126 and 150 printed with empty answers. Asserted as an exact set,
  so a page that has been re-edited in *either* direction now fails here.
- The last unit of each work absorbing its page footer: Philaret ending with a
  citation of itself, Dositheus with the host site's navigation menu. The
  corroboration gate does not catch this — a few hundred characters of
  navigation on a long unit still scores well — so the boundaries are explicit.
- Gutenberg's CRLF line endings, which made every blank-line paragraph split
  fail and produced 28 correctly-detected chapters with no text under any of
  them.

`TODO.md` was also wrong and is corrected: it named Kadloubovsky's Philokalia
extracts as the public-domain route. That translation is Faber, **1951**, and
in copyright exactly like the Palmer/Sherrard/Ware one it was offered as an
alternative to. There is no public-domain English Philokalia.

### Reformation and post-Reformation — CCEL

`tools/survey_ccel.py` then `tools/ingest_reformation.py`.

The acquisition list is *derived*, not remembered: `survey_ccel.py` walks
CCEL's own author index pages, and every title, author, translator and rights
line comes out of the work's own export header. The only judgements in the
ingester are which works to take and which tradition and genre each belongs to.
That distinction matters, because the two things most easily got wrong from
memory — who translated a work and whether it is public domain — are exactly
the two the header states outright.

**Units are cut on CCEL's own structure.** Not with a heading regex per work;
there are two hundred works here and their headings agree on nothing. Every
CCEL export is divided by a rule of underscores, and that rule is a real
boundary in all of them — it separates each of Spurgeon's sermons, each chapter
of the *Institutes*, each chapter of Matthew Henry, each section of Edwards. So
the rule is the backbone and a classifier sorts the segments into headings,
footnote blocks and body text.

Three things that had to be learned by looking rather than assumed:

- **Titles are recognised by layout, not by case.** An all-capitals test finds
  the chapter marks in Calvin and Henry and misses every one of Spurgeon's
  sermon titles, which are set in ordinary mixed case — leaving nine hundred
  sermons named after the volume they came from. What actually marks a heading
  is a short block standing alone between blank lines that does not end like a
  sentence.
- **CCEL's `Creator(s)` field is not one name per person.** `Calvin, John
  (1509-1564) (Alternative) (Translator)` is one man with role markers, not two
  people; reading the roles naively made Calvin his own translator and filed
  forty-five commentary volumes with no author at all.
- **Most exports have no `Rights:` line.** See below.

### Public domain where the archive does not say

The rights gate is the one place this phase had to decide something rather than
read it. CCEL states `Rights: Public Domain` for some works and says nothing at
all for most. Refusing everything unstated would drop Spurgeon, Owen, Edwards
and Bunyan; accepting everything unstated is how in-copyright text gets a
public-domain label, which this corpus has already had to be cleaned of once.

Two bases, in order of strength, and every source records which one it rests
on:

1. **CCEL states public domain.** Taken at face value.
2. **Publication date.** The work is in the author's own English — so no
   translator's copyright can attach — and the author died before 1929. This is
   the same reasoning `ingest_gutenberg.py` already records for the Book of
   Concord.

A declared modern print basis refuses the work under (2) but not under (1).
Owen died in 1683, but CCEL sets his *Mortification of Sin* from a Banner of
Truth printing of 1967, and a modern edition can carry modern editorial matter;
with nothing but an inference to go on, that is not something to reason past.
Calvin's commentaries are set from a Baker printing of 1996 and are ingested
anyway, because CCEL affirmatively states public domain — the printing is a
photographic reissue of the Calvin Translation Society's Victorian edition, and
second-guessing the archive that cleared it, on the strength of a date the
archive can see too, is not caution but noise.

The works this refuses are listed by name and reason in `SOURCES.md`. Luther's
*Bondage of the Will* is the notable loss: CCEL credits no translator and
states no rights, and a translation of unknown date is not something to guess
at.

### Delivery

The Reformed fragment would otherwise have become a single hundred-megabyte
download holding everything from Calvin on Genesis to a Puritan tract. Ten
author fragments were split out ahead of the tradition fragments — Calvin,
Henry, Spurgeon, Owen, Edwards, Luther, Bunyan, Barnes, Baxter, Hodge — exactly
as `f-augustine` already sits ahead of `f-fathers-rest`, with matching author
collections so a reader can take Calvin without taking the Puritans.

### What 3.7× exposed

Three defects that were latent at 123 M characters and load-bearing at 453 M.
None was found by reasoning about the change; all three came out of the
integration suite, which went from 4 minutes 57 seconds to 5 seconds.

**Search became unusable on scoped questions.** `ftsMatchQuery` made every term
a prefix match, so a question phrased as a sentence handed FTS5 `the*`,
`did*` and `about*` — each matching a large fraction of the index — and asked
it to rank all of that to return six passages. Unscoped questions merely got
slow. Scoped ones fell off a cliff: when the filter admits one source in 638,
the scan runs a long way down the ranking before it finds anything, and "What
did the Council of Trent decree about justification?" went from about a second
to over thirty. Dropping stopwords from the match brings it to 319 ms and costs
nothing in precision, because no passage was ever worth returning on the
strength of containing "about".

The general lesson, recorded because it will recur: **a prefix match is a
scan**, and its cost scales with the corpus while its value does not.

**Loading the vector index blocked every other query.** `VectorIndex.load`
issued one query for all 429,516 embeddings. sqflite marshals the whole result
set across the platform channel before the first row is read, and it runs every
database operation through a single queue — so for as long as that call ran,
nothing else in the app could touch the database. Now paged, with keyset
pagination rather than OFFSET.

Worth stating precisely, because it points at the real fix: SQLite reads those
same 165 MB in **0.28 seconds**. The remaining cost is per-row marshalling, and
the way to remove it rather than spread it is to stop having 429,516 rows —
store the vectors as a handful of contiguous blocks written at build time. The
index does not need to be sorted, only paired, so blocks can arrive in any
order and per-fragment blocks would merge without renumbering. Not done here;
paging was enough to stop it blocking.

**The first download tripled in size without anyone touching it.**
"Creeds & Confessions" references the tradition fragments, and those had
quietly become the Puritan shelf — Manton's 18.1 M characters among them —
taking the essentials pack from 4.3 MB to 31.5 MB. Ten more author fragments
were split out ahead of the tradition ones and it is back to 8.5 MB.

This is a property of the fragment design worth watching: a collection defined
by *which fragments it references* inherits whatever those fragments later
accumulate. Adding an author to a tradition silently enlarges every collection
that names that tradition's fragment.

### Delivery, and a ranking change it forced

Two genres were added to `source_types`, which had held the same eight since
the corpus was creeds and Fathers: **Commentary** and **Liturgy**. Filing
Calvin on Genesis as a "Treatise", or the Orthodox rite of baptism as one, is a
small lie that shows up in every citation of it. `load_ccel.py` creates genre
rows on demand; `traditions` deliberately keeps its hard lookup, because a
typo'd genre is a wrong label while a typo'd tradition silently invents a new
branch of Christianity.

Per-author collections then broke a suggestion rule that had been right up to
that point. Asked "What do Baptists believe about baptism?" with nothing
Baptist installed, the app offered **John Bunyan** — Baptist, two works, and so
the winner under "the narrowest pack that fixes it", which is the correct rule
for a question naming an author or a work. It is the wrong rule here: the gap
reported is not "you lack a Baptist author" but "you lack the Baptist
tradition", and Bunyan's allegories are not the confessions. Inverting to
breadth overshoots to "Creeds & Confessions", which holds Baptist material
among six other traditions and is not what was asked about either. What
actually identifies the right answer is that the collection covers *one*
tradition and is the fullest such — so that is what the sort now does when, and
only when, the reason is `traditionAbsent`.

---

## Phase 35 — Owen, the Treasury, and 30 M characters of link tables (2026-07-27)

Phase 34 ended with a refusal table. Two rows of it were large enough to be worth
going back for: all 31 works of John Owen, and all six volumes of Spurgeon's
*Treasury of David*. Both are now in, and neither came in by relaxing a gate.

### Owen: answering a rights question with evidence instead of a date

CCEL's Owen carries no rights statement and names a Banner of Truth printing of
1965-68. `ingest_reformation.py` refused all 31, correctly: a header cannot tell
a *new* edition from a *reprint* of an old one, and guessing wrong puts
in-copyright text in the corpus under a public-domain label.

But the question is answerable, just not from the header. Banner of Truth's Owen
is a facsimile of William H. Goold's edition of 1850-55, which is on archive.org
as page scans. So `ingest_owen.py` measures rather than reasons: it scores the
text CCEL transcribed against the OCR of Goold's volumes and admits a work only
where the match says the two are the same document.

The measure is word-pair containment, the primitive `ingest_orthodox.py` already
used. What makes it trustworthy here is not the absolute number but the spread
between the cases that could be confused:

| | containment |
|---|---:|
| Owen, *Death of Death* vs the volume that contains it | 92.0% |
| Owen, *Mortification of Sin* — same author, same idiom, wrong volume | 43.7% |
| Calvin, *Institutes* — unrelated Reformed treatise | 18.2% |

Fifty points between a true match and the hardest near-miss available. All 31
works cleared it, 87-98%. Three that no single volume holds — the collected
sermons, *Pneumatologia*, the *Inquiry into Evangelical Churches* — are admitted
on a whole-edition score against a *higher* bar (90%), because scoring against
sixteen volumes at once is a much easier test to pass and the fallback must not
become a way in for what the sharp test rejected. The run re-measures Calvin
against the assembled witness every time, and aborts if the control ever climbs
into the range where the measure has stopped discriminating.

**The pinning bug worth remembering.** The first run refused *Vindiciæ
Evangelicæ* and the Grotius review as uncorroborated. They were not:
archive.org's `volume` metadata is unreliable, the scans numbered straight
through Goold's twenty-four volumes put a Hebrews volume where Works vol. 12
should be, and the two works had no witness to match against at all. A missing
witness read as a fact about the text. The fix was to verify each pin against
the volume's own contents page, and — more durably — to make `parse` report the
volume each work matched, so a bad pin shows up as a work with no home rather
than as a rights problem.

### The Treasury: a text problem, not a rights one

Spurgeon died in 1892; nothing about the Treasury's copyright is in doubt. CCEL
simply serves it as page images. The text therefore comes from Ted Hildebrandt's
2007 digitisation for Gordon College — a real text layer, not OCR — with all 150
psalms corroborated against archive.org's scans of the Victorian printings at a
median of 97%, lowest 91%.

Two sources were considered and rejected, and the reasons are worth keeping:

- **sacred-texts.com** has the whole work in clean per-psalm HTML. Its
  robots.txt sets `Content-Signal: ai-train=no, use=reference`, which is an
  express reservation against exactly this use, and the site is behind a
  challenge that would have to be worked around to read at all. Either alone is
  disqualifying.
- **An anonymous HTML transcription on archive.org** is complete in structure
  and not in content: missing psalms 4, 10, 11, 17-20, 22-24 and the whole of
  119 — 139 of 150, absent the two psalms most likely to be looked up.

The units follow Spurgeon's own divisions. Psalms are attributed to pages by
**running head** rather than by heading, because the headings are not uniform:
psalm 119 is a volume of the original in its own right, opens with a preface
instead of the usual navigation block, and runs to 172 sub-sections under a
different vocabulary. Keying on headings loses the longest psalm in the Psalter.

**The same class of pinning bug, caught by the same reporting.** Psalms 53-57
scored 52-62% and were refused. The cause was that the printings *do not divide
the work the same way* — the 1882 second volume stops at psalm 52 while the 1881
third starts at 58 — so pinning one of each left five psalms in no volume at all.
Numbering the pins by volume is what made a hole in the witness look like a fact
about the text, so the pins are now a flat list of identifiers, deliberately
overlapping. Overlap is free here: each psalm takes its *best* scan rather than a
union, so an extra witness can only close a gap, never make the measure more
permissive.

### What the corroboration work exposed

Going after two refused works surfaced a defect in the text that was already
shipping, and it was larger than either of them.

- **3,438 units — about 30 M characters — were CCEL's reference apparatus.**
  Every export ends with a colophon and a numbered list resolving each hyperlink
  to a `file:///ccel/...` path. All 3,438 were over half link text; the worst
  were 95%. They passed every gate because a page of link targets is long enough
  to satisfy a floor expressed in characters. `clean()` now drops paragraphs
  that are majority URL, judged by proportion rather than presence — a sentence
  that cites a URL is still a sentence.
- **Front-matter skipping was discarding whole works.** It took the *last*
  match inside a twelve-segment window, and `INDEXES?` was in the front-matter
  pattern despite being back matter. In a short work the closing indexes fall
  inside that window, so the skip jumped past the entire body: twelve works were
  lost outright as stubs, and five of Charnock's regeneration discourses shipped
  at about an eighth of their real length. Owen's *Review of Grotius* was the
  diagnostic case — it was ingested as five units of the index's link table, and
  scored 11.9% against Goold because what was being measured was not Owen.
  Front matter is now a contiguous *prefix*, and the index patterns are gone
  from it because `BACK_MATTER` already had them.

The general lesson is the one the corpus keeps re-learning from a new angle:
**every floor here is expressed in characters, and apparatus has characters.**
The gates that work are the ones that measure a *ratio* — placeholders per
thousand characters, lowercase share, URL share — because those distinguish text
from things that merely occupy the space text would.

The corroboration passes did not find these defects by looking for them. They
found them because a work that is silently not itself cannot match a scan of
itself, which is a property worth having on purpose.

---

# Forward-looking plans (not yet scheduled)

The sections below are design decisions and backlog, not dated phase logs. They
record where the architecture is headed so the reasoning isn't lost between
sessions.

## Android — FTS5 missing from platform SQLite (RESOLVED 2026-07-23)

**Fixed and verified on the Pixel emulator the same day.** Added
`sqflite_common_ffi` + `sqlite3_flutter_libs`, set
`databaseFactory = databaseFactoryFfi` in `main()` before any DB opens, and
switched `DatabaseService.initialize()` off `getDatabasesPath()` to a
`path_provider` application-support directory (the FFI factory's databases path
is not reliably writable on Android). Now one bundled FTS5-enabled SQLite is used
on every platform. Re-running the smoke test: the same "Explain the Nicene Creed"
query that threw `no such module: fts5` returned six matched passages, and a full
Ask (retrieval → Ollama on the host via `10.0.2.2` → grounded answer with
citations and the coverage notice) completed successfully. `flutter analyze`
clean. Still worth a quick iOS/macOS re-verify that the DB opens through the new
factory (the path moved), but Apple was already the working platform. Details of
the original bug kept below for context.

### Original report (BLOCKER, found 2026-07-23)

Smoke test on the Pixel emulator (API 37) found the core Ask flow **broken on
Android**. Tapping a question returns:

```
DatabaseException(no such module: fts5 (code 1 SQLITE_ERROR)),
while compiling: SELECT ... FROM content_fts fts ... WHERE content_fts MATCH ?
```

**Cause.** The app uses plain `sqflite: ^2.3.0`, whose `openDatabase()`
(`database_service.dart:55`) opens the **platform's system SQLite**. Apple's
system SQLite (iOS/macOS) includes FTS5, so every prior test passed; Android's
bundled SQLite does **not** ship the FTS5 module, so the lexical half of hybrid
search throws and aborts the whole query before retrieval or the LLM is reached.
The FTS5 table is built in Python and shipped inside `theology.db`, but querying
it needs FTS5 compiled into the *runtime* engine.

**Scope.** Android-only, and it blocks the app's central feature there. Vector
search is pure Dart and would work alone, but the hybrid path calls FTS first.

**Fix (recommended): bundle a full-featured SQLite on every platform instead of
relying on the system one.** Add `sqlite3_flutter_libs` (ships a modern SQLite
native lib with FTS5/JSON1 for Android/iOS/Linux/Windows) + `sqflite_common_ffi`,
and set `databaseFactory = databaseFactoryFfi` at startup so `openDatabase`
routes to the bundled engine on all platforms. This also pins one SQLite version
everywhere, removing "works on my platform" drift. Small code change (startup
init + factory), then rebuild and re-run this smoke test. Verify on Android
first, and re-confirm iOS/macOS still open the DB through the new factory.

*Alternative considered:* guard/skip FTS and fall back to vector-only on Android
— rejected; it silently degrades retrieval quality and hides the real problem.

## Ollama cold-start connection abort (RESOLVED 2026-07-23)

**Fixed as part of beta polish.** Two layers: (1) `OllamaService.preload()` sends
an empty-prompt `keep_alive` request that loads the model, called from
`InferenceProvider.refreshStatus()` whenever Ollama is the reachable backend — so
the model is warmed on app start / on selecting Ollama, before the first
question; (2) `generateStream()` retries on a connection-reset that happens
before any token (the cold-start signature), only while nothing has streamed, so
a mid-answer drop is never duplicated. The chat screen also maps a residual
connection error to "the model may still be loading — try again" instead of a
raw socket exception. Verified on the Android emulator: with the model unloaded,
`ollama ps` showed it preloaded right after launch, and the first question
streamed a full grounded answer with no abort. Original report kept below.

### Original report (minor, found 2026-07-23)

During the same smoke test the **first** Ask after switching the backend to
Ollama failed with `ClientException: Software caused connection abort,
uri=.../api/generate`, while retrieval and the connection test both succeeded. A
warm retry produced a full answer. Cause: the first `/api/generate` had to
cold-load a 20 GB / 33B model into GPU, and during that long silent gap (no
bytes flowing) the connection was reset — on the emulator this is the QEMU slirp
NAT dropping an idle connection, but a real device on a slow cold load could see
it too. `ollama_service.generateStream()` puts no timeout on `client.send()`, so
this is a socket/keepalive issue, not a Dart timeout.

Not a blocker (warm calls work), but a real first-run UX rough edge: a user who
opens the app and asks before the model is loaded gets a cryptic error. Options
when we get to it: send an initial `keep_alive`/warm-up ping when the Ollama
backend is selected; catch the abort and show "the model is still loading, try
again in a moment" with an auto-retry; or issue a tiny priming request on
backend-select so the model is resident before the first real question.

## Android — 16 KB page-size alignment (pre-Play-Store, found 2026-07-23)

The app builds, installs, runs and renders correctly on the Android emulator
(Pixel, API 37 / Android 17) — Material chrome, onboarding, pack list all
correct. But on launch Android shows an **"App Compatibility"** dialog: the app
isn't **16 KB page-size compatible**, so it runs in page-size-compatible mode.

- **Not a crash, not a testing blocker** — it runs fine in compatibility mode.
- **Is a Play Store blocker at release**: Google requires 16 KB-aligned native
  libraries for apps targeting Android 15+ (the platform is moving from 4 KB to
  16 KB memory pages). Modern devices/emulators enforce the check.
- **Real offender: `lib/arm64-v8a/libonnxruntime.so` — "LOAD segment not
  aligned."** It ships inside the `onnxruntime: ^1.4.1` plugin, which wraps an
  older ONNX Runtime build. The other libs the dialog lists (`libflutter.so`,
  `libdartjni.so`, `libVkLayer_khronos_validation.so`) report "Unknown error"
  and are largely the emulator's own check noise — current Flutter aligns its
  engine libs.
- **Fix at release time:** bump/replace the onnxruntime plugin to a 16 KB-aligned
  build (or a maintained fork), and bump AGP + NDK (r27+ aligns to 16 KB by
  default). Re-verify the dialog is gone. Defer until we're preparing a Play
  Store submission — it changes nothing for development or sideloaded testing.

**Shelved 2026-08-02: Google Play is not planned.** Distribution is the APK
download for the foreseeable future, and sideloading has no alignment
requirement, so nothing here blocks anything. It stays recorded because the
decision could reverse and the diagnosis would otherwise be redone.

What does *not* go away with it: the `onnxruntime` plugin's last pub.dev release
is **1.4.1, published 2024-03-27**, so there is nothing to bump to. That is worth
separating from the Play question — the plugin is the app's only path to on-device
embeddings, which is half of hybrid search and the reason Council works with no
network. An unmaintained dependency in that position is a risk on any
distribution channel.

## Scaling — the corpus, GitHub, and search as data grows (decided 2026-07-23)

The question that prompted this: if we eventually ship packs for everything in
the research catalog, does the current design hold? Traced the whole pipeline
(ingest → chunk → embed → pack → runtime search → LLM). Conclusion: **it holds
much further than it looks, and the first thing to break is the vector index —
not storage, and not the LLM.**

### Embeddings do not need a full rebuild per source

`tools/build_embeddings.py --incremental` embeds only chunks that lack a vector.
This is safe because chunk ids are **derived, not autoincremented**
(`id = unit_id * 1000 + sequence`, `build_chunks.py`), so appending sources
never renumbers existing chunks and their vectors stay valid. Workflow for a
batch of new sources:

```
python3 tools/build_chunks.py --write
python3 tools/build_embeddings.py --incremental --write   # seconds, not minutes
```

Full re-embed (`--write` without `--incremental`, which does `DELETE FROM
chunk_embeddings` first) is only needed when a source is **replaced in place**
(stub → full text, e.g. the Scots Confession), and even then only the changed
unit's chunks actually differ. The 18.8-min full rebuild on 2026-07-23 was
avoidable — use `--incremental` by default.

### Storage is not the constraint

| | Now (435 sources, 81M chars) | ~5× (most PD material) | Maximal (all Bibles, Spurgeon, Migne, commentaries) |
|---|---|---|---|
| Chunks | 76k | ~375k | ~1.4M |
| Embeddings resident | 28 MB | ~140 MB | ~525 MB |
| Packs total (gzip) | 48 MB | ~250 MB | ~1 GB |
| Largest single fragment | 14 MB | ~40 MB | ~120 MB |

- **GitHub Releases**: 2 GB per-asset cap (largest fragment is 14 MB — miles
  under); release assets don't count against repo size; no practical cap on
  total release-asset storage. Fine even at the maximal column.
- **SQLite / the device**: handles multi-GB DBs without issue. The fragment
  model already ships only what the user installs and stores overlapping content
  once (dedup across packs).

### The LLM never slows down with corpus size

This is RAG: retrieval selects the top-K chunks (`limit * 6` candidates in
`semantic_search.dart`) and only those enter the Ollama context. The model sees
the same small fixed context whether the library is 50 MB or 10 GB. So corpus
growth is a **retrieval-quality** problem, never an LLM-latency problem.

### What actually breaks first: the in-memory brute-force vector index

`VectorIndex.load()` pulls **every** embedding into RAM and `search()` does an
exhaustive dot-product scan (`vector_index.dart`). Elegant and correct at 76k
chunks (~28 MB, a few ms). At ~1.4M chunks it means ~525 MB resident (rough for
a phone) and hundreds of ms per keystroke-triggered search. **RAM is the ceiling
before latency is.** The code comment already acknowledges this trade.

### Staged plan (build only when the numbers demand it)

- **Now (free):** make `--incremental` the standard embed step (already
  supported); keep the fragment/pack model.
- **At ~300–500k installed chunks — make search corpus-size-independent:**
  - *Two-stage retrieval*: let FTS5 cheaply pre-select a few thousand lexical
    candidates, then run the vector dot-product only over those. `HybridRanker`
    already fuses lexical + semantic; this bounds vector work with **no new
    dependency**. This is the one architectural change to plan for.
  - *Memory-map the vectors* instead of a resident `Int8List`, so RAM stops
    being the ceiling.
- **Only if truly maximal (millions of chunks):** adopt an on-disk ANN index —
  `sqlite-vec` is the cleanest fit since we're already in SQLite. This is the
  dependency the current comment defers; keep it deferred until then.
- **For correctness as competing chunks multiply:** add a light **rerank** over
  the top ~20 fused candidates (the LLM itself, or a cross-encoder) before they
  enter context. Cheap because it only touches the top-K.
- **Storage hygiene for the "installs everything" user:** uninstall already
  reclaims space and dedups. Add a **"Manage storage"** view in the Library
  showing per-pack on-disk size and total footprint. UI task, not architecture.

**Bottom line:** the single investment to plan for (not build yet) is moving the
vector search from "load-all + brute-force" to "FTS-prefiltered + vector-rerank,"
triggered somewhere around a few hundred thousand installed chunks. Everything
else already scales.

## Bible versions — add every copyright-free translation we can

Today the app ships **KJV only**, which is the most conspicuous gap for an app
whose premise is comparing traditions. Add public-domain translations as their
own Scripture packs. Reference list of what's copyright-free:
`https://www.blueletterbible.org/versions.cfm` (BLB marks each version's status).

Public-domain / copyright-free versions to add (cross-checked with BLB and
ebible.org USFM ids where applicable):

- **King James Version (KJV)** — have it.
- **American Standard Version (ASV, 1901)** — PD. `eng-asv`.
- **Young's Literal Translation (YLT)** — PD. `eng-ylt`.
- **Darby Translation (DBY)** — PD. `eng-DBY`.
- **Webster's Bible** — PD (BLB's "WEB" is *Webster's*, not the World English
  Bible — don't confuse the two).
- **World English Bible (WEB/WEBBE)** — PD/CC0. `eng-web` / `eng-webbe` (with
  Apocrypha). Modern-language PD baseline.
- **Geneva Bible (1560)** — PD. Reformed/historical.
- **Douay-Rheims (Challoner)** — PD. `eng-dra`. Catholic canon. (Pull the ebible
  USFM; drbo.org claims © on presentation only.)
- **Brenton's English Septuagint (BES)** — PD. `eng-Brenton`. Orthodox OT.
- **Latin Vulgate (VUL)** — PD. Textual base / Catholic.
- **Textus Receptus / Westcott-Hort Greek NT** — PD. Original-language study.
- **Reina-Valera 1960 (Spanish)** — usable under attribution guidelines, not
  strictly PD; treat as a permissions item, not a clean PD add.

Modern translations (ESV, NIV, NASB, NKJV, CSB, NLT, NET, AMP, LSB) are all
**copyright-blocked** — do not ingest without a licensing path. Build the single
ebible.org USFM importer once; it serves every PD version above. See
`~/Documents/council research/research/acquisition-roadmap.md` §15 for the full
Bible-version gap analysis.

## Reader annotations — built

Selecting text while reading, and everything that follows from it. Previously
listed here as post-v1; built ahead of that because it is what turns a library
into something a reader works *in*.

Tapping a passage selects it — verses for Scripture, paragraphs for prose,
sentences where a paragraph runs too long to be a useful unit — and raises a
toolbar offering copy, the platform share sheet, five highlight colours, a note,
and a question to the configured model about the selected text.

The data model, since it was undecided when this section was written:

- **A separate database.** `council_user.db`, opened by `UserDatabase`, holding
  highlights, notes, conversations and messages. Deliberately *not*
  `theology.db`: that file is deleted and reinstalled whenever `corpusVersion`
  changes, so a note kept there would be destroyed by a routine content update.
- **Anchored by character range, plus a snapshot of the text.** The offsets are
  what make rendering cheap; the stored quotation is what lets an annotation be
  re-found if a corpus rebuild shifts a unit, and what lets a note still show
  what it is about after its passage is uninstalled with a pack.
- **Conversations are persisted**, so the Ask tab reopens where it was left and
  the Chat history page can return to any earlier thread. A thread started from
  a selection stores that passage, and leads its own prompt with it.

Still deferred:

- **Text-to-speech** — the app reads a source aloud (offline TTS so it works
  without a network, consistent with the offline-first premise).
- **Collections of saved passages** beyond the existing bookmarks, and reading
  themes/fonts beyond the current set.
- **Re-anchoring on drift.** The snapshot is stored but not yet used: an
  annotation whose offsets no longer match is currently rendered where the
  offsets say. Searching for the stored text and re-anchoring is the fix, and
  costs nothing until a corpus rebuild actually moves something.

## Desktop release signing (not started, blocked on purchases)

The 2026.7.27 release ships installers for both desktop platforms, and a reader
on either sees an operating-system warning the first time they run one. Neither
is a bug in the build; both are the absence of a paid identity, which is why
they are recorded here rather than fixed.

**macOS is nearly there.** The DMG is signed with the Developer ID Application
certificate for team `Y2Q5JVG8X5` and built with the hardened runtime enabled,
so `codesign --verify --deep --strict` passes and the whole chain resolves to
the Apple Root CA. What is missing is notarisation — Apple's own scan — so
`spctl --assess` returns `rejected: Unnotarized Developer ID` and Gatekeeper
declines a plain double-click. The download page tells the reader to right-click
and choose Open, which works, but it is an apology rather than a fix.
Notarising needs an app-specific password or an App Store Connect API key, then
`notarytool submit --wait` and `stapler staple` on the DMG itself. Stapling the
`.app` inside the DMG instead is the trap: the ticket has to be attached to the
artefact that is actually downloaded.

**Windows needs a certificate bought first.** The Inno Setup installer is
unsigned, so SmartScreen shows "Windows protected your PC" and hides the run
button behind *More info*. An OV code-signing certificate clears this only after
the binary accrues download reputation, which a low-volume release may never do;
an EV certificate carries reputation immediately. That difference — not the
signature itself — is what is being paid for, and it is the reason to decide
deliberately rather than buy the cheaper one by default.

When there is a certificate, signing belongs in CI rather than on a laptop: a
`signtool` step in the Windows job of `.github/workflows/release-desktop.yml`,
placed after ISCC and before the release upload, reading the certificate from
repository secrets. The macOS side stays local for now, because the signing
identity lives in the login keychain and moving it into CI means exporting a
`.p12` into secrets — worth doing only if desktop releases stop being occasional.

Both platforms' `note` fields on the download page exist solely to explain these
warnings. Both come off when this is done.

## On-device generation — the platform model, and a downloadable one (proposed 2026-08-02)

Council currently offers three backends: none, Ollama, and a cloud provider the
reader holds a key for. That leaves the default experience — no server, no key —
as search only. Two additions would give those readers grounded answers without
either.

**`InferenceBackend` already anticipates this and needs no change.** Its own
docstring names "the platform's own on-device model" among the backends, and the
three properties that make such a backend awkward are already on the interface:
`checkStatus()` exists partly to report "platform model supported on this
hardware", `contextBudgetChars` exists because "the on-device platform models
have small context windows", and `isPrivate` is what keeps the privacy
disclosure honest per backend. Adding either of the below is writing a class,
not reworking a design.

### Apple's Foundation Models framework

Apple ships a ~3-billion-parameter model on the device and exposes it to
third-party apps through the **Foundation Models** framework. No key, no
network, no download, and nothing leaves the phone — which is the same claim the
rest of the app makes, so this is the one generation path that does not weaken
it.

**Availability is the part to get right, and it is not a version test.** The
framework arrived in **iOS 26**, not 27, and the real gate is Apple
Intelligence support: A17 Pro or later on iPhone, M-series on iPad and Mac.
Gating on the OS version alone is wrong in both directions — it would exclude
working iOS 26 devices, and it would offer the backend on an iOS 27 iPhone too
old to run it. The check belongs in `checkStatus()`, asking the framework
whether the model is available and surfacing its own reason when it is not,
which is exactly what `BackendStatus.unavailable(detail)` is for.

Cost: a Swift platform channel, since there is no Flutter binding. Bounded work.
The context window is small — a few thousand tokens — so `contextBudgetChars`
will be far below the cloud backends', and retrieval will need to send fewer
passages rather than truncated ones.

### A downloadable small model for everything else

For Android, older iPhones, and desktop, the equivalent is shipping no model but
offering to fetch one: a 0.6–4 B parameter instruct model, quantised, run
locally. Qwen 3's smaller sizes are the obvious candidates, and the pack
machinery already solves the hard part — a catalogue of downloadable artefacts
with sizes and checksums, installed on request, is precisely what
`pack_service.dart` does for corpus fragments.

Two constraints decide the sizes offered, and both are RAM rather than disk. The
vector index is already ~170 MB resident (`VectorIndex.load` holds every
embedding), so a model has to fit *beside* it: a 4-bit 0.6 B model is a few
hundred megabytes, a 4 B is a few gigabytes and is a desktop-only option.
Second, this needs a generation runtime, which the app does not have — the
`onnxruntime` plugin here does embeddings only. llama.cpp through FFI with GGUF
weights is the well-trodden route.

Set expectations in the picker rather than in a support thread: a 1 B model
grounded in retrieved text is genuinely useful for summarising and comparing
passages the app has already found, and is not close to a hosted frontier model.
`description` on the interface is where that sentence goes.

### Sequencing

Apple's framework first: no runtime to integrate, no download to manage, no
model licensing to check, and it covers the newest hardware — where readers are
least tolerant of "install a server first". The downloadable path is the larger
piece and benefits from the picker and prompt-budgeting work the first one
forces.

## Replacing onnxruntime — researched and decided (2026-08-02)

Not urgent, and not a bug — embeddings work. But `onnxruntime`'s last pub.dev
release is **1.4.1, 2024-03-27**, and it is the app's only route to on-device
embeddings, which is half of hybrid search and the reason Council works with no
network. An unmaintained dependency in that position should have a known exit.

There is no upstream fix for anything that goes wrong with it — an ABI change on
a future Android or macOS, a security issue, or the 16 KB alignment problem that
would matter again if Google Play ever came back into scope.

Options, none costed yet:

- **Vendor a current ONNX Runtime build** behind the same plugin API. Smallest
  change: the model and the calling code stay as they are.
- **Call ONNX Runtime through Dart FFI directly**, dropping the plugin. More
  work, but removes the abandoned layer rather than patching under it.
- **Change the embedding model as well as the runtime.** Qwen 3 publishes open
  embedding models that would likely outperform all-MiniLM-L6-v2. This is the
  expensive option and the reason to think about it early rather than late:
  changing the model invalidates every stored vector, so the whole corpus must
  be re-embedded, and `idSpace` and the pack manifest have to carry the model
  identity so an app on the old model cannot silently mix its vectors with new
  ones. That is a corpus-wide migration, not a dependency bump.

### The decision

**Keep `onnxruntime` for embeddings for now, and make replacing it safe rather
than replacing it.** Researched against the alternatives:

| package | last release |
|---|---|
| `flutter_gemma` | 3 days |
| `llama_cpp_dart` | 7 months |
| `cactus` | 8 months |
| `fllama` | ~2 years |
| `onnxruntime` (current) | 2024-03-27 |

`flutter_gemma` is now a dependency anyway — it is what runs the downloadable
generation model — and it advertises embeddings, so the runtime for a switch is
already present and actively maintained. That makes it the obvious destination.

It is not the obvious *next step*, and the reason is the model rather than the
runtime. Vectors from two embedding models are not interchangeable: the
similarity between them is noise, not a weaker signal. Swapping the model means
re-embedding all 445,445 chunks — about 2.4 hours — and, worse, the failure mode
of getting it wrong is silent. Every count and every checksum would still be
correct while retrieval quietly returned irrelevant passages. Nothing in the
pipeline would have caught it.

So what is implemented now is the guard that was missing: the pack manifest
carries `embeddingModel`, `DatabaseService.embeddingModel` names what the app
encodes queries with, and `PackManifest.embeddingsCompatibleWith` refuses a pack
built by a different model. Manifests published before this carry no identity
and are trusted, because they predate any change.

With that in place the switch is a decision about whether better embeddings are
worth a corpus rebuild, which is a judgement call, rather than a change that can
silently corrupt retrieval, which is not. Nothing about the current runtime is
broken; embeddings work, and Google Play — the one thing that made its 16 KB
alignment problem urgent — is not planned.

## The iOS floor moved to 16, and why that is a dependency and not a decision

`flutter_gemma` requires **iOS 16**, so `IPHONEOS_DEPLOYMENT_TARGET` went 15.0 →
16.0 in all three build configurations and the Podfile followed. Recorded here
because a minimum-OS rise normally reflects a judgement about who is worth
supporting, and this one does not — it is what the downloadable-model runtime
demands.

What it costs is close to nothing, which is why it was accepted rather than
worked around. The devices capped at iOS 15 are the iPhone 6s, 7 and first SE,
all of which have 2 GB of RAM. The vector index alone is ~170 MB resident, and
the smallest model offered wants 400 MB beside it; none of them could have run
the feature that forced the bump. Making the runtime optional to keep those
three devices on a build that cannot use it would have been cost with no
beneficiary.

## Apple Intelligence — confirmed working (2026-08-02)

The bridge answers on real hardware. Previously only the *unavailable* branch
had been exercised, so this closes the one part of the feature that compilation
could not establish: the framework returns `available`, the stream delivers
deltas, and grounded answers come back with their citations intact.

Two corrections to what was assumed while building it:

* **The simulator does provide Apple Intelligence.** An iOS 27 simulator on
  Apple silicon inherits the host Mac's model, so the available path is
  reachable without a physical device. The earlier note that simulators can
  only exercise the unavailable branch was wrong.
* **The Xcode install is fine; the simulator-panel tooling is out of date.**
  This was misdiagnosed twice — first as a missing Xcode, then as an incomplete
  one — so the actual cause is worth stating. Xcode 27.0 (27A5228h) is complete:
  every SDK present, both simulator runtimes `Ready`, 15.7 GB of them under
  `/Library/Developer/CoreSimulator/Volumes` where Xcode 15+ keeps them, and the
  app builds and runs. `SimulatorKit.framework` exists as a real arm64e binary
  at `Contents/SharedFrameworks/SimulatorKit.framework`. Apple moved the
  simulator frameworks there out of `Developer/Library/PrivateFrameworks`, which
  no longer exists in any Xcode of this generation. The panel is built on
  FBControlCore, which still appends the pre-move path to whatever
  `xcode-select` reports, so the load fails.

  Nothing on this machine is misconfigured, and `sudo xcode-select -s` would not
  help — it already points at a working Xcode, and that is the only one
  installed. Symlinking the old path to the new one would break Xcode's code
  signature, which is a worse trade than losing screenshots. `simctl` is
  unaffected, so `flutter run -d <sim>` works and only attach/tap/screenshot are
  lost.

### The one bug it surfaced

The coverage notice's action row overflowed by 25 px on an iPhone 17 whenever
the suggested collection had a long name: `Row(mainAxisSize: min)` holding
"Browse library" beside "Add Church Fathers · 46.5 MB" is wider than the 354 px
the notice gets. Replaced with a `Wrap`, so the install button drops to its own
line instead — the only option that neither truncates the byte count nor hides
the button, and the size is on the button deliberately, because this is an
unsolicited suggestion to spend someone's data.

Reproduced before fixing: the old tree at 354 px throws a Flutter layout error
and the `Wrap` does not.

## The downloadable model, made to actually work (2026-08-02)

Verified end to end on the Android emulator: download → install → load →
grounded answer with citations. Asked what baptism is, Qwen 2.5 0.5B returned
the Westminster Larger Catechism's definition, cited [1]–[6]. Three separate
faults had to be fixed to get there, and each was invisible until the one
before it was cleared.

**1. No engine was registered.** `flutter_gemma` has been a *core* package
since 1.0 — it registers no inference engine by itself, and `initialize()` must
be called with the engines the app ships. Neither was present, so the first
download failed with `Bad state: FlutterGemma not initialized`. Fixed by adding
`flutter_gemma_mediapipe` (the engine that reads `.task`, which is the format
these weights ship in) and awaiting `FlutterGemma.initialize` during bootstrap.

The failure is worth noting as a class: the package resolved, compiled, and
analysed clean while being incapable of running a model. Nothing short of
running it on a device would have caught it.

**2. The Gemma weights are gated.** With the engine registered, the download
got as far as `DownloadException: Authentication required (HTTP 401)`. Both
`litert-community` Gemma repositories are gated, so fetching them needs a
HuggingFace account and a token — which is precisely what this backend promises
readers they will not need. Embedding a shared token in the app would put a
credential in a client binary and make the feature one revocation away from
breaking for everybody; mirroring the weights would mean hosting 550 MB under
someone else's licence.

Replaced with Apache-2.0, ungated weights. Qwen was also what was wanted from
the start. The cost is real and is recorded rather than hidden: Qwen 2.5 0.5B
is a weaker model than Gemma 3 1B would have been. It is still the right trade,
because a model requiring a signup is not an option this backend can offer.

**3. The 135M was worse than nothing.** SmolLM 135M was to be the 170 MB option
for older phones. Asked what baptism is, with the Westminster catechisms and
Aquinas retrieved and in front of it, it produced advice about learning a
foreign language. Not a weak answer — no engagement with the passages at all,
which is the single thing this backend exists to do. Removed. The honest floor
is now 550 MB and one model, which is better than a cheap option that
discredits the feature.

### Also settled here

* **Phones only.** `flutter_gemma_mediapipe` declares android and ios; there is
  no desktop `.task` support. The download was being offered on macOS, Windows
  and Linux, where it could never have loaded. Gated on
  `LocalModelChoice.runsHere`, with `checkStatus` explaining itself for a
  settings file carried over from a phone. Desktop keeps Ollama, which is a
  better answer there anyway.
* **`ModelType` is per model.** It was hardcoded `gemmaIt` from when both
  choices were Gemma; it is now carried on `LocalModelChoice`.
* **GPU on Android** needs four `uses-native-library` entries in the manifest.
  Without them the OpenCL loader cannot reach the vendor driver on Android 12+
  and the engine falls back to WebGPU, which hard-freezes some Mali GPUs. All
  marked `required="false"`, so a device without OpenCL still runs on the CPU.
* **A stale model id is harmless.** `byId` falls back to the first choice, so
  the `gemma3-1b` left in preferences resolved cleanly instead of crashing.
  Confirmed on the device rather than assumed.

## One engine, one family, five platforms (2026-08-02)

Three asks, and the third turned the first two inside out: offer removal of a
downloaded model; offer the download on desktop too, for readers who do not
have Ollama or do not want to learn it; and standardise on Qwen, which
publishes at every size.

**MediaPipe cannot do that, so LiteRT-LM replaced it.** MediaPipe reads `.task`
on Android and iOS only. LiteRT-LM reads `.litertlm` on Android, iOS, macOS,
Windows and Linux — so the whole "phones only" restriction added earlier the
same day was not a fact about the problem, it was a fact about the engine
chosen. Swapping it removes the restriction, drops a dependency rather than
adding one, and leaves a single native runtime to reason about.

**The trap in that swap.** `ModelFileType` has a distinct `litertlm` value, and
both `installModel` and `createModel` default the parameter to
`ModelFileType.task`. A `.litertlm` file left on the default downloads, installs
and reports itself installed — and then fails at the first question with "No
inference engine can handle this model (ModelFileType.task)". The package README
still says to use `task` for `.litertlm`; that advice predates the enum value.
Carried on `LocalModelChoice` now, so it cannot drift from the filename, and
asserted in `test/local_model_catalogue_test.dart`.

Worth noting the shape, because it is the second instance in a day: both this
and the missing engine registration produced a build that compiled, analysed
clean, downloaded successfully and was incapable of answering. The only thing
that catches this class of fault is running it.

### The ladder

Qwen throughout, which was the point — one family covers 0.6B to 8B under
Apache-2.0 with no gate, so the picker does not become a tour of unrelated
projects. What a device is offered is a subset of the catalogue, because the
sensible sizes differ by an order of magnitude:

| | offered | recommended |
|---|---|---|
| phone | 0.6B (500 MB), 1.7B (2.1 GB) | 0.6B |
| desktop | 1.7B, 4B Instruct (2.7 GB), 8B (4.9 GB) | 1.7B |

`byId` resolves against the full catalogue rather than the platform's
shortlist, so a model chosen on a laptop is recognised on a phone instead of
silently resetting.

**Not Qwen 3.5 or 3.6, and this was checked rather than assumed.** Both exist
upstream — 3.5 at 4B/9B/27B/122B, 3.6 at 27B/35B — and neither has a LiteRT or
MediaPipe conversion. Even converted, 3.5 starts at 4B and 3.6 at 27B, so both
miss the phone end entirely. Qwen 3 is the newest line that reaches 0.6B. Worth
re-checking when `litert-community` catches up.

### Removal

`uninstall()` unloads the runtime before deleting, because the engine holds the
file open and on Windows deleting underneath a live handle fails outright. The
button appears only when there is something to remove, and confirms first: it
is not undoable in any cheap sense, since getting the model back means
re-downloading the gigabytes the reader was trying to reclaim.

### Verified, and not

Verified on the Android emulator: download, install, **remove**, re-download,
and a grounded answer citing all six retrieved sources — Qwen 3 0.6B synthesises
across them rather than quoting one, which the 2.5 0.5B did not.

macOS builds and launches with the engine registered, and `flutter test` runs
on the host so the desktop half of the catalogue is covered by assertions. What
is **not** verified is a desktop download and generation: that is a 2.1 GB fetch
and needs the app driven by hand. Same for iOS.

## Three faults found by asking who the feature is actually for (2026-08-02)

### Progress bars showed no progress, app-wide

A 500 MB download rendered an identical solid bar at 14% and at 56%. Sampling
the pixels settled what staring at the widget could not: the whole bar was one
colour, `#7AA2F7`, end to end. The value was never wrong — the *track* was being
painted in the same colour as the fill.

Material 3 paints the unfilled part of a `LinearProgressIndicator` in
`colorScheme.secondaryContainer`, and `ColorScheme`'s constructor falls that back
to `secondary` when it is not supplied. All three hand-built palettes set
`secondary` to the same accent as `primary` — reasonable for one-accent designs
— so track and fill came out identical. This affected **every** progress bar in
the app, including pack downloads, in every theme.

Fixed once in `_build` with an explicit `linearTrackColor`, rather than in each
palette: stating the colour beats depending on which role Material reaches for
next. Verified by measuring the painted run — 291 px of 911 at 32%, 564 px at
62%.

### `minDeviceRamMb` was decoration

Every model declared one and nothing read it. A 2 GB iPhone 8 — which can
install Council, since iOS 16 is both its ceiling and the app's floor — was
offered the 2.1 GB model that declares a need for 8 GB. It would have downloaded
in full and then been killed by the OS, and those phones are precisely who this
feature exists for, since Apple Intelligence covers the new ones.

`DeviceMemory` now reads physical memory per platform, and `availableHere()`
filters on it. Unknown is treated as permissive rather than as "too little":
hiding the feature from a device that merely failed to answer is worse than
offering one it might not run. When nothing fits, the smallest is shown anyway
with a line saying why, so the card explains itself instead of vanishing.

**The thresholds were wrong on first contact, in the instructive direction.**
They were written against nominal sizes, but the OS reports less than the device
is sold as — a 4 GB Android reports 3,967 MB — so a 4 GB emulator that had
already generated an answer with the 0.6B was told it lacked the memory for it.
Each is now set about a tier below the nominal size it is meant to admit.

## The recommendation now matches the machine (2026-08-02)

Audited against the actual question — does the app pick the best model the
device can run? — it did not, in two directions.

**`recommended()` never consulted memory.** It returned `all.first`, the
smallest option for the platform, so a 64 GB Mac Studio was defaulted to the
1.7B: the weakest thing it could possibly run. The reader had to notice the
picker to get anything better. Now `recommendedHere()` takes the *largest* that
fits, which is safe precisely because the thresholds already carry the caution —
each sits well above the model's resident cost, so "fits" means fits beside the
OS, the database and the vector index.

**The platform split excluded the small model from desktop.** `all` was a
disjoint pair of lists, so a 4 GB Linux box saw only the 1.7B and was told it
lacked the memory — while the 0.6B would have run there perfectly well. Platform
now sets a *ceiling*, never a floor.

**And the ceiling had to become per-platform rather than a flag.** Marking only
the 8B as desktop-only left the 4B — 3.2 GB resident — offered to an 8 GB phone,
which is exactly the case a per-app cap kills. Total RAM is simply the wrong
measure on a phone: iOS and Android limit what one app may hold to well under
the physical amount, and exceeding it means the OS kills the app rather than
swapping. So each model now carries `minPhoneRamMb` separately from
`minDeviceRamMb`, and null means desktop-only.

| device | offered | recommended |
|---|---|---|
| 2 GB phone | 0.6B, marked as not fitting | 0.6B |
| 3–8 GB phone | 0.6B | 0.6B |
| 16 GB phone | 0.6B, 1.7B | 1.7B |
| 4 GB desktop | 0.6B | 0.6B |
| 8 GB desktop | 0.6B, 1.7B, 4B | 4B |
| 16 GB+ desktop | all four | 8B |

Verified on both branches: the desktop half by host tests, the phone half by an
integration test on the emulator, since `Platform.isAndroid` is the only way to
reach it.

The phone figures are the least-evidenced numbers in the app — only the 0.6B has
been run on real hardware — and they are set cautiously on purpose. Being too
conservative costs a flagship reader a better model; being too generous costs an
ordinary reader a multi-gigabyte download that ends in a crash.

## The transcript stopped fighting the reader (2026-08-02)

Reported as the app feeling like it was resisting you: scrolling up while an
answer streamed snapped straight back to the bottom, so the start of a long
answer could not be read until it had finished.

Every streamed chunk called `_scrollToBottom()`, which animated to
`maxScrollExtent` unconditionally. Chunks arrive far faster than the 300 ms
curve could finish, so each one interrupted the last *and* undid any scrolling
the reader had done — several times a second.

Following is now conditional: on until the reader scrolls away from the end, on
again the moment they come back. The moments they caused directly — asking a
question, opening a thread — still force it, because asking a question is a
statement that you want to see the answer. Streaming also jumps rather than
animates, since animating to a target that moves every frame is what made it
stutter.

**The subtle half is that growing content emits scroll notifications too.**
While an answer streams, `maxScrollExtent` runs ahead of `pixels` every frame,
and reading that as "the reader scrolled up" would switch following off a
moment after switching it on — the same bug inverted. So the decision only
moves on notifications that arrive during an actual drag or fling.

That rule is [TailFollower], extracted from the screen rather than left inline,
because it is not obvious and it is exactly the kind of thing that gets
"simplified" back into the bug. Eight tests cover it, including both
growing-content traps.

Scrolling away is now sticky, so a "Jump to latest" pill appears while an
answer is still arriving and the reader has moved off the end — without it,
getting back means dragging by hand through text that is still growing.

Verified on the device: mid-stream, scrolled to the top of the answer, and the
position held pixel-identical seven seconds later with the answer still
arriving.

## Apple Intelligence on the Mac, and the download offered everywhere (2026-08-02)

**The Mac had Apple Intelligence and Council said it had none.** Two independent
halves were wrong, which is why it looked like a single stubborn bug: the Dart
gate read `Platform.isIOS`, and the macOS runner never registered the channel.
Fixing either alone would have changed nothing.

Apple's Foundation Models framework is on macOS 26+ as well as iOS 26+, with the
same API. `FoundationModelsBridge.swift` is now shared between the two runners —
a symlink into `macos/Runner/` rather than a copy, because the framework, the
availability rules and the channel contract are identical, and a divergence
between two copies would be invisible until one platform silently stopped
offering the model. Only three things differ, all handled in-file: the Flutter
module name, `messenger` being a method on iOS and a property on macOS, and the
user-facing strings, since "check Settings" and "needs an iPhone 15 Pro" are
both wrong on a Mac.

Verified on this machine rather than inferred: the framework reports
`available`, and asked what baptism is through the macOS bridge it answered.

## The downloadable model is offered everywhere

It used to be suppressed whenever the built-in model worked. That was backwards.
Having Apple Intelligence is a reason to *default* to it, not a reason to
withhold the alternative: the built-in model is a fixed, modest one, and a Mac
with memory to spare can run a 4B or 8B the reader picks themselves. Now every
device the engine covers gets the option and its three tiers, whatever else it
has.

`supersedesDownload` was deleted rather than left unused — it encoded exactly
the assumption being removed.

Renamed to "Download a local model": "small" described the only option that
existed when there was one, and is now false on the tier that exists to be the
largest the machine can hold.

## A picker of two or three, and a disk check (2026-08-02)

**Everything that fits is not a useful list.** On a workstation that is four
entries an order of magnitude apart in both download size and speed, with
nothing saying which is which — and a parameter count is not a decision anyone
can make unaided. The picker now answers the three questions a reader actually
has: what is the sensible choice, what if I want it smaller and faster, and what
if I want the best answers this machine can give.

`LocalModelTier` labels by *fit*, not by model, which is the point: the same
weights are the "best answers" option on a mid-range phone and the "smaller and
faster" one on a Mac Studio. The tier leads the row and the model name sits
under it, because the tier is what is being chosen between.

**The recommendation is deliberately not the largest that fits** once there are
three. The largest is also the slowest, and defaulting to it would make the
feature feel broken on exactly the machines that can run the most; it is offered
as "Best answers", described plainly as slower.

That change caught a contradiction: `recommendedHere()` still returned the
largest, so the radio selected by default and the row labelled "Recommended"
pointed at different models. It is now *defined* as whatever the picker
recommends, and a test asserts they agree.

### Disk

The catalogue reasoned about memory and said nothing about storage, so a reader
with 3 GB free could start the 4.9 GB download. It failed loudly rather than
silently — but only after the bytes had been fetched, which on a metered
connection is paid for nothing.

`DeviceStorage` reads free space per platform: `StatFs` on Android against the
directory the model is actually written to (adopted storage makes that different
from the root volume), `volumeAvailableCapacityForImportantUsage` on iOS because
the plain free-space key under-reports and would refuse downloads that would
succeed, and `df`/PowerShell on desktop so the Windows C++ runner needs no
native code for one number.

Treated differently from memory, and the difference matters: a reader can free
space and try again but cannot add RAM, so a model too large for the disk stays
visible with its download blocked and the numbers shown, rather than
disappearing. It is also not cached — free space is the one device fact that
changes while the app is open, often *because* the reader has just gone to make
room, and a stale answer would tell them their effort had not worked.

Verified on the emulator by filling `/data` to 421 MB free: the card explained
itself, and pressing Download refused before a byte moved.

### The download was hidden from anyone eligible for Apple Intelligence

`offersPlatformLlm` covered `notEnabled` and `modelNotReady` as well as
`available`, and the downloadable model was hidden whenever it was true. So an
eligible iPhone with Apple Intelligence switched **off** was shown the switch and
nothing else: a reader who did not want to turn it on was left with a server to
stand up or a key to buy, on a device perfectly able to run a downloaded model.

Split into `supersedesDownload`, true only for `available`. Being *eligible* for
a built-in model is not the same as having one that answers.

## The app can now tell you it is out of date (2026-08-02)

**Council had no way to say a new version existed.** On four of its five
platforms it is a direct download — no Play Store, no Mac App Store, no apt —
so nothing on the device was ever going to mention it. A reader found out by
happening to visit the download page again, which for most people means never.
Every fix in this file shipped to whoever downloaded after it and to nobody
else.

The app now checks at launch, and offers what it finds.

### The manifest, and why it is not the GitHub API

`https://www.spencersmith.site/council/updates.json` states, per platform, the
current version, the URL, the exact byte count and the sha256 of the installer.

Not the releases API, and not `releases/latest/download/...` either: **app
releases in this repository are marked pre-release**, so `releases/latest`
resolves to the corpus content releases — which is exactly what `PackService`
depends on and must keep doing. There is no stable "latest" URL for the app to
follow. A static file on the site is also one request with no rate limit, which
matters when every launch makes it.

It restates what `download.js` already says, which is drift waiting to happen,
and the drift is quiet in the worst way: the page would offer a build no
installed app ever updates itself to, and neither file would look wrong.
`scripts/check-council-release.mjs` in the site repo settles it — it *evaluates*
the page's `PLATFORMS` array rather than pattern-matching it, so reformatting
cannot break the check, and compares every version, URL and size, reporting all
disagreements rather than the first.

### The checksum is the load-bearing part

This feature downloads an executable and hands it to the operating system to
run with the reader's own privileges. That is a different risk from a content
pack, and the checksum is the only thing that separates a genuine installer
from a truncated download, a proxy serving something else, or a substituted
file. So:

- a platform entry with no sha256, a malformed one, or a plain-`http` URL is
  **dropped at parse time** rather than offered hopefully;
- a download whose bytes do not hash to the published value is deleted and
  reported, never handed on;
- the manifest's checksums are GitHub's own per-asset digests, and they were
  verified rather than trusted: the macOS disk image was downloaded and hashed
  locally and matched the digest and the byte count exactly.

### Dates are not strings

`AppVersion` parses `2026.8.2+7` into numbers because the obvious shortcut is
wrong in a way that hides for most of a month: `'2026.8.2'.compareTo('2026.8.10')`
is positive, so a string comparison decides the tenth is *older* than the second
and every reader stops being offered updates until the next month rolls over.
The same trap sits at `2026.9.1` versus `2026.10.1`. The date parts decide and
the build counter only breaks a tie, so a rebuild of the same day is still an
update.

### Checked automatically; downloaded on request

The setting is "check for updates automatically", on by default, and that
default is the whole point — off by default would leave most installs sitting on
whatever they first downloaded.

**The download is one tap, not automatic.** The Android package is nearly 200 MB,
and starting that unasked on whatever connection a phone happens to be using —
quite possibly metered, quite possibly roaming — is a real cost taken without
permission. The sheet states the version and the size before anything moves.
The launch check itself is silent about everything except finding something: no
spinner, no error on a device with no network, because it was not asked for.

Free space is checked before the bytes rather than after, which is the lesson
the model download taught the hard way.

### Handing over, which is where the platforms differ

No platform lets a running application replace itself in place, so the honest
design is fetch, prove, hand over, get out of the way.

- **Android** needs native code and is the only one that does: the package
  installer will not take a file path, only a `content://` URI from a
  FileProvider, and only from an Activity. Since Oreo it also needs the reader
  to have allowed this app to install unknown apps — and without that the intent
  does *nothing*: no dialog, no error, no installer. So the native side checks
  first and opens that settings page, which is the difference between an update
  that works and a button that appears to be broken.
- **macOS** is sandboxed, so spawning `/usr/bin/open` is not reliable.
  url_launcher goes through NSWorkspace, which is an out-of-process request to
  LaunchServices and is allowed to open a file inside the app's own container.
- **Windows** cannot overwrite a loaded executable, so the installer is started
  detached and the app quits. The button says "Install and quit" for that
  reason.
- **Linux** gets no pretence of an installation. A running AppImage is a mounted
  image of the very file that would have to be replaced, so the new one is made
  executable and its folder opened.
- **iOS** cannot install anything, itself least of all, so it opens TestFlight.

### Verified on devices, not assumed

Everything in Phase 11 through the model work says the same thing: the faults
here compile, analyse clean, download successfully and only fail on hardware.
`integration_test/update_flow_test.dart` runs against the real manifest and the
real release.

- **Android emulator:** the published manifest parsed, an older build was
  offered 2026.8.2, the running build was offered nothing, the real 195 MB APK
  downloaded and matched its published sha256, and — with
  `appops set … REQUEST_INSTALL_PACKAGES allow` — `UpdateInstaller.install`
  returned `handedOff`, meaning FileProvider produced a URI the package
  installer accepted. That last step has no unit-test equivalent: a wrong
  authority or a path missing from `update_paths.xml` throws there and nowhere
  earlier.
- **macOS:** the real 56 MB disk image downloaded, verified, and NSWorkspace
  mounted it from inside the sandbox.

A tampered byte was tested too, in the unit suite: the download is deleted and
the sheet says so, with no Install button anywhere.

## What stands between here and an official release (2026-08-11)

2026.8.2+7 is published as a pre-release with installers for four platforms and
TestFlight for the fifth. What separates that from a release called official is
not a feature. It is that on two platforms the operating system still warns the
reader that Council might be dangerous, and on a third the app was signed with a
key that cannot be used again.

**Android signing is done, and it was the only irreversible one.** Release
builds carried the Flutter template's debug `signingConfig`, so the published
APK is signed with the debug keystore. Android refuses an update signed with a
different key than the installed copy, which makes this unlike every other item
here: it cannot be fixed in a later build for anyone who installed the earlier
one. It is now a real 4096-bit key read from a git-ignored `key.properties`,
with the certificate fingerprint recorded in `TODO.md` and a release build
*failing* rather than falling back to debug — the fallback being what shipped
the problem in the first place, silently.

The cost is one-time and lands on the pre-release's users: the properly signed
build will not install over a debug-signed one. They uninstall and reinstall
once, and through the in-app updater that looks like a broken update rather than
a key change. So the download page has to say so — and that line lands *with*
the release cut, never before it, because the page must not describe a build
that is not published.

**The other two are purchases, and stay open.** Notarising the macOS DMG needs
an app-specific password or an App Store Connect API key; signing the Windows
installer needs a certificate, where OV and EV differ in whether SmartScreen
reputation is immediate or accrued. Both are described in *Desktop release
signing* above and neither has changed. They are the release's remaining
blockers in the sense that they decide what the reader sees on first run, and
shipping without them is a defensible choice — the download page's `note` fields
already explain both warnings — but it should be a decision rather than an
oversight.

**Hardware verification, as of 2026-08-06.** An Android phone, a Mac, an iPhone
and an iPad were all run by hand: the app launches and the AI features work.
What is still unrun is the Windows and Linux update hand-off, and a desktop
model download. Both are accepted for now rather than closed, which is a
different thing from being unknown.

**What the app itself gained on the way here.** Ask now opens on a new
conversation rather than on the middle of the last one; a citation leads into
the work it came from, at the section quoted; and two overflows were fixed at
320 px and the largest font size, both of which removed a control the reader
needed — the Stop button during generation, and the composer itself. Read and
Library were audited the same way and are clean.

## 32-bit Android gets no local model, and that is the answer (2026-08-11)

A Galaxy A13 5G was offered the downloadable model, spent 500 MB on it, and got
a plugin exception about ABIs at the first question. The gate tested the
operating system rather than the architecture, so every 32-bit Android build
satisfied it; LiteRT-LM is arm64-only there. Fixed, with the reason now stated
before the download rather than after it.

**The device is not the fault of its owner.** The A13 5G has a 64-bit MediaTek
Dimensity 700 and shipped with a 32-bit kernel — Samsung's choice, unchangeable
by any update. So the message names the operating system, not the processor: a
reader told their hardware is too old would be told something false about a
phone they cannot do anything about.

### A path exists, and was declined

Worth recording because the plugin's own error suggests it, so anyone reading
that message will find it and cost themselves an afternoon.

`com.google.mediapipe:tasks-genai` really does ship a 32-bit engine —
`libllm_inference_engine_jni.so` is 18.3 MB in `armeabi-v7a`, against 25.4 MB in
`arm64-v8a`, so it is a real implementation and not a stub — and
`flutter_gemma_mediapipe` exists on pub to reach it. MediaPipe's natives could
be excluded from `arm64-v8a` the same way the Hexagon skeletons are, so arm64
readers would pay nothing and only the 32-bit slice would grow.

**Not doing it.** It would add a second inference engine, a second model format
(`.task` rather than `.litertlm`, which in practice means Gemma rather than
Qwen), a second catalogue and a second code path — permanently, for a device
class Google is phasing out — in exchange for generation that a 32-bit ARMv7
process on a 4 GB phone would run without dotprod, beside a 170 MB vector index,
at a speed nobody has measured and no one expects to be good.

A device that cannot run a local model simply does not get one. Ollama, an API
key, and the whole offline library, search and citations remain, which is most
of what Council is. Saying so plainly is a better answer than a 550 MB download
that produces a paragraph in a minute.

## Qwen 3 was thinking out loud into the transcript (2026-08-11)

Asked to compare views on baptism, the downloadable model answered with several
paragraphs of its own scratch work before the answer — "First, looking at source
[1], it talks about John the Baptist… So, the key points are…" — and only then
reached "1. John the Baptist's Role in Preaching". Qwen 3 is a hybrid reasoning
model and thinks out loud before answering, which is normal; putting the
thinking in front of the reader is not.

**The markers were there the whole time.** Two explanations were open — that the
model emitted no `<think>` tags, so the reasoning could not be separated, or
that it emitted them and nothing stripped them — and the transcript could not
settle it, because `MarkdownBody` drops unknown HTML tags. The tags were being
rendered to nothing, so the scratch work arrived looking exactly like prose. The
one place the difference is visible is the raw token stream, and printing it
settled it in one run: the stream opens `"<think>"`, `"\n"`, `"Okay"`, `","`,
`" the"`, `" user"`, and closes the block with `"</think>"` before the real
answer. Emitted, and not stripped.

**Why nothing stripped them.** `flutter_gemma` does strip them — inside
`InferenceChat`, along with appending Qwen 3's `/no_think` switch. Council drives
a bare `openSession` instead, deliberately, because the RAG prompt is the whole
conversation and a chat object would add history management this backend does
not want. Every layer that would have caught this sits in the path not taken.
`openSession` does take `enableThinking`, but false does not mean "off" — it
means `flutter_gemma` sends no `enable_thinking` hint at all, leaving the model
bundle's own template to decide, and Qwen 3's template thinks by default.

**Fixed at both ends, because they do different jobs.** `/no_think` is appended
to the prompt, which stops the thinking from being generated; `ReasoningFilter`
strips the markers from the stream, which stops anything that is generated
anyway from reaching the reader. The first is a soft switch a small model can
ignore, so it cannot be the only defence; the second cannot recover the wasted
tokens, so it is not a substitute for the first.

Both were measured on the real weights rather than assumed, and `/no_think`
turned out to be worth having on its own:

| | chunks emitted | generation |
|---|---|---|
| bare session, as shipped | 652 | 9,150 ms / 6,144 ms |
| with `/no_think` | 190 | 1,990 ms / 2,259 ms |

The chunk counts are the figure to trust — they were identical across both runs.
The times are from a cold and a warm run of the same test and are given as a
range rather than a headline, because a 2.7×–4.6× spread is a fact about how
warm the engine was, not about the change. What is stable is that the model was
generating **3.4× as many tokens** as the reader ever saw. The answer stayed
grounded and cited across the change.

**The filter handles two marker shapes, not one.** `<think>…</think>` is what
Qwen 3 emits. But when LiteRT-LM reports reasoning on a separate
`channels.thought` field instead, `SdkTextExtractor` rewrites it into Gemma's
`<|channel>thought…<channel|>` form — and `flutter_gemma`'s own Qwen filter only
looks for `<think>`, so that shape leaks even on the path that filters. Which
one arrives is a property of the model bundle and the engine build, so both are
handled.

Filtering happens per chunk rather than on the finished string, because the
answer streams into the transcript as it arrives — filtering at the end would
mean the reader watches the reasoning appear and then vanish. Markers split
across chunk boundaries are the normal case, not an edge one: the raw stream
above delivers `<think>` and `\n` as separate chunks. So anything that could
still turn out to be the start of a marker is held back until the next chunk
settles it, which is at most a few characters.

**One shape is knowingly not handled.** A template that *prefills* the opening
marker would make the closer the model's first emitted token, with the reasoning
already unmarked ahead of it — `flutter_gemma` handles that for DeepSeek.
Catching it in a stream would mean withholding the start of every answer until a
closer arrived or was ruled out, paying a visible stall on every question against
a shape the real 0.6B does not produce. The marker is still dropped if it appears;
only the prose ahead of it gets through. Pinned as a passing test rather than
left to be rediscovered.

**Verified against real weights, not fixtures.**
`integration_test/local_model_reasoning_test.dart` downloads the 0.6B and runs
it on macOS, and is opt-in because it fetches 500 MB:

    flutter test integration_test/local_model_reasoning_test.dart -d macos \
      --dart-define=RUN_LOCAL_MODEL=true --dart-define=PRINT_RAW_OUTPUT=true

It asserts twice over: that no markers survive, and that the answer does not
*open in the reasoning register* — which is the assertion that would have caught
the reported bug even with the markers rendered invisible. A second test drives
the bare session with nothing suppressing it, so the filter is shown to be
removing something real rather than passing against a model that never thought.
The chunk-boundary cases are covered on the host in
`test/reasoning_filter_test.dart`, which feeds the stream a character at a time.

`LOG_RAW_MODEL_OUTPUT=true` on a debug build prints the raw stream from the app
itself, which is the diagnostic this was found with and the one to reach for
first next time an answer looks wrong in a way the transcript cannot explain.

Scoped to the downloadable backend. Apple Intelligence, Ollama and the cloud
providers are untouched, as are retrieval and citations.

---

## The taxonomy, and a shelf shaped like the church (2026-08-30)

Three pieces of work that turned out to be one: a corpus survey, an ingest the
tooling had refused, and a `traditions` table that could not express what the
app claims to cover.

### The survey, and what it found

Two user-facing defects, both of the same kind — a pack description asserting
something the corpus did not hold. The Methodist pack promised Wesley's *Notes
on the New Testament*; the corpus held one Wesley source and it was the
*Sermons*. Three tradition packs described a single confession and shipped
between 3.7 MB and 107 MB, so a reader downloaded Spurgeon's complete sermons
expecting the 1689 Baptist Confession. Both are fixed, and the fix in each case
was to say what is there — including two things no description mentioned, the
First London Baptist Confession and the Scots Confession — and to name what is
not, which the Anabaptist pack was already doing and the others were not.

The README was wrong about its own numbers in both directions: 687 works
against an actual 650 (it predated the v16 apocrypha prune) and 460 M
characters against 471 M. It also gave a reason for Oriental Orthodox being
absent, and the tradition was not absent and that was never the reason.

### Searching by the shape of the document, not by the archive

Three texts sat under *Wanted, with no clean text anywhere* in `TODO.md` —
searched for, not merely missing. All three are on English Wikisource: the
Dordrecht Confession complete at 29,459 characters, nine works of Menno Simons
at 1.04 M, and the Book of Jubilees inside Charles' *Apocrypha and
Pseudepigrapha*. Vatican I and Thomas Campbell's *Declaration and Address* are
there too, both named in `SOURCES.md` as public domain and never fetched.

The lesson is not "try Wikisource", which is where the Westminster Confession
came from. It is that those three searches had only been run against Gutenberg
and CCEL, and both are **book** archives. A 29,000-character confession has no
Gutenberg edition because nobody publishes it by itself, and that is a fact
about the document rather than about the archive.

Wikisource rate-limits hard, and its failure mode is the dangerous one: without
a descriptive User-Agent and a delay it returns HTML errors that parse as an
empty page rather than as a failure. A silently-empty result is
indistinguishable from a work with no text, which is the reason to write a tool
for it rather than fetch by hand.

### Schaff: answering a refusal instead of relaxing it

`ingest_ccel.py` refuses Schaff's *Creeds of Christendom* because CCEL's export
linearizes his parallel Latin/English columns into unreadable prose. The
refusal is correct. It is also written about the volume and applied to every
document in it, and it is not true of all of them — the third edition adds an
English appendix carrying the whole Second Helvetic Confession.

`ingest_schaff.py` answers that with a measurement. Every candidate is scored
for Latin, French and German function words that have no English homograph, as
a ratio against English ones, and anything above 0.02 is refused before it is
parsed. The populations do not overlap: clean English measures 0.000 on all
three axes, the nearest refusal is 0.021 and the worst is 8.6. The refused
documents stay in `CANDIDATES` so `survey` can be watched rejecting them, which
is the same reason `audit_completeness.py` prints its near misses.

Calibrating it caught the obvious trap. A first pass included `in`, `sed`,
`non` and `cum` as Latin markers and scored the Second Helvetic — which
contains no Latin whatever — as 1.3 parts Latin, because those are English
words. The gate is only as good as the markers having no homograph.

Taken: the Second Helvetic Confession, 30 chapters and 185 K characters, which
both ledgers recorded as copyright-blocked in every English edition found; the
Savoy Declaration's Platform of Discipline, Congregationalism's constitutional
document and previously absent; and the Reformed Episcopal Articles. Refused
and worth a second pass with a column-aware extractor rather than a lower
standard: the Piedmont (Waldensian) confession and the Moravian Easter Litany,
both of which have a real English column the export interleaves.

### A table that could not say what the app covers

`traditions` was fifteen rows grown one ingest at a time, so "Early Church" and
"Baptist" sat at the same level as though they were the same kind of thing. One
is a period every branch inherits; the other is a family inside one branch.

It is now **branch → family**, with denominations to hang off families later.
The taxonomy is data — `tools/data/traditions.json` — because the tradition
list is a doctrinal judgement rather than a schema detail, and a judgement
should be readable and diffable without reading Python. The inclusion rule
lives in the same file as the groups it excludes.

**The rule is Nicene in substance**, and the load-bearing word is *substance*.
The test is doctrinal content, not creedal form, which is what lets the
Brethren, the Restorationists and the Adventists in: their non-creedalism is a
conviction about creeds, not a denial of the doctrine creeds state. A test that
could not tell those apart would exclude traditions this app exists to
represent. Note the seam inside Pentecostalism — Trinitarian bodies are in,
Oneness Pentecostalism is modalist and is out — so "Pentecostal" is not one
verdict.

**Granularity is families, of which there are 31.** Not denominations: the
World Christian Database counts roughly 45,000, so that is a different project
and not a longer list.

Three things this settled that were open:

* **Congregational needs no row.** Reformed, Presbyterian and Congregational
  are one family, because the polity difference between them is not a
  confessional one — the Savoy Declaration *is* Westminster with Congregational
  revisions. The Savoy Platform is therefore correctly filed, not filed under
  Reformed for want of anywhere better.
* **Waldensian needs no row either**, for a less comfortable reason: it is
  grouped with Moravian and Hussite, and two of those three predate the
  Reformation and joined it rather than issuing from it. Filing them under
  Protestant records where they ended up, not where they began. Split them at
  the denomination tier.
* **`name` is load-bearing and was not touched.** Eleven ingesters and every
  `*_units.json` address traditions by name, and the app renders that string on
  citations and shelf headings, where the taxonomy's longer labels would not
  fit. Those went into a new `full_name` column. `build_traditions.py` asserts
  the slug set *and* the name set against the database and refuses to run if
  either would lose a row — a source pointing at a tradition the app cannot
  name raises nowhere, it just renders a blank citation.

### The shelf

Read now groups **branch → tradition**, ordered by the taxonomy rather than the
alphabet. Sorting by name put Adventist above Anglican and the Reformation
above Chalcedon, which is the shape of a list and not of a church.

Four decisions worth keeping:

* **Branches are labels, not disclosures.** The collapsed set is persisted as a
  list of *names*, and a branch can share its name with the only family inside
  it; making branches collapsible would mean collapsing "Eastern Orthodox"
  silently acts on both. Families stay the unit that opens and closes, so the
  stored arrangement needed no migration.
* **A branch heading is suppressed when it would only repeat itself.** Eastern
  Orthodox inside Eastern Orthodox says nothing twice. The family heading is
  the one kept, because it carries the count and the chevron.
* **Scripture's special case is gone.** It used to be hoisted out of
  alphabetical order by name; it is now the first family of the first branch
  and already sits directly under Pinned. Hoisting it again would move it out
  of the branch that explains why it is there.
* **The branch heading takes over the gap that preceded each family** rather
  than adding one of its own. The first version added about fifty vertical
  pixels per branch, which on a 320 px phone at the largest font size pushed
  the first family under the floating search bar — where `narrow_width_test`'s
  tap landed in the search field instead, and the failure read as a missing
  widget rather than as a layout cost.

**`corpusVersion` goes to 16, and that forces an app release.** The bundled
database gained a table, and a query joining a table that does not exist is an
error rather than a null — no amount of `COALESCE` makes the shelf survive an
older unpacked corpus. This is exactly what `corpusVersion` is for: the app
discards an installed copy whose stamp differs and unpacks the bundled one. The
packs themselves still install into any app on id space 1, which is unchanged,
because this build only appends.

### The ledger was watching 645 of 653 sources

Found while writing the phase above, and fixed the same day. `current_ledger`
grouped correctly — `GROUP BY s.id`, one row per source — and then filed each
row under `sources[url]`. Where several sources come from one document, the last
row overwrote the rest: four parts of the Summa, two of Brannan's confessions
and two of Schaff's were outside the check that decides whether a rebuild has
reassigned ids readers already hold. Nothing reported it, because a dictionary
that collapses keys does not raise — it just returns fewer entries than it was
handed.

Nothing was corrupted. Everything ingested that day landed above the previous
high-water mark of 178,840, so it could not have collided with anything. What
was missing was *detection*, and the failure it detects is the one this project
has already had once: vectors pointing at unrelated text, with every count and
checksum still correct.

Four decisions, of which only the first is the bug:

* **Key by `sources.id`, not by url.** It is the identity the packs and the
  reader's bookmarks already carry, so its stability was load-bearing anyway.
  Keying on it also lets the check see a fault it never could before — a
  *source* id reused for different content — and removes the reason a source
  had to have a url to be watched at all.
* **Version the ledger, and fail closed on a version it cannot read.** This is
  the part that made the fix landable rather than another entry in the
  known-issues list. Any repair changes the file's keys, and a format-1 baseline
  read by format-2 code makes every key look new, every settled source read as
  `occupied`, and the id space bump — which tells every reader to update the app
  for a build that changed nothing. **The check's failure mode on an
  unrecognised baseline has to be *stop*, never *bump*.** Crying wolf here is
  not a small cost; it is the whole cost the id space exists to avoid.
* **Migrate once, with the proof as the precondition.**
  `tools/migrate_id_ledger.py` rekeys and refuses to write unless the new ledger
  reproduces the old one exactly — the old entry for a url being whichever of
  its sources has the highest id, since that is the row `GROUP BY s.id` wrote
  last. It reproduced 645 of 645, every range, count and hash, and added the 8
  the url key could not hold. It also refuses if the corpus has moved since the
  ledger was written, because that would make it the invention of a baseline
  rather than the rekeying of one.
* **Count the entries against the corpus on every build.** Sources with units
  in, ledger entries out. One line, and it would have caught this the day it
  appeared. It survived months because nothing had ever compared those two
  numbers — which is the general lesson: a structure that silently loses
  elements needs a conservation check, not more careful code.

The six unmonitored sources sitting on settled ids were then verified against
what readers actually hold, rather than assumed: `f-aquinas.db.gz` and
`f-reformed.db.gz` from release `corpus-v17`, unpacked and compared source by
source. All six matched the live corpus exactly — range, count and text hash.
Writing them into the new baseline asserts that their ids have not moved, and
that assertion now has a witness instead of a shrug.

## Two empty families filled, and what the survey found in the rest (2026-08-30)

The taxonomy defined 31 families and the corpus held 13 of them. This closes two
— **Adventist** and **Holiness** — and, more usefully, replaces guesses about
the other fourteen with measurements.

### Picking them was not a judgement call

`TODO.md` and `SOURCES.md` both already named Adventist and Restorationist as
the next two, for a reason that was recorded and is unusual: almost every
tradition the corpus lacks is missing because its founding documents are in
copyright, and these two are missing because nobody had gone to fetch texts that
have been public domain for a century. Both were logged as *blocked on the
tradition rows, not on the texts* — and the taxonomy phase above unblocked them
the same day. Holiness came along because the survey found it, not because it
was planned.

### The survey, and why it was a survey

Eleven CCEL author slugs were probed one request at a time at the archive's
stated `Crawl-delay: 10`, and the result is worth more than the two ingests:

* **`white` — five works.** The Conflict of the Ages series minus its first
  volume, plus *Steps to Christ*. Adventist is a tradition with a foundational
  author, and this is that author rather than an account of the movement.
* **`finney` — eight, `smith_hw` — three, `upham` — one.** Enough for Holiness.
* **`palmer` has an author page with no works on it, and `booth` has no page at
  all.** So Phoebe Palmer and the Salvation Army are still unrepresented, and
  the pack description says so rather than letting Finney stand in for them.
* **`campbell` is the wrong Campbell** — J. M. Campbell, the Scot who wrote
  *The Nature of the Atonement* — and `acampbell` and `stone` have no page.
  Restorationist is not on CCEL, which is now recorded rather than assumed.
* **`hus`, `huss`, `zinzendorf`, `comenius`** — either no page or a page with no
  works. CCEL is not the route to anything Moravian or Hussite. That family
  needs a different archive, and knowing which archive *not* to try again is the
  point of doing this as a survey.

The rule the corpus already had — *nothing is hand-typed, work ids come off the
archive's own index* — is what made this cheap. The alternative is writing a
list of plausible ids from memory and discovering the shape of the archive one
404 at a time.

### Holiness is filed as its antecedents, deliberately

The Nazarene, Wesleyan, Free Methodist and Salvation Army standards are all
twentieth-century and in copyright. A public-domain corpus cannot represent this
family by its confessions the way it represents Lutheran or Reformed, so the
choice is between leaving it empty and holding the teaching its denominations
came out of. It holds the teaching, and every description says which it is.

One entry in it is a deliberate exception. **Wesley's *A Plain Account of
Christian Perfection* is filed Holiness, not Methodist**, while his *Sermons*
stay Methodist. Entire sanctification is the doctrine the family organised
itself around, and without the *Plain Account* the pack would be revival
preaching and devotional writing with no statement of the teaching that makes it
a family at all. The taxonomy already makes Holiness a child of Methodist, so
the two sit adjacent on the shelf rather than in unrelated places.

### Three defects the parse turned up, and what they teach

* **Every Ellen White export opens with a colophon**, not with the book: a
  title-page block followed by the White Estate's note on who keyed the e-text
  and where to write for a copy. It arrives as unit 1 because it sits below the
  title page and is long enough to clear the body-text floor, so five of the
  corpus's works would have opened on a note about e-text provenance. It is
  dropped — but read first, because it states the publication year, which the
  export's `Creator(s)` line does not: `parse_work` left White's date empty and
  the colophon supplies 1892, 1898, 1911, 1911 and 1917. **Front matter is not
  always only noise; sometimes it is the only place the metadata lives.**
* **CCEL spells the same author three ways.** "White, Ellen Gould" and "White,
  Ellen Gould Harmon"; Finney as "Charles", "Charles G." and "Charles
  Grandison". To anything that groups by author those are separate people, and
  the corpus already carries this defect for Spurgeon — who needs both his
  spellings listed in `packs.json` to stay inside one fragment. Canonicalised
  here, because it costs a line at ingest and a row rewrite afterwards.
* **CCEL's header misspells Fénelon as "Felon".** Corrected, and the correction
  is a typo fix rather than a retitling — which is the distinction that decides
  whether overriding an archive's metadata is honest.

### What it cost, and what it did not

16 works, 2,219 units, 11.25 M characters. Corpus to 669 sources and 482.5 M
characters; chunks and vectors to 456,396, of which **10,706 were new and only
those were embedded** — `--incremental`, which is the flag whose omission cost
136 minutes earlier in this phase. Packs to 47 fragments and 300.6 MB.

**No app release is required for any of it.** The id space stays 1 because the
build only appends, and the bundled core is byte-identical in size and content —
still the King James Version, seven branches and thirty-one traditions.
`corpusVersion` stays 16, which it needed anyway for the `branches` table. Two
new traditions reach readers as ordinary pack downloads, which is exactly what
the pack/core split was bought for.

### The Restorationist decision, deferred on evidence

*Declaration and Address of the Christian Association of Washington* is on
Wikisource at 160,942 characters, and it is a clean transcription. It is not
ingested, for two reasons that are about the document rather than about effort.
Wikisource tags it **not backed by a scanned copy** — nobody has proofread it
against a page image — and the rendered page carries **no headings at all**: the
Declaration, the Address, the thirteen Propositions and the Appendix run
together as one block. Every other ingester in this repository cuts units on
structure the document itself provides. Inferring boundaries from prose is a
different job with a different failure mode, and it should be started
deliberately rather than tacked onto a CCEL pass.

### The ingest uncovered a bigger thing: 60,000 units had never been tagged

`tag_units.py` is meant to be run after every ingest, and running it after this
one tagged **57,578 units that had nothing to do with this ingest**. The
Reformation and Baptist expansions — Calvin, Owen, Spurgeon, Matthew Henry,
Edwards, Gill — had gone in untagged. 88,237 of 105,677 units now carry a topic
tag; the 17,446 that remain match no keyword, which is a different and honest
outcome.

Tag search is one of the three engines fused in `searchForRAG`, so those works
had been retrievable lexically and semantically but not by subject. That is the
same defect this tool was written to fix once before, for the confessional
documents, and it recurred for the same reason: the tool is a separate step and
separate steps get skipped.

**It also silently falsified the pack coverage notice.** That notice compares
the tagged material a reader holds against the tagged material that exists, and
"exists" was being computed over the patristic corpus alone. The library claimed
5,042 units on grace when it had 28,505 and 304 on justification when it had
2,416. Every "you have most of what there is" was measured against a denominator
missing two thirds of the corpus.

Correcting the counts made `_missingShare = 0.5` fire on all ten test subjects
after a 108 MB install — the notice-nobody-reads failure the constant exists to
prevent. It is now **0.8**: the reader holds under a fifth of what has been
written on the subject they just asked. The constant's meaning did not change;
the denominator did.

A test caught this, and what it caught is worth stating precisely. `assert
warned < 3` after installing "the largest pack" had been true and became false
without any code changing, because the fixture named Church Fathers — largest by
*works*, 357 of them, and less than half the size of Reformed & Presbyterian in
text. **It only looked dominant while most of the corpus was uncounted.** The
fixture now names the pack that is actually largest, and a second test asserts
the opposite direction: a reader holding only the Fathers *should* be warned
about the Reformation subjects, so the threshold cannot be quietly raised until
the notice never fires at all.

## The corpus had been calling things copyrighted that were not (2026-08-30)

Prompted by a direct challenge to the claim, and the challenge was right. The
audit is in `SOURCES.md` under *The copyright audit*; this is what it changes.

### The error was a category error, and it was in a table

`SOURCES.md` carried a table dating each *movement* and inferring the status of
its *documents*. "Pentecostal, Nazarene | 20th c. | in copyright" reads like a
fact and is an inference, and the inference does not hold: a body founded in
1901 can have adopted its statement of faith in 1916, and 1916 is public domain.

Three findings follow, and the middle one is the one that matters:

* **Holiness is not a copyright problem at all.** The Salvation Army's eleven
  doctrines are 1878, Booth's *In Darkest England* 1890, the Free Methodist
  *Doctrines and Discipline* 1860 with 1915 and 1923 printings sitting on
  archive.org, the Nazarene *Manual* 1908. The pack shipped that morning
  describes the family as representable only through antecedents. That was true
  of what CCEL holds and false of what exists.
* **Pentecostalism is not structurally excluded.** The Assemblies of God
  *Statement of Fundamental Truths* is 1916 and the Foursquare *Declaration of
  Faith* is 1923 — the confessional documents of the two largest Trinitarian
  Pentecostal bodies, both public domain. `README.md` tells readers that
  Pentecostalism is absent and that "no better archive fixes it". The first half
  is true today; the second half is not true at all, and it is the sentence that
  most needed correcting, because this is the second-largest Christian movement
  in the world.
* **Post-Vatican II Catholicism really is closed.** Checked, not assumed. What
  is open and entirely absent is the pre-1931 magisterium — Vatican I, the
  Baltimore Catechism, every encyclical through 1930.

### The distinction that had collapsed

**"In copyright" and "no clean transcription" had been getting the same label**,
and they are opposites in the only way that matters: one has no remedy and the
other has three. The 1662 Prayer Book is the sharpest case. Its UK position is
genuinely unusual — perpetual Crown copyright through letters patent — but that
is a UK restriction on a text printed in 1662, and it does not reach a corpus
published in the US. It was never a rights problem. It is a transcription
problem, which is a queue this repository already knows how to work.

Everything now recorded as closed says which of the two it is.

### A constant that was right when written and wrong every January after

`PD_CUTOFF` was the literal `1929`. US copyright runs publication plus 95 years,
so the line moves on the first of January and the constant did not; by this
audit it was refusing two years of publishing for no reason. It is now
`date.today().year - 95`.

The objection to deriving it is reproducibility, and it is the wrong way round:
a work refused in 2025 and admitted in 2027 is not the tool being inconsistent,
it is the copyright expiring. Every source records the rights statement it was
admitted under, so any decision can be read back.

### What the re-check found, in one line

Fourteen works, public domain and located with identifiers, closing gaps in
seven families — including **an entire branch**. The Church of the East has no
sources at all, and Nestorius's own *Bazaar of Heracleides* has been sitting in
Driver and Hodgson's 1925 translation the whole time. Alexander Campbell's *The
Christian System* was recorded as "not found" after two archives were searched;
it is on the third. Peter Mogila's *Orthodox Confession* was **deleted from this
corpus as unprovenanced paraphrase**, and the real 1898 edition is available to
put back.

Rights are settled for all fourteen. Text quality is not: archive.org holds
scans and raw OCR, and this corpus refuses uncorrected OCR. The route in is the
two-witness method `ingest_owen.py` and `ingest_treasury.py` already use — a
clean transcription may stand in for a printing whenever it can be shown to *be*
that printing. So these are queued as work, not as downloads.

### The category still unexamined

US works published 1929–1963 lost copyright unless renewed, and most were never
renewed. Two candidates turn on it: the English *Rudder* (1957), the Orthodox
canonical collection, and Wenger's Schleitheim translation (1945) — the
Anabaptist founding confession, which `TODO.md` records as having no clean text
anywhere. Renewal is checkable per title in the Stanford Copyright Renewal
Database, which is behind a bot challenge and cannot be scripted from here.
It is a manual lookup, and nothing may be claimed on this basis until someone
does it.

## A Wikisource ingester, and what it brought (2026-08-30)

The tool `TODO.md` item 6b had been asking for. It was the right next thing for a
reason that has nothing to do with any one document: five works were already
*located* and waiting behind a fetch nobody had written, so the leverage was in
the fetcher rather than in another search.

What it landed: **Vatican I and thirty Leonine encyclicals** into a Catholic
tradition that held Aquinas, Trent and à Kempis and no papal magisterium at all,
and **the Dordrecht Confession and the complete works of Menno Simons** into an
Anabaptist tradition that was the *Martyrs Mirror* and nothing else — a
martyrology with no confession and no systematics, as its own pack description
had to keep admitting. 40 works, 525 units, 2.04 M characters.

### Wikisource states a work's licence once, on the work

`SOURCES.md` already recorded that Wikisource states its terms per page and that
the terms differ per page. What it did not record is where: **a multi-page work
carries its licence template on the root page, and every chapter under it
carries none.** The first implementation asked each chapter and got "no
public-domain category" for 44 of 46 pages — the two exceptions being the two
single-page works. Reading the chapter would have refused every multi-page work
in the archive.

The rights gate is a category match rather than a guess, and the category is
recorded verbatim on each source, so a reader can see which claim admitted the
work — `PD-old`, `PD-anon-US`, `PD-US`.

### Three parsing defects, and the same lesson under each

* **Headings were being dropped.** The first version read only `<p>` elements,
  and the Dordrecht Confession states each of its eighteen articles as an
  `<h2>`. It arrived as five untitled runs of prose — a confession with no
  articles. Reading the headings gives nineteen units, each named. The rule the
  corpus already had is *cut where the document says its sections begin*, and
  this was throwing away the document saying so.
* **`<style>` blocks live inside the content and read as text.** Strip tags
  naively and every document ends with `.wst-smallrefs{font-size:83%...}` as a
  closing paragraph. Elements are removed before tags are.
* **The scans' line wrapping survived inside paragraphs** — 9,689 breaks — so
  units would have wrapped where a Victorian compositor wrapped. Collapsed;
  paragraph boundaries survive because they are `<p>` elements, not newlines.

### The size floor was the gate making the error it exists to prevent

`MIN_PAGE_CHARS` was set to 2,000 to catch the failure this tool was written
for: Wikimedia answers a throttled request with HTML, and HTML parses as *a page
with no text* rather than as an error. At 2,000 it refused six of the Vatican
decrees' fourteen chapters, which are 900–1,900 characters because **a conciliar
chapter is short**. The gate was mistaking a brief document for a failed fetch,
which is its own failure mode pointed backwards.

It is now 200, and throttling is caught where it actually shows: `json.loads`
raises on an HTML body, so `api` retries and returns None. Catch the failure at
the point where it is unambiguous, not by a proxy that a legitimate document can
trip.

### The documents were asked what they are called

The Benziger collection titles the encyclicals in English — "The Condition of
the Working Classes" — and nobody searches for that. Each opens with its own
dateline, "Encyclical Letter Rerum Novarum, May 15, 1891", so the Latin incipit
and the year are parsed out of the text rather than typed in: *Rerum Novarum*,
*Æterni Patris*, *Immortale Dei*, *Providentissimus Deus*, *Satis Cognitum*,
*Apostolicæ Curæ*. Twenty-two of the thirty carry a date the record would
otherwise not have had.

The Vatican decrees needed the reverse fix. They set a chapter's number and its
subject as separate lines, and only the number reads as a heading, so twelve
chapters arrived titled "I", "II", "III", "IV" across three constitutions —
twelve units with four names between them. A unit titled only by a numeral now
takes the short line printed under it, which is how
"IV. Concerning the Infallible Teaching of the Roman Pontiff" gets its name.

### Transcription quality was measured, and the first measurement was wrong

These are transcriptions of scans, and this corpus refuses raw OCR:
`ingest_gutenberg.py` records archive.org's OCR of this material at about one
error per hundred characters. So the question had to be answered with a number.

**The first attempt at a number was useless and worth recording as such.**
Counting words absent from `/usr/share/dict/words` gave 483–586 per 10,000 for
the new material — and 568 for Calvin's *Institutes*, 724 for *The Great
Controversy*, and **923 for the Westminster Confession**, all of which are
already in the corpus. The dictionary has no inflections, so "called", "having"
and "duties" all count as misses and the measure cannot tell a scanning error
from an ordinary English word. What it does say, and this is worth keeping, is
that **the new texts score no worse than what the corpus already ships.**

The measure that discriminates is narrower: the residue of two specific scanner
failures visible in this material — the "li" ligature read as "h" (*hght* for
light, *pubhc* for public) and "it"/"th" read as "d" (*wdth* for with). Both
produce non-words, so a hit is a hit. Measured: **Leo XIII 4.3 per 10,000 words,
Menno Simons 0.1, Dordrecht and the Vatican decrees 0.0** — against roughly 580
for the raw OCR this project already refused.

It is a floor rather than the true rate, and the code says so: a scanner that
turns "modern" into "modem" produces a real word this will never see. It is
still the right thing to gate on, because it can be checked rather than
asserted. Every source carries its own measurement in `notes`, so a reader who
finds a mangled word can see that the transcription was checked and how far.

### Taking the whole collection rather than the famous parts

Twenty-two of Leo XIII's thirty subpages are the encyclicals anyone would name.
The rest are occasional letters — on the Philippines, on Columbus, to the
American hierarchy. All thirty are taken, because curating the others out would
be an editorial judgement about what Leo XIII "really" wrote, and the collection
is the thing that was published. The work ids came off Wikisource's own index,
which is the same rule `survey_ccel.py` exists to enforce.

Two pages were dropped and both for stated reasons: "The Education of Children"
renders as twelve characters — the page exists and the transcription does not —
and the earlier list carried "The Christian Constitution of States" twice.

## The Church of the East, and what it cost to open the seventh branch (2026-08-30)

The taxonomy has defined seven branches since the day it was written, and this
one has had nothing in it. It is now open — six of the seven branches hold text,
and the seventh is *Other and Independent*, whose families are all
twentieth-century bodies.

### The queue said "scans". The queue was out of date by one tool

The copyright audit had filed this branch under archive.org identifiers —
Driver and Hodgson's 1925 *Bazaar of Heracleides*, Badger's *Nestorians and
their Rituals* — with a note that it needed the two-witness route because
archive.org holds scans and raw OCR. That was true when it was written and
stopped being true the moment `ingest_wikisource.py` existed: **English
Wikisource has Badger's volume II fully transcribed**, 34 pages, every one of
them `PD-old`. It went in as proofread text and the OCR problem never arose.

The lesson is about the queue rather than about Badger. A "how" recorded
alongside a "what" goes stale silently — the work item still names the right
book and the wrong route, and nobody re-checks a route that is written down as
settled.

### What was checked before ingesting anything

* **The Liturgy of Addai and Mari is already in the app.** The East Syriac rite
  is in the corpus as *The Liturgy of the Blessed Apostles*, ingested with the
  Ante-Nicene Fathers and filed under **Early Church**. So the branch read empty
  while the app held that church's liturgy.

  **It was deliberately not re-filed**, and the reason is a hazard worth
  recording: moving a source between traditions moves it between *fragments*,
  and fragments are only guaranteed disjoint **within one build**. A reader
  holding `f-fathers-rest` from an earlier release already has those unit ids;
  a new `f-assyrian` carrying the same source would collide on primary key
  halfway through the install. Re-filing an existing source is therefore not a
  metadata edit — it is an id-space event, and it costs an id-space bump.
* **The Doctrine of Addai stays withdrawn.** It is in the New Advent manifest
  and was withdrawn on 2026-08-01 as New Testament apocrypha. That decision was
  found and left alone rather than quietly reversed to pad a thin branch.
* **Abdisho's *Marganitha*** — the Book of the Pearl, this church's own
  doctrinal manual and the thing that ought to be here — has a Wikisource page
  that is **1,028 characters of stub**. Measured, not assumed.

### What went in, and the caveat that travels with it

Badger's volume II is **not a Church of the East document**. He was an East
India Company chaplain, and the volume is an Anglican's examination of the
church's doctrine in which the chapters are mapped onto the Thirty-Nine
Articles — "the doctrine of our Article held by the Nestorians". What makes it
worth having anyway is what he builds it out of: long translated quotations from
that church's own service books — the Khudhra, the Gezza, the Warda, the
Khâmees, the Sinhadòs — and from Abdisho bar Berika, whose creed he gives in
full. Counted in the ingested text: 61 quotations attributed to the Khudhra, 24
to Abdisho, 23 to the Warda, 19 to the Gezza.

It is a documentary anthology inside a frame. **The frame is disclosed on the
source and in the pack description**, because a reader who quotes it should know
whose arrangement they are quoting. Volume I — a missionary travel narrative
through Mesopotamia and Kurdistan with an inquiry into the Yezidis attached — is
deliberately absent; none of it is theology. Wikisource's transcription of
volume II is partial, and the note says which chapters are missing.

### A concatenated book needs to know which page it came from

Multi-page works are joined before they are cut into units, and until now the
page was forgotten in the joining. Badger sets "quotations, then REMARKS." in
every chapter, so **twenty units arrived titled `REMARKS.` and nothing else** —
a table of contents with twenty identical entries, and citations that cannot say
where they point. Seven more said `THE ANAPHORA.`

Units now carry the page's own label: `Chapter 13 — REMARKS.`,
`Appendix B — Part 5 — CHAPTER V.` A single-page work gets no label, because
the source title already says where the unit is.

That change then broke Vatican I, which is the useful part of the story. Its
chapters are numbered on one line and named on the next, and a rule added
earlier promoted the name into a numeral-only title. Prefixing the page label
made the title no longer numeral-only, so the promotion stopped firing and
`I. Of God the Creator of all things` reverted to `Part 1 — Chapter 1 — I`. The
fix is ordering: **promote the name first, then add the label.** A heading rule
that inspects the title has to run before anything else edits the title.

The same pass drops a heading left dangling on a function word — the
heading-chaining had glued a title page into `THE NESTORIANS — AND`, which is
not a section name. Where that happens the page label stands alone.

### A documentation audit, because four ingests in one day outrun the prose

Run after the Church of the East landed, against the database rather than by
reading. The counts in `TODO.md`'s header and `README.md`'s collection table
were correct — every one of the sixteen table rows matched the manifest — and
the errors were all of one kind: **claims written in the present tense that
were true when written and were overtaken by a later ingest the same day.**

* The *Found by survey* table still described the Dordrecht Confession, Menno
  Simons and the Vatican decrees as located-but-not-ingested, hours after all
  three went in.
* Two entries still said Schleitheim, Dordrecht and Menno Simons had no
  proofread transcription anywhere. That had been written after searching
  Gutenberg and CCEL alone, and two of the three were on Wikisource.
* Three section headings in `SOURCES.md` stated past conditions as present
  facts — "Baptist — a defined tradition with nothing in it", when Baptist is
  82 sources and the second-largest tradition in the corpus; "Eastern
  Orthodox — 0.004 M characters", when it is 0.575 M.
* Two live figures had been overtaken: the tag-coverage ratio and the vector
  count in the publishing checklist's `--incremental` warning.

**Dated phase notes were deliberately left alone.** The ones in this file say
653 sources, 47 fragments, 456,396 chunks, and they should: a phase note is a
record of a build, and rewriting its numbers to match today would destroy the
only account of what each change actually cost.

The distinction is the thing worth keeping. **A history keeps its numbers; a
ledger has to be re-checked against the database.** `TODO.md` and the priority
plan in `SOURCES.md` are ledgers and were audited against `theology.db`;
`PLAN.md` is a history and was not touched.

## Three more families, and the near miss that changed the ingester (2026-08-30)

Restorationist, Moravian & Hussite, and Old Catholic. **All seven branches now
hold text**, and 19 of the 31 families do.

### What went in

* **Restorationist** — Thomas Campbell's *Declaration and Address* (1809) and
  the *Last Will and Testament of the Springfield Presbytery* (1804). The
  Stone-Campbell movement's two founding documents, for a family that had
  nothing.
* **Moravian & Hussite** — Hus's *De Ecclesia*, the treatise he was burned for,
  in David S. Schaff's 1915 translation; and Comenius's *Labyrinth of the World
  and the Paradise of the Heart*, by the last bishop of the Unity of the
  Brethren, which is the Moravian Church's own predecessor. 23 and 54 chapters,
  both confirmed complete against Wikisource's index rather than assumed.
* **Old Catholic** — the *Declaration of Utrecht* (1889), short and entire. It
  rejects the Vatican decrees of 1870, which this corpus now also holds in full
  from the same archive.

### The near miss

Wikisource has a page titled exactly **`The Christian System`**. Alexander
Campbell's book of that name is the Restoration movement's systematic
statement, and `SOURCES.md` and `TODO.md` both recorded it as searched-for and
not found. Finding a page with the exact title looked like the record being
wrong.

The page is an essay by **Arthur Schopenhauer**, translated by Thomas Bailey
Saunders, from *Studies in Pessimism*.

It fetched cleanly. It carried a valid public-domain licence category. It passed
the page-size floor, the work-size floor and the transcription-quality gate, and
it parsed into three tidy units of nineteenth-century prose about religion and
reason. **Every automatic check this module had was about whether the text was
good, and not one was about whether it was the right text.** It was caught by
reading a sentence of it.

The generalisable error is the one worth naming: **a title match is not
identification**, and a search that fails is evidence about the query, not about
the archive. The old record was right and the attempt to overturn it was wrong.

### The gate that now makes it hard to repeat

Wikisource states the author in its header template, as a field in the wikitext.
So the ingester fetches each work's root wikitext, reads the declared author,
and refuses any work whose claimed author the archive does not corroborate.

Getting the comparison right took two attempts, and the first failure is
instructive. Matching on the *longest* word of the claimed name refused all
thirty Leonine encyclicals — "Pope Leo XIII" has no long word in it, so the rule
picked "Pope". The rule now compares the **last** name-word after honorifics are
stripped: last rather than longest because of regnal names, and last rather than
*any* because "Thomas Campbell" and "Thomas Aquinas" share a forename and a
match on a shared forename is not identification either. Ten cases are asserted
in the module, including the one it was written for.

A work may still be filed under a name the archive does not use — the
Springfield Presbytery document is cited by Barton Stone's name and attributed
by Wikisource to the presbytery as a body — but only through an explicit
`author_override` carrying the reason.

### A regex that could not do what it was asked

Hus's *De Ecclesia* opened with "1915 translation of the 1413 treatise ... played
an important role in his trial at Constance" — Wikisource describing the work,
not Hus writing it. The furniture-removal regex used `.*?</div>`, and a
non-greedy match stops at the **first** closing tag: for a container with nested
divs it removes the opening tag and leaves the contents. The header wraps its
editorial note one level deep, so the note survived.

Fixed by finding the closing tag through depth counting instead. It is the sort
of defect that only shows up on the one work whose header happens to carry a
`notes` field, which is why it survived three ingests through the same code.

## Pentecostal, the family this project told readers was impossible (2026-08-30)

The second-largest Christian movement in the world, and until the copyright
audit `README.md` said its documents were all in copyright and "no better
archive fixes it". The audit established that was wrong. Working the family
established something more precise: **the rights were never the problem, and the
transcription always was.**

### What is not there, checked rather than assumed

Every document the audit named as the obvious target is absent from archive.org
entirely: the **Assemblies of God Statement of Fundamental Truths** (1916), the
**Foursquare Declaration of Faith** (1923), the **Azusa Street *Apostolic
Faith*** periodical, **Parham**, **Seymour**. Searching for the AG Statement
returns commentaries on it from 1948 and 1971, both lending-only. So the
canonical list of Pentecostal founding documents is public domain and, for the
most part, not digitised.

**An item on archive.org is not necessarily readable**, and that had to be
built into the tool. Much of the twentieth century there is lending-only: the
scan exists, the catalogue entry is public, and the text cannot be downloaded.
It is flagged as `access-restricted-item`, and the ingester checks it rather
than inferring availability from a search hit.

### Aimee Semple McPherson, measured and refused

Three independent scans of *This Is That* (1923) are open — different scanning
stations, different years, different sponsors. That is the ideal two-witness
setup, so it was measured properly: aligning two independent OCR passes of the
same edition word by word gives **373 disagreements per 10,000 words of body
prose**, and 326 for her *Divine Healing Sermons*. Not punctuation — "soul"
read as "seul", "sanctified" as "sanetified", "she" as "sihe", "was" as "wa".

That is the same order as the raw OCR `ingest_gutenberg.py` already refuses
(~580 per 10,000) and eighty times worse than the Wikisource material ingested
earlier the same day (4.3). **Refused**, and the number is recorded so nobody
re-litigates it from the fact that the book is public domain and available.

An 840-page book scans badly. That turned out to be the whole story.

### What worked: a 38-page pamphlet and a 158-page manual

Duke University digitised 33 pre-1931 items from Pentecostal bodies for its
*Religion in North Carolina* project, and short documents in clear type scan
well. Two went in:

* **The Discipline of the Pentecostal Holiness Church (1917).** Section I is the
  Basis of Union — justification by faith, entire sanctification as an
  instantaneous second work of grace, the Pentecostal baptism of the Holy Ghost
  with speaking in tongues as its initial evidence, divine healing in the
  atonement, the premillennial second coming. **Zero countable scanner artefacts
  in 6,554 words.**
* **The Book of Doctrines (Church of God, Cleveland, 1922)** — a full doctrinal
  manual: the Bible, sin, repentance, justification, sanctification, Spirit
  baptism, water baptism, the Lord's Supper, feet washing, tithing, healing,
  and the church practices. 3.9 artefacts per 10,000 words.

### Two witnesses, scoped to what the two witnesses share

The Pentecostal Holiness Church printed its Basis of Union twice — in the
*Constitution and General Rules* of 1913 and again in the *Discipline* of 1917 —
and the two were scanned separately. That is scan-against-scan corroboration,
which is `ingest_owen.py`'s standard applied where neither witness is a clean
transcription.

**The first attempt compared the volumes whole and scored 52%, and the gate
correctly refused the work.** The refusal was right and the comparison was
wrong: the two are different documents that happen to share one section, so
comparing them entire measures how much the *governance* differs, not whether
the *doctrine* is transcribed correctly. Scoped to the passage both actually
print, they agree on **94% of words — and every disagreement is the 1913 scan
being wrong**: "there generation" for "the regeneration", "tlie" for "the",
"ivord" for "Lord", "chr st" for "Christ", "sm" for "sin".

So the 1917 scan is what ships, the 1913 is the witness that proves it, and the
1913 is refused *as a source* by the same artefact gate — 47.4 per 10,000
against the 1917's zero. The corroboration note on the source says which passage
was checked and which was not.

### Three defects that only scans have

* **A contents page is not a chapter.** "The Bible Is Truth" appears twice — in
  the table of contents with its page number, and as the chapter heading. Taking
  the first match opened the book on its own contents page, which is precisely
  what `audit_completeness.py` exists to catch. Matched on the whole paragraph
  instead: the contents entry carries a page number and the heading does not.
* **The running head is re-OCR'd on every page.** "THE BOOK OF DOCTRINES 7"
  appears once per leaf — short, capitalised, punctuation-free, exactly what a
  heading detector wants — and became the title of most of the book's units. An
  exact filter removed two thirds of them, because the head comes back as "THE
  BOOK OF DOCTEINES" and "THE BOOK OP DOCTRINES" as often as correctly. Matched
  by similarity, with the threshold pinned by this book's own chapter "THE BOOK
  OF GENESIS" at 0.65 against the misreadings at 0.94.
* **A book's own contents is the only statement of its structure.**
  `ingest_reformation.is_headingish` was tuned on CCEL, where headings read
  "CHAPTER I", and returns False for "Sanctification", "Repentance" and "Feet
  Washing" alike. Without the chapter list the volume was cut arbitrarily and
  units were titled "THE BOOK OP GENESIS (5 of 8)" over text that is not about
  Genesis. The chapters are now taken from the printed contents and matched
  fuzzily, so a unit is titled as the book titles it rather than as the scanner
  read it.

### What the family still lacks, stated plainly

The two largest Pentecostal bodies — the Assemblies of God and the Foursquare
Church — are still unrepresented, and not because their founding documents are
closed. They are public domain and nobody has digitised them. That is a
different sentence from the one this project used to print, and it points at a
different remedy.

## Brethren, which was never a rights problem or a transcription problem (2026-08-30)

The last family with genuinely public-domain founding documents and nothing in
the corpus. Pentecostal turned out to be a digitisation problem. This one was
only ever a **search** problem: Project Gutenberg has seventeen Brethren works
as proofread transcriptions, and three earlier surveys missed them.

**Why they were missed is worth keeping.** The surveys asked CCEL (which has a
`darby` author page whose one work has no text export) and archive.org (whose
Darby is lending-only), and when they did ask Gutenberg they asked for *Darby* —
the movement's central figure, and the one Brethren author Gutenberg does not
have. Searching for the most important name in a movement is a reasonable first
move and a bad only move.

What Gutenberg has instead is **C. H. Mackintosh's complete *Notes on the
Pentateuch*** — six volumes, and the work his name is shorthand for — with six
volumes of his *Miscellaneous Writings*, **George Müller's *Narrative*** in all
four parts, and **Anthony Norris Groves's *Christian Devotedness*** of 1825, the
tract on holding no reserve of wealth that is as close as the movement has to a
founding document. 17 works, 2,059 units, 8.95 M characters — the largest single
ingest since the Reformation expansion.

### A separate units file, and the reason is the id space

`gutenberg_units.json` holds the Book of Concord, ingested long ago at unit ids
far below the last published high-water mark. `load_ccel.py` replaces by title,
so regenerating that file and re-loading it would delete and reinsert the
Augsburg Confession at fresh ids — **a settled source moving, which is exactly
the fault `check_id_space` exists to catch.** It would bump the id space and
force every reader to update the app for nothing.

So the Brethren works are written to their own file and touch nobody else's
rows. The general rule this session has now hit twice: *reusing an ingester's
code is free; reusing its units file is an id-space event.*

### Refusing to hand-type a date

Every work here was going to carry a publication year I had typed from memory —
1880 for the *Notes*, 1898 for the *Miscellaneous Writings*, 1837 for Müller's
first part. Checking the sources showed **Gutenberg's header states only the
ebook's release date**, and Müller's *Narrative* is a journal whose opening
pages are thick with years that are diary entries rather than imprints.

So the dates were removed. These works now carry the author's life dates —
"1820-1896" for Mackintosh — which is how the corpus already files its CCEL
works, and which is verifiable. The single exception is *Christian Devotedness*,
whose own closing note reads "The first edition ... was published by Hatchard
1825", and 1825 is therefore sourced rather than remembered.

A guess on a citation is indistinguishable from a fact on a citation. That is
the whole reason this corpus records provenance per source.

### Two small archive habits

Gutenberg's **older files sign off in prose** — "End of Project Gutenberg's
Notes on the Book of Leviticus, by C. H. Mackintosh" — *before* the `***` marker
that `ingest_gutenberg.body_of` cuts at, so the sign-off survived into the final
unit of two works. And they **open with the volunteer's credit**, which put
"Produced by David Haslam" at the head of Groves's tract. Both are stripped.

### What the family still lacks, and it is two different absences

**J. N. Darby is not here**, and he is the movement's central figure — the man
dispensationalism is named after. Gutenberg has none of him and archive.org's
*Collected Writings* are lending-only. That is a digitisation gap of the
Pentecostal kind, not a rights one.

**The Church of the Brethren is not here either**, and this is a different
problem: the taxonomy files two unrelated bodies under one name. The Dunkers are
Anabaptist-Pietist German immigrants with no connection to Plymouth beyond the
word "Brethren", and Alexander Mack's *Rights and Ordinances* is not digitised
anywhere found. The pack description says which of the two it holds, because a
reader who installs "Brethren" expecting Mack would otherwise find Mackintosh.
