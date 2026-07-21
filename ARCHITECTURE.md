# Council — Architecture Assessment

Written 2026-07-21, after the corpus rebuild. Numbers here are measured against
the current 95 MB / 18,231-unit corpus, not estimated.

The goal: an installable app on phone *and* computer, holding the writings and
council statements of every major branch of Christianity, where the user asks a
question and gets a short synopsis backed by several real sources.

That goal is achievable, but one part of the current design cannot survive
contact with a phone.

---

## 1. The blocker: Ollama is not a mobile runtime

`OllamaService` talks to `http://localhost:11434`. On macOS that is a server the
user installed. **On iOS and Android there is no such server and cannot be one** —
Ollama has no mobile build, and neither platform lets an app ship a background
inference daemon on that port.

So today the app is: a working offline library on desktop, with AI; and on
mobile, a library with a permanently dead chat tab.

Everything else in this document is tractable engineering. This is the one
decision that changes the shape of the project, and it has to be made before
mobile work starts. Options in §6.

## 2. Platform reality

Only `macos/` and `web/` exist. `android/`, `ios/`, `windows/`, `linux/` have
never been generated (`flutter create --platforms=...` adds them).

| Target | UI | SQLite | LLM | Verdict |
|---|---|---|---|---|
| macOS | ✅ | ✅ | ✅ Ollama | Works today |
| Windows / Linux | ✅ | ✅ | ✅ Ollama | Just needs the platform folders |
| iOS / Android | ✅ | ✅ | ❌ no Ollama | Needs a different inference path |
| Web | ✅ | ❌ | ❌ | **Does not actually work** |

The web caveat is worth stating plainly: `sqflite` ships `sqflite_android` and
`sqflite_darwin` implementations and **no web implementation**. The web target
compiles — which is why it was recorded as "working" — but `DatabaseService.
initialize()` throws at runtime. Making web real means a second storage backend
(`sqflite_common_ffi_web` or `drift`) and shipping sql.js/WASM. Recommend
dropping web as a target unless it earns its keep.

## 3. How many sources can the database hold?

**SQLite is not the constraint, and neither is search.** Measured on the current
95 MB corpus:

- FTS5 lookups: **under 10 ms**, including the join to sources and rank ordering
- SQLite's own ceiling is terabytes; a 1 GB corpus on a phone is unremarkable
- The FTS index costs roughly 25% on top of the text

The real constraints are distribution and device storage:

| | size |
|---|---|
| Corpus, uncompressed | 95 MB |
| Shipped asset (gzip) | 39 MB |
| On device after first launch | ~134 MB (bundle + decompressed copy) |

Both app stores accept that comfortably. Extrapolating, a corpus of **300–500 MB
decompressed** — roughly 5× today, on the order of 100,000 units — stays within
sane download and storage budgets if delivered well (§6).

For context on what is left to ingest: the entire Book of Concord, Calvin's
*Institutes*, the Westminster Standards and Wesley's sermons together are a few
MB of text. **The Church Fathers were the big one.** Full denominational
coverage is not going to blow the budget; it roughly doubles the corpus, not 10×.

So: sources are effectively unlimited for this project's purposes. Stop worrying
about corpus size and worry about retrieval quality.

## 4. Can the LLM parse through them?

No — and it never should. The model does not see the corpus. It sees whatever
retrieval hands it, which today is 5 passages truncated to 1,500 characters:

**~2,715 characters ≈ 700 tokens per question.**

That is *tiny*. Even a 1B model with a 4k window has room to spare. The current
design leaves most of the budget unused; 6–10 passages at 2,000 characters would
still fit a 8k-token context comfortably and would give noticeably better
answers.

The corpus size is irrelevant to the model. **Retrieval quality is the whole
game**, and that is where the actual problems are.

## 5. Retrieval: speed is solved, quality is not

Three concrete defects:

**a) Search is lexical, not semantic.** FTS5 matches words. "How is a person
saved?" does not match "justification by faith" — no shared terms. The current
mitigation is a hand-written map of 36 phrases onto 21 tags, which is a patch
over a missing capability, not a solution.

The fix is embeddings, and the arithmetic is friendly:

| representation | size for 18,231 units |
|---|---|
| float32, 384-dim | 26 MB |
| int8 quantized, 384-dim | **6 MB** |

Precompute at build time and ship them. Query-time embedding needs a small model
on device (~25–90 MB for a MiniLM/bge-small class ONNX model), or Ollama's
embedding endpoint on desktop. Then combine BM25 rank from FTS5 with cosine
similarity and fuse the two rankings. This is the single biggest quality win
available and it is cheap.

