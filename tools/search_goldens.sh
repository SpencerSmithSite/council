#!/usr/bin/env bash
# Verify or regenerate the golden search fixtures in shared/golden/search/.
#
#   tools/search_goldens.sh            # assert the Dart code reproduces search.json
#   tools/search_goldens.sh --update   # rewrite search.json from the Dart code
#
# Runs integration_test/search_golden_test.dart on macOS against the bundled
# core corpus. The macOS debug build is sandboxed, so the test can neither read
# nor write the repository: this script serves the fixture to it over loopback
# HTTP for verification, and in update mode decodes the fixture the test prints
# (gzip + base64, between SEARCH_GOLDEN_BEGIN/END markers) back into the file.
#
# FLUTTER overrides the toolchain; it defaults to the CI-pinned one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER="${FLUTTER:-$HOME/development/flutter-3.44.8/bin/flutter}"
GOLDEN_DIR="$ROOT/shared/golden/search"
GOLDEN="$GOLDEN_DIR/search.json"
TEST=integration_test/search_golden_test.dart

if [[ ! -f "$ROOT/assets/model/model_quantized.onnx" ]]; then
  echo "assets/model/model_quantized.onnx is missing; run tools/fetch_model.sh" >&2
  exit 1
fi

LOG="$(mktemp -t search_goldens)"
cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT

cd "$ROOT"

if [[ "${1:-}" == "--update" ]]; then
  "$FLUTTER" test "$TEST" -d macos --dart-define=UPDATE_GOLDENS=true 2>&1 | tee "$LOG"
  if ! grep -q 'SEARCH_GOLDEN_END' "$LOG"; then
    echo "the test did not print a fixture; see the output above" >&2
    exit 1
  fi
  mkdir -p "$GOLDEN_DIR"
  sed -n '/SEARCH_GOLDEN_BEGIN/,/SEARCH_GOLDEN_END/p' "$LOG" \
    | grep -o 'SEARCH_GOLDEN:[A-Za-z0-9+/=]*' \
    | sed 's/^SEARCH_GOLDEN://' \
    | tr -d '\n' \
    | base64 --decode \
    | gunzip > "$GOLDEN.tmp"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$GOLDEN.tmp"
  mv "$GOLDEN.tmp" "$GOLDEN"
  echo "wrote $GOLDEN ($(wc -c < "$GOLDEN" | tr -d ' ') bytes)"
  exit 0
fi

if [[ ! -f "$GOLDEN" ]]; then
  echo "$GOLDEN does not exist; run with --update first" >&2
  exit 1
fi

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$GOLDEN_DIR" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -fs -o /dev/null "http://127.0.0.1:$PORT/search.json" && break
  sleep 0.1
done

"$FLUTTER" test "$TEST" -d macos \
  --dart-define=SEARCH_GOLDEN_URL="http://127.0.0.1:$PORT/search.json"
