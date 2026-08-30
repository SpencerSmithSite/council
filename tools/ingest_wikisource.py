#!/usr/bin/env python3
"""Ingest proofread transcriptions from English Wikisource.

The tool `TODO.md` item 6b asks for. Three of this corpus's longest-standing
gaps were closed by one archive it had never queried, and the documents behind
this fetch had been sitting there waiting for someone to write the fetcher.

**Why a tool rather than a handful of curl calls.** The API rate-limits by
returning an HTML error page, and an HTML error page parses as *a page with no
text* rather than as a failure. A silently-empty document looks exactly like a
document that is genuinely empty, which is the failure mode this corpus is least
able to detect after the fact. So every fetch is gated on a minimum size and
every parse is gated again, and both say which document failed.

**Rights are read, not assumed.** `SOURCES.md` records that Wikisource states
its terms per page and that the terms differ per page — the 1689 Baptist
confession's page declares `{{no source}}` while the 1690 Westminster page
carries `{{PD-UKGov}}`. Those templates surface through the API as categories,
so this asks for them and refuses any page not in a public-domain category. The
category is recorded verbatim on the source, so a reader can see *which* claim
the work was admitted under.

**What the HTML actually looks like**, since none of it matched expectations:

* **There are no headings.** Not in the encyclicals, not in Menno Simons, not
  in the conciliar decrees. These are Proofread Page transcriptions of scanned
  books, and the page structure is paragraphs. Unit boundaries therefore come
  from the prose, which is done here the same way `ingest_reformation.py` does
  it — a short line without terminal punctuation heads what follows.
* **`<style>` blocks live inside the content and their CSS reads as text.**
  Strip tags naively and every document ends with
  `.mw-parser-output .wst-smallrefs{font-size:83%...}` as though it were a
  closing paragraph. Elements are removed before tags are.
* **The scans' end-of-line hyphens survive**: "If I threat- en with the wrath".
  Rejoined only where the following fragment is lower-case and the pair makes a
  word the hyphen was splitting, never across a real compound.

    python3 tools/ingest_wikisource.py survey   # what is there, and how big
    python3 tools/ingest_wikisource.py fetch
    python3 tools/ingest_wikisource.py parse
"""

import argparse
import html as htmllib
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import ingest_reformation as ccel  # noqa: E402

CACHE = ROOT / ".cache" / "wikisource"
UNITS = ROOT / "tools" / "data" / "wikisource_units.json"

API = "https://en.wikisource.org/w/api.php"

# Wikimedia asks for a descriptive User-Agent that identifies the client and a
# way to reach whoever runs it, and throttles anything that does not supply one.
USER_AGENT = ("council-corpus/1.0 (offline theology corpus; "
              "https://github.com/SpencerSmithSite/council)")

# Wikimedia's guidance is to keep serial requests slow rather than parallel.
DELAY_SECONDS = 3.0

# Licence categories that mean the text may be redistributed. Anything else —
# including a page with no licence category at all — is refused by name.
PD_CATEGORIES = re.compile(r"^Category:(PD-|CC-?(0|PD)|Public domain)", re.I)

# A floor for "the archive answered with nothing". Deliberately low, and it was
# deliberately lowered: at 2,000 it refused six of the Vatican decrees'
# fourteen chapters, which are 900-1,900 characters because a conciliar chapter
# is short. That is the gate mistaking a genuinely brief document for a failed
# fetch, which is the same class of error it exists to prevent, pointed the
# other way.
#
# Throttling is caught earlier and more precisely: Wikimedia answers a
# rate-limited request with HTML, `json.loads` raises on it, and `api` retries
# and then returns None. So this only has to catch a page that renders empty.
MIN_PAGE_CHARS = 200

MIN_UNIT_CHARS = 200
MAX_UNIT_CHARS = 9000
MIN_WORK_CHARS = 1500

# Proofread Page stamps each transcription with the printing it came from, as
# the first line of the body: "Chicago: Benziger Brothers, pages 18-19". It is
# provenance, not text, and it is worth keeping — as the source's print basis,
# not as its opening paragraph.
PRINT_BASIS = re.compile(
    r"^[A-Z][A-Za-z .'-]{2,40}:\s+.{3,80}?,\s+pages?\s+[\divxlc]+(?:[-–][\divxlc]+)?\.?$",
    re.I)

