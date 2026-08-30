# Source roadmap

What Council holds, what it is missing, and where the missing material can
actually be obtained.

The goal is the teachings, writings and conciliar statements of every branch of
Christianity. This document is the map from that goal to specific documents and
specific archives, so that adding a tradition is a matter of executing a plan
rather than starting a search.

## Who is in, and at what granularity

Both questions are settled, and the answers live in
[`tools/data/traditions.json`](tools/data/traditions.json) rather than here, so
that the app and this document cannot disagree about them.

**Who is in: Nicene in substance.** A body is covered if it affirms the
Trinity, the full deity and full humanity of Christ, and the incarnation,
atoning death and bodily resurrection. The test is doctrinal *content*, not
creedal form — which is the part that does the work. Non-creedal groups pass:
the Brethren, the Restorationists and the Adventists all decline to recite
creeds as a matter of conviction, and all teach what the creeds state. Refusing
a creed is not denying its doctrine, and a test that could not tell those apart
would exclude several traditions this app exists to represent.

What it excludes is not a matter of taste either. The Latter-day Saints,
Jehovah's Witnesses, Oneness Pentecostals, Christadelphians, Christian Science
and the Unitarian bodies each fail on the same clause, and each is recorded in
the taxonomy file next to which one. Note the seam inside Pentecostalism:
Trinitarian Pentecostal bodies are in and Oneness Pentecostalism is out, so
"Pentecostal" is not a single verdict.

Two usable proxies when a body is unclear: whether the historic churches
recognise its baptism (Catholic and Orthodox recognition is a strong signal —
Baptist and Methodist baptisms are recognised, LDS and Jehovah's Witness ones
are not), and the World Council of Churches basis, whose membership test is
explicitly Trinitarian.

**At what granularity: families, about thirty of them.** The structure is
**branch → family → denomination**, and this corpus is being built at the
family level. That is a decision forced by arithmetic rather than preference:
the World Christian Database counts roughly 45,000 denominations, so "all of
them" is not a target, it is a category error. Families are completable — there
are 31 — and denominations are the next tier of work, not this one.

Sources are filed at the family level. Branches are the split-by-split backbone
(431, 451, 1054, 1517), plus a *shared* branch holding scripture, the Fathers
and the councils, which belong to every branch rather than to one.

## Read this first: two constraints that shape everything

**Copyright is a real constraint and this document had been overstating it.**
Audited 2026-08-30, and the audit is recorded here because the error was
systematic rather than incidental: the table below used to date each *movement*
and infer the status of its *documents*. Those are different facts. A body
founded in 1901 can have written its statement of faith in 1916, and 1916 is
public domain.

The rule in the United States is publication plus 95 years, so as of 2026
everything published through **1930** is free. Three corrections follow from
applying it to documents instead of movements:

| | Founded | Defining documents |
|---|---|---|
| Reformed, Lutheran, Anglican | 16th–17th c. | public domain |
| Methodist, Baptist, Quaker | 17th–18th c. | public domain |
| Adventist, Restoration | 19th c. | public domain |
| Holiness (Nazarene, Free Methodist, Salvation Army) | 19th–20th c. | **founding documents public domain**, current ones not |
| Pentecostal (Assemblies of God, Foursquare) | 20th c. | **founding documents public domain**, current ones not |
| Post-Vatican II Catholic | 20th c. | **in copyright**, and no route around it |

* **Holiness is not a 20th-century copyright problem.** The Salvation Army's
  eleven doctrines date from 1878 and Booth's *In Darkest England* from 1890;
  the Free Methodist *Doctrines and Discipline* runs from 1860 and its 1915 and
  1923 printings are on archive.org; the Church of the Nazarene's first
  *Manual* is 1908. What is in copyright is each body's *current* edition, and a
  current edition is not a founding document.
* **Pentecostalism is not structurally excluded either.** The Assemblies of God
  *Statement of Fundamental Truths* was adopted in 1916 and the Foursquare
  *Declaration of Faith* in 1923 — both public domain, both the actual
  confessional documents of the two largest Trinitarian Pentecostal bodies. The
  Azusa Street periodical *The Apostolic Faith* ran 1906–1908 and Aimee Semple
  McPherson's *This Is That* is 1923, on archive.org. The line this file used to
  take — that the movement can only ever appear through antecedents — was
  wrong, and it is the one claim here that mattered most, because Pentecostalism
  is the second-largest Christian movement in the world.
* **Post-Vatican II Catholicism is genuinely closed.** The Catechism of the
  Catholic Church and the Vatican II constitutions are © Libreria Editrice
  Vaticana, and no archive changes that. Two of the 23 unsourced entries were
  removed for exactly this reason. What *is* open and entirely absent is the
  pre-1931 magisterium: Vatican I, the Baltimore Catechism (1885), and every
  encyclical through *Casti Connubii* (1930).

**"In copyright" and "no clean transcription" are different problems and had
been getting the same label.** A rights problem has no solution; a transcription
problem has three — find a better archive, corroborate a scan against a second
witness the way `ingest_owen.py` does, or wait for someone to key it. Several
works filed here as copyright-blocked were only ever transcription-blocked, and
one — the Second Helvetic Confession — turned out to be neither. Anything now
recorded as closed says which of the two it is.

