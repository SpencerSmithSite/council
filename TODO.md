# Council TODO

The corpus ledger: what is in the app, what is missing, what should be added
next, and what was taken out and must not come back.

Everything here is checked by a tool rather than remembered. Run all three
before and after any corpus change:

```bash
python3 tools/audit_corpus.py          # generated filler vs primary text
python3 tools/audit_completeness.py    # contents pages filed as the work
python3 tools/prune_unprovenanced.py   # sources with no recorded origin
```

*Last verified: 2026-07-27 · corpus v15 · 687 sources, 104,115 units, 460.1 M
characters · all three audits clean except the three noted at the bottom.*

---

## Shouldn't have — removed, and why

Do not re-add any of these. Each was in the app and each was worse than the gap
it filled, because a citation makes unverified text look checked.

| removed | what it actually was |
|---|---|
| The Philokalia Selections | half its units are *Pilgrim's Progress* — Slough of Despond, Vanity Fair, the Celestial City |
| A Plain Account of the People Called Methodists (Wesley) | opens with the Didache's Two Ways and the martyrdom of Polycarp |
| The Life of Moses (Gregory of Nyssa) | three units are *Nostra Aetate* — Vatican II, 1965, **in copyright** |
| The Interior Castle (Teresa of Ávila) | alternates with Richard Foster's *Celebration of Discipline*, 1978, **in copyright** |
| The Spiritual Exercises (Ignatius) | seven paragraphs of unsourced précis under Ignatius' byline |
| The Orthodox Confession of Faith (Peter Mogila) | six paragraphs of précis; the first is just the Nicene Creed |
| Second Helvetic Confession | nine paragraphs standing in for thirty chapters |
| The Seven Ecumenical Councils | seven paragraphs of summary — **superseded**, not merely deleted: the acts themselves (creeds, canons, synodal letters, 503 K characters) were already in the corpus |
| Catechism of the Catholic Church, Lumen Gentium | © Libreria Editrice Vaticana, recorded here as public domain |
| 9 stub confessions and catechisms | superseded by sourced editions (`prune_unprovenanced.py`) |

Four of those eight were not abridgement at all but **two unrelated works
interleaved**, odd units from one and even from the other under one title — the
Philokalia, the Wesley, the Gregory of Nyssa and the Teresa. The other four are
unsourced précis standing in for the document they name. Both defects read as
genuine text, which is why "the wording looks right" was never a sufficient
test, and why `source_url` is now required rather than preferred: **every
source in the corpus records where it came from.**

Also do not re-add, on rights grounds: post-1929 texts generally, the Vatican
II documents, the 1992 Catechism, NA28/BHS, and every modern Bible translation
(ESV, NIV, NASB, NKJV, CSB, NLT, NET, AMP, LSB). See `SOURCES.md` for the full
copyright constraint.

---

## Have — verified primary text

- **Scripture** — KJV, ASV, World English Bible, Douay-Rheims (Challoner),
  Brenton's Septuagint.
- **Early Church** — the New Advent patristic corpus, ~389 works in the Schaff
  Ante-Nicene / Nicene and Post-Nicene translations, with translator and
  edition recorded per work.
- **Ecumenical councils** — the acts themselves: creeds, canons and synodal
  letters for all seven ecumenical councils and eleven local synods.
- **Catholic** — the Summa Theologiae, complete; Trent's canons and decrees;
  à Kempis, *The Imitation of Christ*.
- **Reformed** — Westminster Confession, Shorter and Larger Catechisms, Belgic,
  Heidelberg, Canons of Dordt, Scots Confession. Then, from 2026-07-26:
  Calvin's *Institutes* and 45 volumes of his commentaries; Matthew Henry's
  unabridged *Commentary on the Whole Bible*; Jonathan Edwards; Thomas Manton;
  Charles Hodge's *Systematic Theology*; Albert Barnes' *Notes*; Knox, Watson,
  Flavel, Charnock, Andrew Murray. Then, from 2026-07-27: **John Owen, all 31
  works** from Goold's edition — *The Death of Death*, *Pneumatologia*,
  *Communion with God*, *Of the Mortification of Sin*, *Of Temptation*,
  *Vindiciæ Evangelicæ*, the sermons.
- **Lutheran** — Augsburg Confession and the other confessions of the Book of
  Concord, plus Luther's *Commentary on Galatians*, *Table Talk*, the Ninety-Five
  Theses and the treatises.
