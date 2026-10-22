.PHONY: build build-app dmg test scrub install clean run check-clean

# Stable code signature: Keychain items only survive rebuilds when every
# build carries the same verifiable identity. Ad-hoc ("-") signatures change
# every build, so the app loses access to its own saved API keys. Falls back
# to ad-hoc when no signing identity is installed.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development|Developer ID Application/ {print $$2; exit}')
export SIGN_IDENTITY

build:
	swift build -c release

# The full gate: the publish scrub and the app suite.
test: scrub
	swift test

# No personal paths, private hosts, keys or client names in tracked files.
scrub:
	sh scripts/scrub.sh

build-app:
	./scripts/build-app.sh

# The free GitHub release download: an ad hoc signed DMG, SHA256SUMS, release
# notes and the draft-release command, in dist/release (or $(RELEASE_OUT)).
# It needs no Developer ID and publishes nothing. See scripts/make-dmg.sh.
dmg:
	./scripts/make-dmg.sh

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

# Quitting is one polite request and a bounded wait. The app waits for its
# archive writes before it quits and refuses the quit if they fail. The
# installer never escalates to SIGTERM or SIGKILL: if the app is still running
# after the bounded wait, the replacement is refused so no unsaved answer is
# lost. `scripts/wait-for-exit.sh` owns the wait and is tested with fake
# predicates, never against the real app.
install: check-clean build-app
	-@osascript -e 'with timeout of 5 seconds' \
		-e 'tell application "Quick Launch" to quit' \
		-e 'end timeout' >/dev/null 2>&1
	@if ! QUIT_WAIT_POLL_SECONDS=0.5 sh scripts/wait-for-exit.sh 10 pgrep -x quick-launch; then \
		echo "Quick Launch is still running; refusing to replace it." >&2; \
		echo "Quit it (and fix any save error it reports), then re-run make install." >&2; \
		exit 1; \
	fi
	rm -rf "/Applications/Quick Launch.app"
	/usr/bin/ditto "build/Quick Launch.app" "/Applications/Quick Launch.app"
	codesign --verify --deep --strict --verbose=2 "/Applications/Quick Launch.app"
	rm -rf "build/Quick Launch.app"

clean:
	swift package clean

run:
	open "/Applications/Quick Launch.app"
