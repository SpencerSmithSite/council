# Source roadmap

What Council holds, what it is missing, and where the missing material can
actually be obtained.

The goal is the teachings, writings and conciliar statements of every branch of
Christianity. This document is the map from that goal to specific documents and
specific archives, so that adding a tradition is a matter of executing a plan
rather than starting a search.

## Read this first: two constraints that shape everything

**Copyright is the binding constraint, not availability.** Almost everything
before roughly 1929 is public domain in the United States and freely
redistributable. Almost nothing after it is. This falls unevenly across
Christianity, and not by accident — the traditions that formed most recently
are exactly the ones whose defining documents are still in copyright:

| | Founded | Defining documents |
|---|---|---|
| Reformed, Lutheran, Anglican | 16th–17th c. | public domain |
| Methodist, Baptist, Quaker | 17th–18th c. | public domain |
| Adventist, Restoration | 19th c. | public domain |
| Pentecostal, Nazarene | 20th c. | **in copyright** |
| Post-Vatican II Catholic | 20th c. | **in copyright** |

So a corpus built only from what can be freely redistributed will
systematically under-represent Pentecostalism — the second-largest Christian
movement in the world — and modern Catholicism. That is a real limitation of
the app, not a gap to be quietly filled. Two of the 23 unsourced entries were
removed for exactly this reason: the Catechism of the Catholic Church and Lumen
Gentium are © Libreria Editrice Vaticana and had been recorded here as public
domain.

Where a tradition's own materials cannot be shipped, the honest options are its
**pre-copyright antecedents** (Wesley for the Holiness movement, the Azusa
Street periodicals for Pentecostalism), **linking out** rather than bundling,
or **saying the tradition is not covered**. Faking coverage with summaries is
what this project already spent several phases undoing.

**Verification status is recorded, not assumed.** Every archive below is marked
with whether it was actually checked. A list of plausible URLs written from
memory is precisely the kind of unverifiable content this corpus exists to be
free of.

## Where the corpus stands

| tradition | sources | volume |
|---|---:|---:|
| early-church | 389 | 56.26 M |
| ecumenical | 19 | 0.91 M |
| lutheran | 4 | 0.79 M |
| catholic | 4 | 0.58 M |
| reformed | 8 | 0.28 M |
| anglican | 1 | 0.04 M |
| eastern-orthodox | 2 | 0.004 M |
| methodist | 2 | 0.001 M |

**96% of the corpus is patristic.** Eight traditions have a database row;
Baptist, Pentecostal and Oriental Orthodox have a row and no content at all.
Eastern Orthodox and Methodist have entries so small they are effectively
placeholders.

## Archives

Checked on 2026-07-22 by request:

| archive | status | holds |
|---|---|---|
| newadvent.org/fathers | **200** | Ante-Nicene and Nicene fathers (already ingested) |
| ccel.org | **200** | Confessions, catechisms, Reformation and Puritan works |
| gutenberg.org | **200** | Wide, uneven; strongest on English-language classics |
| archive.org | **200** | Scanned conciliar and denominational material; OCR quality varies |
| documentacatholicaomnia.eu | **200** | Latin patristic and magisterial texts |
| vatican.va/archive | **200** | Councils and encyclicals — **mostly not redistributable** |
| orthodoxebooks.org | **200** | Orthodox texts; licence must be checked per item |
| newadvent.org/summa | **200** | Aquinas in English — **checked for real text, not an index** |

Checked and **not usable**:

| archive | status | note |
|---|---|---|
| quod.lib.umich.edu (EEBO) | 403 | Institutional access required |
| gameo.org (Mennonite encyclopedia) | 403 | Blocks automated access; approach for permission |
| anglican.net | no response | Dead or blocking |
| wesley.nnu.edu | no response | Dead; the Wesley Center corpus has moved |

**Rights are verified per work, not per archive.** CCEL declares
`Rights: Public Domain` in each text export's header, and checking it per file
is what caught its Westminster Confession edition, which declares nothing.

## Verified specific texts

Confirmed present on Project Gutenberg with an ID:

| work | tradition | Gutenberg |
|---|---|---|
| The Pilgrim's Progress — Bunyan | Baptist | 131 |
| The Imitation of Christ — à Kempis | Catholic | 1653 |
| Institutes of the Christian Religion — Calvin | Reformed | 45001 |
| Selected Sermons — Jonathan Edwards | Reformed | 34632 |
| The Journal — John Woolman | Quaker | 37311 |
| No Cross, No Crown — William Penn | Quaker | 44895 |
| The Great Controversy — Ellen White | Adventist | 25833 |
| The Book of Common Prayer (1662) | Anglican | 29622 (ingested) |

## The plan, in priority order

Priority weighs three things: how central the tradition is to the app's
purpose, whether its texts can actually be shipped, and how large the gap is.

### 1. Baptist — a defined tradition with nothing in it

The database has a `baptist` row and zero sources, while Baptists are among the
largest Protestant families in the world.

- **Second London Baptist Confession (1689)** — the central document. Public
  domain. Source to confirm.
- **New Hampshire Confession (1833)**; **Philadelphia Confession (1742)**.
- **Bunyan** — *Pilgrim's Progress* (131) and *Grace Abounding*.
- **Spurgeon** — sermons, enormous in volume; on CCEL rather than Gutenberg.
- **John Gill**, *Body of Divinity*; **Andrew Fuller**.

