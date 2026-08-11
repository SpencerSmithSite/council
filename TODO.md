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

*Last verified: 2026-08-02 · corpus v17 · 650 sources, 103,364 units, 471.1 M
characters · all three audits clean except the three noted at the bottom.*

---

## Before the official release

2026.8.2+7 is published as a **pre-release**. What stands between that and a
release called official is distribution trust, not features — an installer the
operating system does not warn about. The detail for each is further down; this
is the index, so the gate is in one place.

- [x] **Android signing** — done 2026-08-06. The only one of these that could
      not have been fixed afterwards. See *App work*.
- [ ] **Notarise the macOS DMG** — needs an app-specific password or an App
      Store Connect API key. See *Release signing*.
- [ ] **Sign the Windows installer** — needs a code-signing certificate bought
      first, and OV vs EV is a decision, not a formality. See *Release signing*.
- [ ] **Say on the download page that the Android pre-release cannot be updated
      over.** Lands *with* the release cut, not before — the page must never
      describe a build that is not published yet. See *App work*.

**Verified by hand, 2026-08-06:** a physical Android phone, a Mac, an iPhone
and an iPad all run the app with the AI features working. The gaps that remain
— the Windows and Linux update hand-off, a desktop model download — are
accepted rather than closed, and are listed under *App work* so they stay
visible rather than forgotten.

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

## Removed on doctrinal rather than textual grounds — done in v16 (2026-08-01)

Every removal above was for a defect in the *text*: interleaved works, unsourced
précis, or copyright. This was the first cut on what a work **is**.

**Decided and executed.** All 45 below were removed and `f-apocrypha` dropped
from `packs.json`; 1 Enoch was added in their place. `tools/prune_apocrypha.py`
holds the selection rules and refuses to run if the corpus has drifted from
them, and `tools/data/withdrawn.json` is what stops a rebuild quietly restoring
them. The audit that follows is kept because it is the reasoning, and because
two of its findings are the kind that get re-assumed otherwise.

**There are no Gnostic texts in the corpus.** Gospel of Mary, Judas, Philip,
Truth, Pistis Sophia and the rest of the Nag Hammadi library are all absent, and
structurally so: every patristic text here comes from the 1880s Ante-Nicene and
Nicene Fathers volumes via newadvent, and Nag Hammadi was not found until 1945.
Its translations are all modern and in copyright, so that library could not have
been ingested even deliberately.

**The corpus's "Gospel of Thomas" is not the Gnostic one.** `[909]` is the
*Infancy Gospel of Thomas* — ANF Vol. 8, newadvent 0846, miracle stories about
the boy Jesus, opening "I Thomas, an Israelite, write you this account… the
miracles of our Lord Jesus Christ in His infancy." The Gnostic sayings gospel is
a different work and is not here.

**What is here: 40 works bylined `Apocrypha`,** 1.43 M characters, all in
fragment `f-apocrypha`. None is in the bundled core — but the fragment is listed
in the **Church Fathers** and **Ante-Nicene Writers** collections in
`tools/data/packs.json`, so a reader installing either gets all 40 without ever
choosing apocrypha. That, rather than their presence in the database, is the
part worth deciding about.

| group | works | note |
|---|---|---|
| Infancy and nativity gospels | Infancy Thomas, Protoevangelium of James, Pseudo-Matthew, Arabic Infancy, Nativity of Mary, History of Joseph the Carpenter | the Protoevangelium is where Joachim and Anne, and the perpetual-virginity tradition, come from |
| Pilate cycle | Gospel of Nicodemus (192 K, the largest), Report/Letter/Giving Up/Death of Pilate, Avenging of the Saviour, Narrative of Joseph of Arimathea | Nicodemus is the source of the Harrowing of Hell |
| Apocryphal Acts | Andrew, John, Thomas, Philip, Peter & Paul, Paul & Thecla, Barnabas, Bartholomew, Matthew, Thaddaeus, Xanthippe, Andrew & Matthias, Peter & Andrew, Consummation of Thomas | Acts of John and Acts of Thomas carry the most doctrinally alien material |
| Apocalypses | Peter, Paul, John (late), Moses, Esdras, Sedrach, the Virgin | Apocalypse of Peter appears in the Muratorian canon list |
| OT pseudepigrapha | Testaments of the Twelve Patriarchs (140 K), Testament of Abraham, Narrative of Zosimus | Second Temple Jewish, not Christian forgery |
| Other | Gospel of Peter, Assumption of Mary, Doctrine of Addai | |

