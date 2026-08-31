#!/usr/bin/env python3
"""Ingest the Brethren from Project Gutenberg.

The last family with genuinely public-domain founding documents and nothing in
the corpus. Unlike Pentecostal, which turned out to be a digitisation problem,
this one was only ever a *search* problem: Project Gutenberg has seventeen
Brethren works as proofread transcriptions, and the earlier surveys missed them
because they queried CCEL and archive.org and asked Gutenberg for "Darby".

`ingest_gutenberg.py` already knows how to read this archive — its markers, its
licence footer, its paragraph chunking — and that code is reused rather than
rewritten. Two things are not reused, and both matter.

**A separate units file, deliberately.** `gutenberg_units.json` holds the Book
of Concord, ingested long ago at unit ids far below the last published
high-water mark. Regenerating that file and re-loading it would delete and
reinsert the Augsburg Confession at fresh ids — a *settled* source moving, which
is exactly the fault `check_id_space` exists to catch, and it would bump the id
space and force every reader to update the app for nothing. So this writes its
own file and touches nobody else's rows.

**Its own rights reasoning.** `assert_public_domain` there states the basis for
the Book of Concord: the Bente and Dau translation of 1921. That reasoning does
not transfer. These are English originals by authors who died in 1853, 1896 and
1898, so no translator's copyright can attach and the author's own death settles
it — the same rule `ingest_reformation.py` applies to its English authors.

**What is here and what is not.** The family covers two unrelated bodies. The
Plymouth Brethren are represented well: Mackintosh's complete *Notes on the
Pentateuch* and six volumes of his *Miscellaneous Writings*, Müller's *Narrative*
in all four parts, and Groves's *Christian Devotedness* — the 1825 tract that is
as close as the movement has to a founding document. **J. N. Darby is absent**,
and he is the movement's central figure: Gutenberg has none of him, and the
archive.org copies of his *Collected Writings* are lending-only. The **Church of
the Brethren** — the Dunkers, a wholly separate Anabaptist-Pietist body sharing
the name — is absent too; Alexander Mack's *Rights and Ordinances* is not
digitised anywhere found.

    python3 tools/ingest_brethren.py fetch
    python3 tools/ingest_brethren.py parse
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

import ingest_gutenberg as pg  # noqa: E402
import ingest_reformation as ccel  # noqa: E402

CACHE = ROOT / ".cache" / "brethren"
UNITS = ROOT / "tools" / "data" / "brethren_units.json"

# Authors, with the death year the rights reasoning rests on.
DIED = {"Charles Henry Mackintosh": 1896,
        "George Müller": 1898,
        "Anthony Norris Groves": 1853}

# Chapter headings in the body carry no page number; the table of contents
# repeats them with one. Anchoring the end of the line separates the two.
CHAPTERS = r"^(CHAPTER\s+[IVXLC]+(?:[.,\-–]\s*[IVXLC]+)*\.?)\s*$"
PARTS = r"^(PART\s+[IVXLC]+\.?)\s*$"

WORKS = [
    # --- C. H. Mackintosh: Notes on the Pentateuch -------------------------
    # His major work and a Brethren classic — the six volumes are the reason
    # "Notes on the Pentateuch" is shorthand for him.
    (37915, "Notes on the Book of Genesis", None, "Commentary", CHAPTERS),
    (40596, "Notes on the Book of Exodus", None, "Commentary", CHAPTERS),
    (40610, "Notes on the Book of Leviticus", None, "Commentary", CHAPTERS),
    (76552, "Notes on the Book of Numbers", None, "Commentary", CHAPTERS),
    (41571, "Notes on the Book of Deuteronomy, Volume I", None, "Commentary", CHAPTERS),
    (41584, "Notes on the Book of Deuteronomy, Volume II", None, "Commentary", CHAPTERS),

    # --- C. H. Mackintosh: Miscellaneous Writings --------------------------
    (37274, "The Assembly of God", None, "Treatise", PARTS),
    (40515, "Elijah the Tishbite", None, "Treatise", PARTS),
    (40556, "The Lord's Coming", None, "Treatise", PARTS),
    (40575, "The Great Commission", None, "Treatise", PARTS),
    (41502, "The All-Sufficiency of Christ", None, "Treatise", PARTS),
    (42343, "Life and Times of David", None, "Treatise", PARTS),

    # --- George Müller -----------------------------------------------------
    # The Narrative in its four parts, and only that. Gutenberg also has *The
    # Life of Trust*, which is an American editor's rearrangement of the same
    # text, and *Answers to Prayer*, which is extracts from it. Taking all
    # three would put the same material in the corpus three times — the
    # "content duplicated elsewhere" finding `audit_corpus.py` reports.
    (20379, "A Narrative of Some of the Lord's Dealings with George Müller, Part 1",
     None, "Treatise", None),
    (22034, "A Narrative of Some of the Lord's Dealings with George Müller, Part 2",
     None, "Treatise", None),
    (22148, "A Narrative of Some of the Lord's Dealings with George Müller, Part 3",
     None, "Treatise", None),
    (20245, "A Narrative of Some of the Lord's Dealings with George Müller, Part 4",
     None, "Treatise", None),

    # --- Anthony Norris Groves ---------------------------------------------
    # The 1825 tract that argued a Christian should hold no reserve of wealth,
    # and the nearest thing the movement has to a founding document — Groves
    # is the man Darby and the others gathered around in Dublin. His *Journal
    # of a Residence at Bagdad* is on Gutenberg too and is not taken: it is a
    # missionary travel diary, not theology.
    # 1825 is the one date any of these texts states about itself: its
    # closing note reads "The first edition ... was published by
    # Hatchard 1825."
    (24293, "Christian Devotedness", "1825", "Treatise", None),
]

AUTHOR_OF = {
    **{i: "Charles Henry Mackintosh" for i in
       (37915, 40596, 40610, 76552, 41571, 41584,
        37274, 40515, 40556, 40575, 41502, 42343)},
    **{i: "George Müller" for i in (20379, 22034, 22148, 20245)},
    24293: "Anthony Norris Groves",
}


# Gutenberg's older files sign off in prose — "End of Project Gutenberg's Notes
# on the Book of Leviticus, by C. H. Mackintosh" — *before* the `***` marker
# that `ingest_gutenberg.body_of` cuts at, so the sign-off survives into the
# last unit. Two of the seventeen works ended that way.
SIGN_OFF = re.compile(r"^End of (?:the )?Project Gutenberg.*$", re.I | re.M)

# And they open with the volunteer's credit, which is not part of the work.
PRODUCED_BY = re.compile(r"\A\s*Produced by[^\n]*\n+", re.I)


def trimmed(body):
    """The work, with Gutenberg's own opening and closing lines removed."""
    body = PRODUCED_BY.sub("", body)
    sign_off = SIGN_OFF.search(body)
    return body[:sign_off.start()] if sign_off else body


