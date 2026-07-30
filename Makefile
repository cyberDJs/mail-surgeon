.PHONY: build test app run clean-app

build:
	swift build

test:
	swift test

app:
	./Scripts/build-app.sh debug

run:
	./Scripts/run-app.sh

clean-app:
	rm -rf .build/app
