#!/usr/bin/env python3
"""Ingest Spurgeon's *Treasury of David*, which CCEL has only as page images.

The Treasury is Spurgeon's commentary on the whole Psalter — twenty years of
work, and the largest single thing he wrote. `ingest_reformation.py` refused all
six volumes CCEL lists, and rightly: CCEL serves them as scans, so each "text"
export is about fifty kilobytes of `Image of page 73` wrapped around four
thousand words of front matter. It clears every floor expressed in characters
while containing none of the commentary, which is why that ingester grew a gate
measuring placeholders per thousand characters.

So the text comes from elsewhere. Ted Hildebrandt's 2007 digitisation, hosted by
Gordon College's Biblical eLearning, is a genuine text layer rather than OCR —
six PDFs covering all hundred and fifty psalms, drawn with permission from Phil
Johnson's Spurgeon Archive transcription.

**Sources considered and rejected.** sacred-texts.com carries the whole work in
clean per-psalm HTML, and is not used: its robots.txt sets
`Content-Signal: ai-train=no, use=reference`, which is an express reservation
against exactly this, and the site is behind a challenge that would have to be
worked around to read at all. Either one alone is a reason to go elsewhere.
An anonymous HTML transcription on archive.org
(`TheTreasuryOfDavidByCharlesH.Spurgeon`) is complete in structure but not in
content: it is missing psalms 4, 10, 11, 17-20, 22-24 and the whole of 119 —
a hundred and thirty-nine of a hundred and fifty, absent the two psalms most
likely to be looked up.

**Corroboration.** Same standard as `ingest_orthodox.py` and `ingest_owen.py`:
a transcription is only as good as the printing it can be matched to, so every
psalm is scored by word-pair containment against archive.org's scans of the
1868-85 Passmore & Alabaster volumes, and a psalm that cannot be matched is
refused. The negative control is deliberately the hardest one available —
Calvin's *Commentary on the Psalms*, which is the same genre expounding the
same verses of the same book, and which therefore shares far more vocabulary
with the Treasury than any unrelated text would. A measure that can separate
those two is measuring the text and not the subject.

**How the units are cut.** By Spurgeon's own divisions, which he keeps for every
psalm: the exposition, the collected "explanatory notes and quaint sayings", and
the preacher's hints. The psalm each page belongs to is read off the running
head rather than from a heading, because the headings are not uniform — psalm
119 alone runs to a hundred and seventy-two sub-sections under a different
vocabulary, being a volume of the original in its own right — whereas every page
of every book carries its psalm number at the top.

The bibliographies ("WORKS UPON THE FORTIETH PSALM") are dropped. They are lists
of Victorian book titles, and they retrieve as text while saying nothing, which
is the same defect as a scripture index standing in for a commentary.

    python3 tools/ingest_treasury.py fetch
    python3 tools/ingest_treasury.py parse
"""

import argparse
import json
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ingest_reformation as reformation  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "treasury"
UNITS = ROOT / "tools" / "data" / "treasury_units.json"

USER_AGENT = reformation.USER_AGENT
DELAY_SECONDS = 2.0

BASE = "https://biblicalelearning.org/wp-content/uploads/2020/10"

# Hildebrandt's six files, and the psalms each covers. The ranges are the file
# names' own claim; `parse` checks them against the running heads it actually
# finds and refuses a book that does not deliver what it says.
BOOKS = [
    ("Bk1-ch1-41", 1, 41),
    ("Bk2-ch42-72", 42, 72),
    ("Bk3-ch73-89", 73, 89),
    ("Bk4-ch90-106", 90, 106),
    ("Bk5a-ch107-119", 107, 119),
    ("Bk5b-ch120-150", 120, 150),
]

