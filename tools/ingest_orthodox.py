#!/usr/bin/env python3
"""Ingest Eastern Orthodox primary texts.

The tradition had a row in the database and nothing in it. Both previous
entries were removed as misattributed — one of them filed *Pilgrim's Progress*
as the Philokalia — leaving a truthful zero, and the largest gap in the table.

Three documents close it, chosen because each is a *primary* Orthodox text with
an unambiguously public-domain English translation, not because they were the
first three found:

* **The Longer Catechism of the Orthodox, Catholic, Eastern Church** (Philaret
  of Moscow, 1830) — the Orthodox catechism, 611 questions organised on faith,
  hope and love. Blackmore's 1845 English, as reprinted in Schaff's *Creeds of
  Christendom* vol. 2 (1877).

* **The Confession of Dositheus** (Synod of Jerusalem, 1672) — the Orthodox
  answer to Cyril Lucaris's Calvinising confession, and the nearest thing
  Orthodoxy has to a post-schism conciliar symbol. Robertson's 1899 English.

* **The Book of Needs** (the *Trebnik*) — the sacramental rites themselves:
  baptism, chrismation, confession, marriage, unction, burial. Shann's 1894
  English. A catechism says what a tradition believes; a service book shows
  what it does, and for Orthodoxy the second is where most of the theology
  actually lives.

**Why not the obvious ones.** `TODO.md` named Kadloubovsky's Philokalia
extracts as the public-domain route. They are not: Kadloubovsky and Palmer's
*Writings from the Philokalia on Prayer of the Heart* is Faber, 1951, and in
copyright, as is the complete Palmer/Sherrard/Ware translation. There is no
public-domain English Philokalia, and this file does not pretend otherwise.
Mogila's *Orthodox Confession* is public domain in Schaff, but Schaff prints it
in parallel Greek and English columns, which CCEL's text export linearises into
each other mid-sentence — the defect already recorded in `ingest_ccel.py`.
Philaret covers the same doctrinal ground from the same volume in English only.

**Two witnesses**, as with [ingest_first_london.py] and [ingest_baptist.py].
The two web transcriptions are clean HTML, which is what makes them worth
using and also what makes them unverifiable on their own: a transcription can
be silently abridged or modernised and still look immaculate. Each is therefore
gated against the scanned printing it claims to reproduce. The scans are OCR
and unusable as text — the Robertson volume is bilingual and its OCR confuses
Greek and Latin scripts outright — but OCR is entirely good enough to answer
the question actually being asked: *is this the same document, at full length,
in its own century's English?*

The Book of Needs needs no second witness for a different reason, stated rather
than assumed: it is a Project Gutenberg text, proofread by the Distributed
Proofreaders, which is the same standard already relied on for the Book of
Concord in `ingest_gutenberg.py` — a transcription with a named process behind
it, not an anonymous web page.

    python3 tools/ingest_orthodox.py fetch
    python3 tools/ingest_orthodox.py parse
"""

import argparse
import html
import json
import re
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "orthodox"
UNITS = ROOT / "tools" / "data" / "orthodox_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)

# --- sources -----------------------------------------------------------------

PHILARET_URL = (
    "http://www.pravoslavieto.com/docs/eng/Orthodox_Catechism_of_Philaret.htm"
)
PHILARET_CITE = (
    "Philip Schaff (ed.), The Creeds of Christendom, with a History and "
    "Critical Notes, vol. II (New York: Harper, 1877), pp. 445-542; English "
    "by R. W. Blackmore, The Doctrine of the Russian Church (Aberdeen, 1845)"
)

DOSITHEUS_URL = "https://www.crivoice.org/creeddositheus.html"
DOSITHEUS_CITE = (
    "J. N. W. B. Robertson (trans.), The Acts and Decrees of the Synod of "
    "Jerusalem, sometimes called the Council of Bethlehem, holden under "
    "Dositheus, Patriarch of Jerusalem, in 1672 (London: Thomas Baker, 1899)"
)

NEEDS_ID = 71513
NEEDS_URL = f"https://www.gutenberg.org/ebooks/{NEEDS_ID}"
NEEDS_TEXT = f"https://www.gutenberg.org/ebooks/{NEEDS_ID}.txt.utf-8"

# Corroborating scans. Identifiers are pinned so a re-run compares against the
# same scan rather than whichever copy archive.org's search returns today.
BLACKMORE_ID = "doctrineofrussia00blac"
ROBERTSON_ID = "actsdecreesofsyn00orth"


