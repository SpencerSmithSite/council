#!/usr/bin/env python3
"""Precompute a semantic embedding for every chunk.

FTS5 is lexical: "how is a person saved?" shares no words with "justification by
faith" and so does not match it. Embeddings fix that, and the vectors can be
computed once at build time and shipped — only the query needs encoding at
runtime.

The model here (all-MiniLM-L6-v2, quantized) is the *same file the app ships*.
That is not incidental: document and query vectors must come from one model, so
precomputing with a different or unquantized model would silently degrade every
search.

Vectors are L2-normalized then quantized to int8, which makes cosine similarity
a plain dot product and costs 384 bytes per chunk instead of 1,536.

    python3 tools/build_embeddings.py            # report
    python3 tools/build_embeddings.py --write    # compute and store
"""

import argparse
import sqlite3
import sys
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "assets" / "theology.db"
MODEL_DIR = ROOT / "assets" / "model"

DIMS = 384
MAX_TOKENS = 256
BATCH = 64

SCHEMA = """
CREATE TABLE IF NOT EXISTS chunk_embeddings (
    chunk_id INTEGER PRIMARY KEY,
    vector BLOB NOT NULL,
    FOREIGN KEY (chunk_id) REFERENCES content_chunks(id)
);
"""


def load_model():
    tokenizer = Tokenizer.from_file(str(MODEL_DIR / "tokenizer.json"))
    tokenizer.enable_truncation(max_length=MAX_TOKENS)
    tokenizer.enable_padding(length=None)

    session = ort.InferenceSession(
        str(MODEL_DIR / "model_quantized.onnx"),
        providers=["CPUExecutionProvider"],
    )
    return tokenizer, session


def embed(tokenizer, session, texts):
    """Mean-pooled, L2-normalized embeddings for a batch of texts."""
    encodings = tokenizer.encode_batch(texts)

    ids = np.array([e.ids for e in encodings], dtype=np.int64)
    mask = np.array([e.attention_mask for e in encodings], dtype=np.int64)
    types = np.zeros_like(ids)

    hidden = session.run(
        None,
        {"input_ids": ids, "attention_mask": mask, "token_type_ids": types},
    )[0]

    # Mean-pool over real tokens only — padding must not drag the vector.
    weights = mask[..., None].astype(np.float32)
    pooled = (hidden * weights).sum(axis=1) / np.clip(weights.sum(axis=1), 1e-9, None)

    norms = np.linalg.norm(pooled, axis=1, keepdims=True)
    return pooled / np.clip(norms, 1e-9, None)


def quantize(vectors):
    """Normalized floats in [-1, 1] -> int8, so cosine becomes a dot product."""
    return np.clip(np.rint(vectors * 127.0), -127, 127).astype(np.int8)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DB_PATH)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--limit", type=int, help="only process N chunks")
    args = parser.parse_args()

    mode = "" if args.write else "?mode=ro"
    conn = sqlite3.connect(f"file:{args.db}{mode}", uri=True)

    # Chunks are stored as offsets; slice the parent unit to get the text.
    rows = conn.execute(
        """SELECT c.id, substr(cu.content, c.char_start + 1, c.char_end - c.char_start)
           FROM content_chunks c
           JOIN content_units cu ON c.content_unit_id = cu.id
           ORDER BY c.id"""
    ).fetchall()
    if args.limit:
        rows = rows[: args.limit]

    print(f"{len(rows)} chunks, {DIMS} dims int8 "
          f"-> {len(rows) * DIMS / 1048576:.1f} MB")

    if not args.write:
        print("\ndry run — pass --write to compute and store")
        return

    tokenizer, session = load_model()
    conn.executescript(SCHEMA)
    conn.execute("DELETE FROM chunk_embeddings")

    started = time.monotonic()
    for offset in range(0, len(rows), BATCH):
        batch = rows[offset : offset + BATCH]
        vectors = quantize(embed(tokenizer, session, [t for _, t in batch]))

        conn.executemany(
            "INSERT INTO chunk_embeddings (chunk_id, vector) VALUES (?, ?)",
            [(cid, vec.tobytes()) for (cid, _), vec in zip(batch, vectors)],
        )

        done = offset + len(batch)
        if done % (BATCH * 25) == 0 or done == len(rows):
            rate = done / (time.monotonic() - started)
            remaining = (len(rows) - done) / rate
            print(f"  {done}/{len(rows)}  {rate:.0f}/s  "
                  f"~{remaining / 60:.1f} min left", flush=True)
            conn.commit()

    conn.commit()
    conn.execute("VACUUM")

    stored = conn.execute("SELECT count(*) FROM chunk_embeddings").fetchone()[0]
    print(f"stored {stored} embeddings in {(time.monotonic() - started) / 60:.1f} min")
    conn.close()


if __name__ == "__main__":
    main()
