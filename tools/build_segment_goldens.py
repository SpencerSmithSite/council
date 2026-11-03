#!/usr/bin/env python3
"""Rebuild the inputs of the passage-segmentation golden fixture.

shared/golden/segments/segments.json holds, per case, a passage's content and
what the Flutter reader's lib/src/reader/passage_segments.dart makes of it. The
native Apple app ports that file to Swift and has to reproduce every offset,
because highlights and notes are stored as offsets into the content and the
native app reads the ones the Flutter app saved.

This script owns the *inputs* only: it picks chapters from the bundled corpus
(assets/theology.db.gz) and adds the hand-written cases below, then writes them
into segments.json with no outputs, and runs the Dart test in update mode to
fill the outputs in from the real Dart code:

    python3 tools/build_segment_goldens.py

Nothing here segments anything. The outputs come from the Dart code alone, so
a change to the segmenter is regenerated with the Dart step by itself
(see shared/golden/segments/README.md); this script is only needed to change
the set of cases.

FLUTTER overrides the toolchain; it defaults to the CI-pinned one.
"""

import gzip
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORPUS = ROOT / "assets" / "theology.db.gz"
GOLDEN = ROOT / "shared" / "golden" / "segments" / "segments.json"
FLUTTER = os.environ.get(
    "FLUTTER", str(Path.home() / "development/flutter-3.44.8/bin/flutter"))
KJV = "The Holy Bible: King James Version"

# (title, why). Measured with a query against the corpus when this was written:
# every KJV chapter is one numbered verse per line, joined by "\n" with no
# trailing newline; the only non-ASCII character in the whole corpus is U+2019
# (as an apostrophe); there are no headings above verse 1, no tabs, no CR, no
# square brackets and no double quotes.
CHAPTERS = [
    ("Genesis 1", "The canonical first chapter; the Dart unit tests quote it."),
    ("Genesis 3", "Questions and U+2019 apostrophes (the corpus's only non-ASCII character)."),
    ("Genesis 10", "Parentheses inside verses."),
    ("Genesis 17", "Exclamation marks."),
    ("Exodus 20", "Verse text opening with a parenthesis."),
    ("Psalms 23", "Short and familiar."),
    ("Psalms 117", "The shortest unit in the corpus: two verses, 178 characters."),
    ("Psalms 119", "The longest unit: 176 verses, three-digit verse numbers."),
    ("Psalms 120", "Short verses: one of the lowest median run lengths."),
    ("Psalms 134", "Second-shortest unit."),
    ("Psalms 136", "A refrain repeated on every verse."),
    ("Job 25", "Short chapter of six verses."),
    ("Nehemiah 10", "Lists of names: the lowest median run length (28)."),
    ("Joshua 12", "Lists of kings, one per verse."),
    ("Ezra 9", "The highest median run length in the corpus (213), still under 400."),
    ("Ezra 3", "A single verse run of 405 characters, over the 400 limit, in a chapter whose median is not."),
    ("Jeremiah 44", "Thirty verses with runs up to 404 characters."),
    ("Esther 8", "The longest single verse in the corpus (529 characters)."),
    ("2 Kings 16", "Long verses (up to 444 characters)."),
    ("Lamentations 3", "Sixty-six short verses."),
    ("Malachi 4", "Ends in the stray Gutenberg marker '*** The New Testament of the King James Bible' inside verse 6."),
    ("Obadiah 1", "A single-chapter book."),
    ("Matthew 5", "Long New Testament chapter."),
    ("Matthew 6", "Parentheses in the Gospels."),
    ("John 3", "Familiar New Testament chapter."),
    ("Acts 27", "Long narrative chapter."),
    ("Romans 8", "Dense epistle with questions."),
    ("Philemon 1", "Single-chapter epistle."),
    ("3 John 1", "Short single-chapter epistle."),
    ("Jude 1", "Single-chapter epistle with a doxology."),
    ("Revelation 22", "The last unit in the corpus."),
]

# Extra selections for specific corpus cases, on top of the standard set the
# Dart generator derives from the segment count.
CHAPTER_SELECTIONS = {
    "Psalms 119": [[98, 99, 100, 101, 175], list(range(8, 41)), [174, 175]],
    "Genesis 1": [[0, 1, 3, 4, 6, 8, 9], [30, 29, 28]],
}


def utf16_len(text):
    return len(text.encode("utf-16-le")) // 2


