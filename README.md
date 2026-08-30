# Council

An offline-first Flutter app for Christian theology research. Browse a curated library of primary sources, search with full-text search, and ask theological questions with AI-powered answers grounded in the texts — all running locally on your device.

## What it does

Council ships with the King James Version — 1,189 chapters — and everything else is downloaded on request, starting with the creeds, councils, catechisms and confessions. That keeps the install small while the full library runs to **710 works and 485 million characters**.

Bundled: the King James Version, complete.

First download — **Creeds & Confessions**, 9.2 MB:

- Ecumenical creeds and councils — the acts themselves, not summaries: the
  creeds, canons and synodal letters of all seven ecumenical councils and
  eleven local synods, plus Trent's canons and decrees
- Confessions and catechisms (Augsburg, Westminster, Heidelberg, Dort, the
  Thirty-Nine Articles, both London Baptist confessions)
- Lutheran, Reformed, Catholic, Anglican, Baptist, Methodist and Eastern
  Orthodox standards

Downloadable from the **Browse** tab, or from Settings → Library → Manage
content:

| Collection | Works | Download |
|---|---|---|
| Church of the East | 1 | 0.3 MB |
| Leo XIII | 30 | 0.8 MB |
| Adventist | 5 | 3.2 MB |
| Holiness | 11 | 3.8 MB |
| Anabaptist | 10 | 4.3 MB |
| Quaker | 6 | 4.7 MB |
| Creeds & Confessions | 57 | 9.2 MB |
| Eastern Orthodox | 74 | 11.8 MB |
| Catholic | 130 | 25.6 MB |
| Augustine of Hippo | 48 | 12.9 MB |
| John Owen | 31 | 13.8 MB |
| Matthew Henry | 6 | 24.0 MB |
| John Calvin | 48 | 29.6 MB |
| Church Fathers | 357 | 49.2 MB |
| Charles Spurgeon | 74 | 93.1 MB |
| Reformed & Presbyterian | 147 | 108.2 MB |

Thirty-eight collections over forty-nine shared fragments, 302 MB published in
all. The same collections as standalone files would be 587 MB — no work is
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
- Catholic (Aquinas, Trent, Vatican I including papal infallibility, all
  thirty of Leo XIII's encyclicals, Thomas à Kempis)
- Anglican and Methodist (Ryle, Newton, William Law, Wesley, Whitefield)
- Holiness (Wesley on Christian perfection, Finney, Hannah Whitall Smith)
- Adventist (Ellen G. White — the Conflict of the Ages volumes, Steps to Christ)
- Anabaptist and Quaker (the Dordrecht Confession, the complete works of Menno
  Simons, van Braght's *Martyrs Mirror*, Barclay's *Apology*, the journals of
  Fox and Woolman, Penn, Sewel)
- Oriental Orthodox (1 Enoch, scripture in the Ethiopian and Eritrean Tewahedo
  churches)
- Church of the East (Badger's *Nestorians and their Rituals*, vol. II — an
  Anglican's study, but built from that church's own service books and from
  Abdisho's creed)
- Ecumenical creeds and councils (Nicene, Chalcedon, the Seven Councils)
- Confessions and catechisms (Westminster, Heidelberg, Augsburg, Dort, and more)

**Who counts as a tradition here** is settled by one test, applied to doctrinal
content rather than to creedal form: a body is covered if it holds the Trinity,
the full deity and humanity of Christ, and the incarnation, atoning death and
bodily resurrection. That is deliberately not a creedalism test — the Brethren,
the Restorationists and the Adventists decline to recite creeds and teach what
the creeds state, so they are in. Groups that fail it on the doctrine itself
are not. The rule, the groups it excludes and the reason for each are in
[`tools/data/traditions.json`](tools/data/traditions.json); the library is
organised branch → tradition, at 7 branches and 31 traditions. Sixteen of those
traditions hold text today, across six of the seven branches; the seventh is
Other and Independent, whose families are all twentieth-century bodies. The rest are defined and empty, and the shelf shows
a tradition only once it has something in it — an empty family is a piece of
work that has not been done, not a section a reader has to walk past.

It stops where the public domain does. Modern theology is not here — no Barth,
Lewis, Packer or Sproul — and neither is Pentecostalism or post-Vatican II
Catholicism. Those two absences are not the same kind of thing, and this file
used to say they were. The Catechism of the Catholic Church and the Vatican II
constitutions are in copyright and there is no way around that. Pentecostalism
is simply **not ingested yet**: the Assemblies of God *Statement of Fundamental
Truths* dates from 1916 and the Foursquare *Declaration of Faith* from 1923,
both long out of copyright. A corpus of what can be freely redistributed does
under-represent the second-largest Christian movement in the world today — but
by not having done the work, not because the documents are closed.

The traditions that are here are not all here to the same depth. Oriental
Orthodox is one work, Anabaptist is a martyrology with no systematics, and
Eastern Orthodox is three documents. Holiness is a subtler case of the same
thing: its own denominations — Nazarene, Wesleyan, Free Methodist, the
Salvation Army — wrote their standards in the twentieth century, so the pack
holds the teaching they came out of and not the bodies themselves. Each pack
says so in its own description rather than implying coverage it does not have. Nothing is generated to fill
those gaps; `tools/prune_bylined_sources.py` exists because some of it once
was, and was removed. See `SOURCES.md`.

The **Ask** tab uses RAG (retrieval-augmented generation): your question is matched against the library by full-text search *and* semantic search over on-device embeddings, the results are fused, and the passages are passed to whichever model you have configured — or shown on their own, if you would rather not use AI at all.

## Running the app

All you need is [Flutter](https://flutter.dev/docs/get-started/install) (3.x+):

```bash
flutter run -d macos    # or ios, android, linux, windows
```

Nothing else is required to read. The King James Version is bundled, search is
local, and the app works offline with no AI configured at all.

Answers need a backend, chosen during onboarding or later from Settings → AI.
A reader who has chosen nothing starts on whichever of the first two the device
can offer:

- **This device's built-in AI** — Apple Intelligence, on an iPhone or Mac that
  has it. Nothing to install, no account, no key.
- **A downloaded local model** — one download, then it runs on-device. You pick
  the size; a 32-bit phone is not offered one, because it cannot run it.
- **[Ollama](https://ollama.com/)** — a model on this machine or one reached
  over your network. Host and model are both configurable.
- **Your own API key** — Claude, ChatGPT, Gemini or Grok, billed to your own
  account. The only option that sends a question off the device.

## Tech stack

| Layer | Technology |
|---|---|
| UI framework | Flutter (Dart) — Material 3 |
| Database | SQLite via `sqflite`, bundled as an asset |
| Full-text search | SQLite FTS5 |
| AI inference | Apple Foundation Models, on-device weights via `flutter_gemma`, [Ollama](https://ollama.com/), or a cloud API key |
| RAG retrieval | FTS5 fused with semantic search over on-device embeddings |
| State management | `provider` |
| Persistence | `shared_preferences` (bookmarks, reading position, settings) |
| Markdown rendering | `flutter_markdown` |

## Screens

Three tabs, each a thing the reader does:

- **Ask** — put a question to the corpus and get an answer with citations
- **Read** — the installed shelf and the reader itself; full-text search across
  everything installed lives here too. The shelf is arranged branch by branch —
  the undivided church, then each split in the order it happened, then the
  Reformation families — with each tradition collapsible inside its branch
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
