.PHONY: help bootstrap build-ghostty generate build run-app format lint check check-rename test clean build-cli archive release

# Use full Xcode.app when xcode-select points at Command Line Tools only.
# See DEC-10 in docs/exec-plans/0001-bootstrap-monorepo.md.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

help:
	@echo "apps/mac Makefile targets (usually invoked via top-level 'make mac-*'):"
	@echo "  bootstrap        - Init submodules + mise install"
	@echo "  build-ghostty    - Build GhosttyKit.xcframework (fingerprint-cached)"
	@echo "  generate         - tuist install + tuist generate"
	@echo "  build            - Build touch-code app + tc CLI"
	@echo "  build-cli        - Build tc only"
	@echo "  run-app          - Build and launch touch-code.app"
	@echo "  archive          - Release archive + Developer ID export (needs Release.xcconfig)"
	@echo "  release          - archive + notarize + DMG + notarize DMG + staple"
	@echo "  format           - swift-format in-place"
	@echo "  lint             - swiftlint"
	@echo "  check            - format + lint"
	@echo "  test             - (placeholder)"
	@echo "  clean            - Remove workspace + project + Package.resolved"

bootstrap:
	cd ../.. && git submodule update --init --recursive && mise install

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
	@APP=$$(xcodebuild -workspace touch-code.xcworkspace -scheme touch-code -configuration Debug -showBuildSettings 2>/dev/null | awk '$$1=="BUILT_PRODUCTS_DIR"{d=$$3} $$1=="FULL_PRODUCT_NAME"{p=$$3} END{print d "/" p}') && open "$$APP"

archive: generate
	./scripts/release.sh archive

release: generate
	./scripts/release.sh release

format:
	swift format --in-place --recursive --configuration ./.swift-format.json touch-code tc TouchCodeCore TouchCodeIPC

lint:
	mise exec -- swiftlint lint --quiet --config .swiftlint.yml

check-rename:
	../../scripts/check-rename-residue.sh apps/mac

check: format lint check-rename

test:
	@echo "no tests yet"

clean:
	rm -rf .build touch-code.xcworkspace touch-code.xcodeproj Tuist/Package.resolved
