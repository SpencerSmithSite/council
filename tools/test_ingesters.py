#!/usr/bin/env python3
"""Self-tests for the parts of the ingesters that decide things.

Most ingester code is checked by its own assertions at run time: if Philaret
does not yield 611 questions, or a work does not clear its character floor, the
tool refuses to write. That covers the shape of a document. It does not cover
the small functions that make *judgements* — whether a work is public domain,
who its author is, whether a block of text is a title page — because those
return a value rather than crash, and a wrong value ships.

Each case here is one that was actually got wrong, and the comment says how.

    python3 tools/test_ingesters.py
"""

import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_packs  # noqa: E402
import ingest_reformation as reformation  # noqa: E402
import ingest_orthodox as orthodox  # noqa: E402
import ingest_treasury as treasury  # noqa: E402

FAILURES = []


def check(label, got, want):
    if got != want:
        FAILURES.append(f"{label}\n      got  {got!r}\n      want {want!r}")
        print(f"  FAIL  {label}")
    else:
        print(f"  ok    {label}")


# --- CCEL's Creator(s) field -------------------------------------------------

def test_creators():
    print("\nread_creators")

    # The case that filed forty-five Calvin commentary volumes with no author:
    # one man carrying role markers, read as a translator credit because the
    # person-splitter expected "(dates) Surname," and got "(dates) (Alternative)".
    check("role markers on the author himself",
          reformation.read_creators(
              "Calvin, John (1509-1564) (Alternative) (Translator)"),
          ("John Calvin", None, "1509-1564"))

    check("a genuinely separate translator",
          reformation.read_creators(
              "Calvin, John (1509-1564) Beveridge, Henry (Translator)"),
          ("John Calvin", "Henry Beveridge", "1509-1564"))

    # No dates at all. Matthew Henry's export gives only the name, and the
    # rights fallback must therefore not be reachable for him — see below.
    check("name only", reformation.read_creators("Henry, Matthew"),
          ("Matthew Henry", None, None))

    check("no creators at all", reformation.read_creators(""),
          (None, None, None))


# --- the rights decision -----------------------------------------------------

def test_public_domain():
    print("\npublic_domain")

    statement, why = reformation.public_domain(
        "calvin", {"Rights": "Public Domain"}, 1564)
    check("an explicit statement is taken at face value",
          (statement is not None, why), (True, None))

    # The ordering bug: the print-basis veto ran first and refused Calvin's
    # commentaries, which CCEL affirmatively clears, on the strength of a
    # photographic reissue's date.
    statement, why = reformation.public_domain(
        "calvin", {"Rights": "Public Domain", "Print Basis": "Baker, 1996"}, 1564)
    check("a modern reissue does not override a clearance",
          (statement is not None, why), (True, None))

    # ...but with nothing stated, a modern print basis is not something to
    # infer past. Owen died in 1683; the edition is Banner of Truth, 1967.
    statement, why = reformation.public_domain(
        "owen", {"Print Basis": "The Banner of Truth Trust, Edinburgh, 1967."},
        1683)
    check("a modern reissue does refuse an inference", statement, None)

    statement, why = reformation.public_domain("owen", {}, 1683)
    check("an English author dead before the cutoff passes",
          statement is not None, True)

    # A translation of unknown date is the whole reason the fallback is
    # restricted to authors who wrote in English.
    statement, why = reformation.public_domain("luther", {}, 1546)
    check("an unstated translation is refused", statement, None)

    statement, why = reformation.public_domain("henry", {}, None)
    check("no dates and no statement is refused", statement, None)

    statement, why = reformation.public_domain("spurgeon", {}, 1950)
    check("an author who died after the cutoff is refused", statement, None)

    statement, why = reformation.public_domain(
        "spurgeon", {"Rights": "Copyrighted; used by permission"}, 1892)
    check("a statement that is not public domain is refused", statement, None)


# --- segment classification --------------------------------------------------

def test_display_matter():
    print("\nis_display_matter")

    # Title pages clear the length floor and then sit in the corpus as
    # retrievable passages that say nothing.
    check("a title page",
          reformation.is_display_matter(
              "CALLED GENESIS BY JOHN CALVIN TRANSLATED FROM THE ORIGINAL "
              "LATIN, AND COMPARED WITH THE FRENCH EDITION, BY THE REV. JOHN "
              "KING, M.A., OF QUEEN'S COLLEGE, CAMBRIDGE"),
          True)

    check("ordinary prose",
          reformation.is_display_matter(
              "Our wisdom, in so far as it ought to be deemed true and solid "
              "wisdom, consists almost entirely of two parts: the knowledge "
              "of God and of ourselves."),
          False)


