#!/usr/bin/env python3
"""Find sources that hold a work's contents page instead of the work.

Read-only. Complements `audit_corpus.py`, which detects *generated* text; this
detects *real* text that is the wrong real text — the summary of a work filed
under the work's own title.

This is the defect that hid the longest, because every other check passes. The
provenance is right, the source URL is right, the translator is right, and the
words are genuinely Augustine's. What is stored is his *argument* for each of
the 22 books of the City of God, 8,259 characters of it, where the City of God
runs past a million. Nothing about it looks broken until a reader opens Book 1
and finds a paragraph describing Book 1.

**The signal is punctuation, not vocabulary.** A contents page is a run of
headings — "Chapter 1 Absurd ideas of the disciples of Valentinus … Chapter 2
The Propator was known to Monogenes alone" — so it carries a structural marker
every hundred characters or so and almost no sentence-ending periods. Prose
carries the reverse. The two populations do not overlap: measured across the
corpus, the flagged sources run 3 to 96 markers per 1,000 characters and the
next unflagged source is at 2.3.

Conciliar acts are the case that makes a naive threshold wrong. Laodicea is 71
"Canon N" markers in 33,000 characters, which is structurally similar to a
contents page — but each canon is followed by real prose, so it sits at 2.15
markers per 1,000 characters against a contents page's 3 to 96, and its
sentence density is normal. Both bounds are needed: the marker floor is what
finds them, and the sentence ceiling is what keeps a dense canon collection
from being mistaken for one.

A ratio test — markers outpacing sentences — was tried first and is what this
does *not* do. It reads well and it silently missed the City of God, the
Confessions and the Harmony of the Gospels, whose contents pages summarise each
book in a sentence or two and so keep an ordinary sentence rate. The two flat
bounds separate the populations completely; the ratio only looked like it did.

**A second check, which is not a heuristic at all.** The punctuation signal has
a blind spot: a contents page whose entries are full sentences reads as prose.
Augustine's Christian Doctrine describes each of its four books in a sentence,
scores 0.62, and is as wrong as the City of God. For New Advent works there is
an exact test available instead of a statistical one — the cached hub page says
how many parts the work has. A work whose page links to 22 book pages and whose
corpus entry holds one unit is not a judgement call.

That check needs `.cache/newadvent`, so it is skipped with a note when the
cache has not been fetched.

    python3 tools/audit_completeness.py
    python3 tools/audit_completeness.py --all      # every source, ranked
"""

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "assets" / "theology.db"
CACHE = ROOT / ".cache" / "newadvent"
MANIFEST = ROOT / "tools" / "data" / "newadvent_manifest.json"

# The words a translated edition uses to head a division of a work. Matched
# only when followed by a number, so "the book of Job" and "in this chapter"
# do not count.
MARKER_RE = re.compile(
    r"\b(?:Chapter|Book|Homily|Letter|Section|Article|Canon|Sermon|Discourse"
    r"|Tractate|Question|Part|Preface|Prologue)\s+[IVXLC\d]",
    re.IGNORECASE,
)
SENTENCE_RE = re.compile(r"[.!?](?:\s|$)")

# Per 1,000 characters. Calibrated against the corpus, not chosen: at these
# values the fourteen known contents-page sources are flagged and the closest
# genuine text — the canons of Neocaesarea, at 2.34 markers and 6.46 sentences
# — is not.
MARKERS_PER_1K = 3.0
SENTENCES_PER_1K = 6.0


def measure(text):
    if not text:
        return 0.0, 0.0
    scale = 1000 / len(text)
    return (
        len(MARKER_RE.findall(text)) * scale,
        len(SENTENCE_RE.findall(text)) * scale,
    )


def suspect(markers, sentences):
    return markers >= MARKERS_PER_1K and sentences < SENTENCES_PER_1K


