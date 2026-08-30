#!/usr/bin/env python3
"""Ingest the English documents from Schaff's *Creeds of Christendom*, Vol. III.

**This answers a refusal rather than relaxing it.** `ingest_ccel.py` records
Schaff as deliberately not used, and the reason it gives is correct:

    CCEL's text export linearizes Schaff's parallel Latin/English columns
    badly, running one straight into the other mid-sentence ("...colatur et
    servetur Most Invincible Emperor, Caesar Augustus...").

That is true of most of the volume and it is still true today. What the refusal
missed is that it is not true of *all* of it. Schaff sets some documents in
parallel columns and others in English alone, and the third edition adds an
appendix — an English version of the Second Helvetic Confession — that is
continuous English prose from first chapter to last. The refusal was written
about the volume and applied to every document in it.

So the gate here is a measurement, not a judgement. Every candidate document is
scored for Latin, French and German function words that have no English
homograph, as a ratio against English ones, and anything above 0.02 is refused
before it is parsed. **The two populations do not overlap.** Measured across
the documents this script considers:

    Second Helvetic (English appendix)     lat 0.000  fra 0.000  ger 0.000
    Savoy Platform of Discipline           lat 0.000  fra 0.000  ger 0.000
    Reformed Episcopal Articles            lat 0.000  fra 0.000  ger 0.000
    Piedmont (Waldensian) confession       lat 0.000  fra 0.431  ger 0.000
    Moravian Easter Litany                 lat 0.000  fra 0.021  ger 0.630
    Confessio Augustana                    lat 0.142  fra 0.054  ger 0.013
    Theses Bernenses                       lat 0.982  fra 0.759  ger 8.625

Clean English scores exactly zero on all three axes; every parallel-column
document is an order of magnitude clear of the threshold. The refused rows are
kept in `CANDIDATES` on purpose — a gate nobody can watch reject anything is a
gate nobody should trust, so `--survey` runs the scorer over the refusals too.

**What this closes.** The Second Helvetic Confession (1566) is the fullest
statement of Reformed doctrine before Westminster and is recorded in `TODO.md`
as removed as a précis and not replaced, and in `SOURCES.md` as copyright-
blocked in every English edition found — the 1966 translation is in copyright.
Schaff's third edition carries an older English version that is not. The Savoy
Declaration's Platform of Discipline is Congregationalism's constitutional
document and the corpus has held nothing of it.

    python3 tools/ingest_schaff.py fetch
    python3 tools/ingest_schaff.py survey     # score every candidate, write nothing
    python3 tools/ingest_schaff.py parse

Then load it like any other ingester's output:

    python3 tools/load_ccel.py --units tools/data/schaff_units.json --write
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "ccel"
UNITS = ROOT / "tools" / "data" / "schaff_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)

# CCEL's robots.txt sets Crawl-delay: 10 for '*'. Honour it.
DELAY_SECONDS = 10.0

WORK_ID = "creeds3"
WORK_URL = "https://www.ccel.org/ccel/schaff/creeds3/cache/creeds3.txt"

# Function words with no English homograph. "in", "sed", "non" and "cum" are
# excluded deliberately: they are ordinary English words or fragments of them,
# and including them scored the Second Helvetic — which contains no Latin at
# all — as 1.3 parts Latin.
LATIN = re.compile(
    r"\b(?:quae|quod|atque|autem|enim|igitur|nostrae|nostram|Deum|Dei|"
    r"Ecclesiae|ecclesiae|sunt|esse|etiam|neque|omnia|omnes|propter|sicut|"
    r"tamen|vero|nisi)\b"
)
FRENCH = re.compile(
    r"\b(?:nous|vous|leur|leurs|cette|cet|avec|dans|pour|est|sont|qui|que|"
    r"les|des|une|aux|ainsi|parce)\b"
)
GERMAN = re.compile(
    r"\b(?:und|nicht|dass|daß|wir|ist|der|die|das|von|zu|sich|wird|aber|"
    r"auch|einen|einer|durch)\b"
)
ENGLISH = re.compile(
    r"\b(?:the|and|of|that|which|is|are|we|God|shall|unto|his|with)\b",
    re.IGNORECASE,
)

# Clean English measures 0.000 on every axis and the nearest refusal sits at
# 0.021, so this is set an order of magnitude below the closest thing it must
# reject rather than tuned against it.
MAX_FOREIGN_RATIO = 0.02

RULE = "_" * 20

# Every document considered, taken or not. `take: False` rows are what the
# survey exists to demonstrate: they are the parallel-column documents the
# original refusal was written about, and the gate must still reject them.
CANDIDATES = [
    {
        "take": True,
        "start": "APPENDIX:\n\nTHE SECOND HELVETIC CONFESSION",
        "end": "SYMBOLA EVANGELICA.",
        "title": "The Second Helvetic Confession",
        "date": "1566",
        "tradition": "Reformed",
        "kind": "Confession",
        "author": "Heinrich Bullinger",
        "unit_re": r"^\s*CHAPTER ([IVXLC]+)\.--(.*)$",
        "heading_wraps": True,
        # Schaff omitted an English text from earlier editions of Vol. III and
        # added this one in the third; a reader comparing it against a modern
        # edition should know which they are holding.
        "notes": (
            "English version added in Schaff's third edition, based on the "
            "translation in The Harmony of Reformed Confessions (Cambridge, "
            "1586). Schaff's own bracketed editorial notes are retained; his "
            "numbered footnotes are not."
        ),
        "supersedes": ["Second Helvetic Confession"],
    },
    {
        "take": True,
        "start": "Of the Institution of Churches, and the Order appointed in them by",
        "end": "THE DECLARATION OF THE CONGREGATIONAL UNION",
        "title": "The Savoy Declaration: Platform of Discipline",
        "date": "1658",
        "tradition": "Reformed",
        "kind": "Confession",
        "unit_re": r"^\s*([IVXLC]+)\.\s",
        # Naming what is *not* here matters more than usual for this one: the
        # Savoy Declaration has three parts and Schaff prints only two of them
        # whole, giving the confession as a diff against Westminster. Calling
        # this source "The Savoy Declaration" would promise all three.
        "notes": (
            "The Platform of Discipline only. Schaff prints the Savoy "
            "Declaration's Preface and Platform in full but gives its "
            "Confession of Faith only as the chapters where it differs from "
            "the Westminster Confession, so the confession itself is not "
            "reproduced here."
        ),
    },
    {
        "take": True,
        "start": "ARTICLES OF RELIGION OF THE REFORMED EPISCOPAL CHURCH IN AMERICA",
        "end": "APPENDIX:\n\nTHE SECOND HELVETIC CONFESSION",
        "title": "Articles of Religion of the Reformed Episcopal Church",
        "date": "1875",
        "tradition": "Anglican",
        "kind": "Confession",
        "unit_re": r"^\s*ARTICLE ([IVXLC]+)\.\s*$",
        "subtitle": True,
        "notes": (
            "Schaff's text numbers two consecutive articles 'II'; the "
            "misnumbering is his edition's and is reproduced rather than "
            "silently corrected."
        ),
    },
    # ---- refused, and kept so the gate can be seen rejecting them ----
    {
        "take": False,
        "start": "BRIÈVE CONFESSION DE FOY DES ÉGLISES REFORMÉES DE PIÉMONT.",
        "end": "CUMBERLAND CONFESSION. WESTMINSTER CONFESSION.",
        "title": "A Brief Confession of Faith of the Reformed Churches of Piedmont",
        "why": "parallel French/English columns",
    },
    {
        "take": False,
        "start": "EASTER LITANY OF THE MORAVIAN CHURCH. A.D. 1749.",
        "end": "ARTICLES OF RELIGION OF THE REFORMED EPISCOPAL CHURCH IN AMERICA",
        "title": "Easter Litany of the Moravian Church",
        "why": "parallel German/English columns",
    },
    {
        "take": False,
        "start": "CONFESSIO AUGUSTANA.",
        "end": "ARTICULI IN QUIBUS",
        "title": "Confessio Augustana",
        "why": "Latin, with English interleaved by the export",
    },
    {
        "take": False,
        "start": "THESES BERNENSES. A.D. 1528.",
        "end": "CATECHISMUS GENEVENSIS, CONSENSUS TIGURINUS",
        "title": "Theses Bernenses",
        "why": "German and Latin, no English column",
    },
]

_ROMAN = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100}


def _to_int(value):
    if value.isdigit():
        return int(value)
    total = previous = 0
    for char in reversed(value.upper()):
        current = _ROMAN.get(char, 0)
        total += current if current >= previous else -current
        previous = max(previous, current)
    return total


def fetch():
    path = CACHE / f"{WORK_ID}.txt"
    if path.exists():
        print(f"  cached {WORK_ID} ({path.stat().st_size:,} bytes)")
        return
    result = subprocess.run(
        ["curl", "-fsSL", "--max-time", "180", "-A", USER_AGENT, WORK_URL],
        capture_output=True,
    )
    if result.returncode != 0:
        sys.exit(f"fetch failed: curl exit {result.returncode}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(result.stdout)
    print(f"  fetched {WORK_ID} ({path.stat().st_size:,} bytes)")
    time.sleep(DELAY_SECONDS)


def assert_public_domain(text):
    """CCEL states rights in the export header. Do not ingest without it."""
    match = re.search(r"Rights:\s*(.+)", text[:1500])
    rights = match.group(1).strip() if match else "(absent)"
    if "public domain" not in rights.lower():
        sys.exit(f"{WORK_ID}: rights are '{rights}' — refusing to ingest.")
    return rights


def foreign_ratios(segment):
    """Latin, French and German density, each against English."""
    english = max(len(ENGLISH.findall(segment)), 1)
    return (
        len(LATIN.findall(segment)) / english,
        len(FRENCH.findall(segment)) / english,
        len(GERMAN.findall(segment)) / english,
    )


def segment_for(text, candidate):
    """The document's own text, bounded by the next document's heading."""
    start = text.find(candidate["start"])
    if start < 0:
        return None
    after = text.find(candidate["end"], start + len(candidate["start"]))
    return text[start:after if after > 0 else len(text)]


def clean(block):
    """CCEL indents body text; footnote markers are bracketed numerals."""
    lines = []
    for line in block.split("\n"):
        line = line.strip()
        if not line or line.startswith(RULE):
            continue
        if re.match(r"^\[\d+\]", line):
            continue
        lines.append(line)
    text = " ".join(lines)
    text = re.sub(r"\[\d+\]", "", text)
    return re.sub(r"\s+", " ", text).strip()


def _take_heading(body, heading, candidate):
    """Lift the section's own title out of the body and onto the unit.

    Two shapes, and getting either wrong buries a heading in the prose:

    *Wrapped.* Schaff sets long chapter headings across two lines, and a regex
    anchored to one line takes half. "OF INTERPRETING THE HOLY SCRIPTURES; AND
    OF FATHERS," is followed by "COUNCILS, AND TRADITIONS." on the next line,
    and without this the second half opens the chapter text.

    *Subtitled.* The Reformed Episcopal articles carry their subject on the
    line below the number ("ARTICLE I." / "Of the Holy Trinity."), which is the
    only thing distinguishing one article from another in a list of them.
    """
    lines = body.lstrip("\n").split("\n")
    if candidate.get("heading_wraps"):
        while lines and lines[0].strip() and lines[0].strip().isupper():
            heading = f"{heading} {lines.pop(0).strip()}".strip()
    elif candidate.get("subtitle"):
        first = lines[0].strip() if lines else ""
        if first.startswith("Of ") and len(first) < 80:
            heading, lines = first, lines[1:]
    return "\n".join(lines), heading


def carve(segment, candidate):
    unit_re = re.compile(candidate["unit_re"], re.M)
    marks = list(unit_re.finditer(segment))
    units = []
    for i, mark in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(segment)
        body = segment[mark.end():end]
        # A heading captured by the second group is the document's own section
        # title; where there is none the number has to stand as the title.
        heading = (mark.group(2).strip()
                   if unit_re.groups > 1 and mark.group(2) else "")
        body, heading = _take_heading(body, heading, candidate)

        content = clean(body)
        if len(content) < 40:
            continue
        label = f"Chapter {mark.group(1)}" if "CHAPTER" in mark.group(0).upper() \
            else f"Article {mark.group(1)}"
        units.append({
            "number": _to_int(mark.group(1)),
            "title": f"{label} — {heading.rstrip('.')}" if heading else label,
            "content": content,
        })
    return units


def survey(text):
    print(f"{'document':46} {'lat':>7} {'fra':>7} {'ger':>7}   verdict")
    for candidate in CANDIDATES:
        segment = segment_for(text, candidate)
        if segment is None:
            print(f"{candidate['title'][:46]:46} {'not found in this edition':>33}")
            continue
        lat, fra, ger = foreign_ratios(segment)
        passes = max(lat, fra, ger) <= MAX_FOREIGN_RATIO
        note = "" if candidate["take"] else f"  ({candidate['why']})"
        print(f"{candidate['title'][:46]:46} {lat:>7.3f} {fra:>7.3f} {ger:>7.3f}"
              f"   {'english' if passes else 'REFUSED'}{note}")


def parse():
    path = CACHE / f"{WORK_ID}.txt"
    if not path.exists():
        sys.exit(f"missing {path} — run fetch first")
    text = path.read_text(encoding="utf-8", errors="replace")
    rights = assert_public_domain(text)

    title_match = re.search(r"Title:\s*(.+)", text[:1500])
    collection = title_match.group(1).strip() if title_match else WORK_ID

    records = []
    for candidate in CANDIDATES:
        if not candidate["take"]:
            continue
        segment = segment_for(text, candidate)
        if segment is None:
            print(f"  WARNING: {candidate['title']} not found", file=sys.stderr)
            continue

        lat, fra, ger = foreign_ratios(segment)
        if max(lat, fra, ger) > MAX_FOREIGN_RATIO:
            # Not a warning. A document that was English when this was written
            # and is not now means the edition changed under us, and guessing
            # which half to keep is how parallel columns got shipped as prose.
            sys.exit(
                f"{candidate['title']}: foreign-word ratio lat {lat:.3f} / "
                f"fra {fra:.3f} / ger {ger:.3f} exceeds {MAX_FOREIGN_RATIO} — "
                f"refusing to ingest."
            )

        units = carve(segment, candidate)
        if not units:
            print(f"  WARNING: no units for {candidate['title']}", file=sys.stderr)
            continue

        records.append({
            "title": candidate["title"],
            "date": candidate["date"],
            "tradition": candidate["tradition"],
            "kind": candidate["kind"],
            "author": candidate.get("author"),
            "url": WORK_URL,
            "rights": rights,
            "collection": collection,
            "editor": "Schaff, Philip",
            "notes": candidate["notes"],
            "supersedes": candidate.get("supersedes", []),
            "units": units,
        })
        chars = sum(len(u["content"]) for u in units)
        print(f"  {candidate['title'][:46]:<46} {len(units):>3} units  "
              f"{chars:>8,} chars")

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    UNITS.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
    print(f"\n-> {UNITS}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["fetch", "survey", "parse"])
    args = parser.parse_args()
    if args.command == "fetch":
        return fetch()
    path = CACHE / f"{WORK_ID}.txt"
    if not path.exists():
        sys.exit(f"missing {path} — run fetch first")
    text = path.read_text(encoding="utf-8", errors="replace")
    if args.command == "survey":
        return survey(text)
    return parse()


if __name__ == "__main__":
    main()
