#!/usr/bin/env bash
# Real-world client compatibility test: drive translate's HTTP server with
# the actual production client libraries used to talk to DeepL,
# LibreTranslate, and Google. Proves drop-in compatibility, not just
# byte-stable response shapes.
#
# Dependencies installed on demand into a venv (./.build/realclients-venv):
#   deepl                -- official DeepL Python SDK
#   libretranslatepy     -- community LibreTranslate client
#   google-cloud-translate
#   requests
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/translate"
VENV="$ROOT/.build/realclients-venv"

if [ ! -x "$BIN" ]; then
    echo "error: $BIN not built. Run 'swift build -c release' first." >&2
    exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 required" >&2
    exit 2
fi

if [ ! -d "$VENV" ]; then
    echo "==> creating venv at $VENV"
    python3 -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"

echo "==> installing client libraries"
python3 -m pip install --quiet --upgrade pip >/dev/null
python3 -m pip install --quiet \
    'deepl>=1.16' \
    'libretranslatepy>=2.1' \
    'requests>=2.31' \
    'google-cloud-translate>=3.0' \
    >/dev/null

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
echo "==> starting translate --serve on port $PORT"
"$BIN" --serve --port "$PORT" --quiet >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
    if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
    sleep 0.1
done

# Pass the port to the Python harness via env var
PORT="$PORT" python3 "$ROOT/scripts/integration-real-clients.py"
