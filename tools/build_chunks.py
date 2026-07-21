#!/usr/bin/env python3
"""Split content units into retrieval-sized chunks.

Units are display-sized, not retrieval-sized: they average 3,153 characters but
1,431 of them exceed 6,000 and the largest is 162,014. Anything past the first
truncation window is invisible to the model today, and no single embedding can
represent a 162 KB span.

Chunks are stored as **offsets into the parent unit**, never as copied text.
Duplicating the text would add ~55 MB for no benefit — the same mistake the old
`content_plain` column made. The parent unit stays the thing that is displayed
and cited; chunks only decide which slice is retrieved and embedded.

Dry run by default.

    python3 tools/build_chunks.py            # report
    python3 tools/build_chunks.py --write    # build the table
"""

import argparse
import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "assets" / "theology.db"

# Chunk sizing. Large enough to keep an argument intact, small enough that one
# embedding meaningfully represents it, and that a handful fit any backend's
# context budget.
TARGET_CHARS = 1200
MAX_CHARS = 1800
OVERLAP_CHARS = 200

# Prefer to break at a paragraph, then a sentence, then a word.
PARAGRAPH_RE = re.compile(r"\n\s*\n")
SENTENCE_END_RE = re.compile(r"(?<=[.!?])\s+")

SCHEMA = """
CREATE TABLE IF NOT EXISTS content_chunks (
    id INTEGER PRIMARY KEY,
    content_unit_id INTEGER NOT NULL,
    sequence INTEGER NOT NULL,
    char_start INTEGER NOT NULL,
    char_end INTEGER NOT NULL,
    FOREIGN KEY (content_unit_id) REFERENCES content_units(id)
);
CREATE INDEX IF NOT EXISTS idx_chunks_unit ON content_chunks(content_unit_id);
"""


def split_points(text):
    """Candidate break offsets, best boundary first."""
    paragraphs = [m.end() for m in PARAGRAPH_RE.finditer(text)]
    sentences = [m.end() for m in SENTENCE_END_RE.finditer(text)]
    return paragraphs, sentences


def choose_break(text, start, paragraphs, sentences):
    """Pick where the chunk beginning at `start` should end.

    Walks down the boundary preferences: a paragraph break inside the window,
    then a sentence break, then a space, then a hard cut.
    """
    ideal = start + TARGET_CHARS
    hard_limit = min(start + MAX_CHARS, len(text))

    if hard_limit >= len(text):
        return len(text)

    # Best paragraph break at or before the hard limit but past the halfway
    # point, so chunks don't collapse to tiny fragments.
    floor = start + TARGET_CHARS // 2
    for candidates in (paragraphs, sentences):
        usable = [p for p in candidates if floor <= p <= hard_limit]
        if usable:
            # Closest to the target length.
            return min(usable, key=lambda p: abs(p - ideal))

    space = text.rfind(" ", floor, hard_limit)
    return space if space > floor else hard_limit


def chunk_spans(text):
    """Yield (start, end) offsets covering `text` with overlap."""
    if len(text) <= MAX_CHARS:
        yield (0, len(text))
        return

    paragraphs, sentences = split_points(text)
    start = 0
    while start < len(text):
        end = choose_break(text, start, paragraphs, sentences)
        yield (start, end)
        if end >= len(text):
            break
        # Overlap so an idea spanning a boundary is retrievable from either
        # side, but never step backwards past the start of this chunk.
        start = max(start + 1, end - OVERLAP_CHARS)


def build(conn, write):
    units = conn.execute(
        "SELECT id, content FROM content_units ORDER BY id"
    ).fetchall()

    rows = []
    for unit_id, content in units:
        text = content or ""
        for seq, (start, end) in enumerate(chunk_spans(text), 1):
            rows.append((unit_id, seq, start, end))

    lengths = [end - start for _, _, start, end in rows]
    print(f"{len(units)} units -> {len(rows)} chunks")
    print(f"  mean {sum(lengths) / len(lengths):.0f} chars, max {max(lengths)}")
    print(f"  units yielding >1 chunk: "
          f"{len({u for u, s, _, _ in rows if s > 1})}")

    over = [n for n in lengths if n > MAX_CHARS]
    if over:
        print(f"  WARNING: {len(over)} chunks exceed MAX_CHARS", file=sys.stderr)

    if not write:
        print("\ndry run — pass --write to build the table")
        return

    conn.executescript(SCHEMA)
    conn.execute("DELETE FROM content_chunks")
    conn.executemany(
        """INSERT INTO content_chunks (content_unit_id, sequence, char_start, char_end)
           VALUES (?, ?, ?, ?)""",
        rows,
    )
    conn.commit()
    conn.execute("VACUUM")
    print(f"wrote {len(rows)} chunks")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    mode = "" if args.write else "?mode=ro"
    conn = sqlite3.connect(f"file:{args.db}{mode}", uri=True)
    build(conn, args.write)
    conn.close()


if __name__ == "__main__":
    main()