# "Encyclical Letter Rerum Novarum , May 15, 1891." — the Latin incipit and the
# date, stated by the document about itself. Worth parsing rather than typing:
# the English titles Benziger gave these are not what anyone searches for, and
# the date is otherwise unknown to the record.
INCIPIT = re.compile(
    r"^(?:Encyclical|Apostolic)\s+(?:Letter|Constitution)\s+(.+?)\s*,\s*"
    r"(?:[A-Z][a-z]+\.?\s+\d{1,2}\s*,\s*)?(\d{4})\s*\.?$")

# End-of-line hyphens the transcription kept. Only rejoined when what follows is
# lower-case: "threat- en" is one word broken across a line, whereas "self-
# denial" and "twenty- five" are compounds whose hyphen belongs to the word.
# Requiring the tail to be lower-case is not sufficient on its own — hence the
# whitelist of nothing: this joins, and `survey` reports the count so the
# decision can be re-examined against a real number rather than a guess.
LINE_HYPHEN = re.compile(r"(\w)-\s+([a-z])")

# --- transcription quality ---------------------------------------------------
#
# Wikisource's texts are transcriptions of scans, and how far they have been
# proofread varies per work. That is measurable rather than a matter of trust,
# and it has to be measured because the corpus refuses raw OCR outright:
# `ingest_gutenberg.py` records archive.org's OCR of this material at about one
# error per hundred characters, roughly 580 broken words per ten thousand.
#
# What is counted is the residue of two specific scanner failures visible in
# this material — the "li" ligature read as "h" ("hght" for light, "pubhc" for
# public) and "it"/"th" read as "d" ("wdth" for with). Both produce non-words,
# so a hit is a hit rather than a guess.
#
# This is a **floor, not the true rate**: it can only find corruptions on the
# list, and a scanner that turns "modern" into "modem" produces a real word this
# will never see. It is still the right measure to gate on, because it is the
# one that can be checked rather than asserted, and the numbers it gives are two
# orders of magnitude below the floor the corpus already rejects.
#
# Measured on this ingest: Leo XIII 4.3 per 10,000 words, Menno Simons 0.1,
# the Dordrecht Confession and the Vatican decrees 0.0.
LIGATURE_ERRORS = re.compile(
    r"\b(?:wdth|ndth|whde|untd|hght|hfe|hke|hving|hberty|hne|hmit|hst|"
    r"enhghten\w*|earher|Hesh|Hame|Hock|pubhc|rehgion|rehgious|Cathohc|"
    r"Enghsh|hkewise|behef|behevers?|exphcit|imphed|estabhshed|dehver\w*)\b",
    re.I)

# Ten times the worst measured here, and still fifteen times better than the
# rate that got archive.org's OCR refused. A work past this is not a
# transcription with a few slips in it; it is a scan nobody has read.
MAX_LIGATURE_PER_10K = 50.0


def transcription_quality(text):
    """(errors per 10,000 words, count). See LIGATURE_ERRORS above."""
    words = len(re.findall(r"[A-Za-z]+", text))
    errors = len(LIGATURE_ERRORS.findall(text))
    return (10000.0 * errors / words if words else 0.0), errors


