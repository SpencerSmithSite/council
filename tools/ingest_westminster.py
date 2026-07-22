#!/usr/bin/env python3
"""Ingest the Westminster Confession of Faith.

The corpus has carried a 13-unit, 4,157-character entry called "Westminster
Confession of Faith" with no author, no source URL and no stated rights. The
document runs to some 35,000 words. That entry is not an abridgement of the
Confession; it is a paraphrase of one, and it has been sitting under the name
of the most important Reformed document in the corpus.

Four editions were examined. The three rejected are worth recording:

* **CCEL `anonymous/westminster3`** — properly punctuated and modern, but it
  carries the PCUS and UPCUSA recensions in parallel with variants inline:

      yet [PCUS are they] [UPCUSA they are] not sufficient

  It also declares no rights, and its paragraph numbering is taken from *The
  Constitution of the Presbyterian Church (U.S.A.)*, a modern denominational
  publication. A twentieth-century critical edition of a seventeenth-century
  text is careful scholarship and the wrong thing to ship.

* **Wikisource, *The Humble Advice of the Assembly of Divines* (1647)** — the
  first published printing, proofread against a scan, which is the best
  provenance available anywhere for this document. **Nine of its thirty-three
  chapters exist.** The page says so itself with `{{incomplete|scan=yes}}`,
  and the banner was checked rather than believed: chapters 10 through 33 are
  simply absent.

* **Wikisource, Carruthers' 1946 transcription** — a container page with no
  subpages. Nothing is there.

What is used is the text as ratified by the Scottish Parliament in 1690,
which is complete, is tagged `{{PD-UKGov}}` on the page itself, and is the
form still held as the subordinate standard of the Church of Scotland.

**Its orthography is seventeenth-century and it is almost unpunctuated** —
seven commas in seventy-five thousand characters, because that is how the Act
was entered in the parliamentary record. "Gods eternall Decree", "Christs
sake", "gospell". That is a real cost to reading it, and it is accepted rather
than hidden: the alternative on offer was a paraphrase wearing the document's
name, and an authentic text with awkward spelling is better than a fluent text
that is not the document.

    python3 tools/ingest_westminster.py fetch
    python3 tools/ingest_westminster.py parse
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "westminster"
UNITS = ROOT / "tools" / "data" / "westminster_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)

PAGE = "Confession of Faith Ratification Act 1690"
API = ("https://en.wikisource.org/w/api.php?action=parse&page="
       "Confession%20of%20Faith%20Ratification%20Act%201690"
       "&prop=wikitext&format=json")
URL = ("https://en.wikisource.org/wiki/"
       "Confession_of_Faith_Ratification_Act_1690")

CHAPTERS = 33

# Paragraphs per chapter in the original text, asserted rather than counted.
#
# This is the strongest check available for a document whose failure mode is a
# chapter quietly losing a paragraph to inconsistent markup — which this
# transcription's markup invites, since it numbers some paragraphs in bold and
# some as bare digits, and numbers the opening paragraph of some chapters and
# not others.
#
# Two entries are worth knowing rather than assuming. Chapter 12, *Of
# Adoption*, really is one paragraph. Chapter 31 has five, which is how the
# original reads — the American revision of 1788 cut it to four, so a run
# producing 31:4 would mean this is a later recension wearing a 1690 date.
EXPECTED = {
    1: 10, 2: 3, 3: 8, 4: 2, 5: 7, 6: 6, 7: 6, 8: 8, 9: 5, 10: 4, 11: 6,
    12: 1, 13: 3, 14: 3, 15: 6, 16: 7, 17: 3, 18: 4, 19: 7, 20: 4, 21: 8,
    22: 7, 23: 4, 24: 6, 25: 6, 26: 3, 27: 5, 28: 7, 29: 8, 30: 4, 31: 5,
    32: 3, 33: 3,
}

# "{{c|{{larger|{{sc|Chap. i. Of the Holy Scripture}}}}}}"
CHAPTER_RE = re.compile(
    r"\{\{c\|\{\{larger\|\{\{sc\|Chap\.\s*([ivxl]+)\.\s*(.*?)\}\}\}\}\}\}",
    re.S | re.I)

# A paragraph number alone on a line, bolded or not.
#
# The transcription is not consistent about this: chapter 1 marks paragraphs 2,
# 3, 4, 6, 7, 9 and 10 as `'''4'''` and paragraphs 5 and 8 as a bare `5`.
# Matching only the bold form drops those two, and drops them *silently* —
# their text is absorbed into the previous paragraph, so nothing is missing,
# nothing is empty, and the chapter simply has eight paragraphs where it should
# have ten.
PARAGRAPH_RE = re.compile(r"^(?:''')?\s*(\d+)\s*(?:''')?\s*$")

# Where the Act's own business ends and the Confession begins is marked by the
# first chapter heading; where the Confession ends is the licence tag.
END_RE = re.compile(r"\{\{PD-|\[\[Category:")

LICENCE = "{{PD-UKGov}}"

ROMAN = {"i": 1, "v": 5, "x": 10, "l": 50}


def roman_to_int(value):
    total, previous = 0, 0
    for char in reversed(value.lower()):
        current = ROMAN[char]
        total += current if current >= previous else -current
        previous = max(previous, current)
    return total


def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / "act1690.json"
    if path.exists():
        print(f"  cached   {path.name}")
        return
    print(f"  fetching {path.name}")
    result = subprocess.run(
        ["curl", "-fsSL", "--max-time", "120", "-A", USER_AGENT,
         API, "-o", str(path)],
        capture_output=True)
    if result.returncode != 0:
        sys.exit(f"FAILED: curl exit {result.returncode}")


def clean(text):
    """Wikitext to plain prose."""
    text = re.sub(r"\{\{[^{}]*\}\}", "", text)
    text = re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", text)
    text = re.sub(r"<ref[^>]*>.*?</ref>", "", text, flags=re.S)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("'''", "").replace("''", "")
    # Blockquote indentation, which is layout rather than text.
    lines = [re.sub(r"^:+\s*", "", line).strip() for line in text.split("\n")]
    paragraphs = [" ".join(block.split())
                  for block in re.split(r"\n\s*\n", "\n".join(lines))]
    return "\n\n".join(p for p in paragraphs if p)


def parse(wikitext):
    if LICENCE not in wikitext:
        sys.exit(
            f"REFUSED: {LICENCE} is not on the page. Its licence tag is the "
            f"only thing declaring this text's terms; do not ingest what has "
            f"not stated them.")

    headings = list(CHAPTER_RE.finditer(wikitext))
    if len(headings) != CHAPTERS:
        sys.exit(f"REFUSED: found {len(headings)} chapters, expected "
                 f"{CHAPTERS}. The page changed shape.")

    end = END_RE.search(wikitext, headings[-1].end())
    if end is None:
        sys.exit("REFUSED: cannot find where the Confession stops.")

    units, sequence = [], 0
    for index, heading in enumerate(headings):
        number = roman_to_int(heading.group(1))
        if number != index + 1:
            sys.exit(f"REFUSED: chapter {index + 1} is numbered "
                     f"{heading.group(1)!r} ({number}).")
        title = clean(heading.group(2))

        stop = (headings[index + 1].start()
                if index + 1 < len(headings) else end.start())

        # Some chapters number their opening paragraph and some do not:
        # chapter 1 runs straight from the heading into the text, chapter 2
        # marks it `'''1'''`. So an unnumbered first paragraph is opened
        # speculatively and discarded if the chapter turns out to number its
        # own — otherwise chapter 2 gains an empty paragraph 1 and a duplicate.
        paragraphs, current = [], {"number": 1, "lines": [], "implicit": True}
        for line in wikitext[heading.end():stop].split("\n"):
            match = PARAGRAPH_RE.match(line.strip())
            if match:
                paragraphs.append(current)
                current = {"number": int(match.group(1)), "lines": [],
                           "implicit": False}
            else:
                current["lines"].append(line)
        paragraphs.append(current)

        if paragraphs[0]["implicit"] and not clean(
                "\n".join(paragraphs[0]["lines"])):
            paragraphs.pop(0)

        numbers = [p["number"] for p in paragraphs]
        if len(numbers) != EXPECTED[number]:
            sys.exit(
                f"REFUSED: chapter {number} ({title}) parsed "
                f"{len(numbers)} paragraphs, expected {EXPECTED[number]}.")
        missing = sorted(set(range(1, max(numbers) + 1)) - set(numbers))
        if missing:
            sys.exit(
                f"REFUSED: chapter {number} ({title}) is missing paragraph(s) "
                f"{missing}. The transcription marks some numbers in bold and "
                f"some as bare digits; the parser is matching only one form.")

        for paragraph in paragraphs:
            content = clean("\n".join(paragraph["lines"]))
            # Low, because 28.7 is genuinely seventy characters long — "THE
            # sacrament of baptism is but once to be administred unto any
            # person" is the whole paragraph. A threshold set to catch short
            # parses has to sit under the shortest real one, which meant
            # checking what that was rather than picking a round number.
            if len(content) < 40:
                sys.exit(f"REFUSED: {number}.{paragraph['number']} parsed "
                         f"{len(content)} characters.")
            sequence += 1
            units.append({
                "number": sequence,
                # Cited as WCF 1.6, so the citation reads that way.
                "title": f"{number}.{paragraph['number']}. {title}",
                "content": content,
            })

    return units


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()

    if args.command == "fetch":
        fetch()
        return

    body = (CACHE / "act1690.json").read_text(encoding="utf-8")
    units = parse(json.loads(body)["parse"]["wikitext"]["*"])

    chars = sum(len(u["content"]) for u in units)
    print(f"  {CHAPTERS} chapters, {len(units)} paragraphs, "
          f"{chars / 1e6:.3f} M chars")

    document = {
        "title": "The Westminster Confession of Faith",
        "date": "1646",
        "tradition": "Reformed",
        "kind": "Confession",
        "url": URL,
        "rights": "Public domain (PD-UKGov; Act of the pre-union Scottish "
                  "Parliament, 1690)",
        # The edition is named rather than left to be inferred, because which
        # Westminster this is genuinely matters: the orthography and near
        # absence of punctuation are the parliamentary record's, not an error.
        "collection": "As ratified by the Parliament of Scotland, 1690 "
                      "(Wikisource) — original orthography, minimally "
                      "punctuated",
        "author": "",
        "editor": "",
        # The paraphrase this replaces: 13 units, 4,157 characters, no author,
        # no URL, no stated rights.
        "supersedes": ["Westminster Confession of Faith"],
        "units": units,
    }

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    with open(UNITS, "w") as handle:
        json.dump([document], handle, indent=2)
        handle.write("\n")
    print(f"\nWrote {UNITS}")


if __name__ == "__main__":
    main()