def test_titles():
    print("\ntitle_and_body")

    # Spurgeon's sermon titles are mixed case, so a capitals test misses every
    # one of them and names nine hundred sermons after their volume.
    title, body = reformation.title_and_body(
        "The Immutability of God\n\nA Sermon\n\n"
        "Delivered on Sabbath Morning, January 7th, 1855, by the Rev. C. H. "
        "Spurgeon at New Park Street Chapel, Southwark.")
    check("a mixed-case sermon title", title, "The Immutability of God — A Sermon")

    # Matthew Henry sets the book in spaced display capitals and the chapter
    # under it.
    title, body = reformation.title_and_body(
        "G E N E S I S\n\nCHAP. I.\n\n"
        "The foundation of all religion being laid in our relation to God as "
        "our Creator, it was fit that the book of divine revelations should "
        "begin, as it does, with a plain account of the creation.")
    check("spaced capitals plus a chapter mark", title, "Genesis — CHAP. I")

    # A segment that is nothing *but* a heading must not consume itself: it is
    # the heading for the next segment, and the caller carries it forward.
    title, body = reformation.title_and_body("ERASMUS' PREFACE REVIEWED.")
    check("a bare heading is left to the caller", (title, body.strip()),
          ("", "ERASMUS' PREFACE REVIEWED."))


# --- corroboration -----------------------------------------------------------

def test_containment():
    print("\ncontainment")

    witness = orthodox.bigrams(
        "we  believe  in  one  God,  true,  almighty,  and  infinite,  the "
        "Father,  the  Son,  and  the  Holy  Spirit  THE SYNOD OF JERUSALEM 23")

    check("a matching passage scores high, OCR junk notwithstanding",
          orthodox.containment(
              "We believe in one God, true, almighty, and infinite, the "
              "Father, the Son, and the Holy Spirit.", witness) > 0.9,
          True)

    # The reason the check is on word *pairs*. Same period, same subject, same
    # vocabulary, completely different sentence — single words would pass it.
    check("same vocabulary in a different order scores low",
          orthodox.containment(
              "The Holy Spirit and the Son believe one Father, almighty and "
              "true, in infinite God.", witness) < 0.4,
          True)

    check("empty text scores zero", orthodox.containment("", witness), 0.0)


def test_reference_apparatus():
    print("\nreference apparatus")

    # The trailing block of every CCEL export. 3,438 units of this shipped,
    # because a page of link targets is long enough to satisfy a floor
    # expressed in characters.
    check("a list of link targets is apparatus",
          reformation.is_reference_apparatus(
              "1. file:///ccel/r/ryle/matthew/cache/matthew.html3?scrBook=Gen"
              "&scrCh=1&scrV=3#vi.ii-p3.1 2. file:///ccel/r/ryle/matthew/cache/"
              "matthew.html3?scrBook=Gen&scrCh=3&scrV=4#xviii.i-p9.1"),
          True)

    check("the CCEL colophon is apparatus",
          reformation.is_reference_apparatus(
              "This document is from the Christian Classics Ethereal Library "
              "at Calvin College, http://www.ccel.org, generated on demand "
              "from ThML source."),
          True)

    # Judged by proportion, not by presence: a sentence that cites a URL is
    # still a sentence, and dropping it would silently edit the author.
    check("a sentence that happens to cite a URL is not apparatus",
          reformation.is_reference_apparatus(
              "Spurgeon's sermons were collected and published weekly for "
              "nearly forty years, and the whole run is now readable at "
              "http://www.ccel.org, which is a mercy to anyone without a "
              "library of Victorian octavos to hand."),
          False)

    check("ordinary prose is not apparatus",
          reformation.is_reference_apparatus(
              "Blessed are they that keep his testimonies."),
          False)


