#!/usr/bin/env python3
"""Ingest the Summa Theologiae from New Advent.

The largest single gain available to this corpus. Aquinas is the central
figure of medieval theology and the corpus holds none of him: the only entry
under his name was an unsourced seven-unit abridgement, removed when the
unprovenanced legacy sources were pruned. New Advent hosts the complete English
translation at `/summa/`, a section the existing `ingest_newadvent.py` never
touched — it only ever walked `/fathers/`.

**Checked before trusting it.** `/summa/1001.htm` returns the article itself —
objections, *sed contra*, "I answer that", and the replies — not a chapter
index. That check is not ceremonial: two sources already in this corpus turned
out to hold New Advent index pages rather than text, and one of them was very
nearly kept because it was the same size as the abridgement it replaced.

Numbering is `<part><question>` with the question zero-padded to three digits,
verified at both ends of every part rather than assumed from the first:

    1001–1119  Prima Pars                 119 questions
    2001–2114  Prima Secundae Partis      114
    3001–3189  Secunda Secundae Partis    189
    4001–4090  Tertia Pars                 90
    5001–5099  Supplementum                99

611 pages. Past the end of a part the site serves its home page rather than a
404, so a run that silently walked off the end would collect the same page many
times over; the parser refuses anything without articles.

Units are **articles**, not questions. An article is the atomic argument and
the way Aquinas is actually cited — ST I, q.1, a.3 — so it is both the right
retrieval granularity and the right thing for a citation to name.

    python3 tools/ingest_summa.py fetch
    python3 tools/ingest_summa.py parse
"""

import argparse
import html
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "summa"
UNITS = ROOT / "tools" / "data" / "summa_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)

# robots.txt disallows only /cgi-bin/ and /tmp/ and sets no crawl delay. One
# second anyway: 611 pages is not a load worth imposing quickly.
DELAY_SECONDS = 1.0

PARTS = [
    (1, "Prima Pars", 119, "Summa Theologiae: Prima Pars"),
    (2, "Prima Secundae", 114, "Summa Theologiae: Prima Secundae"),
    (3, "Secunda Secundae", 189, "Summa Theologiae: Secunda Secundae"),
    (4, "Tertia Pars", 90, "Summa Theologiae: Tertia Pars"),
    (5, "Supplementum", 99, "Summa Theologiae: Supplementum"),
]

# The question number and title come from the page's <h1>, not its <title>.
#
# New Advent's <title> is malformed on any page whose question title contains
# double quotes — Q120 "Epikeia" ships as `<head><name=""Epikeia" or equity
# (Secunda Secundae Partis, Q. 120)">`, with no title element at all. Three
# questions were silently dropped that way, and the run still looked like a
# success because the other 608 parsed.
#
# The <h1> is well-formed on those pages, and carries the question number,
# which is a stronger check than the part name ever was: it confirms the page
# is the question that was actually asked for.
QUESTION_RE = re.compile(
    r"<h1[^>]*>\s*Question\s+(\d+)\.\s*(.*?)\s*</h1>", re.S | re.I)
# Headings are "<h2 id="article3">Article 3. Whether ...?</h2>". Anchoring on
# the id rather than on the visible text keeps the summary list of article
# titles at the top of each page — which uses the same words inside <li><a> —
# from being mistaken for the articles themselves.
ARTICLE_RE = re.compile(
    r'<h2[^>]*id="article\d+"[^>]*>\s*(Article\s+\d+\..*?)</h2>', re.S | re.I)
TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"[ \t\r\f\v]+")

# New Advent's page furniture, which sits inside the body and is not Aquinas.
FURNITURE = re.compile(
    r"(New Advent|Copyright © |Kevin Knight|Home\s+Encyclopedia|"
    r"Fathers of the Church|Contact us|ADVERTISEMENT)", re.I)


def page_id(part, question):
    return f"{part}{question:03d}"


def url_for(part, question):
    return f"https://www.newadvent.org/summa/{page_id(part, question)}.htm"


