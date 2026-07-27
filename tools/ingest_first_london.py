#!/usr/bin/env python3
"""Ingest the First London Baptist Confession (1644).

The corpus shipped the Second London Confession (1689) and not the First, which
reads as though 1689 were where Baptists began. It is not: 1644 is the founding
document of the Particular Baptists, written while they were being prosecuted
for it, and it says several things the 1689 does not — believer's baptism *by
immersion* stated outright (article XL), and the church's independence from the
magistrate in article XLVIII, which is why the confession exists at all.

Two witnesses, as with [ingest_baptist.py]:

* **reformedreader.org** — the 1644 first edition, in its original article
  order, annotating the later impressions' additions in square brackets. Clean
  HTML transcription; no OCR. This supplies the text.

* **Edward Bean Underhill, *Confessions of Faith … of the Baptist Churches of
  England in the 17th Century*, Hanserd Knollys Society, 1854** — the standard
  scholarly edition, scanned at archive.org. This corroborates it.

**What the corroboration does and does not establish, stated plainly.**
Underhill prints the *second impression of 1646*, "corrected and enlarged",
footnoting the 1644 readings where they differ. It is therefore not a second
transcription of the same words, and no word-identity check against it is
meaningful — article I was rewritten wholesale between the two impressions
("That God as he is in himself, cannot be comprehended" became "The Lord our
God is but one God, whose subsistence is in himself"). What Underhill does
establish is everything that actually goes wrong with a confessional text found
on the open web: it fixes the article count and order, it proves this is the
whole document rather than an abridgement, and its 17th-century vocabulary
proves the transcription has not been quietly modernised into a paraphrase. The
gate below is set to what that evidence supports and no higher.

Two defects in the numbering are **expected and asserted**, not tolerated. The
1644 printing misnumbers: the 36th article is set as XXVI, and the last is set
as LII when the preceding article is already LII. Both are in Underhill too, and
reformedreader marks the second `[sic]`. Asserting them means a page that has
been silently re-edited fails here instead of shipping.

    python3 tools/ingest_first_london.py fetch
    python3 tools/ingest_first_london.py parse
"""

import argparse
import html
import json
import re
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "baptist"
UNITS = ROOT / "tools" / "data" / "first_london_units.json"

USER_AGENT = (
    "council-research/0.1 (offline theology corpus; "
    "contact via github SpencerSmithSite/council)"
)

CONFESSION_URL = "https://www.reformedreader.org/ccc/1644lbc.htm"

# Underhill's volume, Toronto scan. archive.org exposes the OCR of any scan at
# /download/<id>/<id>_djvu.txt; the identifier is pinned so a re-run compares
# against the same scan rather than whichever copy search returns today.
UNDERHILL_ID = "confessionsoffai00unde"
UNDERHILL_URL = f"https://archive.org/download/{UNDERHILL_ID}/{UNDERHILL_ID}_djvu.txt"
UNDERHILL_CITE = (
    "Edward Bean Underhill (ed.), Confessions of Faith and Other Public "
    "Documents Illustrative of the History of the Baptist Churches of England "
    "in the 17th Century (London: Hanserd Knollys Society, 1854), pp. 27-48"
)

ARTICLES = 53

# The confession runs from its own heading to the appendix that follows it.
# Underhill's volume is 768 KB of other documents; anchoring on these two
# phrases rather than on byte offsets means a re-scan with different pagination
# still lands on the same text, and a scan that does not contain it fails.
# Whitespace is matched loosely because the OCR breaks display headings across
# lines — the title is set as "CONFESSION OF FAITH\n\nOF THE SEVERAL\n\n…".
UNDERHILL_OPENS = re.compile(r"CONGREGATIONS\s+OR\s+CHURCHES\s+OF\s+CHRIST")
UNDERHILL_CLOSES = re.compile(r"AN\s+APPENDIX")

# The printing's own numbering errors, by position in the sequence.
KNOWN_MISNUMBERING = {36: "XXVI", 53: "LII"}

# Vocabulary containment of each 1644 article against the whole 1646 text.
#
# Both numbers are measured, not chosen: across the 53 articles the median is
# 92% and the lowest is 72% (article IV, on the fall, which 1646 recast). A
# modernised paraphrase or a different document scores nothing like this — the
# rejected Founders Press modernisation of the 1689 scored below 40% against
# its original. The floor is set just under the observed worst so that a real
# change in either page fails, and the median is gated too, because one article
# drifting is a revision and twenty drifting is a different text.
MIN_ARTICLE_OVERLAP = 0.70
MIN_MEDIAN_OVERLAP = 0.88

