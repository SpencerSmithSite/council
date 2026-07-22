# Council

An offline-first Flutter app for Christian theology research. Browse a curated library of primary sources, search with full-text search, and ask theological questions with AI-powered answers grounded in the texts — all running locally on your device.

![Council home screen](screenshots/home.png)

## What it does

Council ships with the creeds, councils, catechisms and confessions — **44 works, 902 passages** — and everything else is downloaded on request. That keeps the install small while the full library runs to 437 works and 58.8 million characters.

Bundled:

- Ecumenical creeds and councils (Nicaea, Chalcedon, the Seven Councils, Trent)
- Confessions and catechisms (Augsburg, Westminster, Heidelberg, Dort, the Thirty-Nine Articles)
- Lutheran, Reformed, Catholic, Anglican, Orthodox and Methodist standards

Downloadable from **Settings → Library**:

| Collection | Works | Download |
|---|---|---|
| Augustine of Hippo | 44 | 4.6 MB |
| John Chrysostom | 36 | 6.3 MB |
| Church Fathers | 313 | 22.8 MB |

The full library spans:

- Early Church Fathers (Athanasius, Augustine, Chrysostom, Origen, and more)
- Medieval scholastics (Aquinas, Anselm, Boethius)
- Reformation (Luther, Calvin, Melanchthon)
- Puritan (Owen, Baxter, Charnock, Brakel)
- Eastern Orthodox (Desert Fathers, Philokalia, Climacus)
- Catholic mystical theology (Ignatius, Teresa of Ávila, Thomas à Kempis)
- Ecumenical creeds and councils (Nicene, Chalcedon, the Seven Councils)
- Confessions and catechisms (Westminster, Heidelberg, Augsburg, Dort, and more)
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
| Persistence | `shared_preferences` (bookmarks, search history, settings) |
| Markdown rendering | `flutter_markdown` |

## Screens

- **Home** — database stats and quick actions
- **Browse** — explore sources by tradition or type
- **Search** — full-text search across all content
- **Chat** — ask questions, get AI answers with citations
- **Bookmarks** — saved passages