**Outside that bucket, four more that fit the same question:**

- `[958]` **The False Decretals** (c. 850) — the Pseudo-Isidorian forgeries, a
  deliberate fabrication of papal letters, and the clearest forgery in the corpus.
- `[647]` **Recognitions** and `[648]` **Clementine Homilies** — Pseudo-Clementine,
  carrying Ebionite material, and currently bylined **Clement of Rome** as though
  genuine. Even if kept, the byline is a misattribution the catalogue asserts.
- `[633]` **Bardesanes**, *Book of the Laws of Various Countries* — a heterodox
  author, though this particular text is his least objectionable and was written
  down by a disciple.
- `[944]` **The Legend of Barlaam and Josaphat** — a Christianised retelling of
  the life of the Buddha. Not heresy; not history either.

**Do not confuse these with the following, which should stay.** The Apostolic
Fathers are sub-apostolic and orthodox, not apocryphal: the *Didache*, the
*Epistle of Barnabas*, the *Shepherd* of Hermas, 1 Clement, Ignatius, Polycarp,
*Epistle to Diognetus*. Nor the refutations — Tertullian's *Against Marcion*,
Hippolytus' *Refutation of All Heresies* — which exist precisely to argue
against this material and are useless without knowing what they answer. Nor the
deuterocanon, which is canon for Catholics and the Orthodox and is already here
inside the Douay-Rheims, Brenton's Septuagint and the WEB.

**1 Enoch was added in the same pass; Jubilees was not.** Both are canon in the
Ethiopian Orthodox Tewahedo and Eritrean Orthodox Tewahedo churches, so on the
corpus's own principle — hold what a tradition actually receives as scripture —
their absence was a gap rather than a policy. 1 Enoch is now in from R. H.
Charles' 1917 translation via Gutenberg's proofread transcription, and is the
corpus's first Oriental Orthodox content. Jubilees has no such transcription and
is listed under *Wanted, with no clean text anywhere* above.

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
- **Oriental Orthodox** — 1 Enoch, canon in the Ethiopian and Eritrean Tewahedo
  churches (Charles, SPCK 1917). Added 2026-08-01, corpus v16.
- **Quaker** — Barclay's *Apology* in its fifteen propositions, both volumes of
  Fox's *Journal*, Penn's *No Cross, No Crown*, Woolman's *Journal*, and Sewel's
  *History*. Added 2026-08-02, corpus v17.
- **Anabaptist** — van Braght's *Martyrs Mirror*, 526 accounts, and **only**
  that: see *Wanted, with no clean text anywhere*. Martyrology, not systematics,
  and the collection description says so.

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

## Wanted, with no clean text anywhere — searched, not merely absent

These are not "not yet attempted". Each was looked for and the search failed, so
what follows is a record of **where it was looked** — the point is that the next
attempt should start somewhere new rather than repeat this. Every one of them is
out of copyright; the obstacle is transcription quality, not rights.

The bar they fail is the corpus's oldest one: a proofread transcription, not a
scan. `ingest_gutenberg.py` states the reason — archive.org's OCR of this
material runs about one error per hundred characters, and in an app whose whole
purpose is quoting a source accurately that is a regression, not a shortcut. It
is also the defect that got eight works deleted in *Shouldn't have* above.

| wanted | why it matters | searched | date |
|---|---|---|---|
| **Menno Simons**, *Complete Works* (Funk, 1871) | The Anabaptist theologian. Without him the tradition has no systematics at all | Gutenberg: nothing under any title. CCEL: `/ccel/menno` 404s, `/ccel/simons` returns an error page rather than an author index | 2026-08-01 |
| **Schleitheim Confession** (1527) | The founding Anabaptist confession — believers' baptism, the ban, non-resistance, the sword | Gutenberg: 0 results | 2026-08-01 |
| **Dordrecht Confession** (1632) | The Mennonite confession, still confessionally binding | Gutenberg: 0 results | 2026-08-01 |
| **The Book of Jubilees** (R. H. Charles, 1902) | Canon in the Ethiopian and Eritrean Tewahedo churches, exactly as 1 Enoch is — the two belong together | Gutenberg: 0 results for *Jubilees*, *Little Genesis*, or Charles as translator | 2026-08-01 |