def pad_to(text, length, filler=" Words without end"):
    """`text` extended with lower-case filler to exactly `length` UTF-16 units."""
    out = text
    while utf16_len(out) < length:
        out += filler
    while utf16_len(out) > length:
        out = out[:-1]
    # Cutting an astral character can undershoot by one unit; and the text must
    # not end in whitespace, or trimming would make it shorter than intended.
    while utf16_len(out) < length:
        out += "x"
    if out[-1].isspace():
        out = out[:-1] + "x"
    assert utf16_len(out) == length, (utf16_len(out), length)
    return out


# One long paragraph exercising every sentence-boundary rule. Over 700 units,
# no blank lines, so it is split into sentences.
LONG_SENTENCES = (
    "St. Paul wrote to the Romans, and Gen. 1 is cited as the ground of the "
    "argument; e.g. the creation itself is called to witness. Mr. Smith "
    "disagreed. He said, \"The text is plain.\" Then he sat down. The church "
    "replied (as it always had.) Next came the vote. The clerk wrote [sic.] "
    "Later the minutes were read. Was it carried? Yes! It was carried by a "
    "large margin.  Two spaces preceded this sentence.\u00a0A no-break space "
    "preceded this one. “Curly quotes open this sentence.” And a curly "
    "close quote does not end one in the lookbehind. 'Single quotes do not "
    "start one.' lower case does not start one either. Rom. 8:28 is quoted "
    "next. The end of a sentence before a digit. 3 men followed. The end of "
    "a sentence before a tab.\tTabs are whitespace. The end before a line "
    "separator.\u2028Line separators are whitespace. The end before a next-line "
    "character.\u0085Next-line is not whitespace to a Dart RegExp. The end "
    "before an em space.\u2003Em spaces are. The end before a byte-order "
    "mark.\ufeffZero-width no-break spaces are too. Greek capitals do not "
    "count. Αλφα begins this one. Neither do accented "
    "capitals. Émile begins this one. The last sentence ends here."
)
assert utf16_len(LONG_SENTENCES) > 700

ASTRAL_SENTENCES = (
    "\U0001d50a\U0001d522\U0001d52b. The opening fraktur is three astral "
    "characters. \U0001f600 An emoji leads this sentence. A sentence with "
    "\U0001f600 inside it and \U0001d50a\U0001d52c\U0001d521 too. Then "
    "בְּרֵאשִׁית "
    "appears with its points. \U0001f64f\U0001f3fd A skin-toned emoji is "
    "two scalars. Combining marks follow: e\u0301glise and n\u0303o. "
)
ASTRAL_SENTENCES = pad_to(ASTRAL_SENTENCES * 3, 720,
                          " \U0001f600 more words follow here.")


def numbered(lines, sep="\n"):
    return sep.join(f"{n}. {t}" for n, t in lines)


def run_of(length, start="Text", filler=" and more text"):
    """A verse body of exactly `length` UTF-16 units, run included up to
    the next marker (the newline counts)."""
    return pad_to(start, length - 1, filler)


