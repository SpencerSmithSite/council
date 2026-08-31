#!/usr/bin/env python3
"""Ingest scanned public-domain works from archive.org, corroborated.

The Pentecostal family is why this exists. It is the second-largest Christian
movement in the world, `README.md` used to tell readers its documents were all
in copyright, and the copyright audit of 2026-08-30 established that they are
not — the confessional documents of several Trinitarian Pentecostal bodies were
printed before 1931. What is true is narrower and harder: **none of them is
transcribed anywhere.** archive.org has them only as scans and raw OCR, and this
corpus refuses raw OCR, for the reason `ingest_gutenberg.py` records — about one
error per hundred characters, in an app whose whole purpose is quoting a source
accurately.

So this module does not trust OCR. It measures it.

**Two witnesses, where two printings exist.** The Pentecostal Holiness Church
printed its Basis of Union in the *Constitution and General Rules* of 1913 and
again in the *Discipline* of 1917. Two separate printings, digitised separately
by different scanning stations. Where the two agree, the text is established;
where they differ, at least one is wrong and the disagreement can be read.
Measured on that pair: 94% word agreement, and **every disagreement is the 1913
scan being wrong** — "there generation" for "the regeneration", "tlie" for
"the", "ivord" for "Lord", "chr st" for "Christ", "sm" for "sin". The 1917 scan
is the one ingested, and the 1913 is kept as the witness that proves it.

This is the same standard `ingest_owen.py` set — a text may stand in for a
printing when it can be shown to *be* that printing — applied to a case where
neither witness is a clean transcription and the corroboration runs scan against
scan.

**Where no second printing exists**, as for the Church of God's *Book of
Doctrines* of 1922, the work is admitted only on a measured artefact rate. The
two scanner failures that dominate this material are countable because both
produce non-words: a capital L read as "Iv"/"ly", and "th" read as "tli"/"tb".
The 1922 book scores 3.6 per 10,000 words, which is the same order as the
proofread Wikisource material this corpus already holds; the 1913 Constitution
scores 47.4 and is refused as a source on exactly that basis.

    python3 tools/ingest_archive.py survey   # access, size, artefact rate
    python3 tools/ingest_archive.py fetch
    python3 tools/ingest_archive.py parse
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import ingest_reformation as ccel  # noqa: E402

CACHE = ROOT / ".cache" / "archive"
UNITS = ROOT / "tools" / "data" / "archive_units.json"

USER_AGENT = ("council-corpus/1.0 (offline theology corpus; "
              "https://github.com/SpencerSmithSite/council)")
DELAY_SECONDS = 2.0

MIN_UNIT_CHARS = 200
MAX_UNIT_CHARS = 9000
MIN_WORK_CHARS = 4000

# The two scanner failures that dominate this material, both of which produce
# non-words and are therefore countable rather than guessable: a capital L read
# as "Iv" or "ly" ("Ivord" for Lord, "Ivuke" for Luke), and "th" read as "tli"
# or "tb" ("tlie" for the, "witli" for with).
ARTEFACTS = re.compile(
    r"\b(?:(?:Iv|lv|ly)[a-z]{2,}|tlie|tbe|tliat|tbat|witli|liave|liis|sucli|"
    r"tliey|tliis|wliich|wlien)\b")

# Ten times the rate of the cleanest scan measured here, and an order of
# magnitude below the raw OCR this project already refuses. A work above this
# is a scan nobody has checked, not a transcription with slips in it.
MAX_ARTEFACTS_PER_10K = 20.0

# Agreement below this means the two witnesses are not the same text — a
# different edition, or the wrong book — rather than the same text scanned
# twice. The measured pair sits at 94%.
MIN_WITNESS_AGREEMENT = 0.85

WORKS = [
    {
        "id": "phc-discipline-1917",
        "identifier": "disciplineofpent00nort",
        "witness": "constitutiongene00nort",
        # Only Section I is shared between the two printings: the 1913
        # Constitution and the 1917 Discipline are different documents that
        # both carry the same Basis of Union. Comparing the volumes whole
        # scores 52% and means nothing — it measures how much of the governance
        # differs, not whether the doctrine is transcribed correctly. The
        # corroboration is therefore scoped to the passage both actually print,
        # and the note on the source says which passage that is.
        "witness_section": ("Basis of Union", "SECTION II"),
        "title": "The Discipline of the Pentecostal Holiness Church",
        "author": None,
        "date": "1917",
        "tradition": "Pentecostal",
        "kind": "Confession",
        "start": "Basis of Union",
        "chapters": None,     # its own "SECTION N." headings are enough
        "collection": ("Discipline of the Pentecostal Holiness Church (1917), "
                       "digitised by Duke University for the Religion in North "
                       "Carolina project"),
        "notes": (
            "Section I is the Basis of Union — ten articles stating "
            "justification by faith, entire sanctification as an "
            "instantaneous second work of grace, the Pentecostal baptism of "
            "the Holy Ghost with speaking in tongues as its initial evidence, "
            "divine healing in the atonement, and the premillennial second "
            "coming. The doctrinal core of a body now known as the "
            "International Pentecostal Holiness Church. The text is "
            "corroborated word by word against the same articles as printed "
            "in the Constitution and General Rules of 1913 and scanned "
            "separately; the two agree on 94% of words and every disagreement "
            "is an error in the 1913 scan."),
    },
    {
        "id": "cog-doctrines-1922",
        "identifier": "bookofdoctrinesi00chur",
        "witness": None,
        "witness_section": None,
        "title": "The Book of Doctrines",
        "author": None,
        "date": "1922",
        "tradition": "Pentecostal",
        "kind": "Treatise",
        "start": "The Bible Is Truth",
        # The book's own table of contents, which is the only statement of its
        # structure that exists: `ingest_reformation.is_headingish` was tuned
        # on CCEL's "CHAPTER I" style and returns False for "Sanctification",
        # "Repentance" and "Feet Washing" alike, so without this the volume was
        # cut at arbitrary points and forty-three units carried titles like
        # "THE BOOK OP GENESIS (5 of 8)" over text that is not about Genesis.
        "chapters": [
            "The Bible Is Truth", "All Are Sinners", "Repentance",
            "Justification", "Sanctification", "The Baptism with the Holy Ghost",
            "Baptism in Water", "The Lord's Supper", "Feet Washing",
            "Tithing and Giving", "Healing of the Body",
            "The Name of the Church of God", "The Organization of the Church of God",
            "The Officers of the Church of God", "Women Speaking in the Church",
            "Speaking in Tongues in the Church", "The Covering of the Woman",
            "Abstinence from Alcoholic Drink", "Meats and Drinks",
            "The Sabbath Day", "Ornaments and Decorations",
        ],
        "collection": ("The Book of Doctrines, issued in the interest of the "
                       "Church of God (Cleveland, Tennessee, 1922)"),
        "notes": (
            "The doctrinal manual of the Church of God (Cleveland), one of the "
            "oldest Pentecostal denominations: the Bible, sin, repentance, "
            "justification, sanctification, the baptism with the Holy Ghost, "
            "water baptism, the Lord's Supper, feet washing, tithing, healing "
            "of the body, and the church practices — speaking in tongues in "
            "the church, the covering of the woman, the Sabbath day. There is "
            "no second printing to corroborate this against, so it is admitted "
            "on its measured scanner-artefact rate alone."),
    },
]


# --- the archive -------------------------------------------------------------

def curl(url, out=None):
    args = ["curl", "-fsSL", "--max-time", "300", "-A", USER_AGENT, url]
    if out:
        args += ["-o", str(out)]
    result = subprocess.run(args, capture_output=True)
    time.sleep(DELAY_SECONDS)
    return result.stdout if result.returncode == 0 else None


def metadata(identifier):
    raw = curl(f"https://archive.org/metadata/{identifier}")
    if not raw:
        return None
    try:
        return json.loads(raw.decode("utf-8", errors="replace"))
    except ValueError:
        return None


def usable(identifier):
    """(ok, why). An item on archive.org is not necessarily readable.

    Much of what the site holds from the last century is lending-only: the scan
    exists, the catalogue entry is public, and the text cannot be downloaded.
    That is flagged as `access-restricted-item`, and it has to be checked rather
    than inferred from the item being findable.
    """
    data = metadata(identifier)
    if data is None:
        return False, "no metadata"
    fields = data.get("metadata", {})
    if str(fields.get("access-restricted-item", "")).lower() == "true":
        return False, "lending only — the text cannot be downloaded"
    if not any(f["name"].endswith("_djvu.txt") for f in data.get("files", [])):
        return False, "no OCR text file"
    return True, fields.get("date") or fields.get("year") or "?"


def path_for(identifier):
    return CACHE / f"{identifier}.txt"


# --- OCR text into paragraphs ------------------------------------------------

def readable(raw):
    """archive.org's OCR dump as paragraphs.

    Three repairs, in order. Words broken across a line by the printer's hyphen
    are rejoined; the scan's hard line wrapping inside a paragraph is collapsed,
    because a unit that wraps where a 1917 compositor wrapped reads as broken
    text; and the doubled spaces the OCR puts between words are squeezed.
    """
    text = raw.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"(\w)-\s*\n\s*([a-z])", r"\1\2", text)

    out = []
    for block in re.split(r"\n\s*\n", text):
        block = re.sub(r"\s+", " ", block).strip()
        if block:
            out.append(block)
    return out


def artefact_rate(text):
    """(per 10,000 words, count) for the two countable scanner failures."""
    words = len(re.findall(r"[A-Za-z]{3,}", text))
    hits = len(ARTEFACTS.findall(text))
    return (10000.0 * hits / words if words else 0.0), hits


def agreement(a, b):
    """Fraction of the first witness's words the second corroborates."""
    import difflib
    wa = [w.lower() for w in re.findall(r"[A-Za-z']+", a)]
    wb = [w.lower() for w in re.findall(r"[A-Za-z']+", b)]
    if not wa or not wb:
        return 0.0
    matcher = difflib.SequenceMatcher(None, wa, wb, autojunk=False)
    return sum(block.size for block in matcher.get_matching_blocks()) / len(wa)


