PREFIX ?= $(HOME)/.local

build:
	swift build -c release

test:
	swift test

install: build
	mkdir -p $(PREFIX)/bin
	cp .build/release/rr $(PREFIX)/bin/rr

.PHONY: build test install
