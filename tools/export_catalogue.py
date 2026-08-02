#!/usr/bin/env python3
"""Export the Council corpus to the JSON the Sources page reads.

The site's source list is generated, never hand-maintained. There are 687 works
and they change whenever the corpus is rebuilt; a hand-written list would be
wrong within a week and wrong in the worst way, because a catalogue that says a
work is in the app is a claim a reader will act on.

**On descriptions.** Every card needs one, and the corpus does not carry
editorial summaries — it carries text and provenance. Writing 687 summaries
would mean writing them from nothing, and a plausible-sounding paragraph about
what *Vindiciae Evangelicae* argues is exactly the fabrication this project
spent its history removing from the corpus itself. So a description here is
built from two things that are both checkable:

  - the provenance already recorded against the source (translator, edition,
    series, print basis, rights, where it was ingested from), parsed out of the
    `notes` field rather than restated; and
  - an **excerpt of the work's own opening**, lifted verbatim from the text the
    app ships.

The excerpt is the part that does the work a summary would. It cannot be wrong
about the book, because it *is* the book.

Fragment assignment is imported from the app's own `build_packs`, not
reimplemented, so "which download contains this work" is answered by the same
code that decides what goes into the download.

**This tool lives here rather than with the website it feeds**, because it needs
the 900 MB corpus and `build_packs` — neither of which belongs in a repository of
static HTML. The website is published from `spencersmith.site` under
`public/council/`, so the destination is named explicitly rather than guessed at:
the two repositories are not siblings and no relative default would be right on
more than one machine.

    python3 tools/export_catalogue.py --out \\
        ../../spencersmithsite/spencersmith.site/public/council/assets/data/sources.json

Commit the result alongside the site.
"""

import argparse
import json
import re
import sqlite3
from pathlib import Path

# tools/ is this file's own directory, so `import build_packs` resolves without
# touching sys.path — Python puts the script's directory first.
import build_packs  # noqa: E402

APP = Path(__file__).resolve().parent.parent
DB = APP / "assets" / "theology.db"

# How much of the opening to quote. Long enough to show the register and the
# subject, short enough to stay an excerpt.
EXCERPT_CHARS = 400

# Trailing provenance that is true of the whole corpus and so says nothing on an
# individual card.
NOISE = re.compile(r"^(Ingested from|Rights:|Print basis:|From )")

# A digitiser's note about the file, which sits in the text but is not the work.
# The Pilgrim's Progress opened with "This text was prepared by Logos Research
# Systems, Inc. from an edition marked as follows:" — provenance worth keeping in
# the corpus and worthless as a description of Bunyan.
TRANSCRIBER = re.compile(
    r"\b(this (?:e?text|document|file|version) (?:was|is)|prepared by|"
    r"transcribed by|digiti[sz]ed by|scanned by|proofread|"
    r"produced by .{0,40}(?:Project Gutenberg|Distributed Proofread))",
    re.IGNORECASE)

# An editor's pointer into the book rather than a sentence of it: a contents
# line, or the credential block under a volume's title.
APPARATUS = re.compile(
    r"^(?:The following are the contents|Contents of|"
    r"[A-Z][A-Za-z.'\- ]+,\s*(?:D\.D\.|M\.A\.|LL\.D\.|Ph\.D\.|B\.D\.)[,.]?\s)")


def parse_notes(notes):
    """Split the provenance note into labelled parts.

    The note is pipe-separated and its segments are positional rather than
    keyed — `Translated by X | Ante-Nicene Fathers , Vol. 1 | Public-domain
    translation, 1885 | Ingested from newadvent.org`. Anything unrecognised is
    kept rather than dropped: an unparsed fact is still a fact, and silently
    discarding it would make the card look more certain than the record is.
    """
    parsed = {"translator": None, "edition": None, "rights": None,
              "source": None, "corroboration": None, "extra": []}
    for raw in (notes or "").split("|"):
        part = re.sub(r"\s+", " ", raw).strip()
        if not part:
            continue
        if part.startswith("Translated by "):
            parsed["translator"] = part[len("Translated by "):].strip()
        elif part.startswith("Ingested from "):
            parsed["source"] = part[len("Ingested from "):].strip()
        elif part.startswith("Rights: "):
            parsed["rights"] = part[len("Rights: "):].strip()
        elif part.startswith("Corroborated against "):
            parsed["corroboration"] = part[len("Corroborated against "):].strip()
        elif part.startswith("Print basis: "):
            parsed["edition"] = part[len("Print basis: "):].strip()
        elif re.match(r"^(Ante-Nicene|Nicene and Post-Nicene) Fathers", part):
            # Normalise the stray space Schaff's series names pick up from the
            # ingest ("Fathers , Vol. 4").
            parsed["edition"] = re.sub(r"\s+,", ",", part)
        elif part.startswith("Public-domain translation,"):
            parsed["rights"] = parsed["rights"] or part
        elif part.startswith("From "):
            parsed["extra"].append(part)
        else:
            parsed["extra"].append(part)
    return parsed