def chapter_named(paragraph, chapters):
    """The chapter this paragraph is the heading of, spelled as the book spells it.

    Fuzzy, for the same reason the running-head filter is: a heading is OCR'd
    like everything else, and six of this book's eighteen chapter headings come
    back mangled. Returning the *declared* spelling rather than the scanned one
    also means the unit is titled "Sanctification" and not "SANCTIFICATION" or
    whatever the scanner made of it.
    """
    if not chapters or len(paragraph) > 90:
        return None
    import difflib

    def letters(text):
        return re.sub(r"[^a-z]", "", text.lower())

    scanned = letters(paragraph)
    if len(scanned) < 4:
        return None
    for chapter in chapters:
        if difflib.SequenceMatcher(None, scanned, letters(chapter)).ratio() >= 0.88:
            return chapter
    return None


def strip_running_heads(paragraphs, title):
    """Drop the printed running head that appears at the top of every page.

    A scan captures it once per leaf, so the Church of God's *Book of
    Doctrines* yielded a hundred paragraphs reading "THE BOOK OF DOCTRINES 7"
    — short, capitalised and punctuation-free, which is exactly what a heading
    detector is looking for. Left in, they became the titles of most of the
    book's units and broke a unit at every page boundary.

    Compared by similarity rather than equality, because **the running head is
    itself OCR'd afresh on every page** and comes back as "THE BOOK OF
    DOCTEINES" and "THE BOOK OP DOCTRINES" as often as correctly. An exact test
    removed two thirds of them and left the rest as unit titles.

    The threshold has to leave real headings alone, and the case that pins it is
    this book's own chapter "THE BOOK OF GENESIS" — 0.63 similar to the running
    head, against 0.94 for the misread variants.
    """
    import difflib

    def letters(text):
        return re.sub(r"[^a-z]", "", text.lower())

    head = letters(title)
    kept = []
    for paragraph in paragraphs:
        stripped = letters(paragraph)
        if len(stripped) < 3:        # a page number, or gutter noise, alone
            continue
        if len(paragraph) <= 90 and difflib.SequenceMatcher(
                None, stripped, head).ratio() >= 0.75:
            continue
        kept.append(paragraph)
    return kept