**The date is derived, not written down.** `PD_CUTOFF` in
`ingest_reformation.py` used to be the literal `1929`, which was right when it
was written and silently wrong from the following January; by the time of this
audit it was refusing two years of publishing for no reason. It is now
`date.today().year - 95`.

**A whole category is still unexamined: US works published 1929–1963 required
renewal, and most were never renewed.** That covers, among other things, the
English *Rudder* (1957) and the standard English Schleitheim. Renewal is
checkable per title in the Stanford Copyright Renewal Database, which is behind
a bot challenge and cannot be queried from a script here — so it is a manual
lookup, and nothing should be claimed public domain on this basis until someone
does it.

Where a tradition's own materials genuinely cannot be shipped, the honest
options are its **pre-copyright antecedents**, **linking out** rather than
bundling, or **saying the tradition is not covered**. Faking coverage with
summaries is what this project already spent several phases undoing.

**Verification status is recorded, not assumed.** Every archive below is marked
with whether it was actually checked. A list of plausible URLs written from
memory is precisely the kind of unverifiable content this corpus exists to be
free of.

## Where the corpus stands

As of 2026-07-27 (corpus v15):

| tradition | sources | volume | previous build |
|---|---:|---:|---:|
| reformed | 145 | 174.152 M | 176.268 M |
| baptist | 82 | 152.050 M | 142.706 M |
| early-church | 402 | 80.781 M | 80.781 M |
| scripture | 5 | 22.382 M | 22.382 M |
| catholic | 7 | 15.024 M | 15.050 M |
| anglican | 12 | 5.833 M | 5.988 M |
| methodist | 3 | 5.505 M | 5.465 M |
| lutheran | 10 | 2.860 M | 2.894 M |
| ecumenical | 18 | 0.912 M | 0.912 M |
| eastern-orthodox | 3 | 0.575 M | 0.575 M |
| oriental-orthodox | 0 | 0 | 0 |
| pentecostal | 0 | 0 | 0 |

687 sources, 104,115 units, **460.1 M characters**. See Phase 35 in `PLAN.md`.

**Reformed shrank while gaining Owen's 31 works, and that is the good news in
this build.** The previous one shipped 30 M characters of CCEL's own reference
apparatus as if it were text: every export ends with a colophon and a numbered
list resolving each hyperlink to a `file:///ccel/...` path, and a page of that
is long enough to clear any floor expressed in characters. 3,438 units of it
were in the corpus. A second defect in the same family — front-matter skipping
that treated a *closing* index as a reason to discard everything before it —
was silently truncating short works to their tail matter, costing twelve works
outright and reducing five of Charnock's discourses to about an eighth of
themselves. Both are fixed; the net is that Reformed lost more junk than Owen
added.

**The shape of the corpus changed, not just its size.** It was a patristic
library with a confessional appendix — 402 of 446 sources were early-church,
Reformed had seven and Baptist two. A question about assurance or the atonement
could be answered out of Augustine and Chrysostom without one voice from the
tradition that spent four centuries arguing about them. Early-church is now 13%
of the volume rather than 65%, and nothing was removed to make that true.

**Eastern Orthodox is no longer zero.** It was, for exactly one build, after
both its entries were removed as misattributed — one of them filed *Pilgrim's
Progress* as the Philokalia. It now holds Philaret's *Longer Catechism*, the
Confession of Dositheus and the *Book of Needs*. Still the smallest covered
tradition, and still short of a Philokalia, because there is no public-domain
English translation of one.

**Two traditions remain honestly empty**, and are meant to stay that way until
their material can actually be shipped: Oriental Orthodox and Pentecostal. The
second is the structural one — Pentecostalism's defining documents are
20th-century and in copyright, so a corpus built from what is freely
redistributable will under-represent the second-largest Christian movement in
the world. That is a limitation of the app, not a gap to be quietly filled.

Size is not the measure that matters. Ecumenical is 0.2% of the corpus and
holds the acts of all seven ecumenical councils. What changed for Reformed and
Baptist is not that they grew large but that they went from confessional
documents alone to the commentary, preaching and controversy those documents
came out of.

### The second axis: having a work is not holding its text

A tradition can be *covered* and still be wrong, because "we have the City of
God" and "we have 8,259 characters describing the City of God" look identical
in every table above. Coverage is one axis; **completeness** is the other, and
it is invisible to a source count.

Three defects produce it, and they are told apart differently:

| defect | what it looks like | what finds it |
|---|---|---|
| generated filler | plausible prose asserting nothing | `audit_corpus.py` — recursive relative clauses |
| a contents page filed as the work | real prose, right author, right URL, wrong length | `audit_completeness.py` — markers vs sentences, and part counts |
| two works interleaved under one title | genuine text, wrong byline | `source_url` is missing; read the unit titles in order |

Run all three before and after any corpus change. `TODO.md` is the running
ledger of what each has found and what is still outstanding.

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
| wesley.nnu.edu | no response | Dead. **Superseded by CCEL's Wesley shelf** — see the Methodist section |