# Scans of the Victorian printings, pinned by archive.org identifier so a re-run
# scores against the same images and not whichever copies search returns today.
#
# A flat list, not a volume-numbered map, and that is the point. The Treasury
# was reissued repeatedly and **the printings do not divide it the same way**:
# the 1882 second volume stops at psalm 52 while the 1881 third volume starts at
# 58, so pinning one of each leaves psalms 53-57 in no volume at all — which is
# exactly what happened, and read as five uncorroborated psalms rather than as a
# hole in the witness. Numbering the pins by volume was what made that look like
# a fact about the text. So the volume number is dropped, more scans than
# strictly needed are kept, and `parse` reports the coverage it actually found.
#
# Overlap costs nothing here: each psalm takes its *best* scan rather than a
# union of all of them, so an extra witness can only close a gap, never make the
# measure more permissive.
SCANS = [
    "treasuryofdavid0001chsp_d1s7",   # 1882, from psalm 1
    "treasuryofdavidc0002spur",       # 1882, through psalm 52
    "treasuryofdavid02spuruoft",      # 1881, through psalm 57 — closes the gap
    "treasuryofdavid0003chsp_p3x5",   # 1872, from psalm 53 — closes it the other way
    "thetreasuryofdav03spuruoft",     # 1881, from psalm 58
    "treasuryofdavid04spuruoft",      # 1881
    "treasuryofdavidc0005spur",       # 1882
    "treasuryofdavidc0006spur",       # 1882, psalm 119
    "treasuryofdavidc0007spur",       # 1882, to psalm 150
]

# Calvin on the Psalms: the same genre, expounding the same verses of the same
# book of the Bible, quoting the same text. Nothing else available is a harder
# case, which is what makes it worth measuring — a threshold that clears this
# is not riding on shared subject matter.
NEGATIVE_CONTROL = reformation.CACHE / "calvin__calcom08.txt"
MAX_CONTROL_CONTAINMENT = 0.55

MIN_PSALM_CONTAINMENT = 0.70
MIN_MEDIAN_CONTAINMENT = 0.85

MIN_UNIT_CHARS = 200
MAX_UNIT_CHARS = reformation.MAX_UNIT_CHARS

# --- structure ---------------------------------------------------------------

RUNNING_HEAD = re.compile(r"^Psalm\s+(\d+)\s*$")
PAGE_NUMBER = re.compile(r"^\d+\s*$")

# Spurgeon's divisions. The full vocabulary, taken from every standalone
# capitalised line in the six books rather than assumed: psalm 119 heads its
# homiletic section differently from the other hundred and forty-nine.
SECTIONS = {
    "EXPOSITION": "Exposition",
    "EXPLANATORY NOTES AND QUAINT SAYINGS": "Explanatory Notes and Quaint Sayings",
    "HINTS TO THE VILLAGE PREACHER": "Hints to the Village Preacher",
    "HINTS FOR PASTORS AND LAYPERSONS": "Hints for Pastors and Laypersons",
    "NOTES RELATING TO THE PSALM AS A WHOLE": "Notes on the Psalm as a Whole",
    "PSALM 119 OVERVIEW": "Overview",
}
BIBLIOGRAPHY = re.compile(r"^WORKS?\s+UPON\s+THE\b.*PSALM\s*$")

# The verse markers Spurgeon hangs everything on; also the paragraph boundaries,
# since the extracted text is hard-wrapped and carries no blank lines inside a
# section.
VERSE = re.compile(r"^Verses?\s+\d+")

# The four in-page navigation lines the transcription carries under each psalm
# heading. They are links in the original and a list of section names here.
NAVIGATION = {
    "Exposition", "Explanatory Notes and Quaint Sayings",
    "Hints to the Village Preacher", "Hints for Pastors and Laypersons",
    "Other Works", "Works upon this Psalm",
}


def strip_page(page):
    """Drop the running head and page number, and nothing else.

    Deliberately not a loop over "anything that looks like furniture": a psalm's
    opening page carries the running head *and* then the heading proper, both
    reading `Psalm 119`, so a greedy strip swallows the heading and every psalm
    in the book goes undetected.
    """
    lines = page.split("\n")
    i = 0
    while i < len(lines) and not lines[i].strip():
        i += 1
    if i < len(lines) and RUNNING_HEAD.match(lines[i].strip()):
        i += 1
        while i < len(lines) and not lines[i].strip():
            i += 1
    if not (i < len(lines) and PAGE_NUMBER.match(lines[i].strip())):
        return page  # not the expected furniture — leave the page as it is
    i += 1
    while i < len(lines) and not lines[i].strip():
        i += 1
    return "\n".join(lines[i:])


