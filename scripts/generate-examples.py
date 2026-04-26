#!/usr/bin/env python3
"""
generate-examples.py — runs every documented example for `translate`,
captures the real stdout / stderr / exit code, asserts an expected
behavior on each one, and writes the result into per-API Markdown files
plus a top-level EXAMPLE.md index.

Two outputs in one pass:
  1. Documentation (always honest — lifted straight from the running tool)
  2. End-to-end battle test (any scene whose expectation fails => exit 1)

Surfaces covered:
  - CLI (stdin, args, --file, --format json/ndjson, --batch, --detect-only,
    --installed, --available, error paths)
  - HTTP server with all three drop-in APIs:
      * DeepL v2 via curl AND the official `deepl` Python SDK
      * LibreTranslate via curl AND `libretranslatepy`
      * Google v2 via curl AND raw requests
  - Cross-API consistency check
  - Stress: many pairs, big inputs, many tokens

Usage:
  scripts/generate-examples.py            # uses .build/release/translate
  TRANSLATE=path scripts/generate-examples.py
  PORT=8989 scripts/generate-examples.py  # pin the server port (default: random)
"""

from __future__ import annotations

import json
import os
import shlex
import socket
import subprocess
import sys
import textwrap
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, List, Optional, Sequence

ROOT = Path(__file__).resolve().parent.parent
BIN = Path(os.environ.get("TRANSLATE", ROOT / ".build" / "release" / "translate"))
EXAMPLES_DIR = ROOT / "examples"
INDEX_PATH = ROOT / "EXAMPLE.md"

# If a venv with the third-party clients (deepl, libretranslatepy, requests)
# was set up by `make test-real-clients`, prefer it over system Python so
# this script can run without polluting the host environment.
VENV_PYTHON = ROOT / ".build" / "realclients-venv" / "bin" / "python3"
PYTHON: str = str(VENV_PYTHON) if VENV_PYTHON.is_file() else sys.executable

if not BIN.is_file() or not os.access(BIN, os.X_OK):
    print(f"error: {BIN} not built. Run 'swift build -c release' first.", file=sys.stderr)
    sys.exit(2)

# ---------------------------------------------------------------------------
# Capture types
# ---------------------------------------------------------------------------

@dataclass
class Captured:
    label: str
    command: str
    stdin: Optional[str]
    stdout: str
    stderr: str
    exit_code: int
    runner: str  # "shell" | "python"
    redact: bool = False
    notes: List[str] = field(default_factory=list)
    skipped_reason: Optional[str] = None


def run_shell(label: str, command: str, *, stdin: Optional[str] = None,
              expect_exit: Optional[int] = 0,
              expect_contains: Sequence[str] = (),
              expect_not_contains: Sequence[str] = (),
              env_extra: Optional[dict[str, str]] = None,
              skip_if: Optional[Callable[[], Optional[str]]] = None,
              redact_stdout: bool = False) -> Captured:
    if skip_if is not None:
        why = skip_if()
        if why is not None:
            return Captured(label=label, command=command, stdin=stdin, stdout="",
                            stderr="", exit_code=0, runner="shell", skipped_reason=why)

    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)

    proc = subprocess.run(
        ["/bin/bash", "-lc", command],
        input=stdin if stdin is not None else None,
        capture_output=True,
        text=True,
        env=env,
    )
    cap = Captured(
        label=label,
        command=command,
        stdin=stdin,
        stdout=proc.stdout,
        stderr=proc.stderr,
        exit_code=proc.returncode,
        runner="shell",
        redact=redact_stdout,
    )

    failures = []
    if expect_exit is not None and cap.exit_code != expect_exit:
        failures.append(f"exit {cap.exit_code} != expected {expect_exit}")
    for needle in expect_contains:
        if needle not in cap.stdout and needle not in cap.stderr:
            failures.append(f"missing substring: {needle!r}")
    for needle in expect_not_contains:
        if needle in cap.stdout or needle in cap.stderr:
            failures.append(f"forbidden substring present: {needle!r}")
    if failures:
        cap.notes.extend(f"FAIL {f}" for f in failures)
    return cap