WORKS = [
    # --- Catholic: Vatican I, the council itself -----------------------------
    # Fifteen small pages rather than one document, because that is how the
    # decrees are structured: three constitutions, each with a prologue and
    # four chapters. Kept as one source with the chapters as its units.
    {
        "id": "vatican-i",
        "title": "The Decrees of the Vatican Council",
        "author": None,
        "date": "1870",
        "tradition": "Catholic",
        "kind": "Council",
        "root": "The Decrees of the Vatican Council",
        "pages": [
            "The Decrees of the Vatican Council/Part 1/Prologue",
            "The Decrees of the Vatican Council/Part 1/Chapter 1",
            "The Decrees of the Vatican Council/Part 1/Chapter 2",
            "The Decrees of the Vatican Council/Part 1/Chapter 3",
            "The Decrees of the Vatican Council/Part 1/Chapter 4",
            "The Decrees of the Vatican Council/Part 2/Chapter 1",
            "The Decrees of the Vatican Council/Part 2/Chapter 2",
            "The Decrees of the Vatican Council/Part 2/Chapter 3",
            "The Decrees of the Vatican Council/Part 2/Chapter 4",
            "The Decrees of the Vatican Council/Part 3/Prologue",
            "The Decrees of the Vatican Council/Part 3/Chapter 1",
            "The Decrees of the Vatican Council/Part 3/Chapter 2",
            "The Decrees of the Vatican Council/Part 3/Chapter 3",
            "The Decrees of the Vatican Council/Part 3/Chapter 4",
        ],
        "collection": "The Decrees of the Vatican Council (Benziger, 1870)",
        "notes": ("The dogmatic constitutions Dei Filius and Pastor Aeternus, "
                  "as their prologues and chapters. The council's canons are "
                  "attached to the chapters they follow in this edition."),
    },
    # --- Catholic: the Leonine encyclicals -----------------------------------
    # One source each, because they are separate documents that answer separate
    # questions and a reader citing Rerum Novarum should land on Rerum Novarum.
    *[
        {
            "id": f"leo-{n}",
            "title": None,          # taken from the page, with the Latin added
            "author": "Pope Leo XIII",
            "date": None,           # parsed from the document's own dateline
            "tradition": "Catholic",
            "kind": "Encyclical",
            "root": "The Great Encyclical Letters of Pope Leo XIII",
            "pages": [f"The Great Encyclical Letters of Pope Leo XIII/{n}"],
            "collection": ("The Great Encyclical Letters of Pope Leo XIII "
                           "(Benziger, 1903)"),
        }
        # All thirty subpages of the Benziger collection, taken off
        # Wikisource's own index rather than chosen. The first twenty-two
        # are the encyclicals anyone would name; the rest are the occasional
        # letters, and curating those out would be an editorial judgement
        # about what Leo XIII "really" wrote, which is not this file's to
        # make when the collection is the thing that was published.
        for n in [
            "The Condition of the Working Classes",
            "The Study of Scholastic Philosophy",
            "The Christian Constitution of States",
            "Human Liberty",
            "The Unity of the Church",
            "Christian Marriage",
            "The Holy Spirit",
            "The Study of Holy Scripture",
            "The Most Holy Eucharist",
            "Socialism, Communism, Nihilism",
            "Freemasonry",
            "On the Evils Affecting Modern Society",
            "On the Chief Duties of Christians as Citizens",
            "Christian Democracy",
            "The Reunion of Christendom",
            "True and False Americanism in Religion",
            "The Right Ordering of Christian Life",
            "On the Consecration of Mankind to the Sacred Heart of Jesus",
            "Anglican Orders",
            "The Prohibition and Censorship of Books",
            "Christ Our Redeemer",
            "To the English People",
            "Allegiance to the Republic",
            "Catholicity in the United States",
            "Congratulations to the American Hierarchy",
            "Review of His Pontificate",
            "The Church in the Philippines",
            "The Holy Scriptures; The Biblical Commission",
            "The Pope and the Columbus Tercentenary",
            "The Religious Congregations in France",
        ]
    ],
    # --- Church of the East: a branch with no sources at all -----------------
    #
    # The taxonomy defines seven branches and this one has been empty since it
    # was written. What exists in English and out of copyright is thin,
    # scattered and mostly unproofread scans; this is the exception.
    #
    # **What this is, stated plainly, because the record has to carry it.**
    # George Percy Badger was an East India Company chaplain, and volume II is
    # not a Church of the East document — it is an Anglican's examination of
    # their doctrine, chapter by chapter, in which the chapters are mapped onto
    # the Thirty-Nine Articles ("the doctrine of our Article held by the
    # Nestorians"). What makes it worth having anyway is that he builds each
    # chapter out of long translated quotations from the church's own service
    # books — the Khudhra, the Gezza, the Warda, the Khâmees, the Sinhadòs —
    # and from Abdisho bar Berika, whose creed he gives in full. It is a
    # documentary anthology inside a frame, and the frame is disclosed on the
    # source rather than left for a reader to discover.
    #
    # Volume I is deliberately not here. It is a missionary travel narrative
    # through Mesopotamia and Kurdistan with an inquiry into the Yezidis
    # attached, and none of it is theology.
    #
    # Abdisho's *Marganitha* — the Book of the Pearl, the church's own doctrinal
    # manual and the thing that ought to be here instead — has a Wikisource
    # page that is 1,028 characters of stub. The full text is not transcribed
    # anywhere that has been found.
    {
        "id": "badger-2",
        "title": "The Nestorians and their Rituals, Volume II",
        "author": "George Percy Badger",
        "date": "1852",
        "tradition": "Assyrian",
        "kind": "Treatise",
        "root": "The Nestorians and their Rituals",
        "pages": (
            [f"The Nestorians and their Rituals/Volume 2/Chapter {n}"
             for n in list(range(1, 29)) + [42]]
            + [f"The Nestorians and their Rituals/Volume 2/Appendix B/Part {n}"
               for n in range(1, 6)]
        ),
        "collection": ("The Nestorians and their Rituals, vol. II "
                       "(Joseph Masters, London, 1852), ed. John Mason Neale"),
        "notes": (
            "An Anglican chaplain's examination of the doctrine of the Church "
            "of the East, arranged against the Thirty-Nine Articles, and built "
            "throughout from translated quotations of that church's own "
            "service books — the Khudhra, Gezza, Warda, Khâmees and Sinhadòs — "
            "and from Abdisho bar Berika, whose creed is given in full in "
            "chapter VI. The framing is Badger's and is not the Church of the "
            "East's own. English Wikisource's transcription of the volume is "
            "partial: chapters I-XXVIII and XLII and Appendix B are "
            "transcribed, and chapters XXIX-XLI are not, so this is not the "
            "whole book. Volume I, a travel narrative, is deliberately not "
            "ingested."),
    },
    # --- Anabaptist: the confession and the systematics ----------------------
    # The Anabaptist pack has been the Martyrs Mirror and nothing else, and its
    # own description has had to say so. This is the confession and the man.
    {
        "id": "dordrecht",
        "title": "The Dordrecht Confession of Faith",
        "author": None,
        "date": "1632",
        "tradition": "Anabaptist",
        "kind": "Confession",
        "root": "Dordrecht Confession of Faith",
        "pages": ["Dordrecht Confession of Faith"],
        "collection": "Dordrecht Confession of Faith (1632)",
        "notes": ("The Mennonite confession, adopted at Dordrecht on 21 April "
                  "1632 and still the doctrinal standard of the conservative "
                  "Mennonite and Amish churches."),
    },
    *[
        {
            "id": f"menno-{i}",
            "title": None,
            "author": "Menno Simons",
            "date": None,
            "tradition": "Anabaptist",
            "kind": "Treatise",
            "root": "The Complete Works of Menno Simons",
            "pages": [f"The Complete Works of Menno Simons/{p}"],
            "collection": ("The Complete Works of Menno Simons "
                           "(Elkhart, 1871)"),
        }
        for i, p in enumerate([
            "The True Christian Faith",
            "A Reply to a Publication of Gellius Faber",
            "The Conversion of Menno Simons",
            "The Reason Why Menno Simons Does Not Cease Teaching and Writing",
            "A Brief Complaint or Apology of the Despised Christians and "
            "Exiled Strangers",
            "A Very Humble Supplication of the Poor, Despised Christians",
            "A Very Sincere Epistle to Martin Micron",
            "A Pleasing Instruction and Doctrine",
            # "The Education of Children" is listed by Wikisource and renders
            # as twelve characters: the page exists and the transcription does
            # not. Left out rather than ingested as an empty work.
        ], 1)
    ],
]