def opening_at(paragraphs, marker):
    """Where the work proper begins: title page, contents and stamps come first.

    Matched against a paragraph that *is* the marker, not one that merely
    contains it, because the phrase appears twice — once in the table of
    contents and once as the chapter heading. The contents entry carries its
    page number ("The Bible Is Truth 5") and the heading does not, so the whole
    -paragraph test separates them. Taking the first containing match instead
    made the Church of God's *Book of Doctrines* open on its own contents page,
    which is the defect `audit_completeness.py` exists to catch.
    """
    wanted = re.sub(r"\s+", " ", marker).strip().lower()
    for i, paragraph in enumerate(paragraphs):
        if re.sub(r"\s+", " ", paragraph).strip().lower() == wanted:
            return i
    for i, paragraph in enumerate(paragraphs):
        if wanted in paragraph.lower():
            return i
    return 0


def section_of(text, start_at, end_at):
    """The passage between two printed markers, for a scoped corroboration."""
    lowered = text.lower()
    i = lowered.find(start_at.lower())
    if i < 0:
        return ""
    j = lowered.find(end_at.lower(), i + len(start_at))
    return text[i:j if j > 0 else min(len(text), i + 12000)]


def units_from(paragraphs, chapters=None):
    """Cut paragraphs into display-sized units on the prose's own headings.

    These scans carry no markup at all, so the only structure available is what
    the printing states in words — "SECTION I.", "Basis of Union." — which is
    the judgement `ingest_reformation.is_headingish` already encodes.
    """
    units, heading, body = [], None, []

    def emit():
        units.append({
            "number": len(units) + 1,
            "title": (heading or f"Section {len(units) + 1}")[:200],
            "content": "\n\n".join(body).strip(),
        })

    for paragraph in paragraphs:
        declared = chapter_named(paragraph, chapters)
        # `>= 3` because the OCR leaves stray single capitals between pages,
        # and one of them became a unit titled "G".
        if declared or (3 <= len(paragraph) <= 90
                        and ccel.is_headingish(paragraph)):
            paragraph = declared or paragraph
            if sum(len(x) for x in body) >= MIN_UNIT_CHARS:
                emit()
                body, heading = [], paragraph
            elif not body:
                heading = f"{heading} — {paragraph}"[:200] if heading else paragraph
            else:
                body.append(paragraph)
            continue
        body.append(paragraph)

    if sum(len(x) for x in body) >= MIN_UNIT_CHARS:
        emit()
    elif body and units:
        units[-1]["content"] += "\n\n" + "\n\n".join(body)
    return ccel.split_oversized(units)