def test_front_matter():
    print("\nfront matter")

    # Front matter is a contiguous prefix. Taking the *last* match inside a
    # window instead meant a short work's closing "Indexes" segment discarded
    # everything before it: Owen's Gospel Grounds and Evidences lost all four
    # of its chapters, and his Review of Grotius was ingested as five units of
    # the index's link table.
    parts = ["Title: A Work", "Table of Contents", "Chapter I. The body of it "
             + "x" * 400, "Indexes", "Index of Scripture References"]
    kept = parts[reformation.first_body_segment(parts):]
    check("the body survives an index later in the file",
          kept[0].startswith("Chapter I."), True)

    check("a contents page ahead of the work is still dropped",
          reformation.first_body_segment(["Title: A Work", "CONTENTS", "Body"]),
          2)

    check("a work with no front matter loses only its header",
          reformation.first_body_segment(["Title: A Work", "Body", "More"]), 1)


def test_psalm_pages():
    print("\ntreasury page attribution")

    # A psalm's opening page carries the running head *and* the heading, both
    # reading "Psalm 119". A greedy strip of anything that looks like furniture
    # swallows the heading too, and every psalm in the book goes undetected.
    check("stripping a page leaves the heading beneath the running head",
          treasury.strip_page("Psalm 119\n\n352\n\nPsalm 119\nPREFACE.\nAt "
                              "length I am able").splitlines()[0],
          "Psalm 119")

    check("stripping an ordinary page leaves the prose",
          treasury.strip_page("Psalm 1\n\n13\n\nby the gospel. He that hopes"),
          "by the gospel. He that hopes")

    # Psalm 119 opens with a preface rather than the usual navigation block, so
    # keying on headings loses the longest psalm in the Psalter. Running heads
    # are the one uniform feature the document has.
    pages = treasury.pages_by_psalm(
        "front matter, no head\x0cPsalm 118\n\n351\n\nlast of it"
        "\x0cPsalm 119\n\n352\n\nPsalm 119\nPREFACE.\x0cPsalm 119\n\n353\n\nmore")
    check("pages group under the psalm in their running head",
          sorted(pages), [118, 119])
    check("a psalm's pages are joined in order",
          "PREFACE." in pages[119] and "more" in pages[119], True)


def test_ledger_keys():
    """Two sources from one document must be two ledger entries.

    They were one for months. `current_ledger` grouped by source id and then
    wrote each row into a dict keyed by `source_url`, so the five parts of the
    Summa collapsed into whichever came last, and eight of 653 sources sat
    outside the check that guards against id reassignment. It shipped because a
    dict that loses keys returns a smaller dict rather than raising, and nothing
    counted. This is the fixed shape and the count that would have caught it.
    """
    conn = sqlite3.connect(":memory:")
    conn.executescript("""
        CREATE TABLE sources (id INTEGER PRIMARY KEY, source_url TEXT, title TEXT);
        CREATE TABLE content_units (id INTEGER PRIMARY KEY, source_id INTEGER,
                                    content TEXT);
        INSERT INTO sources VALUES (1, 'http://one/doc', 'Part I'),
                                   (2, 'http://one/doc', 'Part II'),
                                   (3, '',               'No url at all');
        INSERT INTO content_units VALUES (1, 1, 'alpha'), (2, 2, 'beta'),
                                         (3, 3, 'gamma');
    """)
    ledger = build_packs.current_ledger(conn)

    check("a shared url yields one entry per source",
          sorted(ledger["sources"]), ["1", "2", "3"])
    # Keyed by url, these two were indistinguishable; the hashes differ, so the
    # collapse silently discarded a real fact about ids 1 and 2.
    check("each entry keeps its own footprint",
          ledger["sources"]["1"]["hash"] != ledger["sources"]["2"]["hash"], True)
    # A source with no url used to be skipped outright. Source id needs no url.
    check("a source without a url is still watched",
          ledger["sources"]["3"]["count"], 1)
    check("the format is stamped so an old ledger cannot be misread",
          ledger["format"], build_packs.LEDGER_FORMAT)
    conn.close()


def main():
    for test in (test_creators, test_public_domain, test_display_matter,
                 test_titles, test_containment, test_reference_apparatus,
                 test_front_matter, test_psalm_pages,
                 test_ledger_keys):
        test()

    print()
    if FAILURES:
        print(f"{len(FAILURES)} failed:\n")
        for failure in FAILURES:
            print(f"  - {failure}")
        sys.exit(1)
    print("all passed")


if __name__ == "__main__":
    main()