**Rights are verified per work, not per archive.** CCEL declares
`Rights: Public Domain` in each text export's header, and checking it per file
is what caught its Westminster Confession edition, which declares nothing —
and which turned out to have a second, worse problem besides: its paragraph
numbering is taken from *The Constitution of the Presbyterian Church (U.S.A.)*,
a modern denominational publication, and it prints the PCUS and UPCUSA
recensions in parallel with the variants inline.

**Most CCEL exports have no `Rights:` line at all**, which the Reformation
ingest of 2026-07-26 discovered at scale: the field is present for Calvin and
Matthew Henry and absent for Spurgeon, Owen, Edwards and Bunyan. Refusing
everything unstated would have dropped most of the Puritans; accepting
everything unstated is how in-copyright text acquires a public-domain label.
The rule `ingest_reformation.py` settled on, and records against every source
it creates:

1. **CCEL states public domain** — taken at face value.
2. **Otherwise, publication date** — the work is in the author's own English,
   so no translator's copyright can attach, *and* the author died before 1929.

Under (2) only, a declared modern print basis refuses the work: Owen died in
1683, but his *Mortification of Sin* is set from a Banner of Truth printing of
1967, and a modern edition can carry modern editorial matter. Under (1) it does
not, because an explicit clearance outranks an inference drawn from a date the
archive can see as well as we can.

3. **Or corroboration against the printing it claims to descend from** — added
   2026-07-27, and the only way past rule (2). A modern print basis makes a work
   *unproven*, not proven modern, and the difference is measurable: Banner of
   Truth's Owen is a facsimile of William H. Goold's edition of 1850-55, which
   is on archive.org as page scans. `ingest_owen.py` scores each transcription's
   word pairs against those scans and admits it only on a match. All 31 works
   scored 87-98% against the volume that holds them, where Calvin's *Institutes*
   measured the same way scores 33% and Owen's *own other works* score in the
   forties — so the test separates "this is that printing" from "this is the
   same author", which is the confusion that would otherwise let something
   through. The rights line on each source records the score.

   The same route settled the *Treasury of David*, which was a text problem
   rather than a rights one: CCEL serves it only as page images, so it comes
   instead from Ted Hildebrandt's 2007 digitisation for Gordon College, with
   every one of the 150 psalms scored against the Victorian printings (median
   97%, lowest 91%). The negative control there is Calvin *on the Psalms* —
   same genre, same verses, same book — at 33%.

   This is the same two-witness standard `ingest_orthodox.py` already used, and
   the rule it generalises to is: a clean transcription may stand in for a
   printing whenever it can be shown to *be* that printing, and not otherwise.

The consequence worth stating plainly: **translated works whose export states
no rights are refused**, because a translation made in 1950 is in copyright
however old its original. Luther's *Bondage of the Will* is the notable
casualty — CCEL credits no translator and states nothing.

**Wikisource states its terms per page, and the terms differ per page.** The
1689 Baptist confession's page declares `{{no source}}` and had to be
corroborated against a second edition; the 1690 Westminster page carries
`{{PD-UKGov}}` and needed no such thing. Reading the banner is the check.

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
| The Book of Common Prayer (1662) | Anglican | **Not on Gutenberg, and 29622 is not it.** This row has been wrong twice: first "(ingested)" when the database had no such source, then "confirmed present on Gutenberg" when 29622 is the *Scottish* Prayer Book of 1912 — author "Episcopal Church in Scotland", and the string "1662" appears nowhere in the file. Checked 2026-07-27. See `TODO.md` for the routes tried |
| The Book of Common Prayer — Scottish, 1912 | Anglican | 29622, cached. Public domain on date and genuinely Anglican, worth ingesting *as the Scottish book*. Mostly lectionary and psalter tables, which need separating from the liturgy first |

## The plan, in priority order

Priority weighs three things: how central the tradition is to the app's
purpose, whether its texts can actually be shipped, and how large the gap is.

### 1. Baptist — a defined tradition with nothing in it

The database had a `baptist` row and zero sources, while Baptists are among the
largest Protestant families in the world.

- [x] **Second London Baptist Confession (1689)** — done, 2026-07-22. 32
  chapters, 160 paragraphs, 0.083 M chars. `tools/ingest_baptist.py`.

  Four editions were examined and three rejected, which is the part worth
  keeping:

  | edition | verdict |
  |---|---|
  | Internet Archive `confeo00phil`, 1765 Philadelphia printing | **OCR destroyed.** Long-s read as `f`: `Chrift` ×48, `Christ` ×0 |
  | `founders.org` | **Wrong text.** The confession *in Modern English* — a paraphrase Founders Press sells |
  | `ccel.org` | has no edition of it |
  | Wikisource | clean original wording, all 32 chapters — but its own first line is `{{no source}}` |

  Wikisource's text is right and its provenance is not stated, so **every
  paragraph is verified against a second, independent edition that does state
  its terms**: Chapel Library's 2016 typesetting, whose notice reads *"©
  Copyright 2016 Chapel Library: compilation, annotations. Original texts are
  in the public domain."* Their compilation is theirs; the 1689 text is not.
  Two independent transcriptions agreeing is a stronger claim than one
  asserting an edition.

  The verification earned its keep twice. It caught the last chapter running
  past its own end and swallowing the closing list of signatories into the
  paragraph on the last judgment — well-formed prose that no structural check
  would question. And it forced the metric to be right: the first attempt
  matched word *order*, which failed a paragraph whose every word was present
  because Chapel prints a running header across the middle of it. The gate is
  vocabulary, because vocabulary is what the two real risks move — destroyed
  OCR and modernisation both collapse it.