def archive_text(identifier):
    return f"https://archive.org/download/{identifier}/{identifier}_djvu.txt"


FILES = {
    "philaret.html": PHILARET_URL,
    "dositheus.html": DOSITHEUS_URL,
    "book_of_needs.txt": NEEDS_TEXT,
    "blackmore_scan.txt": archive_text(BLACKMORE_ID),
    "robertson_scan.txt": archive_text(ROBERTSON_ID),
}

# --- expected structure ------------------------------------------------------

# Schaff numbered the questions himself ("The numbering of Questions, and the
# difference in type of Questions and Answers, are ours"), so the count is a
# property of this edition and can be asserted exactly.
PHILARET_QUESTIONS = 611

# Where this transcription loses text. Recorded rather than tolerated:
# asserting the exact set means a page that has been re-edited — in either
# direction — fails here instead of shipping.
#
# 288 is absent outright, falling between "why does not the Creed mention all
# these Sacraments" (287) and the questions on Unction with Chrism (289 on).
# 126 and 150 are present but answered by an empty paragraph; both sit
# immediately before a section heading, which is where this page drops text.
# Three of 611, and the questions either side of each are intact.
PHILARET_MISSING = {288}
PHILARET_UNANSWERED = {126, 150}

PHILARET_CLOSES = re.compile(r"<hr\s*/?>\s*<p[^>]*>\s*\[The Longer Catechism", re.I)

DOSITHEUS_DECREES = 18
DOSITHEUS_QUESTIONS = 4

DOSITHEUS_CLOSES = re.compile(r'<p[^>]*class="author"', re.I)

# Shann translated a selection and says so in his own preface: the chapters of
# the Trebnik "which are not of general interest" are omitted, as are the
# Kalendar and Paschal tables. This is the set he actually printed. Asserting
# it keeps the omission a recorded property of the edition rather than an
# unnoticed hole in the corpus.
NEEDS_CHAPTERS = [
    "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X",
    "XI", "XII", "XIII", "XIV", "XV", "XVI", "XVII", "XVIII", "XIX", "XX",
    "XXI", "XXIV", "XXV", "XXVI", "XXVII", "XXVIII", "XXIX", "XXXIII",
]

# Vocabulary containment of each unit against the whole corroborating scan.
#
# Both numbers are measured on the fetched pair and printed on every run, so a
# drift in either page shows up as a number rather than as silence. The floors
# sit just under the observed worst case: high enough that a modernised
# paraphrase or a different document fails, low enough to absorb OCR damage and
# the genuine editorial differences between two printings.
MIN_UNIT_OVERLAP = 0.55
MIN_MEDIAN_OVERLAP = 0.80

# Below this a "unit" is a heading or a stray fragment, not a passage.
MIN_UNIT_CHARS = 60


def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    for name, url in FILES.items():
        path = CACHE / name
        if path.exists():
            print(f"  cached   {name:<20} {path.stat().st_size:>10,} bytes")
            continue
        print(f"  fetching {name:<20} {url}")
        result = subprocess.run(
            ["curl", "-fsSL", "--max-time", "300", "-A", USER_AGENT, url,
             "-o", str(path)],
            capture_output=True,
        )
        if result.returncode != 0:
            sys.exit(f"  FAILED {name}: curl exit {result.returncode}")
        print(f"           {'':<20} {path.stat().st_size:>10,} bytes")


def read(name):
    """Read a cached file, normalising line endings.

    Gutenberg serves CRLF. Every paragraph split downstream looks for a blank
    line as `\\n\\n`, which `\\r\\n\\r\\n` does not contain, so leaving the
    carriage returns in produced 28 correctly-detected chapters with no text
    under any of them — a shape that reads as "the parser found nothing"
    rather than as an encoding fault.
    """
    path = CACHE / name
    if not path.exists():
        sys.exit(f"missing {path} — run `ingest_orthodox.py fetch` first")
    text = path.read_bytes().decode("utf-8", errors="replace")
    return text.replace("\r\n", "\n").replace("\r", "\n")


# --- corroboration -----------------------------------------------------------

def words(text):
    return re.findall(r"[a-z]+", text.lower())


def bigrams(text):
    tokens = words(text)
    return {(a, b) for a, b in zip(tokens, tokens[1:])}


