#!/usr/bin/env python3
"""Ingest Reformation-era and post-Reformation works from CCEL text exports.

The corpus was strong on the Fathers and thin on everyone who came after them:
402 early-church sources against 7 Reformed, 4 Lutheran and 2 Baptist. A
question about assurance, or providence, or the atonement, could be answered
with Augustine and Chrysostom and nothing from the tradition that spent four
centuries arguing about exactly those things.

This fills that in from CCEL, which is the right archive for the job for the
same reason `ingest_gutenberg.py` chose Gutenberg over a scan: these are
proofread transcriptions, not OCR, and every export carries its own metadata
header — Title, Creator(s) with translator, and Rights.

**Nothing here is hand-typed.** The work ids came off CCEL's own author index
pages via `survey_ccel.py`, and the title, author, dates, translator and
rights of every source come out of that work's own export header. The only
judgements made in this file are which works to take and which tradition and
genre each belongs to. That matters: a hand-written list of titles is a list of
guesses, and the two things most easily got wrong — who translated it and
whether it is public domain — are exactly the two the header states outright.

**How the units are cut.** Not with a heading regex per work; there are two
hundred works here and their headings agree on nothing. CCEL's exports are
divided by a rule of underscores, and that rule is a real structural boundary
in every export examined — it separates each of Spurgeon's sermons, each
chapter of Calvin's *Institutes*, each chapter of Matthew Henry, each section
of Edwards. So the rule is the backbone, and the classifier below sorts the
resulting segments into headings, footnote blocks and body text. Where a
segment is too long to read as one passage it is split on paragraph
boundaries, as in `ingest_gutenberg.py`.

Every work is gated on its own header stating public domain, and on producing
at least `MIN_UNITS` units and `MIN_WORK_CHARS` characters. A work that fails
is reported and skipped rather than ingested in a broken state — the failure
mode this whole corpus has been cleaning up after is text that looks fine and
is not.

CCEL's robots.txt sets `Crawl-delay: 10` and disallows nothing. Honour it; the
fetch is meant to run in the background.

    python3 tools/ingest_reformation.py fetch
    python3 tools/ingest_reformation.py parse
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "reformation"
UNITS = ROOT / "tools" / "data" / "reformation_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)
DELAY_SECONDS = 10.0


def works():
    """(ccel author, work id, tradition, genre) for everything to ingest.

    Traditions are the ones already in the database. Some assignments are
    judgement calls worth stating: Whitefield is filed Methodist though he died
    an Anglican priest, because he is read as a founder of the movement;
    Barnes and Hodge are Reformed as American Presbyterians; à Kempis and
    Brother Lawrence are Catholic; Ryle, Newton and William Law are Anglican.
    Bunyan, Gill and Spurgeon are Baptist, which is what takes that tradition
    out of single figures.
    """
    entries = []

    def add(author, ids, tradition, kind):
        entries.extend((author, work, tradition, kind) for work in ids)

    # --- Reformed ------------------------------------------------------------
    add("calvin", ["institutes"], "Reformed", "Treatise")
    add("calvin", [f"calcom{n:02d}" for n in range(1, 46)], "Reformed", "Commentary")
    add("calvin", ["chr_life", "prayer", "treatise_relics", "sermons"],
        "Reformed", "Treatise")
    add("henry", [f"mhc{n}" for n in range(1, 7)], "Reformed", "Commentary")
    add("knox", ["history_reformation", "blast", "prayer", "works1"],
        "Reformed", "Treatise")
    add("bullinger", ["apocalypse"], "Reformed", "Commentary")
    # Owen is not listed here. All thirty-one of his works were refused by
    # `public_domain` below, because CCEL sets every one of them from a Banner
    # of Truth printing of 1965-68 and states no rights — and this file has no
    # way to tell a modern reprint of a Victorian edition from a modern edition.
    # `ingest_owen.py` answers that question with evidence instead of a date,
    # and owns the author.
    add("edwards", ["affections", "will", "works1", "works2", "sermons",
                    "treatiseongrace", "trinity"], "Reformed", "Treatise")
    add("baxter", ["saints_rest", "pastor", "practical"], "Reformed", "Treatise")
    add("watson", ["beatitudes", "commandments", "contentment", "cordial",
                   "divinity", "prayer"], "Reformed", "Treatise")
    add("flavel", ["fountain", "grace", "life", "lovely", "pneum",
                   "saintindeed"], "Reformed", "Treatise")
    add("charnock", ["cleansing", "efficient_regeneration", "instr_regen",
                     "nat_regen", "nec_regen", "reconcil"], "Reformed", "Treatise")
    add("manton", [f"manton{n:02d}" for n in (1, 2, 3, 4, 5, 6, 7, 8, 20)],
        "Reformed", "Sermon")
    add("boston", ["crook"], "Reformed", "Treatise")
    add("hodge", ["theology1", "theology2", "theology3", "ephesians"],
        "Reformed", "Treatise")
    add("bonar", ["peace", "followlamb", "goto", "soulwinners"],
        "Reformed", "Treatise")
    add("murray", ["covenants", "deeper", "indwelling", "lords_table",
                   "new_life", "obedience", "prayer", "surrender", "true_vine",
                   "waiting", "working"], "Reformed", "Treatise")
    add("barnes", ["ntnotes"], "Reformed", "Commentary")

    # --- Baptist -------------------------------------------------------------
    add("spurgeon", [f"sermons{n:02d}" for n in range(1, 64)], "Baptist", "Sermon")
    # The Treasury of David is no longer listed. CCEL serves it only as page
    # images — each volume's "text" export is ~50 KB of "Image of page 73"
    # against about four thousand real words of front matter — so all six were
    # refused by the placeholder gate in `parse_work`. `ingest_treasury.py`
    # takes it from a transcription instead.
    add("spurgeon", ["morneve", "checkbook", "grace", "catechism",
                     "till_he_come"], "Baptist", "Treatise")
    add("bunyan", ["pilgrim", "holy_war", "grace", "miscellaneous"],
        "Baptist", "Treatise")
    add("gill", ["doctrinal", "practical", "song"], "Baptist", "Treatise")

    # --- Lutheran ------------------------------------------------------------
    # smalcald and smallcat are deliberately absent: the corpus already holds
    # the Book of Concord from Gutenberg's Bente/Dau text, and a second copy
    # under a different translator is a duplicate, not coverage.
    add("luther", ["bondage", "galatians", "tabletalk", "christianliberty",
                   "first_prin", "good_works", "largecatechism",
                   "prefacetoromans", "romans_pt", "stpeter_stjude",
                   "theses", "translating"], "Lutheran", "Treatise")
    add("luther", ["sermons"], "Lutheran", "Sermon")

    # --- Anglican ------------------------------------------------------------
    add("ryle", ["holiness", "matthew", "twobears", "upper_room"],
        "Anglican", "Treatise")
    add("law", ["serious_call", "love2", "clergy", "justific", "prayer"],
        "Anglican", "Treatise")
    add("newton", ["olneyhymns", "messiah1", "messiah2"], "Anglican", "Treatise")
    add("lightfoot", ["fathers"], "Anglican", "Treatise")

    # --- Methodist -----------------------------------------------------------
    add("whitefield", ["sermons"], "Methodist", "Sermon")
    add("clarke", ["entire_sanct"], "Methodist", "Treatise")

    # --- Catholic ------------------------------------------------------------
    add("kempis", ["imitation"], "Catholic", "Treatise")
    add("lawrence", ["practice"], "Catholic", "Treatise")

    return entries


WORKS = works()

# --- gates -------------------------------------------------------------------

# A work producing fewer units than this parsed as one undivided blob, which
# means the rule backbone did not apply to it and its units are not citable.
MIN_UNITS = 3
# Below this the export is a stub or a table of contents, not the work. CCEL
# carries both: `barnes/isaiah1` is 46 KB of front matter for a commentary
# whose text lives in `barnes/ntnotes`.
MIN_WORK_CHARS = 20000

MIN_UNIT_CHARS = 200
MAX_UNIT_CHARS = 9000

# --- CCEL export shape -------------------------------------------------------

RULE = re.compile(r"^[ \t]*_{20,}[ \t]*$", re.M)

# CCEL's header is a label column and a value column, and a value may run onto
# further lines indented to that column — which is exactly where the translator
# lives:
#
#      Creator(s): Calvin, John (1509-1564)
#                  Beveridge, Henry (Translator)
#
# Reading only the labelled line therefore drops the translator of every
# translated work in the archive.
FIELD_LINE = re.compile(r"^\s*([A-Z][A-Za-z()/ .]*?):\s*(.*)$")

# --- rights ------------------------------------------------------------------

# US public domain. Everything published before this year is free; almost
# nothing after it is. Same cutoff SOURCES.md states for the corpus at large.
PD_CUTOFF = 1929

# Authors who wrote in English. For these, the author's own death date settles
# the question: there is no translator whose separate copyright could still be
# running. For everyone else — Calvin, Luther, Bullinger, à Kempis, Brother
# Lawrence — the English is somebody's translation, and a translation made in
# 1950 is in copyright however old its original is. Those works are ingested
# only when CCEL states public domain outright.
ENGLISH_ORIGINAL = {
    "barnes", "baxter", "bonar", "boston", "bunyan", "charnock", "clarke",
    "edwards", "flavel", "gill", "henry", "hodge", "knox", "law", "lightfoot",
    "manton", "murray", "newton", "owen", "ryle", "spurgeon", "watson",
    "whitefield",
}

YEAR = re.compile(r"\b(1[5-9]\d\d|20\d\d)\b")

# A segment that is only a footnote block: CCEL emits these between body
# segments and they are reference apparatus keyed to markers the text no longer
# carries, so they read as non-sequiturs wherever they land.
FOOTNOTES = re.compile(r"^\s*\[\d+\]")

# Front matter to skip before the work proper. Matched against a segment's
# first line, over the opening run of segments only — see `parse_work`.
#
# The index patterns that used to be listed here have been removed. They are
# back matter, they are already caught by `BACK_MATTER`, and having them here
# was actively destructive: a short work's closing "Indexes" segment falls
# inside the opening window, so the skip jumped past the entire body and left
# the indexes standing in for the work.
FRONT_MATTER = re.compile(
    r"^\s*(TITLE PAGE|CONTENTS|TABLE OF CONTENTS|ABOUT THIS BOOK|"
    r"COPYRIGHT|PRINTING HISTORY)\b", re.I)

# Back matter, which front-matter skipping cannot reach because it comes after
# the work. Matthew Henry's six volumes each end with a scripture index —
# 231 units and 6.5 M characters of "Isaiah 1:1 ... 1:2 ..." that read as text,
# retrieve as text, and say nothing. This is the same defect as a contents page
# standing in for a work, arriving from the other end of the book.
BACK_MATTER = re.compile(
    r"^\s*(INDEX(ES)?\b|SCRIPTURE INDEX|SUBJECT INDEX|GENERAL INDEX)", re.I)

# Spaced-out display capitals: "G E N E S I S", "P R E F A C E".
SPACED = re.compile(r"^(?:[A-Z]\s){2,}[A-Z]\.?$")


def is_headingish(line):
    """A line that titles what follows rather than saying anything itself."""
    stripped = line.strip()
    if not stripped or len(stripped) > 90:
        return False
    if SPACED.match(stripped):
        return True
    if re.match(r"^(CHAP(TER)?|SERMON|PART|SECT(ION)?|BOOK|DISCOURSE|"
                r"LECTURE|PSALM|ARTICLE)\b", stripped, re.I):
        return True
    letters = [c for c in stripped if c.isalpha()]
    if letters and sum(c.isupper() for c in letters) / len(letters) > 0.9:
        return True
    return False


def unspace(text):
    """'G E N E S I S' -> 'Genesis'."""
    if SPACED.match(text.strip()):
        return re.sub(r"\s+", "", text.strip()).title()
    return text


def is_display_matter(content):
    """True for title pages and dedications — set in capitals, not prose.

    These survive the length floor (a title page runs to several hundred
    characters of translator, college and publisher) and then sit in the corpus
    as a retrievable "passage" that says nothing. Case is the giveaway: real
    prose is overwhelmingly lower case.
    """
    letters = [c for c in content if c.isalpha()]
    if not letters:
        return True
    return sum(c.islower() for c in letters) / len(letters) < 0.55


# Apparatus from CCEL's own production, not the author's text. "Image of page
# 336" is a placeholder for a scan CCEL serves separately; the Treasury of
# David volumes carry runs of hundreds of them, which parsed into 108 units
# that were nothing else. `Topic No. 05901` is CCEL's internal section id.
NOISE = re.compile(r"(Image of page \d+|Topic No\.\s*\d+)\s*")

# Every CCEL export ends with a colophon and a numbered list resolving each
# hyperlink in the document to a `file:///ccel/...` path. It is machine
# apparatus, but a page of it is long enough to satisfy any floor expressed in
# characters, so 3,438 units of it — some 27 M characters — passed every gate
# here and shipped as text.
URL_TEXT = re.compile(r"(?:file|https?|ftp)://\S+")
COLOPHON = re.compile(
    r"^This document is from the Christian Classics Ethereal Library")


def is_reference_apparatus(paragraph):
    """A paragraph that is link targets rather than prose.

    By proportion rather than by presence: a sentence that cites a URL is still
    a sentence, and the reference lists are essentially nothing else.
    """
    if COLOPHON.match(paragraph):
        return True
    urls = URL_TEXT.findall(paragraph)
    if not urls:
        return False
    return sum(len(u) for u in urls) / len(paragraph) > 0.5


def clean(block):
    block = NOISE.sub("", block)
    paragraphs = [re.sub(r"\s+", " ", p).strip() for p in re.split(r"\n\s*\n", block)]
    kept = [p for p in paragraphs
            if len(p) > 1
            and not FOOTNOTES.match(p)
            and not is_reference_apparatus(p)]
    return "\n\n".join(kept).strip()


def segments(text):
    """Split a CCEL export on its rule separators."""
    rules = list(RULE.finditer(text))
    if not rules:
        return []
    out = []
    for i, rule in enumerate(rules):
        stop = rules[i + 1].start() if i + 1 < len(rules) else len(text)
        body = text[rule.end():stop].strip("\n")
        if body.strip():
            out.append(body)
    return out


PARAGRAPH = re.compile(r"\n\s*\n")
SENTENCE_END = (".", "?", "!", ",", ";", ":")

# At most this many leading blocks become the title. Two is enough for the
# deepest real case — Matthew Henry sets the book and the chapter on separate
# lines, "G E N E S I S" then "CHAP. I." — and three starts dragging the
# opening clause of the text in behind them.
MAX_TITLE_BLOCKS = 2


def title_and_body(segment):
    """Peel the leading heading blocks off a segment.

    Case alone is not enough to recognise a heading. Spurgeon's sermon titles
    are set in ordinary mixed case — "The Immutability of God" — so an
    all-capitals test finds the chapter marks in Calvin and Matthew Henry and
    misses the title of every one of the nine hundred sermons in the archive,
    leaving them all titled after the volume they came from.

    What actually distinguishes a heading in these exports is layout: it is a
    short block, standing alone between blank lines, that does not end like a
    sentence. That is true of the mixed-case titles and the capitalised chapter
    marks alike.
    """
    blocks = [b for b in PARAGRAPH.split(segment.strip("\n"))]
    head = []

    while blocks and len(head) < MAX_TITLE_BLOCKS:
        first = " ".join(blocks[0].split())
        if not first:
            blocks.pop(0)
            continue
        # Never take the last block: a segment that is nothing but a heading is
        # the heading *for the next one*, and the caller handles that.
        standalone = len(blocks) > 1 and len(first) <= 90
        if standalone and (is_headingish(first)
                           or not first.endswith(SENTENCE_END)):
            head.append(unspace(first))
            blocks.pop(0)
            continue
        break

    title = " — ".join(h.rstrip(".") for h in head if h)
    return title, "\n\n".join(blocks)


def hard_split(text, limit):
    """Break a paragraph that is itself over the limit, at a sentence if we can.

    Paragraph splitting alone is not enough, and assuming it is produced units
    of 5.4 M characters labelled "(1 of 1)": some of these exports contain a
    block with no blank line in it at all, so there is no boundary to cut on
    and the "split" returns the whole thing. Those units are unreadable, and
    they also break chunking outright — `build_chunks.py` derives chunk ids as
    `unit_id * 1000 + sequence`, so a unit yielding more than a thousand chunks
    collides with the next unit's ids and the embeddings silently start
    pointing at unrelated text.
    """
    parts = []
    while len(text) > limit:
        window = text[:limit]
        cut = max(window.rfind(". "), window.rfind("? "), window.rfind("! "))
        if cut < limit // 2:
            cut = window.rfind(" ")
        if cut < limit // 2:
            cut = limit
        parts.append(text[:cut + 1].strip())
        text = text[cut + 1:].lstrip()
    if text.strip():
        parts.append(text.strip())
    return parts


def split_oversized(units):
    result = []
    for unit in units:
        if len(unit["content"]) <= MAX_UNIT_CHARS:
            result.append(unit)
            continue

        parts, chunk, size = [], [], 0
        for para in unit["content"].split("\n\n"):
            for piece in (hard_split(para, MAX_UNIT_CHARS)
                          if len(para) > MAX_UNIT_CHARS else [para]):
                chunk.append(piece)
                size += len(piece)
                if size >= MAX_UNIT_CHARS * 0.6:
                    parts.append("\n\n".join(chunk))
                    chunk, size = [], 0
        if chunk:
            parts.append("\n\n".join(chunk))

        for i, part in enumerate(parts, 1):
            result.append({
                "number": unit["number"],
                "title": f"{unit['title']} ({i} of {len(parts)})"[:200],
                "content": part,
            })
    return result


def read_header(text):
    """CCEL's label/value header, keeping multi-line values together."""
    fields, label = {}, None
    for line in text[:3000].split("\n"):
        if RULE.match(line):
            if fields:
                break
            continue
        match = FIELD_LINE.match(line)
        if match and match.group(1) in (
            "Title", "Creator(s)", "Rights", "Print Basis", "CCEL Subjects",
            "LC Call no", "LC Subjects", "Description", "Source",
        ):
            label = match.group(1)
            fields[label] = match.group(2).strip()
        elif label and line.strip() and line.startswith("  "):
            fields[label] = f"{fields[label]} {line.strip()}".strip()
        elif not line.strip():
            label = None
    return fields


