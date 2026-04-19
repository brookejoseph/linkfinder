SDK ?= /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
MODULE_CACHE ?= /tmp/linkfinder-module-cache
BUILD_DIR ?= .build
PRODUCT := $(BUILD_DIR)/linkfinder
SOURCE := Sources/LinkFinder/main.swift

.PHONY: build clean run

build:
	@mkdir -p "$(BUILD_DIR)" "$(MODULE_CACHE)"
	swiftc -module-cache-path "$(MODULE_CACHE)" -sdk "$(SDK)" "$(SOURCE)" -o "$(PRODUCT)"

run: build
	"$(PRODUCT)" scan "/System/Applications/System Settings.app" --limit 20

clean:
	rm -rf "$(BUILD_DIR)"