def containment(unit_text, witness):
    """Fraction of the unit's word-pairs that also occur in the witness.

    Word *pairs* rather than words: a single-word check passes on any two texts
    of the same period and subject, because English theological vocabulary is
    small and shared. Pairs carry enough word order to distinguish "this is the
    same sentence" from "this is about the same topic", while staying immune to
    the pagination junk, running heads and marginal notes that OCR sprays
    through a scan — those add bigrams to the witness, and adding to the
    witness can only help containment, never fake it.
    """
    pairs = bigrams(unit_text)
    if not pairs:
        return 0.0
    return len(pairs & witness) / len(pairs)


def corroborate(title, units, witness_text, opens=None, closes=None):
    """Gate a transcription against the scan of the printing it claims to be."""
    region = witness_text
    if opens:
        match = opens.search(region)
        if not match:
            sys.exit(f"{title}: corroborating scan does not contain the opening "
                     f"anchor — refusing to ingest")
        region = region[match.start():]
    if closes:
        match = closes.search(region)
        if match:
            region = region[:match.start()]

    witness = bigrams(region)
    scores = [containment(u["content"], witness) for u in units]
    median = statistics.median(scores)
    worst = min(scores)
    lowest = units[scores.index(worst)]["title"]

    print(f"    corroboration: median {median:.0%}, lowest {worst:.0%} "
          f"({lowest[:44]})")

    if median < MIN_MEDIAN_OVERLAP:
        sys.exit(f"{title}: median containment {median:.0%} is below "
                 f"{MIN_MEDIAN_OVERLAP:.0%} — the transcription and the scan "
                 f"are not the same document. Refusing to ingest.")
    if worst < MIN_UNIT_OVERLAP:
        sys.exit(f"{title}: {lowest!r} scores {worst:.0%}, below "
                 f"{MIN_UNIT_OVERLAP:.0%} — refusing to ingest.")
    return median, worst


# --- HTML --------------------------------------------------------------------

TAG = re.compile(r"<[^>]+>")
DROP = re.compile(r"<(script|style)[^>]*>.*?</\1>", re.S)
BLOCK = re.compile(r"<(h1|h2|h3|h4|p)\b[^>]*>(.*?)</\1>", re.S)


def plain(fragment):
    text = html.unescape(TAG.sub(" ", fragment))
    return re.sub(r"\s+", " ", text).strip()


def blocks(document):
    return [(tag.lower(), plain(inner)) for tag, inner in BLOCK.findall(DROP.sub(" ", document))]


# --- Philaret ----------------------------------------------------------------