def public_domain(author_slug, fields, death_year):
    """Decide, and say on what basis. Returns (statement, None) or (None, why).

    Two bases, in order of strength. CCEL's own `Rights: Public Domain` is the
    strong one and is taken at face value. Where the field is simply absent —
    which it is for most of the archive — the fallback is publication date, the
    same reasoning `ingest_gutenberg.py` records for the Book of Concord: an
    English author dead before 1929 cannot have a live copyright in his own
    words, and no translator's can attach to a work that was never translated.

    A declared Print Basis later than the cutoff refuses the work — but only
    where the fallback is doing the work. Owen died in 1683, and CCEL sets his
    *Mortification of Sin* from a Banner of Truth printing of 1967; with no
    rights statement to go on, a modern edition that may carry modern editorial
    matter is not something to infer past. Refusing costs one work, where
    guessing wrong puts an in-copyright text in the corpus under a
    public-domain label — the mistake this corpus already had to be cleaned of
    once.

    An explicit statement outranks that inference rather than being vetoed by
    it. Calvin's commentaries are set from Baker's 1996 printing and CCEL still
    states public domain, because the printing is a photographic reissue of the
    Calvin Translation Society's Victorian edition. Refusing a work whose
    archive has affirmatively cleared it, on the strength of a date the archive
    can see too, is second-guessing the only party who actually knows.
    """
    rights = fields.get("Rights", "")
    if "public domain" in rights.lower():
        return f"CCEL states: {rights}", None
    if rights:
        return None, f"rights are {rights!r}"

    basis_edition = fields.get("Print Basis", "")
    if basis_edition:
        years = [int(y) for y in YEAR.findall(basis_edition)]
        if years and max(years) >= PD_CUTOFF:
            return None, f"no rights statement and print basis is {basis_edition!r}"

    if author_slug not in ENGLISH_ORIGINAL:
        return None, ("no rights statement, and the English is a translation "
                      "of unknown date")
    if death_year is None:
        return None, "no rights statement and no author dates to reason from"
    if death_year >= PD_CUTOFF:
        return None, f"no rights statement and the author died {death_year}"

    return (f"Public domain in the US: written in English by an author who "
            f"died in {death_year}, before the {PD_CUTOFF} cutoff; CCEL's "
            f"export states no rights"), None