- [x] **First London Baptist Confession (1644)** — done, 2026-07-26. 53
  articles, 0.032 M chars. `tools/ingest_first_london.py`.

  Shipping the 1689 without the 1644 reads as though Baptists began in 1689.
  They did not: 1644 is the founding document of the Particular Baptists,
  written while they were being prosecuted for it, and it says two things the
  1689 does not put as sharply — baptism *by dipping* stated outright in
  article XL, and the church's independence of the magistrate in article
  XLVIII, which is the reason the confession exists.

  Text from **reformedreader.org**, the 1644 first edition in its original
  article order, bracketing the later impressions' additions. Corroborated
  against **Underhill's *Confessions of Faith*, Hanserd Knollys Society,
  1854**, on archive.org.

  **What that corroboration is worth, stated rather than implied.** Underhill
  prints the *1646 second impression*, "corrected and enlarged", so it is not a
  second transcription of the same words and no word-identity check against it
  would mean anything — article I was rewritten wholesale between the two. What
  it does settle is every way a confession found on the open web actually goes
  wrong: it fixes the article count and order, proves this is the whole
  document rather than an abridgement, and its 17th-century vocabulary proves
  the text has not been quietly modernised into a paraphrase. Measured across
  the 53 articles the vocabulary overlap is 93% median, 71% lowest; the gate is
  set to what that supports and no higher.

  Two numbering defects are **asserted rather than tolerated**: the 1644
  printing sets the 36th article as XXVI and the last as LII when the preceding
  article is already LII. Both are in Underhill; reformedreader marks the
  second `[sic]`. A page that has been silently re-edited now fails the
  ingester instead of shipping.

  Wikisource has no 1644 page, `the1689.com` and `baptiststudiesonline.com` did
  not respond, and `spurgeon.org/creeds/bc1644.htm` — which reformedreader's
  own footnote anchors still point at — is 404.

- [x] **Spurgeon** — done. The sermons (63 volumes) came from CCEL on
  2026-07-26; *The Treasury of David* on 2026-07-27, and separately, because
  CCEL has that one only as page images. Its six "text" exports are runs of
  `Image of page 73` around four thousand words of front matter — enough to
  clear every floor while containing none of the commentary, which is why
  `ingest_reformation.py` grew a gate counting placeholders per thousand
  characters.

  The text comes instead from Ted Hildebrandt's 2007 digitisation for Gordon
  College Biblical eLearning, which is a real text layer rather than OCR, drawn
  with permission from Phil Johnson's Spurgeon Archive transcription. All 150
  psalms, cut by Spurgeon's own divisions: the exposition, the collected
  explanatory notes and quaint sayings, and the hints to the village preacher.

  **Two other sources were rejected.** sacred-texts.com has the whole work in
  clean per-psalm HTML and its robots.txt sets `Content-Signal: ai-train=no,
  use=reference` — an express reservation against this use — behind a challenge
  that would have to be circumvented to read at all. An anonymous HTML
  transcription on archive.org is complete in structure but missing psalms 4,
  10, 11, 17-20, 22-24 and the whole of 119: 139 of 150, absent the two psalms
  most likely to be looked up.

  Corroborated psalm by psalm against archive.org's scans of the 1868-85
  printings, median 97% and lowest 91%, with Calvin *on the Psalms* as the
  negative control at 33% — the same genre expounding the same verses of the
  same book, which is the hardest case available and the one that shows the
  measure is reading the text rather than the subject.
- **New Hampshire Confession (1833)**; **Philadelphia Confession (1742)**.
- **Bunyan** — *Pilgrim's Progress* (131) and *Grace Abounding*.
- **John Gill**, *Body of Divinity*; **Andrew Fuller**.

### 2. Methodist and Wesleyan — two placeholder entries

- [x] **Wesley's sermons** — done, 2026-07-22. Not the 44 Standard Sermons but
  all **141** of *Sermons on Several Occasions* (1771), 3.59 M chars, from
  CCEL, which declares `Rights: Public Domain` in the export's own header. The
  edition states its own standing on its title page: *"to which reference is
  made in the trust-deeds of the Methodist Chapels, as constituting, with Mr.
  Wesley's notes on the New Testament, the standard doctrines of the Methodist
  connexion."* The 44 are the subset the trust-deeds bind and are its opening
  run — Sermon 1 is *Salvation by Faith*, Standard Sermon 1 — so taking the
  whole collection costs nothing and avoids this project deciding which of a
  man's sermons count.

  Needed no corroborating second edition, unlike the Baptist confession: the
  defect there was Wikisource stating neither rights nor base edition, and
  CCEL states both. `tools/ingest_wesley.py`.

  This replaced a legacy stub — "Wesleys Standard Sermons", 6 units, no author,
  no URL — and doing so exposed that the loader only displaced stale entries
  matching the **new** source's exact title. A real edition rarely shares a
  title with the paraphrase filed in its place, so the two would have coexisted
  and the corpus would have gained a second Wesley. Ingesters now name what
  they supersede.

