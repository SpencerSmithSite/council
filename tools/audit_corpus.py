#!/usr/bin/env python3
"""Classify every content unit in the bundled corpus by provenance.

Read-only. Produces a report, and with --json a machine-readable dump that a
later migration can act on. Nothing here modifies the database.

The corpus mixes genuine primary text (real translations of Augustine, the
Didache, the Philokalia) with auto-generated filler that is presented and cited
identically. This scores each unit against a set of signals so the two can be
told apart before anything is deleted.

Usage:
    python3 tools/audit_corpus.py                    # summary report
    python3 tools/audit_corpus.py --samples 5        # with example units
    python3 tools/audit_corpus.py --json out.json    # dump per-unit verdicts
"""

import argparse
import json
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent.parent / "assets" / "theology.db"

# Titles the generator emitted by reshuffling words of the source name.
# e.g. "On the Creed That Is the Nicene" / "On the Nicene That the Creed Professes"
TEMPLATE_TITLE_RE = re.compile(
    r"^On the .+ (?:That Is|That the|as the|and the|Who Is|Which Is) ",
    re.IGNORECASE,
)

# The generator's most distinctive tic: recursive relative clauses that restate
# the subject instead of saying anything. Real prose almost never stacks these.
#   "The creed that is the Nicene is the Nicene that the Council who is the
#    Nicaea establishes -- the Nicene that the Father who is the creator reveals"
DEGENERATE_CHAIN_RE = re.compile(r"\b(?:who|that|which) is the\b", re.IGNORECASE)
DEGENERATE_CHAIN_THRESHOLD = 3

# Anaphora is a real rhetorical device, so this threshold is set high enough to
# catch mechanical repetition without flagging genuine homiletic style.
REPETITION_THRESHOLD = 4
REPETITION_MAX_LEN = 2500


def max_ngram_repeat(text, sizes=(3, 4)):
    """Highest repeat count of any n-gram in the text."""
    words = re.findall(r"[a-z']+", text.lower())
    best = 0
    for n in sizes:
        counts = Counter(
            " ".join(words[i : i + n]) for i in range(len(words) - n + 1)
        )
        if counts:
            best = max(best, max(counts.values()))
    return best

# Scraper furniture from New Advent and similar sources.
BOILERPLATE_MARKERS = (
    "new advent",
    "kevin knight",
    "nihil obstat",
    "imprimatur",
    "contact information",
    "this page",
    "transcribed by",
    "for the sake of the poor souls",
)

BOILERPLATE_TITLES = {"about this page", "about this page.", "footer", "credits"}

# Source-level unit counts the generator produced. 400 sources have exactly 9
# units and 82 have exactly 7 — real works do not cluster like that.
TEMPLATE_UNIT_COUNTS = {7, 9}

PRIMARY = "primary_text"
SUMMARY = "summary"
BOILERPLATE = "boilerplate"
UNKNOWN = "unknown"


def normalized_title_tokens(title):
    """Word multiset of a title, for detecting reshuffled variants."""
    words = re.findall(r"[a-z]+", (title or "").lower())
    stop = {"on", "the", "that", "is", "a", "of", "and", "as", "who", "which"}
    return frozenset(w for w in words if w not in stop)


def load_units(conn):
    return conn.execute(
        """
        SELECT cu.id, cu.source_id, cu.title, cu.content AS content_plain, cu.unit_type,
               s.title AS source_title
        FROM content_units cu
        LEFT JOIN sources s ON cu.source_id = s.id
        ORDER BY cu.source_id, cu.sequence
        """
    ).fetchall()