def first_body_segment(parts):
    """Index of the first segment that is the work rather than what precedes it.

    Segment 0 is always the metadata header. After that, front matter is a
    contiguous *prefix*, so the scan stops at the first segment that is not
    front matter.

    It used to take the last match inside a twelve-segment window instead, and
    that is a different thing entirely: one stray match late in a short work
    discarded everything before it. Owen's *Gospel Grounds and Evidences* lost
    all four of its chapters to a match on its closing indexes, and his *Review
    of Grotius* was ingested as five units of the index's link table — which
    cleared every floor below, because a page of `file:///ccel/...` is long
    enough to look like prose to a character count.
    """
    start = 1
    for segment in parts[1:12]:
        if not FRONT_MATTER.match(segment):
            break
        start += 1
    return start


def parse_work(entry, text, rights_override=None):
    """Cut one CCEL export into units, or say why it was refused.

    `rights_override` supplies a public-domain statement from outside this
    file's reasoning, and is the only way past `public_domain` below. It exists
    for `ingest_owen.py`, which settles the rights question by evidence this
    function cannot see: it matches the transcription against a scan of the
    Victorian printing it descends from. Nothing here can do that — all it has
    is the header — so the alternative to an override would be to weaken the
    gate for every work in order to admit one author.
    """
    author_slug, work_id, tradition, kind = entry
    text = text.replace("\r\n", "\n").replace("\r", "\n")

    fields = read_header(text)
    title = fields.get("Title")
    if not title:
        return None, "no Title in the export header"

    author, translator, dates = read_creators(fields.get("Creator(s)", ""))
    death_year = int(dates.split("-")[1]) if dates and "-" in dates else None

    if rights_override:
        rights = rights_override
    else:
        rights, why = public_domain(author_slug, fields, death_year)
        if rights is None:
            return None, why

    parts = segments(text)
    if not parts:
        return None, "no rule separators — not a CCEL export"

    parts = parts[first_body_segment(parts):]

    units, carried = [], None
    for segment in parts:
        if FOOTNOTES.match(segment.lstrip()):
            continue
        heading, body = title_and_body(segment)
        if BACK_MATTER.match(heading or segment.lstrip()):
            carried = None
            continue
        content = clean(body)

        if is_display_matter(content):
            # A title page is not a heading for what follows it. Carrying it
            # forward prefixed Calvin's translator's preface with "COMMENTARIES
            # ON THE FIRST BOOK OF MOSES — CALLED".
            continue
        if len(content) < MIN_UNIT_CHARS:
            # A segment that is *only* a heading titles the next one.
            if heading:
                carried = heading
            continue

        label = " — ".join(x for x in (carried, heading) if x) or title
        carried = None
        units.append({
            "number": len(units) + 1,
            "title": label[:200],
            "content": content,
        })

    units = split_oversized(units)
    chars = sum(len(u["content"]) for u in units)

    if len(units) < MIN_UNITS:
        return None, f"only {len(units)} units"
    if chars < MIN_WORK_CHARS:
        return None, f"only {chars:,} characters — a stub or contents page"

    # A work served as page scans rather than text. CCEL's Treasury of David
    # exports are ~50 KB each of "Image of page 73" against about four thousand
    # real words of front matter — enough to clear both floors above while
    # containing none of the commentary. Stripping the placeholders and
    # measuring what is left against how many there were is the test that
    # separates this from a work that merely mentions an illustration: a real
    # transcription has none of these per thousand characters, and the Treasury
    # has eighteen.
    placeholders = len(re.findall(r"Image of page \d+", text))
    if placeholders and placeholders / (chars / 1000) > 1.0:
        return None, (f"{placeholders} page-image placeholders against "
                      f"{chars:,} characters — served as scans, not text")

    return {
        "title": title,
        "author": author,
        "date": dates,
        "tradition": tradition,
        "kind": kind,
        "url": f"https://www.ccel.org/ccel/{author_slug}/{work_id}",
        "rights": rights,
        "translator": translator,
        "collection": " | ".join(x for x in (
            f"CCEL text export {author_slug}/{work_id}",
            f"Print basis: {fields['Print Basis']}" if fields.get("Print Basis") else None,
        ) if x),
        "units": units,
    }, None