def hand_cases():
    cases = []

    def case(id_, why, content, title="Hand-written", extra=None):
        entry = {"id": id_, "why": why, "unitTitle": title, "content": content}
        if extra:
            entry["extraSelections"] = extra
        cases.append(entry)

    # ---- prose -------------------------------------------------------------
    case("prose-two-paragraphs", "Paragraphs separated by a blank line; the second is hard-wrapped and stays one paragraph.",
         "First paragraph, short.\n\nSecond paragraph,\nwrapped across\nthree lines.")
    case("prose-single-newlines", "No blank line anywhere, so each line is its own paragraph.",
         "Line one.\nLine two.\n\n", title=None)
    case("prose-blank-lines-with-spaces", "Blank lines containing spaces and tabs, runs of blank lines, leading and trailing whitespace.",
         "  \n\n  Alpha paragraph.  \n \t\nBeta paragraph.\n\n\n\nGamma\n \n \nDelta.\n\n  ", title="")
    case("prose-long-sentences", "A paragraph over 700 units: every sentence-boundary rule, abbreviations (St. Paul splits, Gen. 1 does not), quotes, brackets, Unicode spaces.",
         LONG_SENTENCES, title="  Of Sentences  ")
    case("prose-long-wrapped-among-short", "A long hard-wrapped paragraph between short ones: \\s+ crosses the line breaks inside it, and only it is split.",
         "A short opening paragraph.\n\n"
         + LONG_SENTENCES.replace(". The", ".\nThe")
         + "\n\nA short closing paragraph. With two sentences.")
    case("prose-long-no-boundary", "Over 700 units with no sentence boundary: one segment, but the kind is still 'sentence'.",
         pad_to("one long clause", 720, ", and then another clause"))
    case("prose-700-exact", "Trimmed length exactly 700 UTF-16 units: not split.",
         "  " + pad_to("Exactly at the limit. So it stays whole.", 700) + "  ")
    case("prose-701", "Trimmed length 701: split.",
         pad_to("One over the limit. So it is split.", 701))
    case("prose-astral-over-700", "690-odd scalars but over 700 UTF-16 units: Dart splits it; a Character or scalar count would not.",
         ASTRAL_SENTENCES, title="\U0001d50a\U0001d522\U0001d52b")
    case("prose-astral-paragraphs", "Astral characters before and inside short paragraphs, so offsets differ from Character and scalar offsets.",
         "\U0001f600\U0001f600 First, after two emoji.\n\n\U0001d50a\U0001d522\U0001d52b "
         "second \U0001f64f\U0001f3fd paragraph.\n\n\U0001f1fa\U0001f1e6 third: a flag.")
    case("prose-combining", "Decomposed combining marks and Hebrew points: offsets count each mark.",
         "Cafe\u0301 and e\u0301glise.\n\n"
         "בְּרֵאשִׁית בָּרָא\n\n"
         "ἐν ἀρχῇ ἦν ὁ λόγος "
         "and decomposed ε\u0313\u0300ν.")
    case("prose-greek-long", "A long Greek paragraph: the Greek question mark and Greek capitals never end a sentence; only ASCII A-Z does.",
         pad_to("Εἰ δὲ τοῦτο οὕτως; "
                "Οὐκ ἔστιν. Καὶ οὕτως. "
                "Then English. And more.", 760,
                " καὶ λόγος. Θεός."))
    case("prose-unicode-spaces", "Paragraph text padded with NBSP, em space, ideographic space, narrow NBSP, medium math space, BOM, NEL and ZWSP; trim removes all but ZWSP.",
         "\u00a0\u2003Padded paragraph.\u3000\u202f\n\n\u205f\ufeffSecond.\u0085\n\n\u200bZero-width space stays.\u200b")
    case("prose-crlf", "CRLF line endings: the blank-line separator only knows \\n, so every line becomes a paragraph and the \\r is trimmed off.",
         "First paragraph line one\r\nline two.\r\n\r\nSecond paragraph.\r\n")
    case("prose-cr-only", "Bare CR line endings never separate anything.",
         "Old Mac line one.\rOld Mac line two.\r\rStill one paragraph.")
    case("prose-line-separators", "U+2028 and U+2029 do not separate paragraphs either.",
         "One\u2028Two\u2029Three\n\nFour")
    case("prose-tabs", "Tabs around and inside paragraphs.",
         "\tIndented paragraph\twith a tab.\t\n\t\n\tSecond.\t")

    # ---- whitespace and degenerate ----------------------------------------
    case("empty", "Empty content: no segments, kind paragraph.", "", title=None)
    case("whitespace-only", "Only characters Dart's trim removes, including NEL and BOM.",
         " \n\t \u00a0\u2003\ufeff\u0085\r\n\u2028\u3000")
    case("zwsp-only", "U+200B is not whitespace to Dart's trim: one segment.", "\u200b")
    case("single-char", "A single character.", "x", title=None)

    # ---- numbered ----------------------------------------------------------
    case("single-numbered-line", "One '1.' line is not a numbered text: prose.",
         "1. In the beginning God created the heaven and the earth.")
    case("two-numbered-lines", "Two markers are the minimum for verses.",
         "1. First.\n2. Second.", title="Two")
    case("confession", "Confession-style: a heading and a title line above article 1, articles with indentation and a tab after the stop.",
         "CHAPTER I.\nOf the Holy Scripture\n\n"
         "1. Although the light of nature, and the works of creation and providence, do so far manifest the goodness, wisdom, and power of God, as to leave men inexcusable; yet are they not sufficient to give that knowledge of God, and of his will, which is necessary unto salvation.\n"
         "  2.\tUnder the name of Holy Scripture, or the Word of God written, are now contained all the books of the Old and New Testament.\n"
         "\t3. The books commonly called Apocrypha, not being of divine inspiration, are no part of the canon of the Scripture.\n\n"
         "4. The authority of the Holy Scripture dependeth not upon the testimony of any man or church.\n",
         title="Westminster Confession I")
    case("numbered-prose-long-runs", "Numbered points each governing several hundred characters: median run over 400, so prose.",
         "Three objections are raised.\n\n"
         + "\n\n".join(f"{n}. " + pad_to(f"Objection {n} runs long. It has sentences.", 520) for n in (1, 2, 3)),
         title="Sermon XV")
    case("median-run-400", "Median run exactly 400 UTF-16 units: still verses (the test is > 400).",
         "\n".join(f"{n}. " + run_of(400) for n in (1, 2)) + "\n3. " + pad_to("x", 399))
    case("median-run-401", "Median run 401: prose.",
         "\n".join(f"{n}. " + run_of(401) for n in (1, 2)) + "\n3. " + pad_to("x", 401))
    case("median-upper-of-two", "Two runs, 10 and 500: the median is the upper one, so prose.",
         "1. Short one.\n2. " + pad_to("Long one.", 500))
    case("median-astral", "A run of about 395 scalars that is over 400 UTF-16 units because of astral characters: prose.",
         "\n".join(f"{n}. " + run_of(405, "\U0001f600" * 10 + "Astral") for n in (1, 2)))
    case("verse-heading-astral", "A heading above verse 1, astral characters before and inside verses.",
         "\U0001d50a\U0001d522\U0001d52b\U0001d522\U0001d530\U0001d526\U0001d530 \U0001f600\n"
         "1. \U0001d50aod said, Let there be light \U0001f600.\n"
         "2. \U0001f600\U0001f600 And it was so \U0001d50a.\n"
         "3. Plain ASCII after them.",
         title="\U0001d50aenesis 1")
    case("verse-combining-hebrew", "Hebrew verses with points and ASCII numbers.",
         "1. בְּרֵאשִׁית בָּרָא אֱלֹהִים\n"
         "2. וְהָאָרֶץ הָיְתָה תֹהוּ",
         title="בראשית 1")
    case("verse-greek", "Greek verses, precomposed and decomposed.",
         "1. Ἐν ἀρχῇ ἦν ὁ λόγος\n"
         "2. οὗτος ἦν ἐν ἀρχῇ\n"
         "3. Ε\u0313\u0300ν decomposed.",
         title="ΚΑΤΑ ΙΩΑΝΝΗΝ 1")
    case("arabic-indic-digits", "Arabic-Indic digits are not \\d to a Dart RegExp: prose. ICU's \\d would match them.",
         "١. الآية الأولى\n"
         "٢. الآية الثانية\n"
         "١٢. الآية")
    case("other-script-digits", "Fullwidth and Devanagari digits: prose.",
         "１. Fullwidth one.\n２. Fullwidth two.\n१. Devanagari one.\n२. Devanagari two.")
    case("mixed-digit-scripts", "ASCII markers among other-script ones: only the ASCII ones count.",
         "1. Ascii one.\n٢. Arabic-Indic two, part of verse 1.\n3. Ascii three.")
    case("nbsp-after-stop", "NBSP is not [ \\t]: '1.\\u00a0' is no marker, so prose.",
         "1.\u00a0First.\n2.\u00a0Second.\n3.\u00a0Third.")
    case("space-then-unicode-space", "A space then NBSP or em space: a marker, and the Unicode space is trimmed off the text.",
         "1. \u00a0First.\n2. \u2003Second.\n3.\t\u3000Third.")
    case("bom-first-line", "A BOM before the first marker: line 1 is no marker, so only one marker: prose.",
         "\ufeff1. First.\n2. Second.")
    case("bom-then-verses", "A BOM before the first marker with two markers after it: the BOM line becomes the unnumbered first segment.",
         "\ufeff1. First.\n2. Second.\n3. Third.")
    case("crlf-verses", "CRLF verses: ^ matches after \\n, the \\r is trimmed off each text.",
         "1. In the beginning.\r\n2. And the earth.\r\n3. And God said.\r\n")
    case("cr-verses", "Bare CR before markers: Dart's multiline ^ matches after \\r.",
         "1. One.\r2. Two.\r3. Three.")
    case("line-separator-verses", "U+2028 and U+2029 before markers: Dart's ^ matches after both.",
         "1. One.\u20282. Two.\u20293. Three.")
    case("nel-verses", "U+0085 before a marker: Dart's ^ does not match after NEL (ICU's would), so one marker: prose.",
         "1. One.\u00852. Two.")
    case("formfeed-vt-verses", "Form feed and vertical tab before markers: not line terminators to Dart (ICU treats them as such).",
         "1. One.\n2. Two.\f3. Three.\u000b4. Four.")
    case("tabs-verses", "Tabs before and after the number, and trailing tabs.",
         "\t1.\tIn the beginning.\t\n\t\t2. \t And the earth.\t\t\n3.\t\tThird.")
    case("indented-verses", "Indented markers: start includes the indentation.",
         "   12. Twelve.\n    13. Thirteen.\n14. Fourteen.", title="Chapter")
    case("four-digit-numbers", "Four digits are not \\d{1,3}: no markers, prose.",
         "1000. One thousand.\n1001. One thousand and one.")
    case("leading-zeros", "Numbers 0, 00 and 007: int.tryParse gives 0, 0 and 7.",
         "0. Zero.\n00. Double zero.\n007. Seven.", title="Zeros")
    case("unordered-duplicate-numbers", "Numbers out of order and repeated: references sort and dedupe them.",
         "3. Three.\n1. One.\n2. Two.\n2. Two again.\n5. Five.\n9. Nine.\n10. Ten.\n11. Eleven.",
         title="Out of order", extra=[[0, 1, 2], [2, 3], [0, 1, 2, 3], [5, 6, 7], [4, 5, 6, 7], [1, 4]])
    case("empty-verse-texts", "Markers with no text after them are skipped, and indices stay contiguous.",
         "1. \n2. Something.\n3.  \t \n4. More.\n5.\nNot a marker, joins verse 4.")
    case("all-verse-texts-empty", "Every marker is empty: no verse segments, so prose.",
         "1. \n2. \n3.\t\n")
    case("multiline-verse", "A verse continuing onto further lines keeps its inner newlines.",
         "1. First line\ncontinues here\n\nand after a blank line.\n2. Second.")
    case("mid-line-numbers", "Numbers mid-line are not markers.",
         "See 1. above and 2. below.\nAnd 3. here.")
    case("verse-quotes", "Verses with straight and curly quotes and brackets; no sentence splitting inside verses.",
         "1. And he said, \"Go.\" Then they went.\n"
         "2. “Who is this?” [they asked.] (And none answered.)\n"
         "3. ‘Single’ quotes.",
         title="Quotes 1")
    case("long-heading", "A long heading above numbered text: the heading is one unnumbered segment however long, never sentence-split.",
         pad_to("A preface that runs on. It has sentences. Many of them.", 900) + "\n1. Short.\n2. Short too.\n3. And three.",
         title="Preface")
    case("trailing-whitespace-verses", "Trailing blank lines and spaces after the last verse.",
         "1. One.  \n2. Two.\n\n   \n\t")
    return cases


