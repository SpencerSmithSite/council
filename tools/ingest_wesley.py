#!/usr/bin/env python3
"""Ingest John Wesley's *Sermons on Several Occasions*.

The `methodist` tradition held 16 units — a placeholder, not a tradition. This
is its actual doctrinal standard, and the edition says so on its own title
page:

    Published in four volumes, in the year, 1771

    And to which reference is made in the trust-deeds of the Methodist
    Chapels, as constituting, with Mr. Wesley's notes on the New Testament,
    the standard doctrines of the Methodist connexion.

**141 sermons, not the 44 usually meant by "the Standard Sermons."** The 44 are
the subset the trust-deeds bind; this is Wesley's collected preaching, and the
44 are its opening run — Sermon 1 here is *Salvation by Faith*, which is
Standard Sermon 1. Taking the whole collection costs nothing and avoids
deciding, on this project's behalf, which of a man's sermons count.

Source: CCEL, which declares `Rights: Public Domain` in the text export's own
header. That declaration is checked here rather than assumed from the
collection, which is what caught CCEL's Westminster Confession export
declaring nothing at all.

Unlike the Baptist confession, this needs no corroborating second edition:
the defect there was that Wikisource stated no rights and no base edition.
CCEL states both, and the same standard that rejected its Westminster file
accepts this one.

    python3 tools/ingest_wesley.py fetch
    python3 tools/ingest_wesley.py parse
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "wesley"
UNITS = ROOT / "tools" / "data" / "wesley_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)

URL = "https://www.ccel.org/ccel/wesley/sermons/cache/sermons.txt"

# Asserted, not counted. A parser that finds 140 produces a file where every
# sermon is well-formed and one is simply absent, which nothing downstream
# would ever question.
SERMONS = 141

# "Sermon 12 [34]" at the head of a line. The number is what the collection is
# cited by, and the trailing bracket is CCEL's footnote anchor.
#
# The front matter carries a Number Index listing every sermon by title, but it
# numbers them "1." rather than "Sermon 1", so it cannot be mistaken for the
# sermons themselves — which is worth stating, because an index that parses as
# 141 well-formed stubs is exactly the failure that put chapter listings into
# this corpus twice before.
SERMON_RE = re.compile(r"^[ \t]*Sermon[ \t]+(\d+)\b.*$", re.M)

# Where the sermons stop. Everything past this is CCEL's apparatus: a scripture
# index, a title index, the generation notice, and some two thousand lines of
# `file:///` link targets. Left in, all of it becomes the tail of Sermon 141.
#
# Anchored on the "Indexes" banner rather than on "Index of Scripture
# References", which is the first thing inside it — a difference of eighty
# characters, and the difference between Sermon 141 ending on "Amen" and
# ending on the word "Indexes".
END_RE = re.compile(r"^\s*Indexes\s*$", re.M)

FOOTNOTE_RE = re.compile(r"\[\d+\]")

# CCEL rules off its sections with a line of underscores. It is a page
# ornament, and appended to the close of a sermon it reads as corruption.
# Requires at least one underscore: a pattern that also matched blank lines
# would strip the paragraph separators and return each sermon as one
# unbroken block.
RULE_RE = re.compile(r"^\s*_+\s*$")

# A bare editorial note on the source edition, left behind once its footnote
# marker is stripped. The other footnote bodies are kept — "Preached at St.
# Mary's, Oxford, before the University, on June 18, 1738" is a fact about the
# sermon and worth retrieving on.
EDITION_NOTE_RE = re.compile(r"^\s*\[?text from the \d{4} edition\]?\s*$", re.I)


def fetch():
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / "sermons.txt"
    if path.exists():
        print(f"  cached   {path.name}")
        return
    print(f"  fetching {path.name}")
    result = subprocess.run(
        ["curl", "-fsSL", "--max-time", "300", "-A", USER_AGENT,
         URL, "-o", str(path)],
        capture_output=True)
    if result.returncode != 0:
        sys.exit(f"FAILED: curl exit {result.returncode}")


def assert_rights(text):
    if "Rights: Public Domain" not in text[:2000]:
        sys.exit(
            "REFUSED: no public-domain declaration in the CCEL header. "
            "Do not ingest what has not stated its terms.")


def clean(text):
    text = FOOTNOTE_RE.sub("", text)
    kept = [line for line in text.split("\n")
            if not RULE_RE.match(line) and not EDITION_NOTE_RE.match(line)]
    # CCEL indents its body text; paragraphs are separated by blank lines.
    # Rebuilt from the surviving lines so that removing a rule does not weld
    # the paragraphs either side of it together.
    paragraphs = [" ".join(block.split())
                  for block in re.split(r"\n\s*\n", "\n".join(kept))]
    return "\n\n".join(p for p in paragraphs if p)


def parse(text):
    assert_rights(text)

    matches = list(SERMON_RE.finditer(text))
    numbers = [int(m.group(1)) for m in matches]
    if numbers != list(range(1, SERMONS + 1)):
        missing = sorted(set(range(1, SERMONS + 1)) - set(numbers))
        sys.exit(
            f"REFUSED: expected sermons 1-{SERMONS}, found {len(numbers)}"
            f"{f', missing {missing[:10]}' if missing else ''}.")

    end = END_RE.search(text, matches[-1].end())
    if end is None:
        sys.exit("REFUSED: cannot find where the sermons stop; the last one "
                 "would swallow CCEL's indexes and link table.")

    units, short = [], []
    for index, match in enumerate(matches):
        stop = (matches[index + 1].start()
                if index + 1 < len(matches) else end.start())
        body = text[match.end():stop]

        # The first non-empty line after the heading is the sermon's title;
        # the rest is the sermon.
        lines = [line for line in body.split("\n")]
        title, rest = "", lines
        for at, line in enumerate(lines):
            if line.strip():
                title = clean(line)
                rest = lines[at + 1:]
                break

        content = clean("\n".join(rest))
        if not title or len(content) < 500:
            short.append(numbers[index])
            continue

        units.append({
            "number": numbers[index],
            # Cited by number, so the citation should carry it.
            "title": f"Sermon {numbers[index]}. {title}",
            "content": content,
        })

    if short:
        sys.exit(f"REFUSED: sermons {short[:10]} parsed with no title or "
                 f"almost no text.")
    return units


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()

    if args.command == "fetch":
        fetch()
        return

    text = (CACHE / "sermons.txt").read_text(encoding="utf-8", errors="replace")
    units = parse(text)

    chars = sum(len(u["content"]) for u in units)
    print(f"  {len(units)} sermons, {chars / 1e6:.2f} M chars")
    print(f"  shortest {min(len(u['content']) for u in units)} chars, "
          f"longest {max(len(u['content']) for u in units)}")

    document = {
        "title": "Sermons on Several Occasions",
        "date": "1771",
        "tradition": "Methodist",
        "kind": "Sermon",
        "url": "https://www.ccel.org/ccel/wesley/sermons.html",
        "rights": "Public Domain",
        "collection": "Christian Classics Ethereal Library",
        "author": "John Wesley",
        "editor": "",
        # The legacy entry this replaces: six units, no author, no source URL,
        # filed under a title the collection does not actually carry. Named
        # here because the loader cannot infer it — the real edition and the
        # paraphrase of it do not share a title.
        "supersedes": ["Wesleys Standard Sermons"],
        "units": units,
    }

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    with open(UNITS, "w") as handle:
        json.dump([document], handle, indent=2)
        handle.write("\n")
    print(f"\nWrote {UNITS}")


if __name__ == "__main__":
    main()