def pages_by_psalm(text):
    """Attribute every page to a psalm using its running head.

    The running head is the one structural feature this document has that is
    both uniform and unambiguous. Headings are not: psalm 119 opens with a
    preface instead of the usual navigation block, so keying on headings loses
    the longest psalm in the Psalter — which is a whole volume of the original.
    """
    grouped, current = {}, None
    for page in text.split("\x0c"):
        head = None
        for line in page.split("\n"):
            if line.strip():
                match = RUNNING_HEAD.match(line.strip())
                head = int(match.group(1)) if match else None
                break
        if head is not None:
            current = head
        if current is None:
            continue  # front matter, ahead of the first psalm
        grouped.setdefault(current, []).append(strip_page(page))
    return {psalm: "\n".join(parts) for psalm, parts in grouped.items()}


def flow(lines):
    """Join hard-wrapped lines into paragraphs, breaking at verse markers."""
    paragraphs, current = [], []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            if current:
                paragraphs.append(" ".join(current))
                current = []
            continue
        if VERSE.match(stripped) and current:
            paragraphs.append(" ".join(current))
            current = []
        current.append(stripped)
    if current:
        paragraphs.append(" ".join(current))
    return "\n\n".join(p for p in paragraphs if len(p) > 1).strip()


def sections_of(text):
    """Cut one psalm into its named divisions, in order.

    Returns a list of `(label, body)`. Everything ahead of the first division —
    the psalm's title, subject and division notes — is kept under its own label,
    because that is where Spurgeon states what the psalm is about.
    """
    out, label, buffer = [], None, []

    def flush():
        body = flow(buffer)
        if body:
            out.append((label or "Title and Division", body))

    skip_bibliography = False
    for line in text.split("\n"):
        stripped = line.strip()
        if stripped in SECTIONS:
            flush()
            label, buffer, skip_bibliography = SECTIONS[stripped], [], False
            continue
        if BIBLIOGRAPHY.match(stripped):
            flush()
            label, buffer, skip_bibliography = None, [], True
            continue
        if skip_bibliography:
            continue
        # The navigation block under a psalm heading, and the heading itself.
        if stripped in NAVIGATION or RUNNING_HEAD.match(stripped):
            continue
        buffer.append(line)
    flush()
    return out


def units_for(psalm, text):
    """Every unit for one psalm, already split to a readable size.

    Titles carry the verse where Spurgeon's section opens on one. Most do, but
    not all: psalm 119 is expounded twice over, once verse by verse and once for
    each of its twenty-two eight-verse stanzas, and the stanza pieces begin "In
    this ninth section the verses all begin with the letter Teth" rather than
    with a verse marker. Left alone they collapse to twenty identical "Psalm 119
    — Exposition" titles, and a unit that cannot be told from nineteen others
    cannot be cited, bookmarked or usefully retrieved. So a repeated title gets
    an ordinal — accurate about what is known, rather than inventing a verse
    number the text does not give.
    """
    units, seen = [], {}
    for label, body in sections_of(text):
        if len(body) < MIN_UNIT_CHARS:
            continue
        verse = VERSE.match(body)
        number = re.search(r"\d+", verse.group(0)).group(0) if verse else None
        reference = f"Psalm {psalm}" + (f":{number}" if number else "")
        title = f"{reference} — {label}"
        seen[title] = seen.get(title, 0) + 1
        if seen[title] > 1:
            title = f"{title} ({seen[title]})"
        units.append({
            "number": len(units) + 1,
            "title": title[:200],
            "content": body,
        })
    return reformation.split_oversized(units)


# --- corroboration -----------------------------------------------------------

WORDS = re.compile(r"[a-z']+")


def bigrams(text):
    tokens = WORDS.findall(text.lower())
    return {f"{a} {b}" for a, b in zip(tokens, tokens[1:])}


def scan_path(identifier):
    return CACHE / f"scan-{identifier}.txt"


