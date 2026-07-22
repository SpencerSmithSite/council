#!/usr/bin/env python3
"""Ingest the Second London Baptist Confession (1689).

The database has a `baptist` tradition row and **zero sources** in it, while
Baptists are among the largest Protestant families in the world. An app whose
whole claim is showing what each tradition actually taught, answering a
question about baptism with nothing Baptist in it, is the worst failure
available to it. One short document closes that.

Four sources were examined and three rejected. Recording why, because the
rejections are the part worth keeping:

* **Internet Archive `confeo00phil`** — a genuine 1765 Philadelphia printing,
  unambiguously public domain, 159 KB of OCR. **Rejected: the OCR is
  destroyed.** 18th-century printing uses the long s, and the scan renders it
  as `f` — `Chrift` appears 48 times and `Christ` *zero* times. Not "mostly
  fine with some errors": every occurrence is wrong, and the page text around
  it is single characters per line. This is the same defect that put OCR noise
  into the Trent decrees, caught this time before it reached the database.

* **`founders.org`** — complete, clean, well presented, and **the wrong text**:
  it is the confession *in Modern English*, a modernisation Founders Press
  sells in print. A paraphrase with a living copyright holder fails on both
  counts, and it fails quietly, because a modernisation reads as correct to
  anyone not holding the original beside it.

* **`ccel.org`** — has no edition of it.

* **Wikisource `1689 Baptist Confession of Faith`** — clean original wording,
  all 32 chapters, no OCR damage, no modernisation. **But its own first line is
  `{{no source}}`**: Wikisource declares that the page names no base edition.
  That is exactly the defect this project prunes sources for, and it is not
  cured by the text looking right.

So the text is taken from Wikisource and **every paragraph of it is verified
against a second, independent edition that does declare its terms**: Chapel
Library's 2016 typesetting, whose own notice draws precisely the right line —

    © Copyright 2016 Chapel Library: compilation, annotations.
    Original texts are in the public domain.

Their compilation and annotations are theirs; the 1689 text is not. We take
only the text. Corroboration is what converts `{{no source}}` into a provenance
a reader can actually check: two independent transcriptions agreeing word for
word is a stronger claim than one transcription asserting an edition.

Units are **paragraphs**, not chapters. A paragraph is how the confession is
cited — 2LBCF 1.10 — so it is both the right retrieval granularity and the
right thing for a citation to name.

    python3 tools/ingest_baptist.py fetch
    python3 tools/ingest_baptist.py parse
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "baptist"
UNITS = ROOT / "tools" / "data" / "baptist_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)

WIKISOURCE_PAGE = "1689 Baptist Confession of Faith"
WIKISOURCE_API = (
    "https://en.wikisource.org/w/api.php?action=parse&page="
    "1689%20Baptist%20Confession%20of%20Faith&prop=wikitext&format=json"
)
WIKISOURCE_URL = (
    "https://en.wikisource.org/wiki/1689_Baptist_Confession_of_Faith"
)

CHAPEL_PDF = "https://www.chapellibrary.org/pdf/books/lbcw.pdf"

# The confession has thirty-two chapters. Asserted rather than counted,
# because a parser that finds thirty-one produces a file that looks entirely
# correct — every chapter well-formed, nothing empty, no error raised.
CHAPTERS = 32

# Chapel Library's own rights notice, checked verbatim in the extracted text.
# Checking it per document rather than trusting the publisher is what caught
# the Westminster Confession export, which declares nothing at all.
CHAPEL_RIGHTS = "Original texts are in the public domain"

HEADING_RE = re.compile(r"^==\s*Chapter\s+(\d+)\s*:\s*(.+?)\s*==\s*$", re.M)
# Any section heading, used only to find where a chapter *stops*.
#
# Chapter 32 is the last, and the page carries one more section after it —
# "Closing Statement & Signatories". Ending the last chapter at the end of the
# page rather than at the next heading appended a list of seventeenth-century
# ministers' names to the confession's paragraph on the last judgment. It read
# as perfectly well-formed prose and was caught only because those names are
# not in Chapel Library's text.
ANY_HEADING_RE = re.compile(r"^==[^=].*==\s*$", re.M)
# "10. The supreme judge, by which..." — a paragraph number at the start of a
# line. Anchored, because chapter 1 paragraph 2 lists the canon and contains
# "1 & 2 Samuel, 1 & 2 Kings", which an unanchored pattern reads as the start
# of paragraphs 1 and 2 and shreds the books of the Bible into fragments.
PARAGRAPH_RE = re.compile(r"^(\d+)\.\s+(.*)$")
# "( 2 Timothy 3:15-17; Isaiah 8:20; ... )" — the scripture proofs the
# confession publishes with each paragraph. Held apart from the prose because
# the two editions cite differently: Wikisource writes "2 Peter" where Chapel
# Library writes "2Pe", so comparing them compares typography. They are kept
# in the stored text, where they are worth having; they are simply not
# evidence about whether the two editions agree on the confession's wording.
PROOF_RE = re.compile(r"^\(.*\)$", re.S)


def run(url, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        print(f"  cached   {path.name}")
        return
    print(f"  fetching {path.name}")
    result = subprocess.run(
        ["curl", "-fsSL", "--max-time", "180", "-A", USER_AGENT,
         url, "-o", str(path)],
        capture_output=True)
    if result.returncode != 0:
        sys.exit(f"FAILED {path.name}: curl exit {result.returncode}")


def fetch():
    run(WIKISOURCE_API, CACHE / "wikisource.json")
    run(CHAPEL_PDF, CACHE / "chapel.pdf")

    text = CACHE / "chapel.txt"
    if not text.exists():
        # `-layout` keeps the superscript annotation markers on their own
        # lines rather than jammed into the middle of words, which matters
        # because they are single letters and would otherwise be silently
        # welded onto real ones.
        result = subprocess.run(
            ["pdftotext", "-layout", str(CACHE / "chapel.pdf"), str(text)],
            capture_output=True)
        if result.returncode != 0:
            sys.exit(
                "FAILED to extract chapel.pdf. Install poppler:\n"
                "    brew install poppler")
    print(f"  ok       {text.name}")


def words(text):
    """A comparable word stream.

    Single-character tokens are dropped from **both** sides rather than from
    neither. Chapel Library sets some scripture-proof markers as bare letters
    inside the running text — "which also he most wisely and powerfully m
    boundeth" — so a literal comparison fails on their annotations rather than
    on any disagreement about the confession. Dropping one-letter tokens
    everywhere removes those markers and removes "a" and "I" from both texts
    symmetrically, which costs nothing and keeps the comparison honest.
    """
    text = text.lower()
    # Chapel Library's lines are hyphenated at the right margin: "after-\nward"
    # is one word, and left alone it reads as two that appear in neither text.
    #
    # The optional group is not defensive padding. A proof marker can land in
    # the gap, so "without equivocation" is set as `equivo-` / `g` / `cation`
    # across three lines, and rejoining only the outer two leaves two
    # fragments and no word. That single case was the last paragraph standing
    # between this text and the corpus.
    text = re.sub(r"-\s*\n\s*(?:[a-z]\s*\n\s*)?", "", text)
    text = re.sub(r"[’']", "", text)
    return [w for w in re.findall(r"[a-z]+", text) if len(w) > 1]


def unfuse(stream, vocabulary):
    """Undo Chapel Library's fused proof markers.

    Their other marker style sets the letter hard against the word that
    follows: `cinfinite`, `gimmense`, `heternal`, `kmost`, `lworking`. Dropping
    lone letters does nothing for those, and they land often enough — several
    per paragraph — to break every long run of matching words, which is what
    made two identical texts look 60% alike.

    A token is only unfused when it is **not** a word of the confession and
    removing its first letter **is** one. That condition is what keeps this
    from being a licence to make things match: it can repair a marker, and it
    cannot manufacture agreement about a clause, because the words still have
    to appear in the right order afterwards.
    """
    repaired, fixed = [], 0
    for token in stream:
        if token not in vocabulary and token[1:] in vocabulary:
            token = token[1:]
            fixed += 1
        repaired.append(token)
    return repaired, fixed


def shingles(stream, size=8):
    return {tuple(stream[i:i + size]) for i in range(len(stream) - size + 1)}


def parse_wikisource(body):
    """Wikitext -> chapters of numbered paragraphs."""
    wikitext = json.loads(body)["parse"]["wikitext"]["*"]

    headings = list(HEADING_RE.finditer(wikitext))
    if len(headings) != CHAPTERS:
        sys.exit(
            f"REFUSED: found {len(headings)} chapters, expected {CHAPTERS}. "
            f"The page changed shape, or the parser stopped matching it.")

    chapters = []
    for index, heading in enumerate(headings):
        following = [m.start() for m in ANY_HEADING_RE.finditer(wikitext)
                     if m.start() > heading.start()]
        stop = following[0] if following else len(wikitext)
        number, title = int(heading.group(1)), heading.group(2)
        if number != index + 1:
            sys.exit(f"REFUSED: chapter {index + 1} is numbered {number}.")

        body = wikitext[heading.end():stop]
        paragraphs, current = [], None
        for raw in body.splitlines():
            line = raw.strip()
            match = PARAGRAPH_RE.match(line)
            if match:
                current = {"number": int(match.group(1)),
                           "lines": [match.group(2)], "proofs": []}
                paragraphs.append(current)
            elif current is not None and line:
                (current["proofs"] if PROOF_RE.match(line)
                 else current["lines"]).append(line)

        for paragraph in paragraphs:
            paragraph["text"] = " ".join(paragraph.pop("lines")).strip()
            paragraph["proofs"] = " ".join(paragraph["proofs"]).strip()

        # Chapter 12, "Of Adoption", is one paragraph long and therefore
        # carries no number — a chapter with a single paragraph has nothing to
        # distinguish. Taking the body whole is correct there and would be a
        # disaster anywhere else, so it is allowed only when the chapter
        # contains no numbering at all: a chapter that numbers *some* of its
        # paragraphs and loses the rest still fails, which is the case worth
        # catching.
        if not paragraphs:
            kept = [line.strip() for line in body.splitlines() if line.strip()]
            text = " ".join(l for l in kept if not PROOF_RE.match(l))
            if not text:
                sys.exit(f"REFUSED: chapter {number} is empty.")
            paragraphs = [{
                "number": 1,
                "text": text,
                "proofs": " ".join(l for l in kept if PROOF_RE.match(l)),
            }]
            print(f"  chapter {number} ({title}) is a single unnumbered "
                  f"paragraph; taken whole")

        assert_complete(number, [p["number"] for p in paragraphs])
        chapters.append({"number": number, "title": title,
                         "paragraphs": paragraphs})
    return chapters


def assert_complete(chapter, numbers):
    """Refuse a chapter with holes in its paragraph numbering.

    A chapter that parses cleanly and is missing a paragraph looks entirely
    correct from the outside. Only the numbering shows it — which is how the
    Shorter Catechism was caught shipping 100 of its 107 questions.
    """
    if not numbers:
        sys.exit(f"REFUSED: chapter {chapter} parsed no paragraphs.")
    missing = sorted(set(range(1, max(numbers) + 1)) - set(numbers))
    if missing:
        sys.exit(f"REFUSED: chapter {chapter} is missing paragraph(s) "
                 f"{missing} — the parser is not matching every one.")


def verify(chapters, chapel):
    """Check every paragraph against Chapel Library's independent edition.

    This is the step that gives the text a provenance. Wikisource states no
    base edition, so agreement with a second transcription that declares its
    terms is what makes the wording checkable rather than merely plausible.

    The gate is **vocabulary containment**: what share of a paragraph's
    distinct words appear anywhere in the other edition. Word order was tried
    first, as 8-grams, and it measures the wrong thing — chapter 6 paragraph 5
    scored 72% with *every one of its words* present, because Chapel Library
    prints a running header across the middle of it and a page header is not a
    textual variant. Vocabulary is what the two real risks actually move:
    destroyed OCR turns `Christ` into `Chrift`, and a modernisation swaps the
    wording wholesale. Both collapse this score; neither survives it.

    What it does not check is order, and that is stated rather than hidden. A
    transposition between two transcriptions of a fixed 1689 text is not a
    plausible failure, and it is not what any of the rejected sources did.
    """
    if CHAPEL_RIGHTS not in chapel:
        sys.exit(
            "REFUSED: Chapel Library's public-domain declaration is not in "
            "the extracted text. Do not ingest what has not stated its terms.")

    vocabulary = {w for chapter in chapters
                  for paragraph in chapter["paragraphs"]
                  for w in words(paragraph["text"])}
    stream, fixed = unfuse(words(chapel), vocabulary)
    print(f"  reconciled {fixed} fused proof markers in Chapel Library's text")

    reference = set(stream)
    worst, checked, failures = (1.0, None), 0, []

    for chapter in chapters:
        for paragraph in chapter["paragraphs"]:
            found = list(dict.fromkeys(words(paragraph["text"])))
            if not found:
                continue
            checked += 1
            missing = [w for w in found if w not in reference]
            score = 1 - len(missing) / len(found)
            label = f"{chapter['number']}.{paragraph['number']}"
            if score < worst[0]:
                worst = (score, label)
            if score < 0.95:
                failures.append((label, score, missing))

    print(f"  verified {checked} paragraphs against Chapel Library "
          f"(worst {worst[0]:.1%} at {worst[1]})")
    if failures:
        for label, score, missing in failures[:10]:
            print(f"    {label}: {score:.0%} — absent: {missing[:10]}")
        sys.exit(
            f"REFUSED: {len(failures)} paragraph(s) use wording that is not "
            f"in the second edition. Either the Wikisource text has been "
            f"altered or the two are not the same document.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()

    if args.command == "fetch":
        fetch()
        return

    chapters = parse_wikisource(
        (CACHE / "wikisource.json").read_text(encoding="utf-8"))
    verify(chapters,
           (CACHE / "chapel.txt").read_text(encoding="utf-8", errors="replace"))

    units, sequence = [], 0
    for chapter in chapters:
        for paragraph in chapter["paragraphs"]:
            sequence += 1
            # The proofs are kept: they are what the confession itself cites,
            # and a reader asking which scripture supports a clause should be
            # able to find it in the passage rather than be told it exists.
            content = paragraph["text"]
            if paragraph["proofs"]:
                content = f"{content}\n\n{paragraph['proofs']}"
            units.append({
                "number": sequence,
                # Cited as 2LBCF 1.10, so the citation reads that way rather
                # than as an opaque sequence number.
                "title": f"{chapter['number']}.{paragraph['number']}. "
                         f"{chapter['title']}",
                "content": content,
            })

    chars = sum(len(u["content"]) for u in units)
    print(f"  {CHAPTERS} chapters, {len(units)} paragraphs, "
          f"{chars / 1e6:.3f} M chars")

    document = {
        "title": "The Second London Baptist Confession of Faith",
        "date": "1689",
        "tradition": "Baptist",
        "kind": "Confession",
        "url": WIKISOURCE_URL,
        "rights": "Public domain (composed 1689)",
        # Named so the corroborating edition travels with the text rather than
        # living only in this file's docstring.
        "collection": "Wikisource, verified against Chapel Library's 2016 "
                      "edition (chapellibrary.org/pdf/books/lbcw.pdf)",
        "author": "",
        "editor": "",
        "units": units,
    }

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    with open(UNITS, "w") as handle:
        json.dump([document], handle, indent=2)
        handle.write("\n")
    print(f"\nWrote {UNITS}")


if __name__ == "__main__":
    main()
