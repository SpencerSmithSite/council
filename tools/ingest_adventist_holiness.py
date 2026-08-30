#!/usr/bin/env python3
"""Ingest the Adventist and Holiness traditions from CCEL text exports.

Two of the fourteen families the taxonomy defines and the corpus does not hold.
`SOURCES.md` §7 and §8 recorded both as *absent and freely available* — unusual
among the newer movements, whose founding documents are normally in copyright —
and blocked on tradition rows rather than on texts. The rows exist now, so this
is the ingest they were waiting for.

**Adventist** is Ellen G. White, and CCEL carries the Conflict of the Ages
series plus *Steps to Christ*. Nothing here is a summary of Adventism written
by someone else; it is the movement's own foundational author, which is the
standard this corpus holds every tradition to.

**Holiness** is filed here as its antecedents, and that is a judgement worth
stating plainly rather than burying. The movement's own denominational
standards — Nazarene, Wesleyan, Free Methodist, Salvation Army — are all
20th-century and in copyright, so the family cannot be represented by its
confessions the way Lutheran or Reformed can. What is public domain is the
teaching those standards came out of: Finney's Oberlin perfectionism and Hannah
Whitall Smith's Keswick devotional writing. Neither author was a member of a
Holiness denomination — Finney was a Presbyterian turned Congregationalist,
Smith a Quaker — and filing them here is the same kind of call as filing
Whitefield under Methodist in `ingest_reformation.py`: they are read as sources
of the movement rather than products of it. Thomas Upham belongs to it more
directly, as Phoebe Palmer's colleague — Palmer's own CCEL author page carries
no works. And Wesley's *A Plain Account of Christian Perfection* is filed here
rather than under Methodist, because entire sanctification is the doctrine the
whole family organised itself around and nothing else in this list states it;
the reasoning is set out beside the entry.

**The parsing is not reimplemented.** `ingest_reformation.py` already cuts CCEL
exports on their rule-of-underscores backbone, classifies front matter,
footnote blocks and title pages, and splits oversized segments; that code was
shaped by about two hundred works and has the scars to prove it. This module
supplies a work list and its own rights reasoning and calls that parser.

**Rights are decided here rather than there**, because
`ingest_reformation.public_domain` gates its date fallback on a set of authors
that file ingests, and four of these five are not in it. The reasoning is the
same one: every author here wrote in English, so no translator's separate
copyright can be running, and every one of them died before the 1929 cutoff —
Wesley in 1791, Upham in 1872, Finney in 1875, Smith in 1911, White in 1915. A
CCEL rights statement, where the export carries one, is taken in preference to
that inference; a print basis at or after the cutoff refuses the work outright,
exactly as it does there.

    python3 tools/ingest_adventist_holiness.py fetch
    python3 tools/ingest_adventist_holiness.py parse
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

CACHE = ROOT / ".cache" / "adventist_holiness"
UNITS = ROOT / "tools" / "data" / "adventist_holiness_units.json"

# Work ids came off CCEL's own author index pages, not from memory — the same
# rule `survey_ccel.py` exists to enforce. `white` yields five, `finney` eight
# and `smith_hw` three, and every one of them is listed below: nothing was
# dropped for being inconvenient, and what CCEL refuses on rights or fails on
# a parse gate is reported by `parse` rather than quietly omitted here.
WORKS = [
    # --- Adventist ----------------------------------------------------------
    # The Conflict of the Ages series runs Patriarchs and Prophets → Prophets
    # and Kings → The Desire of Ages → The Acts of the Apostles → The Great
    # Controversy. CCEL's author index lists four of the five: volume one,
    # *Patriarchs and Prophets*, is the one it has no page for. Steps to Christ
    # is the devotional work, and the most widely read thing she wrote.
    ("white", "prophets", "Adventist", "Treatise"),
    ("white", "desire", "Adventist", "Treatise"),
    ("white", "acts", "Adventist", "Treatise"),
    ("white", "controversy", "Adventist", "Treatise"),
    ("white", "steps", "Adventist", "Treatise"),

    # --- Holiness -----------------------------------------------------------
    ("finney", "revivals", "Holiness", "Treatise"),
    ("finney", "theology", "Holiness", "Treatise"),
    ("finney", "lectures", "Holiness", "Treatise"),
    ("finney", "power", "Holiness", "Treatise"),
    ("finney", "fire", "Holiness", "Treatise"),
    ("finney", "backslide", "Holiness", "Treatise"),
    ("finney", "toprofessingchristians", "Holiness", "Sermon"),
    ("finney", "sermons", "Holiness", "Sermon"),
    ("smith_hw", "secret", "Holiness", "Treatise"),
    ("smith_hw", "comfort", "Holiness", "Treatise"),
    ("smith_hw", "types", "Holiness", "Treatise"),
    # Thomas Cogswell Upham, the Methodist perfectionist who worked alongside
    # Phoebe Palmer. Palmer herself has a CCEL author page with no works on it.
    ("upham", "maxims", "Holiness", "Treatise"),
    # Wesley, filed Holiness rather than Methodist — the one deliberate
    # exception, and the reason is doctrinal rather than biographical. Entire
    # sanctification is what the Holiness movement organised itself around, and
    # this is where the doctrine is set out; without it the family is
    # represented only by revival preaching and devotional writing, with no
    # statement of the teaching that makes it a family at all. Wesley's
    # *Sermons* stay under Methodist, where he belongs, and the taxonomy makes
    # Holiness a child of Methodist in any case, so the two sit adjacent on the
    # shelf rather than in unrelated places.
    ("wesley", "perfection", "Holiness", "Treatise"),
]

# Death years, for the fallback below. Stated here rather than read from the
# export header because the header is what is being reasoned *about*: a work
# whose Creator(s) line carries no dates would otherwise silently lose its only
# basis and be refused for a reason that has nothing to do with its rights.
DIED = {"white": 1915, "finney": 1875, "smith_hw": 1911, "upham": 1872,
        "wesley": 1791}


def rights_for(author_slug, fields):
    """(statement, None) or (None, why). CCEL's own words first, dates second.

    Mirrors `ingest_reformation.public_domain`, including its refusal on a
    modern print basis, and differs only in where the date fallback gets its
    authors from. The order matters and is not arbitrary: an archive that has
    affirmatively cleared a work knows something this file does not, and an
    archive that states a *restriction* must not be reasoned past on the
    strength of an author's dates.
    """
    rights = fields.get("Rights", "")
    if "public domain" in rights.lower():
        return f"CCEL states: {rights}", None
    if rights:
        return None, f"rights are {rights!r}"

    basis = fields.get("Print Basis", "")
    if basis:
        years = [int(y) for y in ccel.YEAR.findall(basis)]
        if years and max(years) >= ccel.PD_CUTOFF:
            return None, f"no rights statement and print basis is {basis!r}"

    died = DIED.get(author_slug)
    if died is None:
        return None, "no rights statement and no death year recorded here"
    if died >= ccel.PD_CUTOFF:
        return None, f"no rights statement and the author died {died}"
    return (f"Public domain in the US: written in English by an author who died "
            f"in {died}, before the {ccel.PD_CUTOFF} cutoff; CCEL's export "
            f"states no rights"), None


# --- corrections applied after parsing ---------------------------------------

# One author, one name. CCEL's Creator(s) line spells the same person three
# different ways across their own exports — "White, Ellen Gould" and "White,
# Ellen Gould Harmon"; Finney as "Charles", "Charles G." and "Charles
# Grandison" — and to anything that groups by author those are three authors.
# The corpus already carries this defect for Spurgeon, who is filed under two
# spellings and needs both listed in `packs.json` to stay in one fragment.
# Fixing it costs a line here and cannot be fixed later without rewriting rows.
AUTHOR_CANON = {
    "Ellen Gould White": "Ellen G. White",
    "Ellen Gould Harmon White": "Ellen G. White",
    "Charles Finney": "Charles G. Finney",
    "Charles Grandison Finney": "Charles G. Finney",
}

# CCEL's header misspells Fénelon. This corrects the archive's typo rather than
# retitling the work: Upham's book is an exposition of Fénelon's *Maxims of the
# Saints*, and "Felon's Maxims of the Saints" is not an alternative name for it.
TITLE_FIXES = {"Felon's Maxims of the Saints": "F\u00e9nelon's Maxims of the Saints"}

# The colophon the Ellen G. White Publications trustees attached to every text
# they released. It is a statement *about* the book — its publication year, who
# keyed it, where to write for a copy — and it arrives as the work's first unit
# because it sits below the title page and is long enough to clear the body
# floor. Shipping it means the first thing a reader opens in five of the
# corpus's works is a note about e-text provenance.
#
# It also carries the one piece of metadata the export header lacks: the year.
# CCEL's Creator(s) line gives no dates for White, so `parse_work` leaves the
# date empty; the colophon states it outright. So this is read for its year and
# then dropped, rather than simply dropped.
COLOPHON = re.compile(
    r"This is a public domain book, published in (\d{4})", re.I)


def correct(record):
    """Apply the fixes above to one parsed record, in place."""
    record["title"] = TITLE_FIXES.get(record["title"], record["title"])
    if record.get("author"):
        record["author"] = AUTHOR_CANON.get(record["author"], record["author"])

    units = record["units"]
    if units:
        match = COLOPHON.search(units[0]["content"])
        if match:
            if not record.get("date"):
                record["date"] = match.group(1)
            del units[0]
            for number, unit in enumerate(units, 1):
                unit["number"] = number
    return record


def path_for(entry):
    author_slug, work_id, _, _ = entry
    return CACHE / f"{author_slug}__{work_id}.txt"


def fetch():
    """One request per work, at CCEL's stated Crawl-delay of ten seconds."""
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
            ["curl", "-fsSL", "--max-time", "300", "-A", ccel.USER_AGENT, url,
             "-o", str(path)],
            capture_output=True,
        )
        if result.returncode != 0:
            path.unlink(missing_ok=True)
            print(f"  [{i}/{len(pending)}] FAILED  {author_slug}/{work_id} "
                  f"(curl exit {result.returncode})", file=sys.stderr, flush=True)
        else:
            print(f"  [{i}/{len(pending)}] ok      {author_slug}/{work_id:<24} "
                  f"{path.stat().st_size:>10,} bytes", flush=True)
        time.sleep(ccel.DELAY_SECONDS)