def score_against_scans(targets):
    """`{name: (best_score, best_scan)}` over the pinned printings."""
    missing = [s for s in SCANS if not scan_path(s).exists()]
    if missing:
        sys.exit(f"scans {missing} not fetched — run `fetch` first")

    best = {name: (0.0, None) for name in targets}
    for identifier in SCANS:
        pairs = bigrams(
            scan_path(identifier).read_bytes().decode("utf-8", errors="replace"))
        for name, target in targets.items():
            if not target:
                continue
            score = len(target & pairs) / len(target)
            if score > best[name][0]:
                best[name] = (score, identifier)
        print(f"  {identifier:<32} {len(pairs):>8,} word pairs", flush=True)
    return best


# --- commands ----------------------------------------------------------------


def book_text_path(name):
    return CACHE / f"{name}.txt"


def fetch():
    if not shutil.which("pdftotext"):
        sys.exit("pdftotext not found — install poppler (`brew install poppler`)")
    CACHE.mkdir(parents=True, exist_ok=True)

    for name, _, _ in BOOKS:
        text_path = book_text_path(name)
        if text_path.exists():
            print(f"  cached   {name}")
            continue
        pdf_path = CACHE / f"{name}.pdf"
        url = f"{BASE}/Spurgeon-Treasury-{name}.pdf"
        result = subprocess.run(
            ["curl", "-fsSL", "--max-time", "300", "-A", USER_AGENT, url,
             "-o", str(pdf_path)],
            capture_output=True)
        if result.returncode != 0:
            pdf_path.unlink(missing_ok=True)
            print(f"  FAILED   {name}: curl exit {result.returncode}",
                  file=sys.stderr)
            continue
        subprocess.run(["pdftotext", "-enc", "UTF-8", str(pdf_path),
                        str(text_path)], check=True)
        print(f"  ok       {name:<18} {pdf_path.stat().st_size:>10,} bytes pdf "
              f"-> {text_path.stat().st_size:>10,} chars", flush=True)
        time.sleep(DELAY_SECONDS)

    for identifier in SCANS:
        path = scan_path(identifier)
        if path.exists():
            print(f"  cached   {identifier}")
            continue
        url = f"https://archive.org/download/{identifier}/{identifier}_djvu.txt"
        result = subprocess.run(
            ["curl", "-fsSL", "--max-time", "300", "-A", USER_AGENT, url,
             "-o", str(path)],
            capture_output=True)
        if result.returncode != 0:
            path.unlink(missing_ok=True)
            print(f"  FAILED   {identifier}: curl exit {result.returncode}",
                  file=sys.stderr)
        else:
            print(f"  ok       {identifier:<32} "
                  f"{path.stat().st_size:>10,} bytes", flush=True)
        time.sleep(DELAY_SECONDS)