def fetch_all():
    CACHE.mkdir(parents=True, exist_ok=True)
    fetched = cached = 0

    for part, _, count, _ in PARTS:
        for question in range(1, count + 1):
            path = CACHE / f"{page_id(part, question)}.htm"
            if path.exists():
                cached += 1
                continue
            result = subprocess.run(
                ["curl", "-fsSL", "--max-time", "60", "-A", USER_AGENT,
                 url_for(part, question), "-o", str(path)],
                capture_output=True)
            if result.returncode != 0:
                print(f"  FAILED {page_id(part, question)}: "
                      f"curl exit {result.returncode}", file=sys.stderr)
            else:
                fetched += 1
            time.sleep(DELAY_SECONDS)
        print(f"  {PARTS[part - 1][1]}: done")

    print(f"fetched {fetched}, already cached {cached}")


def clean(fragment):
    text = html.unescape(TAG_RE.sub(" ", fragment))
    text = WS_RE.sub(" ", text)
    return re.sub(r"\s*\n\s*", "\n", text).strip()


def parse_page(body, part_name, question):  # noqa: ARG001
    """One question page -> its articles.

    The article text is the span between one bold `Article N.` heading and the
    next, which avoids having to model New Advent's surrounding markup at all.
    """
    heading = QUESTION_RE.search(body)
    if heading is None:
        return None, []

    # Past the end of a part the site serves its home page rather than a 404.
    # Requiring the page to announce the question that was asked for is what
    # stops a run walking off the end and recording the same page ninety times.
    if int(heading.group(1)) != question:
        return None, []

    question_title = clean(heading.group(2))

    matches = list(ARTICLE_RE.finditer(body))
    articles = []
    for index, match in enumerate(matches):
        stop = matches[index + 1].start() if index + 1 < len(matches) else len(body)
        title = clean(match.group(1))
        text = clean(body[match.end():stop])

        # Drop the trailing page furniture on the last article.
        lines = [line for line in text.split("\n")
                 if line.strip() and not FURNITURE.search(line)]
        text = "\n".join(lines).strip()
        if len(text) < 200:
            continue

        number = re.match(r"Article\s+(\d+)", title)
        articles.append({
            "article": int(number.group(1)) if number else index + 1,
            "title": title,
            "content": text,
        })

    return question_title, articles


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()

    if args.command == "fetch":
        fetch_all()
        return

    documents = []
    for part, part_name, count, source_title in PARTS:
        units, sequence, skipped = [], 0, []

        for question in range(1, count + 1):
            path = CACHE / f"{page_id(part, question)}.htm"
            if not path.exists():
                skipped.append(question)
                continue

            body = path.read_text(encoding="utf-8", errors="replace")
            question_title, articles = parse_page(body, part_name, question)
            if not articles:
                skipped.append(question)
                continue

            for article in articles:
                sequence += 1
                units.append({
                    "number": sequence,
                    # Cited as ST I, q.1, a.3, so the citation should read that
                    # way rather than as an opaque sequence number.
                    "title": f"Q{question} A{article['article']}. "
                             f"{article['title'].split('.', 1)[-1].strip()}",
                    "content": f"{question_title}\n\n{article['content']}",
                })

        chars = sum(len(u["content"]) for u in units)
        print(f"{source_title:38} {len(units):5} articles  {chars / 1e6:6.2f} M"
              f"{'  skipped ' + str(len(skipped)) if skipped else ''}")
        if skipped:
            print(f"    questions with nothing parsed: {skipped[:12]}"
                  f"{'...' if len(skipped) > 12 else ''}")
        if not units:
            sys.exit(f"REFUSED {source_title}: parsed nothing")

        documents.append({
            "title": source_title,
            "date": "1265-1274",
            "tradition": "Catholic",
            "kind": "Treatise",
            "url": f"https://www.newadvent.org/summa/",
            "rights": "Public domain (Benziger Bros. edition, 1947)",
            "collection": "New Advent",
            "author": "Thomas Aquinas",
            "editor": "",
            "units": units,
        })

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    with open(UNITS, "w") as handle:
        json.dump(documents, handle, indent=2)
        handle.write("\n")
    print(f"\nWrote {UNITS}")


if __name__ == "__main__":
    main()