PARAGRAPH_RE = re.compile(r'<p[^>]*class="main_body"[^>]*>(.*?)</p>', re.S)
# Every proof marker and every note label is an <a> to the (now dead) spurgeon
# .org anchors. Matching the tag rather than the digits is what keeps scripture
# references like "1 Tim. 6:16" out of the marker stream.
ANCHOR_RE = re.compile(r"<a[^>]*>(.*?)</a>", re.S)
NOTE_RE = re.compile(r"<a[^>]*>\[(\d+)\]</a>(.*?)(?=<a[^>]*>\[\d+\]</a>|$)", re.S)
TAG_RE = re.compile(r"<[^>]+>")


def run(url, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        print(f"  cached   {path.name}")
        return
    print(f"  fetching {path.name}")
    result = subprocess.run(
        ["curl", "-fsSL", "--max-time", "180", "-A", USER_AGENT, url, "-o", str(path)],
        capture_output=True,
    )
    if result.returncode != 0:
        sys.exit(f"FAILED {path.name}: curl exit {result.returncode}")


def fetch():
    run(CONFESSION_URL, CACHE / "first_london.html")
    run(UNDERHILL_URL, CACHE / "underhill.txt")


def clean(fragment, keep_anchors=False):
    if not keep_anchors:
        fragment = ANCHOR_RE.sub(" ", fragment)
    text = html.unescape(TAG_RE.sub(" ", fragment))
    return re.sub(r"\s+", " ", text).strip()


def roman(n):
    out = ""
    for value, sign in ((50, "L"), (40, "XL"), (10, "X"), (9, "IX"),
                        (5, "V"), (4, "IV"), (1, "I")):
        while n >= value:
            out += sign
            n -= value
    return out


NUMERALS = {roman(n) for n in range(1, ARTICLES + 7)}


def heading_of(text):
    """The article numeral, if this paragraph is a heading and nothing else."""
    match = re.match(r"^([IVXL]+)\.?(?:\s*\[sic\])?$", text)
    return match.group(1) if match and match.group(1) in NUMERALS else None


def parse_notes(paragraphs):
    """marker number -> the scripture proofs it points at.

    The confession publishes 149 proofs as endnotes and marks them inline. The
    marks are useless on their own once the anchors are stripped, so each
    article's proofs are resolved here and stored with it.
    """
    for raw in paragraphs:
        if "NOTES" not in clean(raw)[:8]:
            continue
        notes = {int(n): clean(body) for n, body in NOTE_RE.findall(raw)}
        if notes:
            return notes
    sys.exit("REFUSED: the page carries no NOTES block — the proofs are gone.")


def parse_confession(body):
    """The page -> 53 articles, each with its text and its scripture proofs."""
    paragraphs = PARAGRAPH_RE.findall(body)
    if not paragraphs:
        sys.exit("REFUSED: no main_body paragraphs — the page changed shape.")

    notes = parse_notes(paragraphs)

    articles, index = [], 0
    while index < len(paragraphs):
        label = heading_of(clean(paragraphs[index]))
        if label is None:
            index += 1
            continue

        # A heading owns every paragraph up to the next heading. Articles XLVI
        # and LII run to two paragraphs, so taking only the next one would
        # silently truncate them.
        text, markers, index = [], [], index + 1
        while index < len(paragraphs) and heading_of(clean(paragraphs[index])) is None:
            fragment = paragraphs[index]
            if clean(fragment).startswith("NOTES"):
                index += 1
                continue
            markers += [
                int(m) for m in re.findall(r"<a[^>]*>(\d+)</a>", fragment)
            ]
            if clean(fragment):
                text.append(clean(fragment))
            index += 1
        articles.append({"label": label, "text": " ".join(text), "markers": markers})

    assert_shape(articles)

    for position, article in enumerate(articles, 1):
        article["number"] = position
        article["proofs"] = "; ".join(
            notes[m] for m in article["markers"] if m in notes
        )
    return articles


def assert_shape(articles):
    """Refuse anything but the document this ingester was written against.

    An article that parses as empty, or a count that has drifted, is the defect
    that ships looking correct — the confession reads fine with one article
    missing, because nothing in it points back at the one before.
    """
    if len(articles) != ARTICLES:
        sys.exit(
            f"REFUSED: found {len(articles)} articles, expected {ARTICLES}. "
            f"Labels: {[a['label'] for a in articles]}"
        )

    empty = [i for i, a in enumerate(articles, 1) if len(a["text"]) < 80]
    if empty:
        sys.exit(f"REFUSED: article(s) {empty} parsed with no text of their own.")

    for position, article in enumerate(articles, 1):
        expected = KNOWN_MISNUMBERING.get(position, roman(position))
        if article["label"] != expected:
            sys.exit(
                f"REFUSED: article {position} is labelled {article['label']}, "
                f"expected {expected}. The page's numbering has changed, and "
                f"this ingester's positions can no longer be trusted."
            )
    print(f"  {ARTICLES} articles, numbering matches the 1644 printing "
          f"(including its own errors at {sorted(KNOWN_MISNUMBERING)})")


def words(text):
    """A comparable word stream.

    Short tokens are dropped: they are where OCR noise concentrates ("110" for
    "no", "tbe" for "the") and they carry no evidence either way. Long words are
    what separate two impressions of one confession from two different
    documents.
    """
    text = re.sub(r"-\s*\n\s*", "", text.lower())
    text = re.sub(r"[’']", "", text)
    return [w for w in re.findall(r"[a-z]+", text) if len(w) > 3]


def underhill_confession(raw):
    """The confession's own text, cut out of the 768 KB volume around it."""
    opens = UNDERHILL_OPENS.search(raw)
    closes = UNDERHILL_CLOSES.search(raw, opens.end() if opens else 0)
    if not opens or not closes:
        sys.exit(
            "REFUSED: could not locate the confession inside the Underhill "
            "scan. Without the second witness this text has one source, and "
            "one source is what the corpus rule exists to prevent."
        )
    return raw[opens.start():closes.start()]


def verify(articles, underhill):
    """Check each article against Underhill's 1646 impression.

    See the module docstring for what this can and cannot show. It is a test
    for abridgement, modernisation and fabrication, not for word-identity,
    because the two impressions genuinely differ.
    """
    # The confession is 46 KB of Underhill's 768 KB volume and yields about
    # 1100 distinct long words. The floor catches anchors that have slipped
    # onto a short or empty region, which would otherwise make every article
    # fail below and read as though the transcription were at fault.
    reference = set(words(underhill))
    if len(reference) < 800:
        sys.exit(
            f"REFUSED: the extracted Underhill text has only {len(reference)} "
            f"distinct words — the scan or the anchors are wrong."
        )

    scored = []
    for article in articles:
        found = list(dict.fromkeys(words(article["text"])))
        missing = [w for w in found if w not in reference]
        scored.append((1 - len(missing) / len(found), article, missing))

    median = statistics.median(score for score, _, _ in scored)
    scored.sort(key=lambda row: row[0])
    worst, worst_article, worst_missing = scored[0]

    print(f"  corroborated against {UNDERHILL_ID}: median {median:.0%}, "
          f"lowest {worst:.0%} (article {worst_article['number']})")

    failures = [row for row in scored if row[0] < MIN_ARTICLE_OVERLAP]
    if failures:
        for score, article, missing in failures[:10]:
            print(f"    article {article['number']}: {score:.0%} — "
                  f"absent from Underhill: {missing[:10]}")
        sys.exit(
            f"REFUSED: {len(failures)} article(s) share too little vocabulary "
            f"with the 1646 impression to be the same document."
        )
    if median < MIN_MEDIAN_OVERLAP:
        sys.exit(
            f"REFUSED: median overlap {median:.0%} is below "
            f"{MIN_MEDIAN_OVERLAP:.0%}. One article diverging is the 1646 "
            f"revision; the whole text diverging is a different text."
        )

    # Named rather than buried: these are the articles 1646 rewrote, and a
    # reader comparing editions should be told which they are.
    revised = [a["number"] for score, a, _ in scored if score < 0.80]
    if revised:
        print(f"  most revised in 1646: articles {sorted(revised)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["fetch", "parse"])
    args = parser.parse_args()

    if args.command == "fetch":
        fetch()
        return

    articles = parse_confession(
        (CACHE / "first_london.html").read_text(encoding="utf-8", errors="replace")
    )
    verify(
        articles,
        underhill_confession(
            (CACHE / "underhill.txt").read_text(encoding="utf-8", errors="replace")
        ),
    )

    units = []
    for article in articles:
        content = article["text"]
        if article["proofs"]:
            content = f"{content}\n\n{article['proofs']}"
        # Cited as 1LBCF 40, so the title leads with the number a citation
        # would use. The printed numeral is kept beside it where the two
        # disagree, so a reader holding a facsimile is not told they are wrong.
        label = article["label"]
        printed = "" if label == roman(article["number"]) else f" [printed {label}]"
        units.append(
            {
                "number": article["number"],
                "title": f"Article {article['number']}{printed}",
                "content": content,
            }
        )

    chars = sum(len(u["content"]) for u in units)
    print(f"  {len(units)} articles, {chars / 1000:.1f} K chars")

    document = {
        "title": "The First London Baptist Confession of Faith",
        "date": "1644",
        "tradition": "Baptist",
        "kind": "Confession",
        "url": CONFESSION_URL,
        "rights": "Public domain (composed 1644)",
        "collection": (
            f"reformedreader.org transcription of the 1644 first edition, "
            f"corroborated against {UNDERHILL_CITE}, which prints the 1646 "
            f"second impression"
        ),
        "author": "",
        "editor": "",
        "units": units,
    }

    UNITS.parent.mkdir(parents=True, exist_ok=True)
    UNITS.write_text(json.dumps([document], indent=2) + "\n", encoding="utf-8")
    print(f"\nWrote {UNITS}")


if __name__ == "__main__":
    main()