def classify(units):
    """Return {unit_id: (verdict, [reasons])}."""
    by_source = defaultdict(list)
    for u in units:
        by_source[u["source_id"]].append(u)

    # Content duplicated anywhere in the corpus.
    content_counts = Counter((u["content_plain"] or "").strip() for u in units)

    verdicts = {}

    for source_id, source_units in by_source.items():
        unit_count = len(source_units)
        title_counts = Counter((u["title"] or "").strip().lower() for u in source_units)

        # Titles within this source that are word-shuffles of each other.
        token_counts = Counter(normalized_title_tokens(u["title"]) for u in source_units)

        for u in source_units:
            reasons = []
            title = (u["title"] or "").strip()
            content = (u["content_plain"] or "").strip()
            lower_content = content.lower()

            # --- boilerplate ---
            if title.lower() in BOILERPLATE_TITLES:
                reasons.append("boilerplate title")
            marker_hits = [m for m in BOILERPLATE_MARKERS if m in lower_content]
            # A single weak marker inside a long passage is likely a real
            # mention; require either a strong signal or a short unit.
            if marker_hits and (len(content) < 1200 or len(marker_hits) > 1):
                reasons.append(f"boilerplate markers: {', '.join(marker_hits[:3])}")

            if reasons:
                verdicts[u["id"]] = (BOILERPLATE, reasons)
                continue

            # --- generated filler ---
            if TEMPLATE_TITLE_RE.match(title):
                reasons.append("templated title pattern")

            if len(DEGENERATE_CHAIN_RE.findall(content)) >= DEGENERATE_CHAIN_THRESHOLD:
                reasons.append("degenerate relative-clause chain")

            if (
                content
                and len(content) < REPETITION_MAX_LEN
                and max_ngram_repeat(content) >= REPETITION_THRESHOLD
            ):
                reasons.append("mechanical phrase repetition")

            tokens = normalized_title_tokens(title)
            if tokens and token_counts[tokens] > 1:
                reasons.append("title is a word-shuffle of a sibling unit")

            if title_counts[title.lower()] > 1:
                reasons.append("duplicate title within source")

            if content and content_counts[content] > 1:
                reasons.append("content duplicated elsewhere in corpus")

            if unit_count in TEMPLATE_UNIT_COUNTS:
                reasons.append(f"source has templated unit count ({unit_count})")

            # The unit-count signal is weak on its own — a real short work can
            # have 9 sections. Require it to corroborate something else.
            strong = [r for r in reasons if not r.startswith("source has templated")]

            if strong and reasons != strong:
                verdicts[u["id"]] = (SUMMARY, reasons)
            elif len(strong) >= 2:
                verdicts[u["id"]] = (SUMMARY, reasons)
            elif strong:
                verdicts[u["id"]] = (UNKNOWN, reasons)
            else:
                verdicts[u["id"]] = (PRIMARY, [])

    return verdicts


def report(units, verdicts, sample_count):
    by_id = {u["id"]: u for u in units}
    counts = Counter(v for v, _ in verdicts.values())
    total = len(units)

    print(f"Corpus audit — {total} content units\n")
    print(f"{'verdict':<16}{'units':>8}{'share':>9}")
    print("-" * 33)
    for verdict in (PRIMARY, SUMMARY, UNKNOWN, BOILERPLATE):
        n = counts.get(verdict, 0)
        print(f"{verdict:<16}{n:>8}{n / total:>8.1%}")
    print()

    reason_counts = Counter()
    for _, reasons in verdicts.values():
        for r in reasons:
            reason_counts[re.sub(r":.*", "", r)] += 1

    print("Signals fired:")
    for reason, n in reason_counts.most_common():
        print(f"  {n:>6}  {reason}")
    print()

    # Which sources are worst affected.
    per_source = defaultdict(Counter)
    for uid, (verdict, _) in verdicts.items():
        per_source[by_id[uid]["source_title"]][verdict] += 1

    fully_generated = [
        (src, c) for src, c in per_source.items() if c.get(PRIMARY, 0) == 0
    ]
    print(
        f"Sources with zero primary-text units: "
        f"{len(fully_generated)} of {len(per_source)}"
    )
    for src, c in sorted(fully_generated, key=lambda kv: -sum(kv[1].values()))[:10]:
        print(f"  {sum(c.values()):>4} units  {src}")
    print()

    if sample_count:
        for verdict in (SUMMARY, BOILERPLATE):
            print(f"--- sample: {verdict} ---")
            shown = 0
            for uid, (v, reasons) in verdicts.items():
                if v != verdict:
                    continue
                u = by_id[uid]
                print(f"  [{uid}] {u['source_title']} — {u['title']}")
                print(f"        why: {'; '.join(reasons)}")
                print(f"        {(u['content_plain'] or '')[:160]!r}")
                shown += 1
                if shown >= sample_count:
                    break
            print()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--samples", type=int, default=0)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    if not args.db.exists():
        sys.exit(f"database not found: {args.db}")

    conn = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    units = load_units(conn)
    verdicts = classify(units)
    report(units, verdicts, args.samples)

    if args.json:
        payload = [
            {"id": uid, "verdict": v, "reasons": r} for uid, (v, r) in verdicts.items()
        ]
        args.json.write_text(json.dumps(payload, indent=2) + "\n")
        print(f"wrote {len(payload)} verdicts to {args.json}")


if __name__ == "__main__":
    main()