def parse():
    records, skipped = [], []

    for entry in WORKS:
        author_slug, work_id, _, _ = entry
        path = path_for(entry)
        if not path.exists():
            skipped.append((entry, "not fetched"))
            continue

        # Normalised before the header is read, not only inside `parse_work`.
        # `read_header` splits on "\n", so a CRLF export leaves a trailing \r on
        # every value — enough for `"public domain" in rights.lower()` to still
        # match, and enough for the Print Basis year check to read a different
        # string than the one printed in a refusal message.
        text = (path.read_bytes().decode("utf-8", errors="replace")
                .replace("\r\n", "\n").replace("\r", "\n"))
        rights, why = rights_for(author_slug, ccel.read_header(text))
        if rights is None:
            skipped.append((entry, why))
            continue

        record, why = ccel.parse_work(entry, text, rights_override=rights)
        if record is None:
            skipped.append((entry, why))
            continue
        records.append(correct(record))

    records.sort(key=lambda r: (r["tradition"], r["author"] or "", r["title"]))

    for record in records:
        chars = sum(len(u["content"]) for u in record["units"])
        print(f"  {record['tradition']:<10} {record['title'][:46]:<48} "
              f"{len(record['units']):>4} units {chars/1000:>8.1f} K")

    total_units = sum(len(r["units"]) for r in records)
    total_chars = sum(len(u["content"]) for r in records for u in r["units"])
    print(f"\n  {len(records)} works, {total_units:,} units, "
          f"{total_chars/1e6:.2f} M characters")

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
