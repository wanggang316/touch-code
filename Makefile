.PHONY: help bootstrap mac-bootstrap mac-build-ghostty mac-generate mac-build mac-build-cli mac-run-app mac-archive mac-format mac-lint mac-check mac-test mac-clean

MAC_APP_DIR := apps/mac

help:
	@echo "touch-code top-level Makefile (delegates to $(MAC_APP_DIR)/Makefile):"
	@echo "  bootstrap         - Init submodules + mise install"
	@echo "  mac-generate      - Generate touch-code.xcworkspace from Tuist"
	@echo "  mac-build         - Build mac app + tc CLI"
	@echo "  mac-build-cli     - Build tc CLI only"
	@echo "  mac-run-app       - Build and launch touch-code.app"
	@echo "  mac-archive       - Release archive + Developer ID export"
	@echo "  mac-build-ghostty - Build GhosttyKit.xcframework"
	@echo "  mac-format        - swift-format in-place"
	@echo "  mac-lint          - swiftlint"
	@echo "  mac-check         - format + lint"
	@echo "  mac-test          - (placeholder)"
	@echo "  mac-clean         - Remove workspace + project + Package.resolved"

bootstrap:
	git submodule update --init --recursive
	mise install

mac-bootstrap mac-build-ghostty mac-generate mac-build mac-build-cli mac-run-app mac-archive mac-format mac-lint mac-check mac-test mac-clean:
	$(MAKE) -C $(MAC_APP_DIR) $(subst mac-,,$@)
