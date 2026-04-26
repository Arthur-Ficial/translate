# translate

**A deterministic, on-device translator for macOS.** A UNIX-style command and a drop-in HTTP server for DeepL, LibreTranslate, and Google v2 — all running 100% on-device using Apple's Translation framework.

`translate` is a tiny macOS CLI built as a UNIX filter: stdin in, stdout out, stderr for errors and optional progress. It uses Apple's on-device Translation framework on macOS Tahoe, auto-detects the source language with NaturalLanguage, reuses a single translation session per run, and batches work wherever possible. With `--serve` it exposes the same engine over HTTP, byte-compatible with DeepL `/v2/*`, LibreTranslate `/translate /detect /languages`, and Google `/language/translate/v2/*` — so existing client libraries point at it unchanged.

No cloud calls, no API keys, no telemetry, no LLMs, no third-party translation libraries. Apple's Translation framework is a deterministic neural translation engine — same input, same output, every time.

## What it is

| Mode | Command | Purpose |
| --- | --- | --- |
| **UNIX tool** | `translate --to en` | Pipe-friendly filter, exit codes, JSON/NDJSON output |
| **HTTP server** | `translate --serve` | Drop-in for DeepL, LibreTranslate, Google v2 clients |

## Requirements

- macOS 26 Tahoe or newer
- Apple silicon Mac
- Swift 6 toolchain (Command Line Tools with the macOS 26.4 SDK)
- Translation language models installed — see [docs/install-translation-models.md](docs/install-translation-models.md)

## Install

```sh
git clone https://github.com/Arthur-Ficial/translate.git
cd translate
make install
```

`make install` copies the release binary to `/usr/local/bin/translate` and creates the short alias `/usr/local/bin/ueb`.

## Quick Start: UNIX tool

```sh
echo "hallo welt" | translate --to en
translate --to de "hello world" "good night"
pbpaste | translate --to en | pbcopy
translate --to ja --format ndjson < sentences.txt | jq -r .dst
translate --install de-en
translate --detect-only < unknown.txt
```

## Quick Start: HTTP server

```sh
translate --serve --port 8989
```

### DeepL

Drop-in for DeepL clients (Python `deepl`, Node `deepl-node`):

```python
import deepl
translator = deepl.Translator("any-token", server_url="http://localhost:8989")
print(translator.translate_text("Hallo Welt", target_lang="EN"))
```

```sh
curl -s -X POST http://localhost:8989/v2/translate \
  --data-urlencode "text=Hallo Welt" \
  --data-urlencode "target_lang=EN"
# {"translations":[{"detected_source_language":"DE","text":"Hello World"}]}
```

### LibreTranslate

Drop-in for LibreTranslate clients (`libretranslatepy`, raw `requests`):

```python
import requests
r = requests.post("http://localhost:8989/translate",
                  json={"q": "Hallo Welt", "source": "auto", "target": "en"})
print(r.json())
# {"detectedLanguage":{"confidence":97,"language":"de"},"translatedText":"Hello World"}
```

### Google Cloud Translation v2

Drop-in for the v2 REST API. Override the base URL in your client.

```sh
curl -s -X POST "http://localhost:8989/language/translate/v2" \
  --data-urlencode "q=Hallo Welt" \
  --data-urlencode "target=en"
# {"data":{"translations":[{"detectedSourceLanguage":"de","translatedText":"Hello World"}]}}
```

## Options

| Flag | Meaning |
| --- | --- |
| `--to <lang>` | Target language, e.g. `en`, `de`, `ja`, `de-AT` |
| `--from <lang>` | Source language; skips auto-detection |
| `--detect-only` | Print detected language and confidence, then exit |
| `--format <mode>` | `plain` (default), `json`, `ndjson` |
| `--preserve-newlines` | Preserve newline structure; default |
| `--no-preserve-newlines` | Allow paragraph-level reflow |
| `--batch` | Treat each stdin line as an independent unit |
| `--file <path>` | Translate a UTF-8 file; repeatable |
| `--install <pair>` | Prepare/download a pair such as `de-en` |
| `--installed` | List installed language pairs |
| `--available` | List supported language pairs |
| `--no-install` | Fail with exit 4 if a required model is missing |
| `--langs <a,b,c>` | Detection hints for short ambiguous input |
| `--quiet` | Suppress progress on stderr |
| `--serve` | Run as HTTP server |
| `--port <n>` | Server port (default 8989) |
| `--host <addr>` | Server bind address (default 127.0.0.1) |
| `--api-key <k>` | Optional client auth token |

## Why on-device?

On-device translation keeps source text local, reduces latency, works offline after models are installed, and needs no API key, account, usage quota, proxy, or billing setup. It is also easier to script safely: the same input, model version, and flags produce byte-stable output without a remote service changing behavior between runs.

## Model management

```sh
translate --install de-en      # prepare a pair
translate --installed          # list installed pairs
translate --available          # list supported pairs on this OS
```

For scripts, prevent automatic model preparation:

```sh
translate --from de --to en --no-install < input.txt
```

If the model is missing, the command exits with code 4.

## Protected text

`translate` does not translate fenced code blocks, inline backtick spans, URLs, or email addresses. Those spans pass through unchanged.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | OK |
| 1 | input or usage error |
| 2 | translation failure |
| 3 | unsupported OS |
| 4 | model not installed and `--no-install` set |
| 5 | unsupported language pair |

## Testing

```sh
make test                  # unit + Swift HTTP integration tests
make test-real-clients     # exercise the server with real Python clients
                           # (deepl, libretranslatepy, requests, google-cloud-translate)
```

The unit suite drives every codec and every endpoint via real loopback HTTP. The real-client suite proves drop-in compatibility with three production translation APIs.

See [EXAMPLE.md](EXAMPLE.md) for end-to-end CLI and server scenarios.

## Benchmarks

```sh
make bench
```

Reference targets on Apple silicon with installed low-latency models:

| Scenario | Target |
| --- | --- |
| Cold start, installed model | < 200 ms |
| Batch short sentences | ≥ 500 sentences/sec |
| Typical resident memory | < 300 MB |
| Network calls during translation | 0 |

## License

MIT — see [LICENSE](LICENSE).
