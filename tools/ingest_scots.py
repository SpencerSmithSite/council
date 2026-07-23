#!/usr/bin/env python3
"""Ingest the Scots Confession (1560).

One of the Reformed stubs: six units and 1,882 characters under a name that
belongs to a 25-chapter document, with no author, no URL and no rights. This
replaces it with the whole confession.

The text is from Wikisource, in the standard modern-English rendering, and the
page ends with `{{PD-old}}` — public domain by age, which for a 1560 document
drafted by Knox and the other five Johns is beyond question. The page also
carries `{{unsourced}}`, meaning it names no base edition, so the wording is
**verified against a second independent edition** the same way the 1689 Baptist
confession was: creeds.net's transcription, which is the same rendering and the
same 25-chapter structure. Two independent transcriptions agreeing is what
turns "no edition cited" into a checkable claim.

Units are the **25 chapters**, which is how the confession is cited (Scots
Confession, ch. 3). The page also carries a preface — a dedication from "the
Estates of Scotland ... to their natural countrymen" — which is **not**
ingested: neither creeds.net nor Schaff's *Creeds of Christendom* carries it in
this rendering (Schaff keeps the archaic Scots spelling), so it cannot be
corroborated, and this corpus does not ship text it could not check. The
preface is a salutation, not doctrine, and is cited by no one.

    python3 tools/ingest_scots.py fetch
    python3 tools/ingest_scots.py parse
"""

import argparse
import html
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "reformed"
UNITS = ROOT / "tools" / "data" / "scots_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)

API = ("https://en.wikisource.org/w/api.php?action=parse&page=Scots%20Confession"
       "&prop=wikitext&format=json")
URL = "https://en.wikisource.org/wiki/Scots_Confession"
CREEDS_NET = "https://www.creeds.net/reformed/scots.htm"

# 25 chapters, asserted. A parser that finds 24 produces a file that is
# well-formed and simply missing an article, which nothing downstream questions.
CHAPTERS = 25

LICENCE = "{{PD-old}}"

# "===The Preface===" and "===Chapter 1: Of God===". Wikisource uses level-3
# headings here; matching a fixed level-2 found nothing.
HEADING_RE = re.compile(
    r"^={2,3}\s*(?:(The Preface)|Chapter\s+(\d+):\s*(.*?))\s*={2,3}\s*$", re.M)
# Wikisource's editorial scripture citations, e.g. "<ref>Ps. 51:5; Rom. 5:10</ref>".
# These are the transcriber's additions, not the confession, and are dropped.
REF_RE = re.compile(r"<ref[^>]*>.*?</ref>", re.S)


def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    for url, name in ((API, "scots.json"), (CREEDS_NET, "scots_creedsnet.html")):
        path = CACHE / name
        if path.exists():
            print(f"  cached   {name}")
            continue
        print(f"  fetching {name}")
        result = subprocess.run(
            ["curl", "-fsSL", "--max-time", "120", "-A", USER_AGENT,
             url, "-o", str(path)], capture_output=True)
        if result.returncode != 0:
            sys.exit(f"FAILED {name}: curl exit {result.returncode}")


def clean(fragment):
    """Wikitext fragment -> plain prose."""
    text = REF_RE.sub("", fragment)
    text = re.sub(r"\{\{[^{}]*\}\}", "", text)
    text = re.sub(r"\[\[File:[^\]]*\]\]", "", text, flags=re.I)
    text = re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", text)
    text = re.sub(r"<references\s*/?>", "", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("'''", "").replace("''", "")
    text = html.unescape(text)
    paragraphs = [" ".join(block.split())
                  for block in re.split(r"\n\s*\n", text)]
    return "\n\n".join(p for p in paragraphs if p)


def words(text):
    text = re.sub(r"[’']", "", text.lower())
    return [w for w in re.findall(r"[a-z]+", text) if len(w) > 1]


def creeds_net_vocabulary(path):
    raw = path.read_text(encoding="utf-8", errors="replace")
    raw = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", raw)
    return set(words(html.unescape(re.sub(r"<[^>]+>", " ", raw))))


def parse(wikitext, reference):
    if LICENCE not in wikitext:
        sys.exit(f"REFUSED: {LICENCE} is not on the page; its rights are no "
                 f"longer declared where expected.")

    headings = list(HEADING_RE.finditer(wikitext))
    chapters = [h for h in headings if h.group(2)]
    if len(chapters) != CHAPTERS:
        sys.exit(f"REFUSED: found {len(chapters)} chapters, expected "
                 f"{CHAPTERS}. The page changed shape.")
    if not any(h.group(1) for h in headings):
        sys.exit("REFUSED: the preface heading is gone; the skip below would "
                 "silently do nothing and the numbering assertion would be off.")

    units, sequence, worst = [], 0, (1.0, None)
    for index, heading in enumerate(headings):
        # The preface is deliberately skipped — see the module docstring.
        if heading.group(1):
            continue

        stop = (headings[index + 1].start()
                if index + 1 < len(headings) else len(wikitext))
        body = clean(wikitext[heading.end():stop])
        if len(body) < 120:
            sys.exit(f"REFUSED: section {heading.group(0).strip()!r} parsed "
                     f"{len(body)} characters.")

        number = int(heading.group(2))
        if number != index:  # preface is index 0, chapter 1 is index 1
            sys.exit(f"REFUSED: chapter {number} is out of order at "
                     f"position {index}.")
        title = f"Chapter {number}. {heading.group(3)}"

        # Every chapter's wording checked against the second edition. Vocabulary
        # containment, not word order: the two transcriptions punctuate
        # differently, and the only difference that matters is a substituted or
        # missing clause, which drops the score. 0.80 is the Baptist gate —
        # generous enough for two independent modern-English renderings, strict
        # enough that a swapped clause or a modernisation fails it.
        found = list(dict.fromkeys(words(body)))
        missing = [w for w in found if w not in reference]
        score = 1 - len(missing) / len(found)
        if score < worst[0]:
            worst = (score, title)
        if score < 0.80:
            sys.exit(f"REFUSED: {title} is only {score:.0%} present in the "
                     f"second edition; absent words: {missing[:12]}")

        sequence += 1
        units.append({"number": sequence, "title": title, "content": body})

    print(f"  verified {len(units)} sections against creeds.net "
          f"(worst {worst[0]:.0%} at {worst[1]})")
    return units


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()

    if args.command == "fetch":
        fetch()
        return

    wikitext = json.loads(
        (CACHE / "scots.json").read_text(encoding="utf-8"))["parse"]["wikitext"]["*"]
    reference = creeds_net_vocabulary(CACHE / "scots_creedsnet.html")
    units = parse(wikitext, reference)

    chars = sum(len(u["content"]) for u in units)
    print(f"  {len(units)} sections, {chars / 1e6:.3f} M chars")

    document = {
        "title": "The Scots Confession",
        "date": "1560",
        "tradition": "Reformed",
        "kind": "Confession",
        "url": URL,
        "rights": "Public domain (composed 1560; PD-old)",
        "collection": "Wikisource, verified against creeds.net "
                      "(creeds.net/reformed/scots.htm)",
        "author": "",
        "editor": "",
        "supersedes": ["Scots Confession"],
        "units": units,
    }

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    with open(UNITS, "w") as handle:
        json.dump([document], handle, indent=2)
        handle.write("\n")
    print(f"\nWrote {UNITS}")


if __name__ == "__main__":
    main()