**b) Chunks are the wrong size for retrieval.** Units average 3,153 characters,
but **1,431 units exceed 6,000 characters and the largest is 162,014** (the
"Faith" section of Augustine's *Enchiridion*). **15 MB of the corpus sits in
units too big to retrieve meaningfully** — the model gets the first 1,500
characters and the rest is invisible, and a single embedding cannot represent a
162k-character span.

These need a retrieval-level split: keep the display unit intact, but index
overlapping ~1,000-character windows underneath it, each pointing back to its
parent. Retrieve windows, cite and display parents.

**c) Nothing measures whether retrieval works.** There is no evaluation set. A
few dozen questions with known-good expected sources would let any retrieval
change be judged instead of guessed at.

## 6. Making it work logistically

### Inference strategy — decided 2026-07-21

The user picks their backend. No model is ever downloaded for this app alone.

| Backend | Platforms | Offline | Notes |
|---|---|---|---|
| **Retrieval-only** | all | ✅ | The floor. Full library, no AI. |
| **Bring your own API key** | all | ❌ | Claude, OpenAI, Gemini, Grok |
| **Ollama (local or LAN/VPN)** | all | ✅ | Host is user-configurable |
| **Apple Foundation Models** | iOS/macOS 26+ | ✅ | Apple Intelligence hardware only |
| **Gemini Nano (ML Kit)** | Android | ✅ | Flagship chip, 12 GB+ RAM |

Deliberately excluded: shipping a dedicated LLM with the app. A 4-bit 1–3B model
is 0.7–2 GB, and would be both larger and worse than any option above.

**The two platform backends are a bonus tier, not a baseline.** Apple's requires
an iPhone 15 Pro or later or an M-series Mac; Gemini Nano requires a flagship
chip with 12 GB+ RAM. Most devices in circulation qualify for neither, so
retrieval-only and BYO-key are the paths that must always work. Both platform
backends also need native platform-channel bridges (Swift and Kotlin), adding
native code to what is currently pure Dart.

Consequences that fall out of supporting all five:

- **Context budget is per-backend.** Apple FM and Gemini Nano have small windows;
  Claude and GPT have very large ones. The current fixed 5 passages × 1,500
  characters is simultaneously far too small for cloud and possibly too large
  for Nano. `contextBudgetChars` belongs on the backend interface.
- **API keys go in the Keychain/Keystore** via `flutter_secure_storage`, never in
  `shared_preferences` where the other settings live.
- **The privacy claim becomes conditional.** The chat dialog currently asserts
  "All processing happens locally / No data sent to cloud". That is false with a
  cloud key active, and must be stated per-backend.
- **LAN Ollama needs platform work on mobile.** iOS App Transport Security
  rejects cleartext HTTP and iOS 14+ requires `NSLocalNetworkUsageDescription`;
  Android needs a cleartext-traffic policy.

### Semantic search — decided 2026-07-21

Semantic search needs an *embedding* model, not an LLM — a different and far
smaller thing. The binding constraint is that **document and query embeddings
must come from the same model**: vector spaces are not interchangeable, so
"embed with whatever backend the user chose" cannot work.

Therefore a single small embedding model (~25 MB, quantized MiniLM/bge-small
class, ONNX) ships with the app, with corpus vectors precomputed at build time
(**6 MB at int8 for 18,231 units**). Only the query is embedded at runtime.

This keeps semantic search identical on every device, requires no API key and no
LLM, and means **retrieval-only users keep it** rather than losing it. Retrieval
then fuses BM25 rank from FTS5 with cosine similarity.

### Corpus delivery

Bundling everything stops scaling once denominational packs land. Better:

- ship a **core corpus** in the app (creeds, councils, a patristic selection)
- offer **downloadable packs per tradition** (Lutheran, Reformed, Orthodox…)
- version them, so corpus updates do not require an app release

This also solves the licensing problem cleanly: packs whose texts are not freely
redistributable simply are not offered.

### Updates and correctness

- `corpusVersion` already forces reinstall when the bundled DB changes; extend
  it to per-pack versions
- keep `tools/audit_corpus.py` in the loop — any newly ingested pack gets
  audited before shipping
- provenance (`source_url`, translator, licence) stays mandatory per §rules in
  PLAN.md

---

## Summary of what to do next

1. **Decide the inference strategy** (§6) — blocks all mobile work.
2. **Abstract inference behind an interface** — small, unblocks everything else.
3. **Generate `ios/` and `android/`**; drop or properly implement web.
4. **Add retrieval-level chunking** — 15 MB of corpus is currently unreachable.
5. **Add embeddings + hybrid ranking** — 6 MB int8, biggest quality win.
6. **Build a retrieval evaluation set** so 4 and 5 can be measured.
7. **Raise the RAG budget** from ~700 tokens; it is far below what any model can take.