- **Explanatory Notes upon the New Testament** — the other half of the
  doctrinal standard, and still missing. Public domain.

  **The replacement for the dead Wesley Center archive is CCEL**, whose Wesley
  shelf was enumerated on 2026-07-22 rather than guessed at:

  | path | work | status |
  |---|---|---|
  | `/ccel/wesley/sermons` | Sermons on Several Occasions | **ingested** |
  | `/ccel/wesley/notes` | Explanatory Notes upon the New Testament | next |
  | `/ccel/wesley/journal` | The Journal | |
  | `/ccel/wesley/perfection` | A Plain Account of Christian Perfection | |
  | `/ccel/wesley/hymn` | Hymns | |
  | `/ccel/wesley/works` | Collected works | overlaps the above; check before use |

  Note that `perfection` is *A Plain Account of Christian Perfection*, a
  different work from the unprovenanced stub already in the corpus, which is
  *A Plain Account of the People Called Methodists*. Ingesting one will not
  replace the other, and assuming it would is how a corpus ends up with a
  paraphrase sitting quietly beside a real edition.
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

### 4. Anabaptist, Mennonite, Quaker — mostly done, 2026-08-02

- [x] **Quaker** — done. Barclay's *Apology*, both volumes of Fox's *Journal*,
  Penn's *No Cross, No Crown*, Woolman's *Journal*, Sewel's *History*.
- [x] **Martyrs Mirror** — done. van Braght, and currently the whole of the
  Anabaptist tradition.