**Routes worth trying next**, none yet attempted: Schaff's *Creeds of Christendom*
vol. 3 may carry Dordrecht, and CCEL has a `schaff` author index the survey tool
already knows how to walk; the Mennonite and Quaker archives that have digitised
their own confessional documents may have transcriptions rather than scans; and
a scan is only unusable *uncorrected* — `ingest_owen.py` and `ingest_treasury.py`
both exist because a text was rescued by corroborating it against a second
witness, which is the same move available here.

Three of the four are Anabaptist, which is why the tradition ships as the
*Martyrs Mirror* alone. That is stated in the collection's own description and on
the Sources page, so a reader sees a known gap rather than a claim of coverage.

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
- [ ] **Pentecostal and Assyrian** — traditions with a row in the database and
      nothing in it. Pentecostalism's defining documents are 20th-century and in
      copyright; the honest route is the pre-1929 antecedents (the *Apostolic
      Faith* periodicals, Azusa Street) or saying plainly that the tradition is
      not covered. **Oriental Orthodox** is no longer one of these — 1 Enoch
      landed in v16 — but one work is a presence, not coverage.
- [x] **Anabaptist, Mennonite, Quaker** — done for two of the three, 2026-08-02,
      corpus v17. Quaker is now Barclay's *Apology*, both volumes of Fox's
      *Journal*, Penn's *No Cross, No Crown*, Woolman's *Journal* and Sewel's
      *History*; Anabaptist is van Braght's *Martyrs Mirror* and only that.
      Schleitheim, Dordrecht and Menno Simons were all searched for and none has
      a proofread transcription anywhere — they are recorded above under
      *Wanted, with no clean text anywhere*, which is where the next attempt
      should start.
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
3. [x] Anabaptist and Quaker — done 2026-08-02, corpus v17, as far as it can be.
       Barclay, Fox, Penn, Woolman and Sewel are in, and the *Martyrs Mirror*
       with them. Schleitheim, Dordrecht and Menno Simons turned out not to be a
       copyright problem but a transcription one, and moved to *Wanted, with no
       clean text anywhere* rather than being finished here.
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

- [x] ~~Consider splitting the Android APK per ABI~~ — decided against,
      2026-08-02. Reach matters more than size: a universal APK installs on
      every device the app supports, and any split either breaks the "Android 7
      or later" promise for 32-bit devices or asks someone on a phone to know
      their CPU architecture. Play Store apps get this for free from app
      bundles; a direct download has no store to choose for it.

- [ ] **Drop the Qualcomm NPU libraries if the APK needs to shrink.** This is
      the lever that costs no device support, unlike an ABI split. Ten `libQnn*`
      files total **50.4 MB** of the 124.3 MB of `arm64-v8a` native code —
      including four Hexagon DSP skeletons, one per Snapdragon generation
      (V73/V75/V79/V81) at ~10.5 MB each. They accelerate the downloaded model
      on Snapdragon NPUs; every Pixel and Exynos device carries all four and
      uses none, and the model still runs on CPU and GPU without them. Worth
      checking whether `flutter_gemma_litertlm` allows excluding them before
      touching anything else.

      For reference, what the 195 MB is made of: `arm64-v8a` 124.3 MB,
      `armeabi-v7a` 27.6 MB, `x86_64` 21.9 MB. Within arm64: Qualcomm 50.4,
      LiteRT-LM 39.9, onnxruntime 13.5, engine and Dart 20.4.