def parse_philaret(document):
    """Question-and-answer units, using the numbering as the parser's spine.

    The page marks questions two different ways — `<p class="q">` for the first
    306 and a bold run thereafter — so keying on the markup finds half the
    document. Keying on the number instead works for both, and the answers
    themselves contain enumerated lists ("1. ... 2. ...") that would wreck a
    naive number match. Requiring each question to be the *next* one expected
    steps straight over those: an enumeration restarts at 1, which is always
    behind the count, while a real question only ever moves it forward.
    """
    body = document[document.find("INTRODUCTION TO THE ORTHODOX CATECHISM"):]
    if not body:
        sys.exit("Philaret: catechism body not found — refusing to ingest")

    # The page closes with its own provenance note after a rule. It is a
    # paragraph like any other, so without this the note lands inside question
    # 611 and the corpus ends the Orthodox catechism with a citation of itself.
    closing = PHILARET_CLOSES.search(body)
    if not closing:
        sys.exit("Philaret: closing note not found — the page has changed. "
                 "Refusing to ingest.")
    body = body[:closing.start()]

    units, missing, unanswered = [], set(), set()
    heading = None
    expect = 1
    pending = None

    def close(pending):
        # Any answer at all is enough. A length floor here silently ate 93 of
        # the 610 questions on the first run, because a catechism's answers are
        # often a single clause — "There is a way, which is penitence." — and
        # dropping those leaves a document that looks complete, numbers
        # correctly, and is missing a sixth of itself.
        if not pending:
            return
        if not "".join(pending["answer"]).strip():
            unanswered.add(pending["number"])
            return
        units.append({
            "number": pending["number"],
            "title": pending["title"][:200],
            "content": " ".join([pending["question"], *pending["answer"]]).strip(),
        })

    for tag, text in blocks(body):
        if tag != "p":
            if text:
                heading = text.rstrip(".")
            continue

        match = re.match(r"(\d{1,3})[.)]\s*(.*)", text)
        number = int(match.group(1)) if match else None

        if number is not None and number >= expect:
            close(pending)
            if number > expect:
                missing.update(range(expect, number))

            # The short questions carry their answer on the same line —
            # "469. What does the Lord promise to the pure in heart? That they
            # shall see God." — so the paragraph is split at its question mark
            # rather than assumed to be a question alone.
            rest = match.group(2).strip()
            question, mark, answer = rest.partition("?")
            question = (question + mark).strip() if mark else rest
            pending = {
                "number": number,
                "question": question,
                "answer": [answer.strip()] if answer.strip() else [],
                "title": f"{number}. {question}" if not heading
                         else f"{heading} — {number}. {question}",
            }
            expect = number + 1
        elif pending and text:
            pending["answer"].append(text)

    close(pending)

    highest = units[-1]["number"] if units else 0
    if highest != PHILARET_QUESTIONS:
        sys.exit(f"Philaret: highest question is {highest}, expected "
                 f"{PHILARET_QUESTIONS} — refusing to ingest")
    if missing != PHILARET_MISSING or unanswered != PHILARET_UNANSWERED:
        sys.exit(f"Philaret: absent {sorted(missing)}, unanswered "
                 f"{sorted(unanswered)}; expected {sorted(PHILARET_MISSING)} "
                 f"and {sorted(PHILARET_UNANSWERED)} — the page has changed. "
                 f"Refusing to ingest.")

    expected_units = PHILARET_QUESTIONS - len(missing) - len(unanswered)
    if len(units) != expected_units:
        sys.exit(f"Philaret: {len(units)} units for {expected_units} answered "
                 f"questions — refusing to ingest")

    print(f"    {len(units)} of {PHILARET_QUESTIONS} questions "
          f"({sorted(missing)[0]} absent, {sorted(unanswered)} unanswered, "
          f"as expected)")

    corroborate(
        "Philaret", units, read("blackmore_scan.txt"),
        # Blackmore's volume opens with the Primer and the Shorter Catechism;
        # the Longer Catechism runs from its own title page to the treatise on
        # parish priests that follows it.
        opens=re.compile(r"END\s+OF\s+THE\s+SHORTER\s+CATECHISM"),
        closes=re.compile(r"DUTY\s+OF\s+PARISH\s+PRIESTS"),
    )

    return {
        "title": "The Longer Catechism of the Orthodox, Catholic, Eastern Church",
        "author": "Philaret (Drozdov) of Moscow",
        "date": "1830",
        "tradition": "Eastern Orthodox",
        "kind": "Catechism",
        "url": PHILARET_URL,
        "translator": "R. W. Blackmore",
        "collection": PHILARET_CITE,
        "rights": (
            "Public domain: composed 1830, Blackmore's English 1845, "
            "reprinted in Schaff's Creeds of Christendom vol. II, 1877"
        ),
        "notes": (
            f"608 of the edition's {PHILARET_QUESTIONS} questions: "
            f"{sorted(PHILARET_MISSING)[0]} is absent from this transcription "
            f"and {sorted(PHILARET_UNANSWERED)} are printed without their "
            f"answers. The questions either side of each are intact. "
            f"Corroborated against the 1845 Aberdeen printing "
            f"(archive.org/details/{BLACKMORE_ID})."
        ),
        "supersedes": ["The Orthodox Confession of Faith", "Orthodox Confession"],
        "units": units,
    }


# --- Dositheus ---------------------------------------------------------------