- **Baptist** — First London (1644) and Second London (1689) confessions;
  Spurgeon's sermons, 63 volumes, and *The Treasury of David* on all 150
  psalms; Bunyan; John Gill.
- **Methodist** — Wesley, *Sermons on Several Occasions*, all 141; Whitefield's
  sermons.
- **Anglican** — the Thirty-Nine Articles, J. C. Ryle, William Law, John Newton,
  Lightfoot on the Apostolic Fathers. Still *not* the 1662 Book of Common
  Prayer, which `SOURCES.md` once marked "(ingested)". See *Don't have*.
- **Eastern Orthodox** — Philaret of Moscow's *Longer Catechism* (608 of its 611
  questions), the Confession of Dositheus, and the *Book of Needs*.

Each of these is text, not summary, and each has `source_url`, translator and
edition on the source row.

### What was offered and refused

72 of the 261 CCEL works attempted were not ingested, and the reasons are worth
keeping because they are the reasons that will recur:

| refused | count | why |
|---|---:|---|
| ~~a modern print basis, with no rights statement~~ | ~~32~~ → 1 | Banner of Truth reprints, 1965-68. 31 of these were the whole of John Owen, **now recovered** — see below |
| too few units, or a stub | 12 | an export that is front matter or a table of contents |
| no rights statement and no author dates | 8 | nothing to reason from in either direction |
| ~~served as page scans, not text~~ | ~~7~~ → 1 | Spurgeon's *Treasury of David* — ~50 KB of "Image of page 73" per volume. **Now ingested from a transcription instead** |
| fetch failed | 6 | 404 at CCEL |
| a translation of unknown date | 5 | CCEL credits no translator and states no rights; includes Luther's *Bondage of the Will* |
| no Title in the export header | 2 | not a CCEL text export |

**Both of the big refusals have since been resolved, and neither by relaxing a
gate.** Owen's rights question was settled by evidence rather than by a date:
`ingest_owen.py` scores CCEL's transcription against archive.org's scans of
Goold's 1850-55 edition, and all 31 works matched at 87-98%, against 33% for
Calvin's *Institutes* measured the same way. The *Treasury of David* was never a
rights problem at all — only a text problem — and `ingest_treasury.py` takes it
from Ted Hildebrandt's 2007 digitisation, corroborated psalm by psalm against
the Victorian printings at a median of 97%.

What is left in the table is genuinely unresolved, and mostly small.

---

## Don't have — named gaps with a known route in

Ordered by how badly the absence distorts an answer.

- [ ] **A Philokalia, at all.** Closing the Eastern Orthodox zero did not
      close this one, and the entry that used to stand here was wrong about
      why. It named "Kadloubovsky's extracts" as the public-domain route:
      Kadloubovsky and Palmer's *Writings from the Philokalia on Prayer of the
      Heart* is Faber, **1951**, and in copyright, exactly like the complete
      Palmer/Sherrard/Ware translation it was offered as an alternative to.
      **There is no public-domain English Philokalia.** The nearest available
      substitutes are its constituent authors where they predate the
      collection — Maximus the Confessor and Diadochus are reachable through
      the patristic corpus already here.
- [x] **John Owen, all 31 works** — done. `tools/ingest_owen.py`.
- [ ] **Book of Common Prayer (1662)** — and this entry has been wrong twice.
      It first claimed the book was ingested when the database had no such
      source. It then named **Gutenberg 29622** as the route in, and 29622 is
      not the 1662 English Prayer Book at all: its author is the *Episcopal
      Church in Scotland*, its full Gutenberg title is "The Book of Common
      Prayer: and The Scottish Liturgy", the only date in it is **1912**, and
      the string "1662" does not appear anywhere in the file. Checked
      2026-07-27.

      **Gutenberg does not have the 1662 book** — searching its catalogue for
      "book of common prayer" returns three results and none is the English
      text. So this is research rather than an afternoon's ingest:

      - `justus.anglican.org`, the usual free HTML source, could not be
        reached — it negotiates a TLS version this toolchain refuses
        (`UNSUPPORTED_PROTOCOL`), from both `curl` and the fetch tool.
      - archive.org has the 1662 lineage in quantity, but as scans of
        early-modern printings — long-s, black letter, and OCR to match. A
        scan is a fine *witness* and a poor *source*, which is the standing
        rule here.

      Anglican holds Ryle, Law, Newton and Lightfoot, and still no liturgy.
