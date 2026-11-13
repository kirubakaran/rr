PREFIX ?= $(HOME)/.local

build:
	swift build -c release

test:
	swift test

install: build
	mkdir -p $(PREFIX)/bin
	# Remove first: overwriting a signed binary in place makes macOS kill it on launch.
	rm -f $(PREFIX)/bin/rr
	cp .build/release/rr $(PREFIX)/bin/rr

.PHONY: build test install