def parse_dositheus(document):
    """Eighteen decrees and four questions, each an <h2> with paragraphs under.

    The confession ends with Dositheus's own subscription; everything after
    that is the site's own footer, which is made of ordinary paragraphs and so
    lands inside the last question if it is not cut off here. The corroboration
    gate does not catch it — a few hundred characters of navigation appended to
    a long unit still scores well — which is why the boundary is explicit
    rather than left to the check downstream.
    """
    closing = DOSITHEUS_CLOSES.search(document)
    if not closing:
        sys.exit("Dositheus: page footer boundary not found — the page has "
                 "changed. Refusing to ingest.")
    document = document[:closing.start()]

    units = []
    current = None

    for tag, text in blocks(document):
        match = re.match(r"(Decree|Question)\s+(\d+)\s*$", text) if tag == "h2" else None
        if match:
            if current:
                units.append(current)
            kind, number = match.group(1), int(match.group(2))
            current = {
                "number": number,
                "title": f"{kind} {number}",
                "content": "",
                "kind": kind,
            }
        elif current and tag == "p" and text:
            current["content"] = f"{current['content']} {text}".strip()

    if current:
        units.append(current)

    units = [u for u in units if len(u["content"]) >= MIN_UNIT_CHARS]
    decrees = sum(1 for u in units if u["kind"] == "Decree")
    questions = sum(1 for u in units if u["kind"] == "Question")
    for unit in units:
        del unit["kind"]

    if (decrees, questions) != (DOSITHEUS_DECREES, DOSITHEUS_QUESTIONS):
        sys.exit(f"Dositheus: found {decrees} decrees and {questions} questions, "
                 f"expected {DOSITHEUS_DECREES} and {DOSITHEUS_QUESTIONS} — "
                 f"refusing to ingest")

    print(f"    {decrees} decrees, {questions} questions")

    corroborate("Dositheus", units, read("robertson_scan.txt"))

    return {
        "title": "The Confession of Dositheus",
        "author": "Synod of Jerusalem",
        "date": "1672",
        "tradition": "Eastern Orthodox",
        "kind": "Confession",
        "url": DOSITHEUS_URL,
        "translator": "J. N. W. B. Robertson",
        "collection": DOSITHEUS_CITE,
        "rights": (
            "Public domain: synod of 1672, Robertson's English published 1899; "
            "the transcriber makes no copyright claim on the document itself"
        ),
        "notes": (
            f"The transcription describes itself as adapted from Robertson's "
            f"1899 translation rather than reprinted from it; corroborated "
            f"against the 1899 printing "
            f"(archive.org/details/{ROBERTSON_ID})."
        ),
        "units": units,
    }


# --- Book of Needs -----------------------------------------------------------

GUTENBERG_START = re.compile(r"\*\*\*\s*START OF TH(?:E|IS) PROJECT GUTENBERG EBOOK.*?\*\*\*", re.I)
GUTENBERG_END = re.compile(r"\*\*\*\s*END OF TH(?:E|IS) PROJECT GUTENBERG EBOOK.*?\*\*\*", re.I)
CHAPTER = re.compile(r"^_Chapter\s+([IVXLC]+)\._\s*$", re.M)

# What follows the last chapter, in order: the book's endnotes, then its
# appendix — the offices for the laying on of hands named on the title page.
# Neither carries a chapter mark, so without this the last chapter runs to the
# end of the file and a prayer for a traveller finishes with the appointment of
# an archimandrite.
TAIL = re.compile(r"^(FOOTNOTES|APPENDIX\.)\s*$", re.M)
APPENDIX = re.compile(r"^APPENDIX\.\s*$", re.M)
# The appendix repeats its own table of contents before the offices begin.
APPENDIX_OPENS = re.compile(r"^CONTENTS OF APPENDIX\.\s*$", re.M)
APPENDIX_BODY = re.compile(r"^\[Illustration\]\s*$", re.M)

# A display unit larger than this is not a citable passage. Matches the ceiling
# already used for the Book of Concord in ingest_gutenberg.py.
MAX_UNIT_CHARS = 9000


def clean_gutenberg(block):
    paragraphs = [re.sub(r"\s+", " ", p).strip() for p in re.split(r"\n\s*\n", block)]
    text = "\n\n".join(p for p in paragraphs if len(p) > 1)
    text = text.replace("[Illustration]", "")
    # Gutenberg marks italics with underscores; the rubrics are set entirely in
    # italic, so leaving them in would underscore half the book.
    text = re.sub(r"_([^_\n]{1,400})_", r"\1", text)
    return re.sub(r"[ \t]+", " ", text).strip()


def split_oversized(units):
    result = []
    for unit in units:
        if len(unit["content"]) <= MAX_UNIT_CHARS:
            result.append(unit)
            continue
        parts, chunk, size = [], [], 0
        for para in unit["content"].split("\n\n"):
            chunk.append(para)
            size += len(para)
            if size >= MAX_UNIT_CHARS * 0.6:
                parts.append("\n\n".join(chunk))
                chunk, size = [], 0
        if chunk:
            parts.append("\n\n".join(chunk))
        for i, part in enumerate(parts, 1):
            result.append({
                "number": unit["number"],
                "title": f"{unit['title']} ({i} of {len(parts)})",
                "content": part,
            })
    return result


_ROMAN = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100}


def to_int(value):
    total = previous = 0
    for char in reversed(value.upper()):
        current = _ROMAN.get(char, 0)
        total += current if current >= previous else -current
        previous = max(previous, current)
    return total