# Life dates, used as the work's date wherever the text does not state its own
# publication year. Hand-typing a year the source does not give is how a guess
# ends up on a citation looking like a fact — Gutenberg's header carries only
# the *release* date of the ebook, and Müller's Narrative is a journal whose
# opening pages are thick with years that are diary entries, not imprints.
# The corpus already files CCEL works this way: Ryle is "1816-1900".
LIFE_DATES = {"Charles Henry Mackintosh": "1820-1896",
              "George Müller": "1805-1898",
              "Anthony Norris Groves": "1795-1853"}


def rights_for(author, text, work_id):
    """The basis on which this work is public domain, stated per work.

    Two things, both recorded on the source. Gutenberg's own statement is
    collection-level and is therefore evidence rather than a guarantee — the
    same caveat `ingest_gutenberg.py` records. The per-work basis is the
    author's death: all three wrote in English, so no translator's copyright
    can attach, and all three died well before the cutoff.
    """
    if not re.search(r"public domain", text, re.I):
        raise SystemExit(f"{work_id}: no public-domain statement in the file — "
                         f"refusing to ingest")
    died = DIED[author]
    return (f"Public domain in the US: written in English by an author who died "
            f"in {died}, before the {ccel.PD_CUTOFF} cutoff; "
            f"Project Gutenberg's collection statement agrees")


def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    for work_id, title, *_ in WORKS:
        path = CACHE / f"{work_id}.txt"
        if path.exists():
            print(f"  cached   {work_id:<7} {title[:52]}")
            continue
        result = subprocess.run(
            ["curl", "-fsSL", "--max-time", "180", "-A", pg.USER_AGENT,
             f"https://www.gutenberg.org/cache/epub/{work_id}/pg{work_id}.txt"],
            capture_output=True)
        if result.returncode != 0:
            print(f"  FAILED   {work_id}: curl exit {result.returncode}",
                  file=sys.stderr)
            continue
        path.write_bytes(result.stdout)
        print(f"  fetched  {work_id:<7} {title[:44]:<46} "
              f"{len(result.stdout):>9,} bytes")
        time.sleep(pg.DELAY_SECONDS)


def parse():
    records, skipped = [], []

    for work_id, title, date, kind, unit_re in WORKS:
        path = CACHE / f"{work_id}.txt"
        if not path.exists():
            skipped.append((work_id, title, "not fetched"))
            continue

        text = path.read_text(encoding="utf-8", errors="replace")
        author = AUTHOR_OF[work_id]
        rights = rights_for(author, text, work_id)
        body = trimmed(pg.body_of(text, work_id))

        units = []
        if unit_re:
            marks = list(re.compile(unit_re, re.M).finditer(body))
            for i, mark in enumerate(marks):
                end = marks[i + 1].start() if i + 1 < len(marks) else len(body)
                content = pg.clean(body[mark.end():end])
                if len(content) < 200:
                    continue
                units.append({"number": len(units) + 1,
                              "title": mark.group(1).strip()[:200],
                              "content": content})
        if len(units) < 3:
            if unit_re:
                print(f"  {title}: {len(units)} heading matches — "
                      f"falling back to paragraph chunking", file=sys.stderr)
            units = pg.paragraph_units(body, title)

        units = pg.split_oversized(units)
        chars = sum(len(u["content"]) for u in units)
        if chars < 5000:
            skipped.append((work_id, title, f"only {chars:,} characters"))
            continue

        records.append({
            "title": title,
            "author": author,
            "date": date or LIFE_DATES[author],
            "tradition": "Brethren",
            "kind": kind,
            "url": f"https://www.gutenberg.org/ebooks/{work_id}",
            "rights": rights,
            "collection": f"Project Gutenberg ebook {work_id}",
            "units": units,
        })

    records.sort(key=lambda r: (r["author"], r["title"]))
    for record in records:
        chars = sum(len(u["content"]) for u in record["units"])
        print(f"  {record['author'][:24]:<26} {record['title'][:44]:<46} "
              f"{len(record['units']):>4} units {chars/1000:>8.1f} K")
    print(f"\n  {len(records)} works, "
          f"{sum(len(r['units']) for r in records):,} units, "
          f"{sum(len(u['content']) for r in records for u in r['units'])/1e6:.2f} M chars")

    if skipped:
        print(f"\n{len(skipped)} not ingested:")
        for work_id, title, why in skipped:
            print(f"    {work_id:<8} {title[:40]:<42} {why}")

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
