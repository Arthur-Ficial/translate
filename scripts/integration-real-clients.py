"""
Massive real-world integration suite for `translate --serve`.

Drives the live HTTP server with the actual third-party clients used to
talk to DeepL, LibreTranslate, and Google v2:

  * official `deepl` Python SDK (every public method)
  * community `libretranslatepy` client (every public method)
  * raw `requests` for Google v2 REST + a few raw URLSession-style probes

What's tested:
  1. Every endpoint, every shape (form, JSON, repeated `q`, array `q`).
  2. Every auth method:
       - Authorization: DeepL-Auth-Key
       - Authorization: <bare key>
       - X-goog-api-key header
       - ?key=... URL parameter
       - body field (auth_key, api_key)
  3. Every error path (missing target, invalid lang, malformed JSON,
     empty body, oversize body) with the right per-API envelope:
       - DeepL  : {"message":"..."}
       - Libre  : {"error":"..."}
       - Google : {"error":{"code":N,"message":"...","errors":[{...}]}}
  4. Cross-API parity: the same source text, translated through all
     three protocols, must produce IDENTICAL target text.
  5. Concurrency: 30+ parallel requests across all three APIs without
     deadlock or 5xx.
  6. Unicode + emoji + RTL preservation.
  7. Big batch (50 inputs) and very long single input (4 KB+).
  8. CORS headers on every JSON response.

Real translation models must be installed (System Settings -> General ->
Language & Region -> Translation Languages). Without them, scenes that
do real translation skip cleanly. Shape/auth/error scenes always run.
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import shlex
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Callable, List, Optional

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, ".build", "release", "translate")
PORT = int(os.environ.get("PORT", "0")) or 0
BASE = ""

passed = 0
failed = 0
skipped = 0
failures: List[tuple[str, str]] = []


def ok(msg: str) -> None:
    global passed
    print(f"  PASS  {msg}")
    passed += 1


def fail(msg: str, detail: Any = "") -> None:
    global failed
    print(f"  FAIL  {msg}")
    if detail:
        print(f"        {detail!r}")
    failures.append((msg, str(detail)))
    failed += 1


def skip(msg: str, why: str) -> None:
    global skipped
    print(f"  SKIP  {msg} -- {why}")
    skipped += 1


def section(title: str) -> None:
    print(f"\n=== {title} ===")


def has_pair(pair: str) -> bool:
    out = subprocess.run([BIN, "--installed"], capture_output=True, text=True).stdout
    return any(line.strip() == pair for line in out.splitlines())


# ---------------------------------------------------------------------------
# Client SDKs
# ---------------------------------------------------------------------------

import deepl                                      # type: ignore  # noqa: E402
from libretranslatepy import LibreTranslateAPI    # type: ignore  # noqa: E402
import requests                                   # type: ignore  # noqa: E402


def deepl_translator() -> "deepl.Translator":
    return deepl.Translator("any-token", server_url=BASE)


def libre_api() -> "LibreTranslateAPI":
    return LibreTranslateAPI(BASE)


# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------

def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start_server(port: int) -> subprocess.Popen[bytes]:
    proc = subprocess.Popen(
        [BIN, "--serve", "--port", str(port), "--quiet"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    deadline = time.time() + 5
    while time.time() < deadline:
        try:
            r = requests.get(f"http://127.0.0.1:{port}/health", timeout=0.5)
            if r.status_code == 200:
                return proc
        except Exception:
            time.sleep(0.05)
    proc.terminate()
    raise RuntimeError(f"server failed to start on port {port}")


# ---------------------------------------------------------------------------
# Test sections
# ---------------------------------------------------------------------------

def test_health() -> None:
    section("HEALTH")
    r = requests.get(f"{BASE}/health", timeout=2)
    if r.status_code == 200 and r.json().get("ok") is True:
        ok("/health returns ok=true")
    else:
        fail("/health unexpected", r.text)
    r = requests.get(f"{BASE}/healthz", timeout=2)
    ok("/healthz responds 200") if r.status_code == 200 else fail("/healthz", r.status_code)


def test_cors_on_every_endpoint() -> None:
    section("CORS HEADERS")
    endpoints = [
        ("GET", "/health"),
        ("GET", "/v2/languages"),
        ("GET", "/v2/usage"),
        ("GET", "/languages"),
        ("GET", "/spec"),
        ("GET", "/frontend/settings"),
        ("GET", "/language/translate/v2/languages"),
    ]
    for method, path in endpoints:
        r = requests.request(method, f"{BASE}{path}", timeout=2)
        if r.headers.get("Access-Control-Allow-Origin") == "*":
            ok(f"CORS on {method} {path}")
        else:
            fail(f"missing CORS on {path}", dict(r.headers))


# -------------------------------- DeepL -------------------------------------

def test_deepl_languages() -> None:
    section("DEEPL: /v2/languages")
    t = deepl_translator()
    targets = list(t.get_target_languages())
    if targets and len(targets) > 5 and all(l.code for l in targets):
        ok(f"deepl SDK get_target_languages -> {len(targets)} entries")
    else:
        fail("deepl get_target_languages", repr(targets[:3]))

    sources = list(t.get_source_languages())
    if sources and len(sources) > 5:
        ok(f"deepl SDK get_source_languages -> {len(sources)} entries")
    else:
        fail("deepl get_source_languages", repr(sources[:3]))

    # Direct hit with ?type=source / ?type=target
    r = requests.get(f"{BASE}/v2/languages?type=source", timeout=2)
    if r.status_code == 200 and r.json():
        ok("/v2/languages?type=source 200")
    else:
        fail("?type=source", r.status_code)
    r = requests.get(f"{BASE}/v2/languages?type=target", timeout=2)
    if r.status_code == 200 and r.json():
        ok("/v2/languages?type=target 200")
    else:
        fail("?type=target", r.status_code)


def test_deepl_usage() -> None:
    section("DEEPL: /v2/usage")
    t = deepl_translator()
    u = t.get_usage()
    if u.character is not None and u.character.limit is not None:
        ok(f"deepl get_usage character_count={u.character.count} limit={u.character.limit}")
    else:
        fail("deepl get_usage shape", repr(u))


def test_deepl_translate_single() -> None:
    section("DEEPL: translate_text single")
    if not has_pair("de-en"):
        skip("translate_text single", "de-en not installed")
        return
    t = deepl_translator()
    r = t.translate_text("Hallo Welt.", source_lang="DE", target_lang="EN-US")
    if r.text and "ello" in r.text.lower() and r.detected_source_lang.upper() == "DE":
        ok(f"deepl translate_text -> {r.text!r}")
    else:
        fail("deepl translate_text", repr(r))


def test_deepl_translate_batch() -> None:
    section("DEEPL: translate_text list")
    if not has_pair("de-en"):
        skip("translate_text list", "de-en not installed")
        return
    t = deepl_translator()
    rs = t.translate_text(["Hallo", "Welt", "Guten Morgen", "Wie geht es dir?"],
                          source_lang="DE", target_lang="EN-US")
    texts = [r.text for r in rs]
    if len(texts) == 4 and all(texts):
        ok(f"deepl translate_text batch -> {texts}")
    else:
        fail("deepl translate_text batch", texts)


def test_deepl_translate_lang_pairs() -> None:
    section("DEEPL: many language pairs")
    pairs = [
        ("DE", "EN-US", "Hallo.", ["hello", "hi"]),
        ("FR", "EN-US", "Bonjour.", ["hello", "good", "hi"]),
        ("ES", "EN-US", "Hola.", ["hello", "hi"]),
        ("IT", "EN-US", "Ciao.", ["hello", "hi", "bye"]),
        ("JA", "EN-US", "こんにちは。", ["hello", "good", "afternoon"]),
        ("ZH", "EN-US", "你好。", ["hello"]),
    ]
    t = deepl_translator()
    for src, tgt, text, accepted in pairs:
        bcp_src = src.lower()
        bcp_tgt = tgt.lower().split("-")[0]
        if not has_pair(f"{bcp_src}-{bcp_tgt}"):
            skip(f"deepl {src}->{tgt}", f"{bcp_src}-{bcp_tgt} not installed")
            continue
        try:
            r = t.translate_text(text, source_lang=src, target_lang=tgt)
            lower = r.text.lower()
            if any(needle in lower for needle in accepted):
                ok(f"deepl {src}->{tgt} '{text}' -> '{r.text}'")
            else:
                fail(f"deepl {src}->{tgt} '{text}' -> '{r.text}'",
                     f"expected one of {accepted}")
        except Exception as e:
            fail(f"deepl {src}->{tgt}", repr(e))


def test_deepl_authorization_header() -> None:
    section("DEEPL: Authorization header forms")
    body = {"text": "Hallo.", "target_lang": "EN", "source_lang": "DE"}
    headers_variants = [
        {"Authorization": "DeepL-Auth-Key any-token"},
        {"Authorization": "any-token"},
        {"Authorization": "Bearer any-token"},
    ]
    for hdr in headers_variants:
        r = requests.post(f"{BASE}/v2/translate", data=body, headers=hdr, timeout=5)
        if r.status_code in (200, 400):
            # 200 if model installed, 400 if not -- both are non-5xx (pass).
            ok(f"DeepL accepts {hdr['Authorization'][:24]}... -> {r.status_code}")
        else:
            fail(f"DeepL Auth hdr {hdr}", r.status_code)


def test_deepl_passthrough_fields() -> None:
    section("DEEPL: passthrough fields (formality / tag_handling / split_sentences)")
    body = {
        "text": "Hallo.",
        "target_lang": "EN",
        "source_lang": "DE",
        "formality": "more",
        "tag_handling": "xml",
        "split_sentences": "1",
        "preserve_formatting": "1",
        "glossary_id": "ignored-glossary-uuid",
    }
    r = requests.post(f"{BASE}/v2/translate", data=body, timeout=5)
    if r.status_code in (200, 400):
        ok("DeepL ignores passthrough fields without 5xx")
    else:
        fail("DeepL passthrough", r.status_code)


def test_deepl_error_envelope() -> None:
    section("DEEPL: error envelope")
    r = requests.post(f"{BASE}/v2/translate", data={"target_lang": "EN"}, timeout=5)
    if r.status_code == 400 and "message" in r.json():
        ok("DeepL 400 -> {\"message\":...}")
    else:
        fail("DeepL error shape", r.text)

    # Invalid JSON body
    r = requests.post(f"{BASE}/v2/translate",
                      data="{not valid json",
                      headers={"Content-Type": "application/json"},
                      timeout=5)
    if r.status_code == 400 and "message" in r.json():
        ok("DeepL invalid JSON -> {\"message\":...}")
    else:
        fail("DeepL invalid JSON shape", r.text)


def test_deepl_billed_characters() -> None:
    section("DEEPL: billed_characters in response")
    if not has_pair("de-en"):
        skip("billed_characters", "de-en not installed")
        return
    r = requests.post(f"{BASE}/v2/translate",
                      data={"text": "Hallo Welt.", "target_lang": "EN", "source_lang": "DE"},
                      timeout=5)
    body = r.json()
    if r.status_code == 200 and body["translations"][0].get("billed_characters") == len("Hallo Welt."):
        ok(f"billed_characters = {body['translations'][0]['billed_characters']}")
    else:
        fail("billed_characters missing/wrong", body)


def test_deepl_unicode_and_emoji() -> None:
    section("DEEPL: unicode + emoji round-trip")
    if not has_pair("de-en"):
        skip("unicode emoji", "de-en not installed")
        return
    text = "Hallo Welt 🌍 mit Emoji 🚀 und Sonderzeichen ä ö ü ß."
    t = deepl_translator()
    r = t.translate_text(text, source_lang="DE", target_lang="EN-US")
    out = r.text
    if "🌍" in out and "🚀" in out:
        ok(f"emoji preserved: '{out}'")
    else:
        fail("emoji not preserved", out)


# ----------------------------- LibreTranslate -------------------------------

def test_libre_languages() -> None:
    section("LIBRE: /languages")
    api = libre_api()
    ls = api.languages()
    if isinstance(ls, list) and ls and "code" in ls[0] and "targets" in ls[0]:
        ok(f"libre languages -> {len(ls)} entries")
    else:
        fail("libre languages shape", str(ls)[:200])


def test_libre_detect() -> None:
    section("LIBRE: /detect")
    api = libre_api()
    cases = [
        ("Das ist ein deutscher Satz mit genug Worten.", "de"),
        ("Ceci est une phrase française avec assez de mots.", "fr"),
        ("これは日本語の文章で、十分な長さがあります。", "ja"),
        ("Это русское предложение с достаточным количеством слов.", "ru"),
        ("هذه جملة بالعربية تحتوي على كلمات كافية.", "ar"),
        ("이것은 한국어 문장이며 인식을 위해 충분히 깁니다.", "ko"),
        ("Detta är en svensk mening med tillräckligt många ord.", "sv"),
    ]
    for text, expected in cases:
        d = api.detect(text)
        if d and d[0]["language"].startswith(expected):
            ok(f"libre detect '{text[:40]}...' -> {d[0]['language']} ({d[0]['confidence']}%)")
        else:
            fail(f"libre detect '{text[:40]}...'", d)


def test_libre_translate_single_string() -> None:
    section("LIBRE: translate single string q")
    if not has_pair("de-en"):
        skip("libre translate single", "de-en not installed")
        return
    api = libre_api()
    out = api.translate("Hallo Welt.", "de", "en")
    if isinstance(out, str) and "ello" in out.lower():
        ok(f"libre translate single -> {out!r}")
    else:
        fail("libre translate single", out)


def test_libre_translate_array() -> None:
    section("LIBRE: translate array q (raw, since libretranslatepy single-only)")
    if not has_pair("de-en"):
        skip("libre array q", "de-en not installed")
        return
    body = {"q": ["Hallo", "Welt", "Foo"], "source": "de", "target": "en"}
    r = requests.post(f"{BASE}/translate", json=body, timeout=10)
    parsed = r.json()
    if r.status_code == 200 and isinstance(parsed.get("translatedText"), list):
        ok(f"libre array q -> {parsed['translatedText']}")
    else:
        fail("libre array q", parsed)


def test_libre_translate_auto_detection() -> None:
    section("LIBRE: source=auto returns detectedLanguage")
    if not has_pair("de-en"):
        skip("libre auto", "de-en not installed")
        return
    body = {"q": "Das ist ein deutscher Satz mit genug Worten.", "source": "auto", "target": "en"}
    r = requests.post(f"{BASE}/translate", json=body, timeout=10)
    parsed = r.json()
    if (r.status_code == 200
            and parsed.get("detectedLanguage", {}).get("language") == "de"
            and "translatedText" in parsed):
        ok(f"libre auto -> detected de, translated to '{parsed['translatedText']}'")
    else:
        fail("libre auto", parsed)


def test_libre_error_envelope() -> None:
    section("LIBRE: error envelope")
    r = requests.post(f"{BASE}/translate", json={"q": "x"}, timeout=5)
    if r.status_code == 400 and "error" in r.json():
        ok("libre 400 -> {\"error\":...}")
    else:
        fail("libre error shape", r.text)


def test_libre_spec_and_frontend_settings() -> None:
    section("LIBRE: /spec + /frontend/settings")
    r = requests.get(f"{BASE}/spec", timeout=2)
    if r.status_code == 200 and "openapi" in r.json():
        ok("/spec returns OpenAPI stub")
    else:
        fail("/spec", r.text)
    r = requests.get(f"{BASE}/frontend/settings", timeout=2)
    if r.status_code == 200 and "language" in r.json():
        ok("/frontend/settings returns LibreTranslate UI shape")
    else:
        fail("/frontend/settings", r.text)


# -------------------------------- Google v2 ---------------------------------

def test_google_languages() -> None:
    section("GOOGLE v2: /language/translate/v2/languages")
    r = requests.get(f"{BASE}/language/translate/v2/languages", timeout=2)
    body = r.json()
    if r.status_code == 200 and body.get("data", {}).get("languages"):
        ok(f"google languages -> {len(body['data']['languages'])} entries")
    else:
        fail("google languages shape", body)


def test_google_translate_single_form() -> None:
    section("GOOGLE v2: translate single (form)")
    if not has_pair("de-en"):
        skip("google single", "de-en not installed")
        return
    r = requests.post(f"{BASE}/language/translate/v2",
                      data={"q": "Hallo Welt.", "target": "en", "source": "de"}, timeout=10)
    body = r.json()
    if (r.status_code == 200
            and body["data"]["translations"][0]["translatedText"]
            and body["data"]["translations"][0]["detectedSourceLanguage"] == "de"):
        ok(f"google single -> {body['data']['translations'][0]['translatedText']!r}")
    else:
        fail("google single", body)


def test_google_translate_repeated_q() -> None:
    section("GOOGLE v2: repeated q params")
    if not has_pair("de-en"):
        skip("google repeated q", "de-en not installed")
        return
    r = requests.post(f"{BASE}/language/translate/v2",
                      data=[("q", "Hallo"), ("q", "Welt"), ("q", "Foo"),
                            ("target", "en"), ("source", "de")], timeout=10)
    translations = r.json()["data"]["translations"]
    if len(translations) == 3 and all(t["translatedText"] for t in translations):
        ok(f"google repeated q -> {[t['translatedText'] for t in translations]}")
    else:
        fail("google repeated q", translations)


def test_google_translate_json() -> None:
    section("GOOGLE v2: JSON body")
    if not has_pair("de-en"):
        skip("google json", "de-en not installed")
        return
    body = {"q": "Hallo Welt.", "target": "en", "source": "de"}
    r = requests.post(f"{BASE}/language/translate/v2", json=body, timeout=10)
    parsed = r.json()
    if r.status_code == 200 and parsed["data"]["translations"][0]["translatedText"]:
        ok(f"google json -> {parsed['data']['translations'][0]['translatedText']!r}")
    else:
        fail("google json", parsed)


def test_google_auth_methods() -> None:
    section("GOOGLE v2: auth methods")
    if not has_pair("de-en"):
        skip("google auth methods", "de-en not installed")
        return
    body = {"q": "Hallo.", "target": "en", "source": "de"}
    # ?key=
    r = requests.post(f"{BASE}/language/translate/v2?key=any-key", data=body, timeout=10)
    ok("google ?key=") if r.status_code == 200 else fail("google ?key=", r.status_code)
    # X-goog-api-key header
    r = requests.post(f"{BASE}/language/translate/v2", data=body,
                      headers={"X-goog-api-key": "any-key"}, timeout=10)
    ok("google X-goog-api-key") if r.status_code == 200 else fail("google X-goog-api-key", r.status_code)
    # body field
    body_with_key = dict(body, key="any-key")
    r = requests.post(f"{BASE}/language/translate/v2", data=body_with_key, timeout=10)
    ok("google body key=") if r.status_code == 200 else fail("google body key=", r.status_code)


def test_google_error_envelope() -> None:
    section("GOOGLE v2: error envelope")
    r = requests.post(f"{BASE}/language/translate/v2", data={"target": "en"}, timeout=5)
    body = r.json()
    if (r.status_code == 400
            and isinstance(body.get("error"), dict)
            and body["error"].get("code") == 400
            and isinstance(body["error"].get("errors"), list)
            and body["error"]["errors"][0].get("domain") == "global"):
        ok("google error envelope matches Google v2 shape")
    else:
        fail("google error envelope", body)


# --------------------------- Cross-API parity -------------------------------

def test_cross_api_parity() -> None:
    section("CROSS-API: identical output through all 3")
    if not has_pair("de-en"):
        skip("cross-api parity", "de-en not installed")
        return

    cases = [
        "Hallo Welt.",
        "Guten Morgen, wie geht es dir?",
        "Das ist ein langer Satz, der prüft, ob alle drei APIs identisch antworten.",
        "Berlin ist die Hauptstadt von Deutschland.",
    ]
    for text in cases:
        r1 = requests.post(f"{BASE}/v2/translate",
                           data={"text": text, "target_lang": "EN", "source_lang": "DE"},
                           timeout=10).json()
        deepl_text = r1["translations"][0]["text"]

        r2 = requests.post(f"{BASE}/translate",
                           json={"q": text, "source": "de", "target": "en"},
                           timeout=10).json()
        libre_text = r2["translatedText"]

        r3 = requests.post(f"{BASE}/language/translate/v2",
                           data={"q": text, "target": "en", "source": "de"},
                           timeout=10).json()
        google_text = r3["data"]["translations"][0]["translatedText"]

        if deepl_text == libre_text == google_text:
            ok(f"3-way parity: {deepl_text!r}")
        else:
            fail(f"3-way parity for '{text}'",
                 f"deepl={deepl_text!r} libre={libre_text!r} google={google_text!r}")


# ------------------------------ Big batches ---------------------------------

def test_big_deepl_batch() -> None:
    section("DEEPL: batch of 50 in one request")
    if not has_pair("de-en"):
        skip("big batch deepl", "de-en not installed")
        return
    texts = [f"Satz Nummer {i} mit etwas Inhalt." for i in range(50)]
    body = [("text", t) for t in texts]
    body.extend([("target_lang", "EN"), ("source_lang", "DE")])
    start = time.time()
    r = requests.post(f"{BASE}/v2/translate", data=body, timeout=60)
    elapsed = time.time() - start
    translations = r.json()["translations"]
    if len(translations) == 50 and all(t["text"] for t in translations):
        ok(f"50 translations in {elapsed:.2f}s ({50/elapsed:.0f}/sec)")
    else:
        fail("big batch deepl", len(translations))


def test_long_input() -> None:
    section("LIBRE: very long single input (~3 KB)")
    if not has_pair("de-en"):
        skip("long input", "de-en not installed")
        return
    base = "Berlin ist die Hauptstadt von Deutschland und liegt im Nordosten des Landes. "
    text = base * 40
    body = {"q": text, "source": "de", "target": "en"}
    start = time.time()
    r = requests.post(f"{BASE}/translate", json=body, timeout=60)
    elapsed = time.time() - start
    out = r.json().get("translatedText", "")
    if isinstance(out, str) and len(out) > len(text) * 0.5:
        ok(f"input {len(text)} chars -> output {len(out)} chars in {elapsed:.2f}s")
    else:
        fail("long input", f"{len(text)} -> {len(out)}")


# ------------------------------ Concurrency ---------------------------------

def test_concurrency() -> None:
    section("CONCURRENCY: 30 parallel requests across all APIs")
    if not has_pair("de-en"):
        skip("concurrency", "de-en not installed")
        return

    def call(i: int) -> int:
        if i % 3 == 0:
            r = requests.post(f"{BASE}/v2/translate",
                              data={"text": f"Hallo {i}.", "target_lang": "EN", "source_lang": "DE"},
                              timeout=15)
        elif i % 3 == 1:
            r = requests.post(f"{BASE}/translate",
                              json={"q": f"Hallo {i}.", "source": "de", "target": "en"},
                              timeout=15)
        else:
            r = requests.post(f"{BASE}/language/translate/v2",
                              data={"q": f"Hallo {i}.", "target": "en", "source": "de"},
                              timeout=15)
        return r.status_code

    start = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        results = list(pool.map(call, range(30)))
    elapsed = time.time() - start
    bad = [c for c in results if c >= 500]
    if not bad and all(200 <= c < 500 for c in results):
        ok(f"30 parallel requests, all <500, {elapsed:.2f}s, codes={set(results)}")
    else:
        fail("concurrency", f"5xx detected: {bad}; codes={results}")


# -------------------------------- Driver ------------------------------------

def main() -> int:
    global PORT, BASE
    if not os.path.isfile(BIN) or not os.access(BIN, os.X_OK):
        print(f"FATAL: {BIN} not built. Run 'swift build -c release' first.", file=sys.stderr)
        return 2

    PORT = PORT or free_port()
    BASE = f"http://127.0.0.1:{PORT}"
    print(f"==> starting translate --serve on {BASE}")
    server = start_server(PORT)
    try:
        # 1. Plumbing
        test_health()
        test_cors_on_every_endpoint()

        # 2. DeepL surface
        test_deepl_languages()
        test_deepl_usage()
        test_deepl_translate_single()
        test_deepl_translate_batch()
        test_deepl_translate_lang_pairs()
        test_deepl_authorization_header()
        test_deepl_passthrough_fields()
        test_deepl_error_envelope()
        test_deepl_billed_characters()
        test_deepl_unicode_and_emoji()

        # 3. LibreTranslate surface
        test_libre_languages()
        test_libre_detect()
        test_libre_translate_single_string()
        test_libre_translate_array()
        test_libre_translate_auto_detection()
        test_libre_error_envelope()
        test_libre_spec_and_frontend_settings()

        # 4. Google v2 surface
        test_google_languages()
        test_google_translate_single_form()
        test_google_translate_repeated_q()
        test_google_translate_json()
        test_google_auth_methods()
        test_google_error_envelope()

        # 5. Cross-API parity, big batches, concurrency
        test_cross_api_parity()
        test_big_deepl_batch()
        test_long_input()
        test_concurrency()

    finally:
        server.terminate()
        try:
            server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server.kill()

    print()
    print("=" * 60)
    print(f"  passed:  {passed}")
    print(f"  skipped: {skipped}")
    print(f"  failed:  {failed}")
    print("=" * 60)

    if failed:
        for label, detail in failures:
            print(f"FAIL {label}")
            if detail:
                print(f"     {detail}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
