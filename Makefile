.PHONY: build test app run clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

run: app
	open build/record2gif.app

clean:
	swift package clean
	rm -rf build