# --- the archive -------------------------------------------------------------

def api(params):
    """One API call, or None. Retries on the transport, not on a bad answer."""
    url = f"{API}?" + urllib.parse.urlencode({**params, "format": "json"})
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read().decode("utf-8", errors="replace")
            time.sleep(DELAY_SECONDS)
            return json.loads(body)
        except Exception:
            # Backing off rather than retrying immediately: the usual cause is
            # the rate limiter, and hammering it is what produced the empty
            # pages this module's docstring is about.
            time.sleep(8 * (attempt + 1))
    return None


def licence_of(title):
    """The public-domain category this page claims, or None if it claims none.

    Asked of the page given. Callers pass the **work's root page**, because
    that is where Wikisource puts the licence: a multi-page work carries its
    template once, on the work, and every chapter page under it carries none.
    Reading the chapter would refuse every multi-page work in the archive —
    measured, not assumed: of the 46 pages fetched here, exactly two returned a
    category of their own and both are single-page works.
    """
    data = api({"action": "query", "prop": "categories", "titles": title,
                "cllimit": 100})
    pages = (data or {}).get("query", {}).get("pages", {})
    for page in pages.values():
        for category in page.get("categories", []):
            if PD_CATEGORIES.match(category["title"]):
                return category["title"]
    return None


