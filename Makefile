.PHONY: build build-app test install clean run

# Stable code signature: Keychain items only survive rebuilds when every
# build carries the same verifiable identity. Ad-hoc ("-") signatures change
# every build, so the app loses access to its own saved API keys. Falls back
# to ad-hoc when no signing identity is installed.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development|Developer ID Application/ {print $$2; exit}')
export SIGN_IDENTITY

build:
	swift build -c release

test:
	swift test

build-app:
	./scripts/build-app.sh

install: build-app
	-osascript -e 'tell application "Quick Launch" to quit'
	rm -rf "/Applications/Quick Launch.app"
	/usr/bin/ditto "build/Quick Launch.app" "/Applications/Quick Launch.app"
	codesign --verify --deep --strict --verbose=2 "/Applications/Quick Launch.app"
	rm -rf "build/Quick Launch.app"

clean:
	swift package clean

run:
	open "/Applications/Quick Launch.app"
