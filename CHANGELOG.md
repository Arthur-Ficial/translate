# Changelog

All notable changes to `translate` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] – 2026-04-26

First release. UNIX-style on-device translator for macOS Tahoe with a
drop-in HTTP server compatible with three production translation APIs.

### Added

- **CLI**: pipe-friendly UNIX filter (`stdin`/`stdout`/`stderr`,
  `--to`, `--from`, `--detect-only`, `--format plain|json|ndjson`,
  `--batch`, `--file`, `--installed`, `--available`, `--no-install`,
  `--langs`, `--quiet`).
- **HTTP server** (`--serve`):
  - DeepL `/v2/translate`, `/v2/languages`, `/v2/usage` — works with
    the official `deepl` Python SDK by overriding `server_url=`.
    Accepts form-encoded and JSON bodies, repeated `text` fields,
    `Authorization: DeepL-Auth-Key` header, `formality`,
    `tag_handling`, `split_sentences`, `preserve_formatting`.
    Response includes `billed_characters` so the SDK parses cleanly.
  - LibreTranslate `/translate`, `/detect`, `/languages`, `/spec`,
    `/frontend/settings` — works with `libretranslatepy`. Single
    string and array `q`, `source: auto`, `alternatives` field.
  - Google Translate v2 `/language/translate/v2`,
    `/language/translate/v2/languages` — accepts repeated `q`,
    `?key=` URL param, `X-goog-api-key` header. Returns the
    canonical `{"data":{"translations":[...]}}` envelope.
  - `/health`, `/healthz` for liveness checks.
  - Per-API error envelopes: `{"message":...}` for DeepL,
    `{"error":...}` for LibreTranslate,
    `{"error":{"code":N,"message":...,"errors":[...]}}` for Google.
  - CORS headers on every JSON response.
- **Protected text**: URLs, email addresses, fenced code blocks, and
  inline backtick spans pass through translation unchanged.
- **Streaming**: paragraph and line splitters with UTF-8 chunk
  reassembly so very large stdin inputs don't buffer in memory.
- **Apple Translation engine**: deterministic, on-device, no LLM, no
  cloud, no API key.
- **Tests**: 136 Swift unit + integration tests (codecs, masker,
  streaming, errors, model lookup, drop-in compat against real
  loopback HTTP). Subprocess E2E tests drive the built binary.
- **Examples**: `scripts/generate-examples.py` runs every documented
  example against the live server, asserts behavior, and writes
  `EXAMPLE.md` plus per-API files in `examples/`. Doc generation IS
  the battle test.
- **Distribution**: Makefile (`make build`, `make install`,
  `make test`, `make example`, `make bench`), man page,
  `docs/install-translation-models.md` tutorial with screenshots.

### Notes

- `translate --install <pair>` is a no-op on the current Tahoe seed
  because Apple's headless preparation API requires a SwiftUI host.
  Use System Settings → General → Language & Region → Translation
  Languages instead. See `docs/install-translation-models.md`.
- Builds with Swift 6 strict concurrency and `-warn-concurrency`.