CREATOR_ROLE = re.compile(r"\(\s*(Translator|Editor|Compiler|Alternative)\s*\)", re.I)
CREATOR_DATES = re.compile(r"\((\d{3,4})\s*[-–]\s*(\d{3,4})\)")
# A new person begins at a surname followed by a comma: "Beveridge, Henry".
# Splitting on ")" followed by any capital instead — which is what this did —
# leaves `Calvin, John (1509-1564) (Alternative) (Translator)` as one string,
# because "(Alternative)" opens with a bracket rather than a letter. The whole
# entry then reads as a translator credit, Calvin becomes his own translator,
# and forty-five commentary volumes are filed with no author at all.
CREATOR_SPLIT = re.compile(r"(?<=\))\s+(?=[A-Z][A-Za-z'-]+\s*,)")


def read_creators(creators):
    """Pull author, translator and dates out of CCEL's Creator(s) field.

    The field is one or more people, each `Surname, Forename` followed by
    optional dates and optional roles:

        Calvin, John (1509-1564) Beveridge, Henry (Translator)
        Calvin, John (1509-1564) (Alternative) (Translator)

    The second form is the awkward one. It is a single person carrying role
    markers — CCEL recording that the volume has a translator without naming
    them — not two people. So a role marker cannot by itself mean "this is the
    translator, not the author": the author is the first person carrying dates,
    falling back to the first person named at all, and a translator is only
    reported when the name actually differs.
    """
    people = [p for p in CREATOR_SPLIT.split(creators.strip()) if p.strip()]
    parsed = []

    for person in people:
        roles = {m.group(1).lower() for m in CREATOR_ROLE.finditer(person)}
        name = re.sub(r"\s*\([^)]*\)", " ", person).strip().rstrip(",").strip()
        if not name:
            continue
        # CCEL writes names surname-first.
        if "," in name:
            surname, _, rest = name.partition(",")
            name = f"{rest.strip()} {surname.strip()}".strip()
        span = CREATOR_DATES.search(person)
        parsed.append({
            "name": re.sub(r"\s+", " ", name),
            "roles": roles,
            "dates": f"{span.group(1)}-{span.group(2)}" if span else None,
        })

    if not parsed:
        return None, None, None

    author = next((p for p in parsed if p["dates"]), None)
    author = author or next((p for p in parsed if not p["roles"]), parsed[0])
    translator = next(
        (p["name"] for p in parsed
         if "translator" in p["roles"] and p["name"] != author["name"]),
        None,
    )
    return author["name"], translator, author["dates"]


