.PHONY: build build-app test install clean run

build:
	swift build -c release

test:
	swift test

build-app:
	./scripts/build-app.sh

install: build-app
	/usr/bin/ditto "build/Quick Launch.app" "/Applications/Quick Launch.app"
	codesign --verify --deep --strict --verbose=2 "/Applications/Quick Launch.app"

clean:
	swift package clean

run:
	open "/Applications/Quick Launch.app"
