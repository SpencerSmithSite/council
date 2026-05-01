# Council

An offline-first Flutter app for Christian theology research. Browse a curated library of primary sources, search with full-text search, and ask theological questions with AI-powered answers grounded in the texts — all running locally on your device.

![Council home screen](screenshots/home.png)

## What it does

Council ships with a bundled SQLite database of **523 sources** and **4,918 content units** spanning 12 Christian traditions:

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

The **Chat** screen uses RAG (retrieval-augmented generation): your question is matched against the database with FTS5 full-text search, the most relevant passages are retrieved, and a local Ollama model generates an answer with citations.

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

The app connects to Ollama at `http://localhost:11434` by default. You can change the host and model in the Settings screen.

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