- [x] **Bump the version in `pubspec.yaml`, never in Xcode** — enforced
      2026-08-02. `Info.plist` reads
      `$(FLUTTER_BUILD_NAME)`/`$(FLUTTER_BUILD_NUMBER)`, which `flutter build`
      writes from the pubspec; Android reads the same source. Xcode's General
      tab edits `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, which nothing
      references — so an archive uploaded after editing there ships the old
      numbers while the tab shows the new ones. Those two settings now resolve
      to the Flutter variables, so the tab can no longer disagree with what is
      built.

- [x] ~~A withdrawn fragment is never uninstalled~~ — **intended, decided
      2026-08-06.** `install` walks the fragments a collection *declares* in the
      current manifest, so one dropped from every collection is never visited
      again. When `f-apocrypha` was withdrawn in corpus v16 that removed the
      forty works from every new install and every fresh download, and left them
      in place for every reader who already had the Church Fathers or
      Ante-Nicene Writers collection.

      That asymmetry stays. Presence not implying currency is a correctness
      rule — a reader holding a passage the corpus has since fixed should get
      the fix. Absence implying removal is a different thing entirely: it is
      reaching onto someone's device and taking text off it because the
      catalogue changed its mind. An editorial decision here should govern what
      the app *ships*, not what a reader already has. Text stays until they
      remove the collection themselves.

- [x] ~~The downloadable model path is unverified end to end~~ — done
      2026-08-02, and it took three fixes: no engine was registered, the Gemma
      weights turned out to be gated behind a HuggingFace token, and the 135M
      fallback ignored the retrieved passages entirely. Now Qwen 2.5 0.5B on
      Android, verified download → install → load → cited answer. See PLAN.md.

- [x] ~~Free disk space is never checked~~ — done 2026-08-02. `DeviceStorage`
      reads it per platform and the download is refused before any bytes move.
      Verified on the emulator by filling `/data` to 421 MB free.

- [ ] **The LiteRT-LM native libraries are not 16 KB aligned either.** Android
      17 shows a compatibility dialog naming `libonnxruntime.so` — already
      recorded — plus a dozen litertlm libraries, and runs the app in page-size
      compatible mode. Not a crash, and Google Play is not planned, so this is
      not urgent; it becomes blocking the moment Play does come into scope, and
      it now covers two dependencies rather than one.

- [ ] **Check the memory thresholds against real phones.** They are calibrated
      against what the OS reports rather than what the device is sold as, which
      was measured on exactly one machine — a 4 GB Android emulator reporting
      3,967 MB. The 0.6B admits a nominal 3 GB phone and the 1.7B a nominal
      6 GB one; both numbers are judgement, not measurement, and the cost of
      being too strict is silently hiding the feature from someone who could
      use it.

- [ ] **Download and run a model on a desktop, by hand.** macOS builds, launches
      with LiteRT-LM registered, and the desktop half of the catalogue is
      covered by host-run tests — but nobody has actually fetched the 2.1 GB
      1.7B on a Mac and asked it a question. Windows and Linux have not been
      built at all since the engine changed, and Windows carries a known
      upstream regression: discrete GPUs crash in the WebGPU/Dawn stack, so it
      may need `PreferredBackend.cpu` there.

- [ ] **Check Apple Intelligence still works on iOS after the shared-file
      change.** The bridge is now one file compiled into both runners, and only
      the macOS half has been exercised since. The conditional imports and the
      `messenger` method-versus-property split are compile-time, so a green iOS
      build is most of the evidence — but the iOS registration path was edited
      and has not been run.

- [ ] **Try the downloaded model on iOS.** Only Android has been run end to
      end. The engine, the weights and the Dart are shared, but the download
      path is not: iOS has its own background-download behaviour and its own
      memory ceiling, and even the 0.6B wants ~700 MB beside the ~170 MB vector
      index. Apple Intelligence covers the newest iPhones, so this path is for
      exactly the older ones with least headroom.

- [ ] **Re-check Qwen 3.5 / 3.6 in LiteRT format.** Both exist upstream and
      neither has a LiteRT or MediaPipe conversion, which is the only reason
      the app is on Qwen 3. 3.5 starts at 4B and 3.6 at 27B, so a conversion
      would help desktop before it helped phones — the 0.6B rung has no
      successor announced.

- [ ] **`LiteRtTopKMetalSampler` is not bundled on macOS.** The Podfile phase
      the package requires copies three accelerator dylibs; upstream ships only
      two, so that one logs a warning and is skipped. Nothing has visibly
      failed, but it means a sampling path is falling back. Worth checking
      whether it matters once a model has actually been run on a Mac.

- [x] **Audit the rest of the chat screen at a narrow width** — done
      2026-08-06, and it found two more, both only at the largest font size on
      the narrowest phone (320 px, 1.5×, an iPhone SE):

      - The **"Thinking…" row overflowed by 52 px**, and what went off the edge
        was the **Stop** button — the one control that has to stay reachable
        while a long generation runs. A free-sized `Text` followed by a
        `Spacer` gave the label everything and the button nothing; the label is
        now `Expanded` and ellipsizes.
      - The **coverage notice pushed the composer off the bottom** by 140 px.
        The notice is taller than the display on its own at that size, and a
        `Column` that cannot give way answers that by evicting whatever is
        last — leaving the reader told their library is thin with no way to ask
        anything else. It is now `Flexible` and scrolls inside itself.

      `test/narrow_width_test.dart` holds the screen at 320 px at both 1.0×
      and 1.5× with a pinned passage, three citations carrying corpus-length
      source titles, and the notice actually on screen. An overflow throws
      during paint, so the tests need assert nothing about layout — they only
      have to get hostile content in front of the renderer.

- [x] **Read and Library at a narrow width too** — done 2026-08-06, and both
      are clean at 320 px and 1.5×, so the two faults above were the whole of
      it. Covered in the same file, against the real catalogue rather than a
      fixture: the collection names under test are the ones that ship, each
      row carrying a megabyte count, because the labels that break are the ones
      interpolating a name and a size.

      Two things the tests had to do before they meant anything, both of which
      would have made them pass for the wrong reason. Shelf sections start
      collapsed, so pumping Read renders headings and no works at all — the
      test expands one and checks a source title is on screen. And a list lays
      out only what it paints, so a name that breaks the layout twenty rows
      down never gets the chance to; both lists are now scrolled the whole way
      through.

- [ ] **Verify the update hand-off on Windows and Linux.** Both are written and
      neither has been run: Windows starts the Inno installer detached and then
      calls `exit(0)`, and Linux marks the AppImage executable and opens its
      folder. The download and checksum halves are covered by the host-run
      suite, but the hand-off is the part with no test — and on Windows the
      failure mode is the app quitting without an installer appearing.

- [ ] **Open TestFlight from a real iPhone.** The simulator has no TestFlight,
      so the store branch has been exercised only as far as the check: the
      manifest parses, the iOS entry is found, and the button says "Open
      TestFlight". Whether `launchUrl` reaches the app rather than Safari is
      untested on hardware.

- [x] **The Android APK is signed with a real release key** — done 2026-08-06.
      `build.gradle.kts` reads `android/key.properties` (git-ignored; see
      `key.properties.example`) and a release build with no key **fails** rather
      than falling back to the debug key, which is how the debug-signed
      pre-release got out in the first place.

      **The certificate every future release must match:**

      ```
      SHA-256  84615e60dd6dd5fd601b23accdca38c23c43ae7a8f85fc2e3d0e1c02f702e927
      SHA-1    7b1fea4481b49a061b44524cd863f5e927ee9614
      DN       CN=SpencerSmith, OU=SpencerSmithSite, O=SpencerSmithSite, L=US, ST=OH, C=US
      RSA 4096, alias `council`
      ```

      Check a build against it before publishing, rather than against memory:

      ```bash
      ~/Library/Android/sdk/build-tools/36.0.0/apksigner verify --print-certs \
        build/app/outputs/flutter-apk/app-release.apk
      ```

      Signed v2-only, which is correct here: v2 is verified by every Android
      from 7.0 and `minSdk` is 24, so no device that can install Council needs
      the v1 signature. (v3 is off, so key *rotation* is not available later.
      That mitigates a compromised key, not a lost one — the backup is still the
      only thing standing between a lost keystore and stranding every install.)

- [ ] **Say on the download page that this release cannot update over the
      pre-release.** The published 2026.8.2 APK is debug-signed, so Android will
      refuse to install the properly-signed build over it — the reader sees a
      failed install, and through the in-app updater it looks like the update
      is broken rather than like a one-time key change. They have to uninstall
      and reinstall once. This needs a line in the release notes and on
      `download.html`, and it is only true of the Android pre-release: no other
      platform is affected.

- [ ] **Remember `updates.json` when cutting a release.** The version, URL,
      byte count and sha256 all live there as well as on the download page, and
      the app reads only the former. `npm run check:council` in the site repo
      fails if the two disagree; nothing runs it automatically yet.

- [ ] Text-to-speech for a source, offline.
- [ ] Re-anchor annotations on corpus drift. The quote snapshot is stored and
      not yet used; an annotation whose offsets have moved is currently drawn
      where the offsets say. This matters more now that a corpus rebuild can
      replace a work's units wholesale.
- [ ] Collections of saved passages beyond bookmarks; more reading themes.
- [x] ~~Test on macOS~~ — done 2026-07-26. The app builds and runs there, and
      `integration_test/retrieval_test.dart` passes all 24 tests on it against
      the full library with every pack installed.
