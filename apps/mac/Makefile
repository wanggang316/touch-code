.PHONY: help bootstrap build-ghostty generate build run-app format lint check check-rename check-no-space-residue test clean build-cli

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

format:
	swift format --in-place --recursive --configuration ./.swift-format.json touch-code tc TouchCodeCore TouchCodeIPC

lint:
	mise exec -- swiftlint lint --quiet --config .swiftlint.yml

check-rename:
	../../scripts/check-rename-residue.sh apps/mac

# Temporary gate covering the Space -> Tag refactor (refactor/rm-space).
# Removed in M7 once the change has soaked. Excludes:
# - Catalog.swift (intentional v2 legacy decoder for migration)
# - touch-code/Tests/ (M2.12 follow-up)
# - Comments / migration / legacy keywords
# - FIXME markers carrying the rm-space tag
check-no-space-residue:
	@if grep -rn 'SpaceID\|\bSpace\b\|CatalogWindow\|spacePopover\|spaceFooter\|selectedSpaceID' \
	    --include='*.swift' \
	    TouchCodeCore TouchCodeIPC touch-code tc 2>/dev/null \
	    | grep -v 'TouchCodeCore/Catalog.swift' \
	    | grep -v 'touch-code/Tests/' \
	    | grep -v 'Tests/Fixtures' \
	    | grep -v 'TouchCodeCoreTests/CatalogCodableTests.swift' \
	    | grep -v '// FIXME(rm-space' \
	    | grep -v '// .*[Ll]egacy\|//.*migration\|//.*[Ss]pace' \
	    | grep -E '.'; then \
	  echo "Space residue found (see grep output above)"; exit 1; \
	fi

check: format lint check-rename check-no-space-residue

test:
	@echo "no tests yet"

clean:
	rm -rf .build touch-code.xcworkspace touch-code.xcodeproj Tuist/Package.resolved