def corpus_cases():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "theology.db"
        with gzip.open(CORPUS, "rb") as src, open(path, "wb") as dst:
            dst.write(src.read())
        db = sqlite3.connect(path)
        try:
            out = []
            for title, why in CHAPTERS:
                rows = db.execute(
                    "SELECT cu.content FROM content_units cu "
                    "JOIN sources s ON s.id = cu.source_id "
                    "WHERE s.title = ? AND cu.title = ?",
                    (KJV, title)).fetchall()
                if len(rows) != 1:
                    sys.exit(f"{title}: expected one unit, found {len(rows)}")
                entry = {
                    "id": "kjv-" + title.lower().replace(" ", "-"),
                    "why": why,
                    "unitTitle": title,
                    "content": rows[0][0],
                }
                if title in CHAPTER_SELECTIONS:
                    entry["extraSelections"] = CHAPTER_SELECTIONS[title]
                out.append(entry)
            return out
        finally:
            db.close()


def main():
    cases = corpus_cases() + hand_cases()
    ids = [c["id"] for c in cases]
    assert len(ids) == len(set(ids)), "duplicate case ids"
    GOLDEN.parent.mkdir(parents=True, exist_ok=True)
    GOLDEN.write_text(json.dumps({"cases": cases}, ensure_ascii=False, indent=2) + "\n",
                      encoding="utf-8")
    print(f"wrote {len(cases)} case inputs to {GOLDEN.relative_to(ROOT)}", flush=True)
    subprocess.run(
        [FLUTTER, "test", "test/segments_golden_test.dart",
         "--dart-define=UPDATE_GOLDENS=true"],
        cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