def parse():
    psalms, records = {}, []
    for name, first, last in BOOKS:
        path = book_text_path(name)
        if not path.exists():
            sys.exit(f"{name} not fetched — run `fetch` first")
        text = path.read_bytes().decode("utf-8", errors="replace")
        found = pages_by_psalm(text)
        expected = set(range(first, last + 1))
        if not expected <= set(found):
            sys.exit(f"{name} claims psalms {first}-{last} but has no text for "
                     f"{sorted(expected - set(found))}. Refusing to ingest.")
        for psalm in sorted(expected):
            psalms[psalm] = (name, found[psalm])

    absent = [p for p in range(1, 151) if p not in psalms]
    if absent:
        sys.exit(f"no text for psalms {absent} — the Psalter is incomplete. "
                 f"Refusing to ingest.")

    by_psalm = {psalm: units_for(psalm, text)
                for psalm, (_, text) in psalms.items()}

    targets = {psalm: bigrams("\n".join(u["content"] for u in units))
               for psalm, units in by_psalm.items()}
    control_text = "".join(re.split(
        r"_{20,}",
        NEGATIVE_CONTROL.read_bytes().decode("utf-8", errors="replace"))[3:])
    targets[CONTROL_KEY] = bigrams(control_text)

    print(f"Scoring 150 psalms against {len(SCANS)} pinned printings:")
    scored = score_against_scans(targets)
    control, control_volume = scored.pop(CONTROL_KEY)
    print(f"\nNegative control — Calvin on the Psalms, same book and genre: "
          f"{control:.1%} (volume {control_volume})")
    if control >= MAX_CONTROL_CONTAINMENT:
        sys.exit(f"the control scores {control:.1%}, at or above "
                 f"{MAX_CONTROL_CONTAINMENT:.0%} — the measure is no longer "
                 f"telling Spurgeon on a psalm from anyone else on the same "
                 f"psalm. Refusing to ingest.")
    print(f"  below {MAX_CONTROL_CONTAINMENT:.0%} — the measure discriminates\n")

    weak = {p: s for p, (s, _) in scored.items() if s < MIN_PSALM_CONTAINMENT}
    if weak:
        worst = sorted(weak.items(), key=lambda kv: kv[1])[:8]
        sys.exit("these psalms are not corroborated by any printed volume: "
                 + ", ".join(f"{p} ({s:.0%})" for p, s in worst)
                 + ". Refusing to ingest.")

    median = statistics.median(s for s, _ in scored.values())
    if median < MIN_MEDIAN_CONTAINMENT:
        sys.exit(f"median containment {median:.0%} is below "
                 f"{MIN_MEDIAN_CONTAINMENT:.0%} — the transcription and the "
                 f"printing are not the same document. Refusing to ingest.")

    mapping = {}
    for psalm, (_, identifier) in scored.items():
        mapping.setdefault(identifier, []).append(psalm)
    print("Which printing each psalm matched:")
    for identifier in SCANS:
        got = sorted(mapping.get(identifier, []))
        if not got:
            print(f"  {identifier:<32} matched nothing — redundant witness")
            continue
        print(f"  {identifier:<32} psalms {got[0]}-{got[-1]}  ({len(got)})")

    for name, first, last in BOOKS:
        units = []
        for psalm in range(first, last + 1):
            units.extend(by_psalm[psalm])
        for i, unit in enumerate(units, 1):
            unit["number"] = i
        span = [scored[p][0] for p in range(first, last + 1)]
        witnesses = sorted({scored[p][1] for p in range(first, last + 1)})
        records.append({
            "title": f"The Treasury of David — Psalms {first}-{last}",
            # The corpus's spelling of his name, not the title page's. Unlike
            # the CCEL ingesters this record has no header to quote, and the
            # author string is what the pack builder files a work by: spelled
            # any other way, the Treasury misses the Spurgeon fragment and
            # falls through into the Baptist tradition's.
            "author": "Charles Haddon Spurgeon",
            "date": "1834-1892",
            "tradition": "Baptist",
            "kind": "Commentary",
            "url": f"{BASE}/Spurgeon-Treasury-{name}.pdf",
            "rights": (
                f"Public domain in the US: written in English by an author who "
                f"died in 1892, and published 1869-85, well before the 1929 "
                f"cutoff. The text is that of the Victorian printing — "
                f"{statistics.median(span):.0%} of the word pairs in these "
                f"psalms occur in archive.org's scans of it"),
            "collection": (
                f"Digitised by Ted Hildebrandt, 2007, for Gordon College "
                f"Biblical eLearning, from the Spurgeon Archive transcription "
                f"| Corroborated against archive.org "
                f"{', '.join(witnesses)}"),
            "notes": (
                "Spurgeon's bibliographies of works upon each psalm are not "
                "included; they are lists of Victorian book titles rather than "
                "commentary."),
            "units": units,
        })
        chars = sum(len(u["content"]) for u in units)
        print(f"\n  Psalms {first:>3}-{last:<3} {len(units):>6,} units  "
              f"{chars/1e6:>5.2f} M chars  "
              f"containment {min(span):.0%}-{max(span):.0%} "
              f"(median {statistics.median(span):.0%})")

    total_units = sum(len(r["units"]) for r in records)
    total_chars = sum(len(u["content"]) for r in records for u in r["units"])
    print(f"\n  {len(records)} records  {total_units:,} units  "
          f"{total_chars/1e6:.2f} M chars  median containment {median:.0%}")

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    UNITS.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
    print(f"\n-> {UNITS}")


CONTROL_KEY = -1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()
    {"fetch": fetch, "parse": parse}[args.command]()


if __name__ == "__main__":
    main()