### 2. Methodist and Wesleyan — two placeholder entries

- **Wesley's Standard Sermons** (44 sermons) and **Explanatory Notes upon the
  New Testament** — the doctrinal standards of Methodism. Public domain.
- **Wesley's Journal**; **Charles Wesley's hymns**, which carry as much
  Methodist doctrine as the prose.
- **John Fletcher**, *Checks to Antinomianism*.
- 67 Gutenberg hits for "wesley" need filtering — most are not John Wesley.

### 3. Eastern Orthodox — 0.004 M characters

- **The Philokalia** — the current entry is an unsourced abridgement.
  Translation rights need care: the standard English translation is modern and
  in copyright.
- **John of Damascus**, *An Exact Exposition of the Orthodox Faith* — already on
  New Advent, so this is an ingestion task, not a hunt.
- **The Longer Catechism of Philaret** (1830); **the Confession of Dositheus**
  (1672).
- Palamas and the hesychast corpus — mostly modern translations, mostly
  restricted.

### 4. Anabaptist, Mennonite, Quaker — absent entirely

- **Schleitheim Confession (1527)**; **Dordrecht Confession (1632)**.
- **Menno Simons**, *Foundation of Christian Doctrine*.
- **Martyrs Mirror** — large, and the standard English text is old enough to be
  free.
- **Barclay's *Apology for the True Christian Divinity*** — the systematic
  statement of Quaker theology.
- **Fox's *Journal***, **Penn** (44895), **Woolman** (37311).

### 5. Anglican beyond the Articles

One source, now that the Thirty-Nine Articles are properly sourced.

- **Book of Common Prayer 1662** — already fetched for the Articles; the
  liturgy itself is the larger part and is not yet ingested.
- **Hooker**, *Of the Laws of Ecclesiastical Polity*.
- **The Homilies** (1547, 1571) — referenced by Article 35, so the corpus
  currently cites a document it does not contain.
- **Newman**, *Apologia* and the Tracts.

### 6. Reformed — finish what is started

- **Westminster Confession of Faith** — still unsourced. CCEL's edition was
  rejected: it interleaves the PCUS and UPCUSA recensions with variant readings
  inline (`yet [PCUS are they] [UPCUSA they are] not sufficient`), the same
  defect that disqualified Schaff's *Creeds of Christendom*. A clean edition is
  needed.
- **Scots Confession (1560)**, **Second Helvetic (1566)** — both still stubs.
- **Calvin's *Institutes*** (45001) — the single largest Reformed work absent.
- **Owen**, **Turretin**, **Bavinck** (Dutch, translations vary in status).

### 7. Restoration and Adventist — absent, and freely available

Unusual among the newer movements in that their founding documents predate
copyright.

- **Alexander Campbell**, *The Christian System*; **Barton Stone**.
- **Ellen White** — *The Great Controversy* (25833) and others. The Ellen G.
  White Estate publishes her complete works and their status should be
  confirmed directly rather than assumed from age.

### 8. Pentecostal and Holiness — the hard case

The `pentecostal` row exists and will stay empty under a public-domain-only
policy. Honest options:

- **The Apostolic Faith** (Azusa Street periodical, 1906–1908) — public domain,
  and the closest thing to a primary founding document.
- **Phoebe Palmer**, **William Booth**, **Charles Finney** — the Holiness
  antecedents, all public domain.
- Modern statements of faith — Assemblies of God, Church of the Nazarene,
  Foursquare — are **in copyright**. Link out, or state plainly that the
  tradition is represented only by its antecedents.

### 9. Catholic beyond the medievals

- **Aquinas**, *Summa Theologica* — the English translation is public domain and
  New Advent hosts it at `/summa/`, a section the ingester has never touched.
  This is the largest single win available in the Catholic tradition. Checked:
  `/summa/1001.htm` returns the article itself — objections, *sed contra* and
  replies — and not a chapter list. That check matters here specifically,
  because two sources already in the corpus turned out to hold New Advent index
  pages rather than text.
- **Council of Trent** — already ingested. **Vatican I** — public domain.
- **Vatican II and the Catechism** — © Libreria Editrice Vaticana, **not
  shippable**. This is the gap that cannot be closed by finding a better
  archive.

### 10. Oriental Orthodox, Assyrian, and the rest

`oriental-orthodox` is defined and empty. Coptic, Ethiopian, Syriac and
Armenian material in English translation is thin, scattered, and often modern.
Realistically this needs a dedicated search rather than a line in a plan, and
should be scoped honestly before being promised.

## Immediate next steps

1. **Aquinas from `newadvent.org/summa/`** — largest single gain, an archive
   already trusted and already parsed by existing tooling, and verified to
   serve article text rather than indexes.
2. **Second London Baptist Confession (1689)** — fills an empty tradition with
   one short document.
3. **Wesley's Standard Sermons** — fills a placeholder tradition with its actual
   doctrinal standard.
4. **Re-ingest `Adversus haereses` and *The Harmony of the Gospels***, which
   currently hold chapter indexes rather than chapter text.
5. **A clean Westminster Confession**, the last high-value document still
   unsourced.

Once two or three of these land, the pack split should be revisited: the
boundaries live in `tools/data/packs.json` and re-splitting is an edit and a
rebuild, not a code change.