def path_for(entry):
    author_slug, work_id, _, _ = entry
    return CACHE / f"{author_slug}__{work_id}.txt"


def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    pending = [e for e in WORKS if not path_for(e).exists()]
    print(f"{len(WORKS)} works, {len(pending)} to fetch "
          f"({len(WORKS) - len(pending)} cached)\n")

    for i, entry in enumerate(pending, 1):
        author_slug, work_id, _, _ = entry
        path = path_for(entry)
        url = (f"https://www.ccel.org/ccel/{author_slug}/{work_id}"
               f"/cache/{work_id}.txt")
        result = subprocess.run(
            ["curl", "-fsSL", "--max-time", "300", "-A", USER_AGENT, url,
             "-o", str(path)],
            capture_output=True,
        )
        if result.returncode != 0:
            path.unlink(missing_ok=True)
            print(f"  [{i}/{len(pending)}] FAILED  {author_slug}/{work_id} "
                  f"(curl exit {result.returncode})", file=sys.stderr)
        else:
            print(f"  [{i}/{len(pending)}] ok      {author_slug}/{work_id:<22} "
                  f"{path.stat().st_size:>10,} bytes", flush=True)
        time.sleep(DELAY_SECONDS)


def parse():
    records, skipped = [], []

    for entry in WORKS:
        path = path_for(entry)
        if not path.exists():
            skipped.append((entry, "not fetched"))
            continue
        text = path.read_bytes().decode("utf-8", errors="replace")
        record, why = parse_work(entry, text)
        if record is None:
            skipped.append((entry, why))
            continue
        records.append(record)

    records.sort(key=lambda r: (r["tradition"], r["author"] or "", r["title"]))

    by_tradition = {}
    for record in records:
        chars = sum(len(u["content"]) for u in record["units"])
        count, total, units = by_tradition.get(record["tradition"], (0, 0, 0))
        by_tradition[record["tradition"]] = (count + 1, total + chars,
                                             units + len(record["units"]))

    for tradition, (count, chars, units) in sorted(by_tradition.items()):
        print(f"  {tradition:<18} {count:>4} works  {units:>7,} units  "
              f"{chars/1e6:>7.2f} M chars")

    total_units = sum(len(r["units"]) for r in records)
    total_chars = sum(len(u["content"]) for r in records for u in r["units"])
    print(f"\n  {'TOTAL':<18} {len(records):>4} works  {total_units:>7,} units  "
          f"{total_chars/1e6:>7.2f} M chars")

    if skipped:
        print(f"\n{len(skipped)} works not ingested:")
        for (author_slug, work_id, _, _), why in skipped:
            print(f"    {author_slug}/{work_id:<24} {why}")

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