- [ ] **Scottish Book of Common Prayer (1912)** — the thing Gutenberg 29622
      actually is, already cached at `.cache/gutenberg/bcp29622.txt`. Public
      domain on date (1912, well before the 1929 cutoff) and a genuine Anglican
      liturgical text, so it is worth having on its own terms — labelled as the
      Scottish book, never as the 1662. Not a substitute for the entry above.

      The work is in the gates, not the fetch: a prayer book is mostly
      lectionary and psalter tables — "PROPER LESSONS", `|MATTINS |EVENSONG` —
      which are exactly the apparatus-that-reads-as-text problem that cost this
      corpus 30 M characters in Phase 35. The liturgy has to be separated from
      the timetable before any of it ships.
- [ ] **Luther's *Bondage of the Will*** — refused: CCEL credits no translator
      and states no rights, and a translation of unknown date cannot be
      assumed public domain. Henry Cole's 1823 translation is public domain;
      the route in is an edition that says so.
- [ ] **Pentecostal, Oriental Orthodox, Assyrian** — traditions with a row in
      the database and nothing in it. Pentecostalism's defining documents are
      20th-century and in copyright; the honest route is the pre-1929
      antecedents (the *Apostolic Faith* periodicals, Azusa Street) or saying
      plainly that the tradition is not covered.
- [ ] **Anabaptist, Mennonite, Quaker** — absent. Schleitheim (1527) and the
      Dordrecht Confession (1632) are public domain; Woolman's *Journal*
      (Gutenberg 37311) and Penn's *No Cross, No Crown* (44895) are there for
      the taking.
- [ ] **Restorationist and Adventist** — absent, and freely available.
      Ellen White, *The Great Controversy* (Gutenberg 25833); the
      Campbell–Stone documents.
- [ ] **Second Helvetic Confession** — removed as précis, not yet replaced.
      Schaff, *Creeds of Christendom* vol. 3, is the public-domain edition.
- [ ] **Teresa of Ávila, *Interior Castle*** — removed as misattributed. The
      Benedictines of Stanbrook / Zimmerman translation (1921) is public
      domain and on CCEL.
- [ ] **Ignatius of Loyola, *Spiritual Exercises*** — removed as précis.
      Elder Mullan's 1909 translation is public domain.
- [ ] **Gregory of Nyssa, *Life of Moses*** — removed as misattributed, and
      **blocked**: the Ferguson–Malherbe translation is 1978 and there is no
      public-domain English edition.
- [ ] **More Bible versions** — YLT, Darby, Webster, Geneva (1560), Vulgate.
      One ebible.org USFM importer already exists and serves all of them.

Fuller acquisition notes, per archive and per document, are in `SOURCES.md`
and in `~/Documents/council research/research/acquisition-roadmap.md`.

---

## Should have — next, in order

1. [ ] **Re-verify after every ingest.** Run the three audits above; move rows
       out of *Don't have* only when the tool agrees.
2. [x] **John Owen from the Goold edition** — done, and the *Treasury of David*
       with it. Both were rights-or-text refusals with a route in, and the route
       worked. `ingest_owen.py`, `ingest_treasury.py`.
3. [ ] Anabaptist and Quaker — the largest tradition-shaped hole that is not
       blocked by copyright, and the largest remaining win. Schleitheim,
       Dordrecht, Menno Simons, Barclay's *Apology*, Fox's *Journal*.
4. [ ] The Scottish Prayer Book (1912) — cached, public domain, and the nearest
       thing to a liturgy this corpus can currently reach. Needs gates that
       separate the services from the lectionary tables.
5. [ ] More Eastern Orthodox. Three sources is a tradition that exists, not one
       that is covered.