def page_html(title):
    data = api({"action": "parse", "page": title, "prop": "text"})
    if not data or "parse" not in data:
        return None
    return data["parse"]["text"]["*"]


# --- HTML to paragraphs ------------------------------------------------------

DROP_ELEMENTS = re.compile(
    r"<(style|script|sup|table)\b[^>]*>.*?</\1>", re.S | re.I)
DROP_BLOCKS = re.compile(
    r'<div[^>]*class="[^"]*(?:ws-noexport|licenseContainer|reflist|'
    r'wst-smallrefs|catlinks|printfooter)[^"]*"[^>]*>.*?</div>', re.S | re.I)
BLOCK = re.compile(r"<(h[2-4]|p)\b[^>]*>(.*?)</\1>", re.S | re.I)
TAG = re.compile(r"<[^>]+>")

# Wikisource's own apparatus, which sits at the foot of a page under headings of
# its own and is not part of the work: editorial notes, the reference list, and
# outbound links. Everything from the first of these onward is dropped.
APPARATUS = re.compile(
    r"^(Notes?|References?|Footnotes?|External links?|Bibliography|"
    r"See also|Source)\s*$", re.I)


def blocks(html):
    """(kind, text) in document order — 'h' for a heading, 'p' for a paragraph.

    Headings are kept rather than discarded, and that is the whole point of
    reading them out of the HTML: the Dordrecht Confession states each of its
    eighteen articles as an `<h2>`, and dropping them merged the confession into
    five untitled runs of prose. A document that says where its sections begin
    should be cut where it says.

    Elements are dropped before tags are stripped. Doing it the other way round
    turns every `<style>` block into a paragraph of CSS — not a hypothetical:
    these pages carry their reference styling inline, and the naive strip ends
    every document with `.wst-smallrefs{font-size:83%...}`.
    """
    # Repeated because the blocks nest: a licence container inside a noexport
    # div leaves its inner half behind on a single pass.
    for _ in range(4):
        html = DROP_ELEMENTS.sub(" ", html)
        html = DROP_BLOCKS.sub(" ", html)

    out = []
    for tag, raw in BLOCK.findall(html):
        text = htmllib.unescape(TAG.sub(" ", raw))
        text = LINE_HYPHEN.sub(r"\1\2", text)
        # Every whitespace run, newlines included. These transcriptions keep the
        # printed page's line breaks inside each paragraph — 9,689 of them
        # across this ingest — and a unit that wraps where a Victorian
        # compositor wrapped reads as broken text on a phone. Paragraph
        # boundaries survive because they are `<p>` elements, not newlines.
        text = re.sub(r"\s+", " ", text).strip()
        if not text:
            continue
        kind = "h" if tag.lower().startswith("h") else "p"
        if kind == "h" and APPARATUS.match(text):
            break
        out.append((kind, text))
    return out


def paragraphs(html):
    """Just the readable text, for the size gates."""
    return [text for _, text in blocks(html)]


def is_heading(paragraph):
    """Whether this paragraph titles what follows rather than saying anything.

    Reuses `ingest_reformation`'s judgement, which was shaped on two hundred
    works, and adds the one case Wikisource brings that CCEL does not: a title
    page split across several short all-caps paragraphs.
    """
    return len(paragraph) <= 120 and ccel.is_headingish(paragraph)