def is_display_matter(paragraph):
    """True for a title page, a byline block, or a bare heading.

    These clear any length floor and say nothing, so quoting one as the opening
    of a work gives a card that reads `BY THE REV. JOHN KING, M.A.` where the
    text should be. Judged by the share of the paragraph that is capitals and by
    how many of its lines are too short to be sentences, because a title page is
    both and prose is neither.
    """
    letters = [c for c in paragraph if c.isalpha()]
    if not letters:
        return True
    upper = sum(1 for c in letters if c.isupper()) / len(letters)
    if upper > 0.5:
        return True
    lines = [ln for ln in paragraph.splitlines() if ln.strip()]
    if len(lines) > 1 and sum(len(ln) < 45 for ln in lines) / len(lines) > 0.7:
        return True
    if TRANSCRIBER.search(paragraph) or APPARATUS.match(paragraph):
        return True
    return bool(re.match(r"^(BY|By|Translated|Edited|PREFACE|CONTENTS)\b", paragraph)
                and len(paragraph) < 120)


def excerpt(units):
    """Quote the first real prose in the work.

    Not simply the first N characters: works open with title pages, bylines and
    dedications, and a card that leads with `A Sermon Delivered on Sabbath
    Morning` has told the reader nothing they could not read in the title.

    Takes *several* opening units, not one. Reading only the first left
    twenty-two works with no excerpt at all — among them Barnes' Notes at 14.8 M
    characters and all four Manton volumes — because their opening unit is
    entirely front matter and the prose starts in the next one.

    Candidates are unit-aware rather than a flat list of paragraphs, because a
    paragraph is the wrong unit of meaning for the catechisms: the Shorter
    Catechism sets its question and its answer as separate paragraphs of thirty
    and sixty characters, so paragraph-wise scanning skipped question one
    entirely and quoted the *answer to question two* — true text, but it opens
    mid-sentence and names nothing. Read whole, that unit is "What is the chief
    end of man? Man's chief end is to glorify God, and to enjoy Him for ever",
    which is both the work's real opening and the best one-line description it
    could be given.

    The second pass reads whole units and exists for verse. The Pilgrim's
    Progress opens with Bunyan's apology in couplets, and a poem set one line to
    a paragraph offers nothing but forty-character candidates — so the
    paragraph-wise pass finds no prose in the whole book and the card is left
    blank. Read whole, the unit is continuous text like anything else.
    """
    return (_first_prose(_candidates(units), 80)
            or _first_prose((re.sub(r"\s+", " ", u).strip() for u in units), 60))


def _candidates(units):
    """Opening passages in document order, each a plausible whole thought.

    A unit short enough to quote entire is offered entire; a long one is broken
    into paragraphs, since quoting the first four hundred characters of a
    chapter and quoting the chapter are the same thing anyway.
    """
    for unit in units:
        collapsed = re.sub(r"\s+", " ", unit).strip()
        if len(collapsed) <= EXCERPT_CHARS:
            yield collapsed
        else:
            yield from re.split(r"\n\s*\n", unit)


def _first_prose(candidates, floor=80):
    for paragraph in candidates:
        paragraph = re.sub(r"\s+", " ", paragraph).strip()
        # Section anchors carried over from the source markup — "[Addr-1] The
        # reason of my humbly addressing…" is the author's sentence with an
        # editor's label welded to the front.
        paragraph = re.sub(r"^\[[^\]]{1,12}\]\s*", "", paragraph)
        if len(paragraph) < floor or is_display_matter(paragraph):
            continue
        if len(paragraph) <= EXCERPT_CHARS:
            return paragraph
        cut = paragraph[:EXCERPT_CHARS]
        # Prefer a sentence end, then a word boundary. Never mid-word: the
        # ellipsis is meant to read as an abridgement, not as a truncation bug.
        stop = max(cut.rfind(". "), cut.rfind("? "), cut.rfind("! "))
        if stop > EXCERPT_CHARS * 0.6:
            return cut[:stop + 1]
        return cut[:cut.rfind(" ")].rstrip(",;:") + "…"
    return None


def collections_by_fragment(collections):
    index = {}
    for collection in collections:
        for fragment in collection["fragments"]:
            index.setdefault(fragment, []).append(
                {"id": collection["id"], "name": collection["name"]})
    return index


