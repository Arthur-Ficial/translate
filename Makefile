PRODUCT := translate
ALIAS := ueb
PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
MANDIR := $(PREFIX)/share/man/man1
VERSION_FILE := .version

BIN_PATH := $(shell swift build -c release --arch arm64 --show-bin-path 2>/dev/null)

.PHONY: build release install test test-unit test-integration test-real-clients example bench uninstall clean version

# --- Build ---

build:
	swift build

release:
	swift build -c release --arch arm64

# --- Install ---

install: release
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 0755 "$(BIN_PATH)/$(PRODUCT)" "$(DESTDIR)$(BINDIR)/$(PRODUCT)"
	ln -sf "$(PRODUCT)" "$(DESTDIR)$(BINDIR)/$(ALIAS)"
	install -d "$(DESTDIR)$(MANDIR)"
	install -m 0644 "man/translate.1" "$(DESTDIR)$(MANDIR)/translate.1"
	@echo "✓ installed: $$($(DESTDIR)$(BINDIR)/$(PRODUCT) --version)"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(PRODUCT)"
	rm -f "$(DESTDIR)$(BINDIR)/$(ALIAS)"
	rm -f "$(DESTDIR)$(MANDIR)/translate.1"

# --- Test ---

test: test-unit test-integration

test-unit:
	swift test

test-integration: release
	@bash scripts/run-examples.sh

test-real-clients: release
	@bash scripts/integration-real-clients.sh

example: release
	@python3 scripts/generate-examples.py

# --- Benchmarks ---

bench: release
	yes "Hallo Welt." | head -n 1000 | /usr/bin/time -p "$(BIN_PATH)/$(PRODUCT)" --from de --to en --batch --no-install > /dev/null

# --- Utilities ---

version:
	@cat $(VERSION_FILE)

clean:
	swift package clean
