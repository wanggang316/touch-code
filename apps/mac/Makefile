.PHONY: help bootstrap build-ghostty generate build run-app format lint check test clean build-cli \
  skill-version skill-validate skill-golden-update skill-tier-b

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
	@echo "  skill-version    - Sync tc version into touch-code-skill/VERSION + package.json"
	@echo "  skill-validate   - Tier-A skill checks (tc help-json roundtrip + golden + orthogonality)"
	@echo "  skill-golden-update - Regenerate apps/mac/scripts/skill-golden-manifest.txt"
	@echo "  skill-tier-b     - Run Tier-B per-agent smoke tests (release gate)"

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
	@APP=$$(xcodebuild -workspace touch-code.xcworkspace -scheme touch-code -configuration Debug -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{d=$$3} /FULL_PRODUCT_NAME/{p=$$3} END{print d "/" p}') && open "$$APP"

format:
	swift format --in-place --recursive --configuration ./.swift-format.json touch-code tc TouchCodeCore TouchCodeIPC

lint:
	mise exec -- swiftlint lint --quiet --config .swiftlint.yml

check: format lint

test:
	@echo "no tests yet"

clean:
	rm -rf .build touch-code.xcworkspace touch-code.xcodeproj Tuist/Package.resolved

# --- Skill package (C5) ---

skill-version:
	./scripts/generate-skill-version.sh

skill-validate: build-cli
	./scripts/skill-tier-a.sh

skill-golden-update: build-cli
	./scripts/skill-golden-update.sh

# Tier-B runs the per-agent smoke scripts. Each degrades gracefully (exit 0 with
# warning) when its agent CLI isn't installed — see DEC-5.
skill-tier-b: build-cli
	./scripts/skill-tier-b-claude.sh
	./scripts/skill-tier-b-codex.sh
	../../touch-code-skill/tests/pi.smoke.sh