- [ ] **Menno Simons** — **found 2026-08-30, not yet ingested.** English
  Wikisource carries nine works under *The Complete Works of Menno Simons/*,
  1.04 M characters of rendered text, including *The True Christian Faith* and
  the *Reply to Gellius Faber*. Not the whole Funk edition, but it is the
  tradition's systematics, which it has never had.
- [ ] **Dordrecht Confession (1632)** — **found 2026-08-30, not yet ingested.**
  Wikisource, *Dordrecht Confession of Faith*, 29,459 characters, complete.
- [ ] **Schleitheim Confession (1527)** — still not found. Gutenberg and
  Wikisource both return nothing under *Schleitheim*, *Brotherly Union* or
  *seven articles*. See `TODO.md`.

### 5. Anglican beyond the Articles

One source, now that the Thirty-Nine Articles are properly sourced.

- **Book of Common Prayer 1662** — already fetched for the Articles; the
  liturgy itself is the larger part and is not yet ingested.
- **Hooker**, *Of the Laws of Ecclesiastical Polity*.
- **The Homilies** (1547, 1571) — referenced by Article 35, so the corpus
  currently cites a document it does not contain.
- **Newman**, *Apologia* and the Tracts.

### 6. Reformed — finish what is started

- [x] **Westminster Confession of Faith** — done, 2026-07-22. 33 chapters,
  172 paragraphs, 0.065 M chars, replacing a 13-unit 4,157-character paraphrase
  that had been sitting under the name of the most important Reformed document
  in the corpus. `tools/ingest_westminster.py`.

  Four editions examined, three rejected:

  | edition | verdict |
  |---|---|
  | CCEL `anonymous/westminster3` | PCUS and UPCUSA recensions interleaved with variants inline; declares no rights; numbering taken from a modern PCUSA publication |
  | Wikisource, *Humble Advice* (1647) | Scan-backed and proofread — the best provenance available — but **9 of 33 chapters exist**. Its `{{incomplete}}` banner was checked, not believed |
  | Wikisource, Carruthers 1946 | container page, no subpages, nothing there |
  | Wikisource, **Ratification Act 1690** | complete, tagged `{{PD-UKGov}}`, still the subordinate standard of the Church of Scotland |

  **The cost is orthography.** The 1690 text is the parliamentary record, so it
  is seventeenth-century spelling and almost unpunctuated — seven commas in
  seventy-five thousand characters, "Gods eternall Decree", "Christs sake". That
  is a real cost to reading it and it is accepted rather than hidden, because
  the alternative on offer was a paraphrase wearing the document's name. An
  authentic text with awkward spelling beats a fluent text that is not the
  document. Worth revisiting if a complete, punctuated, clearly-licensed edition
  appears — the 1647 Wikisource transcription would be ideal if it is ever
  finished.

  **A punctuated edition was looked for afterwards and not found.** CCEL has
  no other Westminster file (`westminster`, `4`, `5` all 404); Gutenberg has
  none; and archive.org's most promising hit, `westminsterconf00unknuoft`,
  is titled *The Westminster Confession of Faith*, has clean punctuated OCR
  with no long-s damage — and does not contain the confession. It is
  Macpherson's 1881 *commentary*, "with Introduction and Notes", scanned from
  a 1958 impression. The phrase "Of the Holy Scripture" appears in it zero
  times. Checking that before parsing is the only reason it was caught; it is
  the third time in this corpus a title has promised a text and delivered
  something else.

  Verified by asserting the **paragraph count of every chapter** against the
  original, not merely the chapter count. The transcription numbers some
  paragraphs in bold and some as bare digits, and numbers the opening paragraph
  of some chapters and not others; matching one form silently absorbed 1.5 and
  1.8 into their neighbours. Chapter 31 having five paragraphs rather than four
  is what distinguishes the original from the American revision of 1788.
- [x] **Scots Confession (1560)** — done, 2026-07-23. 25 chapters, 0.041 M
  chars, replacing a 6-unit 1,882-character stub. `tools/ingest_scots.py`.
  Text from Wikisource (declared `{{PD-old}}` — public domain by age, which for
  a 1560 document is beyond question), with each chapter verified against
  creeds.net's independent transcription. The preface is deliberately omitted:
  it is a non-doctrinal salutation that neither creeds.net nor Schaff carries in
  this rendering, so it could not be corroborated, and the corpus does not ship
  what it cannot check.
- [x] **Second Helvetic (1566)** — **done 2026-08-30**, `tools/ingest_schaff.py`.
  30 chapters, 185 K characters, public domain.

  This entry was wrong, and the sentence that made it wrong was *"Schaff's
  Creeds of Christendom has the confession only in the Latin original."* It has
  the Latin in the body of vol. III and an **English version as an appendix**,
  which Schaff added in the third edition for the stated reason that the
  volumes had begun to be sold separately — so a reader of vol. III alone could
  no longer be referred to the summary in vol. I. The rest of the entry stands:
  the 1966 Cochrane translation on `ccel.org/creeds/helvetic.htm` is © West-
  minster Press and is still not usable.

  The generalisation worth keeping is about editions rather than about this
  document. "Schaff has it in Latin" was true of the edition someone looked at
  and false of the one CCEL serves, and nothing in the note recorded which had
  been checked. A rights or language verdict needs the edition attached to it.
- [x] **Calvin's *Institutes*** — done, 2026-07-26, with 45 volumes of his
  commentaries. `tools/ingest_reformation.py`.
- [x] **Owen** — done, 2026-07-27. All 31 works, from Goold's edition of
  1850-55. `tools/ingest_owen.py`.
- **Turretin**, **Bavinck** (Dutch, translations vary in status).

### 7. Restoration and Adventist — half done, 2026-08-30

Unusual among the newer movements in that their founding documents predate
copyright. Both were recorded here as blocked on a schema decision rather than
on a text; the taxonomy settled the rows, and one of the two was ingested the
same day.

- **Adventist — done.** Ellen G. White, five works, from CCEL rather than the
  Gutenberg route this section used to name. That is the correction worth
  keeping: Gutenberg has two of her books, CCEL has five, and the entry here
  pointed at the smaller archive because it was the one that had been searched.
  `tools/ingest_adventist_holiness.py`.
- **Alexander Campbell**, *The Christian System* — not on Gutenberg or
  Wikisource (2026-08-30), and **not on CCEL either**: the `campbell` author
  page there is J. M. Campbell, a Scot, and there is no `acampbell` or `stone`
  page at all. Three archives, none of them holding the Restoration movement's
  systematic statement.
- **Thomas Campbell**, *Declaration and Address of the Christian Association of
  Washington* (1809) — on English Wikisource at 160,942 characters, fetched and
  measured 2026-08-30. Two caveats that decide whether it can be ingested as it
  stands: Wikisource tags it **not backed by a scanned copy**, meaning no one
  has proofread it against a page image, and the rendered page has **no
  headings** — the Declaration, the Address, the thirteen Propositions and the
  Appendix arrive as one undivided run of text. Unit boundaries would have to
  be inferred from the prose, which is a different and riskier job than reading
  a document's own structure.

### 8. Pentecostal and Holiness — one of them answered

**Holiness — done 2026-08-30, as antecedents.** This section's own framing
turned out to be the right one and is now what shipped: the family is
represented by the teaching its denominations came out of, because the
denominations themselves are twentieth-century and in copyright. Wesley's *A
Plain Account of Christian Perfection* carries the doctrine, Finney six works
and Hannah Whitall Smith three carry it into the nineteenth century, and Thomas
Upham — Phoebe Palmer's colleague — carries the Fénelon and Guyon strand that
came with it. Palmer herself has a CCEL author page with no works on it, and
**William Booth has no CCEL page at all**, so the Salvation Army is still
unrepresented. The pack description states the gap rather than implying
coverage.

**Pentecostal stays empty**, and the reasoning is unchanged and structural:

- **The Apostolic Faith** (Azusa Street periodical, 1906–1908) — public domain,
  and the closest thing to a primary founding document. Not yet located as a
  transcription.
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
- **Council of Trent** — already ingested. **Vatican I** — **ingested
  2026-08-30** from English Wikisource, `ingest_wikisource.py`: the dogmatic
  constitutions *Dei Filius* and *Pastor Aeternus* as their prologues and
  chapters, the definition of papal infallibility among them. *Petri
  Privilegium* — Manning's three pastoral letters on the council — is on the
  same archive and was not taken: it is a book about the council rather than
  the council's acts.
- **Leo XIII, thirty encyclicals and letters** — ingested the same day, from
  the Benziger collection of 1903. The Catholic tradition had held Aquinas,
  Trent and à Kempis and no papal magisterium whatever. The Latin incipits and
  the dates were parsed out of each document's own dateline rather than typed.
- **Vatican II and the Catechism** — © Libreria Editrice Vaticana, **not
  shippable**. This is the gap that cannot be closed by finding a better
  archive.

### 10. Oriental Orthodox, Assyrian, and the rest

**The Church of the East branch is open as of 2026-08-30**, and not by the route
this section expected. It had been queued against archive.org scans, needing the
two-witness method; English Wikisource turned out to hold **Badger's *The
Nestorians and their Rituals*, volume II** fully transcribed and `PD-old`, so it
went in as proofread text. What it is — an Anglican chaplain's examination of
the church's doctrine, arranged against the Thirty-Nine Articles and built out
of long quotations from that church's own service books — is recorded on the
source and in the pack description rather than left for a reader to discover.

Two things this branch still wants, both blocked on text and not on rights:

- **Abdisho bar Berika, *The Marganitha*** (Book of the Pearl) — the church's
  own doctrinal manual. Wikisource's page is 1,028 characters of stub; no full
  transcription has been found.
- **Nestorius, *The Bazaar of Heracleides*** (Driver & Hodgson, 1925) — scans
  and raw OCR only, with no clean transcription to corroborate against, so the
  two-witness method has only one witness.

Also worth recording, because it is invisible from the tradition counts: **the
East Syriac liturgy is already in the app**, as *The Liturgy of the Blessed
Apostles* in the Ante-Nicene Fathers, filed under Early Church. It was not
re-filed to this branch, and the reason is structural rather than editorial —
see the phase note in `PLAN.md`: moving a source between traditions moves it
between fragments, and fragments are only disjoint within a single build, so a
reader holding the old fragment would collide on install.

`oriental-orthodox` is still one work. Coptic, Ethiopian, Syriac and Armenian
material in English translation is thin, scattered, and often modern. The
located exception is the **Kebra Nagast** (Budge, 1922) — see the copyright
audit above.

## Immediate next steps

1. **Aquinas from `newadvent.org/summa/`** — largest single gain, an archive
   already trusted and already parsed by existing tooling, and verified to
   serve article text rather than indexes.
2. ~~**Second London Baptist Confession (1689)**~~ — done 2026-07-22.
3. **Wesley's Standard Sermons** — fills a placeholder tradition with its actual
   doctrinal standard.
4. **Re-ingest `Adversus haereses` and *The Harmony of the Gospels***, which
   currently hold chapter indexes rather than chapter text.
5. ~~**A clean Westminster Confession**~~ — done 2026-07-22.
6. ~~**Scots Confession (1560)**~~ — done 2026-07-23. Second Helvetic deferred
   (1966 English translation is in copyright; see the Reformed section).

Once two or three of these land, the pack split should be revisited: the
boundaries live in `tools/data/packs.json` and re-splitting is an edit and a
rebuild, not a code change.

---

## The copyright audit — 2026-08-30

Every work this file or `TODO.md` had written off was re-checked against the
question *is the text actually in copyright*, rather than *did the archive I
tried have it*. Located means found and its identifier recorded, not believed to
exist.

**Rights are settled for everything in this section. What separates the two
tables is text quality, which is a different problem with different remedies.**
archive.org holds scans and their raw OCR, and this corpus refuses uncorrected
OCR — about one error per hundred characters, which in an app whose purpose is
quoting a source accurately is a regression. So a scan is a route in only
through the two-witness method `ingest_owen.py` and `ingest_treasury.py`
already use: a clean transcription may stand in for a printing whenever it can
be shown to *be* that printing.

### Public domain, located, and worth having

| work | date | where | closes |
|---|---|---|---|
| **Alexander Campbell**, *The Christian System* | 1839 | archive.org `christiansystem010camp` | The Restoration movement's systematic statement. Recorded here as "not found" after Gutenberg and Wikisource were searched; it was on a third archive the whole time |
| **The Christian Baptist**, 7 vols | 1823–30 | archive.org `the-christian-baptist-1823-1830` | Campbell's periodical — the movement arguing itself into existence |
| **Ellen G. White**, *Patriarchs and Prophets* | 1890 | archive.org `patriarchsprophe0000mrse` | Volume one of the Conflict of the Ages series, the only one CCEL lacks |
| **Jan Hus**, *De Ecclesia* (trans. D. S. Schaff) | 1915 | archive.org `deecclesiachurch00husj` | The Hussite family, which has nothing. An English translation by the same Schaff whose *Creeds* this corpus already ingests |
| **Samuel Morland**, *History of the Evangelical Churches of the Valleys of Piemont* | 1658 | archive.org `historyofevangel00morl` | The Waldensian confession **in English**, from 1658. `ingest_schaff.py` refused the Piedmont confession for being French; this is the same document in a language the corpus can use |
| **Nestorius**, *The Bazaar of Heracleides* (trans. Driver & Hodgson) | 1925 | archive.org `nestoriusbazaaro0000nest` | The Church of the East — an entire *branch* with no sources. Nestorius in his own defence |
| **G. P. Badger**, *The Nestorians and their Rituals* | 1852 | archive.org `nestorianstheirr0001badg` | The same branch's liturgy and creed, in English |
| **F. E. Brightman**, *Liturgies Eastern and Western* | 1896 | archive.org `liturgieseastern0001febr_p2z8` | Eastern Orthodox is three documents and no liturgy. This is the standard critical edition of the Eastern rites |
| **Peter Mogila**, *The Orthodox Confession* (trans. Shann) | 1898 | archive.org `the-orthodox-confession-of-the-catholic-and-apostolic-eastern-church` | A Mogila source was **removed** from this corpus as unprovenanced paraphrase. This is the real edition, and would restore it properly |
| **Kebra Nagast** (trans. Budge) | 1922 | archive.org `kebranagast` | Oriental Orthodox holds one work. This is the Ethiopian national epic and a Tewahedo text |
| **Free Methodist Church**, *Doctrines and Discipline* | 1915, 1923 | archive.org `doctrinesanddisc00unknuoft`, `doctrinesdiscipl00free` | A Holiness body's own standard, not an antecedent |
| **William Booth**, *In Darkest England and the Way Out* | 1890 | archive.org `cihm_29082` | The Salvation Army, recorded here as unrepresented because CCEL has no `booth` page |
| **Aimee Semple McPherson**, *This Is That* | 1923 | archive.org `thisisthatperson0000mcph` | Foursquare's founder. Pentecostal, and public domain |
| **The Book of Common Prayer**, 1662 text | 1662 | archive.org, 215 printings incl. `bookofcommonpray00chur_14` (1669) | Anglican liturgy. See the note below — the rights question here is not what it looks like |

### Public domain by date, not yet located as text

Each is out of copyright on the arithmetic. None has been found as a
transcription, and none should be listed as available until it has.

- **Assemblies of God**, *Statement of Fundamental Truths* (1916) — the
  confessional document of the largest Pentecostal body. archive.org has only
  later commentaries on it; the 1916 text needs finding.
- **Foursquare**, *Declaration of Faith* (McPherson, 1923).
- **The Apostolic Faith** (Azusa Street, 1906–1908) — periodical issues.
- **Charles Parham**, *A Voice Crying in the Wilderness* (1902).
- **Church of the Nazarene**, *Manual* (1908 and after) — archive.org's
  `Church of the Nazarene` creator search is swamped by sermon audio.
- **C. H. Mackintosh**, *Notes on the Pentateuch*, and **J. N. Darby**,
  *Collected Writings* — the Brethren family. Both authors died in the 1880s
  and both are widely mirrored on denominational sites; neither was located in a
  form with recorded provenance.
- **Papal encyclicals through 1930** — *Rerum Novarum* (1891), *Aeterni Patris*
  (1879), *Pascendi* (1907), *Quas Primas* (1925), *Casti Connubii* (1930) —
  and the **Baltimore Catechism** (1885).

### The 1662 Prayer Book is a special case, and the entry here was wrong about it

`README.md` and `TODO.md` say there is no public-domain transcription. The
rights position is more specific than that. In the **United Kingdom** the 1662
text is under perpetual Crown copyright, exercised through letters patent held
by the Queen's Printer and the two university presses. That restriction is
**UK-only and does not reach a US-published corpus**, and the text was printed
in 1662 in any case.

So the Prayer Book is not a rights problem. It is a transcription problem: the
Society of Archbishop Justus hosts a complete transcription at
`justus.anglican.org`, which could not be fetched during this audit — the host
presented a certificate this environment would not verify — and archive.org has
215 printings as scans. Recorded as *transcription-blocked, rights clear*,
which is a different queue.

### Genuinely closed, and confirmed so

- **The Catechism of the Catholic Church** (1992) and the **Vatican II**
  constitutions — © Libreria Editrice Vaticana.
- **The Philokalia in English** — Kadloubovsky & Palmer (Faber, 1951) and
  Palmer/Sherrard/Ware (Faber, 1979–). Both British publications, both restored
  in the US by the URAA. There is no pre-1931 English Philokalia. Its
  constituent authors are reachable individually through the patristic corpus.
- **Modern theology** — Barth, Lewis, Packer, Sproul.
- **Gregory of Nyssa**, *Life of Moses* — Ferguson & Malherbe, 1978.
- **The Second Helvetic Confession**, 1966 translation — in copyright, and
  irrelevant now: Schaff's own English appendix of 1877 was ingested instead.

### Unresolved: the 1929–1963 renewal question

US works published in this window lost copyright unless renewed, and the large
majority were not. Two candidates turn on it — the English *Rudder / Pedalion*
(Cummings, 1957), which is the Orthodox canonical collection, and the standard
English **Schleitheim Confession** (Wenger's translation, *Mennonite Quarterly
Review*, 1945). Both would close a real gap. Neither may be claimed until the
renewal records are checked by hand, which the Stanford database supports and a
script here cannot reach.