def units_from(blocks_):
    """Cut a document into display-sized units.

    Blocks are `(kind, text, label)`, where the label names the page the block
    came from. Multi-page works are concatenated before cutting, and without the
    label the units of a book lose all trace of which chapter they belong to:
    Badger sets "quotations, then REMARKS." in every chapter, so twenty units
    arrived titled `REMARKS.` and nothing else. A reader scanning a table of
    contents cannot use twenty identical entries, and neither can a citation.

    An HTML heading always opens a unit: the document said so. A paragraph that
    merely *looks* like a heading only opens one when what has accumulated is
    long enough to stand alone — these transcriptions begin with title pages
    split across four or five short all-caps lines, and each would otherwise
    become a unit saying nothing.
    """
    units, heading, body, label = [], None, [], None

    def size():
        return sum(len(x) for x in body)

    def emit(title, where):
        content = "\n\n".join(body).strip()
        name = (title or "").strip()

        # A chapter numbered but not named takes the name printed under its
        # number. Done here, before the page label is added, because the label
        # would otherwise hide the numeral this looks for.
        if NUMERAL_ONLY.match(name):
            first, _, rest = content.partition("\n\n")
            if rest and len(first) <= 90:
                name, content = f"{name.strip('.')}. {first}", rest

        # A heading left dangling on a function word is a title page that the
        # heading-chaining glued together — "THE NESTORIANS — AND" — not a
        # section name. The page label alone is more use than a fragment.
        if DANGLING.search(name):
            name = ""

        # The label is dropped when the heading already carries it, so a
        # chapter that names itself is not made to say so twice.
        if where and not name.upper().startswith(where.upper()):
            name = f"{where} — {name}" if name else where
        units.append({
            "number": len(units) + 1,
            "title": (name or f"Section {len(units) + 1}")[:200],
            "content": content,
        })

    for kind, text, block_label in blocks_:
        declared = kind == "h"
        if declared or is_heading(text):
            if size() >= MIN_UNIT_CHARS:
                emit(heading, label)
                body, heading, label = [], text, block_label
            elif not body:
                heading = f"{heading} — {text}"[:200] if heading else text
                label = label or block_label
            elif declared:
                emit(heading, label)
                body, heading, label = [], text, block_label
            else:
                body.append(text)
            continue
        if not body:
            label = block_label
        body.append(text)

    if size() >= MIN_UNIT_CHARS:
        emit(heading, label)
    elif body and units:
        units[-1]["content"] += "\n\n" + "\n\n".join(body)

    return ccel.split_oversized(units)


NUMERAL_ONLY = re.compile(r"^[IVXLC]{1,6}\.?$|^\d{1,3}\.?$")

# A composed heading that trails off on a function word or an "&c.".
DANGLING = re.compile(r"(?:^|\s|—\s)(?:AND|OR|OF|THE|A|AN|WITH|BY|TO|IN|&c\.?)\s*$",
                      re.I)


# --- commands ----------------------------------------------------------------

def page_label(page, work):
    """How a unit should name the page it came from, or None for a lone page.

    A single-page work needs no label — the source title already says where the
    unit is. A multi-page work needs one, and the useful part is whatever the
    page title adds beyond the work's own root: "Chapter 6", "Appendix B —
    Part 3", "Part 1 — Chapter 4".
    """
    if len(work["pages"]) < 2:
        return None
    tail = page[len(work["root"]):].strip("/")
    tail = re.sub(r"^Volume \d+/?", "", tail).strip("/")
    return " — ".join(part for part in tail.split("/") if part) or None


def path_for(title):
    safe = re.sub(r"[^A-Za-z0-9]+", "_", title).strip("_")[:120]
    return CACHE / f"{safe}.json"


def all_pages():
    for work in WORKS:
        for page in work["pages"]:
            yield page


def root_of(page):
    """The work whose licence governs this page."""
    for work in WORKS:
        if page in work["pages"]:
            return work["root"]
    return page


def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    wanted = list(dict.fromkeys(all_pages()))
    pending = [p for p in wanted if not path_for(p).exists()]
    print(f"{len(wanted)} pages, {len(pending)} to fetch "
          f"({len(wanted) - len(pending)} cached)\n")
    licences = {}

    for i, title in enumerate(pending, 1):
        html = page_html(title)
        if html is None:
            print(f"  [{i}/{len(pending)}] FAILED   {title}", file=sys.stderr,
                  flush=True)
            continue

        # The gate the docstring exists for. An empty answer here is a
        # throttled request, not an empty document, and it must not be cached
        # as though the archive had answered.
        text = " ".join(paragraphs(html))
        if len(text) < MIN_PAGE_CHARS:
            print(f"  [{i}/{len(pending)}] TOO SMALL {len(text):>7} chars — "
                  f"{title}", file=sys.stderr, flush=True)
            continue

        root = root_of(title)
        licence = licences.get(root)
        if root not in licences:
            licence = licences[root] = licence_of(root)
        path_for(title).write_text(json.dumps(
            {"title": title, "licence": licence, "html": html}, indent=1),
            encoding="utf-8")
        print(f"  [{i}/{len(pending)}] ok  {len(text):>8} chars  "
              f"{licence or 'NO PD CATEGORY':<22} {title}", flush=True)