def run_python(label: str, snippet: str, *, expect_contains: Sequence[str] = (),
               expect_not_contains: Sequence[str] = (),
               skip_if: Optional[Callable[[], Optional[str]]] = None) -> Captured:
    if skip_if is not None:
        why = skip_if()
        if why is not None:
            return Captured(label=label, command=snippet, stdin=None, stdout="",
                            stderr="", exit_code=0, runner="python", skipped_reason=why)

    proc = subprocess.run(
        [PYTHON, "-c", snippet],
        capture_output=True, text=True,
    )
    cap = Captured(
        label=label, command=snippet, stdin=None,
        stdout=proc.stdout, stderr=proc.stderr,
        exit_code=proc.returncode, runner="python",
    )
    failures = []
    if cap.exit_code != 0:
        failures.append(f"exit {cap.exit_code}")
    for needle in expect_contains:
        if needle not in cap.stdout and needle not in cap.stderr:
            failures.append(f"missing substring: {needle!r}")
    for needle in expect_not_contains:
        if needle in cap.stdout or needle in cap.stderr:
            failures.append(f"forbidden substring present: {needle!r}")
    if failures:
        cap.notes.extend(f"FAIL {f}" for f in failures)
    return cap


# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------

def installed_pairs() -> set[str]:
    out = subprocess.run([str(BIN), "--installed"], capture_output=True, text=True)
    return {line.strip() for line in out.stdout.splitlines() if line.strip()}


PAIRS = installed_pairs()
HAS_DE_EN = "de-en" in PAIRS
HAS_EN_DE = "en-de" in PAIRS
HAS_FR_EN = "fr-en" in PAIRS
HAS_JA_EN = "ja-en" in PAIRS


def need(pair: str) -> Callable[[], Optional[str]]:
    return lambda: None if pair in PAIRS else f"{pair} model not installed"


def free_port() -> int:
    if "PORT" in os.environ and os.environ["PORT"]:
        return int(os.environ["PORT"])
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


# ---------------------------------------------------------------------------
# Markdown rendering
# ---------------------------------------------------------------------------

def render(cap: Captured) -> str:
    lines: List[str] = []
    lines.append(f"### {cap.label}")
    lines.append("")
    if cap.skipped_reason is not None:
        lines.append(f"_skipped — {cap.skipped_reason}_")
        lines.append("")
        return "\n".join(lines) + "\n"

    if cap.runner == "shell":
        if cap.stdin is not None:
            heredoc_safe = "EOF" not in cap.stdin
            if heredoc_safe and "\n" in cap.stdin.rstrip("\n"):
                lines.append("```sh")
                lines.append(f"cat <<'EOF' | {cap.command}")
                lines.append(cap.stdin.rstrip("\n"))
                lines.append("EOF")
                lines.append("```")
            else:
                quoted = shlex.quote(cap.stdin)
                lines.append("```sh")
                lines.append(f"printf '%s' {quoted} | {cap.command}")
                lines.append("```")
        else:
            lines.append("```sh")
            lines.append(cap.command)
            lines.append("```")
    else:
        lines.append("```python")
        lines.append(cap.command.rstrip("\n"))
        lines.append("```")
    lines.append("")

    out_block = cap.stdout
    if cap.redact:
        out_block = "<redacted: long output>"
    elif len(cap.stdout) > 1200:
        out_block = cap.stdout[:1200] + f"\n… ({len(cap.stdout) - 1200} more bytes truncated)"

    if out_block.strip():
        lines.append("```")
        lines.append(out_block.rstrip("\n"))
        lines.append("```")
    else:
        lines.append("_(no stdout)_")
    lines.append("")

    if cap.stderr.strip():
        lines.append("stderr:")
        lines.append("")
        lines.append("```")
        lines.append(cap.stderr.rstrip("\n"))
        lines.append("```")
        lines.append("")

    lines.append(f"exit code: `{cap.exit_code}`")
    lines.append("")

    if cap.notes:
        lines.append("**Battle-test result:**")
        lines.append("")
        for n in cap.notes:
            lines.append(f"- {n}")
        lines.append("")

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------

