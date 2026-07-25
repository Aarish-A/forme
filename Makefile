# Forme — common tasks.
# Every command CI runs is defined here, so `make ci` locally is the same check.

PROJECT   := Forme.xcodeproj
SCHEME    := Forme
SIMULATOR ?= iPhone 17
DESTINATION := platform=iOS Simulator,name=$(SIMULATOR)

# xcbeautify makes xcodebuild output readable. Optional — falls back to `cat`.
FORMATTER := $(shell command -v xcbeautify 2>/dev/null || echo cat)

# The versions CI pins. Local tools must match, or the format-on-save hook
# rewrites files in a way CI then rejects.
SWIFTFORMAT_VERSION := $(shell awk '$$1 == "swiftformat" { print $$2 }' .tool-versions)
SWIFTLINT_VERSION   := $(shell awk '$$1 == "swiftlint" { print $$2 }' .tool-versions)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: bootstrap
bootstrap: ## One-time setup for a fresh clone
	@command -v swiftlint >/dev/null || brew install swiftlint
	@command -v swiftformat >/dev/null || brew install swiftformat
	@command -v xcbeautify >/dev/null || brew install xcbeautify
	@test -f Config/Secrets.xcconfig \
		|| (cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig \
			&& echo "Created Config/Secrets.xcconfig — add your Supabase values.")
	@xcodebuild -resolvePackageDependencies -project $(PROJECT) >/dev/null
	@$(MAKE) --no-print-directory tools
	@echo "Ready. Run 'make test'."

.PHONY: tools
tools: ## Check local tool versions match the ones CI pins
	@ok=1; \
	have=$$(swiftformat --version); \
	if [ "$$have" != "$(SWIFTFORMAT_VERSION)" ]; then \
		echo "swiftformat $$have installed, CI pins $(SWIFTFORMAT_VERSION) — brew upgrade swiftformat"; ok=0; \
	fi; \
	have=$$(swiftlint version); \
	if [ "$$have" != "$(SWIFTLINT_VERSION)" ]; then \
		echo "swiftlint $$have installed, CI pins $(SWIFTLINT_VERSION) — brew upgrade swiftlint"; ok=0; \
	fi; \
	test $$ok -eq 1

.PHONY: build
build: ## Build the app for the simulator
	@set -o pipefail && xcodebuild build \
		-project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' | $(FORMATTER)

.PHONY: test
test: ## Run unit and UI tests
	@set -o pipefail && xcodebuild test \
		-project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-enableCodeCoverage YES | $(FORMATTER)

.PHONY: unit
unit: ## Run unit tests only (fast)
	@set -o pipefail && xcodebuild test \
		-project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-only-testing:FormeTests | $(FORMATTER)

.PHONY: lint
lint: ## Check style with SwiftLint
	@swiftlint lint --strict

.PHONY: format
format: ## Rewrite sources with SwiftFormat
	@swiftformat .

.PHONY: format-check
format-check: ## Verify formatting without rewriting
	@swiftformat --lint .

.PHONY: ci
ci: tools format-check lint test ## Everything CI runs

.PHONY: clean
clean: ## Remove build artefacts
	@xcodebuild clean -project $(PROJECT) -scheme $(SCHEME) >/dev/null
	@rm -rf DerivedData
	@echo "Cleaned."
