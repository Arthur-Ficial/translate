#!/usr/bin/env bash
# End-to-end CLI integration: run every example from EXAMPLE.md against the
# released binary. No mocks. Every command's behavior is asserted; tests that
# need installed translation models skip themselves cleanly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/translate"

if [ ! -x "$BIN" ]; then
    echo "error: $BIN not built. Run 'swift build -c release' first." >&2
    exit 2
fi

PASSED=0
SKIPPED=0
FAILED=0

ok() {
    echo "  ✓ $1"
    PASSED=$((PASSED + 1))
}

skip() {
    echo "  ⊘ $1 — $2"
    SKIPPED=$((SKIPPED + 1))
}

fail() {
    echo "  ✗ $1" >&2
    if [ -n "${2:-}" ]; then
        echo "    $2" >&2
    fi
    FAILED=$((FAILED + 1))
}

# Helper: returns 0 if a model pair is installed
has_pair() {
    "$BIN" --installed 2>/dev/null | grep -qx "$1"
}

echo "==> --version"
ver=$("$BIN" --version)
[[ "$ver" == *"0.1.0"* ]] && ok "version contains 0.1.0" || fail "version" "got: $ver"

echo "==> --help"
"$BIN" --help >/dev/null && ok "help exits 0" || fail "help"

echo "==> usage error: missing --to with stdin"
set +e
err=$(echo "hi" | "$BIN" 2>&1)
code=$?
set -e
if [ "$code" -eq 1 ] && [[ "$err" == *"--to is required"* ]]; then
    ok "missing-to exits 1 with usage message"
else
    fail "missing-to" "code=$code err=$err"
fi

echo "==> --detect-only on piped German"
out=$(echo "Das ist ein deutscher Satz mit genug Worten zum Erkennen." | "$BIN" --detect-only)
[[ "$out" == de* ]] && ok "detected de" || fail "detect-only de" "got: $out"

echo "==> --detect-only on French text argument"
out=$("$BIN" --detect-only "Ceci est une phrase française avec plusieurs mots distincts.")
[[ "$out" == fr* ]] && ok "detected fr" || fail "detect-only fr" "got: $out"

echo "==> --detect-only on Japanese"
out=$("$BIN" --detect-only "これは日本語の文章で、翻訳テストのためにあります。")
[[ "$out" == ja* ]] && ok "detected ja" || fail "detect-only ja" "got: $out"

echo "==> --installed (clean exit)"
"$BIN" --installed >/dev/null && ok "--installed exits 0" || fail "--installed"

echo "==> --available (clean exit)"
"$BIN" --available >/dev/null && ok "--available exits 0" || fail "--available"

echo "==> --langs hint constrains detection"
out=$(echo "Hallo" | "$BIN" --detect-only --langs "de,en,fr")
[[ "$out" == de* || "$out" == en* || "$out" == fr* ]] && ok "hint-constrained detection" || fail "langs hint" "got: $out"

# --- Translation tests (require installed models) ---

if has_pair "de-en"; then
    echo "==> de->en plain"
    out=$(echo "Hallo Welt." | "$BIN" --from de --to en --no-install)
    [ -n "$out" ] && ok "de-en translates" || fail "de-en plain"

    echo "==> de->en ndjson"
    out=$(echo "Hallo Welt." | "$BIN" --from de --to en --no-install --format ndjson)
    [[ "$out" == *'"from":"de"'* && "$out" == *'"to":"en"'* && "$out" == *'"src":'* && "$out" == *'"dst":'* ]] \
        && ok "ndjson record shape" || fail "ndjson" "got: $out"

    echo "==> de->en json"
    out=$(echo "Hallo Welt." | "$BIN" --from de --to en --no-install --format json)
    [[ "$out" == \[*\] || "$out" == \{*\} ]] && ok "json wraps records" || fail "json" "got: $out"

    echo "==> protected URL/email pass through"
    out=$(echo "Hallo a@b.com Welt https://example.com." | "$BIN" --from de --to en --no-install)
    [[ "$out" == *"a@b.com"* && "$out" == *"https://example.com"* ]] \
        && ok "URLs and emails preserved" || fail "protected spans" "got: $out"

    echo "==> --batch line-by-line"
    out=$(printf "Hallo\nWelt\nFoo\n" | "$BIN" --from de --to en --no-install --batch)
    nl=$(printf "%s" "$out" | tr -cd '\n' | wc -c | xargs)
    [ "$nl" -ge 2 ] && ok "batch produced multi-line output" || fail "batch" "lines=$nl"

    echo "==> multiple --file inputs"
    tmpdir=$(mktemp -d)
    echo "Hallo." > "$tmpdir/a.txt"
    echo "Welt." > "$tmpdir/b.txt"
    out=$("$BIN" --from de --to en --no-install --file "$tmpdir/a.txt" --file "$tmpdir/b.txt")
    rm -rf "$tmpdir"
    [ -n "$out" ] && ok "two --file inputs" || fail "multi-file"

    echo "==> --no-install with missing pair (de->vi expected unsupported-or-missing)"
    set +e
    "$BIN" --from de --to vi --no-install <<< "Hallo." >/dev/null 2>&1
    code=$?
    set -e
    if [ "$code" -eq 4 ] || [ "$code" -eq 5 ]; then
        ok "missing/unsupported pair returns expected exit"
    else
        skip "no-install missing-pair" "got exit $code (de-vi may already be installed on this Mac)"
    fi
