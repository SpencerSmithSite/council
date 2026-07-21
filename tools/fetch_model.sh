#!/usr/bin/env bash
# Fetch the embedding model weights.
#
# Kept out of git deliberately: the file is ~22 MB and the repository already
# carries a 53 MB compressed corpus. It is byte-identical on every fetch, so
# committing it would only add a large blob to history for no benefit.
#
# The same file serves both sides — tools/build_embeddings.py precomputes the
# corpus vectors with it, and the app ships it to encode queries. Document and
# query vectors must come from one model, so do not substitute another.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/assets/model"
BASE="https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main"

mkdir -p "$DIR"
echo "fetching all-MiniLM-L6-v2 (quantized) -> $DIR"
curl -fsSL -o "$DIR/model_quantized.onnx" "$BASE/onnx/model_quantized.onnx"
curl -fsSL -o "$DIR/tokenizer.json"       "$BASE/tokenizer.json"
ls -lh "$DIR"
