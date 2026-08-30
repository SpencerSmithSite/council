# Council

An offline-first Flutter app for Christian theology research. Browse a curated library of primary sources, search with full-text search, and ask theological questions with AI-powered answers grounded in the texts — all running locally on your device.

![Council home screen](screenshots/home.png)

## What it does

Council ships with the King James Version — 1,189 chapters — and everything else is downloaded on request, starting with the creeds, councils, catechisms and confessions. That keeps the install small while the full library runs to **687 works and 460 million characters**.

Bundled: the King James Version, complete.

First download — **Creeds & Confessions**, 8.9 MB:

- Ecumenical creeds and councils — the acts themselves, not summaries: the
  creeds, canons and synodal letters of all seven ecumenical councils and
  eleven local synods, plus Trent's canons and decrees
- Confessions and catechisms (Augsburg, Westminster, Heidelberg, Dort, the
  Thirty-Nine Articles, both London Baptist confessions)
- Lutheran, Reformed, Catholic, Anglican, Baptist, Methodist and Eastern
  Orthodox standards

Downloadable from **Settings → Library**:

| Collection | Works | Download |
|---|---|---|
| Creeds & Confessions | 53 | 8.9 MB |
| Eastern Orthodox | 74 | 11.8 MB |
| Augustine of Hippo | 48 | 12.9 MB |
| John Owen | 31 | 13.6 MB |
| Matthew Henry | 6 | 23.9 MB |
| John Calvin | 48 | 29.4 MB |
| Church Fathers | 402 | 51.0 MB |
| Charles Spurgeon | 74 | 92.3 MB |

Thirty-one collections over forty-three shared fragments, 285 MB published in
all. The same collections as standalone files would be 568 MB — no work is
downloaded twice, however many collections it belongs to, which is why the
big authors have a fragment each rather than sitting inside their tradition's.

The full library spans:

- Early Church Fathers (Athanasius, Augustine, Chrysostom, Origen, and more)
- Medieval scholastics (Aquinas)
- Reformation (Calvin's *Institutes* and commentaries, Luther, Knox)
- Puritan and Reformed (John Owen's complete works, Edwards, Baxter, Manton,
  Watson, Flavel, Charnock, Matthew Henry's commentary, Hodge's *Systematic
  Theology*)
- Baptist (Spurgeon's sermons and *The Treasury of David* on all 150 psalms,
  Bunyan, Gill, both London confessions)
- Eastern Orthodox (Philaret's *Longer Catechism*, the Confession of
  Dositheus, the *Book of Needs*)
- Catholic (Aquinas, Trent, Thomas à Kempis)
- Anglican and Methodist (Ryle, Newton, William Law, Wesley, Whitefield)
- Ecumenical creeds and councils (Nicene, Chalcedon, the Seven Councils)
- Confessions and catechisms (Westminster, Heidelberg, Augsburg, Dort, and more)

Not covered, and deliberately not faked: Pentecostal and Oriental Orthodox,
whose defining documents are 20th-century and in copyright. See `SOURCES.md`.
- Modern theology (Barth, C.S. Lewis, Schaeffer, Tozer, Packer, Sproul)
- Biblical texts (Sermon on the Mount, Gospel of John, Hebrews, James, the Parables)

The **Chat** screen uses RAG (retrieval-augmented generation): your question is matched against the library by full-text search *and* semantic search over on-device embeddings, the results are fused, and the passages are passed to whichever model you have configured — or shown on their own, if you would rather not use AI at all.

## Running the app

**Prerequisites:**
- [Flutter](https://flutter.dev/docs/get-started/install) (3.x+)
- [Ollama](https://ollama.com/) running locally with at least one model pulled (default: `llama3.2`)

```bash
# Pull a model if you haven't already
ollama pull llama3.2

# Run the app
flutter run -d macos
```

The app connects to Ollama at `http://localhost:11434` and uses the first model Ollama reports. Making the host and model configurable is tracked in [PLAN.md](PLAN.md).

## Tech stack

| Layer | Technology |
|---|---|
| UI framework | Flutter (Dart) — Material 3 |
| Database | SQLite via `sqflite`, bundled as an asset |
| Full-text search | SQLite FTS5 |
| AI inference | [Ollama](https://ollama.com/) (local, streaming) |
| RAG retrieval | FTS5 + tag-based hybrid search |
| State management | `provider` |
| Persistence | `shared_preferences` (bookmarks, reading position, settings) |
| Markdown rendering | `flutter_markdown` |

## Screens

Three tabs, each a thing the reader does:

- **Ask** — put a question to the corpus and get an answer with citations
- **Read** — the installed shelf, arranged by tradition, and the reader itself;
  full-text search across everything installed lives here too
- **Browse** — add and remove collections

Bookmarks, Notes and Chat history are reached from the app menu, and Settings
from the bubble beside it.

## The website

Council's site is at **<https://spencersmith.site/council>**, and its source
lives in [`SpencerSmithSite/spencersmith.site`](https://github.com/SpencerSmithSite/spencersmith.site)
under `public/council/` — plain static HTML alongside the rest of that site.

The one piece that lives *here* is the catalogue generator, because it needs the
corpus and imports `build_packs`, so the Sources page can never disagree with
what the app actually ships:

```bash
gunzip -k assets/theology.db.gz          # if the DB isn't unpacked
python3 tools/export_catalogue.py --out /path/to/spencersmith.site/public/council/assets/data/sources.json
```

Re-run it after any corpus rebuild and commit the JSON in the site repository.
Each card is built from the provenance already recorded against the source plus
**an excerpt of that work's own opening text** — never a written summary, for the
reason set out in `SOURCES.md`.