class Server:
    def __init__(self, port: int) -> None:
        self.port = port
        self.process: Optional[subprocess.Popen[bytes]] = None

    def start(self) -> None:
        self.process = subprocess.Popen(
            [str(BIN), "--serve", "--port", str(self.port), "--quiet"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.5):
                    break
            except OSError:
                time.sleep(0.05)

    def stop(self) -> None:
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()


# ---------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------

def section_cli_basics() -> List[Captured]:
    out: List[Captured] = []

    out.append(run_shell(
        "Show the version",
        f"{shlex.quote(str(BIN))} --version",
        expect_contains=["0.1.0"],
    ))

    out.append(run_shell(
        "Show the help text",
        f"{shlex.quote(str(BIN))} --help",
        expect_contains=["UNIX-style filter", "--to", "--serve"],
    ))

    out.append(run_shell(
        "Detect language from piped German text",
        f"{shlex.quote(str(BIN))} --detect-only",
        stdin="Das ist ein deutscher Satz mit genug Worten zum Erkennen.",
        expect_contains=["de\t"],
    ))

    out.append(run_shell(
        "Detect language from a French argument",
        f"{shlex.quote(str(BIN))} --detect-only \"Ceci est une phrase française avec plusieurs mots distincts.\"",
        expect_contains=["fr\t"],
    ))

    out.append(run_shell(
        "Detect language with hint constraints",
        f"{shlex.quote(str(BIN))} --detect-only --langs de,en,fr 'Hallo Welt mit etwas mehr Inhalt zum Erkennen.'",
        expect_contains=["de\t"],
    ))

    out.append(run_shell(
        "Missing --to with stdin -> usage error (exit 1)",
        f"{shlex.quote(str(BIN))}",
        stdin="hi\n",
        expect_exit=1,
        expect_contains=["--to is required"],
    ))

    out.append(run_shell(
        "List installed model pairs (may be empty)",
        f"{shlex.quote(str(BIN))} --installed",
        expect_exit=0,
        redact_stdout=True,
    ))

    out.append(run_shell(
        "List supported model pairs on this OS (truncated)",
        f"{shlex.quote(str(BIN))} --available | head -n 5",
        expect_exit=0,
    ))

    return out


def section_cli_translate() -> List[Captured]:
    out: List[Captured] = []

    out.append(run_shell(
        "Translate piped German to English (plain)",
        f"{shlex.quote(str(BIN))} --to en --from de --no-install --quiet",
        stdin="Hallo Welt.\n",
        skip_if=need("de-en"),
    ))

    out.append(run_shell(
        "Translate two text arguments",
        f"{shlex.quote(str(BIN))} --to de --from en --no-install --quiet 'good night' 'see you tomorrow'",
        skip_if=need("en-de"),
    ))

    out.append(run_shell(
        "Translate piped paragraphs as NDJSON",
        f"{shlex.quote(str(BIN))} --to en --from de --no-install --format ndjson --quiet",
        stdin="Hallo Welt.\n\nWie geht es dir?\n",
        skip_if=need("de-en"),
        expect_contains=['"from":"de"', '"to":"en"', '"src"', '"dst"'],
    ))

    out.append(run_shell(
        "Translate piped paragraphs as JSON array",
        f"{shlex.quote(str(BIN))} --to en --from de --no-install --format json --quiet",
        stdin="Hallo Welt.\n\nGuten Abend.\n",
        skip_if=need("de-en"),
        expect_contains=["[", "]", '"src"'],
    ))

    out.append(run_shell(
        "Batch mode: each line is its own translation unit",
        f"{shlex.quote(str(BIN))} --to en --from de --no-install --batch --quiet",
        stdin="Eins\nZwei\nDrei\n",
        skip_if=need("de-en"),
    ))

    out.append(run_shell(
        "Protected URLs and emails pass through unchanged",
        f"{shlex.quote(str(BIN))} --to en --from de --no-install --quiet",
        stdin="Hallo, schreibe an a@b.com oder besuche https://example.com.\n",
        skip_if=need("de-en"),
        expect_contains=["a@b.com", "https://example.com"],
    ))

    out.append(run_shell(
        "Translate from a file with --file (single)",
        textwrap.dedent("""\
            tmp=$(mktemp); printf 'Hallo Welt.\\n' > "$tmp";
            %s --from de --to en --no-install --quiet --file "$tmp";
            rm -f "$tmp"
        """) % shlex.quote(str(BIN)),
        skip_if=need("de-en"),
    ))

    out.append(run_shell(
        "Translate from multiple --file inputs",
        textwrap.dedent("""\
            d=$(mktemp -d);
            printf 'Hallo Welt.\\n' > "$d/a.txt";
            printf 'Wie geht es dir?\\n' > "$d/b.txt";
            %s --from de --to en --no-install --quiet --format ndjson --file "$d/a.txt" --file "$d/b.txt";
            rm -rf "$d"
        """) % shlex.quote(str(BIN)),
        skip_if=need("de-en"),
        expect_contains=['"from":"de"'],
    ))

    return out


def section_cli_languages() -> List[Captured]:
    out: List[Captured] = []
    cases = [
        ("French to English", "fr", "en", "Bonjour le monde, comment ça va aujourd'hui ?", "fr-en"),
        ("Japanese to English", "ja", "en", "これは翻訳のテストです。", "ja-en"),
        ("Spanish to English", "es", "en", "Hola mundo, ¿cómo estás hoy?", "es-en"),
        ("Italian to English", "it", "en", "Ciao mondo, come stai oggi?", "it-en"),
        ("Russian to English", "ru", "en", "Привет, мир! Как дела сегодня?", "ru-en"),
        ("Chinese to English", "zh", "en", "你好世界，今天过得怎么样？", "zh-en"),
        ("Arabic to English", "ar", "en", "مرحبا بالعالم. كيف حالك اليوم؟", "ar-en"),
    ]
    for label, src, tgt, text, pair in cases:
        out.append(run_shell(
            label,
            f"{shlex.quote(str(BIN))} --to {tgt} --from {src} --no-install --quiet {shlex.quote(text)}",
            skip_if=need(pair),
        ))
    return out


def section_deepl_curl(server: Server) -> List[Captured]:
    out: List[Captured] = []
    base = f"http://127.0.0.1:{server.port}"

    out.append(run_shell(
        "GET /v2/languages -- DeepL language list",
        f"curl -sf {base}/v2/languages | python3 -c 'import sys, json; d = json.load(sys.stdin); print(json.dumps(d[:3], indent=2))'",
        expect_contains=['"language"', '"name"'],
    ))

    out.append(run_shell(
        "GET /v2/usage -- DeepL quota stub",
        f"curl -sf {base}/v2/usage",
        expect_contains=["character_count", "character_limit"],
    ))

    out.append(run_shell(
        "POST /v2/translate -- single text (form-encoded)",
        f"curl -sf -X POST {base}/v2/translate "
        f"--data-urlencode 'text=Hallo Welt.' "
        f"--data-urlencode 'target_lang=EN' "
        f"--data-urlencode 'source_lang=DE'",
        skip_if=need("de-en"),
        expect_contains=["translations", "text"],
    ))

    out.append(run_shell(
        "POST /v2/translate -- multiple texts in one request",
        f"curl -sf -X POST {base}/v2/translate "
        f"--data-urlencode 'text=Hallo' "
        f"--data-urlencode 'text=Welt' "
        f"--data-urlencode 'text=Guten Morgen' "
        f"--data-urlencode 'target_lang=EN' "
        f"--data-urlencode 'source_lang=DE'",
        skip_if=need("de-en"),
        expect_contains=["translations"],
    ))

    out.append(run_shell(
        "POST /v2/translate -- JSON body with array text",
        textwrap.dedent("""\
            curl -sf -X POST %s/v2/translate \\
              -H "Content-Type: application/json" \\
              --data '{"text":["Hallo","Welt"],"target_lang":"EN","source_lang":"DE"}'
        """) % base,
        skip_if=need("de-en"),
        expect_contains=["translations"],
    ))

    out.append(run_shell(
        "POST /v2/translate -- missing target_lang -> 400",
        f"curl -s -o /dev/null -w '%{{http_code}}' -X POST {base}/v2/translate "
        f"--data-urlencode 'text=Hallo'",
        expect_contains=["400"],
    ))

    return out


def section_deepl_python(server: Server) -> List[Captured]:
    out: List[Captured] = []
    base = f"http://127.0.0.1:{server.port}"

    snippet_languages = textwrap.dedent(f"""\
        import deepl
        t = deepl.Translator("any-token", server_url="{base}")
        langs = t.get_target_languages()
        print(f"got {{len(langs)}} target languages, first three: {{[l.code for l in langs[:3]]}}")
    """)
    out.append(run_python(
        "deepl.Translator.get_target_languages() -- the official Python SDK",
        snippet_languages,
        expect_contains=["target languages"],
    ))

    snippet_usage = textwrap.dedent(f"""\
        import deepl
        t = deepl.Translator("any-token", server_url="{base}")
        u = t.get_usage()
        print(f"character_count={{u.character.count}} character_limit={{u.character.limit}}")
    """)
    out.append(run_python(
        "deepl.Translator.get_usage() -- quota check via the SDK",
        snippet_usage,
        expect_contains=["character_count="],
    ))

    snippet_translate = textwrap.dedent(f"""\
        import deepl
        t = deepl.Translator("any-token", server_url="{base}")
        r = t.translate_text("Hallo Welt.", source_lang="DE", target_lang="EN-US")
        print("text:", r.text)
        print("detected_source_lang:", r.detected_source_lang)
    """)
    out.append(run_python(
        "deepl.Translator.translate_text() -- single string, drop-in usage",
        snippet_translate,
        skip_if=need("de-en"),
        expect_contains=["text:"],
    ))

    snippet_batch = textwrap.dedent(f"""\
        import deepl
        t = deepl.Translator("any-token", server_url="{base}")
        rs = t.translate_text(["Hallo", "Welt", "Guten Morgen"],
                              source_lang="DE", target_lang="EN-US")
        for r in rs: print(r.text)
    """)
    out.append(run_python(
        "deepl.Translator.translate_text() -- list batch",
        snippet_batch,
        skip_if=need("de-en"),
    ))

    return out


def section_libre_curl(server: Server) -> List[Captured]:
    out: List[Captured] = []
    base = f"http://127.0.0.1:{server.port}"

    out.append(run_shell(
        "GET /languages -- LibreTranslate language list",
        f"curl -sf {base}/languages | python3 -c 'import sys, json; d = json.load(sys.stdin); print(json.dumps(d[:2], indent=2))'",
        expect_contains=['"code"', '"targets"'],
    ))

    out.append(run_shell(
        "POST /detect -- language detection",
        f"curl -sf -X POST {base}/detect "
        f"-H 'Content-Type: application/json' "
        f"--data '{{\"q\":\"Das ist ein deutscher Satz mit genug Worten.\"}}'",
        expect_contains=['"language":"de"', '"confidence"'],
    ))

    out.append(run_shell(
        "POST /translate -- single string q",
        f"curl -sf -X POST {base}/translate "
        f"-H 'Content-Type: application/json' "
        f"--data '{{\"q\":\"Hallo Welt.\",\"source\":\"de\",\"target\":\"en\",\"format\":\"text\"}}'",
        skip_if=need("de-en"),
        expect_contains=["translatedText"],
    ))

    out.append(run_shell(
        "POST /translate -- array q (batch)",
        f"curl -sf -X POST {base}/translate "
        f"-H 'Content-Type: application/json' "
        f"--data '{{\"q\":[\"Hallo\",\"Welt\"],\"source\":\"de\",\"target\":\"en\"}}'",
        skip_if=need("de-en"),
        expect_contains=['"translatedText":['],
    ))

    out.append(run_shell(
        "POST /translate -- source=auto adds detectedLanguage to response",
        f"curl -sf -X POST {base}/translate "
        f"-H 'Content-Type: application/json' "
        f"--data '{{\"q\":\"Das ist ein deutscher Satz mit genug Worten.\",\"source\":\"auto\",\"target\":\"en\"}}'",
        skip_if=need("de-en"),
        expect_contains=['"detectedLanguage"', '"language":"de"'],
    ))

    return out


def section_libre_python(server: Server) -> List[Captured]:
    out: List[Captured] = []
    base = f"http://127.0.0.1:{server.port}"

    snippet_lang = textwrap.dedent(f"""\
        from libretranslatepy import LibreTranslateAPI
        api = LibreTranslateAPI("{base}")
        ls = api.languages()
        print(f"got {{len(ls)}} languages; first two: {{[l['code'] for l in ls[:2]]}}")
    """)
    out.append(run_python(
        "libretranslatepy LibreTranslateAPI.languages()",
        snippet_lang,
        expect_contains=["languages"],
    ))

    snippet_detect = textwrap.dedent(f"""\
        from libretranslatepy import LibreTranslateAPI
        api = LibreTranslateAPI("{base}")
        d = api.detect("Das ist ein deutscher Satz mit genug Worten.")
        print(d)
    """)
    out.append(run_python(
        "libretranslatepy LibreTranslateAPI.detect()",
        snippet_detect,
        expect_contains=["language"],
    ))

    snippet_t = textwrap.dedent(f"""\
        from libretranslatepy import LibreTranslateAPI
        api = LibreTranslateAPI("{base}")
        print(api.translate("Hallo Welt.", "de", "en"))
    """)
    out.append(run_python(
        "libretranslatepy LibreTranslateAPI.translate()",
        snippet_t,
        skip_if=need("de-en"),
    ))

    return out


def section_google_curl(server: Server) -> List[Captured]:
    out: List[Captured] = []
    base = f"http://127.0.0.1:{server.port}"

    out.append(run_shell(
        "GET /language/translate/v2/languages",
        f"curl -sf {base}/language/translate/v2/languages | python3 -c 'import sys, json; d = json.load(sys.stdin); print(json.dumps({{\"sample\": d[\"data\"][\"languages\"][:3]}}, indent=2))'",
        expect_contains=['"language"', '"name"'],
    ))

    out.append(run_shell(
        "POST /language/translate/v2 -- single q (form)",
        f"curl -sf -X POST {base}/language/translate/v2 "
        f"--data-urlencode 'q=Hallo Welt.' "
        f"--data-urlencode 'target=en' "
        f"--data-urlencode 'source=de'",
        skip_if=need("de-en"),
        expect_contains=['"data"', '"translations"', '"translatedText"'],
    ))

    out.append(run_shell(
        "POST /language/translate/v2 -- repeated q params (batch)",
        f"curl -sf -X POST {base}/language/translate/v2 "
        f"--data-urlencode 'q=Hallo' "
        f"--data-urlencode 'q=Welt' "
        f"--data-urlencode 'target=en' "
        f"--data-urlencode 'source=de'",
        skip_if=need("de-en"),
        expect_contains=['"translations"'],
    ))

    out.append(run_shell(
        "POST /language/translate/v2 -- JSON body",
        textwrap.dedent("""\
            curl -sf -X POST %s/language/translate/v2 \\
              -H "Content-Type: application/json" \\
              --data '{"q":"Hallo","target":"en","source":"de"}'
        """) % base,
        skip_if=need("de-en"),
        expect_contains=["translatedText"],
    ))

    return out


def section_google_python(server: Server) -> List[Captured]:
    out: List[Captured] = []
    base = f"http://127.0.0.1:{server.port}"

    snippet = textwrap.dedent(f"""\
        import requests
        r = requests.post("{base}/language/translate/v2",
                          data={{"q":"Hallo Welt.","target":"en","source":"de"}},
                          timeout=5)
        r.raise_for_status()
        body = r.json()
        print(body["data"]["translations"][0])
    """)
    out.append(run_python(
        "Google v2 via raw requests -- no Google credentials needed",
        snippet,
        skip_if=need("de-en"),
        expect_contains=["translatedText"],
    ))

    snippet_multi = textwrap.dedent(f"""\
        import requests
        r = requests.post("{base}/language/translate/v2",
                          data=[("q","Hallo"),("q","Welt"),("target","en"),("source","de")],
                          timeout=5)
        r.raise_for_status()
        for t in r.json()["data"]["translations"]:
            print(t["translatedText"])
    """)
    out.append(run_python(
        "Google v2 via requests -- multiple q params (batch)",
        snippet_multi,
        skip_if=need("de-en"),
    ))

    return out


def section_cross_api(server: Server) -> List[Captured]:
    out: List[Captured] = []
    base = f"http://127.0.0.1:{server.port}"

    snippet = textwrap.dedent(f"""\
        import json
        import requests
        from libretranslatepy import LibreTranslateAPI

        text = "Guten Morgen, wie geht es dir?"

        # 1) DeepL surface
        r = requests.post("{base}/v2/translate",
                          data={{"text": text, "target_lang": "EN", "source_lang": "DE"}}, timeout=5)
        r.raise_for_status()
        deepl_text = r.json()["translations"][0]["text"]

        # 2) LibreTranslate surface
        api = LibreTranslateAPI("{base}")
        libre_text = api.translate(text, "de", "en")

        # 3) Google v2 surface
        r = requests.post("{base}/language/translate/v2",
                          data={{"q": text, "target": "en", "source": "de"}}, timeout=5)
        r.raise_for_status()
        google_text = r.json()["data"]["translations"][0]["translatedText"]

        print(json.dumps({{
            "deepl": deepl_text,
            "libre": libre_text,
            "google": google_text,
            "all_equal": deepl_text == libre_text == google_text,
        }}, indent=2))
    """)
    out.append(run_python(
        "Same input through all three APIs returns identical output",
        snippet,
        skip_if=need("de-en"),
        expect_contains=['"all_equal": true'],
    ))

    return out


def section_battle(server: Server) -> List[Captured]:
    out: List[Captured] = []
    base = f"http://127.0.0.1:{server.port}"

    # Big paragraph batch through DeepL
    snippet_big = textwrap.dedent(f"""\
        import requests
        import time

        texts = [f"Satz Nummer {{i}} mit etwas Inhalt." for i in range(50)]
        body = [("text", t) for t in texts]
        body.append(("target_lang", "EN"))
        body.append(("source_lang", "DE"))

        start = time.time()
        r = requests.post("{base}/v2/translate", data=body, timeout=20)
        elapsed = time.time() - start
        r.raise_for_status()
        translations = r.json()["translations"]
        print(f"requested {{len(texts)}} translations -> received {{len(translations)}} in {{elapsed:.2f}}s")
        print("first three texts:", [t["text"] for t in translations[:3]])
    """)
    out.append(run_python(
        "DeepL batch of 50 short sentences in one request",
        snippet_big,
        skip_if=need("de-en"),
        expect_contains=["received 50"],
    ))

    snippet_long = textwrap.dedent(f"""\
        import requests
        text = "Hallo Welt. " * 200  # ~2400 chars
        r = requests.post("{base}/translate",
                          json={{"q": text, "source": "de", "target": "en", "format": "text"}}, timeout=20)
        r.raise_for_status()
        out = r.json()["translatedText"]
        print(f"input chars: {{len(text)}}, output chars: {{len(out)}}")
    """)
    out.append(run_python(
        "LibreTranslate single very-long input (~2400 chars)",
        snippet_long,
        skip_if=need("de-en"),
        expect_contains=["input chars:"],
    ))

    snippet_protected = textwrap.dedent(f"""\
        import requests
        text = "Klick https://example.com/a/b und schreibe a@b.com -- code: `print(1)` -- ende."
        r = requests.post("{base}/v2/translate",
                          data={{"text": text, "target_lang": "EN", "source_lang": "DE"}}, timeout=10)
        r.raise_for_status()
        body = r.json()["translations"][0]["text"]
        print("output:", body)
        for must in ["https://example.com/a/b", "a@b.com", "`print(1)`"]:
            assert must in body, f"missing {{must!r}} in {{body!r}}"
        print("OK -- all protected spans preserved")
    """)
    out.append(run_python(
        "Hardened: URLs, emails, and inline code survive translation",
        snippet_protected,
        skip_if=need("de-en"),
        expect_contains=["all protected spans preserved"],
    ))

    snippet_unicode = textwrap.dedent(f"""\
        import requests
        text = "Hallo Welt 🌍 mit Emoji und العربية gemischt."
        r = requests.post("{base}/translate",
                          json={{"q": text, "source": "auto", "target": "en"}}, timeout=10)
        r.raise_for_status()
        body = r.json()
        print(body)
    """)
    out.append(run_python(
        "Mixed-script Unicode (emoji + Arabic + Latin) through LibreTranslate",
        snippet_unicode,
        skip_if=need("de-en"),
    ))

    return out


# ---------------------------------------------------------------------------
# Generation orchestration
# ---------------------------------------------------------------------------

@dataclass
class File:
    filename: str
    title: str
    intro: str
    captures: List[Captured]


def write_file(file: File) -> None:
    EXAMPLES_DIR.mkdir(parents=True, exist_ok=True)
    path = EXAMPLES_DIR / file.filename
    body: List[str] = []
    body.append(f"# {file.title}")
    body.append("")
    body.append(file.intro)
    body.append("")
    body.append("> Generated by `scripts/generate-examples.py` from a live `translate` install. Each output below is the real captured stdout — none of it is hand-written.")
    body.append("")
    for cap in file.captures:
        body.append(render(cap))
    path.write_text("\n".join(body))
    print(f"  wrote {path.relative_to(ROOT)}  ({len(file.captures)} scenes)")


def write_index(files: List[File]) -> int:
    failures: List[tuple[str, str, List[str]]] = []
    skipped = 0
    passed = 0
    for f in files:
        for c in f.captures:
            if c.skipped_reason is not None:
                skipped += 1
            elif c.notes:
                failures.append((f.filename, c.label, c.notes))
            else:
                passed += 1

    body: List[str] = []
    body.append("# translate — Examples")
    body.append("")
    body.append("Each section is auto-generated by `scripts/generate-examples.py` from a live `translate` install. Every command is executed; every output below is exactly what the tool printed.")
    body.append("")
    body.append("Generation also doubles as a battle-test: a scene fails if its expected substring is missing or its exit code is wrong. Re-run with `make example` (or `python3 scripts/generate-examples.py`) to refresh the docs and re-run the battery.")
    body.append("")
    body.append("## Catalog")
    body.append("")
    for f in files:
        passed_in_file = sum(1 for c in f.captures if not c.notes and c.skipped_reason is None)
        skipped_in_file = sum(1 for c in f.captures if c.skipped_reason is not None)
        failed_in_file = sum(1 for c in f.captures if c.notes)
        status_bits = [f"{passed_in_file} passed"]
        if skipped_in_file:
            status_bits.append(f"{skipped_in_file} skipped")
        if failed_in_file:
            status_bits.append(f"**{failed_in_file} failed**")
        body.append(f"- [{f.title}](examples/{f.filename}) — {', '.join(status_bits)}")
    body.append("")
    body.append("## Summary")
    body.append("")
    body.append(f"- passed:  **{passed}**")
    body.append(f"- skipped: **{skipped}**  (model not installed)")
    body.append(f"- failed:  **{len(failures)}**")
    body.append("")

    if failures:
        body.append("### Failed scenes")
        body.append("")
        for fname, label, notes in failures:
            body.append(f"- `{fname}` — {label}")
            for n in notes:
                body.append(f"  - {n}")
        body.append("")

    INDEX_PATH.write_text("\n".join(body))
    print(f"  wrote {INDEX_PATH.relative_to(ROOT)}")
    return len(failures)


def main() -> int:
    if not EXAMPLES_DIR.exists():
        EXAMPLES_DIR.mkdir(parents=True, exist_ok=True)

    port = free_port()
    server = Server(port)
    print(f"==> starting translate --serve on port {port}")
    server.start()

    try:
        files: List[File] = []

        files.append(File(
            filename="01-cli-basics.md",
            title="01 · CLI basics",
            intro="Version, help, language detection, and listing models.",
            captures=section_cli_basics(),
        ))
        files.append(File(
            filename="02-cli-translate.md",
            title="02 · CLI translation",
            intro="Stdin, arguments, files, plain / JSON / NDJSON formats, batch mode, protected spans.",
            captures=section_cli_translate(),
        ))
        files.append(File(
            filename="03-cli-languages.md",
            title="03 · CLI across many language pairs",
            intro="Same shape, many pairs. Tests skip themselves when the pair is not installed locally.",
            captures=section_cli_languages(),
        ))
        files.append(File(
            filename="04-deepl-curl.md",
            title="04 · DeepL HTTP API · curl",
            intro="`/v2/translate`, `/v2/languages`, `/v2/usage`. Form-encoded and JSON bodies.",
            captures=section_deepl_curl(server),
        ))
        files.append(File(
            filename="05-deepl-python.md",
            title="05 · DeepL HTTP API · official Python SDK",
            intro="Drives `translate --serve` with the real `deepl` Python SDK by overriding `server_url`.",
            captures=section_deepl_python(server),
        ))
        files.append(File(
            filename="06-libretranslate-curl.md",
            title="06 · LibreTranslate HTTP API · curl",
            intro="`/translate`, `/detect`, `/languages`. Single string and array `q`. Auto detection.",
            captures=section_libre_curl(server),
        ))
        files.append(File(
            filename="07-libretranslate-python.md",
            title="07 · LibreTranslate HTTP API · libretranslatepy",
            intro="Drives `translate --serve` with the community `libretranslatepy` client.",
            captures=section_libre_python(server),
        ))
        files.append(File(
            filename="08-google-curl.md",
            title="08 · Google Translate v2 HTTP API · curl",
            intro="`/language/translate/v2`. Form (single + repeated `q`) and JSON bodies.",
            captures=section_google_curl(server),
        ))
        files.append(File(
            filename="09-google-python.md",
            title="09 · Google Translate v2 HTTP API · requests",
            intro="The v2 REST shape spoken by direct HTTP clients (no Google credentials needed against `translate --serve`).",
            captures=section_google_python(server),
        ))
        files.append(File(
            filename="10-cross-api-consistency.md",
            title="10 · Cross-API consistency",
            intro="The same prompt, sent through three different protocols, must return identical text — proving they share a single on-device engine.",
            captures=section_cross_api(server),
        ))
        files.append(File(
            filename="11-battle.md",
            title="11 · Battle tests",
            intro="Big batches, very long single inputs, mixed-script Unicode, protected URLs/emails/code.",
            captures=section_battle(server),
        ))

        for f in files:
            write_file(f)

        failed = write_index(files)
    finally:
        server.stop()

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