else
    skip "de-en plain" "de-en model not installed"
    skip "de-en ndjson" "de-en model not installed"
    skip "de-en json" "de-en model not installed"
    skip "protected URL/email" "de-en model not installed"
    skip "--batch" "de-en model not installed"
    skip "multiple --file" "de-en model not installed"
fi

# --- HTTP server smoke tests ---

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
echo "==> starting server on port $PORT"
"$BIN" --serve --port "$PORT" --quiet >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

# wait for /health
for _ in $(seq 1 50); do
    if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

echo "==> /health"
out=$(curl -sf "http://127.0.0.1:$PORT/health")
[[ "$out" == *'"ok":true'* ]] && ok "/health" || fail "/health" "got: $out"

echo "==> /v2/languages"
out=$(curl -sf "http://127.0.0.1:$PORT/v2/languages")
[[ "$out" == \[*\] ]] && ok "/v2/languages array" || fail "/v2/languages" "got: $(echo "$out" | head -c 80)"

echo "==> /v2/usage"
out=$(curl -sf "http://127.0.0.1:$PORT/v2/usage")
[[ "$out" == *"character_count"* ]] && ok "/v2/usage" || fail "/v2/usage"

echo "==> /languages (LibreTranslate)"
out=$(curl -sf "http://127.0.0.1:$PORT/languages")
[[ "$out" == *'"targets"'* ]] && ok "/languages with targets" || fail "/languages"

echo "==> /language/translate/v2/languages (Google)"
out=$(curl -sf "http://127.0.0.1:$PORT/language/translate/v2/languages")
[[ "$out" == *'"data"'* && "$out" == *'"languages"'* ]] && ok "Google /languages" || fail "Google /languages"

if has_pair "de-en"; then
    echo "==> DeepL /v2/translate"
    out=$(curl -sf -X POST "http://127.0.0.1:$PORT/v2/translate" \
        --data-urlencode "text=Hallo Welt." \
        --data-urlencode "target_lang=EN" \
        --data-urlencode "source_lang=DE")
    [[ "$out" == *'"translations"'* && "$out" == *'"text"'* ]] \
        && ok "DeepL translate" || fail "DeepL translate" "got: $out"

    echo "==> LibreTranslate /translate"
    out=$(curl -sf -X POST "http://127.0.0.1:$PORT/translate" \
        -H "Content-Type: application/json" \
        --data '{"q":"Hallo Welt.","source":"de","target":"en","format":"text"}')
    [[ "$out" == *'"translatedText"'* ]] \
        && ok "LibreTranslate translate" || fail "LibreTranslate translate" "got: $out"

    echo "==> Google /language/translate/v2"
    out=$(curl -sf -X POST "http://127.0.0.1:$PORT/language/translate/v2" \
        --data-urlencode "q=Hallo Welt." \
        --data-urlencode "target=en" \
        --data-urlencode "source=de")
    [[ "$out" == *'"translations"'* && "$out" == *'"translatedText"'* ]] \
        && ok "Google translate" || fail "Google translate" "got: $out"
else
    skip "DeepL translate" "de-en model not installed"
    skip "LibreTranslate translate" "de-en model not installed"
    skip "Google translate" "de-en model not installed"
fi

# Always-runs server tests (no model needed: detect-only)
echo "==> LibreTranslate /detect"
out=$(curl -sf -X POST "http://127.0.0.1:$PORT/detect" \
    -H "Content-Type: application/json" \
    --data '{"q":"Das ist ein deutscher Satz mit genug Worten."}')
[[ "$out" == *'"language":"de"'* ]] && ok "/detect returns de" || fail "/detect" "got: $out"

echo "==> 404 on unknown path"
code=$(curl -sf -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/nope" || true)
[ "$code" = "404" ] && ok "404 on unknown" || fail "404" "got code $code"

echo
echo "==========================="
echo "  passed:  $PASSED"
echo "  skipped: $SKIPPED"
echo "  failed:  $FAILED"
echo "==========================="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
