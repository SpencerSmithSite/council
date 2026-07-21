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

- [ ] **Add a `provenance` column to `content_units`**
  Values: `primary_text` | `summary` | `boilerplate` | `unknown`.
  Requires a DB rebuild step (the bundled DB opens read-only).

- [ ] **Delete scraper boilerplate** (18 units, incl. `title = "About this page"`)

- [ ] **De-duplicate** the 187 duplicate `content_plain` values.

- [ ] **Purge or quarantine generated filler**
  Either drop the templated units or mark them `summary` and exclude them from
  RAG retrieval.

- [ ] **Label provenance in the UI**
  A passage the model paraphrased must never look like the creed itself. Badge
  non-primary units in detail, search results, and citations.

- [ ] **Exclude non-primary units from RAG retrieval** — `searchForRAG`

- [ ] **Populate `authors` and `works`** (both tables currently have **0 rows**)
  Only 12 of 523 sources have an author at all. Blocks the README's headline use
  case ("What did Augustine say about grace?").

- [ ] **Fix 71 orphaned content units** — their `source_id` matches no row in
  `sources`. They're already invisible to search (which inner-joins) and to
  random passage; `getContentUnit` left-joins so they at least still open.
  Either repair the FK or delete them.

- [ ] **Populate `source_url`** (currently **0 of 523**)
  Needed for provenance and to substantiate the `public_domain` / `license`
  claims already in the schema.

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