# --- commands ----------------------------------------------------------------

def wanted():
    for work in WORKS:
        yield work["identifier"]
        if work["witness"]:
            yield work["witness"]


def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    for identifier in dict.fromkeys(wanted()):
        if path_for(identifier).exists():
            print(f"  cached   {identifier}")
            continue
        ok, why = usable(identifier)
        if not ok:
            print(f"  REFUSED  {identifier}: {why}", file=sys.stderr)
            continue
        url = (f"https://archive.org/download/{identifier}/"
               f"{identifier}_djvu.txt")
        if curl(url, path_for(identifier)) is None and not path_for(identifier).exists():
            print(f"  FAILED   {identifier}", file=sys.stderr)
            continue
        print(f"  fetched  {identifier:<28} {path_for(identifier).stat().st_size:>9,} bytes"
              f"  published {why}")


def load(identifier):
    path = path_for(identifier)
    return path.read_text(encoding="utf-8", errors="replace") if path.exists() else None


def survey():
    print(f"{'identifier':<28} {'words':>8} {'artefacts':>10} {'per 10k':>8}  verdict")
    for identifier in dict.fromkeys(wanted()):
        raw = load(identifier)
        if raw is None:
            print(f"{identifier:<28} {'-':>8} {'-':>10} {'-':>8}  not fetched")
            continue
        text = "\n\n".join(readable(raw))
        rate, hits = artefact_rate(text)
        words = len(re.findall(r"[A-Za-z]{3,}", text))
        verdict = "usable" if rate <= MAX_ARTEFACTS_PER_10K else "TOO DIRTY"
        print(f"{identifier:<28} {words:>8,} {hits:>10} {rate:>8.1f}  {verdict}")


