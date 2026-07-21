#!/usr/bin/env python3
"""Show what retrieval actually returns for a question.

Mirrors what the app does — FTS5 for lexical, embeddings for semantic, fused by
reciprocal rank, best chunk per unit — so retrieval quality can be inspected
without running the app or spending an API call. The point is to see whether
the corpus can answer a question at all, separately from whether the model
words it well.

    python3 tools/query_probe.py "What did Aquinas say about the Virgin Mary?"
    python3 tools/query_probe.py --suite      # run the standing question set
"""

import argparse
import re
import sqlite3
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_embeddings import load_model, embed  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "assets" / "theology.db"

RRF_K = 60.0

# Questions the app is meant to answer well. Each names what it is testing, so
# a weak result points at a specific gap rather than a vague impression.
SUITE = [
    ("What are the differences between Catholic and Lutheran beliefs about baptism?",
     "comparative across traditions"),
    ("What did Saint Thomas Aquinas say about the Virgin Mary?",
     "author-scoped"),
    ("What topics were covered at the Council of Trent?",
     "source-scoped enumeration"),
    ("How is a person saved?", "doctrinal, vocabulary mismatch"),
    ("Is the Son equal to the Father?", "doctrinal, christology"),
]


def fts_query(text):
    cleaned = re.sub(r"[^\w\s]", " ", text)
    terms = [t for t in cleaned.split() if len(t) > 2]
    return " OR ".join(f"{t}*" for t in terms)


def lexical(conn, question, limit=30):
    try:
        rows = conn.execute(
            """SELECT cu.id FROM content_fts f
               JOIN content_units cu ON f.rowid = cu.id
               WHERE content_fts MATCH ? ORDER BY f.rank LIMIT ?""",
            (fts_query(question), limit),
        ).fetchall()
        return [r[0] for r in rows]
    except sqlite3.OperationalError:
        return []


def load_index(conn):
    rows = conn.execute(
        """SELECT e.vector, c.content_unit_id, c.char_start, c.char_end
           FROM chunk_embeddings e JOIN content_chunks c ON e.chunk_id = c.id"""
    ).fetchall()
    matrix = (
        np.frombuffer(b"".join(r[0] for r in rows), dtype=np.int8)
        .reshape(len(rows), 384)
        .astype(np.float32)
        / 127.0
    )
    meta = [(r[1], r[2], r[3]) for r in rows]
    return matrix, meta


def semantic(matrix, meta, tokenizer, session, question, limit=30):
    scores = matrix @ embed(tokenizer, session, [question])[0]
    order = np.argsort(-scores)

    best, seen = [], set()
    for i in order:
        unit_id, start, end = meta[i]
        if unit_id in seen:
            continue
        seen.add(unit_id)
        best.append((unit_id, start, end, float(scores[i])))
        if len(best) == limit:
            break
    return best


def fuse(lex, sem, limit=6):
    scores = {}
    for rank, unit_id in enumerate(lex):
        scores[unit_id] = scores.get(unit_id, 0) + 1 / (RRF_K + rank + 1)
    for rank, (unit_id, *_rest) in enumerate(sem):
        scores[unit_id] = scores.get(unit_id, 0) + 1 / (RRF_K + rank + 1)

    ordered = sorted(scores, key=lambda u: (-scores[u], u))[:limit]
    spans = {u: (s, e) for u, s, e, _ in sem}
    return [(u, spans.get(u)) for u in ordered]


def diversify(conn, ranked, limit=6, max_per_source=2, max_per_tradition=None):
    """Mirror of HybridRanker.diversify — see that class for the rationale.

    Kept in step with the Dart deliberately: a ranking change has to be
    checkable against the real corpus, not only in unit tests.
    """
    cap = max_per_tradition or -(-limit // 2)
    selected, deferred = [], []
    per_source, per_tradition = {}, {}

    for unit_id, span in ranked:
        row = conn.execute(
            """SELECT s.title, t.name FROM content_units cu
               LEFT JOIN sources s ON cu.source_id = s.id
               LEFT JOIN traditions t ON s.tradition_id = t.id
               WHERE cu.id = ?""",
            (unit_id,),
        ).fetchone()
        source, tradition = row if row else (None, None)

        if (len(selected) >= limit
                or per_source.get(source, 0) >= max_per_source
                or per_tradition.get(tradition, 0) >= cap):
            deferred.append((unit_id, span))
            continue

        selected.append((unit_id, span))
        per_source[source] = per_source.get(source, 0) + 1
        per_tradition[tradition] = per_tradition.get(tradition, 0) + 1

    for item in deferred:
        if len(selected) >= limit:
            break
        selected.append(item)

    return selected


def describe(conn, unit_id, span):
    row = conn.execute(
        """SELECT s.title, s.author, t.name, cu.title, cu.content
           FROM content_units cu
           LEFT JOIN sources s ON cu.source_id = s.id
           LEFT JOIN traditions t ON s.tradition_id = t.id
           WHERE cu.id = ?""",
        (unit_id,),
    ).fetchone()
    source, author, tradition, title, content = row
    text = content[span[0]:span[1]] if span else content[:1200]
    return source, author, tradition, title, " ".join(text.split())


def run(conn, matrix, meta, tokenizer, session, question, label=None):
    print(f"\n{'=' * 78}\nQ: {question}")
    if label:
        print(f"   (tests: {label})")

    lex = lexical(conn, question)
    sem = semantic(matrix, meta, tokenizer, session, question)
    results = diversify(conn, fuse(lex, sem, limit=40))

    traditions = set()
    for unit_id, span in results:
        source, author, tradition, title, text = describe(conn, unit_id, span)
        traditions.add(tradition or "—")
        byline = f" ({author})" if author else ""
        print(f"\n  • {source}{byline}")
        print(f"    {tradition or '—'} · {title or ''}"[:100])
        print(f"    {text[:190]}…")

    print(f"\n  traditions represented: {', '.join(sorted(traditions))}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("question", nargs="?")
    parser.add_argument("--suite", action="store_true")
    parser.add_argument("--db", type=Path, default=DB_PATH)
    args = parser.parse_args()

    conn = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    matrix, meta = load_index(conn)
    tokenizer, session = load_model()

    if args.suite:
        for question, label in SUITE:
            run(conn, matrix, meta, tokenizer, session, question, label)
    elif args.question:
        run(conn, matrix, meta, tokenizer, session, args.question)
    else:
        parser.error("give a question or --suite")


if __name__ == "__main__":
    main()
