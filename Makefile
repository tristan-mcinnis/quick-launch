.PHONY: build build-app test install clean run check-clean

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

# `make install` installs what build-app.sh compiled from the WORKING TREE,
# not from HEAD, so installing a dirty checkout produces a binary that traces
# to no commit at all (bitten 2026-09-12: a house app installed mid-edit ran
# for an hour answering in a reply format that existed only in uncommitted
# edits, which is the only reason the mismatch was ever noticed). Refuse by
# default; override deliberately with QL_ALLOW_DIRTY=1, and build-app.sh then
# stamps the commit as <sha>-dirty. A recipe line is its own shell, so the
# whole check is one `if` continued with backslashes: its `exit 1` fails the
# recipe and `make` stops before build-app runs. `make build` and
# `make build-app` are deliberately NOT guarded — they install nothing.
check-clean:
	@if [ -n "$$(git status --porcelain)" ] && [ "$${QL_ALLOW_DIRTY:-0}" != "1" ]; then \
		echo "refusing to install from a dirty working tree." >&2; \
		git status --short >&2; \
		echo "commit or stash first, or re-run with QL_ALLOW_DIRTY=1 to override." >&2; \
		exit 1; \
	fi

install: check-clean build-app
	-osascript -e 'tell application "Quick Launch" to quit'
	@for attempt in $$(seq 1 20); do \
		pgrep -x quick-launch >/dev/null || break; sleep 0.5; \
	done; \
	if pgrep -x quick-launch >/dev/null; then \
		echo "Quick Launch did not quit; refusing to replace the running app." >&2; exit 1; \
	fi
	rm -rf "/Applications/Quick Launch.app"
	/usr/bin/ditto "build/Quick Launch.app" "/Applications/Quick Launch.app"
	codesign --verify --deep --strict --verbose=2 "/Applications/Quick Launch.app"
	rm -rf "build/Quick Launch.app"

clean:
	swift package clean

run:
	open "/Applications/Quick Launch.app"