def parse():
    records, skipped = [], []

    for work in WORKS:
        raw = load(work["identifier"])
        if raw is None:
            skipped.append((work["identifier"], "not fetched"))
            continue

        paragraphs = readable(raw)
        paragraphs = paragraphs[opening_at(paragraphs, work["start"]):]
        paragraphs = strip_running_heads(paragraphs, work["title"])
        text = "\n\n".join(paragraphs)

        rate, hits = artefact_rate(text)
        if rate > MAX_ARTEFACTS_PER_10K:
            skipped.append((work["identifier"],
                            f"{rate:.1f} scanner artefacts per 10k words"))
            continue

        corroboration = None
        if work["witness"]:
            witness = load(work["witness"])
            if witness is None:
                skipped.append((work["identifier"], "witness not fetched"))
                continue
            start_at, end_at = work["witness_section"]
            here = section_of(text, start_at, end_at)
            there = section_of("\n\n".join(readable(witness)), start_at, end_at)
            if not here or not there:
                skipped.append((work["identifier"],
                                f"cannot locate {start_at!r} in both printings"))
                continue
            score = agreement(here, there)
            if score < MIN_WITNESS_AGREEMENT:
                skipped.append((work["identifier"],
                                f"the two printings of {start_at!r} agree on "
                                f"only {100*score:.0f}% — not the same text"))
                continue
            corroboration = (
                f"{start_at} corroborated word by word against the same "
                f"passage in a separate printing scanned separately "
                f"({work['witness']}): {100*score:.0f}% agreement. The rest of "
                f"the volume has no second printing to check against")

        units = units_from(paragraphs, work.get("chapters"))
        chars = sum(len(u["content"]) for u in units)
        if chars < MIN_WORK_CHARS:
            skipped.append((work["identifier"], f"only {chars:,} characters"))
            continue

        records.append({
            "title": work["title"],
            "author": work["author"],
            "date": work["date"],
            "tradition": work["tradition"],
            "kind": work["kind"],
            "url": f"https://archive.org/details/{work['identifier']}",
            "rights": (f"Published {work['date']}, before the "
                       f"{ccel.PD_CUTOFF} cutoff; public domain in the US"),
            "collection": work["collection"],
            "notes": " | ".join(x for x in (
                work["notes"], corroboration,
                f"Scanner artefacts measured at {rate:.1f} per 10,000 words "
                f"({hits} found)",
            ) if x),
            "units": units,
        })

    records.sort(key=lambda r: (r["tradition"], r["date"]))
    for record in records:
        chars = sum(len(u["content"]) for u in record["units"])
        print(f"  {record['tradition']:<13} {record['title'][:46]:<48} "
              f"{len(record['units']):>4} units {chars/1000:>8.1f} K  {record['date']}")
    print(f"\n  {len(records)} works, "
          f"{sum(len(r['units']) for r in records):,} units, "
          f"{sum(len(u['content']) for r in records for u in r['units'])/1e6:.2f} M chars")

    if skipped:
        print(f"\n{len(skipped)} not ingested:")
        for identifier, why in skipped:
            print(f"    {identifier:<28} {why}")

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
