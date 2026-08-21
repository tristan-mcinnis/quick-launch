.PHONY: build build-app test install clean run

build:
	swift build -c release

test:
	swift test

build-app:
	./scripts/build-app.sh

install: build-app
	/usr/bin/ditto build/apfel-quick.app /Applications/apfel-quick.app
	codesign --verify --deep --strict --verbose=2 /Applications/apfel-quick.app

clean:
	swift package clean

run:
	open /Applications/apfel-quick.app
