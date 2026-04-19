.PHONY: help bootstrap build-ghostty generate build run-app format lint check test clean build-cli

# Default target
help:
	@echo "touch-code Makefile targets:"
	@echo "  bootstrap        - Initialize mise + git submodules"
	@echo "  build-ghostty    - Build GhosttyKit.xcframework (idempotent via fingerprint cache)"
	@echo "  generate         - Generate touch-code.xcworkspace from Tuist"
	@echo "  build            - Build all targets"
	@echo "  build-cli        - Build tc CLI target only"
	@echo "  run-app          - Build and run touch-code.app"
	@echo "  format           - Format Swift code"
	@echo "  lint             - Run SwiftLint"
	@echo "  check            - Run format + lint"
	@echo "  test             - Run tests (placeholder)"
	@echo "  clean            - Remove build artifacts"

bootstrap:
	git submodule update --init --recursive
	mise install

build-ghostty:
	./scripts/build-ghostty.sh

generate: bootstrap
	mise exec -- tuist install
	mise exec -- tuist generate --no-open

build: generate
	xcodebuild -workspace touch-code.xcworkspace -scheme touch-code -configuration Debug build
	xcodebuild -workspace touch-code.xcworkspace -scheme tc -configuration Debug build

build-cli: generate
	xcodebuild -workspace touch-code.xcworkspace -scheme tc -configuration Debug build

run-app: build
	open ./.build/Debug/touch-code.app

format:
	swift format --in-place --recursive --configuration ./.swift-format.json apps packages

lint:
	mise exec -- swiftlint lint --quiet --config .swiftlint.yml

check: format lint

test:
	@echo "no tests yet"

clean:
	rm -rf .build touch-code.xcworkspace touch-code.xcodeproj Tuist/Package.resolved