def unexpanded_hubs(conn):
    """New Advent works stored with fewer units than their page has parts.

    Exact rather than statistical: the hub page's own links are the count. A
    work is reported when its stored units number fewer than half its parts,
    which is the difference between "the parts were ingested and some are one
    unit each" and "only the contents page was ingested".
    """
    if not (CACHE.exists() and MANIFEST.exists()):
        return None

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from ingest_newadvent import sub_links  # noqa: E402

    stored = {
        row[0]: (row[1], row[2])
        for row in conn.execute(
            """SELECT s.source_url, s.title, COUNT(u.id)
               FROM sources s JOIN content_units u ON u.source_id = s.id
               GROUP BY s.id"""
        )
    }

    findings, absent = [], []
    for work in json.loads(MANIFEST.read_text(encoding="utf-8")):
        page = CACHE / f"{work['id']}.html"
        if not page.exists():
            continue
        entry = stored.get(work["url"])
        if entry is None:
            # Not "short" — not there. Ten works in exactly two books, and four
            # whose parts are lettered rather than numbered, were missing from
            # the corpus outright and nothing reported it, because every check
            # there was looked at sources that exist.
            absent.append((work["title"], work["author"], work["url"]))
            continue
        parts = len(sub_links(work, page.read_text(encoding="utf-8")))
        title, units = entry
        if parts >= 2 and units < max(2, parts / 2):
            findings.append((parts, units, title, work["author"], work["url"]))

    findings.sort(reverse=True)
    return findings, sorted(absent)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--all", action="store_true",
                        help="list every source ranked by marker density")
    args = parser.parse_args()

    conn = sqlite3.connect(args.db)
    rows = conn.execute(
        """SELECT s.id, s.title, s.author, s.source_url,
                  COUNT(u.id), SUM(LENGTH(u.content)), GROUP_CONCAT(u.content, ' ')
           FROM sources s JOIN content_units u ON u.source_id = s.id
           GROUP BY s.id"""
    ).fetchall()

    scored = []
    for sid, title, author, url, units, chars, text in rows:
        markers, sentences = measure(text)
        scored.append((markers, sentences, sid, title, author, url, units, chars))

    scored.sort(reverse=True)
    flagged = [r for r in scored if suspect(r[0], r[1])]

    header = f"{'mk/1k':>6} {'sn/1k':>6} {'units':>6} {'chars':>9}  source"
    if args.all:
        print(header)
        for markers, sentences, sid, title, author, url, units, chars in scored:
            mark = "!" if suspect(markers, sentences) else " "
            print(f"{markers:6.2f} {sentences:6.2f} {units:6} {chars:9} {mark} "
                  f"{title[:44]} — {author or '—'}")
        print()

    print(f"{len(flagged)} of {len(scored)} sources hold a contents page "
          f"rather than the work:\n")
    if flagged:
        print(header)
    for markers, sentences, sid, title, author, url, units, chars in flagged:
        print(f"{markers:6.2f} {sentences:6.2f} {units:6} {chars:9}  "
              f"{title[:40]} — {author or '—'}")
        print(f"{'':>30}  {url or 'no source url'}")

    if not flagged:
        print("Every source holds prose. Nothing to re-ingest.")

    checked = unexpanded_hubs(conn)
    print()
    if checked is None:
        print("New Advent part check skipped — no .cache/newadvent. Run:\n"
              "    python3 tools/ingest_newadvent.py fetch")
        conn.close()
        return

    hubs, absent = checked
    if not hubs:
        print("Every multi-part New Advent work has its parts ingested.")
    else:
        print(f"{len(hubs)} New Advent works hold fewer units than their page "
              f"has parts:\n")
        print(f"{'parts':>6} {'units':>6}  source")
        for parts, units, title, author, url in hubs:
            print(f"{parts:6} {units:6}  {title[:44]} — {author}")
            print(f"{'':>14}{url}")

    print()
    if not absent:
        print("Every work in the New Advent manifest is in the corpus.")
    else:
        print(f"{len(absent)} works are in the manifest and not in the corpus "
              f"at all:\n")
        for title, author, url in absent:
            print(f"  {title[:48]:50} {author}")
            print(f"  {'':50} {url}")

    conn.close()


if __name__ == "__main__":
    main()