def load(title):
    path = path_for(title)
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def survey():
    """What is cached, how big, under what licence, and how it would be cut."""
    hyphens = 0
    print(f"{'chars':>8} {'units':>6} {'licence':<24} page")
    for title in dict.fromkeys(all_pages()):
        cached = load(title)
        if cached is None:
            print(f"{'-':>8} {'-':>6} {'not fetched':<24} {title}")
            continue
        hyphens += sum(len(LINE_HYPHEN.findall(htmllib.unescape(
            TAG.sub(" ", raw)))) for _, raw in BLOCK.findall(cached["html"]))
        units = units_from([(k, t, None) for k, t
                             in blocks(cached["html"])])
        chars = sum(len(u["content"]) for u in units)
        print(f"{chars:>8} {len(units):>6} "
              f"{(cached['licence'] or 'NO PD CATEGORY'):<24} {title}")
    print(f"\nline-break hyphens rejoined across all pages: {hyphens}")


def parse():
    records, skipped = [], []

    for work in WORKS:
        cached = [load(p) for p in work["pages"]]
        if any(c is None for c in cached):
            skipped.append((work["pages"][0], "not fetched"))
            continue

        licences = {c["licence"] for c in cached}
        if None in licences:
            skipped.append((work["pages"][0],
                            "page states no public-domain category"))
            continue

        parts = []
        for c in cached:
            label = page_label(c["title"], work)
            # Proofread Page's own provenance line, kept off the page and put
            # on the source instead.
            parts.extend((k, t, label) for k, t in blocks(c["html"])
                         if not PRINT_BASIS.match(t))
        paras = [t for _, t, _ in parts]

        title = work["title"]
        date = work["date"]
        latin = None
        for paragraph in paras[:6]:
            match = INCIPIT.match(paragraph)
            if match:
                latin, date = match.group(1).strip(" ,"), date or match.group(2)
                break

        if title is None:
            # The page name, which for these collections is the editor's own
            # English title for the document.
            title = work["pages"][0].rsplit("/", 1)[-1]
            if latin:
                title = f"{latin} ({title})"

        units = units_from(parts)
        chars = sum(len(u["content"]) for u in units)
        if chars < MIN_WORK_CHARS:
            skipped.append((work["pages"][0], f"only {chars:,} characters"))
            continue

        rate, errors = transcription_quality(
            "\n".join(u["content"] for u in units))
        if rate > MAX_LIGATURE_PER_10K:
            skipped.append((work["pages"][0],
                            f"{rate:.1f} scanner errors per 10k words"))
            continue

        records.append({
            "title": title,
            "author": work["author"],
            "date": date,
            "tradition": work["tradition"],
            "kind": work["kind"],
            "url": ("https://en.wikisource.org/wiki/"
                    + urllib.parse.quote(work["pages"][0].replace(" ", "_"))),
            "rights": ("English Wikisource states "
                       + ", ".join(sorted(x.replace("Category:", "")
                                          for x in licences))),
            "collection": work["collection"],
            # The measurement travels with the work. A reader who finds a
            # mangled word should be able to see that the transcription was
            # checked and how far, rather than wondering whether anyone looked.
            "notes": " | ".join(x for x in (
                work.get("notes"),
                (f"Transcription checked for scanner errors: {errors} found in "
                 f"{len(units)} units, {rate:.1f} per 10,000 words"
                 if errors else
                 "Transcription checked for scanner errors: none found"),
            ) if x),
            "units": units,
        })

    records.sort(key=lambda r: (r["tradition"], r["author"] or "", r["title"]))
    for record in records:
        chars = sum(len(u["content"]) for u in record["units"])
        print(f"  {record['tradition']:<11} {record['title'][:52]:<54} "
              f"{len(record['units']):>4} units {chars/1000:>8.1f} K "
              f"{record['date'] or '—'}")

    total_units = sum(len(r["units"]) for r in records)
    total_chars = sum(len(u["content"]) for r in records for u in r["units"])
    print(f"\n  {len(records)} works, {total_units:,} units, "
          f"{total_chars/1e6:.2f} M characters")

    if skipped:
        print(f"\n{len(skipped)} not ingested:")
        for page, why in skipped:
            print(f"    {page[:64]:<66} {why}")

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    UNITS.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
    print(f"\n-> {UNITS}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["survey", "fetch", "parse"])
    args = parser.parse_args()
    {"survey": survey, "fetch": fetch, "parse": parse}[args.command]()


if __name__ == "__main__":
    main()