6. [ ] The remaining public-domain Bible versions.
7. [ ] The 1662 Prayer Book, Interior Castle, Spiritual Exercises — **not**
       "already identified" as this list used to claim. The Prayer Book entry
       was wrong about its own source (see *Don't have*); Second Helvetic is
       recorded in `SOURCES.md` as copyright-blocked in every English edition
       found. Treat all of these as research, not as queued ingests.

**None of items 3-7 needs an app release.** `build_packs.py` copies the
reference tables — traditions included — into every fragment with `OR IGNORE`,
so even a new tradition reaches readers as a pack. Only a change to the
*bundled* database, which is the King James Version and nothing else, requires
a build. That is what Phase 33 bought and it is worth spending.

---

## Known, small, deliberately not fixed yet

- **Duplicate unit titles inside a few multi-part works.** For a page with no
  section headings the ingester falls back to grouping paragraphs and takes the
  unit number from the first paragraph's own leading digit, so a part with two
  paragraphs starting "9." yields two units titled "Book I — 9". Ambrose's
  *De fide* has five such pairs. Cosmetic, and the fix would renumber titles
  across many works — which means replacing their units, which means detaching
  every highlight and note anchored to them. Not worth it until the
  re-anchoring below exists.
- **Three sources still flagged by `audit_corpus.py`** with no confidently-primary
  unit: Gregory of Nyssa's *On the Soul and the Resurrection* (a dialogue, so
  heavy anaphora), *Apostolic Constitutions* VIII.47 (a numbered list of
  canons), and Owen's *Eshcol* (a book of numbered rules — every unit opens
  "Rule iv.", which reads as templated). All three are genuine text; they are
  left flagged rather than tuned away, because loosening the signal to clear
  them is how the tool went blind before.

## Publishing a corpus change

After any corpus rebuild, `tools/build_packs.py --write` ends by saying which
of two cases you are in:

- **"install into any app already on id space N"** — the build only appended.
  Upload `dist/packs` to a new GitHub release and readers get it on their next
  visit to Settings → Library. No app release needed.
- **"this build reassigned ids"** — raise `DatabaseService.idSpace` to match,
  and publish the packs *with* the app build, not before it. The tool prints
  which sources moved.

The bundled core (`assets/theology.db.gz`) is inside the binary, so a change to
it always needs a release regardless — bump `DatabaseService.corpusVersion`.

## Performance — one fix deferred, deliberately

- [ ] **Store chunk vectors as contiguous blocks rather than 434,764 rows.**
      `VectorIndex.load` is paged, which stopped it blocking every other query,
      but it did not make it cheap. SQLite reads the 165 MB in **0.28 s**; the
      rest is sqflite marshalling one `Map` and one `Uint8List` per row. The
      fix is to write a few contiguous blocks at build time and read those.
      The index is never searched by order — only each vector paired with its
      chunk — so blocks can arrive in any order, and per-fragment blocks would
      merge without renumbering. Touches `build_packs.py`, `pack_service.dart`
      and `vector_index.dart`, which is why it is not in this change.

## Release signing — both desktop installers warn on first run

Both are gated on a purchase rather than on work, which is why neither is done.
The download page carries a `note` for each explaining the warning the reader
will see; both notes come off once these are settled.

- [ ] **Notarise the macOS DMG.** It is already signed with the Developer ID
      Application certificate (team `Y2Q5JVG8X5`) and built with the hardened
      runtime, so `codesign --verify --deep --strict` passes — but `spctl`
      still returns `rejected: Unnotarized Developer ID`, and Gatekeeper
      refuses a plain double-click. Needs an app-specific password or an App
      Store Connect API key:

      ```bash
      xcrun notarytool submit Council-macos.dmg \
        --apple-id <apple-id> --team-id Y2Q5JVG8X5 --password <app-specific-password> \
        --wait
      xcrun stapler staple Council-macos.dmg
      ```

      Then re-upload with `gh release upload … --clobber`. Staple the DMG, not
      just the .app inside it, or a fresh download is unnotarised again.

- [ ] **Sign the Windows installer.** `Council-windows-setup.exe` has no
      Authenticode signature, so SmartScreen shows "Windows protected your PC"
      on first run and the reader has to choose *More info → Run anyway*.
      Needs a code-signing certificate — an OV certificate still accrues
      SmartScreen reputation slowly, an EV one carries it immediately, which is
      the difference worth paying for if this is bought at all. Once there is a
      certificate, sign inside CI: add a `signtool` step to the Windows job in
      `.github/workflows/release-desktop.yml`, after ISCC and before the
      release upload, with the certificate held in repository secrets rather
      than in the repo.

## App work

- [ ] Text-to-speech for a source, offline.
- [ ] Re-anchor annotations on corpus drift. The quote snapshot is stored and
      not yet used; an annotation whose offsets have moved is currently drawn
      where the offsets say. This matters more now that a corpus rebuild can
      replace a work's units wholesale.
- [ ] Collections of saved passages beyond bookmarks; more reading themes.
- [x] ~~Test on macOS~~ — done 2026-07-26. The app builds and runs there, and
      `integration_test/retrieval_test.dart` passes all 24 tests on it against
      the full library with every pack installed.
