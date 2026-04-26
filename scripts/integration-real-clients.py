"""
Drives translate's HTTP server with the actual third-party clients used to
talk to DeepL, LibreTranslate, and Google. Proves drop-in compatibility.

Skips translation calls (but keeps shape/protocol calls) when no Apple
translation models are installed.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import textwrap
import urllib.request

PORT = int(os.environ["PORT"])
BASE = f"http://127.0.0.1:{PORT}"

passed = 0
skipped = 0
failed = 0


def ok(msg: str) -> None:
    global passed
    print(f"  ✓ {msg}")
    passed += 1


def skip(msg: str, why: str) -> None:
    global skipped
    print(f"  ⊘ {msg} — {why}")
    skipped += 1


def fail(msg: str, detail: str = "") -> None:
    global failed
    print(f"  ✗ {msg}", file=sys.stderr)
    if detail:
        print(textwrap.indent(detail, "    "), file=sys.stderr)
    failed += 1


def has_pair(pair: str) -> bool:
    binary = os.path.join(os.path.dirname(__file__), "..", ".build", "release", "translate")
    out = subprocess.run([binary, "--installed"], capture_output=True, text=True, check=True).stdout
    return any(line.strip() == pair for line in out.splitlines())


# ----------------------------------------------------------------------
# DeepL — official Python SDK
# ----------------------------------------------------------------------

print("== DeepL Python SDK ==")
import deepl  # type: ignore  # noqa: E402

translator = deepl.Translator("any-token", server_url=BASE)

# /v2/languages goes through `get_source_languages` / `get_target_languages`
try:
    targets = translator.get_target_languages()
    if targets and any(lang.code for lang in targets):
        ok(f"deepl get_target_languages -> {len(targets)} entries")
    else:
        fail("deepl get_target_languages", repr(targets))
except Exception as e:
    fail("deepl get_target_languages", repr(e))

try:
    usage = translator.get_usage()
    if usage.character is not None:
        ok(f"deepl get_usage character_count={usage.character.count} character_limit={usage.character.limit}")
    else:
        fail("deepl get_usage")
except Exception as e:
    fail("deepl get_usage", repr(e))

if has_pair("de-en"):
    try:
        result = translator.translate_text("Hallo Welt.", source_lang="DE", target_lang="EN-US")
        if result.text and result.detected_source_lang.upper() == "DE":
            ok(f"deepl translate_text -> {result.text!r} (detected {result.detected_source_lang})")
        else:
            fail("deepl translate_text", repr(result))
    except Exception as e:
        fail("deepl translate_text", repr(e))

    try:
        results = translator.translate_text(["Hallo", "Welt"], source_lang="DE", target_lang="EN-US")
        if isinstance(results, list) and len(results) == 2 and all(r.text for r in results):
            ok(f"deepl translate_text batch -> {[r.text for r in results]}")
        else:
            fail("deepl translate_text batch", repr(results))
    except Exception as e:
        fail("deepl translate_text batch", repr(e))
else:
    skip("deepl translate_text", "de-en model not installed")
    skip("deepl translate_text batch", "de-en model not installed")


# ----------------------------------------------------------------------
# LibreTranslate — libretranslatepy
# ----------------------------------------------------------------------

print("== LibreTranslate (libretranslatepy) ==")
from libretranslatepy import LibreTranslateAPI  # type: ignore  # noqa: E402

lt = LibreTranslateAPI(BASE)

try:
    languages = lt.languages()
    if isinstance(languages, list) and languages and "code" in languages[0] and "targets" in languages[0]:
        ok(f"libretranslate languages -> {len(languages)} entries")
    else:
        fail("libretranslate languages", repr(languages)[:200])
except Exception as e:
    fail("libretranslate languages", repr(e))

try:
    detected = lt.detect("Das ist ein deutscher Satz mit genug Worten.")
    if isinstance(detected, list) and detected and detected[0]["language"].startswith("de"):
        ok(f"libretranslate detect -> {detected[0]}")
    else:
        fail("libretranslate detect", repr(detected))
except Exception as e:
    fail("libretranslate detect", repr(e))

if has_pair("de-en"):
    try:
        translated = lt.translate("Hallo Welt.", "de", "en")
        if isinstance(translated, str) and translated:
            ok(f"libretranslate translate -> {translated!r}")
        else:
            fail("libretranslate translate", repr(translated))
    except Exception as e:
        fail("libretranslate translate", repr(e))
else:
    skip("libretranslate translate", "de-en model not installed")


# ----------------------------------------------------------------------
# Google v2 — direct HTTP (the v2 REST shape is what google-cloud-translate
# v2 uses internally; the official Python SDK additionally requires a
# Google service account credential and is not the right fit for a self-
# hosted backend. Drive the v2 REST shape directly so anyone using a v2
# client library or direct HTTP gets the same responses.)
# ----------------------------------------------------------------------

print("== Google Translate v2 REST ==")
import requests  # type: ignore  # noqa: E402

try:
    r = requests.get(f"{BASE}/language/translate/v2/languages", timeout=5)
    r.raise_for_status()
    body = r.json()
    if "data" in body and "languages" in body["data"]:
        ok(f"google v2 languages -> {len(body['data']['languages'])} entries")
    else:
        fail("google v2 languages", json.dumps(body)[:200])
except Exception as e:
    fail("google v2 languages", repr(e))

if has_pair("de-en"):
    try:
        r = requests.post(
            f"{BASE}/language/translate/v2",
            data={"q": "Hallo Welt.", "target": "en", "source": "de"},
            timeout=5,
        )
        r.raise_for_status()
        body = r.json()
        translations = body["data"]["translations"]
        if translations and translations[0]["translatedText"]:
            ok(f"google v2 translate -> {translations[0]['translatedText']!r}")
        else:
            fail("google v2 translate", json.dumps(body))
    except Exception as e:
        fail("google v2 translate", repr(e))

    try:
        # Multi-q: google v2 accepts repeated `q` form params
        r = requests.post(
            f"{BASE}/language/translate/v2",
            data=[("q", "Hallo"), ("q", "Welt"), ("target", "en"), ("source", "de")],
            timeout=5,
        )
        r.raise_for_status()
        body = r.json()
        translations = body["data"]["translations"]
        if len(translations) == 2 and translations[0]["translatedText"] and translations[1]["translatedText"]:
            ok(f"google v2 multi-q -> {[t['translatedText'] for t in translations]}")
        else:
            fail("google v2 multi-q", json.dumps(body))
    except Exception as e:
        fail("google v2 multi-q", repr(e))
else:
    skip("google v2 translate", "de-en model not installed")
    skip("google v2 multi-q", "de-en model not installed")


# ----------------------------------------------------------------------
# Cross-API consistency: same source text via three APIs must produce
# semantically equivalent (non-empty) translations.
# ----------------------------------------------------------------------

if has_pair("de-en"):
    print("== Cross-API consistency ==")

    def deepl_translate() -> str:
        result = translator.translate_text("Guten Morgen, wie geht es dir?", source_lang="DE", target_lang="EN-US")
        return result.text  # type: ignore

    def libre_translate() -> str:
        return lt.translate("Guten Morgen, wie geht es dir?", "de", "en")

    def google_translate() -> str:
        r = requests.post(
            f"{BASE}/language/translate/v2",
            data={"q": "Guten Morgen, wie geht es dir?", "target": "en", "source": "de"},
            timeout=5,
        )
        r.raise_for_status()
        return r.json()["data"]["translations"][0]["translatedText"]

    deepl_text = deepl_translate()
    libre_text = libre_translate()
    google_text = google_translate()

    if deepl_text and libre_text and google_text:
        # All three should produce identical output -- they share one engine.
        if deepl_text == libre_text == google_text:
            ok(f"three APIs return identical text: {deepl_text!r}")
        else:
            fail("three APIs disagree", f"deepl={deepl_text!r} libre={libre_text!r} google={google_text!r}")
    else:
        fail("cross-API consistency", f"deepl={deepl_text!r} libre={libre_text!r} google={google_text!r}")
else:
    skip("cross-API consistency", "de-en model not installed")


print()
print("===========================")
print(f"  passed:  {passed}")
print(f"  skipped: {skipped}")
print(f"  failed:  {failed}")
print("===========================")

if failed:
    sys.exit(1)