def appendix_units(body, start_number):
    """The offices for the laying on of hands, as one titled run.

    Not split per office: the office headings are not headings but the opening
    words of their own first sentence — "THE OFFICE FOR THE APPOINTMENT OF A
    READER AND SINGER IS PERFORMED ON THIS WISE" — so there is no boundary to
    cut on that is not also a cut through a sentence. `split_oversized` divides
    the run on paragraph boundaries instead, which is honest about what it is
    doing.
    """
    mark = APPENDIX.search(body)
    if not mark:
        sys.exit("Book of Needs: appendix not found — refusing to ingest")

    section = body[mark.end():]
    opens = APPENDIX_BODY.search(section, APPENDIX_OPENS.search(section).end()
                                 if APPENDIX_OPENS.search(section) else 0)
    if opens:
        section = section[opens.end():]

    content = clean_gutenberg(section)
    if len(content) < MIN_UNIT_CHARS:
        sys.exit("Book of Needs: appendix is empty — refusing to ingest")

    return [{
        "number": start_number,
        "title": "Appendix — The Laying On Of Hands",
        "content": content,
    }]


def parse_book_of_needs(text):
    start = GUTENBERG_START.search(text)
    end = GUTENBERG_END.search(text)
    if not start:
        sys.exit("Book of Needs: no Gutenberg start marker — refusing to ingest")
    if not re.search(r"public domain", text, re.I):
        sys.exit("Book of Needs: no public-domain statement — refusing to ingest")
    body = text[start.end(): end.start() if end else len(text)]

    marks = list(CHAPTER.finditer(body))
    numerals = [m.group(1) for m in marks]
    if numerals != NEEDS_CHAPTERS:
        sys.exit(f"Book of Needs: chapters {numerals} do not match the expected "
                 f"{NEEDS_CHAPTERS} — refusing to ingest")

    units = []
    for i, mark in enumerate(marks):
        stop = marks[i + 1].start() if i + 1 < len(marks) else len(body)
        tail = TAIL.search(body, mark.end(), stop)
        if tail:
            stop = tail.start()
        section = body[mark.end():stop]

        # The chapter title is the run of capitals immediately under the mark.
        heading, _, rest = section.lstrip("\n").partition("\n\n")
        heading = " ".join(heading.split()).rstrip(".")
        content = clean_gutenberg(rest)
        if len(content) < MIN_UNIT_CHARS:
            continue
        units.append({
            "number": to_int(mark.group(1)),
            "title": f"Chapter {mark.group(1)} — {heading.title()}"[:200],
            "content": content,
        })

    chapters = len(units)
    units.extend(appendix_units(body, start_number=to_int(numerals[-1]) + 1))

    units = split_oversized(units)
    print(f"    {len(numerals)} chapters + appendix -> {len(units)} units")

    return {
        "title": "The Book of Needs of the Holy Orthodox Church",
        "author": "Orthodox Eastern Church",
        "date": "1894",
        "tradition": "Eastern Orthodox",
        "kind": "Liturgy",
        "url": NEEDS_URL,
        "translator": "G. V. Shann",
        "collection": (
            "Book of Needs of the Holy Orthodox Church, with an appendix "
            "containing offices for the laying on of hands (London: David "
            "Nutt, 1894), from the Moscow Synodal Press Trebnik of 1882"
        ),
        "rights": (
            "Public domain: Shann's translation published 1894; Project "
            "Gutenberg transcription, proofread by Distributed Proofreaders"
        ),
        "notes": (
            "Shann translated a selection: his preface omits the chapters of "
            "the Trebnik 'which are not of general interest' (xxii, xxiii, "
            "xxx-xxxii, xxxiv onward) and the Kalendar and Paschal tables. "
            "The 28 chapters here are the whole of what he printed."
        ),
        "units": units,
    }


# --- driver ------------------------------------------------------------------

def parse():
    records = []

    print("  The Longer Catechism (Philaret, 1830)")
    records.append(parse_philaret(read("philaret.html")))

    print("  The Confession of Dositheus (1672)")
    records.append(parse_dositheus(read("dositheus.html")))

    print("  The Book of Needs (Trebnik, 1894)")
    records.append(parse_book_of_needs(read("book_of_needs.txt")))

    print()
    for record in records:
        chars = sum(len(u["content"]) for u in record["units"])
        print(f"  {record['title'][:52]:<54} {len(record['units']):>4} units  "
              f"{chars:>9,} chars")

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    UNITS.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
    print(f"\n-> {UNITS}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()
    {"fetch": fetch, "parse": parse}[args.command]()


if __name__ == "__main__":
    main()