def main():
    parser = argparse.ArgumentParser(
        description="Export the corpus catalogue for the Council website.")
    parser.add_argument(
        "--out", required=True, type=Path,
        help="where to write sources.json — normally "
             "<spencersmith.site>/public/council/assets/data/sources.json")
    out = parser.parse_args().out

    if not DB.exists():
        raise SystemExit(
            f"{DB} not found — run `gunzip -k assets/theology.db.gz` first "
            f"(the uncompressed corpus is gitignored).")
    if not out.parent.exists():
        # Nearly always a typo in the path to the site checkout, and writing a
        # fresh tree of directories somewhere unintended is worse than stopping.
        raise SystemExit(f"{out.parent} does not exist — is the site checked out there?")

    fragments, collections = build_packs.load_config()
    by_fragment = collections_by_fragment(collections)

    conn = sqlite3.connect(DB)
    assignment = build_packs.assign_sources(conn, fragments)

    rows = conn.execute(
        """SELECT s.id, s.title, s.author, s.date_composed, s.source_url,
                  s.license, s.notes,
                  COALESCE(t.name, ''), COALESCE(st.name, ''),
                  COUNT(u.id), COALESCE(SUM(LENGTH(u.content)), 0)
             FROM sources s
             LEFT JOIN traditions t ON t.id = s.tradition_id
             LEFT JOIN source_types st ON st.id = s.source_type_id
             LEFT JOIN content_units u ON u.source_id = s.id
            GROUP BY s.id
            ORDER BY s.author IS NULL, s.author, s.title"""
    ).fetchall()

    # The opening units of every source, in one pass. Fetching per source would
    # be 687 queries against a 900 MB database. Three units rather than one,
    # because front matter routinely fills the first — see `excerpt`.
    openings = {}
    for source_id, content in conn.execute(
        """SELECT source_id, content FROM (
               SELECT source_id, content,
                      ROW_NUMBER() OVER (PARTITION BY source_id
                                         ORDER BY sequence) AS rank
                 FROM content_units)
            WHERE rank <= 3
            ORDER BY source_id, rank"""
    ):
        openings.setdefault(source_id, []).append(content)

    sources, missing_excerpt = [], 0
    for (sid, title, author, date, url, licence, notes,
         tradition, kind, units, chars) in rows:
        provenance = parse_notes(notes)
        fragment = assignment.get(sid, "core")
        text = excerpt(openings.get(sid, []))
        if not text:
            missing_excerpt += 1

        sources.append({
            "id": sid,
            "title": title,
            "author": author or "Anonymous",
            "dates": date or None,
            "tradition": tradition or "Unattributed",
            "type": kind or "Text",
            "units": units,
            "chars": chars,
            "url": url or None,
            "licence": licence,
            "fragment": fragment,
            # `core` is the corpus bundled inside the app binary; everything
            # else arrives as a download, so the card has to say which.
            "bundled": fragment == "core",
            "collections": by_fragment.get(fragment, []),
            "excerpt": text,
            "translator": provenance["translator"],
            "edition": provenance["edition"],
            "rights": provenance["rights"],
            "corroboration": provenance["corroboration"],
            "from": provenance["source"],
            "notes": [n for n in provenance["extra"] if not NOISE.match(n)],
        })

    catalogue = {
        "corpusVersion": json.loads(
            (APP / "assets" / "pack_catalogue.json").read_text())["corpusVersion"],
        "totals": {
            "sources": len(sources),
            "units": sum(s["units"] for s in sources),
            "chars": sum(s["chars"] for s in sources),
            "authors": len({s["author"] for s in sources}),
            "traditions": len({s["tradition"] for s in sources}),
        },
        "collections": [
            {
                "id": c["id"],
                "name": c["name"],
                "kind": c["kind"],
                "description": c["description"],
                "sources": sum(1 for s in sources
                               if any(x["id"] == c["id"] for x in s["collections"])),
            }
            for c in collections
        ],
        "sources": sources,
    }

    out.write_text(json.dumps(catalogue, ensure_ascii=False, separators=(",", ":")))

    print(f"{len(sources)} sources -> {out} "
          f"({out.stat().st_size / 1e6:.1f} MB)")
    print(f"{catalogue['totals']['chars'] / 1e6:.1f} M characters, "
          f"{catalogue['totals']['units']:,} units, "
          f"{len(catalogue['collections'])} collections")
    if missing_excerpt:
        print(f"note: {missing_excerpt} sources yielded no prose excerpt")


if __name__ == "__main__":
    main()
